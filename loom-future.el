;;; loom-future.el --- Lazy Asynchronous Computations -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file provides primitives for working with "futures". A future
;; represents a deferred computation that is evaluated lazily—only when its
;; result is actually requested. This is useful for defining expensive or
;; asynchronous operations without paying the execution cost upfront.
;;
;; Futures are built on top of promises. When a future is "forced" (i.e., its
;; value is requested for the first time via `loom:force`), it executes its
;; deferred computation and stores the result in an internal promise for all
;; subsequent requests.
;;
;; Key Features:
;; - Lazy Evaluation: A future's computation is only run once, the first
;;   time its result is requested via `loom:force`.
;; - Thread-Safety: Forcing a future is an atomic, thread-safe operation,
;;   making it safe to share futures across different threads.
;; - Seamless Integration: Futures are "awaitable" and integrate transparently
;;   with the entire `loom` promise ecosystem (`loom:await`, `loom:then`).

;;; Code:

(require 'cl-lib)

(require 'loom-log)
(require 'loom-errors)
(require 'loom-lock)
(require 'loom-promise)
(require 'loom-primitives)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-future-error
  "A generic error related to a `loom-future`."
  'loom-error)

(define-error 'loom-invalid-future-error
  "An operation was attempted on an invalid future object."
  'loom-future-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-future (:constructor %%make-future))
  "A lazy future representing a deferred computation.

Fields:
- `id` (symbol): A unique identifier (`gensym`) for logging and debugging. NEW
- `promise` (loom-promise or nil): The cached promise, which is created
  and stored on the first call to `loom:force`. Initially `nil`.
- `thunk` (function): A zero-argument closure that, when called, performs
  the computation and returns a value or another promise.
- `evaluated-p` (boolean): A flag to ensure the `thunk` is only run once.
- `mode` (symbol): The concurrency mode (`:deferred` or `:thread`) for the
  promise that will be created by this future.
- `lock` (loom-lock): A mutex that ensures the process of forcing the
  future is atomic and thread-safe."
  (id nil :type symbol) 
  (promise nil :type (or null loom-promise))
  (thunk (lambda () (error "Empty future thunk")) :type function)
  (evaluated-p nil :type boolean)
  (mode :deferred :type (member :deferred :thread))
  (lock nil :type loom-lock))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-future (future function-name)
  "Signal an error if `FUTURE` is not a `loom-future` object.

Arguments:
- `FUTURE` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting."
  (unless (loom-future-p future)
    (loom-log-error nil "%s: Invalid future object %S" function-name future)
    (signal 'loom-invalid-future-error
            (list (format "%s: Invalid future object" function-name) future))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Creation & Forcing

;;;###autoload
(cl-defmacro loom:future (thunk-form &key (mode :deferred) id)
  "Create a `loom-future` from a `THUNK-FORM`.

The returned future represents a computation that is performed lazily
when `loom:force` is called. The `THUNK-FORM` is captured as a
lexical closure, automatically preserving access to variables in its
surrounding scope.

Arguments:
- `THUNK-FORM` (form): A Lisp form that evaluates to a zero-argument
  function (a thunk), typically a lambda. Its return value can be a
  normal value or another awaitable object (like a promise).
- `:MODE` (symbol, optional): The concurrency mode (`:deferred` or `:thread`)
  for the promise created when this future is forced. Defaults to `:deferred`.
- `:ID` (symbol, optional): A unique identifier for the future. If `nil`,
  a `gensym` is used.

Returns:
- (loom-future): A new `loom-future` object.

Signals:
- No direct signals from the macro itself. Errors in `THUNK-FORM`
  will result in the future's internal promise rejecting when forced.

Side Effects:
- Creates a new `loom-future` struct.
- Initializes an internal `loom-lock`."
  (declare (indent 1) (debug t))
  `(let ((future-id (or ,id (gensym "future-")))) 
     (loom-log-trace future-id "Creating new future with mode: %S" ,mode)
     (%%make-future
      :id future-id 
      :lock (loom:lock (format "future-lock-%S" future-id) :mode ,mode)
      :mode ,mode
      :thunk ,thunk-form)))

;;;###autoload
(defun loom:force (future)
  "Force `FUTURE`'s thunk to run if not already evaluated.
This function is idempotent and thread-safe. The first time it is called on
a given future, it executes the future's deferred computation. All
subsequent calls on the same future will return the same cached promise
without re-running the computation.

Arguments:
- `FUTURE` (loom-future): The future object to force.

Returns:
- (loom-promise): The promise associated with the future's result.

Signals:
- `loom-invalid-future-error`: If `FUTURE` is not a valid `loom-future` object.
- Any error signaled by the future's `thunk` will cause the returned
  promise to reject.

Side Effects:
- Modifies `FUTURE`'s `evaluated-p` field to `t` (on first call).
- Modifies `FUTURE`'s `promise` field to store the result promise (on first call).
- Executes the `thunk` (only on the first call).
- Creates an internal `loom-promise` (on first call).
- Acquires and releases `loom-lock` instances for thread-safe access."
  (loom--validate-future future 'loom:force)
  (let ((future-id (loom-future-id future))) 
    (loom-log-debug future-id "Attempting to force future %S" future)

    ;; Fast path: If already evaluated, just return the cached promise.
    (cl-block loom:force
      (when (loom-future-evaluated-p future)
        (loom-log-debug future-id "Future already evaluated, returning cached promise")
        (cl-return-from loom:force (loom-future-promise future))))

    (let (promise-to-return thunk-to-run)
      ;; Use a double-checked lock to ensure the thunk runs only once, even
      ;; if multiple threads call `force` at the same time.
      (loom:with-mutex! (loom-future-lock future)
        (if (loom-future-evaluated-p future)
            ;; Another thread evaluated it while we waited for the lock.
            (progn
              (loom-log-debug future-id "Future evaluated by another thread during lock wait")
              (setq promise-to-return (loom-future-promise future)))
          ;; We are the first to force this future.
          (loom-log-info future-id "First time forcing future, acquiring lock and evaluating")
          (setf (loom-future-evaluated-p future) t)
          (setq thunk-to-run (loom-future-thunk future))
          (setq promise-to-return
                (loom:promise :mode (loom-future-mode future)
                              :name (format "future-promise-%S" future-id))) 
          (setf (loom-future-promise future) promise-to-return)))

      ;; Run the expensive thunk *outside* the lock to avoid blocking other
      ;; threads and prevent potential deadlocks.
      (when thunk-to-run
        (loom-log-debug future-id "Executing future's thunk")
        (condition-case err
            (loom:resolve promise-to-return (funcall thunk-to-run))
          (error
           (loom-log-error future-id "Future thunk failed: %S" err)
           (loom:reject
            promise-to-return
            (loom:make-error :type :executor-error
                             :message (format "Future thunk failed: %S" err)
                             :cause err)))))
      (loom-log-debug future-id "Future forced, returning promise")
      promise-to-return)))

;;;###autoload
(defun loom:future-get (future &optional timeout)
  "Force `FUTURE` and get its result, blocking until available.
This function is synchronous and is a convenient wrapper around
`(loom:await (loom:force FUTURE))`. Use with caution in
performance-sensitive or UI-related code.

Arguments:
- `FUTURE` (loom-future): The future whose result is needed.
- `TIMEOUT` (number, optional): Max seconds to wait before signaling a
  `loom-timeout-error`. Uses `loom-await-default-timeout` if nil.

Returns:
- (any): The resolved value of the future.

Signals:
- `loom-invalid-future-error`: If `FUTURE` is not a valid `loom-future` object.
- `loom-await-error`: If the future's promise is rejected.
- `loom-timeout-error`: If the timeout is exceeded.

Side Effects:
- Calls `loom:force` on `FUTURE`, which may execute the future's thunk
  and modify its internal state.
- Calls `loom:await`, which blocks the current thread until the promise settles."
  (loom--validate-future future 'loom:future-get)
  (let ((future-id (loom-future-id future))) 
    (loom-log-debug future-id "Calling future-get for future %S (timeout: %S)"
                    future timeout)
    (unwind-protect
        (loom:await (loom:force future) timeout)
      (loom-log-debug future-id "Future-get completed for future %S" future))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Convenience Constructors

;;;###autoload
(cl-defmacro loom:future-resolved! (value-form &key (mode :deferred) id)
  "Return a new `loom-future` that is already resolved with `VALUE-FORM`.
This future is created in an 'already forced' state. Forcing it will not
trigger any new computation.

Arguments:
- `VALUE-FORM` (form): A Lisp form that evaluates to the value for the
  pre-resolved future.
- `:MODE` (symbol, optional): Concurrency mode for the future's promise.
- `:ID` (symbol, optional): A unique identifier for the future. If `nil`,
  a `gensym` is used.

Returns:
- (loom-future): A new, already-evaluated future.

Signals:
- No direct signals from the macro itself. Errors in `VALUE-FORM` will
  cause the future's internal promise to reject when the form is evaluated.

Side Effects:
- Creates a new `loom-future` struct.
- Creates an internal `loom-promise` that is immediately resolved.
- Initializes an internal `loom-lock`."
  (declare (indent 1) (debug t))
  `(let* ((val ,value-form)
          (promise (loom:resolved! val :mode ,mode))
          (future-id (or ,id (gensym "resolved-future-"))))
     (loom-log-trace future-id "Creating pre-resolved future with value: %S" val)
     (%%make-future :id future-id
                    :promise promise :evaluated-p t :mode ,mode
                    :lock (loom:lock (format "future-resolved-lock-%S" future-id)
                                     :mode ,mode))))

;;;###autoload
(cl-defmacro loom:future-rejected! (error-form &key (mode :deferred) id)
  "Return a new `loom-future` that is already rejected with `ERROR-FORM`.
This future is created in an 'already forced' state.

Arguments:
- `ERROR-FORM` (form): A Lisp form that evaluates to the error for the
  pre-rejected future.
- `:MODE` (symbol, optional): Concurrency mode for the future's promise.
- `:ID` (symbol, optional): A unique identifier for the future. If `nil`,
  a `gensym` is used.

Returns:
- (loom-future): A new, already-evaluated future.

Signals:
- No direct signals from the macro itself. Errors in `ERROR-FORM` will
  cause the future's internal promise to reject when the form is evaluated.

Side Effects:
- Creates a new `loom-future` struct.
- Creates an internal `loom-promise` that is immediately rejected.
- Initializes an internal `loom-lock`."
  (declare (indent 1) (debug t))
  `(let* ((err ,error-form)
          (promise (loom:rejected! err :mode ,mode))
          (future-id (or ,id (gensym "rejected-future-")))) 
     (loom-log-trace future-id "Creating pre-rejected future with error: %S" err)
     (%%make-future :id future-id ; Assign the new ID
                    :promise promise :evaluated-p t :mode ,mode
                    :lock (loom:lock (format "future-rejected-lock-%S" future-id)
                                     :mode ,mode))))

;;;###autoload
(cl-defun loom:future-delay (seconds &optional value &key (mode :deferred) id)
  "Create a `loom-future` that resolves with `VALUE` after `SECONDS`.
The timer for the delay only starts when the future is first forced via
`loom:force`.

Arguments:
- `SECONDS` (number): The non-negative delay duration.
- `VALUE` (any, optional): The value to resolve with. Defaults to `t`.
- `:MODE` (symbol, optional): The concurrency mode for the future's promise.
- `:ID` (symbol, optional): A unique identifier for the future. If `nil`,
  a `gensym` is used.

Returns:
- (loom-future): A new, lazy future.

Signals:
- `error`: If `SECONDS` is not a non-negative number.

Side Effects:
- Creates a new `loom-future` struct.
- When the future is forced, it will call `loom:delay`, which in turn
  schedules a timer and creates a promise."
  (unless (and (numberp seconds) (>= seconds 0))
    (loom-log-error nil "Invalid SECONDS for future-delay: %S" seconds)
    (error "SECONDS must be a non-negative number: %S" seconds))
  (loom-log-trace nil "Creating delay future for %S seconds with value: %S"
                  seconds value)
  (loom:future (lambda () (loom:delay seconds value)) :mode mode :id id))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Chaining & Composition

;;;###autoload
(defmacro loom:future-then (future transform-fn)
  "Apply `TRANSFORM-FN` to the result of a future, creating a new future.
The new future is also lazy. When it is forced, it will first force the
original `FUTURE`. Once the original future resolves, `TRANSFORM-FN` is
applied to its result.

Arguments:
- `FUTURE` (loom-future): The parent future.
- `TRANSFORM-FN` (form): A lambda `(lambda (value) ...)` or function symbol.

Returns:
- (loom-future): A new future representing the chained computation.

Signals:
- `loom-invalid-future-error`: If `FUTURE` does not evaluate to a valid
  `loom-future` object.
- Any error signaled by `TRANSFORM-FN` or the forced parent future will
  cause the new future's internal promise to reject.

Side Effects:
- Creates a new `loom-future` struct.
- When the new future is forced:
    - Calls `loom:force` on `FUTURE`.
    - Calls `loom:then` to attach `TRANSFORM-FN`."
  (declare (indent 1) (debug t))
  `(let ((parent-future ,future))
     (loom--validate-future parent-future 'loom:future-then)
     (let ((id (gensym "future-then-")))
       (loom-log-trace id "Creating future-then from parent %S" parent-future)
       (loom:future
        (lambda ()
          (loom-log-debug id "Forcing parent future for future-then chain")
          (loom:then (loom:force parent-future) ,transform-fn))
        :id id 
        :mode (loom-future-mode parent-future)))))

;;;###autoload
(defmacro loom:future-catch (future error-handler-fn)
  "Attach an error handler to a future, creating a new recoverable future.
The new future is lazy. When forced, it forces the original future and, if
it rejects, applies the `ERROR-HANDLER-FN`.

Arguments:
- `FUTURE` (loom-future): The parent future.
- `ERROR-HANDLER-FN` (form): A lambda `(lambda (error) ...)` or function.

Returns:
- (loom-future): A new future that can handle the original's failure.

Signals:
- `loom-invalid-future-error`: If `FUTURE` does not evaluate to a valid
  `loom-future` object.
- Any error signaled by `ERROR-HANDLER-FN` or the forced parent future will
  cause the new future's internal promise to reject.

Side Effects:
- Creates a new `loom-future` struct.
- When the new future is forced:
    - Calls `loom:force` on `FUTURE`.
    - Calls `loom:catch` to attach `ERROR-HANDLER-FN`."
  (declare (indent 1) (debug t))
  `(let ((parent-future ,future))
     (loom--validate-future parent-future 'loom:future-catch)
     (let ((id (gensym "future-catch-")))
       (loom-log-trace id "Creating future-catch from parent %S" parent-future)
       (loom:future
        (lambda ()
          (loom-log-debug id "Forcing parent future for future-catch chain")
          (loom:catch (loom:force parent-future)
                      ,error-handler-fn))
        :id id 
        :mode (loom-future-mode parent-future)))))

;;;###autoload
(defun loom:future-all (futures)
  "Create a future that, when forced, runs a list of `FUTURES` in parallel.

Arguments:
- `FUTURES` (list): A list of `loom-future` objects.

Returns:
- (loom-future): A new future that resolves with a list of all results.

Signals:
- `error`: If `FUTURES` is not a list.
- If any of the forced futures reject, the returned future's internal
  promise will reject (following `loom:all` semantics).

Side Effects:
- Creates a new `loom-future` struct.
- When the new future is forced:
    - Calls `loom:force` on each future in `FUTURES`.
    - Calls `loom:all` to combine the results, which creates new promises
      and attaches handlers."
  (unless (listp futures)
    (loom-log-error nil "`FUTURES` must be a list: %S" futures)
    (error "`FUTURES` must be a list: %S" futures))
  (let ((id (gensym "future-all-"))) ; Generate ID for future-all
    (loom-log-trace id "Creating future-all for %d futures" (length futures))
    (loom:future
     (lambda ()
       (loom-log-debug id "Forcing all child futures for future-all")
       (loom:all (mapcar #'loom:force futures)))
     :id id 
     :mode (cl-some (lambda (f) (when (loom-future-p f) (loom-future-mode f))) futures)))) ; Infer mode from children

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Introspection

;;;###autoload
(defun loom:future-status (future)
  "Return a snapshot of the `FUTURE`'s current status.

Arguments:
- `FUTURE` (loom-future): The future to inspect.

Returns:
- (plist): A property list with metrics: `:evaluated-p`, `:mode`,
  `:promise-status`, `:promise-value`, and `:promise-error`.

Signals:
- `loom-invalid-future-error` if `FUTURE` is not a valid future."
  (loom--validate-future future 'loom:future-status)
  (let* ((promise (loom-future-promise future))
         (status `(:evaluated-p ,(loom-future-evaluated-p future)
                   :mode ,(loom-future-mode future)
                   :promise-status ,(when promise (loom:status promise))
                   :promise-value ,(when promise (loom:value promise))
                   :promise-error ,(when promise (loom:error-value promise)))))
    (loom-log-trace (loom-future-id future) "Getting status for future: %S" status)
    status))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Integration

(defun loom--future-normalize-awaitable (awaitable)
  "Normalize an awaitable into a promise if it's a `loom-future`.
This function is added to `loom-normalize-awaitable-hook` to allow core
functions like `loom:await` to transparently accept futures.

Arguments:
- `AWAITABLE` (any): The object to normalize.

Returns:
- (loom-promise or nil): The forced promise if `AWAITABLE` is a `loom-future`,
  otherwise `nil`.

Signals:
- Any signals from `loom:force` if `AWAITABLE` is a `loom-future`.

Side Effects:
- Calls `loom:force` if `AWAITABLE` is a `loom-future`, which may execute
  the future's thunk and modify its internal state."
  (if (loom-future-p awaitable)
      (let ((future-id (loom-future-id awaitable))) 
        (loom-log-debug future-id "Normalizing future %S into a promise" awaitable)
        (loom:force awaitable))
    nil))

;; Plug the future into the core promise system, making them interchangeable.
(add-hook 'loom-normalize-awaitable-hook #'loom--future-normalize-awaitable)

(provide 'loom-future)
;;; loom-future.el ends here
