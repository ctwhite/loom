;;; loom-primitives.el --- Core Promise Chaining Primitives -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file defines the fundamental functions for chaining and handling promise
;; outcomes: `loom:then`, `loom:catch`, `loom:finally`, and `loom:tap`.
;; These build upon the core promise object and internal callback mechanisms
;; defined in `loom-promise.el`.
;;
;; They provide the primary, user-facing interface for building asynchronous
;; workflows, adhering to the Promise/A+ specification for handler attachment
;; and resolution.

;;; Code:

(require 'cl-lib)

(require 'loom-errors)
(require 'loom-callback)
(require 'loom-promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--find-and-run-catch-handler (handlers err)
  "Find and execute the appropriate error handler for ERR.
This is a helper for `loom:catch`. It returns a cons cell `(FOUND . RESULT)`
where FOUND is t if a handler was run, and RESULT is its return value.

Arguments:
- `HANDLERS` (list): The handler specifications from `loom:catch`.
- `ERR` (loom-error): The error to be handled.

Returns:
- (cons): A cell `(t . value)` on success, or `(nil)` if no handler matched."
  (let ((is-simple-handler (or (null handlers) (not (keywordp (car handlers))))))
    (if is-simple-handler
        ;; --- Case 1: A single, simple handler ---
        (if-let ((handler (car handlers)))
            (cons t (funcall handler err))
          (cons nil nil)) ; No handler provided.
      ;; --- Case 2: Typed handlers ---
      (let* ((err-type (and (loom-error-p err) (loom-error-type err)))
             (handler-list handlers)
             (default-handler nil))
        ;; Isolate the default handler if it exists at the end.
        (when (and handler-list (functionp (car (last handler-list))))
          (setq default-handler (car (last handler-list)))
          (setq handler-list (butlast handler-list)))

        ;; Find and run the first matching typed handler.
        (cl-loop for (key type-spec handler) on handler-list by #'cdddr
                 if (and (eq key :type)
                         (or (eq t type-spec)
                             (eq err-type type-spec)
                             (and (listp type-spec) (memq err-type type-spec))))
                 return (cons t (funcall handler err)))

        ;; If no typed handler matched, try the default handler.
        (if default-handler
            (cons t (funcall default-handler err))
          (cons nil nil)))))) ; No handler matched at all.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Attaching Callbacks

;;;###autoload
(defun loom:then (promise on-resolved &optional on-rejected)
  "The primary function for promise composition (implements Promises/A+ `then`).
Attaches `ON-RESOLVED` and `ON-REJECTED` handlers to a `PROMISE`,
returning a new promise that is resolved or rejected by the return
value of these handlers.

Arguments:
- `PROMISE` (any): The promise or value to attach handlers to.
- `ON-RESOLVED` (function): Handler `(lambda (value))` for success.
- `ON-REJECTED` (function, optional): Handler `(lambda (error))` for failure.

Returns:
- (loom-promise): A new promise representing the outcome of the handler.

Signals:
- Rejects the returned promise with a `:callback-error` if a handler
  function itself raises an error.

Side Effects:
- Schedules the execution of `ON-RESOLVED` or `ON-REJECTED` on
  the microtask queue when `PROMISE` settles."
  (let* ((source-promise (if (loom-promise-p promise)
                             promise
                           (loom:resolved! promise)))
         ;; Spec 2.2.7: `then` must return a promise.
         (new-promise (loom:promise
                       :name (format "then-%S" (loom-promise-id source-promise))
                       :parent-promise source-promise))
         (source-id (loom-promise-id source-promise))
         (target-id (loom-promise-id new-promise))
         (captured-async-stack loom-current-async-stack))
    (loom-attach-callbacks
     source-promise
     ;; on-resolved handler wrapper
     (loom:callback
      (lambda (target-promise res)
        (let ((label (format "on-resolved (%S -> %S)" source-id target-id)))
          (cl-letf (((symbol-value 'loom-current-async-stack)
                     (cons label captured-async-stack)))
            (condition-case err
                ;; Spec 2.2.7.1: If onResolved returns a value x,
                ;; run [[Resolve]](promise2, x).
                (loom:resolve target-promise (funcall on-resolved res))
              ;; Spec 2.2.7.2: If onResolved throws an exception e,
              ;; promise2 must be rejected with e as the reason.
              (error (loom:reject target-promise
                                    (loom:make-error :type :callback-error
                                                     :cause err)))))))
      :type :resolved
      :source-promise-id source-id
      :promise-id target-id)
     ;; on-rejected handler wrapper
     (loom:callback
      (if on-rejected
          ;; If the user provided an on-rejected handler, wrap it.
          (lambda (target-promise err)
            (let ((label (format "on-rejected (%S -> %S)" source-id target-id)))
              (cl-letf (((symbol-value 'loom-current-async-stack)
                         (cons label captured-async-stack)))
                (condition-case handler-err
                    ;; Spec 2.2.7.1
                    (loom:resolve target-promise (funcall on-rejected err))
                  ;; Spec 2.2.7.2
                  (error (loom:reject target-promise
                                        (loom:make-error :type :callback-error
                                                         :cause handler-err)))))))
        ;; Spec 2.2.7.4: If onRejected is not a function, promise2
        ;; must be rejected with the same reason as promise1.
        (lambda (target-promise err)
          (loom:reject target-promise err)))
      :type :rejected
      :source-promise-id source-id
      :promise-id target-id))
    new-promise))

;;;###autoload
(defun loom:catch (promise &rest handlers)
  "Attach an error handler to a promise, with optional type filtering.
This is a more convenient syntax for the `on-rejected` argument of
`loom:then`. It allows successful values to pass through untouched.

Handlers can be provided in two forms:
1. A single function `(lambda (error))` that handles all errors.
2. A plist of `:type` specifications and handler functions, e.g.,
   `(:type :foo #'handle-foo)`. An optional final function can act
   as a default case.

Arguments:
- `PROMISE` (any): The promise or value to attach handlers to.
- `HANDLERS` (function or plist): The error handling logic.

Returns:
- (loom-promise): A new promise that resolves with the original
  value on success, or with the result of a matched error handler
  on failure.

Signals:
- Rejects the returned promise with a `:callback-error` if a matched
  handler function itself raises an error.

Side Effects:
- Schedules handler execution on the microtask queue if `PROMISE` rejects."
  (let* ((source-promise (if (loom-promise-p promise)
                             promise
                           (loom:resolved! promise)))
         (new-promise (loom:promise
                       :name (format "catch-%S" (loom-promise-id source-promise))
                       :parent-promise source-promise))
         (source-id (loom-promise-id source-promise))
         (target-id (loom-promise-id new-promise)))
    (loom-attach-callbacks
     source-promise
     ;; Spec 2.2.7.3: If onResolved is not a function, promise2 must be
     ;; fulfilled with the same value as promise1. This is our pass-through.
     (loom:callback
      (lambda (target-promise value) (loom:resolve target-promise value))
      :type :resolved
      :source-promise-id source-id
      :promise-id target-id)

     ;; on-rejected: The core logic for catching and handling errors.
     (loom:callback
      (lambda (target-promise err)
        (condition-case handler-err
            (let* ((handler-result (loom--find-and-run-catch-handler handlers err))
                   (handler-found (car handler-result))
                   (result (cdr handler-result)))
              (if handler-found
                  (loom:resolve target-promise result)
                ;; If no handler was found, re-reject with the original error.
                (loom:reject target-promise err)))
          ;; If the handler itself throws an error, reject the new promise.
          (error (loom:reject target-promise
                                (loom:make-error :type :callback-error
                                                 :cause handler-err)))))
      :type :rejected
      :source-promise-id source-id
      :promise-id target-id))
    new-promise))

(defun loom:finally (promise callback-fn)
  "Attach a callback to run when `PROMISE` settles (resolves or rejects).
This is useful for cleanup operations that must occur regardless of
the promise's outcome (e.g., closing a file, stopping a spinner).

Arguments:
- `PROMISE` (any): The promise or value to attach the cleanup action to.
- `CALLBACK-FN` (function): A nullary function `(lambda () ...)` to execute.

Returns:
- (loom-promise): A new promise that settles with the original
  outcome of `PROMISE` after `CALLBACK-FN` has also completed.

Signals:
- If `CALLBACK-FN` itself returns a rejected promise or signals an
  error, the new promise returned by `loom:finally` will reject with
  that new error, overriding the original outcome of `PROMISE`.

Side Effects:
- Schedules `CALLBACK-FN` for execution when `PROMISE` settles."
  (let* ((source-promise (if (loom-promise-p promise)
                             promise
                           (loom:resolved! promise)))
         (target-promise (loom:promise
                          :name (format "finally-%S" (loom-promise-id source-promise))
                          :parent-promise source-promise))
         (source-id (loom-promise-id source-promise))
         (target-id (loom-promise-id target-promise)))

    ;; `handle-callback` is a local helper that orchestrates the complex
    ;; chaining required by `finally`.
    (cl-flet ((handle-callback (original-outcome is-resolved)
                (condition-case cb-err
                    (let* (;; 1. Execute the user's side-effect callback.
                           (cb-result (funcall callback-fn))
                           ;; 2. The callback might return a promise, so we
                           ;;    normalize its result into one.
                           (cb-promise (if (loom-promise-p cb-result)
                                           cb-result
                                         (loom:resolved! cb-result))))
                      ;; 3. Wait for the callback's promise to settle before
                      ;;    settling the main `target-promise`.
                      (loom:then
                       cb-promise
                       ;; 3a. If the side-effect callback succeeds...
                       (lambda (_)
                         ;; ...settle our target promise with the
                         ;; original promise's outcome.
                         (if is-resolved
                             (loom:resolve target-promise original-outcome)
                           (loom:reject target-promise original-outcome)))
                       ;; 3b. If the side-effect callback fails...
                       (lambda (cb-reason)
                         ;; ...reject our target promise with the new error.
                         (loom:reject target-promise cb-reason))))
                  ;; If `callback-fn` itself throws a synchronous error,
                  ;; that error immediately rejects the target promise.
                  (error (loom:reject target-promise
                                      (loom:make-error :type :callback-error
                                                       :cause cb-err))))))

      ;; Attach the primary handlers to the original source promise.
      (loom-attach-callbacks
       source-promise
       (loom:callback (lambda (_tp value) (handle-callback value t))
                      :type :resolved
                      :source-promise-id source-id
                      :promise-id target-id)
       (loom:callback (lambda (_tp reason) (handle-callback reason nil))
                      :type :rejected
                      :source-promise-id source-id
                      :promise-id target-id)))
    target-promise))

;;;###autoload
(defun loom:tap (promise callback-fn)
  "Attach a callback for side effects, without altering the promise chain.
This is useful for inspecting a promise's value or error at a
certain point in a chain without modifying it (e.g., for logging).
The original outcome is always passed through.

Arguments:
- `PROMISE` (any): The promise or value to inspect.
- `CALLBACK-FN` (function): A function `(lambda (value error) ...)`
  to execute. It receives either a `value` or an `error`, never both.

Returns:
- (loom-promise): A new promise that settles with the exact same
  outcome as the original `PROMISE`.

Side Effects:
- Schedules `CALLBACK-FN` for execution when `PROMISE` settles. Any
  error raised within `CALLBACK-FN` is ignored."
  (loom:then
   promise
   ;; on-resolved: run callback, then pass original value through.
   (lambda (value)
     (condition-case nil (funcall callback-fn value nil) (error nil))
     value)
   ;; on-rejected: run callback, then re-throw original error.
   (lambda (err)
     (condition-case nil (funcall callback-fn nil err) (error nil))
     (signal (loom-error-type err) (list (loom:error-value err))))))

(provide 'loom-primitives)
;;; loom-primitives.el ends here