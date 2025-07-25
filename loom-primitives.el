;;; loom-primitives.el --- Core Promise Chaining Primitives -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file defines the fundamental functions for chaining and handling
;; promise outcomes: `loom:then`, `loom:catch`, `loom:finally`, and
;; `loom:tap`. These build upon the core promise object and internal
;; callback mechanisms defined in `loom-promise.el`.
;;
;; They provide the primary, user-facing interface for building
;; asynchronous workflows, adhering strictly to the [Promises/A+
;; specification](https://promisesaplus.com/) for handler attachment
;; and resolution.
;;
;; ### Promises/A+ Specification Relevance:
;;
;; - **`loom:then`**: Directly implements the core `then` method. It
;;   ensures that handlers are called asynchronously, that they are called
;;   at most once, and that the new promise it returns is settled
;;   correctly based on the handler's return value or any errors thrown.
;;
;; - **`loom:catch`**: A convenient wrapper around `loom:then` that provides
;;   only an `onRejected` handler while allowing resolved values to pass
;;   through. It also supports advanced, type-based error handling.
;;
;; - **`loom:finally`**: Implements "finally" semantics similar to
;;   `Promise.prototype.finally` from ES2018. It ensures a callback runs
;;   regardless of whether the promise was resolved or rejected, and
;;   propagates the original outcome unless the `finally` callback itself
;;   fails.
;;
;; - **`loom:tap`**: A utility function for side effects, allowing inspection
;;   of a promise's value or error without affecting its resolution path.
;;   Errors within the `tap` callback are intentionally suppressed.

;;; Code:

(require 'cl-lib)

(require 'loom-error)
(require 'loom-callback)
(require 'loom-promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--find-and-run-catch-handler (handlers err)
  "Find and execute the appropriate error handler for a given error.
This is a helper for `loom:catch` that implements its flexible handler
dispatch logic. It supports a single default handler, or a plist of
handlers keyed by error type.

Arguments:
- `HANDLERS` (list): The handler specifications from `loom:catch`.
  This can be a single function `(lambda (err))` or a plist like
  `(:type :some-error-type (lambda (err)) ...)`.
- `ERR` (loom-error): The error object to be handled.

Returns:
- (cons): A cons cell `(FOUND . RESULT)` where `FOUND` is `t` if a
  handler was found and executed, and `RESULT` is its return value.
  Returns `(nil . nil)` if no suitable handler was found."
  (let ((is-simple (or (null handlers) (not (keywordp (car handlers))))))
    (if is-simple
        ;; Case 1: A single, simple handler function.
        (if-let (handler (car handlers))
            (cons t (funcall handler err))
          (cons nil nil))
      ;; Case 2: Typed handlers in a plist format.
      (let* ((err-type (and (loom-error-p err) (loom-error-type err)))
             (default (when (functionp (car (last handlers)))
                        (car (last handlers)))))
        (or (cl-loop for (key type-spec handler) on handlers by #'cdddr
                     when (and (eq key :type)
                               (or (eq t type-spec)
                                   (eq err-type type-spec)
                                   (and (listp type-spec)
                                        (memq err-type type-spec))))
                     return (cons t (funcall handler err)))
            (if default (cons t (funcall default err)) (cons nil nil)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Attaching Callbacks

;;;###autoload
(defun loom:then (promise on-resolved &optional on-rejected)
  "The primary function for promise composition (Promises/A+ `then`).
This function attaches `ON-RESOLVED` and `ON-REJECTED` handlers to a
`PROMISE` and returns a new promise. The new promise is settled based on
the outcome of the executed handler.

Arguments:
- `PROMISE` (any): The promise or value to attach handlers to. If not
  a `loom-promise`, it's treated as an already resolved promise.
- `ON-RESOLVED` (function): A function `(lambda (value))` called when
  `PROMISE` resolves successfully.
- `ON-REJECTED` (function, optional): A function `(lambda (error))`
  called when `PROMISE` is rejected.

Returns:
- (loom-promise): A new promise that represents the outcome of the handler.
  This allows for chaining operations, e.g., `(loom:then (loom:then p f1) f2)`.

Side Effects:
- Schedules `ON-RESOLVED` or `ON-REJECTED` to run on the microtask queue
  once `PROMISE` has settled.

Signals:
- Rejects the returned promise with a `:callback-error` if a handler
  function itself raises a synchronous error."
  (let* ((source-promise (if (loom-promise-p promise) promise
                           (loom:resolved! promise)))
         ;; Spec 2.2.7: `then` must return a new promise.
         (new-promise (loom:promise
                       :name (format "then-%s"
                                     (loom-promise-id source-promise))
                       :parent-promise source-promise)))
    (loom-attach-callbacks
     source-promise
     ;; --- on-resolved handler wrapper ---
     (loom:callback
      (lambda (target-promise value)
        (condition-case err
            ;; Spec 2.2.7.1: If `on-resolved` returns a value `x`,
            ;; resolve the new promise with `x`. `loom:promise-resolve` handles
            ;; the case where `x` is itself a promise.
            (loom:promise-resolve target-promise (funcall on-resolved value))
          ;; Spec 2.2.7.2: If `on-resolved` throws an exception `e`,
          ;; the new promise must be rejected with `e` as the reason.
          (error (loom:promise-reject target-promise
                              (loom:error! :type :callback-error
                                           :cause err)))))
      :type :resolved)

     ;; --- on-rejected handler wrapper ---
     (loom:callback
      (if on-rejected
          (lambda (target-promise err-reason)
            (condition-case handler-err
                ;; Spec 2.2.7.1: If `on-rejected` returns a value,
                ;; the new promise is resolved with that value.
                (loom:promise-resolve target-promise (funcall on-rejected err-reason))
              ;; Spec 2.2.7.2: If `on-rejected` throws an exception,
              ;; the new promise is rejected with that exception.
              (error (loom:promise-reject target-promise
                                  (loom:error! :type :callback-error
                                               :cause handler-err)))))
        ;; Spec 2.2.7.4: If `on-rejected` is not a function, the new
        ;; promise must be rejected with the same reason.
        (lambda (target-promise err-reason)
          (loom:promise-reject target-promise err-reason)))
      :type :rejected))
    new-promise))

;;;###autoload
(defun loom:catch (promise &rest handlers)
  "Attach an error handler to a promise, with optional type filtering.
This is a convenient syntax for providing an `on-rejected` handler to a
promise chain. It allows successful values to pass through untouched while
catching and handling rejections.

Handlers can be provided in two forms:
1.  A single function `(lambda (error))` that handles all errors.
2.  A plist of `:type` specifications and handler functions, e.g.,
    `(:type :foo #'handle-foo)`. An optional final function can act
    as a default case if no type-specific handler matches.

Arguments:
- `PROMISE` (any): The promise or value to attach handlers to.
- `&rest HANDLERS` (function or plist): The error handling logic.

Returns:
- (loom-promise): A new promise that resolves with the original value on
  success, or with the result of a matched error handler on failure. If
  no handler matches the error, it is re-rejected with the original error.

Side Effects:
- Schedules handler execution on the microtask queue if `PROMISE` rejects."
  (loom:then
   promise
   ;; `on-resolved` is nil, so resolved values pass through to the new promise.
   nil
   ;; `on-rejected` is our custom dispatcher.
   (lambda (err)
     (let* ((handler-result (loom--find-and-run-catch-handler handlers err))
            (handler-found (car handler-result))
            (result (cdr handler-result)))
       (if handler-found
           ;; A handler was found and run. The `catch` promise resolves
           ;; with the handler's return value.
           result
         ;; No handler matched the error. Re-throw the original error to
         ;; propagate it down the promise chain.
         (signal (loom-error-type err) (list err)))))))

;;;###autoload
(defun loom:finally (promise callback-fn)
  "Attach a callback to run when `PROMISE` settles (resolves or rejects).
This is useful for cleanup actions (e.g., closing a file handle, hiding a
spinner) that must occur regardless of the promise's outcome.

Arguments:
- `PROMISE` (any): The promise or value to attach the cleanup action to.
- `CALLBACK-FN` (function): A nullary function `(lambda ())` to execute
  when `PROMISE` settles.

Returns:
- (loom-promise): A new promise that settles with the original outcome of
  `PROMISE`, but only *after* `CALLBACK-FN` has completed.

Propagation Rules:
- If `PROMISE` resolves and `CALLBACK-FN` succeeds, the new promise
  resolves with the original value.
- If `PROMISE` rejects and `CALLBACK-FN` succeeds, the new promise
  rejects with the original error.
- If `CALLBACK-FN` fails (throws an error or returns a rejected promise),
  the new promise rejects with that new error, overriding the original
  outcome of `PROMISE`."
  (let ((source-promise (if (loom-promise-p promise) promise
                          (loom:resolved! promise))))
    (loom:then
     source-promise
     ;; `on-resolved` handler for the `finally` logic.
     (lambda (value)
       ;; 1. Execute the callback.
       (let ((cb-promise (loom:resolved! (funcall callback-fn))))
         ;; 2. Wait for the callback to finish (if it was async).
         (loom:then cb-promise
                    ;; 3a. If callback succeeded, pass through original value.
                    (lambda (_) value)
                    ;; 3b. If callback failed, propagate its error.
                    (lambda (err) (signal (loom-error-type err) (list err))))))
     ;; `on-rejected` handler for the `finally` logic.
     (lambda (err)
       ;; 1. Execute the callback.
       (let ((cb-promise (loom:resolved! (funcall callback-fn))))
         ;; 2. Wait for the callback to finish.
         (loom:then cb-promise
                    ;; 3a. If callback succeeded, re-throw original error.
                    (lambda (_) (signal (loom-error-type err) (list err)))
                    ;; 3b. If callback failed, propagate the new error.
                    (lambda (cb-err) (signal (loom-error-type cb-err)
                                             (list cb-err)))))))))

;;;###autoload
(defun loom:tap (promise callback-fn)
  "Attach a callback for side effects, without altering the promise chain.
This is useful for inspecting a promise's value or error (e.g., for
logging or debugging) without modifying it. The original outcome is always
passed through to the next link in the chain.

Arguments:
- `PROMISE` (any): The promise or value to inspect.
- `CALLBACK-FN` (function): A function `(lambda (value error))` to execute.
  It is called with `(VALUE nil)` on resolution, or `(nil ERROR)` on rejection.

Returns:
- (loom-promise): A new promise that will settle with the exact same
  outcome as the original `PROMISE`.

Side Effects:
- Schedules `CALLBACK-FN` for execution when `PROMISE` settles. Any
  error raised within `CALLBACK-FN` is caught and ignored, ensuring that
  the main promise chain is not disrupted."
  (loom:then
   promise
   ;; `on-resolved` handler: execute callback, then pass original value.
   (lambda (value)
     (ignore-errors (funcall callback-fn value nil))
     value)
   ;; `on-rejected` handler: execute callback, then re-throw original error.
   (lambda (err)
     (ignore-errors (funcall callback-fn nil err))
     (signal (loom-error-type err) (list err)))))

(provide 'loom-primitives)
;;; loom-primitives.el ends here