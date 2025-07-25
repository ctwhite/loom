;;; loom-future.el --- Lazy Asynchronous Computations -*- lexical-binding: t; -*-

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
;; ## Key Features:
;;
;; - **Lazy Evaluation:** A future's computation is only run once, the
;;   first time its result is needed.
;; - **Thread-Safety:** Forcing a future is an atomic, thread-safe operation,
;;   preventing race conditions where multiple threads might try to evaluate
;;   the same future simultaneously.
;; - **Seamless Integration:** Futures are "awaitable" and integrate
;;   transparently with the entire `loom` promise ecosystem (`loom:await`,
;;   `loom:then`, etc.).
;; - **Memoization:** Future results are cached (memoized) in an internal
;;   promise, so subsequent requests for the result are fast and do not
-;;   trigger re-computation.
;; - **Composability:** Futures can be chained, combined, and transformed
;;   using a suite of combinator functions (`loom:future-then`,
;;   `loom:future-all`, etc.).

;;; Code:

(require 'cl-lib)

(require 'loom-log)
(require 'loom-error)
(require 'loom-lock)
(require 'loom-promise)
(require 'loom-primitives)
(require 'loom-combinators)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom:deferred "loom-scheduler")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-future-error
  "A generic error related to a `loom-future`." 'loom-error)
(define-error 'loom-invalid-future-error
  "An operation was attempted on an invalid future object."
  'loom-future-error)
(define-error 'loom-future-cancelled-error
  "A future was cancelled before its computation could complete."
  'loom-cancel-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-future (:constructor %%make-future))
  "A lazy future representing a deferred computation.
This struct encapsulates a 'thunk' (a zero-argument function) that
will be executed at most once, the first time its result is
requested via `loom:force`. The result is stored in an internal
promise, making the future compatible with all other promise-based
operations in the Loom library.

Fields:
- `id` (symbol): A unique identifier for logging and debugging.
- `promise` (loom-promise or nil): The cached promise that holds the
  result of the computation. It is created on the first call to
  `loom:force`.
- `thunk` (function): A zero-argument closure that performs the
  computation and returns a value or signals an error.
- `evaluated-p` (boolean): A flag to ensure the `thunk` is only run once.
- `lock` (loom-lock): A mutex ensuring that the `force` operation is
  atomic and thread-safe, preventing multiple threads from
  evaluating the thunk simultaneously.
- `cancelled-p` (boolean): A flag indicating whether this future has
  been cancelled before evaluation.
- `metadata` (plist): A property list for storing additional
  user-defined metadata for debugging and introspection."
  (id nil :type symbol)
  (promise nil :type (or null loom-promise))
  (thunk (lambda () (error "Empty future thunk")) :type function)
  (evaluated-p nil :type boolean)
  (lock nil :type loom-lock)
  (cancelled-p nil :type boolean)
  (metadata nil :type list))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-future (future function-name)
  "Signal an error if `FUTURE` is not a `loom-future` object.
This is a standard validation helper used at the entry point of all
public API functions to ensure they are operating on the correct
data type, providing clearer errors to the user.

Arguments:
- `FUTURE` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting.

Returns: `nil` if validation passes.

Signals:
- `loom-invalid-future-error` if validation fails."
  (unless (loom-future-p future)
    (signal 'loom-invalid-future-error
            (list (format "%s: Invalid future object" function-name) future))))

(defun loom--validate-futures-list (futures function-name)
  "Validate that `FUTURES` is a list of valid future objects.

Arguments:
- `FUTURES` (list): The list to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting.

Returns: `nil` if validation passes.

Signals:
- `error`: If `FUTURES` is not a list.
- `loom-invalid-future-error`: If an element in the list is not a future."
  (unless (listp futures)
    (error "%s: FUTURES must be a list: %S" function-name futures))
  (dolist (future futures)
    (loom--validate-future future function-name)))

(defun loom--future-check-cancelled (future)
  "Check if `FUTURE` is cancelled and signal an error if so.
This is called at the beginning of any operation that would force
the future's evaluation to ensure that cancelled futures cannot be
accidentally executed.

Arguments:
- `FUTURE` (loom-future): The future to check.

Returns: `nil`.

Signals:
- `loom-future-cancelled-error` if the future is cancelled."
  (when (loom-future-cancelled-p future)
    (signal 'loom-future-cancelled-error
            (list "Future has been cancelled" (loom-future-id future)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Creation & Forcing

;;;###autoload
(cl-defun loom:future (thunk &key metadata)
  "Create a `loom-future` from a `THUNK` function.
The returned future represents a computation that is performed lazily
when `loom:force` is called. For a more ergonomic version that
implicitly wraps a body of code in a lambda, see `loom:future!`.

Arguments:
- `THUNK` (function): A zero-argument function (a thunk) that performs
  the computation when called.
- `:METADATA` (plist): A property list for storing additional
  user-defined metadata for debugging.

Returns:
- (loom-future): A new `loom-future` object."
  (let ((id (gensym "future-")))
    (%%make-future
     :id id
     :lock (loom:make-lock (format "future-lock-%S" id))
     :thunk thunk
     :metadata metadata)))

;;;###autoload
(cl-defmacro loom:future! ((&key metadata) &rest body)
  "Create a `loom-future` that will execute `BODY` when forced.
This is an ergonomic wrapper around `loom:future` that implicitly
wraps the `BODY` forms in a `lambda`.

Arguments:
- `:METADATA` (plist): Additional metadata for debugging.
- `BODY` (forms): The Lisp forms to execute when the future is forced.

Returns:
- (loom-future): A new `loom-future` object."
  (declare (indent 1) (debug t))
  `(loom:future (lambda () ,@body) :metadata ,metadata))

(defun loom:force (future)
  "Force `FUTURE`'s thunk to run if not already evaluated.
This function is idempotent and thread-safe. The first time it is called,
it executes the future's deferred computation. Subsequent calls return the
same cached promise without re-running the computation. This is achieved
using a double-checked locking pattern for efficiency.

Arguments:
- `FUTURE` (loom-future): The future object to force.

Returns:
- (loom-promise): The `loom-promise` associated with the future's result.

Side Effects:
- On the first call for a given future, this function will create a new
  `loom-promise`, store it in the future's `promise` slot, and
  schedule the future's `thunk` for execution.

Signals:
- `loom-invalid-future-error`: If `FUTURE` is not a valid future.
- `loom-future-cancelled-error`: If the future has been cancelled."
  (loom--validate-future future 'loom:force)
  (loom--future-check-cancelled future)

  ;; Fast path: If the promise already exists, it means the future has been
  ;; forced before. We can return the cached promise immediately without
  ;; acquiring a lock, which is a significant performance optimization.
  (when-let ((promise (loom-future-promise future)))
    (cl-return-from loom:force promise))

  ;; Slow path: The future may not have been evaluated yet. We must acquire
  ;; a lock to ensure that only one thread can initialize the promise.
  (let ((future-id (loom-future-id future))
        promise-to-return thunk-to-launch)
    (loom:with-mutex! (loom-future-lock future)
      ;; Double-check inside the lock. It's possible another thread created
      ;; the promise while this thread was waiting for the lock. If so, we
      ;; use that existing promise.
      (if (loom-future-promise future)
          (setq promise-to-return (loom-future-promise future))
        ;; This thread wins the race to initialize the future.
        (progn
          (loom--future-check-cancelled future) ; Re-check for cancellation.
          (setf (loom-future-evaluated-p future) t)
          (setq promise-to-return
                (loom:promise
                 :name (format "future-promise-%S" future-id)))
          (setf (loom-future-promise future) promise-to-return)
          ;; We store the thunk in a local variable to be launched *after*
          ;; the lock is released.
          (setq thunk-to-launch (loom-future-thunk future)))))

    ;; Launch the thunk OUTSIDE THE LOCK if this thread won the race.
    ;; This prevents holding the lock during the potentially long-running
    ;; computation, which would block other threads unnecessarily.
    (when thunk-to-launch
      (let ((work-fn (lambda ()
                       (condition-case err
                           ;; The result of the thunk resolves the promise.
                           (loom:promise-resolve promise-to-return
                                         (funcall thunk-to-launch))
                         ;; Any error during execution rejects the promise.
                         (error (loom:promise-reject promise-to-return err))))))
        ;; All futures execute as deferred tasks on the main thread.
        (loom:deferred work-fn)))
    promise-to-return))

;;;###autoload
(defun loom:future-get (future &optional timeout)
  "Force `FUTURE` and get its result, blocking cooperatively until available.
This is a synchronous convenience wrapper around `(loom:await
(loom:force FUTURE))`. It is useful for cases where you need to transition
from an asynchronous context back to a synchronous one.

Arguments:
- `FUTURE` (loom-future): The future whose result is needed.
- `TIMEOUT` (number, optional): The maximum number of seconds to wait.

Returns:
- The resolved value of the future.

Signals:
- `loom-invalid-future-error`: If `FUTURE` is not a valid future object.
- `loom-future-cancelled-error`: If the future was cancelled.
- `loom-timeout-error`: If the timeout is exceeded.
- `loom-await-error`: If the future's computation results in an error."
  (loom--validate-future future 'loom:future-get)
  (loom:await (loom:force future) timeout))

;;;###autoload
(defun loom:future-cancel (future)
  "Cancel a future, preventing its execution if not already started.

Arguments:
- `FUTURE` (loom-future): The future to cancel.

Returns:
- `t` if the future was successfully cancelled (i.e., it was pending),
  `nil` if it was already running or completed.

Side Effects:
- Sets the future's `cancelled-p` flag to `t`.
- If the future has already been forced, this will attempt to reject
  its underlying promise with a cancellation error.

Signals:
- `loom-invalid-future-error`."
  (loom--validate-future future 'loom:future-cancel)
  (let ((future-id (loom-future-id future)) was-pending)
    (loom:with-mutex! (loom-future-lock future)
      (when (and (not (loom-future-evaluated-p future))
                 (not (loom-future-cancelled-p future)))
        (setf (loom-future-cancelled-p future) t)
        (setq was-pending t)
        ;; If a promise was created but the thunk hasn't run, reject it.
        (when-let ((promise (loom-future-promise future)))
          (loom:promise-reject promise
                       (loom:error! :type 'loom-future-cancelled-error
                                    :message "Future was cancelled")))))
    (when was-pending (loom:log! :info future-id "Cancelled future."))
    was-pending))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Convenience Constructors

;;;###autoload
(cl-defmacro loom:future-resolved! (value-form &rest keys)
  "Return a new `loom-future` that is already resolved with `VALUE-FORM`.

Arguments:
- `VALUE-FORM` (form): A Lisp form that evaluates to the resolution value.
- `KEYS` (plist): Options like `:metadata`.

Returns:
- (loom-future): A new, already-evaluated `loom-future`."
  (declare (indent 1) (debug t))
  `(let* ((promise (loom:resolved! ,value-form ,@keys))
          (id (gensym "future-resolved-")))
     (%%make-future :id id :promise promise :evaluated-p t
                    :lock (loom:make-lock (format "lock-%S" id))
                    :metadata (plist-get (list ,@keys) :metadata))))

;;;###autoload
(cl-defmacro loom:future-rejected! (error-form &rest keys)
  "Return a new `loom-future` that is already rejected with `ERROR-FORM`.

Arguments:
- `ERROR-FORM` (form): A Lisp form that evaluates to the rejection error.
- `KEYS` (plist): Options like `:metadata`.

Returns:
- (loom-future): A new, already-evaluated `loom-future`."
  (declare (indent 1) (debug t))
  `(let* ((promise (loom:rejected! ,error-form ,@keys))
          (id (gensym "future-rejected-")))
     (%%make-future :id id :promise promise :evaluated-p t
                    :lock (loom:make-lock (format "lock-%S" id))
                    :metadata (plist-get (list ,@keys) :metadata))))

;;;###autoload
(cl-defmacro loom:future-delay (seconds &optional value-form &rest keys)
  "Create a `loom-future` that resolves after `SECONDS`.
The timer only starts when the future is first forced.

Arguments:
- `SECONDS` (number): The non-negative delay duration.
- `VALUE-FORM` (form, optional): The value to resolve with. Defaults to `t`.
- `KEYS` (plist): Options like `:metadata`.

Returns:
- (loom-future): A new, lazy `loom-future`."
  (declare (indent 1))
  `(progn
     (unless (and (numberp ,seconds) (>= ,seconds 0))
       (error "SECONDS must be a non-negative number: %S" ,seconds))
     (apply #'loom:future (lambda () (loom:delay ,seconds ,(or value-form t)))
            (list ,@keys))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Chaining & Composition

;;;###autoload
(defmacro loom:future-then (future transform-fn)
  "Apply `TRANSFORM-FN` to the result of a future, creating a new future.
The new future is also lazy; the transformation is only applied when
the new future is forced.

Arguments:
- `FUTURE` (loom-future): The parent future.
- `TRANSFORM-FN` (form): A function `(lambda (value) ...)` to apply.

Returns:
- (loom-future): A new `loom-future` representing the chained computation."
  (declare (indent 1) (debug t))
  `(let ((parent-future ,future))
     (loom--validate-future parent-future 'loom:future-then)
     (loom:future
      (lambda () (loom:then (loom:force parent-future) ,transform-fn))
      :metadata (plist-put (copy-sequence (loom-future-metadata parent-future))
                           :parent-id (loom-future-id parent-future)))))

;;;###autoload
(defmacro loom:future-catch (future error-handler-fn)
  "Attach an error handler to a future, creating a new recoverable future.

Arguments:
- `FUTURE` (loom-future): The parent future.
- `ERROR-HANDLER-FN` (form): A function `(lambda (error) ...)` to apply.

Returns:
- (loom-future): A new `loom-future` that can handle the original's failure."
  (declare (indent 1) (debug t))
  `(let ((parent-future ,future))
     (loom--validate-future parent-future 'loom:future-catch)
     (loom:future
      (lambda () (loom:catch (loom:force parent-future) ,error-handler-fn))
      :metadata (plist-put (copy-sequence (loom-future-metadata parent-future))
                           :parent-id (loom-future-id parent-future)))))

;;;###autoload
(defmacro loom:future-finally (future cleanup-fn)
  "Attach a cleanup function to a future that runs regardless of outcome.

Arguments:
- `FUTURE` (loom-future): The parent future.
- `CLEANUP-FN` (form): A nullary function `(lambda () ...)` to execute.

Returns:
- (loom-future): A new `loom-future` with the cleanup attached."
  (declare (indent 1) (debug t))
  `(let ((parent-future ,future))
     (loom--validate-future parent-future 'loom:future-finally)
     (loom:future
      (lambda () (loom:finally (loom:force parent-future) ,cleanup-fn))
      :metadata (plist-put (copy-sequence (loom-future-metadata parent-future))
                           :parent-id (loom-future-id parent-future)))))

;;;###autoload
(defmacro loom:future-tap (future tap-fn)
  "Attach a side-effect function to a future, without altering the chain.

Arguments:
- `FUTURE` (loom-future): The parent future.
- `TAP-FN` (form): A function `(lambda (value error) ...)` to execute.

Returns:
- (loom-future): A new `loom-future` that resolves with the original's outcome."
  (declare (indent 1) (debug t))
  `(let ((parent-future ,future))
     (loom--validate-future parent-future 'loom:future-tap)
     (loom:future
      (lambda () (loom:tap (loom:force parent-future) ,tap-fn))
      :metadata (plist-put (copy-sequence (loom-future-metadata parent-future))
                           :parent-id (loom-future-id parent-future)))))

;;;###autoload
(defun loom:future-all (futures)
  "Create a future that, when forced, runs a list of `FUTURES` in parallel.

Arguments:
- `FUTURES` (list): A list of `loom-future` objects.

Returns:
- (loom-future): A new `loom-future` that resolves with a list of all results."
  (loom--validate-futures-list futures 'loom:future-all)
  (loom:future (lambda () (loom:all (mapcar #'loom:force futures)))
               :metadata `(:type :all :count ,(length futures))))

;;;###autoload
(defun loom:future-all-settled (futures)
  "Create a future that runs `FUTURES` and waits for all to complete.
This is similar to `loom:future-all`, but the returned future will
never reject. Instead, it resolves with a list of plists, each
describing the outcome of one of the input futures.

Arguments:
- `FUTURES` (list): A list of `loom-future` objects.

Returns:
- (loom-future): A new `loom-future` that resolves to a list of outcome plists."
  (loom--validate-futures-list futures 'loom:future-all-settled)
  (loom:future (lambda () (loom:all-settled (mapcar #'loom:force futures)))
               :metadata `(:type :all-settled :count ,(length futures))))

;;;###autoload
(defun loom:future-race (futures)
  "Create a future that resolves with the first of `FUTURES` to complete.

Arguments:
- `FUTURES` (list): A list of `loom-future` objects.

Returns:
- (loom-future): A new `loom-future` that settles with the first result."
  (loom--validate-futures-list futures 'loom:future-race)
  (unless futures (error "Cannot race an empty list of futures"))
  (loom:future (lambda () (loom:race (mapcar #'loom:force futures)))
               :metadata `(:type :race :count ,(length futures))))

;;;###autoload
(defun loom:future-any (futures)
  "Create a future that resolves with the first successful result from `FUTURES`.

Arguments:
- `FUTURES` (list): A list of `loom-future` objects.

Returns:
- (loom-future): A new `loom-future` that resolves with the first successful result."
  (loom--validate-futures-list futures 'loom:future-any)
  (unless futures (error "Cannot process an empty list of futures"))
  (loom:future (lambda () (loom:any (mapcar #'loom:force futures)))
               :metadata `(:type :any :count ,(length futures))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Introspection

;;;###autoload
(defun loom:future-status (future)
  "Return a snapshot of the `FUTURE`'s current status.

Arguments:
- `FUTURE` (loom-future): The future to inspect.

Returns:
- (plist): A property list with metrics like `:evaluated-p`, `:mode`, etc.

Signals: `loom-invalid-future-error`."
  (loom--validate-future future 'loom:future-status)
  (let* ((promise (loom-future-promise future)))
    `(:id ,(loom-future-id future)
      :evaluated-p ,(loom-future-evaluated-p future)
      :cancelled-p ,(loom-future-cancelled-p future)
      :mode ,(loom-future-mode future)
      :metadata ,(loom-future-metadata future)
      :promise-status ,(when promise (loom:promise-status promise))
      :promise-value ,(when promise (loom:promise-value promise))
      :promise-error ,(when promise (loom:promise-error-value promise)))))

;;;###autoload
(defun loom:future-completed-p (future)
  "Return `t` if `FUTURE` has completed (either resolved or rejected).

Arguments:
- `FUTURE` (loom-future): The future to check.

Returns:
- `t` if the future has completed, `nil` otherwise.

Signals: `loom-invalid-future-error`."
  (loom--validate-future future 'loom:future-completed-p)
  (if-let ((promise (loom-future-promise future)))
      (not (loom:promise-pending-p promise))
    nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Integration

(defun loom--future-normalize-awaitable (awaitable)
  "Normalize an awaitable into a promise if it's a `loom-future`.
This function is added to `loom-normalize-awaitable-hook` to allow core
functions like `loom:await` to transparently accept futures.

Arguments:
- `AWAITABLE` (any): The object to normalize.

Returns:
- The forced promise if `AWAITABLE` is a `loom-future`, otherwise `nil`."
  (when (loom-future-p awaitable)
    (condition-case err
        (loom:force awaitable)
      ;; If forcing a cancelled future, return a rejected promise.
      (loom-future-cancelled-error
       (loom:rejected! (loom:error! :type 'loom-future-cancelled-error
                                    :message "Future was cancelled"
                                    :cause err))))))

;; Plug the future into the core promise system, making them interchangeable.
(add-hook 'loom-normalize-awaitable-hook #'loom--future-normalize-awaitable)

(provide 'loom-future)
;;; loom-future.el ends here