;;; loom-cancel.el --- Primitives for Cooperative Cancellation -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides the core primitives for **cooperative cancellation**
;; of asynchronous tasks within the Loom framework. The central concept is
;; the `loom-cancel-token`, a thread-safe object that represents a
;; cancellation signal that can be passed among different functions and
;; threads.
;;
;; ## Key Concepts
;;
;; - **Cooperative Cancellation:** Cancellation is not preemptive. An
;;   asynchronous task must be explicitly designed to "cooperate" by
;;   periodically checking a cancellation token (e.g., via
;;   `loom:throw-if-cancelled`) and aborting its work if signaled.
;;
;; - **Cancellation Propagation:** A `loom-cancel-token` can have
;;   callbacks registered on it. When the token is signaled (via
;;   `loom:cancel-token-signal`), all registered callbacks are executed
;;   asynchronously on the microtask queue. This allows cancellation
;;   signals to be propagated to promises, child tasks, or other parts of
;;   the system.
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
(require 's) 

(require 'loom-log)
(require 'loom-error)
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
- `name` (string): An optional, human-readable name for debugging and
  logging.
- `registrations` (list): A list of `loom-callback` structs to be invoked
  upon cancellation.
- `lock` (loom-lock): A mutex that ensures atomic, thread-safe updates to
  the token's state.
- `data` (any): Optional, arbitrary user data for application-specific
  needs."
  (cancelled-p nil :type boolean)
  (cancel-reason nil :type (or null loom-error))
  (name "" :type string)
  (registrations '() :type list)
  (lock (loom:lock "loom-cancel-token") :type loom-lock)
  (data nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-token (token func-name)
  "Signals a `loom-cancel-invalid-token-error` if `TOKEN` is not a
`loom-cancel-token`.

Arguments:
- `TOKEN` (any): The object to validate.
- `FUNC-NAME` (symbol): The name of the calling function for error
  reporting.

Returns: `nil`.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is invalid (i.e., not
  a `loom-cancel-token` struct)."
  (unless (loom-cancel-token-p token)
    (signal 'loom-cancel-invalid-token-error
            (list (format "%s: Expected a loom-cancel-token, but got %S"
                          func-name token)
                  token))))

(defun loom-cancel--token-name-to-symbol (token-name)
  "Converts a token name string to a valid symbol for logging targets.
Removes common problematic characters and prefixes/suffixes with 'token-'."
  (intern (s-replace-regexp "[^a-zA-Z0-9_]" "-" token-name)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom:cancel-token (&optional name data)
  "Creates and returns a new, non-cancelled cancellation token.
This function initializes a new `loom-cancel-token` in an active state.
It's ready to be passed to cooperative asynchronous operations.

Arguments:
- `NAME` (string, optional): A human-readable name for debugging and
  logging purposes. Defaults to \"unnamed-token\".
- `DATA` (any, optional): Arbitrary user data to attach to the token,
  which can be retrieved later via `loom-cancel-token-data`.

Returns:
- (loom-cancel-token): A new token instance in the active state.

Side Effects:
- Creates a new `loom-cancel-token` struct.
- Creates an internal `loom-lock` for the token.
- Logs the token creation at `:debug` level, using the token's name
  as the log target."
  (let* ((token-name (or name "unnamed-token"))
         (log-target (loom-cancel--token-name-to-symbol token-name))
         (token (%%make-cancel-token
                 :name token-name
                 :data data
                 :lock (loom:lock (format "cancel-lock-%s" token-name)))))
    (loom:log! :debug log-target 
                     "Created cancel token '%s'" token-name)
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

Returns:
- (boolean): `t` if the token has been signaled as cancelled, `nil`
  otherwise.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` struct."
  (loom--validate-token token 'loom:cancel-token-cancelled-p)
  (loom-cancel-token-cancelled-p token))

;;;###autoload
(defun loom:cancel-token-reason (token)
  "Returns the cancellation reason if `TOKEN` is cancelled. Thread-safe.
This function retrieves the `loom-error` object (or `nil`) that was
provided when the token was signaled for cancellation.

Arguments:
- `TOKEN` (loom-cancel-token): The token to query.

Returns:
- (loom-error or nil): The `loom-error` struct provided at cancellation,
  or `nil` if the token is not yet cancelled or no explicit reason was
  provided.

Side Effects:
- Acquires and releases the token's internal mutex for safe access.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` struct."
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
call this periodically to check if they have been requested to stop,
allowing them to abort gracefully. If the token is cancelled, a
`loom-cancel-error` is signaled, wrapping the cancellation reason.

Arguments:
- `TOKEN` (loom-cancel-token): The token to check.

Returns: `nil` if the token is not cancelled.

Side Effects:
- Logs a debug message if cancellation is detected, using the token's name
  as the log target.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` struct.
- `loom-cancel-error`: If the token is cancelled, containing the
  `cancel-reason` as its data."
  (loom--validate-token token 'loom:throw-if-cancelled)
  (when (loom:cancel-token-cancelled-p token)
    (loom:log! :debug (loom-cancel--token-name-to-symbol
                      (loom-cancel-token-name token)) 
                     "Cancellation detected for token '%s'; throwing error."
                     (loom-cancel-token-name token))
    (signal 'loom-cancel-error (list (loom:cancel-token-reason token)))))

;;;###autoload
(defun loom:cancel-token-signal (token &optional reason)
  "Signals `TOKEN` as cancelled and invokes all registered callbacks
asynchronously.
This function is idempotent; it does nothing if the token is already
cancelled. When signaled, the token's `cancelled-p` flag is set to `t`,
its `cancel-reason` is stored, and all previously registered callbacks
are scheduled for execution on the global microtask queue. Callbacks
receive the `loom-error` reason as their argument.

Arguments:
- `TOKEN` (loom-cancel-token): The token to signal.
- `REASON` (loom-error or string, optional): The reason for cancellation.
  If a string is provided, it's wrapped in a standard `loom-error` of type
  `:cancel`. If `nil`, a default `loom-error` is used.

Returns:
- (boolean): `t` if the token was successfully cancelled by this call
  (i.e., it was not already cancelled), `nil` if it was already
  cancelled.

Side Effects:
- Updates the `cancelled-p` and `cancel-reason` slots of `TOKEN`.
- Clears the `registrations` list of `TOKEN` after scheduling.
- Schedules all registered callbacks on the microtask queue.
- Logs informational messages about signaling and errors in callbacks,
  using the token's name as the log target.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` struct."
  (loom--validate-token token 'loom:cancel-token-signal)
  (let ((cancellation-error (if (loom-error-p reason) reason
                              (loom:error! :type :cancel
                                           :message (or reason "Token was cancelled."))))
        was-active
        registrations-to-run
        (token-name (loom-cancel-token-name token))
        (log-target (loom-cancel--token-name-to-symbol
                     (loom-cancel-token-name token))))
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
    ;; This prevents deadlocks if a callback tries to acquire another lock
    ;; during its execution.
    (when was-active
      (loom:log! :info log-target 
                       "Signaling token '%s' (Reason: %s). Scheduling %d callbacks."
                       token-name
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
               (loom:log! :error log-target 
                                 "Cancel callback failed for token '%s': %S"
                                 token-name err))))))))
    was-active))

;;;###autoload
(defun loom:cancel-token-add-callback (token callback)
  "Registers a `CALLBACK` function to run when `TOKEN` is cancelled.
The `CALLBACK` will be a function of one argument, `(lambda (reason))`,
where `reason` is the `loom-error` object containing the cancellation
details. If the token is already cancelled when this is called, the
callback is scheduled for immediate execution on the global microtask
queue. This function ensures thread-safe registration.

Arguments:
- `TOKEN` (loom-cancel-token): The token to monitor.
- `CALLBACK` (function): The function to invoke upon cancellation. This
  function should accept one argument (the `loom-error` reason).

Returns: `nil`.

Side Effects:
- Adds `CALLBACK` to the token's internal list of registrations if the
  token is not yet cancelled.
- If the token is already cancelled, schedules `CALLBACK` for immediate
  execution on the microtask queue.
- Logs debug messages about callback registration or immediate execution,
  using the token's name as the log target.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` struct.
- `error`: If `CALLBACK` is not a function."
  (loom--validate-token token 'loom:cancel-token-add-callback)
  (unless (functionp callback)
    (error "CALLBACK argument must be a function, but got %S" callback))

  (let ((token-name (loom-cancel-token-name token))
        (log-target (loom-cancel--token-name-to-symbol
                     (loom-cancel-token-name token))))
    ;; This "check-lock-check" pattern handles a potential race condition.
    ;; First, check without a lock for the common case where the token is not
    ;; cancelled.
    (if-let ((reason (and (loom-cancel-token-cancelled-p token)
                          (loom:cancel-token-reason token))))
        ;; If already cancelled, execute immediately.
        (progn
          (loom:log! :debug log-target
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
              (loom:log! :debug log-target
                                "Token '%s' cancelled during lock acquisition; running callback."
                                token-name)
              (loom:microtask (lambda () (funcall callback reason-in-lock))))
          ;; State is still active; it's safe to add the callback.
          (loom:log! :debug log-target
                            "Registering new callback for token '%s'."
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
for cancellation completes successfully, it should remove its
callback to avoid being invoked unnecessarily and to allow the token to
be garbage collected more efficiently. This operation is thread-safe.

Arguments:
- `TOKEN` (loom-cancel-token): The token from which to remove the callback.
- `CALLBACK` (function): The exact function object (`eq` comparison)
  to remove from the token's registered callbacks.

Returns:
- (boolean): `t` if the callback was found and successfully removed, `nil`
  otherwise (e.g., if the callback was not registered or already removed).

Side Effects:
- Modifies the `registrations` list of `TOKEN` by removing `CALLBACK`.
- Logs a debug message if a callback is removed, using the token's name
  as the log target.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` struct."
  (loom--validate-token token 'loom:cancel-token-remove-callback)
  (let (removed-p
        (token-name (loom-cancel-token-name token))
        (log-target (loom-cancel--token-name-to-symbol
                     (loom-cancel-token-name token))))
    (loom:with-mutex! (loom-cancel-token-lock token)
      (let* ((registrations (loom-cancel-token-registrations token))
             (new-registrations (cl-delete callback registrations
                                           :key #'loom-callback-handler-fn
                                           :test #'eq)))
        ;; If the list length changed, a removal occurred.
        (when (< (length new-registrations) (length registrations))
          (loom:log! :debug log-target
                            "Removed callback from token '%s'."
                            token-name)
          (setq removed-p t)
          (setf (loom-cancel-token-registrations token)
                new-registrations))))
    removed-p))

;;;###autoload
(defun loom:cancel-token-linked (source-token &optional name data)
  "Creates a new token that is automatically cancelled when `SOURCE-TOKEN` is.
This is the primary tool for creating a hierarchy or tree of cancellable
tasks. If a parent task (represented by `SOURCE-TOKEN`) is cancelled,
this mechanism ensures the cancellation signal is propagated down to its
child (`new-token`). This is achieved by registering a callback on the
`SOURCE-TOKEN` that signals the `new-token`.

Arguments:
- `SOURCE-TOKEN` (loom-cancel-token): The parent token from which to chain.
- `NAME` (string, optional): A descriptive name for the new linked token.
  Defaults to a name derived from `SOURCE-TOKEN`.
- `DATA` (any, optional): Arbitrary user data to attach to the new linked token.

Returns:
- (loom-cancel-token): The newly created and linked `loom-cancel-token`.

Side Effects:
- Creates a new `loom-cancel-token`.
- Registers a callback on `SOURCE-TOKEN` to signal the new token.
- Logs informational messages about linking tokens, using both source and
  new token names as log targets.

Signals:
- `loom-cancel-invalid-token-error`: If `SOURCE-TOKEN` is not a valid
  `loom-cancel-token` struct."
  (loom--validate-token source-token 'loom:cancel-token-linked)
  (let* ((source-token-name (loom-cancel-token-name source-token))
         (new-name (or name (format "linked-to-%s" source-token-name)))
         (new-token (loom:cancel-token new-name data))
         (source-log-target (loom-cancel--token-name-to-symbol
                             source-token-name))
         (new-log-target (loom-cancel--token-name-to-symbol new-name)))
    (loom:log! :info source-log-target 
                     "Creating token '%s' linked to '%s'."
                     new-name source-token-name)
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
When the `PROMISE` resolves or rejects (i.e., 'settles'), the `TOKEN`
will be signaled as cancelled. This is useful for managing a token that
represents the \"scope\" of a promise-based operation; the scope ends
when the operation (promise) ends.

Arguments:
- `TOKEN` (loom-cancel-token): The token to be signaled when the promise
  settles.
- `PROMISE` (loom-promise): The promise instance whose settlement
  (resolution or rejection) triggers the cancellation signal on `TOKEN`.

Returns:
- (loom-cancel-token): The `TOKEN` that was linked.

Side Effects:
- Adds a `loom:finally` handler to `PROMISE` that calls
  `loom:cancel-token-signal` on `TOKEN` when `PROMISE` settles.
- Logs informational messages about linking, using the token's name and
  promise ID as log targets.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` struct.
- `error`: If `PROMISE` is not a `loom-promise` struct."
  (loom--validate-token token 'loom:cancel-token-link-promise)
  (unless (loom-promise-p promise)
    (error "Argument must be a loom-promise, but got: %S" promise))

  (let* ((token-name (loom-cancel-token-name token))
         (log-target (loom-cancel--token-name-to-symbol token-name)))
    (loom:log! :info log-target
                    "Linking token '%s' to settlement of promise %S."
                    token-name (loom-promise-id promise))

    ;; `loom:finally` is perfect for this, as it runs regardless of whether
    ;; the promise resolves or rejects.
    (loom:finally promise
                  (lambda (_value err)
                    (loom:log! :debug log-target
                                     "Promise %S settled; signaling linked token '%S'."
                                     (loom-promise-id promise)
                                     token-name)
                    ;; The reason for cancellation will be the promise's rejection
                    ;; error, or a generic message if the promise resolved
                    ;; successfully.
                    (let ((reason (or err
                                      (loom:error
                                       :type :cancel-link
                                       :message "Linked promise settled successfully."))))
                      (loom:cancel-token-signal token reason))))
    token))

(provide 'loom-cancel)
;;; loom-cancel.el ends here