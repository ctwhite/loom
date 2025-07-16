;;; loom-lock.el --- Mutual Exclusion Locks for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the `loom-lock` (mutex) primitive with comprehensive
;; support for Emacs's diverse concurrency models. It offers a unified
;; interface for thread-safe operations across cooperative and preemptive
;; environments.
;;
;; ## Key Features
;;
;; - **Cooperative Locks (`:deferred`, `:process`):** For single-threaded
;;   asynchronous operations or inter-process coordination. These are
;;   reentrant for the same owner with contention detection.
;;
;; - **Native Thread Locks (`:thread`):** For preemptive thread-safety using
;;   Emacs's native mutexes. Blocking, implicitly reentrant, and fully
;;   thread-safe.
;;
;; - **Timeout Support:** Configurable timeouts for lock acquisition to
;;   prevent indefinite blocking.
;;
;; - **Deadlock Detection:** Basic deadlock prevention through timeout
;;   mechanisms and dependency tracking.
;;
;; - **Non-Blocking Operations:** `try-acquire` variants for all modes with
;;   immediate failure on contention.
;;
;; - **Comprehensive Monitoring:** Resource tracking, performance metrics,
;;   and detailed logging integration.
;;
;; - **Graceful Degradation:** Automatic fallback to cooperative modes when
;;   native threading is unavailable.
;;
;; ## Usage Examples
;;
;;   ;; Basic usage
;;   (let ((lock (loom:lock "my-resource")))
;;     (loom:with-mutex! lock
;;       (message "Critical section")))
;;
;;   ;; Thread-safe mode
;;   (let ((lock (loom:lock "shared-data" :mode :thread)))
;;     (loom:with-mutex! lock
;;       (modify-shared-data)))
;;
;;   ;; Non-blocking attempt
;;   (let ((lock (loom:lock "optional-resource")))
;;     (loom:with-mutex-try! lock
;;       (message "Got the lock!")))
;;
;;   ;; Timeout-based acquisition
;;   (let ((lock (loom:lock "timeout-resource")))
;;     (loom:with-mutex-timeout! lock 5.0
;;       (message "Acquired within 5 seconds")))
;;

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'loom-log)
(require 'loom-errors)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization and Constants

(defcustom loom-lock-default-timeout 30.0
  "Default timeout in seconds for lock acquisition operations.
  A value of nil means no timeout (wait indefinitely)."
  :type '(choice (const :tag "No timeout" nil)
                 (number :tag "Timeout in seconds"))
  :group 'loom-lock)

(defcustom loom-lock-enable-deadlock-detection t
  "Enable basic deadlock detection mechanisms.
  When enabled, locks will track acquisition chains and detect
  simple circular dependencies."
  :type 'boolean
  :group 'loom-lock)

(defcustom loom-lock-enable-performance-tracking t
  "Enable performance tracking for lock operations.
  When enabled, collect timing statistics for lock acquisitions
  and releases."
  :type 'boolean
  :group 'loom-lock)

(defconst *loom-lock-supported-modes* '(:deferred :thread :process)
  "List of supported lock modes.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-invalid-lock-error
  "An operation was attempted on an invalid lock object."
  'loom-error)

(define-error 'loom-lock-unowned-release-error
  "Attempted to release a lock not owned by the caller."
  'loom-error)

(define-error 'loom-lock-unsupported-operation-error
  "An operation is not supported for the lock's mode."
  'loom-error)

(define-error 'loom-lock-contention-error
  "Attempted to acquire a lock already held by another owner."
  'loom-error)

(define-error 'loom-lock-double-release-error
  "Attempted to release a lock that is not currently held."
  'loom-error)

(define-error 'loom-lock-timeout-error
  "Lock acquisition timed out."
  'loom-error)

(define-error 'loom-lock-deadlock-error
  "Potential deadlock detected during lock acquisition."
  'loom-error)

(define-error 'loom-lock-invalid-mode-error
  "Invalid lock mode specified."
  'loom-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Statistics and Monitoring

(defvar loom--lock-global-stats
  (make-hash-table :test 'equal :weakness nil)
  "Global statistics for lock operations.")

(defun loom--lock-init-stats (lock)
  "Initialize statistics tracking for LOCK."
  (when loom-lock-enable-performance-tracking
    (puthash (loom-lock-name lock)
             (list :acquisitions 0
                   :releases 0
                   :contentions 0
                   :total-hold-time 0.0
                   :max-hold-time 0.0
                   :timeouts 0
                   :created (float-time))
             loom--lock-global-stats)))

(defun loom--lock-update-stats (lock stat-type &optional value)
  "Update statistics for LOCK with STAT-TYPE and optional VALUE."
  (when loom-lock-enable-performance-tracking
    (let ((stats (gethash (loom-lock-name lock) loom--lock-global-stats)))
      (when stats
        (pcase stat-type
          (:acquisition (cl-incf (plist-get stats :acquisitions)))
          (:release (cl-incf (plist-get stats :releases)))
          (:contention (cl-incf (plist-get stats :contentions)))
          (:timeout (cl-incf (plist-get stats :timeouts)))
          (:hold-time
           (when value
             (cl-incf (plist-get stats :total-hold-time) value)
             (setf (plist-get stats :max-hold-time)
                   (max (plist-get stats :max-hold-time) value)))))))))

;;;###autoload
(defun loom:lock-global-stats ()
  "Return global statistics for all lock operations.

  Returns:
  - (hash-table): A copy of the global statistics hash table.
    Keys are lock names, values are plists of stats."
  (copy-hash-table loom--lock-global-stats))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-lock (:constructor %%make-lock))
  "A mutual exclusion lock (mutex) with comprehensive concurrency support.

  Fields:
  - `name` (string): Descriptive name for debugging and logging.
  - `mode` (symbol): Operating mode: `:deferred`, `:thread`, or `:process`.
  - `locked-p` (boolean): Lock state for cooperative modes.
  - `native-mutex` (mutex): Underlying native mutex for `:thread` mode.
  - `owner` (any): Current lock owner identifier.
  - `reentrant-count` (integer): Nested acquisition count.
  - `creation-time` (float): Lock creation timestamp.
  - `last-acquired` (float): Last successful acquisition timestamp.
  - `last-released` (float): Last release timestamp.
  - `acquisition-timeout` (float): Timeout for acquisition operations.
  - `total-acquisitions` (integer): Total number of acquisitions.
  - `max-wait-time` (float): Maximum time spent waiting for acquisition.
  - `contention-count` (integer): Number of contention events.
  - `owner-stack` (list): Stack of owners for deadlock detection."
  (name "" :type string)
  (mode :deferred :type symbol)
  (locked-p nil :type boolean)
  (native-mutex nil)
  (owner nil)
  (reentrant-count 0 :type integer)
  (creation-time (float-time) :type float)
  (last-acquired nil :type (or null float))
  (last-released nil :type (or null float))
  (acquisition-timeout loom-lock-default-timeout :type (or null float))
  (total-acquisitions 0 :type integer)
  (max-wait-time 0.0 :type float)
  (contention-count 0 :type integer)
  (owner-stack nil :type list))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Utility Functions

(defun loom--validate-lock (lock function-name)
  "Validate LOCK object and signal error if invalid."
  (unless (loom-lock-p lock)
    (signal 'loom-invalid-lock-error
            (list (if (fboundp 'loom:make-error)
                      (loom:make-error
                       :type :loom-invalid-lock-error
                       :message (format "%S: Invalid lock object" function-name)
                       :data `(:lock ,lock :function ,function-name))
                    (format "%S: Invalid lock object: %S" function-name lock))))))

(defun loom--validate-lock-mode (mode)
  "Validate MODE is a supported lock mode."
  (unless (memq mode *loom-lock-supported-modes*)
    (signal 'loom-lock-invalid-mode-error
            (list (format "Invalid lock mode: %S. Supported modes: %S"
                          mode *loom-lock-supported-modes*)))))

(defun loom--validate-lock-name (name)
  "Validate and normalize a lock name."
  (cond
   ((null name) (format "lock-%S" (gensym)))
   ((stringp name) name)
   ((symbolp name) (symbol-name name))
   (t (format "%S" name))))

(defun loom--lock-get-effective-owner (lock &optional owner)
  "Return the effective owner for a lock operation.
  Defaults to `current-thread` for `:thread` mode or `t` for cooperative
  modes (representing the main Emacs process/thread)."
  (or owner
      (pcase (loom-lock-mode lock)
        (:thread (if (fboundp 'current-thread)
                     (current-thread)
                   (error "Threading support not available for current-thread")))
        ((or :deferred :process)
         ;; For cooperative modes, 't' generally represents the main loop.
         t))))

(defun loom--lock-signal-error (error-symbol message lock &optional data)
  "Signal a structured lock error with comprehensive information."
  (let ((error-data (append `(:lock-name ,(loom-lock-name lock)
                                         :lock-mode ,(loom-lock-mode lock)
                                         :lock-owner ,(loom-lock-owner lock)
                                         :timestamp ,(float-time))
                            data)))
    (signal error-symbol
            (list (if (fboundp 'loom:make-error)
                      (loom:make-error
                       :type (intern (concat ":" (symbol-name error-symbol)))
                       :message message
                       :data error-data)
                    (format "%s: %s" message error-data))))))

(defun loom--lock-check-threading-support ()
  "Check if threading support is available in the current Emacs build."
  (and (fboundp 'make-mutex)
       (fboundp 'current-thread)))

(defun loom--lock-detect-deadlock (lock owner)
  "Perform basic deadlock detection for LOCK and OWNER.
  Signals `loom-lock-deadlock-error` if a potential deadlock is found."
  (when loom-lock-enable-deadlock-detection
    ;; Simple check: if owner is already in the lock's owner-stack, it's a cycle.
    (when (memq owner (loom-lock-owner-stack lock))
      (loom--lock-signal-error
       'loom-lock-deadlock-error
       (format "Potential deadlock detected: %S already in owner stack %S"
               owner (loom-lock-owner-stack lock))
       lock
       `(:owner-stack ,(loom-lock-owner-stack lock) :current-owner ,owner)))))

(defun loom--lock-track-resource (action lock)
  "Track resource usage if tracking function is available."
  (when (and (fboundp 'loom-resource-tracking-function)
             (symbol-value 'loom-resource-tracking-function))
    (condition-case err
        (funcall (symbol-value 'loom-resource-tracking-function) action lock)
      (error
       (loom-log :warn (loom-lock-name lock) "Resource tracking failed: %S" err)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Lock Operations (Internal Helpers)

(defun loom--lock-acquire-cooperative (lock owner timeout)
  "Acquire a cooperative lock with timeout support.
  This function implements the cooperative locking logic, including
  reentrancy, contention detection, and polling with exponential backoff."
  (let ((start-time (float-time))
        (acquired-p nil)
        (sleep-interval 0.001)) ; Start with 1ms polling.

    (while (and (not acquired-p)
                (or (null timeout)
                    (< (- (float-time) start-time) timeout)))
      (cond
       ((not (loom-lock-locked-p lock))
        ;; Lock is free - acquire it.
        (setf (loom-lock-locked-p lock) t
              (loom-lock-owner lock) owner
              (loom-lock-reentrant-count lock) 1
              (loom-lock-last-acquired lock) (float-time))
        (cl-incf (loom-lock-total-acquisitions lock))
        (setq acquired-p t)
        (loom-log :debug (loom-lock-name lock)
                        "Cooperative lock acquired by %S" owner))

       ((equal (loom-lock-owner lock) owner)
        ;; Reentrant acquisition by same owner.
        (cl-incf (loom-lock-reentrant-count lock))
        (setq acquired-p t)
        (loom-log :debug (loom-lock-name lock)
                        "Cooperative lock re-entered (count: %d)"
                        (loom-lock-reentrant-count lock)))

       (t
        ;; Lock is held by someone else - wait or fail.
        (cl-incf (loom-lock-contention-count lock))
        (loom--lock-update-stats lock :contention)
        (when timeout
          (sit-for (min sleep-interval (- timeout (- (float-time) start-time))))
          (setq sleep-interval (min (* sleep-interval 1.5) 0.1)))))) ; Exponential backoff.

    ;; Check if we timed out.
    (unless acquired-p
      (loom--lock-update-stats lock :timeout)
      (loom--lock-signal-error
       'loom-lock-timeout-error
       (format "Lock acquisition timed out after %s seconds" timeout)
       lock
       `(:timeout ,timeout :owner ,owner)))

    ;; Update statistics and track resource if acquired.
    (when acquired-p
      (let ((wait-time (- (float-time) start-time)))
        (setf (loom-lock-max-wait-time lock)
              (max (loom-lock-max-wait-time lock) wait-time))
        (loom--lock-update-stats lock :acquisition)
        (loom--lock-track-resource :acquire lock)))

    acquired-p))

(defun loom--lock-release-cooperative (lock owner)
  "Release a cooperative lock.
  Decrements the reentrant count. The lock is only truly freed when the
  count reaches zero. Signals errors for unowned or double releases."
  (unless (loom-lock-locked-p lock)
    (loom--lock-signal-error
     'loom-lock-double-release-error
     (format "Cannot release lock %S: not currently held"
             (loom-lock-name lock))
     lock
     `(:owner ,owner)))

  (unless (equal (loom-lock-owner lock) owner)
    (loom--lock-signal-error
     'loom-lock-unowned-release-error
     (format "Cannot release lock %S owned by %S"
             (loom-lock-name lock) (loom-lock-owner lock))
     lock
     `(:current-owner ,(loom-lock-owner lock)
       :releasing-owner ,owner)))

  (cl-decf (loom-lock-reentrant-count lock))
  (setf (loom-lock-last-released lock) (float-time))

  (if (zerop (loom-lock-reentrant-count lock))
      (progn
        (setf (loom-lock-owner lock) nil
              (loom-lock-locked-p lock) nil)
        (loom-log :debug (loom-lock-name lock) "Cooperative lock freed"))
    (loom-log :debug (loom-lock-name lock)
                    "Cooperative lock count decremented to %d"
                    (loom-lock-reentrant-count lock)))

  (loom--lock-update-stats lock :release)
  (loom--lock-track-resource :release lock)
  t)

(defun loom--lock-update-thread-metadata (lock effective-owner action)
  "Update thread lock metadata after native operations.
  This function is called within `loom:with-mutex!` and `loom:lock-try-acquire`
  to keep the `loom-lock` struct's fields consistent with the native mutex."
  (when (loom-lock-native-mutex lock)
    (pcase action
      (:acquire
       (setf (loom-lock-owner lock) effective-owner
             (loom-lock-locked-p lock) t
             (loom-lock-reentrant-count lock)
             (if (fboundp 'mutex-count)
                 (mutex-count (loom-lock-native-mutex lock))
               1) ; Fallback if mutex-count is not available.
             (loom-lock-last-acquired lock) (float-time))
       (cl-incf (loom-lock-total-acquisitions lock))
       (loom-log :debug (loom-lock-name lock)
                       "Thread lock metadata updated (owner: %S, count: %d)"
                       effective-owner (loom-lock-reentrant-count lock)))
      (:release
       (setf (loom-lock-owner lock)
             (if (fboundp 'mutex-owner)
                 (mutex-owner (loom-lock-native-mutex lock))
               nil) ; Fallback if mutex-owner is not available.
             (loom-lock-locked-p lock)
             (if (fboundp 'mutex-count)
                 (not (zerop (mutex-count
                               (loom-lock-native-mutex lock))))
               nil) ; Fallback.
             (loom-lock-reentrant-count lock)
             (if (fboundp 'mutex-count)
                 (mutex-count (loom-lock-native-mutex lock))
               0) ; Fallback.
             (loom-lock-last-released lock) (float-time))
       (loom-log :debug (loom-lock-name lock)
                       "Thread lock metadata updated (count: %d)"
                       (loom-lock-reentrant-count lock))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:lock (&optional name &key (mode :deferred)
                             (timeout loom-lock-default-timeout))
  "Create a new lock object (mutex) with comprehensive concurrency support.

  The lock's behavior depends on its MODE:
  - `:deferred`: Cooperative, non-blocking, reentrant lock for single-threaded
    asynchronous operations. Contention from different owners signals an error.
  - `:thread`: Native OS thread mutex providing preemptive thread-safety.
    Blocking and implicitly reentrant.
  - `:process`: Cooperative, non-blocking, reentrant lock for inter-process
    coordination. Similar to `:deferred` but indicates inter-process usage.

  Arguments:
  - NAME (string): Descriptive name for debugging and logging.
  - :MODE (symbol): Lock mode. Defaults to `:deferred`.
  - :TIMEOUT (float): Default timeout for acquisition operations.

  Returns:
  - (loom-lock): A new lock object.

  Signals:
  - `loom-lock-invalid-mode-error` for invalid modes.
  - `error` if `:thread` mode is requested but thread support is unavailable."
  (loom--validate-lock-mode mode)

  ;; Auto-fallback from :thread to :deferred if threading unavailable.
  (let ((effective-mode mode))
    (when (and (eq mode :thread) (not (loom--lock-check-threading-support)))
      (setq effective-mode :deferred)
      (loom-log :warn (loom--validate-lock-name name)
                      "Threading unavailable, falling back to :deferred mode"))

    (let* ((lock-name (loom--validate-lock-name name))
          (new-lock
            (pcase effective-mode
              (:thread
              (%%make-lock :name lock-name
                            :mode :thread
                            :native-mutex (make-mutex lock-name)
                            :acquisition-timeout timeout))
              ((or :deferred :process)
              (%%make-lock :name lock-name
                            :mode effective-mode
                            :acquisition-timeout timeout)))))

      (loom--lock-init-stats new-lock)
      (loom-log :info lock-name "Lock created (mode: %s, timeout: %s)"
                      effective-mode timeout)
      new-lock)))

;;;###autoload
(defun loom:lock-acquire (lock &optional owner timeout)
  "Acquire LOCK with optional timeout support.

  This function is primarily for cooperative locks. For thread locks,
  prefer `loom:with-mutex!` for automatic resource management.

  Arguments:
  - LOCK (loom-lock): The lock object to acquire.
  - OWNER (any): Owner identifier. Defaults to effective owner.
  - TIMEOUT (float): Timeout in seconds. Defaults to lock's default timeout.

  Returns:
  - t if the lock was successfully acquired.

  Signals:
  - `loom-invalid-lock-error` if LOCK is invalid.
  - `loom-lock-timeout-error` if acquisition times out.
  - `loom-lock-contention-error` for cooperative lock contention."
  (loom--validate-lock lock 'loom:lock-acquire)
  (let ((effective-owner (loom--lock-get-effective-owner lock owner))
        (effective-timeout (or timeout (loom-lock-acquisition-timeout lock))))

    (loom--lock-detect-deadlock lock effective-owner)

    (pcase (loom-lock-mode lock)
      (:thread
       (loom-log :warn (loom-lock-name lock)
                       "Direct acquire discouraged for :thread locks. Use loom:with-mutex!")
       (error "loom:lock-acquire not recommended for :thread locks. Use loom:with-mutex! instead"))
      ((or :deferred :process)
       (loom--lock-acquire-cooperative lock effective-owner effective-timeout)))))

;;;###autoload
(defun loom:lock-try-acquire (lock &optional owner)
  "Attempt non-blocking acquisition of LOCK.

  This operation is supported for all lock modes and will return
  immediately with success/failure indication.

  Arguments:
  - LOCK (loom-lock): The lock object.
  - OWNER (any): Owner identifier. Defaults to effective owner.

  Returns:
  - t if the lock was acquired, nil if it was already held.

  Signals:
  - `loom-invalid-lock-error` if LOCK is invalid.
  - `loom-lock-unsupported-operation-error` - try-acquire is unavailable
    for `:thread` mode."
  (loom--validate-lock lock 'loom:lock-try-acquire)

  (cl-block loom:lock-try-acquire
    (let ((effective-owner (loom--lock-get-effective-owner lock owner)))
      (pcase (loom-lock-mode lock)
        (:thread
        (when (null (loom-lock-native-mutex lock))
          (loom--lock-signal-error
            'loom-invalid-lock-error
            (format "Thread-mode lock '%s' has no native-mutex" (loom-lock-name lock))
            lock)
          (cl-return-from loom:lock-try-acquire nil)) ; Should not happen if lock is properly initialized.

        (loom-log :warning (loom-lock-name lock)
                          "try-acquire is not available for :thread locks, "
                          "try-acquire is unsupported.")
        (loom--lock-signal-error
          'loom-lock-unsupported-operation-error
          "try-acquire not supported for :thread mode without mutex-trylock"
          lock)
        (cl-return-from loom:lock-try-acquire nil))

        ((or :deferred :process)
        (if (not (loom-lock-locked-p lock))
            (progn
              (setf (loom-lock-locked-p lock) t
                    (loom-lock-owner lock) effective-owner
                    (loom-lock-reentrant-count lock) 1
                    (loom-lock-last-acquired lock) (float-time))
              (cl-incf (loom-lock-total-acquisitions lock))
              (loom--lock-update-stats lock :acquisition)
              (loom--lock-track-resource :acquire lock)
              (loom-log :debug (loom-lock-name lock)
                              "Cooperative lock try-acquired by %S" effective-owner)
              t)
          (loom-log :debug (loom-lock-name lock)
                          "Lock try-acquire failed: held by %S"
                          (loom-lock-owner lock))
          nil))))))

;;;###autoload
(defun loom:lock-release (lock &optional owner)
  "Release LOCK. Must be called by the current owner.

  For cooperative locks, releases are counted - the lock is freed
  when the reentrant count reaches zero.

  Arguments:
  - LOCK (loom-lock): The lock object to release.
  - OWNER (any): Owner identifier. Must match the current owner.

  Returns:
  - t if the release was successful.

  Signals:
  - `loom-invalid-lock-error` if LOCK is invalid.
  - `loom-lock-unowned-release-error` if OWNER doesn't hold the lock.
  - `loom-lock-double-release-error` if the lock is not held."
  (loom--validate-lock lock 'loom:lock-release)
  (let ((effective-owner (loom--lock-get-effective-owner lock owner)))

    (pcase (loom-lock-mode lock)
      (:thread
       (loom-log :warn (loom-lock-name lock)
                       "Direct release discouraged for :thread locks. Use loom:with-mutex!")
       (error "loom:lock-release not recommended for :thread locks. Use loom:with-mutex! instead"))
      ((or :deferred :process)
       (loom--lock-release-cooperative lock effective-owner)))))

;;;###autoload
(defun loom:lock-owned-p (lock &optional owner)
  "Check if LOCK is owned by OWNER.

  Arguments:
  - LOCK (loom-lock): The lock object to check.
  - OWNER (any): The owner to check. Uses effective owner if nil.

  Returns:
  - t if the lock is owned by the specified owner, nil otherwise.

  Signals:
  - `loom-invalid-lock-error` if LOCK is invalid."
  (loom--validate-lock lock 'loom:lock-owned-p)
  (let ((effective-owner (loom--lock-get-effective-owner lock owner)))
    (pcase (loom-lock-mode lock)
      (:thread
       (and (loom-lock-native-mutex lock)
            (if (fboundp 'mutex-owner)
                (equal (mutex-owner (loom-lock-native-mutex lock)) effective-owner)
              ;; Fallback if mutex-owner is not available.
              (equal (loom-lock-owner lock) effective-owner))))
      ((or :deferred :process)
       (equal (loom-lock-owner lock) effective-owner)))))

;;;###autoload
(defun loom:lock-held-p (lock)
  "Check if LOCK is currently held by any owner.

  Arguments:
  - LOCK (loom-lock): The lock object to check.

  Returns:
  - t if the lock is held, nil otherwise.

  Signals:
  - `loom-invalid-lock-error` if LOCK is invalid."
  (loom--validate-lock lock 'loom:lock-held-p)
  (pcase (loom-lock-mode lock)
    (:thread
     (and (loom-lock-native-mutex lock)
          (if (fboundp 'mutex-count)
              (> (mutex-count (loom-lock-native-mutex lock)) 0)
            ;; Fallback if mutex-count is not available.
            (loom-lock-locked-p lock))))
    ((or :deferred :process)
     (loom-lock-locked-p lock))))

;;;###autoload
(defun loom:lock-stats (lock)
  "Return comprehensive statistics for LOCK.

  Arguments:
  - LOCK (loom-lock): The lock object.

  Returns:
  - (plist): Statistics including acquisition count, contention, timing, etc.

  Signals:
  - `loom-invalid-lock-error` if LOCK is invalid."
  (loom--validate-lock lock 'loom:lock-stats)
  (let ((stats (gethash (loom-lock-name lock) loom--lock-global-stats)))
    (unless stats
      (loom-log :warn (loom-lock-name lock)
                      "No statistics found for lock %S" (loom-lock-name lock))
      (setq stats (list :acquisitions 0 :releases 0 :contentions 0
                        :total-hold-time 0.0 :max-hold-time 0.0 :timeouts 0
                        :created (float-time) :not-tracked t)))
    ;; Add current state to stats for real-time view.
    (append stats
            (list :current-mode (loom-lock-mode lock)
                  :current-locked-p (loom:lock-held-p lock)
                  :current-owner (loom-lock-owner lock)
                  :current-reentrant-count (loom-lock-reentrant-count lock)))))

;;;###autoload
(defmacro loom:with-mutex! (lock-form &rest body)
  "Execute BODY within a critical section guarded by the lock.
  This macro ensures the lock is always released, even if an error occurs
  within the BODY. It uses blocking acquire for `:thread` locks and provides
  comprehensive error handling and resource management.

  Arguments:
  - `LOCK-FORM` (form): A form that evaluates to a `loom-lock` object.
  - `BODY` (forms): The Lisp forms to execute while holding the lock.

  Returns:
  - The value of the last form in `BODY`.

  Signals:
  - `loom-invalid-lock-error` if LOCK-FORM doesn't evaluate to a valid lock.
  - `loom-lock-timeout-error` if acquisition times out.
  - `loom-lock-contention-error` for cooperative lock contention.
  - Any errors from `BODY` are propagated after proper cleanup.

  Side Effects:
  - Acquires and releases the lock with proper resource tracking.
  - Updates lock statistics and maintains deadlock detection state.
  - Logs debug information when enabled."
  (declare (indent 1) (debug (form body)))
  (let ((lock-var (gensym "lock-")))
    `(let ((,lock-var ,lock-form))
       (loom--validate-lock ,lock-var 'loom:with-mutex!)
       (pcase (loom-lock-mode ,lock-var)
         (:thread
          ;; Delegate to the optimized thread-specific macro.
          (loom:with-thread-mutex! ,lock-var ,@body))
         ((or :deferred :process)
          ;; Delegate to the optimized cooperative-specific macro.
          (loom:with-cooperative-mutex! ,lock-var ,@body))
         (_
          (error "Unsupported lock mode for loom:with-mutex!: %S"
                 (loom-lock-mode ,lock-var)))))))

;;;###autoload
(defmacro loom:with-mutex-try! (lock-form &rest body)
  "Execute BODY within a critical section if the lock can be acquired.
  This macro uses non-blocking acquisition and only executes BODY if the
  lock was successfully acquired.

  Arguments:
  - `LOCK-FORM` (form): A form that evaluates to a `loom-lock` object.
  - `BODY` (forms): The Lisp forms to execute while holding the lock.

  Returns:
  - The value of the last form in `BODY` if the lock was acquired, `nil`
    otherwise.

  Side Effects:
  - Attempts to acquire and release the lock. Executes `BODY` forms if
    successful."
  (declare (indent 1) (debug (form &rest form)))
  (let ((lock-var (gensym "lock-"))
        (acquired-var (gensym "acquired-"))
        (start-time-var (gensym "start-time-"))
        (owner-var (gensym "owner-")))
    `(let ((,lock-var ,lock-form)
           (,acquired-var nil))
       (loom--validate-lock ,lock-var 'loom:with-mutex-try!)
       (let ((,start-time-var (float-time))
             (,owner-var (loom--lock-get-effective-owner ,lock-var)))
         (unwind-protect
             (when (setq ,acquired-var (loom:lock-try-acquire ,lock-var ,owner-var))
               ;; Push owner to stack for deadlock detection.
               (when loom-lock-enable-deadlock-detection
                 (push ,owner-var (loom-lock-owner-stack ,lock-var)))
               (progn ,@body))
           (when ,acquired-var
             ;; Pop owner from stack.
             (when loom-lock-enable-deadlock-detection
               (pop (loom-lock-owner-stack ,lock-var)))
             (loom:lock-release ,lock-var ,owner-var)
             ;; Update hold time stats.
             (loom--lock-update-stats ,lock-var :hold-time
                                      (- (float-time) ,start-time-var))))
         ,acquired-var)))) ; Return acquired-var for the macro's result.

;;;###autoload
(defmacro loom:with-mutex-timeout! (lock-form timeout-form &rest body)
  "Execute BODY within a critical section, attempting to acquire the lock
  with a specified timeout.

  Arguments:
  - `LOCK-FORM` (form): A form that evaluates to a `loom-lock` object.
  - `TIMEOUT-FORM` (form): A form that evaluates to the timeout in seconds.
  - `BODY` (forms): The Lisp forms to execute while holding the lock.

  Returns:
  - The value of the last form in `BODY` if the lock was acquired, `nil`
    if the acquisition timed out.

  Signals:
  - `loom-lock-timeout-error` if the timeout is reached (unless handled
    by the caller).
  - Other errors from `loom:lock-acquire` or `BODY`."
  (declare (indent 1) (debug form form &rest form))
  (let ((lock-var (gensym "lock-"))
        (timeout-var (gensym "timeout-"))
        (acquired-var (gensym "acquired-"))
        (start-time-var (gensym "start-time-"))
        (owner-var (gensym "owner-")))
    `(let* ((,lock-var ,lock-form)
            (,timeout-var ,timeout-form)
            (,acquired-var nil))
       (loom--validate-lock ,lock-var 'loom:with-mutex-timeout!)
       (let ((,start-time-var (float-time))
             (,owner-var (loom--lock-get-effective-owner ,lock-var)))
         (unwind-protect
             (progn
               (setq ,acquired-var
                     (condition-case err
                         (progn
                           (loom:lock-acquire ,lock-var ,owner-var ,timeout-var)
                           t)
                       (loom-lock-timeout-error ; Catch timeout specifically.
                        (loom-log :info (loom-lock-name ,lock-var)
                                        "Lock acquisition timed out for with-mutex-timeout!")
                        nil)
                       (error ; Re-signal other errors.
                        (signal (car err) (cdr err)))))
               (when ,acquired-var
                 ;; Push owner to stack for deadlock detection.
                 (when loom-lock-enable-deadlock-detection
                   (push ,owner-var (loom-lock-owner-stack ,lock-var)))
                 (progn ,@body)))
           (when ,acquired-var
             ;; Pop owner from stack.
             (when loom-lock-enable-deadlock-detection
               (pop (loom-lock-owner-stack ,lock-var)))
             (loom:lock-release ,lock-var ,owner-var) ; Call cooperative release.
             ;; Update hold time stats.
             (loom--lock-update-stats ,lock-var :hold-time
                                      (- (float-time) ,start-time-var))))
         ,acquired-var)))) ; Return acquired status.

;;;###autoload
(defmacro loom:with-thread-mutex! (lock-form &rest body)
  "Optimized version specifically for thread-mode locks.
  Executes BODY within a critical section guarded by a native mutex.
  This macro ensures proper acquisition, release, and metadata updates.

  Arguments:
  - `LOCK-FORM` (form): A form that evaluates to a `loom-lock` object
    in `:thread` mode.
  - `BODY` (forms): The Lisp forms to execute while holding the lock.

  Returns:
  - The value of the last form in `BODY`.

  Signals:
  - `error` if the lock is not in `:thread` mode or lacks a native mutex."
  (declare (indent 1) (debug (form &rest form)))
  (let ((lock-var (gensym "lock-"))
        (start-time-var (gensym "start-time-"))
        (owner-var (gensym "owner-")))
    `(let* ((,lock-var ,lock-form)
            (,start-time-var (float-time))
            (,owner-var (loom--lock-get-effective-owner ,lock-var)))
       (loom--validate-lock ,lock-var 'loom:with-thread-mutex!)
       (unless (eq (loom-lock-mode ,lock-var) :thread)
         (error "loom:with-thread-mutex! requires :thread mode lock, got: %S"
                (loom-lock-mode ,lock-var)))

       (let ((native-mutex (loom-lock-native-mutex ,lock-var)))
         (unless native-mutex
           (error "Thread-mode lock '%S' has no native-mutex."
                  (loom-lock-name ,lock-var)))

         (loom-log :debug (loom-lock-name ,lock-var)
                         "Acquiring native mutex for :thread mode.")
         (with-mutex native-mutex
           ;; Update loom-lock's metadata after native acquisition.
           (loom--lock-update-thread-metadata ,lock-var ,owner-var :acquire)
           ;; Track resource acquisition while lock is held.
           (loom--lock-track-resource :acquire ,lock-var)
           ;; Push owner to stack for deadlock detection.
           (when loom-lock-enable-deadlock-detection
             (push ,owner-var (loom-lock-owner-stack ,lock-var)))
           ;; Execute user's body.
           (unwind-protect
               (progn ,@body)
             ;; Pop owner from stack.
             (when loom-lock-enable-deadlock-detection
               (pop (loom-lock-owner-stack ,lock-var)))
             ;; Track resource release before native release.
             (loom--lock-track-resource :release ,lock-var)
             ;; Update loom-lock's metadata after native release.
             (loom--lock-update-thread-metadata ,lock-var nil :release)
             ;; Update hold time stats.
             (loom--lock-update-stats ,lock-var :hold-time
                                      (- (float-time) ,start-time-var))))))))

;;;###autoload
(defmacro loom:with-cooperative-mutex! (lock-form &rest body)
  "Optimized version specifically for cooperative locks.
Executes BODY within a critical section guarded by a cooperative lock.
This macro ensures proper acquisition, release, and metadata updates.

Arguments:
- `LOCK-FORM` (form): A form that evaluates to a `loom-lock` object
  in `:deferred` or `:process` mode.
- `BODY` (forms): The Lisp forms to execute while holding the lock.

Returns:
- The value of the last form in `BODY`.

Signals:
- `error` if the lock is not in a cooperative mode.
- Errors from `loom:lock-acquire` or `loom:lock-release`."
  (declare (indent 1) (debug (form body)))
  (let ((lock-var (gensym "lock-"))
        (start-time-var (gensym "start-time-"))
        (owner-var (gensym "owner-")))
    `(let* ((,lock-var ,lock-form)
            (,start-time-var (float-time))
            (,owner-var (loom--lock-get-effective-owner ,lock-var)))
       (loom--validate-lock ,lock-var 'loom:with-cooperative-mutex!)
       (unless (memq (loom-lock-mode ,lock-var) '(:deferred :process))
         (error "loom:with-cooperative-mutex! requires cooperative mode lock, got: %S"
                (loom-lock-mode ,lock-var)))

       (loom-log :debug (loom-lock-name ,lock-var)
                 "Acquiring cooperative lock via with-cooperative-mutex!.")
       (unwind-protect
           (progn
             (loom:lock-acquire ,lock-var ,owner-var) ; Call cooperative acquire.
             ;; Track resource acquisition while lock is held.
             (loom--lock-track-resource :acquire ,lock-var)
             ;; Push owner to stack for deadlock detection.
             (when loom-lock-enable-deadlock-detection
               (push ,owner-var (loom-lock-owner-stack ,lock-var)))
             ,@body)
         ;; Pop owner from stack.
         (when loom-lock-enable-deadlock-detection
           (pop (loom-lock-owner-stack ,lock-var)))
         ;; Track resource release before releasing the lock.
         (loom--lock-track-resource :release ,lock-var)
         (loom:lock-release ,lock-var ,owner-var) ; Call cooperative release.
         ;; Update hold time stats.
         (loom--lock-update-stats ,lock-var :hold-time
                                  (- (float-time) ,start-time-var))))))
                                  
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shutdown Hook

(defun loom--lock-shutdown-hook ()
  "Shutdown hook to ensure clean termination and reporting for locks."
  (loom-log :info "Global" "Emacs shutdown: Lock module cleanup.")
  (loom-log :info "Global" "Final lock stats: %S" (loom:lock-global-stats))
  (clrhash loom--lock-global-stats) ; Clear stats on shutdown.
  t)

;; Register shutdown hook
(add-hook 'kill-emacs-hook #'loom--lock-shutdown-hook)

(provide 'loom-lock)
;;; loom-lock.el ends here