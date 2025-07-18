;;; loom-poll.el --- Generic Thread-Based Cooperative Polling -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides a robust framework for two distinct but related
;; concurrency patterns: main-thread cooperative polling and background
;; periodic task execution.
;;
;; ## Design Philosophy
;;
;; 1. **Main-Thread Cooperative Polling:**
;;    The `loom:poll-with-backoff` function provides a way to perform a
;;    blocking wait on the main thread without freezing the UI. It works
;;    by repeatedly checking a condition and yielding control via `sit-for`,
;;    allowing Emacs to process I/O and user input. Enhanced with timeout
;;    controls and exponential backoff for efficiency.
;;
;; 2. **Background Scheduler Thread:**
;;    A dedicated background thread runs a registry of tasks at regular
;;    intervals. This is ideal for lightweight, recurring background jobs,
;;    such as checking statuses or notifying other threads. Enhanced with
;;    graceful shutdown, robust error handling, and performance monitoring.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'loom-log)
(require 'loom-lock)
(require 'loom-errors)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-poll-default-interval 0.01
  "Default polling interval (seconds) for the scheduler thread."
  :type 'float
  :group 'loom)

(defcustom loom-poll-max-interval 1.0
  "Maximum polling interval (seconds) for exponential backoff."
  :type 'float
  :group 'loom)

(defcustom loom-poll-backoff-multiplier 1.5
  "Multiplier for exponential backoff in cooperative polling."
  :type 'float
  :group 'loom)

(defcustom loom-poll-max-task-errors 10
  "Max consecutive errors for a periodic task before it's removed.
Set to 0 or a negative value to disable automatic removal."
  :type 'integer
  :group 'loom)

(defcustom loom-poll-shutdown-timeout 5.0
  "Maximum time (seconds) to wait for graceful thread shutdown."
  :type 'float
  :group 'loom)

(defcustom loom-poll-cooperative-default-timeout 30.0
  "Default timeout (seconds) for cooperative polling operations."
  :type 'float
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-poll-error
  "A generic error in the thread polling module."
  'loom-error)

(define-error 'loom-poll-invalid-argument
  "An invalid argument was provided to a polling function."
  'loom-poll-error)

(define-error 'loom-poll-scheduler-start-error
  "Failed to start the background scheduler thread."
  'loom-poll-error)

(define-error 'loom-poll-timeout
  "A polling operation timed out."
  'loom-poll-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State for Scheduler Thread

(defvar loom--scheduler-thread-running nil
  "Flag to control the running state of `loom--scheduler-thread`.")

(defvar loom--scheduler-thread nil
  "The dedicated thread for executing periodic tasks.")

(defvar loom--periodic-tasks-mutex nil
  "A mutex to protect `loom--periodic-tasks-registry` access.")

(defvar loom--periodic-tasks-registry (make-hash-table :test 'eq)
  "A thread-safe registry for periodic tasks.")

(defvar loom--scheduler-startup-time nil
  "Timestamp (`current-time`) of scheduler thread startup.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Scheduler Thread Logic

(defun loom--update-task-stats (task-info success-p error)
  "Update statistics for a periodic task after execution.

Arguments:
- `TASK-INFO` (plist): The task's metadata plist to update.
- `SUCCESS-P` (boolean): Whether the task succeeded.
- `ERROR` (any): The error object if the task failed, otherwise nil.

Returns:
- (plist): The updated `TASK-INFO` plist.

Side Effects:
- Modifies the `task-info` plist in place."
  (plist-put task-info :last-run-time (current-time))
  (plist-put task-info :total-runs
             (1+ (or (plist-get task-info :total-runs) 0)))
  (if success-p
      (progn
        (when (> (or (plist-get task-info :error-count) 0) 0)
          (plist-put task-info :error-count 0)
          (plist-put task-info :last-error nil)))
    (plist-put task-info :error-count
               (1+ (or (plist-get task-info :error-count) 0)))
    (plist-put task-info :last-error error)
    (plist-put task-info :total-errors
               (1+ (or (plist-get task-info :total-errors) 0))))
  task-info)

(defun loom--execute-periodic-task (id task-info)
  "Execute a single periodic task with robust error handling.
This is called from within the scheduler thread's loop.

Arguments:
- `ID` (any): The unique identifier of the task.
- `TASK-INFO` (plist): The task's metadata plist.

Returns:
- `t` on success, `nil` on error.

Side Effects:
- Executes the task function.
- Updates task statistics.
- May remove the task from the registry if it exceeds the error threshold."
  (condition-case err
      (progn
        (funcall (plist-get task-info :function))
        (loom--update-task-stats task-info t nil)
        t)
    (error
     (loom--update-task-stats task-info nil err)
     (let ((new-error-count (plist-get task-info :error-count)))
       (loom-log :error id "Error in periodic task (ID: %S, error #%d): %S"
                 id new-error-count err)
       (when (and (> loom-poll-max-task-errors 0)
                  (>= new-error-count loom-poll-max-task-errors))
         (loom-log :warn id "Removing task %S after %d errors."
                   id new-error-count)
         (remhash id loom--periodic-tasks-registry)))
     nil)))

(defun loom-poll-scheduler-loop ()
  "The main loop for the dedicated scheduler thread.
This loop wakes periodically to execute all registered tasks and terminates
gracefully when `loom--scheduler-thread-running` becomes nil."
  (loom-log :info nil "Enhanced scheduler thread started.")
  (setq loom--scheduler-startup-time (current-time))

  ;; Use a named block to allow for an explicit and immediate exit
  ;; from anywhere inside the loop when the shutdown flag is set.
  (cl-block scheduler-loop
    (while loom--scheduler-thread-running
      (condition-case err
          (when (loom-lock-p loom--periodic-tasks-mutex)
            (loom:with-mutex! loom--periodic-tasks-mutex
              (let ((task-ids (hash-table-keys loom--periodic-tasks-registry)))
                (dolist (id task-ids)
                  ;; If a shutdown is requested, exit the entire function.
                  (unless loom--scheduler-thread-running
                    (cl-return-from scheduler-loop nil))
                  (when-let ((task-info
                              (gethash id loom--periodic-tasks-registry)))
                    (loom--execute-periodic-task id task-info))))))
        (error (loom-log :error nil "Error in scheduler loop: %S" err)))

      ;; Sleep only if the loop is still meant to be running.
      (when loom--scheduler-thread-running
        (sleep-for loom-poll-default-interval))))

  (loom-log :info nil "Scheduler thread stopped gracefully."))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Enhanced Cooperative Polling

(defun loom--calculate-backoff-interval (current-interval)
  "Calculate the next backoff interval using exponential backoff.

Arguments:
- `CURRENT-INTERVAL` (float): The current polling interval.

Returns:
- (float): The new interval, capped at `loom-poll-max-interval`."
  (min loom-poll-max-interval
       (* current-interval loom-poll-backoff-multiplier)))

;;;###autoload
(cl-defun loom:poll-with-backoff (condition-fn &key work-fn poll-interval
                                            debug-id max-iterations timeout)
  "Execute a cooperative polling loop with exponential backoff and timeout.
This function repeatedly calls `WORK-FN` and yields for `POLL-INTERVAL`
seconds until `CONDITION-FN` returns non-nil.

Arguments:
- `CONDITION-FN` (function): Returns non-nil to terminate the loop.
- `:WORK-FN` (function, optional): Executed in each iteration.
- `:POLL-INTERVAL` (float, optional): Initial yield duration.
- `:DEBUG-ID` (any, optional): Identifier for logging.
- `:MAX-ITERATIONS` (integer, optional): Iteration limit.
- `:TIMEOUT` (float, optional): Maximum time to wait in seconds.

Returns:
- The final value from `CONDITION-FN`.

Signals:
- `loom-poll-invalid-argument`: If arguments are invalid.
- `loom-poll-timeout`: If the operation times out."
  (let ((work-fn (or work-fn (lambda () nil)))
        (poll-interval (or poll-interval
                           loom-poll-default-interval))
        (timeout (or timeout
                     loom-poll-cooperative-default-timeout))
        (start-time (current-time)))

    (unless (functionp condition-fn)
      (signal 'loom-poll-invalid-argument
              '("CONDITION-FN not a function")))
    (unless (functionp work-fn)
      (signal 'loom-poll-invalid-argument
              '("WORK-FN not a function")))
    (unless (and (numberp poll-interval) (> poll-interval 0))
      (signal 'loom-poll-invalid-argument
              '("POLL-INTERVAL not positive")))
    (when (and max-iterations
               (not (and (integerp max-iterations) (> max-iterations 0))))
      (signal 'loom-poll-invalid-argument
              '("MAX-ITERATIONS not positive")))
    (unless (and (numberp timeout) (> timeout 0))
      (signal 'loom-poll-invalid-argument
              '("TIMEOUT not positive")))

    (loom-log :debug debug-id "Starting cooperative poll (timeout: %.1fs)"
              timeout)
    (let (iteration result (current-interval poll-interval))
      (while (and (not (setq result (funcall condition-fn)))
                  (or (null max-iterations)
                      (< (or iteration 0) max-iterations)))
        (if (> (float-time (time-subtract (current-time) start-time)) timeout)
            (signal 'loom-poll-timeout
                    (list (format "Polling timed out for %S" debug-id)))
          (condition-case err (funcall work-fn)
            (error (loom-log :error debug-id "Error in work-fn: %S" err)))
          (sit-for current-interval)
          (setq current-interval
                (loom--calculate-backoff-interval current-interval))
          (setq iteration (1+ (or iteration 0)))))
      result)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Enhanced Scheduler Management

;;;###autoload
(defun loom:poll-ensure-scheduler-thread ()
  "Ensure the background scheduler thread is running. Idempotent.

Returns:
- `t` if the thread is running or was started successfully.
- `nil` on failure.

Signals:
- `loom-poll-scheduler-start-error`: On failure to start the thread.

Side Effects:
- May create a new thread and initialize the periodic tasks mutex."
  (if (and loom--scheduler-thread (thread-live-p loom--scheduler-thread))
      t
    (condition-case err
        (progn
          (loom-log :info nil "Starting enhanced scheduler thread.")
          (unless (loom-lock-p loom--periodic-tasks-mutex)
            (setq loom--periodic-tasks-mutex
                  (loom:lock "periodic-tasks-mutex")))
          (setq loom--scheduler-thread-running t)
          (setq loom--scheduler-thread
                (make-thread #'loom-poll-scheduler-loop
                             "loom-enhanced-scheduler"))
          (sleep-for 0.001) ; Brief pause for initialization.
          (unless (thread-live-p loom--scheduler-thread)
            (error "Thread creation failed silently."))
          t)
      (error
       (loom-log :error nil "Failed to start scheduler thread: %S" err)
       (setq loom--scheduler-thread-running nil)
       (signal 'loom-poll-scheduler-start-error (list err))
       nil))))

;;;###autoload
(defun loom:poll-stop-scheduler-thread ()
  "Initiate a graceful, NON-BLOCKING shutdown of the scheduler thread.
This function only signals the thread to stop on its next iteration.
It does NOT wait for the thread to terminate. To wait, use
`loom:poll-join-scheduler-thread`.

Returns:
- `t` if a shutdown was signaled, `nil` if the thread was not running."
  (when (and loom--scheduler-thread (thread-live-p loom--scheduler-thread))
    (loom-log :info nil "Signaling scheduler thread to stop.")
    (setq loom--scheduler-thread-running nil)
    t))

;;;###autoload
(defun loom:poll-join-scheduler-thread (&optional timeout)
  "Cooperatively wait for the scheduler thread to terminate.
This function BLOCKS the current Lisp evaluation but keeps the Emacs UI
responsive by using a cooperative poll (`sit-for`). It does NOT use the
native `thread-join` primitive, which would freeze the entire UI.

This function should be used with caution, typically only in scripts or
during shutdown sequences where blocking is acceptable. For a completely
non-blocking approach, use `loom:poll-stop-scheduler-thread`
and check the thread's status separately.

Arguments:
- `TIMEOUT` (number, optional): Max seconds to wait. Defaults to
  `loom-poll-shutdown-timeout`.

Returns:
- `t` if the thread terminated, `nil` on timeout or if not running."
  (let ((effective-timeout (or timeout loom-poll-shutdown-timeout)))
    (if (or (null loom--scheduler-thread)
            (not (thread-live-p loom--scheduler-thread)))
        t ; Already stopped
      (condition-case nil
          (loom:poll-with-backoff
           (lambda () (not (thread-live-p loom--scheduler-thread)))
           :debug-id 'scheduler-join
           :timeout effective-timeout)
        (loom-poll-timeout nil)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Enhanced Task Management

;;;###autoload
(defun loom:poll-register-periodic-task (id task-fn)
  "Register a function to be run periodically by the scheduler.
If a task with `ID` already exists, it will be overwritten.

Arguments:
- `ID` (any): A unique identifier for the task (e.g., a symbol).
- `TASK-FN` (function): A no-argument function to call periodically.

Returns:
- `t` on success.

Signals:
- `loom-poll-invalid-argument`: If `TASK-FN` is not a function."
  (unless (functionp task-fn)
    (signal 'loom-poll-invalid-argument
            '("TASK-FN must be a function")))

  (when (loom:poll-ensure-scheduler-thread)
    (loom:with-mutex! loom--periodic-tasks-mutex
      (when (gethash id loom--periodic-tasks-registry)
        (loom-log :warn id "Overwriting existing periodic task '%S'." id))
      (puthash id `(:function ,task-fn :error-count 0 :total-runs 0
                               :total-errors 0 :created-time ,(current-time))
               loom--periodic-tasks-registry))
    (loom-log :debug id "Registered periodic task with enhanced tracking.")
    t))

;;;###autoload
(defun loom:poll-unregister-periodic-task (id)
  "Unregister a periodic task by its `ID`.

Arguments:
- `ID` (any): The unique identifier of the task to unregister.

Returns:
- `t` if task was found and removed, `nil` otherwise."
  (if (not (loom-lock-p loom--periodic-tasks-mutex))
      nil
    (loom:with-mutex! loom--periodic-tasks-mutex
      (when (remhash id loom--periodic-tasks-registry)
        (loom-log :debug id "Unregistered periodic task.")
        t))))

;;;###autoload
(defun loom:poll-list-periodic-tasks ()
  "Return a list of all registered periodic task IDs.

Returns:
- (list): A list of all task IDs currently in the registry."
  (if (not (loom-lock-p loom--periodic-tasks-mutex))
      '()
    (loom:with-mutex! loom--periodic-tasks-mutex
      (hash-table-keys loom--periodic-tasks-registry))))

;;;###autoload
(defun loom:poll-get-task-info (id)
  "Get comprehensive information about a registered periodic task.

Arguments:
- `ID` (any): The unique identifier of the task.

Returns:
- (plist): A copy of the task's metadata, or `nil` if not found."
  (when (loom-lock-p loom--periodic-tasks-mutex)
    (loom:with-mutex! loom--periodic-tasks-mutex
      (when-let ((task-info (gethash id loom--periodic-tasks-registry)))
        (copy-sequence task-info)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Enhanced System Status and Monitoring

;;;###autoload
(defun loom:poll-scheduler-status ()
  "Get comprehensive status information about the background scheduler.

Returns:
- (plist): A property list with detailed system metrics and health information."
  (let ((task-count 0) (error-tasks 0))
    (when (loom-lock-p loom--periodic-tasks-mutex)
      (loom:with-mutex! loom--periodic-tasks-mutex
        (setq task-count (hash-table-count loom--periodic-tasks-registry))
        (maphash (lambda (_id task-info)
                   (when (>= (or (plist-get task-info :error-count) 0)
                             (/ loom-poll-max-task-errors 2.0))
                     (cl-incf error-tasks)))
                 loom--periodic-tasks-registry)))
    `(:running ,loom--scheduler-thread-running
      :thread-alive ,(and loom--scheduler-thread
                          (thread-live-p loom--scheduler-thread))
      :startup-time ,loom--scheduler-startup-time
      :task-count ,task-count
      :error-tasks ,error-tasks)))

;;;###autoload
(defun loom:poll-system-health-report ()
  "Generate a comprehensive health report for the thread polling system.

Returns:
- (plist): A detailed property list with system status and recommendations."
  (let* ((status (loom:poll-scheduler-status))
         (errors '()) (warnings '()) (recommendations '())
         (health-score 100)
         health-description)

    (unless (plist-get status :running)
      (push "Scheduler is not set to run" errors))
    (unless (plist-get status :thread-alive)
      (push "Scheduler thread is not alive (crashed?)" errors))
    (when (> (plist-get status :error-tasks) 0)
      (push (format "%d tasks are in an error state"
                    (plist-get status :error-tasks)) warnings))
    (when (= (plist-get status :task-count) 0)
      (push "No periodic tasks are currently registered" recommendations))

    (setq health-score (cond ((not (null errors)) 0)
                             ((not (null warnings)) 50)
                             ((not (null recommendations)) 75)
                             (t 100)))
    (setq health-description (cond ((= health-score 100) "Excellent")
                                   ((= health-score 75) "Good")
                                   ((= health-score 50) "Warning")
                                   (t "Critical")))

    `(:health-score ,health-score
      :health-description ,health-description
      :status ,status
      :errors ,(nreverse errors)
      :warnings ,(nreverse warnings)
      :recommendations ,(nreverse recommendations))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shutdown Hook

(defun loom-poll-shutdown-hook ()
  "Shutdown hook to ensure clean termination of the scheduler thread."
  (when (and loom--scheduler-thread (thread-live-p loom--scheduler-thread))
    (loom-log :info nil "Emacs shutdown: stopping scheduler thread.")
    (loom:poll-stop-scheduler-thread)
    (unless (loom:poll-join-scheduler-thread 0.5) ; Wait max 500ms
      (loom-log :warn nil
                "Scheduler thread did not exit cleanly during shutdown."))))

(add-hook 'kill-emacs-hook #'loom-poll-shutdown-hook)

(provide 'loom-poll)
;;; loom-poll.el ends here
