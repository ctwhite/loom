;;; loom-thread-polling.el --- Generic Thread-Based Cooperative Polling -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This module provides a generic framework for cooperative polling and
;; executing periodic tasks in a dedicated background thread. It is designed
;; to enable efficient, non-blocking waits and recurring operations in
;; Emacs Lisp applications.
;;
;; Key features:
;; - **Generic Cooperative Loop (`loom:thread-polling-cooperative-loop`):**
;;   A function for main-thread polling that executes work and yields
;;   control based on a condition.
;; - **Dedicated Scheduler Thread:** A background thread that periodically
;;   executes a registry of registered tasks. This is crucial for
;;   efficiently waking up threads waiting on condition variables.
;; - **Task Registration (`loom:thread-polling-register-periodic-task`):**
;;   Functions to register and unregister arbitrary functions to be called
;;   periodically by the scheduler thread.
;;
;; This module is designed to be highly decoupled, making no assumptions
;; about the nature of the tasks or the waiting conditions it manages.
;;
;; Usage example:
;;
;;   ;; Register a periodic task
;;   (loom:thread-polling-register-periodic-task
;;    'my-task
;;    (lambda () (message "Periodic task executed")))
;;
;;   ;; Use cooperative polling
;;   (let ((counter 0))
;;     (loom:thread-polling-cooperative-loop
;;      (lambda () (> counter 10))          ; condition
;;      (lambda () (setq counter (1+ counter))) ; work
;;      0.1                                  ; poll interval
;;      'my-loop))                          ; debug ID
;;
;;   ;; Clean up
;;   (loom:thread-polling-unregister-periodic-task 'my-task)
;;   (loom:thread-polling-stop-scheduler-thread)

;;; Code:

(require 'cl-lib)
(require 'subr-x) 
                  
(require 'loom-log)
(require 'loom-lock) 
(require 'loom-errors) 

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-thread-polling-default-interval 0.01
  "Default polling interval (in seconds) for the scheduler thread and
  cooperative loops. Smaller values provide better responsiveness but
  may increase CPU usage."
  :type 'float
  :group 'loom)

(defcustom loom-thread-polling-max-task-errors 10
  "Maximum number of consecutive errors allowed for a periodic task
  before automatic removal. Set to 0 to disable automatic removal."
  :type 'integer
  :group 'loom)

(defcustom loom-thread-polling-shutdown-timeout 5.0
  "Maximum time (in seconds) to wait for scheduler thread shutdown.
  If the thread doesn't terminate within this time, it will be forcibly
  killed."
  :type 'float
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-thread-polling-error
  "A generic error in the thread polling module."
  'loom-error)

(define-error 'loom-thread-polling-invalid-argument-error
  "An invalid argument was provided to a thread polling function."
  'loom-thread-polling-error)

(define-error 'loom-thread-polling-scheduler-start-error
  "Failed to start the scheduler thread."
  'loom-thread-polling-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State for Scheduler Thread

(defvar loom--scheduler-thread-running nil
  "Flag to control the running state of `loom--scheduler-thread`.")

(defvar loom--scheduler-thread nil
  "The dedicated thread for executing periodic tasks.")

(defvar loom--periodic-tasks-mutex nil
  "A mutex to protect `loom--periodic-tasks-registry` from concurrent
  access.")

(defvar loom--periodic-tasks-registry (make-hash-table :test 'eq)
  "Hash table storing periodic tasks, keyed by unique ID.
  Each value is a plist with keys:
  - :function - The task function to execute.
  - :error-count - Number of consecutive errors.
  - :last-error - Last error encountered."
  )

(defvar loom--scheduler-startup-time nil
  "Time when the scheduler thread was started (`current-time` value).")

(defvar loom--scheduler-task-count 0
  "Total number of tasks executed by the scheduler thread since startup.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Scheduler Thread Logic

(defun loom--execute-periodic-task (id task-info)
  "Execute a single periodic task with error handling.

  Arguments:
  - ID: The unique identifier of the task.
  - TASK-INFO: Plist containing task information (:function, :error-count,
    :last-error).

  Returns:
  - t if task executed successfully, nil otherwise."
  (let ((task-fn (plist-get task-info :function))
        (error-count (or (plist-get task-info :error-count) 0)))
    (condition-case err
        (progn
          (funcall task-fn)
          (cl-incf loom--scheduler-task-count)
          ;; Reset error count on success.
          (when (> error-count 0)
            (plist-put task-info :error-count 0)
            (plist-put task-info :last-error nil))
          t)
      (error
       (cl-incf error-count)
       (plist-put task-info :error-count error-count)
       (plist-put task-info :last-error err)
       (loom-log :error id "Error in periodic task (ID: %S, error #%d): %S"
                 id error-count err)

       ;; Remove task if it has exceeded maximum error count.
       (when (and (> loom-thread-polling-max-task-errors 0)
                  (>= error-count loom-thread-polling-max-task-errors))
         (loom-log :warn id
                   "Removing periodic task %S after %d consecutive errors"
                   id error-count)
         (remhash id loom--periodic-tasks-registry))
       nil))))

(defun loom-thread-polling-scheduler-loop ()
  "The main loop for the dedicated scheduler thread.
  This thread's sole purpose is to wake up periodically and execute all
  functions registered in `loom--periodic-tasks-registry`. This allows
  for efficient background processing and notification of waiting threads."
  (loom-log :info nil "Generic scheduler thread started (PID: %d)"
            (emacs-pid))
  (setq loom--scheduler-startup-time (current-time))
  (setq loom--scheduler-task-count 0)

  (while loom--scheduler-thread-running
    (sleep-for loom-thread-polling-default-interval)
    (when loom--scheduler-thread-running ; Check again after sleep.
      (loom:with-mutex! loom--periodic-tasks-mutex
        (let ((task-ids (hash-table-keys loom--periodic-tasks-registry)))
          (dolist (id task-ids)
            (when-let ((task-info (gethash id loom--periodic-tasks-registry)))
              (loom--execute-periodic-task id task-info)))))))

  (loom-log :info nil "Generic scheduler thread stopped (executed %d tasks)"
            loom--scheduler-task-count))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom:thread-polling-cooperative-loop (condition-fn work-fn poll-interval
                                             &optional debug-id max-iterations)
  "Execute a cooperative polling loop until CONDITION-FN returns true.

  This function is designed for non-blocking wait operations. It repeatedly
  executes WORK-FN, then yields control using `sit-for`, until CONDITION-FN
  returns a non-nil value.

  Arguments:
  - CONDITION-FN (function): A no-argument function that returns non-nil
    when the polling loop should terminate.
  - WORK-FN (function): A no-argument function to execute in each iteration
    of the loop before yielding control. This function can perform tasks
    like ticking schedulers or draining IPC queues.
  - POLL-INTERVAL (float): The duration (in seconds) for which `sit-for`
    will yield control in each iteration. A smaller interval means more
    responsiveness but potentially higher CPU usage.
  - DEBUG-ID (any, optional): An identifier for logging purposes.
  - MAX-ITERATIONS (integer, optional): Maximum number of iterations to
    prevent infinite loops. Defaults to nil (no limit).

  Returns:
  - The return value of CONDITION-FN when it becomes true, or nil if
    MAX-ITERATIONS is reached.

  Signals:
  - `loom-thread-polling-invalid-argument-error` if arguments are invalid."
  (unless (functionp condition-fn)
    (signal 'loom-thread-polling-invalid-argument-error
            (loom:make-error
             :type :loom-thread-polling-invalid-argument-error
             :message (format "CONDITION-FN must be a function, got: %S"
                              condition-fn))))
  (unless (functionp work-fn)
    (signal 'loom-thread-polling-invalid-argument-error
            (loom:make-error
             :type :loom-thread-polling-invalid-argument-error
             :message (format "WORK-FN must be a function, got: %S"
                              work-fn))))
  (unless (and (numberp poll-interval) (> poll-interval 0))
    (signal 'loom-thread-polling-invalid-argument-error
            (loom:make-error
             :type :loom-thread-polling-invalid-argument-error
             :message (format "POLL-INTERVAL must be a positive number, got: %S"
                              poll-interval))))
  (when (and max-iterations
             (or (not (integerp max-iterations)) (<= max-iterations 0)))
    (signal 'loom-thread-polling-invalid-argument-error
            (loom:make-error
             :type :loom-thread-polling-invalid-argument-error
             :message (format "MAX-ITERATIONS must be a positive integer, got: %S"
                              max-iterations))))

  (loom-log :debug debug-id
            "Entering cooperative polling loop (interval: %s, max-iterations: %s)"
            poll-interval max-iterations)

  (let ((iteration 0)
        (result nil))
    (while (and (not (setq result (funcall condition-fn)))
                (or (null max-iterations) (< iteration max-iterations)))
      (condition-case err
          (funcall work-fn)
        (error
         (loom-log :error debug-id "Error in work function: %S" err)))

      (sit-for poll-interval)
      (cl-incf iteration))

    (loom-log :debug debug-id
              "Exited cooperative polling loop after %d iterations (result: %S)"
              iteration result)
    result))

;;;###autoload
(defun loom:thread-polling-ensure-scheduler-thread ()
  "Ensure the dedicated scheduler thread is running.
  This thread is responsible for periodically executing registered tasks,
  which can include notifying condition variables to unblock waiting threads.

  Returns:
  - t if thread was started or was already running, nil if failed to start."
  (if (and loom--scheduler-thread (thread-live-p loom--scheduler-thread))
      t ; Already running.
    (condition-case err
        (progn
          (loom-log :info nil "Starting generic scheduler thread.")
          ;; Initialize mutex for periodic tasks registry if not already.
          (unless (loom-lock-p loom--periodic-tasks-mutex)
            (setq loom--periodic-tasks-mutex
                  (loom:lock "periodic-tasks-mutex" :mode :thread)))
          (setq loom--scheduler-thread-running t)
          (setq loom--scheduler-thread
                (make-thread #'loom-thread-polling-scheduler-loop
                             "loom-generic-scheduler"))
          ;; Brief pause to allow thread to start.
          (sleep-for 0.001)
          t)
      (error
       (loom-log :error nil "Failed to start scheduler thread: %S" err)
       (setq loom--scheduler-thread-running nil)
       (signal 'loom-thread-polling-scheduler-start-error
               (loom:make-error
                :type :loom-thread-polling-scheduler-start-error
                :message (format "Failed to start scheduler thread: %S" err)
                :cause err))
       nil))))

;;;###autoload
(defun loom:thread-polling-stop-scheduler-thread ()
  "Stop the dedicated scheduler thread gracefully.
  This function is typically called during Emacs shutdown to ensure a
  clean exit of the background thread.

  Returns:
  - t if thread was stopped successfully, nil if there was no thread to stop."
  (if (not (and loom--scheduler-thread (thread-live-p loom--scheduler-thread)))
      nil ; No thread to stop.
    (loom-log :info nil "Stopping generic scheduler thread.")
    (setq loom--scheduler-thread-running nil)

    ;; Wait for thread to terminate gracefully.
    (let ((start-time (current-time))
          (stopped-cleanly nil))
      (while (and (thread-live-p loom--scheduler-thread)
                  (< (float-time (time-subtract (current-time) start-time))
                     loom-thread-polling-shutdown-timeout))
        (sleep-for 0.01))

      (if (thread-live-p loom--scheduler-thread)
          (progn
            (loom-log :warn nil
                      "Scheduler thread did not terminate gracefully, forcing.")
            (condition-case err
                (progn
                  (thread-signal loom--scheduler-thread 'quit nil)
                  (sleep-for 0.1) ; Brief pause for signal to take effect.
                  (setq stopped-cleanly
                        (not (thread-live-p loom--scheduler-thread))))
              (error
               (loom-log :error nil "Error while forcing termination: %S" err))))
        (setq stopped-cleanly t))

      (when stopped-cleanly
        (loom-log :info nil "Generic scheduler thread stopped gracefully."))

      (setq loom--scheduler-thread nil)
      stopped-cleanly)))

;;;###autoload
(defun loom:thread-polling-register-periodic-task (id task-fn)
  "Register TASK-FN to be executed periodically by the scheduler thread.

  Arguments:
  - `ID` (any): A unique identifier for this task (e.g., a symbol).
  - `TASK-FN` (function): A no-argument function to be called periodically.

  Returns:
  - t if task was registered successfully, nil otherwise.

  Signals:
  - `loom-thread-polling-invalid-argument-error` if TASK-FN is not a function."
  (unless (functionp task-fn)
    (signal 'loom-thread-polling-invalid-argument-error
            (loom:make-error
             :type :loom-thread-polling-invalid-argument-error
             :message (format "TASK-FN must be a function, got: %S" task-fn))))

  (when (loom:thread-polling-ensure-scheduler-thread)
    (loom:with-mutex! loom--periodic-tasks-mutex
      (puthash id (list :function task-fn :error-count 0 :last-error nil)
               loom--periodic-tasks-registry))
    (loom-log :debug id "Registered periodic task.")
    t))

;;;###autoload
(defun loom:thread-polling-unregister-periodic-task (id)
  "Unregister a periodic task, preventing it from being executed further.

  Arguments:
  - `ID` (any): The unique identifier of the task to unregister.

  Returns:
  - t if task was unregistered, nil if task was not found."
  (when (loom-lock-p loom--periodic-tasks-mutex)
    (loom:with-mutex! loom--periodic-tasks-mutex
      (let ((found (gethash id loom--periodic-tasks-registry)))
        (when found
          (remhash id loom--periodic-tasks-registry)
          (loom-log :debug id "Unregistered periodic task.")
          t)))))

;;;###autoload
(defun loom:thread-polling-list-periodic-tasks ()
  "Return a list of all registered periodic task IDs.

  Returns:
  - List of task IDs currently registered with the scheduler."
  (when (loom-lock-p loom--periodic-tasks-mutex)
    (loom:with-mutex! loom--periodic-tasks-mutex
      (hash-table-keys loom--periodic-tasks-registry))))

;;;###autoload
(defun loom:thread-polling-get-task-info (id)
  "Get information about a registered periodic task.

  Arguments:
  - `ID` (any): The unique identifier of the task.

  Returns:
  - Plist with task information, or nil if task not found.
    Keys include :function, :error-count, :last-error."
  (when (loom-lock-p loom--periodic-tasks-mutex)
    (loom:with-mutex! loom--periodic-tasks-mutex
      (gethash id loom--periodic-tasks-registry))))

;;;###autoload
(defun loom:thread-polling-scheduler-status ()
  "Get status information about the scheduler thread.

  Returns:
  - Plist with scheduler status information including:
    :running - Whether the scheduler thread is running.
    :thread-alive - Whether the thread object is alive.
    :startup-time - When the scheduler was started.
    :task-count - Total number of tasks executed.
    :registered-tasks - Number of currently registered tasks."
  (list :running loom--scheduler-thread-running
        :thread-alive (and loom--scheduler-thread
                           (thread-live-p loom--scheduler-thread))
        :startup-time loom--scheduler-startup-time
        :task-count loom--scheduler-task-count
        :registered-tasks (hash-table-count loom--periodic-tasks-registry)))

;;;###autoload
(defun loom:thread-polling-reset ()
  "Reset the thread polling system by stopping the scheduler and clearing
  all tasks. This is primarily useful for testing and debugging.

  Returns:
  - t if reset was successful."
  (loom:thread-polling-stop-scheduler-thread)
  (when (loom-lock-p loom--periodic-tasks-mutex)
    (loom:with-mutex! loom--periodic-tasks-mutex
      (clrhash loom--periodic-tasks-registry)))
  (setq loom--scheduler-startup-time nil
        loom--scheduler-task-count 0)
  (loom-log :info nil "Thread polling system reset.")
  t)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shutdown Hook

(defun loom--thread-polling-shutdown-hook ()
  "Shutdown hook to ensure clean termination of the scheduler thread."
  (when (and loom--scheduler-thread (thread-live-p loom--scheduler-thread))
    (loom-log :info nil "Emacs shutdown: stopping scheduler thread.")
    (loom:thread-polling-stop-scheduler-thread)))

;; Register shutdown hook
(add-hook 'kill-emacs-hook #'loom--thread-polling-shutdown-hook)

(provide 'loom-thread-polling)
;;; loom-thread-polling.el ends here