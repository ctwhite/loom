;;; loom-primitives.el --- Core Promise Chaining Primitives -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file defines the fundamental functions for chaining and handling promise
;; outcomes: `loom:then`, `loom:catch`, `loom:finally`, and `loom:tap`.
;; These build upon the core promise object and internal callback mechanisms
;; defined in `loom-core.el`.
;;
;; They provide the primary, user-facing interface for building asynchronous
;; workflows, adhering to the Promise/A+ specification for handler attachment
;; and resolution.

;;; Code:

(require 'cl-lib)

(require 'loom-core)
(require 'loom-errors)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Attaching Callbacks

;;;###autoload
(defun loom:then (promise on-resolved &optional on-rejected)
  "The primary function for promise composition (implements Promises/A+ `then`).

Attaches `ON-RESOLVED` and `ON-REJECTED` handlers to a `PROMISE`,
returning a new promise that is resolved or rejected by the return
value of these handlers.

If the input `PROMISE` is not a promise, it is treated as an
already-resolved promise with that value.

Arguments:
- `PROMISE` (any): The promise or value to attach handlers to.
- `ON-RESOLVED` (function): Handler `(lambda (value))` for success.
  If it returns a promise, the new promise will adopt its state.
- `ON-REJECTED` (function, optional): Handler `(lambda (error))`
  for failure. If omitted, defaults to a handler that propagates
  the error, allowing it to be caught by a later `loom:catch`.

Returns:
- (loom-promise): A new promise representing the outcome of the handler.

Signals:
- `loom-error` of type `:callback-error` if a provided handler
  function itself raises an error during its execution.

Side Effects:
- Schedules the execution of `ON-RESOLVED` or `ON-REJECTED` on
  the microtask queue when `PROMISE` settles."
  (let* ((source-promise (if (loom-promise-p promise)
                             promise
                           (loom:resolved! promise)))
         (new-promise (loom:promise
                       :name (format "then-%S" (loom-promise-id source-promise))
                       :parent-promise source-promise))
         (source-id (loom-promise-id source-promise))
         (target-id (loom-promise-id new-promise))
         ;; Capture the async stack lexically at creation time. This value is
         ;; "closed over" by the lambdas below and will be available when they
         ;; are eventually executed.
         (captured-async-stack loom-current-async-stack))
    (loom--attach-callbacks
     source-promise
     ;; on-resolved handler wrapper
     (loom--make-internal-callback
      :type :resolved
      :source-promise-id source-id
      :promise-id target-id
      :handler-fn
      (lambda (target-promise res)
        (let ((label (format "on-resolved (%S -> %S)" source-id target-id)))
          ;; Rebind the dynamic variable when the async handler runs.
          (cl-letf (((symbol-value 'loom-current-async-stack)
                     (cons label captured-async-stack)))
            (condition-case err
                (loom:resolve target-promise (funcall on-resolved res))
              (error (loom:reject target-promise
                                    (loom:make-error :type :callback-error
                                                       :cause err))))))))
     ;; on-rejected handler wrapper
     (loom--make-internal-callback
      :type :rejected
      :source-promise-id source-id
      :promise-id target-id
      :handler-fn
      (if on-rejected
          ;; If the user provided an on-rejected handler, wrap it.
          (lambda (target-promise err)
            (let ((label (format "on-rejected (%S -> %S)" source-id target-id)))
              ;; Rebind here as well, using the lexically captured stack.
              (cl-letf (((symbol-value 'loom-current-async-stack)
                         (cons label captured-async-stack)))
                (condition-case handler-err
                    (loom:resolve target-promise (funcall on-rejected err))
                  (error (loom:reject target-promise
                                        (loom:make-error :type :callback-error
                                                           :cause handler-err)))))))
        ;; **FIX**: If no handler is provided, create a default one
        ;; that propagates the error to the next link in the chain.
        (lambda (target-promise err)
          (loom:reject target-promise err)))))
    new-promise))

;;;###autoload
(defun loom:catch (promise &rest handlers)
  "Attach an error handler to a promise, with optional type filtering.

This is a more convenient syntax for the `on-rejected` argument of
`loom:then`. It allows successful values to pass through untouched.

Handlers can be provided in two forms:
1. A single function `(lambda (error))` that handles all errors.
2. A plist of `:type` specifications and handler functions, e.g.,
   `(:type :foo #'handle-foo :type :bar #'handle-bar)`. An optional
   final function can act as a default case.

Arguments:
- `PROMISE` (any): The promise or value to attach handlers to.
- `HANDLERS` (function or plist): The error handling logic.

Returns:
- (loom-promise): A new promise that resolves with the original
  value on success, or with the result of a matched error handler
  on failure.

Signals:
- `loom-error` of type `:callback-error` if a matched handler
  function itself raises an error.

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
    (loom--attach-callbacks
     source-promise
     ;; on-resolved: A simple pass-through for successful values.
     (loom--make-internal-callback
      :type :resolved
      :source-promise-id source-id
      :promise-id target-id
      :handler-fn (lambda (target-promise value) (loom:resolve target-promise value)))

     ;; on-rejected: The core logic for catching and handling errors.
     (loom--make-internal-callback
      :type :rejected
      :source-promise-id source-id
      :promise-id target-id
      :handler-fn
      (lambda (target-promise err)
        (condition-case handler-err
            ;; --- Main handler logic, now safely wrapped ---
            (let* ((is-simple-handler (or (null handlers) (not (keywordp (car handlers)))))
                   (handler-found nil)
                   (result nil))

              (if is-simple-handler
                  ;; --- Case 1: A single, simple handler ---
                  (let ((handler (car handlers)))
                    (if handler
                        (progn
                          (setq result (funcall handler err))
                          (setq handler-found t))
                      ;; No handler provided, so it's a re-rejection.
                      (loom:reject target-promise err)))

                ;; --- Case 2: Typed handlers ---
                (let* ((err-type (and (loom-error-p err) (loom:error-type err)))
                       (handler-list handlers)
                       (default-handler nil))
                  ;; Isolate the default handler if it exists.
                  (when (and handler-list (functionp (car (last handler-list))))
                    (setq default-handler (car (last handler-list)))
                    (setq handler-list (butlast handler-list)))

                  ;; Find the first matching typed handler.
                  (cl-loop for (key type-spec handler) on handler-list by #'cdddr
                           when (and (eq key :type)
                                     (or (eq t type-spec)
                                         (eq err-type type-spec)
                                         (and (listp type-spec) (memq err-type type-spec)))
                                     (not handler-found))
                           do (setq result (funcall handler err)
                                    handler-found t))

                  ;; If no typed handler matched, try the default handler.
                  (when (and (not handler-found) default-handler)
                    (setq result (funcall default-handler err))
                    (setq handler-found t))))

              (if handler-found
                  (loom:resolve target-promise result)
                ;; If no handler was found at all, re-reject.
                (loom:reject target-promise err)))

          ;; --- Error handling for the handler function itself ---
          (error (loom:reject target-promise
                                (loom:make-error :type :callback-error
                                                   :cause handler-err)))))))
    new-promise))

(defun loom:finally (promise callback-fn)
  "Attach a callback to run when `PROMISE` settles (resolves or rejects).

This is useful for cleanup operations that must occur regardless of
the promise's outcome (e.g., closing a file, stopping a spinner).
The outcome of the original `PROMISE` is passed through to the returned
promise, but only after the `CALLBACK-FN` has completed.

Arguments:
- `PROMISE` (any): The promise or value to attach the cleanup action to.
- `CALLBACK-FN` (function): A nullary function `(lambda () ...)` to
  execute for its side effects. Its return value can be a promise,
  which will be awaited before the chain continues.

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
         ;; The new promise that will be returned to the user.
         (target-promise (loom:promise
                          :name (format "finally-%S" (loom-promise-id source-promise))
                          :parent-promise source-promise))
         (source-id (loom-promise-id source-promise))
         (target-id (loom-promise-id target-promise)))
    
    ;; `handle-callback` is a local helper function that orchestrates the
    ;; complex chaining required by `finally`.
    (cl-flet ((handle-callback (original-outcome resolve-with-original-p)
                (condition-case cb-err
                    (let* (;; 1. Execute the user's side-effect callback.
                           (callback-result (funcall callback-fn))
                           ;; 2. The callback itself might return a promise, so we
                           ;;    normalize its result into one.
                           (callback-promise (if (loom-promise-p callback-result)
                                                 callback-result
                                               (loom:resolved! callback-result)))
                           (callback-id (loom-promise-id callback-promise)))
                      ;; 3. We now wait for the callback's promise to settle
                      ;;    before we settle the main `target-promise`.
                      (loom--attach-callbacks 
                       callback-promise
                       ;; If the side-effect callback succeeds...
                       (loom--make-internal-callback
                        :type :resolved
                        :source-promise-id callback-id
                        :promise-id target-id
                        :handler-fn (lambda (_tp _v)
                                      ;; ...settle our target promise with the
                                      ;; original promise's outcome.
                                      (if resolve-with-original-p
                                          (loom:resolve target-promise original-outcome)
                                        (loom:reject target-promise original-outcome))))
                       ;; If the side-effect callback fails...
                       (loom--make-internal-callback
                        :type :rejected
                        :source-promise-id callback-id
                        :promise-id target-id
                        :handler-fn (lambda (_tp cb-reason)
                                      ;; ...reject our target promise with the
                                      ;; new error from the callback.
                                      (loom:reject target-promise cb-reason)))))
                  ;; If the side-effect function itself throws a synchronous error,
                  ;; that error immediately rejects the target promise.
                  (error (loom:reject target-promise (loom:make-error :cause cb-err))))))
      
      ;; Attach the primary handlers to the original source promise.
      (loom--attach-callbacks
       source-promise
       ;; ON-RESOLVED: when the source promise resolves with `value`.
       (loom--make-internal-callback
        :type :resolved
        ;; MODIFIED: Added missing promise IDs for correct execution context.
        :source-promise-id source-id
        :promise-id target-id
        :handler-fn (lambda (_tp value) 
                      (handle-callback value t)))
       ;; ON-REJECTED: when the source promise rejects with `reason`.
       (loom--make-internal-callback
        :type :rejected
        ;; MODIFIED: Added missing promise IDs for correct execution context.
        :source-promise-id source-id
        :promise-id target-id
        :handler-fn (lambda (_tp reason) 
                      (handle-callback reason nil)))))
    
    target-promise))
    
;;;###autoload
(defun loom:tap (promise callback-fn)
  "Attach a callback for side effects, without altering the promise chain.

This is useful for inspecting a promise's value or error at a
certain point in a chain without modifying it (e.g., for logging
or debugging). The original outcome is always passed through.

Arguments:
- `PROMISE` (any): The promise or value to inspect.
- `CALLBACK-FN` (function): A function `(lambda (value error) ...)`
  to execute. It receives either a `value` or an `error`, never both.

Returns:
- (loom-promise): A new promise that settles with the exact same
  outcome as the original `PROMISE`.

Signals:
- Does not signal errors. Any error raised within `CALLBACK-FN` is
  ignored to ensure the main promise chain is not affected.

Side Effects:
- Schedules `CALLBACK-FN` for execution when `PROMISE` settles."
  (let* ((source-promise (if (loom-promise-p promise)
                             promise
                           (loom:resolved! promise)))
         (new-promise (loom:promise
                       :name (format "tap-%S" (loom-promise-id source-promise))
                       :parent-promise source-promise)))
    (loom--attach-callbacks
     source-promise
     ;; on-resolved: run callback, then pass original value through.
     (loom--make-internal-callback
      :type :resolved
      :handler-fn (lambda (_ value)
                    (condition-case nil (funcall callback-fn value nil) (error nil))
                    (loom:resolve new-promise value)))
     ;; on-rejected: run callback, then re-throw original error.
     (loom--make-internal-callback
      :type :rejected
      :handler-fn (lambda (_ error)
                    (condition-case nil (funcall callback-fn nil error) (error nil))
                    (loom:reject new-promise error))))
    new-promise))

(provide 'loom-primitives)
;;; loom-primitives.el ends here