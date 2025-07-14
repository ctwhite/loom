;;; loom-lock.el --- Mutual Exclusion Locks for Concur -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This module provides the `loom-lock` (mutex) primitive. It supports
;; both cooperative (Emacs Lisp-managed) and native (OS-thread-managed)
;; mutexes, ensuring thread-safe access to shared resources across the
;; various concurrency modes within the Concur library.
;;
;; Key features include:
;; - **Cooperative Locks (`:deferred`, `:process`):** For single-threaded
;;   asynchronous operations (via `sit-for`) or inter-process coordination
;;   (via `make-process` where `loom` manages the cooperative blocking).
;;   These are reentrant for the same owner. Contention from a different
;;   owner signals an error.
;; - **Native Thread Locks (`:thread`):** For preemptive thread-safety using
;;   Emacs's native mutexes. These are blocking and implicitly reentrant.
;; - **Non-Blocking `try-acquire`:** For cooperative locks, allows attempting
;;   to acquire a lock without blocking.
;; - **Resource Tracking Hooks:** Integrates with higher-level libraries to
;;   monitor resource acquisition and release.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'loom-log)
(require 'loom-errors)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'loom-lock-error
  "A generic error with a concurrency lock operation."
  'loom-error)

(define-error 'loom-invalid-lock-error
  "An operation was attempted on an invalid lock object."
  'loom-lock-error)

(define-error 'loom-lock-unowned-release-error
  "Attempted to release a lock not owned by the caller."
  'loom-lock-error)

(define-error 'loom-lock-unsupported-operation-error
  "An operation is not supported for the lock's mode."
  'loom-lock-error)

(define-error 'loom-lock-contention-error
  "Attempted to acquire a lock already held by another owner."
  'loom-lock-error)

(define-error 'loom-lock-double-release-error
  "Attempted to release a lock that is not currently held."
  'loom-lock-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (loom-lock (:constructor %%make-lock))
  "A mutual exclusion lock (mutex).

Fields:
- `name` (string): A descriptive name for debugging and logging.
- `mode` (symbol): The lock's operating mode: `:deferred` (cooperative,
  single-thread), `:thread` (native OS thread mutex), or `:process`
  (cooperative, inter-process).
- `locked-p` (boolean): `t` if the lock is held. Used only for the
  cooperative `:deferred` and `:process` modes.
- `native-mutex` (mutex): The underlying native Emacs mutex object, used
  only for the `:thread` mode.
- `owner` (any): An identifier for the entity that currently holds the
  lock. Used for reentrancy checks in cooperative modes and for logging.
- `reentrant-count` (integer): Tracks nested acquisitions for a
  cooperative lock by the same owner.
- `creation-time` (float): Timestamp when the lock was created.
- `last-acquired` (float): Timestamp of the last successful acquisition."
  (name "" :type string)
  (mode :deferred :type (member :deferred :thread :process))
  (locked-p nil :type boolean)
  (native-mutex nil)
  (owner nil)
  (reentrant-count 0 :type integer)
  (creation-time (float-time) :type float)
  (last-acquired nil :type (or null float)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-lock (lock function-name)
  "Signal an error if LOCK is not a `loom-lock` object.

Arguments:
- `LOCK` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for errors."
  (unless (loom-lock-p lock)
    (signal 'loom-invalid-lock-error
            (list (loom:make-error
                   :type :loom-invalid-lock-error
                   :message (format "%S: Invalid lock object" function-name)
                   :data `(:lock ,lock :function ,function-name))))))

(defun loom--validate-lock-name (name)
  "Validate and normalize a lock name.

Arguments:
- `NAME` (any): The name to validate.

Returns:
- (string): A valid lock name."
  (cond
   ((null name) (format "lock-%S" (gensym)))
   ((stringp name) name)
   ((symbolp name) (symbol-name name))
   (t (format "%S" name))))

(defun loom--lock-get-effective-owner (lock owner)
  "Return the effective owner for a lock operation.
Defaults to `current-thread` for `:thread` mode or `t` for cooperative modes.

Arguments:
- `LOCK` (loom-lock): The lock object.
- `OWNER` (any): The requested owner identifier.

Returns:
- (any): The effective owner identifier."
  (or owner
      (pcase (loom-lock-mode lock)
        (:thread (current-thread))
        ((or :deferred :process) t))))

(defun loom--lock-track-resource (action lock)
  "Call the resource tracking function, if defined.
This is a hook for higher-level libraries to monitor resource usage.

Arguments:
- `ACTION` (keyword): The action, either `:acquire` or `:release`.
- `LOCK` (loom-lock): The lock object."
  (when (and (fboundp 'loom-resource-tracking-function)
             loom-resource-tracking-function)
    (condition-case err
        (funcall loom-resource-tracking-function action lock)
      (error
       (loom-log :warning (loom-lock-name lock)
                 "Resource tracking failed: %S" err)))))

(defun loom--lock-signal-error (error-symbol message lock &optional data)
  "Signal a structured lock error.

Arguments:
- `ERROR-SYMBOL` (symbol): The error condition symbol to signal.
- `MESSAGE` (string): The error message.
- `LOCK` (loom-lock): The lock object involved.
- `DATA` (plist, optional): Additional error data."
  (let ((error-type-keyword (intern (concat ":" (symbol-name error-symbol)))))
    (signal error-symbol
            (list (loom:make-error
                   :type error-type-keyword
                   :message message
                   :data (append `(:lock ,lock) data))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:lock (&optional name &key (mode :deferred))
  "Create a new lock object (mutex).

The lock's behavior depends on its `MODE`:
- `:deferred`: A cooperative, non-blocking, reentrant lock intended for
  use within the main Emacs thread. Contention from a different owner
  signals an error.
- `:thread`: A native OS thread mutex that uses `mutex-lock`. It provides
  preemptive thread-safety, is blocking, and is implicitly reentrant.
- `:process`: A cooperative, non-blocking, reentrant lock intended for
  inter-process coordination. Behaves like `:deferred` but indicates
  its use case.

Arguments:
- `NAME` (string): A descriptive name for debugging.
- `:MODE` (symbol, optional): The lock's mode. Defaults to `:deferred`.

Returns:
- (loom-lock): A new lock object.

Signals:
- `error` if an invalid mode is provided or if `:thread` mode is chosen
  but thread support is unavailable in the current Emacs build."
  (unless (memq mode '(:deferred :thread :process))
    (error "Invalid lock mode: %S. Must be :deferred, :thread, or :process" mode))

  (let* ((lock-name (loom--validate-lock-name name))
         (new-lock
          (pcase mode
            (:thread
             (unless (fboundp 'make-mutex)
               (error "Cannot create :thread lock: thread support missing"))
             (%%make-lock :name lock-name :mode :thread
                          :native-mutex (make-mutex lock-name)))
            ((or :deferred :process)
             (%%make-lock :name lock-name :mode mode)))))
    (loom-log :debug lock-name "Lock created (mode: %s)" mode)
    new-lock))

;;;###autoload
(defun loom:lock-acquire (lock &optional owner)
  "Acquire `LOCK`. This is a **blocking** operation for `:thread` locks.
For `:deferred` and `:process` modes, it is cooperative and reentrant
for the same owner.

Arguments:
- `LOCK` (loom-lock): The lock object to acquire.
- `OWNER` (any, optional): Identifier for the entity acquiring the lock.

Returns:
- `t` if the lock was successfully acquired.

Signals:
- `loom-invalid-lock-error` if `LOCK` is not a valid lock object.
- `loom-lock-contention-error` if a `:deferred` or `:process` lock is
  already held by a different owner."
  (loom--validate-lock lock 'loom:lock-acquire)
  (let ((effective-owner (loom--lock-get-effective-owner lock owner)))
    (pcase (loom-lock-mode lock)
      (:thread
       (mutex-lock (loom-lock-native-mutex lock))
       (setf (loom-lock-owner lock) effective-owner)
       (setf (loom-lock-last-acquired lock) (float-time))
       (loom-log :debug (loom-lock-name lock)
                 "Native lock acquired by %S" effective-owner))
      ((or :deferred :process)
       (cond
        ((not (loom-lock-locked-p lock)) ; Lock is free
         (setf (loom-lock-locked-p lock) t)
         (setf (loom-lock-owner lock) effective-owner)
         (setf (loom-lock-reentrant-count lock) 1)
         (setf (loom-lock-last-acquired lock) (float-time))
         (loom-log :debug (loom-lock-name lock)
                   "Cooperative lock acquired by %S" effective-owner))
        ((equal (loom-lock-owner lock) effective-owner) ; Re-entry
         (cl-incf (loom-lock-reentrant-count lock))
         (loom-log :debug (loom-lock-name lock)
                   "Cooperative lock re-entered (count: %d)"
                   (loom-lock-reentrant-count lock)))
        (t ; Contention
         (loom--lock-signal-error
          'loom-lock-contention-error
          (format "Cannot acquire cooperative lock %S (held by %S)"
                  (loom-lock-name lock) (loom-lock-owner lock))
          lock
          `(:current-owner ,(loom-lock-owner lock)
            :requested-owner ,effective-owner))))))

    (loom--lock-track-resource :acquire lock)
    t))

;;;###autoload
(defun loom:lock-try-acquire (lock &optional owner)
  "Attempt to acquire `LOCK`. This is a **non-blocking** operation.
This operation is supported for `:deferred` and `:process` mode locks.
It is NOT re-entrant; if the lock is held by any owner, this will fail.

Arguments:
- `LOCK` (loom-lock): The lock object.
- `OWNER` (any, optional): Identifier for the entity acquiring the lock.

Returns:
- `t` if the lock was acquired, `nil` if it was already held.

Signals:
- `loom-invalid-lock-error` if `LOCK` is not a valid lock object.
- `loom-lock-unsupported-operation-error` if called on a `:thread` lock."
  (loom--validate-lock lock 'loom:lock-try-acquire)
  (when (eq (loom-lock-mode lock) :thread)
    (loom--lock-signal-error
     'loom-lock-unsupported-operation-error
     "try-acquire is not supported for :thread mode locks"
     lock))

  (let ((acquired-p nil)
        (effective-owner (loom--lock-get-effective-owner lock owner)))
    ;; This is a simple if. If the lock is held at all, fail.
    (if (not (loom-lock-locked-p lock))
        (progn
          (setf (loom-lock-locked-p lock) t)
          (setf (loom-lock-owner lock) effective-owner)
          (setf (loom-lock-reentrant-count lock) 1)
          (setf (loom-lock-last-acquired lock) (float-time))
          (setq acquired-p t)
          (loom-log :debug (loom-lock-name lock)
                    "Cooperative lock try-acquired by %S" effective-owner))
      ;; Lock is already held, so fail.
      (setq acquired-p nil)
      (loom-log :debug (loom-lock-name lock)
                "Lock try-acquire failed: held by %S"
                (loom-lock-owner lock)))

    (when acquired-p
      (loom--lock-track-resource :acquire lock))
    acquired-p))

;;;###autoload
(defun loom:lock-release (lock &optional owner)
  "Release `LOCK`. Requires the caller to be the current owner.
For `:deferred` and `:process` locks, the release is counted. The lock is
only truly freed when the nested acquisition count returns to zero.

Arguments:
- `LOCK` (loom-lock): The lock object to release.
- `OWNER` (any, optional): Identifier for the entity releasing the lock.
  Must match the owner who acquired it.

Returns:
- `t` if the release was successful.

Signals:
- `loom-invalid-lock-error` if `LOCK` is invalid.
- `loom-lock-unowned-release-error` if the `OWNER` does not hold the
  lock.
- `loom-lock-double-release-error` if the lock is not currently held."
  (cl-block loom:lock-release
    (loom--validate-lock lock 'loom:lock-release)
    (let ((effective-owner (loom--lock-get-effective-owner lock owner)))

      ;; Check if lock is held at all
      (when (and (memq (loom-lock-mode lock) '(:deferred :process))
                 (not (loom-lock-locked-p lock)))
        (loom--lock-signal-error
         'loom-lock-double-release-error
         (format "Cannot release lock %S: not currently held"
                 (loom-lock-name lock))
         lock
         `(:owner ,effective-owner))
        ;; Exit after signaling to prevent state corruption
        (cl-return-from loom:lock-release))

      ;; Check ownership
      (unless (equal (loom-lock-owner lock) effective-owner)
        (loom--lock-signal-error
         'loom-lock-unowned-release-error
         (format "Cannot release lock %S owned by %S"
                 (loom-lock-name lock) (loom-lock-owner lock))
         lock
         `(:current-owner ,(loom-lock-owner lock)
           :releasing-owner ,effective-owner))
        ;; Exit after signaling to prevent state corruption
        (cl-return-from loom:lock-release))

      (loom--lock-track-resource :release lock)

      (pcase (loom-lock-mode lock)
        (:thread
         (mutex-unlock (loom-lock-native-mutex lock))
         (setf (loom-lock-owner lock) nil)
         (loom-log :debug (loom-lock-name lock) "Native lock released"))
        ((or :deferred :process)
         (cl-decf (loom-lock-reentrant-count lock))
         (if (zerop (loom-lock-reentrant-count lock))
             (progn
               (setf (loom-lock-owner lock) nil)
               (setf (loom-lock-locked-p lock) nil)
               (loom-log :debug (loom-lock-name lock) "Cooperative lock freed"))
           (loom-log :debug (loom-lock-name lock)
                     "Cooperative lock count decremented to %d"
                     (loom-lock-reentrant-count lock)))))
      t)))

;;;###autoload
(defun loom:lock-owned-p (lock &optional owner)
  "Check if `LOCK` is owned by `OWNER`.

Arguments:
- `LOCK` (loom-lock): The lock object to check.
- `OWNER` (any, optional): The owner to check for. Uses effective owner if nil.

Returns:
- `t` if the lock is owned by the specified owner, `nil` otherwise.

Signals:
- `loom-invalid-lock-error` if `LOCK` is not a valid lock object."
  (loom--validate-lock lock 'loom:lock-owned-p)
  (let ((effective-owner (loom--lock-get-effective-owner lock owner)))
    (equal (loom-lock-owner lock) effective-owner)))

;;;###autoload
(defun loom:lock-held-p (lock)
  "Check if `LOCK` is currently held by any owner.

Arguments:
- `LOCK` (loom-lock): The lock object to check.

Returns:
- `t` if the lock is held, `nil` otherwise.

Signals:
- `loom-invalid-lock-error` if `LOCK` is not a valid lock object."
  (loom--validate-lock lock 'loom:lock-held-p)
  (pcase (loom-lock-mode lock)
    (:thread (not (null (loom-lock-owner lock))))
    ((or :deferred :process) (loom-lock-locked-p lock))))

;;;###autoload
(defmacro loom:with-mutex! (lock-form &rest body)
  "Execute BODY within a critical section guarded by the lock.
This macro ensures the lock is always released, even if an error occurs
within the BODY. It uses a **blocking** acquire for `:thread` locks.

Arguments:
- `LOCK-FORM` (form): A form that evaluates to a `loom-lock` object.
- `BODY` (forms): The Lisp forms to execute while holding the lock.

Returns:
- The value of the last form in `BODY`.

Side Effects:
- Acquires and releases the lock. Executes `BODY` forms."
  (declare (indent 1) (debug t))
  (let ((lock-var (gensym "lock-")))
    `(let ((,lock-var ,lock-form))
       (loom:lock-acquire ,lock-var)
       (unwind-protect
           (progn ,@body)
         (loom:lock-release ,lock-var)))))

;;;###autoload
(defmacro loom:with-mutex-try! (lock-form &rest body)
  "Execute BODY within a critical section if the lock can be acquired.
This macro uses non-blocking acquisition and only executes BODY if the
lock was successfully acquired. Only supported for cooperative locks.

Arguments:
- `LOCK-FORM` (form): A form that evaluates to a `loom-lock` object.
- `BODY` (forms): The Lisp forms to execute while holding the lock.

Returns:
- The value of the last form in `BODY` if the lock was acquired, `nil` otherwise.

Side Effects:
- Attempts to acquire and release the lock. Executes `BODY` forms if successful."
  (declare (indent 1) (debug t))
  (let ((lock-var (gensym "lock-"))
        (acquired-var (gensym "acquired-")))
    `(let ((,lock-var ,lock-form)
           (,acquired-var nil))
       (unwind-protect
           (when (setq ,acquired-var (loom:lock-try-acquire ,lock-var))
             ,@body)
         (when ,acquired-var
           (loom:lock-release ,lock-var))))))

(provide 'loom-lock)
;;; loom-lock.el ends here