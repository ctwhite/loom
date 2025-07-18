;;; loom-cancel.el --- Primitives for Cooperative Cancellation -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides the core primitives for **cooperative cancellation**
;; of asynchronous tasks within the Loom framework. The central concept is
;; the `loom-cancel-token`, a thread-safe object that represents a cancellation
;; signal that can be passed among different functions and threads.
;;
;; ## Key Concepts
;;
;; - **Cooperative Cancellation:** Cancellation is not preemptive. An
;;   asynchronous task must be explicitly designed to "cooperate" by
;;   periodically checking a cancellation token (e.g., via
;;   `loom:throw-if-cancelled`) and aborting its work if signaled.
;;
;; - **Cancellation Propagation:** A `loom-cancel-token` can have callbacks
;;   registered on it. When the token is signaled (via
;;   `loom:cancel-token-signal`), all registered callbacks are executed
;;   asynchronously on the microtask queue. This allows cancellation signals
;;   to be propagated to promises, child tasks, or other parts of the system.
;;
;; - **Thread-Safety:** All operations that modify a token's state are
;;   thread-safe, using an internal mutex to prevent race conditions.
;;
;; ## Basic Usage
;;
;; 1. Create a token source:
;;    (let ((token (loom:cancel-token "my-task-token")))
;;      ...)
;;
;; 2. Pass the token to an async function, which registers a callback:
;;    (my-async-op-with-token promise token)
;;
;; 3. When you want to cancel, signal the token:
;;    (loom:cancel-token-signal token "User requested cancellation.")

;;; Code:

(require 'cl-lib)

(require 'loom-log)
(require 'loom-errors)
(require 'loom-callback)
(require 'loom-lock)
(require 'loom-microtask)
(require 'loom-promise)
(require 'loom-primitives)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom:microtask "loom-config")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-cancel-error
  "An error signaled when a task is aborted due to cancellation.
This is the error that is typically thrown by `loom:throw-if-cancelled`."
  'loom-error)

(define-error 'loom-cancel-invalid-token-error
  "An error signaled when an operation is attempted on an object that is
not a valid `loom-cancel-token`."
  'loom-type-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-cancel-token (:constructor %%make-cancel-token))
  "A thread-safe token for signaling cancellation to asynchronous operations.
This object acts as a shared signal. It can be passed to multiple tasks,
and when it is cancelled, all listening tasks are notified.

Fields:
- `cancelled-p` (boolean): `t` if the token has been cancelled. This is the
  primary state flag.
- `cancel-reason` (loom-error or nil): The structured error object
  representing why cancellation occurred.
- `name` (string): An optional, human-readable name for debugging and logging.
- `registrations` (list): A list of `loom-callback` structs to be invoked
  upon cancellation.
- `lock` (loom-lock): A mutex that ensures atomic, thread-safe updates to
  the token's state.
- `data` (any): Optional, arbitrary user data for application-specific needs."
  (cancelled-p nil :type boolean)
  (cancel-reason nil :type (or null loom-error))
  (name "" :type string)
  (registrations '() :type list)
  (lock (loom:lock) :type loom-lock)
  (data nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-token (token func-name)
  "Signals a `loom-cancel-invalid-token-error` if `TOKEN` is not a
`loom-cancel-token`.

Arguments:
- `TOKEN` (any): The object to validate.
- `FUNC-NAME` (symbol): The name of the calling function for error reporting.

Returns: `nil`.
Signals: `loom-cancel-invalid-token-error` if `TOKEN` is invalid."
  (unless (loom-cancel-token-p token)
    (signal 'loom-cancel-invalid-token-error
            (list (format "%s: Expected a loom-cancel-token, but got %S"
                          func-name token)
                  token))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom:cancel-token (&optional name data)
  "Creates and returns a new, non-cancelled cancellation token.

Arguments:
- `NAME` (string, optional): A human-readable name for debugging and logging.
- `DATA` (any, optional): Arbitrary user data to attach to the token.

Returns:
- (loom-cancel-token): A new token instance in the active state."
  (let* ((token-name (or name "unnamed-token"))
         (token (%%make-cancel-token
                 :name token-name
                 :data data
                 :lock (loom:lock (format "cancel-lock-%s" token-name)))))
    (loom-log :debug nil "Created cancel token '%s'" token-name)
    token))

;;;###autoload
(defun loom:cancel-token-cancelled-p (token)
  "Checks if `TOKEN` has been cancelled. This function is thread-safe.

This provides a fast, non-locking check of the token's status. It is safe
because the `cancelled-p` field is only ever written once (from `nil` to
`t`), which is an atomic operation on most platforms. Reading a
momentarily stale value is an acceptable trade-off for performance in a
status check.

Arguments:
- `TOKEN` (loom-cancel-token): The token to check.

Returns: `t` if cancelled, `nil` otherwise.
Signals: `loom-cancel-invalid-token-error` if `TOKEN` is invalid."
  (loom--validate-token token 'loom:cancel-token-cancelled-p)
  (loom-cancel-token-cancelled-p token))

;;;###autoload
(defun loom:cancel-token-reason (token)
  "Returns the cancellation reason if `TOKEN` is cancelled. Thread-safe.

Arguments:
- `TOKEN` (loom-cancel-token): The token to query.

Returns:
- (loom-error or nil): The `loom-error` struct provided at cancellation, or `nil`.

Signals: `loom-cancel-invalid-token-error` if `TOKEN` is invalid."
  (loom--validate-token token 'loom:cancel-token-reason)
  ;; This requires a lock to ensure we read the reason that was set
  ;; atomically with the `cancelled-p` flag.
  (loom:with-mutex! (loom-cancel-token-lock token)
    (loom-cancel-token-cancel-reason token)))

;;;###autoload
(defun loom:throw-if-cancelled (token)
  "Checks `TOKEN` and signals a `loom-cancel-error` if it has been cancelled.

This function is the primary mechanism for implementing **cooperative
cancellation points**. Long-running synchronous loops or functions should
call this periodically to check if they have been requested to stop, allowing
them to abort gracefully.

Arguments:
- `TOKEN` (loom-cancel-token): The token to check.

Returns: `nil` if the token is not cancelled.
Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is invalid.
- `loom-cancel-error`: If the token is cancelled."
  (loom--validate-token token 'loom:throw-if-cancelled)
  (when (loom:cancel-token-cancelled-p token)
    (loom-log :debug nil
              "Cancellation detected for token '%s'; throwing error."
              (loom-cancel-token-name token))
    (signal 'loom-cancel-error (list (loom:cancel-token-reason token)))))

;;;###autoload
(defun loom:cancel-token-signal (token &optional reason)
  "Signals `TOKEN` as cancelled and invokes all registered callbacks
asynchronously.

This function is idempotent; it does nothing if the token is already
cancelled. All registered callbacks are scheduled for execution on the
global microtask queue, ensuring they run promptly but on a clean stack.

Arguments:
- `TOKEN` (loom-cancel-token): The token to signal.
- `REASON` (loom-error or string, optional): The reason for cancellation.
  If a string is provided, it's wrapped in a standard `loom-error`.

Returns: `t` if the token was cancelled by this call, `nil` if it was already
cancelled.
Signals: `loom-cancel-invalid-token-error` if `TOKEN` is invalid."
  (loom--validate-token token 'loom:cancel-token-signal)
  (let ((cancellation-error (if (loom-error-p reason) reason
                              (loom:make-error :type :cancel
                                               :message (or reason "Token was cancelled."))))
        was-active
        registrations-to-run)
    ;; Step 1: Atomically update the token's state and retrieve the callbacks.
    ;; This is done under a lock to prevent race conditions.
    (loom:with-mutex! (loom-cancel-token-lock token)
      (unless (loom-cancel-token-cancelled-p token)
        (setq was-active t)
        (setf (loom-cancel-token-cancelled-p token) t
              (loom-cancel-token-cancel-reason token) cancellation-error)
        ;; Grab the list of callbacks and clear it on the token, so they
        ;; are only ever executed once.
        (setq registrations-to-run (loom-cancel-token-registrations token))
        (setf (loom-cancel-token-registrations token) '())))

    ;; Step 2: If the state was changed, execute callbacks *outside* the lock.
    ;; This prevents deadlocks if a callback tries to acquire another lock.
    (when was-active
      (loom-log :info nil
                "Signaling token '%s' (Reason: %s). Scheduling %d callbacks."
                (loom-cancel-token-name token)
                (loom:error-message cancellation-error)
                (length registrations-to-run))
      ;; Schedule each registered callback to run on the microtask queue.
      (dolist (registered-cb registrations-to-run)
        (loom:microtask
         (loom:callback
          (lambda ()
            (condition-case err
                (funcall (loom-callback-handler-fn registered-cb)
                         cancellation-error)
              (error
               (loom-log :error nil "Cancel callback failed for token '%s': %S"
                         (loom-cancel-token-name token) err))))))))
    was-active))

;;;###autoload
(defun loom:cancel-token-add-callback (token callback)
  "Registers a `CALLBACK` function to run when `TOKEN` is cancelled.

The `CALLBACK` will be a function of one argument, `(lambda (reason))`,
where `reason` is the `loom-error` object. If the token is already
cancelled when this is called, the callback is scheduled for execution
immediately on the global microtask queue.

Arguments:
- `TOKEN` (loom-cancel-token): The token to monitor.
- `CALLBACK` (function): The function to invoke upon cancellation.

Returns: `nil`.
Signals: `loom-cancel-invalid-token-error` or `error` for invalid arguments."
  (loom--validate-token token 'loom:cancel-token-add-callback)
  (unless (functionp callback)
    (error "CALLBACK argument must be a function, but got %S" callback))

  (let ((token-name (loom-cancel-token-name token)))
    ;; This "check-lock-check" pattern handles a potential race condition.
    ;; First, check without a lock for the common case where the token is not
    ;; cancelled.
    (if-let ((reason (and (loom-cancel-token-cancelled-p token)
                          (loom:cancel-token-reason token))))
        ;; If already cancelled, execute immediately.
        (progn
          (loom-log :debug nil
                    "Token '%s' already cancelled; running callback immediately."
                    token-name)
          (loom:microtask (lambda () (funcall callback reason))))
      ;; If not cancelled, acquire the lock to safely modify the registration
      ;; list.
      (loom:with-mutex! (loom-cancel-token-lock token)
        ;; Double-check the state inside the lock, in case it was cancelled
        ;; between the first check and acquiring the lock.
        (if-let ((reason-in-lock (loom:cancel-token-reason token)))
            (progn
              (loom-log :debug nil
                        "Token '%s' cancelled during lock acquisition; running callback."
                        token-name)
              (loom:microtask (lambda () (funcall callback reason-in-lock))))
          ;; State is still active; it's safe to add the callback.
          (loom-log :debug nil "Registering new callback for token '%s'."
                    token-name)
          (cl-pushnew (loom:callback callback :type :cancel)
                      (loom-cancel-token-registrations token)
                      :key #'loom-callback-handler-fn
                      :test #'eq)))))
  nil)

;;;###autoload
(defun loom:cancel-token-remove-callback (token callback)
  "Unregisters a specific `CALLBACK` function from a `TOKEN`.

This is useful for explicit resource management. If a task that was listening
for cancellation completes successfully, it should remove its callback to
avoid being invoked unnecessarily and to allow the token to be garbage
collected.

Arguments:
- `TOKEN` (loom-cancel-token): The token to modify.
- `CALLBACK` (function): The exact function object (`eq`) to remove.

Returns: `t` if the callback was found and removed, `nil` otherwise.
Signals: `loom-cancel-invalid-token-error` if `TOKEN` is invalid."
  (loom--validate-token token 'loom:cancel-token-remove-callback)
  (let (removed-p)
    (loom:with-mutex! (loom-cancel-token-lock token)
      (let* ((registrations (loom-cancel-token-registrations token))
             (new-registrations (cl-delete callback registrations
                                           :key #'loom-callback-handler-fn
                                           :test #'eq)))
        ;; If the list length changed, a removal occurred.
        (when (< (length new-registrations) (length registrations))
          (loom-log :debug nil "Removed callback from token '%s'."
                    (loom-cancel-token-name token))
          (setq removed-p t)
          (setf (loom-cancel-token-registrations token)
                new-registrations))))
    removed-p))

;;;###autoload
(defun loom:cancel-token-linked (source-token &optional name data)
  "Creates a new token that is automatically cancelled when `SOURCE-TOKEN` is.

This is the primary tool for creating a hierarchy or tree of cancellable
tasks. If a parent task is cancelled, this mechanism ensures the cancellation
signal is propagated down to its children.

Arguments:
- `SOURCE-TOKEN` (loom-cancel-token): The parent token to chain from.
- `NAME` (string, optional): A descriptive name for the new linked token.
- `DATA` (any, optional): User data for the new linked token.

Returns: The new linked `loom-cancel-token`.
Signals: `loom-cancel-invalid-token-error` if `SOURCE-TOKEN` is invalid."
  (loom--validate-token source-token 'loom:cancel-token-linked)
  (let* ((new-name (or name (format "linked-to-%s"
                                     (loom-cancel-token-name source-token))))
         (new-token (loom:cancel-token new-name data)))
    (loom-log :info nil "Creating token '%s' linked to '%s'."
              new-name (loom-cancel-token-name source-token))
    ;; Register a simple callback on the source token that will, in turn,
    ;; signal our new token with the same reason.
    (loom:cancel-token-add-callback
     source-token
     (lambda (reason) (loom:cancel-token-signal new-token reason)))
    new-token))

;;;###autoload
(defun loom:cancel-token-link-promise (token promise)
  "Links a `TOKEN` to a `PROMISE`, cancelling the token when the promise
settles.

When the `PROMISE` resolves or rejects, the `TOKEN` will be signaled as
cancelled. This is useful for managing a token that represents the \"scope\"
of a promise-based operation; the scope ends when the operation ends.

Arguments:
- `TOKEN` (loom-cancel-token): The token to be signaled.
- `PROMISE` (loom-promise): The promise whose settlement triggers the signal.

Returns: The `TOKEN` that was linked.
Signals: `loom-cancel-invalid-token-error` or `error` for invalid arguments."
  (loom--validate-token token 'loom:cancel-token-link-promise)
  (unless (loom-promise-p promise)
    (error "Argument must be a loom-promise, but got: %S" promise))

  (loom-log :info nil "Linking token '%s' to settlement of promise %S."
            (loom-cancel-token-name token) (loom-promise-id promise))

  ;; `loom:finally` is perfect for this, as it runs regardless of whether
  ;; the promise resolves or rejects.
  (loom:finally promise
                (lambda (_value err)
                  (loom-log :debug nil
                            "Promise %S settled; signaling linked token '%S'."
                            (loom-promise-id promise)
                            (loom-cancel-token-name token))
                  ;; The reason for cancellation will be the promise's rejection
                  ;; error, or a generic message if the promise resolved
                  ;; successfully.
                  (let ((reason (or err
                                    (loom:make-error
                                     :type :cancel-link
                                     :message "Linked promise settled successfully."))))
                    (loom:cancel-token-signal token reason))))
  token)

(provide 'loom-cancel)
;;; loom-cancel.el ends here