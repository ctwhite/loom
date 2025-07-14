;;; loom-cancel.el --- Primitives for Cooperative Cancellation -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library provides primitives for cooperative cancellation of
;; asynchronous tasks. `loom-cancel-token` is a thread-safe object used
;; to signal cancellation. It is now integrated with the core `loom-callback`
;; and scheduler system.

;;; Code:

(require 'cl-lib)

(require 'loom-log)
(require 'loom-lock)
(require 'loom-core)
(require 'loom-primitives)
(require 'loom-microtask)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'loom-cancel-error
  "A promise or task was cancelled."
  'loom-error)

(define-error 'loom-cancel-invalid-token-error
  "An operation was attempted on an invalid cancel token."
  'loom-type-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (loom-cancel-token (:constructor %%make-cancel-token))
  "A thread-safe token for signaling cancellation to asynchronous operations.

Fields:
- `cancelled-p` (boolean): `t` if the token has been cancelled.
- `cancel-reason` (loom-error or nil): The error object representing why.
- `name` (string): An optional, human-readable name for debugging.
- `registrations` (list): A list of `loom-callback` structs.
- `lock` (loom-lock): A mutex for ensuring thread-safe operations.
- `data` (any): Optional, arbitrary user data."
  (cancelled-p nil :type boolean)
  (cancel-reason nil :type (or null loom-error))
  (name "" :type string)
  (registrations '() :type list)
  (lock (loom:lock) :type loom-lock)
  (data nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-token (token func-name)
  "Signal a `loom-cancel-invalid-token-error` if TOKEN is invalid."
  (unless (loom-cancel-token-p token)
    (signal 'loom-cancel-invalid-token-error
            (list (format "%s: Invalid token object %S" func-name token)
                  token))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom:cancel-token (&optional name data)
  "Create and return a new, non-cancelled cancel token.

Arguments:
- `NAME` (string, optional): A human-readable name for debugging.
- `DATA` (any, optional): Arbitrary user data to attach to the token.

Returns:
- (loom-cancel-token): A new token.

Side Effects:
- Creates a new `loom-cancel-token` struct.
- Logs a debug message using `loom-log`."
  (let* ((token-name (or name ""))
         (token (%%make-cancel-token
                 :name token-name
                 :data data
                 :lock (loom:lock (format "cancel-lock-%s" token-name)))))
    (loom-log :debug nil "Created cancel token %S" (loom-cancel-token-name token))
    token))

;;;###autoload
(defun loom:cancel-token-cancelled-p (token)
  "Check if TOKEN has been cancelled. Thread-safe.

Arguments:
- `TOKEN` (loom-cancel-token): The token to check.

Returns:
- (boolean): `t` if cancelled, `nil` otherwise.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` object."
  (loom--validate-token token 'loom:cancel-token-cancelled-p)
  (loom:with-mutex! (loom-cancel-token-lock token)
    (loom-cancel-token-cancelled-p token)))

;;;###autoload
(defun loom:cancel-token-reason (token)
  "Return the cancellation reason if TOKEN is cancelled.

Arguments:
- `TOKEN` (loom-cancel-token): The token to query.

Returns:
- (loom-error or nil): The error object used for cancellation, or `nil`."
  (loom--validate-token token 'loom:cancel-token-reason)
  (loom:with-mutex! (loom-cancel-token-lock token)
    (loom-cancel-token-cancel-reason token)))

;;;###autoload
(defun loom:throw-if-cancelled (token)
  "Check TOKEN and signal `loom-cancel-error` if it is cancelled.
This function serves as a cooperative cancellation point for long-running
tasks. Tasks are expected to call this periodically to check for
cancellation and abort their operation if the token is signaled.

Arguments:
- `TOKEN` (loom-cancel-token): The token to check.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` object.
- `loom-cancel-error`: If the token is cancelled. The original `loom-error`
  object is passed directly as the error data."
  (loom--validate-token token 'loom:throw-if-cancelled)
  (when-let ((reason (loom:cancel-token-reason token)))
    (signal 'loom-cancel-error reason)))
    
;;;###autoload
(defun loom:cancel-token-signal (token &optional reason)
  "Signal TOKEN as cancelled and invoke registered callbacks asynchronously.
This function is idempotent; it does nothing if the token is already
cancelled. All registered callbacks will be executed via the microtask
scheduler.

Arguments:
- `TOKEN` (loom-cancel-token): The token to signal.
- `REASON` (loom-error or string, optional): The reason for cancellation.
  If a string is provided, it is wrapped in a `loom-cancel-error`.

Returns:
- (boolean): `t` if the token was signalled for the first time, `nil`
  otherwise.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` object.

Side Effects:
- Changes the `cancelled-p` field of `TOKEN` to `t`.
- Sets the `cancel-reason` field of `TOKEN`.
- Clears the `registrations` list of `TOKEN`.
- Logs an info message using `loom-log`.
- Schedules and executes all registered cancellation callbacks
  asynchronously."
  (loom--validate-token token 'loom:cancel-token-signal)
  (let* ((final-reason-string (cond ((stringp reason) reason)
                                    ((loom-error-p reason) (loom:error-message reason))
                                    (t "Token cancelled")))
         (cancellation-error
          (loom:make-error :type :cancel :message final-reason-string))
         (was-active nil)
         (registrations-to-run nil))
    ;; 1. Atomically update the token's state and grab the callbacks.
    (loom:with-mutex! (loom-cancel-token-lock token)
      (unless (loom-cancel-token-cancelled-p token)
        (setq was-active t)
        (setf (loom-cancel-token-cancelled-p token) t
              (loom-cancel-token-cancel-reason token) cancellation-error)
        (setq registrations-to-run (loom-cancel-token-registrations token))
        (setf (loom-cancel-token-registrations token) '())))

    ;; 2. If the state changed, run callbacks outside the lock.
    (when was-active
      (loom-log :info nil "Signaled token %S (Reason: %S)"
                (loom-cancel-token-name token)
                (loom:error-message cancellation-error))
      (let ((tasks-to-run
             (mapcar
              (lambda (registered-cb)
                (let ((handler (loom-callback-handler-fn registered-cb)))
                  (loom:callback
                   :type :deferred
                   :priority 0
                   :handler-fn
                   (lambda ()
                     (condition-case err
                         (funcall handler cancellation-error)
                       (error
                        (loom-log :error nil
                                  "Cancellation callback failed for token %S: %S"
                                  (loom-cancel-token-name token) err)))))))
              registrations-to-run)))
        (when tasks-to-run
          (loom:schedule-microtasks loom--microtask-scheduler tasks-to-run))))
    was-active))

;;;###autoload
(cl-defun loom:cancel-token-add-callback (token callback)
  "Register a CALLBACK function to run when TOKEN is cancelled.
The CALLBACK will receive one argument: the `loom-error` reason. If the
token is already cancelled, the callback is scheduled for execution
immediately via the global microtask queue.

Arguments:
- `TOKEN` (loom-cancel-token): The token to monitor.
- `CALLBACK` (function): A function of one argument, `(lambda (reason))`.

Returns:
- `nil`.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` object.
- `error`: If `CALLBACK` is not a function.

Side Effects:
- Adds a new registration to the `registrations` list of `TOKEN` if the
  token is not yet cancelled and the callback is not already registered.
- If the token is already cancelled, the `CALLBACK` is immediately
  scheduled for execution."
  (loom--validate-token token 'loom:cancel-token-add-callback)
  (unless (functionp callback) (error "CALLBACK must be a function: %S" callback))

  (if-let ((reason (loom:cancel-token-reason token)))
      (loom:schedule-microtasks
       loom--microtask-scheduler
       (list (loom:callback 
               :type :deferred 
               :priority 0
               :handler-fn (lambda () (funcall callback reason)))))
    (loom:with-mutex! (loom-cancel-token-lock token)
      (if-let ((reason-in-lock (loom:cancel-token-reason token)))
          (loom:schedule-microtasks
           loom--microtask-scheduler
           (list (loom:callback
                  :type :deferred 
                  :priority 0
                  :handler-fn (lambda () (funcall callback reason-in-lock)))))
        (let ((reg (loom:callback :type :cancel :handler-fn callback)))
          (cl-pushnew reg (loom-cancel-token-registrations token)
                      :key #'loom-callback-handler-fn
                      :test #'eq)))))
  nil)

;;;###autoload
(defun loom:cancel-token-remove-callback (token callback)
  "Unregister a specific CALLBACK function from a TOKEN.
This is useful for explicit cleanup if a cancellable task completes
successfully and no longer needs to listen for cancellation signals.

Arguments:
- `TOKEN` (loom-cancel-token): The token to modify.
- `CALLBACK` (function): The exact function object to remove.

Returns:
- (boolean): `t` if the callback was found and removed, `nil` otherwise.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` object.

Side Effects:
- Modifies the `registrations` list of `TOKEN`, removing the specified
  `CALLBACK` if found."
  (loom--validate-token token 'loom:cancel-token-remove-callback)
  (let ((removed-p nil))
    (loom:with-mutex! (loom-cancel-token-lock token)
      (let* ((registrations (loom-cancel-token-registrations token))
             (new-registrations (cl-delete
                                 callback registrations
                                 :key #'loom-callback-handler-fn
                                 :test #'eq)))
        (when (< (length new-registrations) (length registrations))
          (setq removed-p t)
          (setf (loom-cancel-token-registrations token) new-registrations))))
    removed-p))

;;;###autoload
(defun loom:cancel-token-linked (source-token &optional name data)
  "Create a new token that is automatically cancelled when `SOURCE-TOKEN` is.
This is useful for propagating cancellation down a hierarchy of tasks,
allowing a parent task's cancellation to automatically cancel its child tasks.

Arguments:
- `SOURCE-TOKEN` (loom-cancel-token): The token to chain from.
- `NAME` (string, optional): A name for the new linked token.
- `DATA` (any, optional): Data for the new linked token.

Returns:
- (loom-cancel-token): The new linked token.

Signals:
- `loom-cancel-invalid-token-error`: If `SOURCE-TOKEN` is not a valid
  `loom-cancel-token` object.

Side Effects:
- Creates a new `loom-cancel-token`.
- Registers a callback on `SOURCE-TOKEN` that signals the new token
  upon cancellation."
  (loom--validate-token source-token 'loom:cancel-token-linked)
  (let ((new-token (loom:cancel-token name data)))
    (loom:cancel-token-add-callback
     source-token
     (lambda (reason) (loom:cancel-token-signal new-token reason)))
    new-token))

;;;###autoload
(defun loom:cancel-token-link-promise (token promise)
  "Link a TOKEN to a PROMISE, cancelling the token when the promise settles.
This is a convenient way to manage a token's lifecycle based on a
promise's outcome. When the `PROMISE` resolves or rejects, the `TOKEN`
will be signaled as cancelled.

Arguments:
- `TOKEN` (loom-cancel-token): The token to signal.
- `PROMISE` (loom-promise): The promise to link to.

Returns:
- (loom-cancel-token): The `TOKEN` that was linked.

Signals:
- `loom-cancel-invalid-token-error`: If `TOKEN` is not a valid
  `loom-cancel-token` object.
- `error`: If `PROMISE` is not a valid `loom-promise` object.

Side Effects:
- Attaches a `loom:finally` handler to the `PROMISE` which will signal
  the `TOKEN` upon the promise's settlement."
  (loom--validate-token token 'loom:cancel-token-link-promise)
  (unless (loom-promise-p promise)
    (error "Argument must be a loom-promise: %S" promise))
  (loom:finally promise
              (lambda (_value err)
              (loom-log :debug nil "Promise %S finally handler triggered for token %S."
                          (loom-promise-id promise) (loom-cancel-token-name token))
                (let ((reason (or err
                                  (loom:make-error
                                   :type :cancel-link
                                   :message "Linked promise settled."))))
                  (loom:cancel-token-signal token reason))))
  token)

(provide 'loom-cancel)
;;; loom-cancel.el ends here