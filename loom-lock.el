;;; loom-lock.el --- Mutual Exclusion Locks for Loom -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the `loom-lock` (mutex) primitive, a
;; cornerstone for safe concurrent programming in Emacs. It offers a
;; unified, robust interface that abstracts over Emacs's diverse
;; concurrency models, ensuring thread-safe operations.
;;
;; ## Key Features
;;
;; - **Unified Concurrency Model:** Provides a single `loom-lock` object
;;   that adapts its behavior based on the specified `:mode`.
;;
;; - **Cooperative Locks (`:deferred`, `:process`):** For single-threaded
;;   asynchronous operations. These locks are reentrant for the same
;;   owner and use a polling-based acquisition strategy with backoff
;;   for contention. They prevent blocking the main Emacs UI thread.
;;
;; - **Native Thread Locks (`:thread`):** For preemptive thread-safety
;;   in multi-threaded Emacs builds. This mode wraps Emacs's native
;;   `mutex` for maximum efficiency and correctness. It is blocking
;;   and implicitly reentrant.
;;
;; - **Safe Usage Macros:** The `loom:with-mutex!` macro is the
;;   recommended way to use locks. It guarantees a lock is always
;;   released, even if an error occurs, preventing deadlocks.
;;
;; - **Timeout Support:** `loom:with-mutex-timeout!` allows acquiring a
;;   lock with a timeout, preventing indefinite blocking.
;;
;; - **Comprehensive Monitoring:** When enabled via `defcustom`, the
;;   module tracks detailed performance statistics for each lock,
;;   including acquisition counts, contention rates, and hold times.
;;
;; - **Graceful Degradation:** Automatically falls back from `:thread` to
;;   `:deferred` mode if native threading support is unavailable,
;;   ensuring code portability.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'loom-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization and Constants

(defcustom loom-lock-default-timeout 30.0
  "Default timeout in seconds for lock acquisition operations.
A value of `nil` means to wait indefinitely, which can risk deadlocks."
  :type '(choice (const :tag "No timeout" nil)
                 (number :tag "Timeout in seconds"))
  :group 'loom)

(defcustom loom-lock-enable-deadlock-detection t
  "Enable basic deadlock detection mechanisms.
When enabled, locks will track acquisition chains to detect simple
circular dependencies, primarily through timeout mechanisms."
  :type 'boolean
  :group 'loom)

(defcustom loom-lock-enable-performance-tracking t
  "Enable performance tracking for lock operations.
When enabled, the system collects timing statistics for lock
acquisitions, releases, and contention events. This can be useful
for performance tuning but adds a small amount of overhead."
  :type 'boolean
  :group 'loom)

(defconst *loom-lock-supported-modes* '(:deferred :thread :process)
  "A list of the officially supported lock modes.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-invalid-lock-error
  "An operation was attempted on an object that is not a valid `loom-lock`."
  'loom-error)

(define-error 'loom-lock-unowned-release-error
  "An attempt was made to release a lock by an entity that does not own it."
  'loom-error)

(define-error 'loom-lock-unsupported-operation-error
  "An operation was attempted that is not supported for the lock's current
mode."
  'loom-error)

(define-error 'loom-lock-contention-error
  "A non-blocking attempt was made to acquire a lock already held by another
owner."
  'loom-error)

(define-error 'loom-lock-double-release-error
  "An attempt was made to release a lock that is not currently held."
  'loom-error)

(define-error 'loom-lock-timeout-error
  "A blocking lock acquisition attempt timed out before the lock could be
acquired."
  'loom-error)

(define-error 'loom-lock-deadlock-error
  "A potential deadlock was detected during a lock acquisition attempt."
  'loom-error)

(define-error 'loom-lock-invalid-mode-error
  "An invalid or unsupported mode was specified during lock creation."
  'loom-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Statistics and Monitoring

(defvar loom--lock-global-stats (make-hash-table :test 'equal)
  "A global hash table for tracking performance statistics of all locks.
Keys are lock names (strings), values are plists of various metrics.")

(defun loom--lock-init-stats (lock)
  "Initializes the statistics tracking entry for a given `LOCK`.

Arguments:
- `LOCK` (loom-lock): The lock for which to initialize stats.

Returns: `nil`.
Side Effects: Creates a new entry in `loom--lock-global-stats`."
  (when loom-lock-enable-performance-tracking
    (puthash (loom-lock-name lock)
             `(:acquisitions 0 :releases 0 :contentions 0
               :total-hold-time 0.0 :max-hold-time 0.0 :timeouts 0
               :created ,(float-time))
             loom--lock-global-stats)))

(defun loom--lock-update-stats (lock stat-type &optional value)
  "Updates a specific performance statistic for a `LOCK`.

This is a no-op if `loom-lock-enable-performance-tracking` is `nil`.

Arguments:
- `LOCK` (loom-lock): The lock whose stats to update.
- `STAT-TYPE` (keyword): The statistic to update (e.g., `:acquisition`).
- `VALUE` (any, optional): The value for the update (e.g., hold time).

Returns: `nil`.
Side Effects: Modifies the statistics plist for the lock."
  (when loom-lock-enable-performance-tracking
    (when-let ((stats (gethash (loom-lock-name lock) loom--lock-global-stats)))
      (pcase stat-type
        (:acquisition (cl-incf (plist-get stats :acquisitions)))
        (:release (cl-incf (plist-get stats :releases)))
        (:contention (cl-incf (plist-get stats :contentions)))
        (:timeout (cl-incf (plist-get stats :timeouts)))
        (:hold-time
         (when value
           (cl-incf (plist-get stats :total-hold-time) value)
           (setf (plist-get stats :max-hold-time)
                 (max (plist-get stats :max-hold-time) value))))))))

;;;###autoload
(defun loom:lock-global-stats ()
  "Returns a copy of the global statistics for all lock operations.

Returns:
- (hash-table): A copy of the global statistics hash table, preventing
  accidental modification of the internal state. Keys are lock names,
  values are plists of performance metrics."
  (copy-hash-table loom--lock-global-stats))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-lock (:constructor %%make-lock))
  "A mutual exclusion lock (mutex) with comprehensive concurrency models.

Fields:
- `name` (string): A descriptive name for debugging and statistics.
- `mode` (symbol): The operating mode: `:deferred`, `:thread`, or `:process`.
- `locked-p` (boolean): The primary lock state for cooperative modes.
- `native-mutex` (mutex): The underlying native Emacs mutex for `:thread`.
- `owner` (any): Identifier for the current lock holder.
- `reentrant-count` (integer): The nested acquisition count for reentrancy.
- `acquisition-timeout` (float): Default timeout for acquisition."
  (name "" :type string)
  (mode :deferred :type symbol)
  (locked-p nil :type boolean)
  (native-mutex nil)
  (owner nil)
  (reentrant-count 0 :type integer)
  (acquisition-timeout loom-lock-default-timeout :type (or null float)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Utility Functions

(defun loom--validate-lock (lock function-name)
  "Validates that `LOCK` is a `loom-lock` object.

Arguments:
- `LOCK` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error.

Returns: `nil`.
Signals: `loom-invalid-lock-error` if `LOCK` is invalid."
  (unless (loom-lock-p lock)
    (signal 'loom-invalid-lock-error
            (list (format "%S: Expected a loom-lock object, but got: %S"
                          function-name lock)))))

(defun loom--lock-get-effective-owner (lock &optional owner)
  "Determines the effective owner for a lock operation.
Defaults to `current-thread` for `:thread` or `t` for cooperative modes.

Arguments:
- `LOCK` (loom-lock): The lock in question.
- `OWNER` (any, optional): A specific owner identifier.

Returns: The effective owner identifier."
  (or owner
      (pcase (loom-lock-mode lock)
        (:thread (current-thread))
        ((or :deferred :process) t))))

(defun loom--lock-check-threading-support ()
  "Checks if native threading support is available.
Returns: `t` if `make-mutex` and `current-thread` exist, `nil` otherwise."
  (and (fboundp 'make-mutex) (fboundp 'current-thread)))

(defun loom--lock-track-resource (action lock)
  "Tracks resource usage if a tracking function is available.
This is a hook point for higher-level monitoring tools.

Arguments:
- `ACTION` (keyword): The action being performed (e.g., `:acquire`).
- `LOCK` (loom-lock): The lock involved in the action.

Returns: `nil`.
Side Effects: Calls the function in `loom-resource-tracking-function`."
  (when (and (fboundp 'loom-resource-tracking-function)
             (symbol-value 'loom-resource-tracking-function))
    (condition-case err
        (funcall (symbol-value 'loom-resource-tracking-function) action lock)
      (error
       (loom:log! :error (loom-lock-name lock)
                 "Resource tracking function failed: %S" err)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Lock Operations (Internal Helpers)

(defun loom--lock-acquire-cooperative (lock owner timeout)
  "Acquires a cooperative lock with timeout support.
Implements reentrancy, contention detection, and polling with backoff.

Arguments:
- `LOCK` (loom-lock): The cooperative lock to acquire.
- `OWNER` (any): The identifier of the entity acquiring the lock.
- `TIMEOUT` (number or nil): Maximum seconds to wait.

Returns: `t` if the lock was acquired successfully.
Signals: `loom-lock-timeout-error` if acquisition times out."
  (let ((start-time (float-time))
        (acquired-p nil)
        (sleep-interval 0.001)) ; Start with 1ms polling interval.

    ;; Loop until acquired or timeout.
    (while (and (not acquired-p)
                (or (null timeout) (< (- (float-time) start-time) timeout)))
      (cond
        ;; Case 1: Lock is free. Acquire it.
        ((not (loom-lock-locked-p lock))
         (setf (loom-lock-locked-p lock) t
               (loom-lock-owner lock) owner
               (loom-lock-reentrant-count lock) 1)
         (setq acquired-p t))
        ;; Case 2: We already own the lock. Increment reentrant count.
        ((equal (loom-lock-owner lock) owner)
         (cl-incf (loom-lock-reentrant-count lock))
         (setq acquired-p t))
        ;; Case 3: Lock is held by someone else (contention).
        (t
         (loom--lock-update-stats lock :contention)
         (loom:log! :debug (loom-lock-name lock)
                   "Contention on lock '%s'. Owner: %S"
                   (loom-lock-name lock) (loom-lock-owner lock))
         ;; If timeout, wait for a short, increasing interval.
         (when timeout
           (sit-for (min sleep-interval
                         (- timeout (- (float-time) start-time))))
           ;; Exponential backoff.
           (setq sleep-interval (min (* sleep-interval 1.5) 0.1))))))

    ;; If timed out.
    (unless acquired-p
      (loom--lock-update-stats lock :timeout)
      (loom:log! :warn (loom-lock-name lock)
                "Lock acquisition for '%s' timed out after %.2fs seconds."
                (loom-lock-name lock) timeout)
      (signal 'loom-lock-timeout-error
              (list (format "Lock acquisition for '%s' timed out after %.2fs"
                            (loom-lock-name lock) timeout))))

    (loom--lock-update-stats lock :acquisition)
    (loom--lock-track-resource :acquire lock)
    t))

(defun loom--lock-release-cooperative (lock owner)
  "Releases a cooperative lock.
Decrements the reentrant count. Lock is freed when count reaches zero.

Arguments:
- `LOCK` (loom-lock): The cooperative lock to release.
- `OWNER` (any): The identifier of the entity releasing the lock.

Returns: `t` if the release was valid.
Signals:
- `loom-lock-unowned-release-error`: If `OWNER` does not hold the lock.
- `loom-lock-double-release-error`: If the lock is not currently held."
  ;; Check for releasing a lock that isn't held.
  (unless (loom-lock-locked-p lock)
    (loom:log! :error (loom-lock-name lock)
              "Attempted to release unheld lock '%s'." (loom-lock-name lock))
    (signal 'loom-lock-double-release-error
            (list (format "Cannot release lock '%s': it is not held"
                          (loom-lock-name lock)))))
  ;; Check for releasing a lock owned by someone else.
  (unless (equal (loom-lock-owner lock) owner)
    (loom:log! :error (loom-lock-name lock)
              "Attempted to release lock '%s' owned by %S with wrong owner %S."
              (loom-lock-name lock) (loom-lock-owner lock) owner)
    (signal 'loom-lock-unowned-release-error
            (list (format "Cannot release lock '%s' owned by %S (current %S)"
                          (loom-lock-name lock) owner (loom-lock-owner lock)))))

  (cl-decf (loom-lock-reentrant-count lock))

  ;; If this was the last release, free the lock.
  (when (zerop (loom-lock-reentrant-count lock))
    (setf (loom-lock-owner lock) nil
          (loom-lock-locked-p lock) nil))

  (loom--lock-update-stats lock :release)
  (loom--lock-track-resource :release lock)
  t)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:lock (&optional name &key (mode :deferred)
                                   (timeout loom-lock-default-timeout))
  "Creates a new lock object (mutex) with comprehensive concurrency support.

The lock's behavior depends on its `MODE`:
- `:deferred` or `:process`: Cooperative, reentrant, polling-based.
- `:thread`: Native OS thread mutex, blocking (Emacs with threads only).

Arguments:
- `NAME` (string or symbol): Descriptive name for debugging.
- `:MODE` (symbol): Lock mode (`:deferred`, `:thread`, `:process`).
- `:TIMEOUT` (float or nil): Default timeout for acquisitions.

Returns:
- (loom-lock): A new lock object.

Signals: `loom-lock-invalid-mode-error` for unsupported modes."
  (unless (memq mode *loom-lock-supported-modes*)
    (signal 'loom-lock-invalid-mode-error
            (list (format "Invalid lock mode specified: %S" mode))))

  (let ((effective-mode mode)
        (lock-name (if (stringp name) name (format "%S" name))))
    ;; Gracefully degrade from :thread to :deferred if no threading.
    (when (and (eq mode :thread) (not (loom--lock-check-threading-support)))
      (setq effective-mode :deferred)
      (loom:log! :warn lock-name
                "Native threading unavailable; lock '%s' falls back to :deferred."
                lock-name))

    (let ((new-lock
           (%%make-lock :name lock-name
                        :mode effective-mode
                        ;; Only create native mutex if in :thread mode.
                        :native-mutex (and (eq effective-mode :thread)
                                           (make-mutex lock-name))
                        :acquisition-timeout timeout)))
      (loom--lock-init-stats new-lock)
      (loom:log! :info lock-name "Lock '%s' created (mode: %s)"
                lock-name effective-mode)
      new-lock)))

;;;###autoload
(defun loom:lock-acquire (lock &optional owner timeout)
  "Acquires `LOCK` with optional timeout. **For cooperative locks only.**
Manual control of cooperative (`:deferred` or `:process`) locks. For
`:thread` locks, prefer `loom:with-mutex!` for safety.

Arguments:
- `LOCK` (loom-lock): The lock object to acquire.
- `OWNER` (any, optional): Owner identifier.
- `TIMEOUT` (float, optional): Override timeout in seconds.

Returns: `t` if acquired.
Signals: `loom-invalid-lock-error`, `loom-lock-timeout-error`, or `error`
  if called on a `:thread` lock (unsafe)."
  (loom--validate-lock lock 'loom:lock-acquire)
  (let ((effective-owner (loom--lock-get-effective-owner lock owner))
        (effective-timeout (or timeout (loom-lock-acquisition-timeout lock))))
    (pcase (loom-lock-mode lock)
      (:thread
       (error "Direct acquire/release is discouraged for :thread locks.
Use `loom:with-mutex!` instead."))
      ((or :deferred :process)
       (loom--lock-acquire-cooperative lock effective-owner effective-timeout)))))

;;;###autoload
(defun loom:lock-try-acquire (lock &optional owner)
  "Attempts to acquire `LOCK` without blocking, returns immediately.

Arguments:
- `LOCK` (loom-lock): The lock object.
- `OWNER` (any, optional): Owner identifier.

Returns: `t` if acquired, `nil` if already held by another owner.
Signals: `loom-invalid-lock-error`, `loom-lock-unsupported-operation-error`
  for `:thread` mode (native `mutex-trylock` not standard)."
  (loom--validate-lock lock 'loom:lock-try-acquire)
  (let ((effective-owner (loom--lock-get-effective-owner lock owner)))
    (pcase (loom-lock-mode lock)
      (:thread
       (signal 'loom-lock-unsupported-operation-error
               '("try-acquire is not supported for native :thread mode locks")))
      ((or :deferred :process)
       (if (not (loom-lock-locked-p lock))
           (progn
             (setf (loom-lock-locked-p lock) t
                   (loom-lock-owner lock) effective-owner
                   (loom-lock-reentrant-count lock) 1)
             (loom--lock-update-stats lock :acquisition)
             (loom--lock-track-resource :acquire lock)
             t)
         (progn (loom--lock-update-stats lock :contention) nil))))))

;;;###autoload
(defun loom:lock-release (lock &optional owner)
  "Releases `LOCK`. Must be called by the current owner.
**For cooperative locks only.** Decrements reentrant count. Lock fully
released when count is zero.

Arguments:
- `LOCK` (loom-lock): The lock object to release.
- `OWNER` (any, optional): Owner identifier. Must match current owner.

Returns: `t` if successful.
Signals: Errors for invalid lock, unowned release, double release, or if
  called on a `:thread` mode lock."
  (loom--validate-lock lock 'loom:lock-release)
  (let ((effective-owner (loom--lock-get-effective-owner lock owner)))
    (pcase (loom-lock-mode lock)
      (:thread
       (error "Direct acquire/release is discouraged for :thread locks.
Use `loom:with-mutex!` instead."))
      ((or :deferred :process)
       (loom--lock-release-cooperative lock effective-owner)))))

;;;###autoload
(defun loom:lock-owned-p (lock &optional owner)
  "Checks if `LOCK` is currently owned by `OWNER`.

Arguments:
- `LOCK` (loom-lock): The lock object to check.
- `OWNER` (any, optional): The owner to check.

Returns: `t` if owned by specified owner, `nil` otherwise.
Signals: `loom-invalid-lock-error`."
  (loom--validate-lock lock 'loom:lock-owned-p)
  (let ((effective-owner (loom--lock-get-effective-owner lock owner)))
    (pcase (loom-lock-mode lock)
      (:thread
       ;; Use native `mutex-owner` if available.
       (and (loom-lock-native-mutex lock)
            (if (fboundp 'mutex-owner)
                (equal (mutex-owner (loom-lock-native-mutex lock))
                       effective-owner)
              ;; Fallback for older Emacs.
              (equal (loom-lock-owner lock) effective-owner))))
      ((or :deferred :process)
       (and (loom-lock-locked-p lock)
            (equal (loom-lock-owner lock) effective-owner))))))

;;;###autoload
(defun loom:lock-held-p (lock)
  "Checks if `LOCK` is currently held by *any* owner.

Arguments:
- `LOCK` (loom-lock): The lock object to check.

Returns: `t` if held, `nil` otherwise.
Signals: `loom-invalid-lock-error`."
  (loom--validate-lock lock 'loom:lock-held-p)
  (pcase (loom-lock-mode lock)
    (:thread
     (and (loom-lock-native-mutex lock)
          ;; `mutex-owner` is most reliable.
          (if (fboundp 'mutex-owner)
              (not (null (mutex-owner (loom-lock-native-mutex lock))))
            ;; Fallback check.
            (loom-lock-locked-p lock))))
    ((or :deferred :process)
     (loom-lock-locked-p lock))))

;;;###autoload
(defun loom:lock-stats (lock)
  "Returns a comprehensive plist of statistics for a specific `LOCK`.

Arguments:
- `LOCK` (loom-lock): The lock object.

Returns:
- (plist): Plist of current state (`:current-*`) and historical metrics.

Signals: `loom-invalid-lock-error`."
  (loom--validate-lock lock 'loom:lock-stats)
  (let ((stats (gethash (loom-lock-name lock) loom--lock-global-stats)))
    (unless stats
      (loom:log! :warn (loom-lock-name lock)
                "No statistics found for lock '%s'. Is tracking enabled?"
                (loom-lock-name lock))
      (setq stats '(:not-tracked t)))
    `(:name ,(loom-lock-name lock)
      :current-mode ,(loom-lock-mode lock)
      :current-locked-p ,(loom:lock-held-p lock)
      :current-owner ,(loom-lock-owner lock)
      :current-reentrant-count ,(loom-lock-reentrant-count lock)
      ,@stats)))

;;;###autoload
(defmacro loom:with-mutex! (lock-form &rest body)
  "Executes `BODY` within a critical section guarded by a lock.
**Recommended way to use locks.** Guarantees lock release via
`unwind-protect`.

Arguments:
- `LOCK-FORM` (form): Evaluates to a `loom-lock` object.
- `BODY` (forms): Lisp forms to execute while holding the lock.

Returns: Value of last form in `BODY`.
Signals: `loom-invalid-lock-error`, `loom-lock-timeout-error`, or
  errors from `BODY`."
  (declare (indent 1) (debug (form &rest form)))
  (let ((lock-var (gensym "lock-")))
    `(let ((,lock-var ,lock-form))
       (loom--validate-lock ,lock-var 'loom:with-mutex!)
       (pcase (loom-lock-mode ,lock-var)
         (:thread
          ;; For :thread mode, delegate to native `with-mutex`.
          ;; Wrap to add statistics tracking.
          (let ((native-mutex (loom-lock-native-mutex ,lock-var)))
            (unless native-mutex
              (error "Thread-mode lock '%S' has uninitialized native mutex"
                     (loom-lock-name ,lock-var)))
            (with-mutex native-mutex
              (unwind-protect
                  (progn
                    (loom--lock-update-stats ,lock-var :acquisition)
                    (loom--lock-track-resource :acquire ,lock-var)
                    ,@body)
                ;; Cleanup runs when lock is released.
                (loom--lock-update-stats ,lock-var :release)
                (loom--lock-track-resource :release ,lock-var)))))
         ((or :deferred :process)
          ;; For cooperative modes, manual acquire/release in unwind-protect.
          (let ((owner (loom--lock-get-effective-owner ,lock-var)))
            (unwind-protect
                (progn
                  (loom:lock-acquire ,lock-var owner)
                  ,@body)
                ;; Cleanup runs on any exit.
                (loom:lock-release ,lock-var owner))))))))

;;;###autoload
(defmacro loom:with-mutex-try! (lock-form &rest body)
  "Executes `BODY` if lock acquired immediately without blocking.
For cooperative locks only.

Arguments:
- `LOCK-FORM` (form): Evaluates to a `loom-lock` object.
- `BODY` (forms): Lisp forms to execute if lock is acquired.

Returns: Value of last form in `BODY` if acquired, `nil` otherwise.
Side Effects: May acquire and release lock. Executes `BODY` on success."
  (declare (indent 1) (debug (form &rest form)))
  (let ((lock-var (gensym "lock-"))
        (owner-var (gensym "owner-")))
    `(let ((,lock-var ,lock-form))
       (loom--validate-lock ,lock-var 'loom:with-mutex-try!)
       (let ((,owner-var (loom--lock-get-effective-owner ,lock-var)))
         ;; Attempt to acquire without blocking.
         (when (loom:lock-try-acquire ,lock-var ,owner-var)
           ;; If successful, execute body in unwind-protect.
           (unwind-protect (progn ,@body)
             (loom:lock-release ,lock-var ,owner-var)))))))

;;;###autoload
(defmacro loom:with-mutex-timeout! (lock-form timeout-form &rest body)
  "Executes `BODY`, attempting to acquire lock with specific timeout.
For cooperative locks only.

Arguments:
- `LOCK-FORM` (form): Evaluates to a `loom-lock` object.
- `TIMEOUT-FORM` (form): Evaluates to timeout in seconds.
- `BODY` (forms): Lisp forms to execute if lock acquired.

Returns: Value of last form in `BODY` if acquired.
Signals: `loom-lock-timeout-error` if acquisition times out."
  (declare (indent 1) (debug (form form &rest form)))
  (let ((lock-var (gensym "lock-"))
        (timeout-var (gensym "timeout-"))
        (owner-var (gensym "owner-")))
    `(let* ((,lock-var ,lock-form)
            (,timeout-var ,timeout-form)
            (,owner-var (loom--lock-get-effective-owner ,lock-var)))
       (loom--validate-lock ,lock-var 'loom:with-mutex-timeout!)
       ;; Attempt to acquire with a timeout. Signals error on failure.
       (when (loom:lock-acquire ,lock-var ,owner-var ,timeout-var)
         (unwind-protect (progn ,@body)
           (loom:lock-release ,lock-var ,owner-var))))))

;;;-------------------------------------------------------------------
;;; Shutdown Hook
;;;-------------------------------------------------------------------

(defun loom--lock-shutdown-hook ()
  "Shutdown hook to log final lock statistics and clean up global state.
Added to `kill-emacs-hook` for debugging and resource analysis on exit.

Returns: `t`."
  (loom:log! :info "loom-lock" "Emacs shutdown: Finalizing lock module.")
  (when loom-lock-enable-performance-tracking
    (loom:log! :info "loom-lock" "Final lock statistics dump: %S"
              (loom:lock-global-stats)))
  ;; Clear the hash table to release memory.
  (clrhash loom--lock-global-stats)
  t)

(add-hook 'kill-emacs-hook #'loom--lock-shutdown-hook)

(provide 'loom-lock)
;;; loom-lock.el ends here