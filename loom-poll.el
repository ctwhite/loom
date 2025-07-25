;;; loom-poll.el --- Generic Thread-Based Cooperative Polling -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides a robust framework for two distinct but related
;; concurrency patterns: cooperative polling and background periodic task
;; execution.
;;
;; ## Design Philosophy
;;
;; 1. **Dedicated Poller Instances (`loom-poll`):**
;;    Users can now create multiple, independent `loom-poll` instances.
;;    Each `loom-poll` manages its own background thread and registry of
;;    periodic tasks, enabling isolated and flexible background task
;;    management.
;;
;;    - Each `loom-poll` instance contains its own thread, task registry,
;;      and control flags.
;;    - Pollers are designed for graceful shutdown, robust error handling,
;;      and performance monitoring.
;;
;; 2. **Generic Cooperative Polling (`loom:poll-with-backoff`):**
;;    This function provides a way for **the current Emacs Lisp thread** to
;;    perform a blocking wait while cooperatively yielding CPU time. When
;;    called on the main thread, it allows the UI to remain responsive. When
;;    called from a background thread, it yields that thread's CPU time to
;;    other active threads. It's a generic utility, not tied to a specific
;;    `loom-poll` instance.
;;    It includes timeout controls and exponential backoff for efficiency.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'loom-lock)
(require 'loom-error)

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

(define-error 'loom-poll-uninitialized-error
  "Operation attempted on an uninitialized or stopped poller."
  'loom-poll-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-poll (:constructor %%make-poll))
  "Represents a dedicated polling instance with its own background thread.

Fields:
- `name` (string): A human-readable name for this poll instance.
- `thread` (thread or nil): The dedicated background scheduler thread.
- `running-p` (boolean): Flag to control the running state of the thread.
- `tasks-mutex` (loom-lock): Mutex to protect `tasks-registry`.
- `tasks-registry` (hash-table): Registry for periodic tasks for this poll.
- `startup-time` (current-time or nil): Timestamp of thread startup.
- `shutdown-p` (boolean): Flag indicating if the poll is shutting down."
  (name nil :type string)
  (thread nil :type (or null thread))
  (running-p nil :type boolean)
  (tasks-mutex nil :type (or null loom-lock))
  (tasks-registry nil :type (or null hash-table))
  (startup-time nil :type (or null current-time))
  (shutdown-p nil :type boolean))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom--default-poll-instance nil
  "The default `loom-poll` instance, initialized on demand.")

(defvar loom--all-poll-instances '()
  "A list of all active `loom-poll` instances for shutdown hook.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Poller Thread Logic

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

(defun loom--execute-periodic-task (id task-info poll)
  "Execute a single periodic task with robust error handling.
This is called from within the scheduler thread's loop.

Arguments:
- `ID` (any): The unique identifier of the task.
- `TASK-INFO` (plist): The task's metadata plist.
- `POLL` (loom-poll): The poll instance executing the task.

Returns:
- `t` on success, `nil` on error.

Side Effects:
- Executes the task function.
- Updates task statistics.
- May remove the task from the registry if it exceeds the error
  threshold."
  (condition-case err
      (progn
        (funcall (plist-get task-info :function))
        (loom--update-task-stats task-info t nil)
        t)
    (error
     (loom--update-task-stats task-info nil err)
     (let ((new-error-count (plist-get task-info :error-count)))
       (loom:log! :error id "Error in periodic task (ID: %S, error #%d): %S"
                 id new-error-count err)
       (when (and (> loom-poll-max-task-errors 0)
                  (>= new-error-count loom-poll-max-task-errors))
         (loom:log! :warn id "Removing task %S after %d errors."
                   id new-error-count)
         (remhash id (loom-poll-tasks-registry poll))))
     nil)))

(defun loom-poll-worker-loop (poll)
  "The main loop for a `loom-poll`'s background thread.
This loop wakes periodically to execute all registered tasks and
terminates gracefully when `(loom-poll-running-p POLL)` becomes nil.

Arguments:
- `POLL` (loom-poll): The poll instance this thread belongs to."
  (loom:log! :info (loom-poll-name poll) "Poller thread started.")
  (setf (loom-poll-startup-time poll) (current-time))

  ;; Execute immediate tasks first, if any
  (when (loom-lock-p (loom-poll-tasks-mutex poll))
    (loom:with-mutex! (loom-poll-tasks-mutex poll)
      (maphash (lambda (id task-info)
                 (when (plist-get task-info :immediate)
                   (loom:log! :debug (loom-poll-name poll)
                             "Executing immediate task '%S'." id)
                   (loom--execute-periodic-task id task-info poll)
                   ;; After immediate execution, mark it so it doesn't run
                   ;; immediately again
                   (plist-put task-info :immediate nil)))
               (loom-poll-tasks-registry poll))))

  (cl-block poll-loop
    (while (loom-poll-running-p poll)
      (condition-case err
          (when (loom-lock-p (loom-poll-tasks-mutex poll))
            (loom:with-mutex! (loom-poll-tasks-mutex poll)
              (let ((task-ids (hash-table-keys
                               (loom-poll-tasks-registry poll))))
                (dolist (id task-ids)
                  (unless (loom-poll-running-p poll)
                    (cl-return-from poll-loop nil))
                  (when-let ((task-info
                              (gethash id
                                       (loom-poll-tasks-registry poll)))
                             (current-task-function
                              (plist-get task-info :function))
                             (last-run-time
                              (or (plist-get task-info :last-run-time)
                                  (current-time)))
                             (interval
                              (or (plist-get task-info :interval)
                                  loom-poll-default-interval)))

                    ;; Check if enough time has passed since last run
                    (when (and current-task-function
                               (>= (float-time
                                    (time-subtract (current-time)
                                                   last-run-time))
                                   interval))
                      (loom--execute-periodic-task id task-info poll)))))))
        (error (loom:log! :error (loom-poll-name poll)
                         "Error in poller loop: %S" err)))

      (when (loom-poll-running-p poll)
        (sleep-for loom-poll-default-interval))))

  (loom:log! :info (loom-poll-name poll) "Poller thread stopped gracefully."))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Poller Lifecycle Management

;;;###autoload
(cl-defun loom:poll (&key name task interval (immediate nil))
  "Create and initialize a new `loom-poll` instance.
If `:task` is provided, it will be registered with the specified
`:interval` and optionally run `:immediate`ly.
This does NOT start the poll's background thread automatically unless
a task is provided and `:immediate` is true.
Call `loom:poll-start` to begin periodic task execution if no task
is provided or `:immediate` is nil.

Arguments:
- `:NAME` (string, optional): A descriptive name for the poll.
  Defaults to a unique generated name.
- `:TASK` (function, optional): A no-argument function to run periodically.
- `:INTERVAL` (float, optional): The interval for the task. Defaults to
  `loom-poll-default-interval`.
- `:IMMEDIATE` (boolean, optional): If `t`, runs the task once immediately
  when the poll is started.

Returns:
- (loom-poll): A new, initialized poll instance."
  (let* ((poll-name (or name (format "poll-%s" (make-symbol "p"))))
         (mutex (loom:lock (format "%s-tasks-mutex" poll-name)))
         (poll (%%make-poll
                :name poll-name
                :tasks-mutex mutex
                :tasks-registry (make-hash-table :test 'eq)
                :running-p nil
                :shutdown-p nil)))
    (loom:log! :info poll-name "New poll instance created.")
    (add-to-list 'loom--all-poll-instances poll)

    (when task
      (unless (functionp task)
        (signal 'loom-poll-invalid-argument '("TASK must be a function")))
      (unless (or (null interval) (and (numberp interval) (> interval 0)))
        (signal 'loom-poll-invalid-argument
                '("INTERVAL must be a positive number or nil")))

      (loom:with-mutex! (loom-poll-tasks-mutex poll)
        (puthash (make-symbol "initial-task")
                 `(:function ,task
                   :interval ,(or interval loom-poll-default-interval)
                   :error-count 0
                   :total-runs 0
                   :total-errors 0
                   :created-time ,(current-time)
                   :immediate ,immediate) ; Store immediate flag
                 (loom-poll-tasks-registry poll)))

      ;; If task is provided and immediate, start the poll
      (when immediate
        (loom:poll-start poll)))
    poll))

;;;###autoload
(defun loom:poll-start (poll)
  "Start the background scheduler thread for `POLL`. Idempotent.

Arguments:
- `POLL` (loom-poll): The poll instance to start.

Returns:
- `t` if the thread is running or was started successfully.
- `nil` on failure.

Signals:
- `loom-poll-invalid-argument`: If `POLL` is not a `loom-poll`.
- `loom-poll-scheduler-start-error`: On failure to start the thread.
- `loom-poll-uninitialized-error`: If the poll is already shut down."
  (unless (loom-poll-p poll)
    (signal 'loom-poll-invalid-argument (list "Not a loom-poll" poll)))
  (when (loom-poll-shutdown-p poll)
    (signal 'loom-poll-uninitialized-error
            (list "Cannot start a poll that has been shut down.")))

  (if (and (loom-poll-thread poll) (thread-live-p (loom-poll-thread poll)))
      t
    (condition-case err
        (progn
          (loom:log! :info (loom-poll-name poll) "Starting poll thread.")
          (setf (loom-poll-running-p poll) t)
          (setf (loom-poll-thread poll)
                (make-thread (lambda () (loom-poll-worker-loop poll))
                             (format "loom-poll-%s" (loom-poll-name poll))))
          (sleep-for 0.001)
          (unless (thread-live-p (loom-poll-thread poll))
            (error "Thread creation failed silently."))
          t)
      (error
       (loom:log! :error (loom-poll-name poll)
                         "Failed to start poll thread: %S" err)
       (setf (loom-poll-running-p poll) nil)
       (signal 'loom-poll-scheduler-start-error (list err))
       nil))))

;;;###autoload
(defun loom:poll-stop (poll)
  "Initiate a graceful, NON-BLOCKING shutdown of `POLL`'s thread.
This function only signals the thread to stop on its next iteration.
It does NOT wait for the thread to terminate. To wait, use
`loom:poll-join`.

Arguments:
- `POLL` (loom-poll): The poll instance to stop.

Returns:
- `t` if a shutdown was signaled, `nil` if the thread was not running."
  (unless (loom-poll-p poll)
    (signal 'loom-poll-invalid-argument (list "Not a loom-poll" poll)))
  (when (and (loom-poll-thread poll) (thread-live-p (loom-poll-thread poll)))
    (loom:log! :info (loom-poll-name poll) "Signaling poll thread to stop.")
    (setf (loom-poll-running-p poll) nil)
    t))

;;;###autoload
(defun loom:poll-join (poll &optional timeout)
  "Cooperatively wait for `POLL`'s thread to terminate.
This function BLOCKS the current Lisp evaluation but keeps the Emacs UI
responsive by using a cooperative poll (`sit-for`). It does NOT use the
native `thread-join` primitive, which would freeze the entire UI.

This function should be used with caution, typically only in scripts or
during shutdown sequences where blocking is acceptable. For a completely
non-blocking approach, use `loom:poll-stop`
and check the thread's status separately.

Arguments:
- `POLL` (loom-poll): The poll instance to join.
- `TIMEOUT` (number, optional): Max seconds to wait. Defaults to
  `loom-poll-shutdown-timeout`.

Returns:
- `t` if the thread terminated, `nil` on timeout or if not running."
  (unless (loom-poll-p poll)
    (signal 'loom-poll-invalid-argument (list "Not a loom-poll" poll)))
  (let ((effective-timeout (or timeout loom-poll-shutdown-timeout)))
    (if (or (null (loom-poll-thread poll))
            (not (thread-live-p (loom-poll-thread poll))))
        t
      (condition-case nil
          (loom:poll-with-backoff
           (lambda () (not (thread-live-p (loom-poll-thread poll))))
           :debug-id (format "poll-join-%s" (loom-poll-name poll))
           :timeout effective-timeout)
        (loom-poll-timeout nil)))))

;;;###autoload
(defun loom:poll-shutdown (poll)
  "Initiate a graceful shutdown of `POLL`, stopping its thread and
clearing tasks. This marks the poll as shut down and it cannot be
restarted.

Arguments:
- `POLL` (loom-poll): The poll instance to shut down.

Returns: `t`.

Side Effects:
- Stops the poll's thread.
- Clears its task registry.
- Removes it from the global list of active pollers."
  (unless (loom-poll-p poll)
    (signal 'loom-poll-invalid-argument (list "Not a loom-poll" poll)))
  (loom:log! :info (loom-poll-name poll) "Initiating poll shutdown.")
  (loom:poll-stop poll)
  (loom:poll-join poll)

  (loom:with-mutex! (loom-poll-tasks-mutex poll)
    (clrhash (loom-poll-tasks-registry poll)))

  (setf (loom-poll-thread poll) nil
        (loom-poll-running-p poll) nil
        (loom-poll-tasks-mutex poll) nil
        (loom-poll-tasks-registry poll) nil
        (loom-poll-startup-time poll) nil
        (loom-poll-shutdown-p poll) t)
  (setq loom--all-poll-instances (delete poll loom--all-poll-instances))
  (loom:log! :info (loom-poll-name poll) "Poll shutdown complete.")
  t)

;;;###autoload
(defun loom:poll-default ()
  "Return the default `loom-poll` instance, initializing and starting it
if needed. This function is idempotent; subsequent calls return the
existing instance without re-initializing or restarting.

Returns:
- (loom-poll): The default poll instance.

Side Effects:
- May create and start the default poll instance if it doesn't exist."
  (unless (and loom--default-poll-instance
               (loom-poll-p loom--default-poll-instance)
               (not (loom-poll-shutdown-p loom--default-poll-instance))
               (loom-poll-running-p loom--default-poll-instance)
               (loom-poll-thread loom--default-poll-instance)
               (thread-live-p
                (loom-poll-thread loom--default-poll-instance)))
    (loom:log! :info 'default-poll
              "Default poll not found or not running. Creating and
starting new one.")
    (setq loom--default-poll-instance
          (loom:poll :name "default-poll"))
    (loom:poll-start loom--default-poll-instance))
  loom--default-poll-instance)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Task Management

;;;###autoload
(defun loom:poll-register-periodic-task (poll id task-fn
                                        &key interval immediate)
  "Register a function to be run periodically by `POLL`'s scheduler.
If a task with `ID` already exists, it will be overwritten.

Arguments:
- `POLL` (loom-poll): The poll instance.
- `ID` (any): A unique identifier for the task (e.g., a symbol).
- `TASK-FN` (function): A no-argument function to call periodically.
- `:INTERVAL` (float, optional): The interval for the task. Defaults to
  `loom-poll-default-interval`.
- `:IMMEDIATE` (boolean, optional): If `t`, runs the task once immediately
  when the poll is started or the task is registered if the poll is
  already running.

Returns:
- `t` on success.

Signals:
- `loom-poll-invalid-argument`: If arguments are invalid.
- `loom-poll-uninitialized-error`: If the poll is shut down."
  (unless (loom-poll-p poll)
    (signal 'loom-poll-invalid-argument (list "Not a loom-poll" poll)))
  (unless (functionp task-fn)
    (signal 'loom-poll-invalid-argument '("TASK-FN must be a function")))
  (when (loom-poll-shutdown-p poll)
    (signal 'loom-poll-uninitialized-error
            (list "Cannot register task on a poll that has been shut down.")))

  (unless (or (null interval) (and (numberp interval) (> interval 0)))
    (signal 'loom-poll-invalid-argument
            '("INTERVAL must be a positive number or nil")))

  (loom:poll-start poll) ; Ensure the poll is running
  (loom:with-mutex! (loom-poll-tasks-mutex poll)
    (when (gethash id (loom-poll-tasks-registry poll))
      (loom:log! :warn (loom-poll-name poll)
                "Overwriting existing task '%S'." id))
    (let ((task-plist `(:function ,task-fn
                        :interval ,(or interval loom-poll-default-interval)
                        :error-count 0
                        :total-runs 0
                        :total-errors 0
                        :created-time ,(current-time)
                        :immediate ,immediate)))
      (puthash id task-plist (loom-poll-tasks-registry poll))
      ;; If poll is already running and immediate is true, execute now.
      ;; Otherwise, it will be picked up by the worker loop on its next run.
      (when (and immediate (loom-poll-running-p poll))
        (loom:log! :debug (loom-poll-name poll)
                  "Executing immediate task '%S' during registration." id)
        (loom--execute-periodic-task id task-plist poll)
        (plist-put task-plist :immediate nil)))) ; Mark as no longer immediate
  (loom:log! :debug (loom-poll-name poll)
            "Registered periodic task '%S'." id)
  t)

;;;###autoload
(defun loom:poll-unregister-periodic-task (poll id)
  "Unregister a periodic task by its `ID` from `POLL`.

Arguments:
- `POLL` (loom-poll): The poll instance.
- `ID` (any): The unique identifier of the task to unregister.

Returns:
- `t` if task was found and removed, `nil` otherwise.

Signals:
- `loom-poll-invalid-argument`: If `POLL` is not a `loom-poll`."
  (unless (loom-poll-p poll)
    (signal 'loom-poll-invalid-argument (list "Not a loom-poll" poll)))
  (if (not (loom-lock-p (loom-poll-tasks-mutex poll)))
      nil
    (loom:with-mutex! (loom-poll-tasks-mutex poll)
      (when (remhash id (loom-poll-tasks-registry poll))
        (loom:log! :debug (loom-poll-name poll) "Unregistered task '%S'." id)
        t))))

;;;###autoload
(defun loom:poll-list-periodic-tasks (poll)
  "Return a list of all registered periodic task IDs for `POLL`.

Arguments:
- `POLL` (loom-poll): The poll instance.

Returns:
- (list): A list of all task IDs currently in the registry.

Signals:
- `loom-poll-invalid-argument`: If `POLL` is not a `loom-poll`."
  (unless (loom-poll-p poll)
    (signal 'loom-poll-invalid-argument (list "Not a loom-poll" poll)))
  (if (not (loom-lock-p (loom-poll-tasks-mutex poll)))
      '()
    (loom:with-mutex! (loom-poll-tasks-mutex poll)
      (hash-table-keys (loom-poll-tasks-registry poll)))))

;;;###autoload
(defun loom:poll-get-task-info (poll id)
  "Get comprehensive information about a registered periodic task from `POLL`.

Arguments:
- `POLL` (loom-poll): The poll instance.
- `ID` (any): The unique identifier of the task.

Returns:
- (plist): A copy of the task's metadata, or `nil` if not found.

Signals:
- `loom-poll-invalid-argument`: If `POLL` is not a `loom-poll`."
  (unless (loom-poll-p poll)
    (signal 'loom-poll-invalid-argument (list "Not a loom-poll" poll)))
  (when (loom-lock-p (loom-poll-tasks-mutex poll))
    (loom:with-mutex! (loom-poll-tasks-mutex poll)
      (when-let ((task-info (gethash id (loom-poll-tasks-registry poll))))
        (copy-sequence task-info)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Poller Status and Monitoring

;;;###autoload
(defun loom:poll-status (poll)
  "Get comprehensive status information about a `POLL` instance.

Arguments:
- `POLL` (loom-poll): The poll instance.

Returns:
- (plist): A property list with detailed status and health information.

Signals:
- `loom-poll-invalid-argument`: If `POLL` is not a `loom-poll`."
  (unless (loom-poll-p poll)
    (signal 'loom-poll-invalid-argument (list "Not a loom-poll" poll)))
  (let ((task-count 0) (error-tasks 0))
    (when (loom-lock-p (loom-poll-tasks-mutex poll))
      (loom:with-mutex! (loom-poll-tasks-mutex poll)
        (setq task-count (hash-table-count (loom-poll-tasks-registry poll)))
        (maphash (lambda (_id task-info)
                   (when (>= (or (plist-get task-info :error-count) 0)
                             (/ loom-poll-max-task-errors 2.0))
                     (cl-incf error-tasks)))
                 (loom-poll-tasks-registry poll))))
    `(:name ,(loom-poll-name poll)
      :running ,(loom-poll-running-p poll)
      :thread-alive ,(and (loom-poll-thread poll)
                          (thread-live-p (loom-poll-thread poll)))
      :startup-time ,(loom-poll-startup-time poll)
      :task-count ,task-count
      :error-tasks ,error-tasks
      :shutdown-p ,(loom-poll-shutdown-p poll))))

;;;###autoload
(defun loom:poll-system-health-report (poll)
  "Generate a comprehensive health report for a `POLL` instance.

Arguments:
- `POLL` (loom-poll): The poll instance.

Returns:
- (plist): A detailed property list with system status and recommendations.

Signals:
- `loom-poll-invalid-argument`: If `POLL` is not a `loom-poll`."
  (unless (loom-poll-p poll)
    (signal 'loom-poll-invalid-argument (list "Not a loom-poll" poll)))
  (let* ((status (loom:poll-status poll))
         (errors '()) (warnings '()) (recommendations '())
         (health-score 100)
         health-description)

    (unless (plist-get status :running)
      (push "Poller is not set to run" errors))
    (unless (plist-get status :thread-alive)
      (push "Poller thread is not alive (crashed?)" errors))
    (when (plist-get status :shutdown-p)
      (push "Poller has been permanently shut down" errors))
    (when (> (plist-get status :error-tasks) 0)
      (push (format "%d tasks are in an error state"
                    (plist-get status :error-tasks)) warnings))
    (when (= (plist-get status :task-count) 0)
      (push "No periodic tasks are currently registered" recommendations))

    (setq health-score (cond ((not (null errors)) 0)
                             ((not (null warnings)) 50)
                             ((not (null recommendations)) 75)
                             (t 100)))
    (setq health-description (cond ((s-ends-with? "Critical"
                                                 health-description)
                                   "Critical")
                                   ((s-ends-with? "Warning"
                                                 health-description)
                                   "Warning")
                                   ((s-ends-with? "Good"
                                                 health-description)
                                   "Good")
                                   (t "Excellent")))

    `(:health-score ,health-score
      :health-description ,health-description
      :status ,status
      :errors ,(nreverse errors)
      :warnings ,(nreverse warnings)
      :recommendations ,(nreverse recommendations))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Generic Cooperative Polling Utilities

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
seconds until `CONDITION-FN` returns non-nil. This mechanism is designed
for use on **the current Emacs Lisp thread** (main or background) to
perform a blocking wait while cooperatively yielding CPU time.

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

    (loom:log! :debug debug-id
              "Starting cooperative poll (timeout: %.1fs)" timeout)
    (let (iteration result (current-interval poll-interval))
      (while (and (not (setq result (funcall condition-fn)))
                  (or (null max-iterations)
                      (< (or iteration 0) max-iterations)))
        (if (> (float-time (time-subtract (current-time) start-time))
               timeout)
            (signal 'loom-poll-timeout
                    (list (format "Polling timed out for %S" debug-id)))
          (condition-case err (funcall work-fn)
            (error (loom:log! :error debug-id "Error in work-fn: %S" err)))
          (sit-for current-interval)
          (setq current-interval
                (loom--calculate-backoff-interval current-interval))
          (setq iteration (1+ (or iteration 0)))))
      result)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shutdown Hook

(defun loom-poll-shutdown-hook ()
  "Shutdown hook to ensure clean termination of all poll instances."
  (when loom--all-poll-instances
    (loom:log! :info nil "Emacs shutdown: stopping %d poll instance(s)."
              (length loom--all-poll-instances))
    (dolist (poll (copy-sequence loom--all-poll-instances))
      (unless (loom-poll-shutdown-p poll)
        (condition-case err
            (loom:poll-shutdown poll)
          (error
           (loom:log! :error (loom-poll-name poll)
                     "Error during poll shutdown: %S" err)))))))

(add-hook 'kill-emacs-hook #'loom-poll-shutdown-hook)

(provide 'loom-poll)
;;; loom-poll.el ends here