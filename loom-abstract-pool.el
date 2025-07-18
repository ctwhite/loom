;;; loom-abstract-pool.el --- Abstract Worker Pool Core -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This module provides a generic, thread-safe, and highly configurable
;; abstract worker pool. It manages the lifecycle of worker processes,
;; task queuing, dispatching, and error handling.
;;
;; It is not intended to be used directly. Instead, it provides the
;; `loom:defpool!` macro, which acts as a factory for generating
;; the boilerplate required for a new, specialized pool type (e.g., for
;; shell commands or Lisp evaluation).
;;
;; This enhanced version includes dynamic sizing, health checks, granular
;; cancellation, backpressure management, and rich status reporting.
;;
;; Thread Safety:
;; All public functions exported by this module are thread-safe, as they
;; acquire the pool's internal lock before accessing shared state. However,
;; any callback functions provided by the user (e.g., `:on-message`, or
;; the various parser/factory functions) must be thread-safe themselves if
;; they access or modify state outside the scope of the callback.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors Definitions

(define-error 'loom-abstract-pool-error
  "Generic pool error."
  'loom-error)

(define-error 'loom-invalid-abstract-pool-error
  "Invalid pool object."
  'loom-abstract-pool-error)

(define-error 'loom-abstract-pool-shutdown
  "Pool was shut down."
  'loom-abstract-pool-error)

(define-error 'loom-abstract-pool-task-error
  "Task failed in worker."
  'loom-abstract-pool-error)

(define-error 'loom-abstract-pool-task-timeout
  "Task timed out in worker."
  'loom-abstract-pool-error)

(define-error 'loom-abstract-pool-poison-pill
  "Task crashed workers."
  'loom-abstract-pool-error)

(define-error 'loom-abstract-pool-queue-full
  "Pool task queue is full."
  'loom-abstract-pool-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-abstract-pool-default-min-size 1
  "Default minimum number of workers in a dynamic pool."
  :type 'integer
  :group 'loom)

(defcustom loom-abstract-pool-default-max-size 4
  "Default maximum number of workers in a dynamic pool."
  :type 'integer
  :group 'loom)

(defcustom loom-abstract-pool-max-worker-restarts 3
  "Max consecutive restarts for a failed worker."
  :type 'integer
  :group 'loom)

(defcustom loom-abstract-pool-management-interval 5
  "Seconds between pool management cycles (scaling, health checks)."
  :type 'integer
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-abstract-task (:constructor %%make-abstract-task))
  "Represents a generic task submitted to the abstract worker pool.

Fields:
- `promise`: The `loom-promise` that settles with the task's result.
- `id`: A unique identifier for the task, for logging and debugging.
- `payload`: The core data or command to be sent to the worker.
- `context`: Additional, secondary data for the task serializer.
- `on-message-fn`: A callback to handle progress messages from the worker.
- `priority`: The task's priority (lower number is higher priority).
- `retries`: The number of times this task has been retried after a crash.
- `worker`: The `loom-abstract-worker` currently assigned to this task.
- `cancel-token`: A token for cooperatively cancelling this task.
- `start-time`: The `float-time` when the task began execution.
- `timeout`: The maximum number of seconds the task is allowed to run."
  (promise nil :type (or null loom-promise))
  (id nil :type (or null string))
  (payload nil :type t)
  (context nil :type t)
  (on-message-fn nil :type (or null function))
  (priority 50 :type integer)
  (retries 0 :type integer)
  (worker nil :type (or null loom-abstract-worker))
  (cancel-token nil :type (or null loom-cancel-token))
  (start-time nil :type (or null float))
  (timeout nil :type (or null number)))

(cl-defstruct (loom-abstract-worker (:constructor %%make-abstract-worker))
  "Represents a single generic worker process in an abstract pool.

Fields:
- `process`: The underlying Emacs process object for this worker.
- `id`: A unique integer identifier for the worker within its pool.
- `status`: The worker's current state (`:idle`, `:busy`, `:dead`, etc.).
- `current-task`: The `loom-abstract-task` the worker is executing.
- `restart-attempts`: The number of times this worker has been restarted
  consecutively. This is reset upon successful task completion.
- `last-active-time`: The `float-time` when the worker last finished a task."
  (process nil :type (or null process))
  (id 0 :type integer)
  (status :idle :type symbol)
  (current-task nil :type (or null loom-abstract-task))
  (restart-attempts 0 :type integer)
  (last-active-time nil :type (or null float)))

(cl-defstruct (loom-abstract-pool (:constructor %%make-abstract-pool))
  "Represents a generic pool of persistent worker processes.

Fields:
- `name`: A human-readable name for the pool.
- `workers`: A list of `loom-abstract-worker` structs.
- `lock`: A mutex to ensure thread-safe access to the pool's state.
- `task-queue`: A queue holding pending tasks.
- `waiter-queue`: A queue holding requests for exclusive worker sessions.
- `worker-factory-fn`: A function to create a new worker process.
- `worker-ipc-filter-fn`: A function to handle output from a worker process.
- `worker-ipc-sentinel-fn`: A function to handle worker process termination.
- `task-serializer-fn`: A function to convert a task payload into a string.
- `task-cancel-fn`: A function to cancel a running task.
- `result-parser-fn`: A function to parse a result string from a worker.
- `error-parser-fn`: A function to parse an error string from a worker.
- `message-parser-fn`: A function to parse a progress message from a worker.
- `shutdown-p`: A flag indicating if the pool is shutting down.
- `next-worker-id`: A counter to generate unique worker IDs.
- `management-timer`: A timer for periodic scaling and health checks.
- `min-size`: The minimum number of workers to maintain.
- `max-size`: The maximum number of workers to scale up to.
- `worker-idle-timeout`: Seconds an idle worker waits before being culled.
- `max-queue-size`: The maximum number of pending tasks before backpressure.
- `tasks-submitted`: A counter for the total number of tasks submitted.
- `tasks-completed`: A counter for the total number of tasks completed.
- `tasks-failed`: A counter for the total number of tasks that failed."
  (name "" :type string)
  (workers '() :type list)
  (lock nil :type (or null loom-lock))
  (task-queue nil :type (or null loom-queue loom-priority-queue))
  (waiter-queue nil :type (or null loom-queue))
  (worker-factory-fn #'ignore :type function)
  (worker-ipc-filter-fn #'ignore :type function)
  (worker-ipc-sentinel-fn #'ignore :type function)
  (task-serializer-fn #'ignore :type function)
  (task-cancel-fn #'ignore :type function)
  (result-parser-fn #'ignore :type function)
  (error-parser-fn #'ignore :type function)
  (message-parser-fn #'ignore :type function)
  (shutdown-p nil :type boolean)
  (next-worker-id 1 :type integer)
  (management-timer nil :type (or null timer))
  (min-size loom-abstract-pool-default-min-size :type integer)
  (max-size loom-abstract-pool-default-max-size :type integer)
  (worker-idle-timeout 300 :type integer)
  (max-queue-size nil :type (or null integer))
  (tasks-submitted 0 :type integer)
  (tasks-completed 0 :type integer)
  (tasks-failed 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Pool Logic

(defun loom--validate-abstract-pool (pool fn-name)
  "Signal an error if POOL is not a `loom-abstract-pool`.

Arguments:
- `POOL`: The object to validate.
- `FN-NAME` (symbol): The calling function's name, for the error message.

Signals:
- `loom-invalid-abstract-pool-error` if POOL is invalid."
  (unless (loom-abstract-pool-p pool)
    (signal 'loom-invalid-abstract-pool-error
            (list (format "%s: Invalid pool object" fn-name) pool))))

(defun loom--abstract-worker-sentinel-dispatcher (proc event pool)
  "Generic sentinel dispatcher. Calls the pool-specific sentinel handler.
This function is attached as the sentinel to the raw worker process. It
retrieves the associated `loom-abstract-worker` struct and calls the
pool's configured `worker-ipc-sentinel-fn`.

Arguments:
- `PROC` (process): The worker process that triggered the sentinel.
- `EVENT` (string): The event string describing the process state change.
- `POOL` (loom-abstract-pool): The pool owning the worker.

Side Effects:
- Delegates to the pool-specific sentinel function, which will typically
  handle worker restarts and task re-queuing."
  (when-let ((worker (process-get proc 'loom-abstract-worker)))
    (funcall (loom-abstract-pool-worker-ipc-sentinel-fn pool)
             worker event pool)))

(defun loom--abstract-worker-filter-dispatcher (proc chunk pool)
  "Generic filter dispatcher. Calls the pool-specific filter handler.
This function is attached as the filter to the raw worker process. It
retrieves the associated `loom-abstract-worker` struct and calls the
pool's configured `worker-ipc-filter-fn`.

Arguments:
- `PROC` (process): The worker process that produced the output.
- `CHUNK` (string): The string output from the process.
- `POOL` (loom-abstract-pool): The pool owning the worker.

Side Effects:
- Delegates to the pool-specific filter function, which will parse the
  output and resolve/reject the associated task's promise."
  (when-let ((worker (process-get proc 'loom-abstract-worker)))
    (when-let ((filter-fn (loom-abstract-pool-worker-ipc-filter-fn pool)))
      (funcall filter-fn worker chunk pool))))

(defun loom--abstract-pool-start-worker (worker pool)
  "Start a WORKER using the POOL's factory and configure its IPC.

Arguments:
- `WORKER` (loom-abstract-worker): The worker instance to start.
- `POOL` (loom-abstract-pool): The pool owning the worker.

Side Effects:
- Sets the worker's status to `:starting`, then `:idle`.
- Calls the pool's `worker-factory-fn` to create the OS process.
- Attaches sentinel and filter dispatchers to the new process.
- Associates the worker struct with the process via `process-put`.
- Updates the worker's `last-active-time`."
  (let ((worker-id (loom-abstract-worker-id worker)))
    (loom-log-debug worker-id "Worker process starting.")
    (setf (loom-abstract-worker-status worker) :starting)
    (funcall (loom-abstract-pool-worker-factory-fn pool) worker pool)
    (let ((proc (loom-abstract-worker-process worker)))
      (process-put proc 'loom-abstract-worker worker)
      (set-process-sentinel
       proc
       (lambda (p e) (loom--abstract-worker-sentinel-dispatcher p e pool)))
      (set-process-filter
       proc
       (lambda (p c) (loom--abstract-worker-filter-dispatcher p c pool)))
      (setf (loom-abstract-worker-status worker) :idle)
      (setf (loom-abstract-worker-last-active-time worker) (float-time))
      (loom-log-debug worker-id "Worker process started and is now idle."))))

(defun loom--abstract-pool-add-worker (pool)
  "Create, start, and add a new worker to the POOL.
This function must be called from within the pool's lock.

Arguments:
- `POOL` (loom-abstract-pool): The pool to add a worker to.

Returns:
The newly created `loom-abstract-worker` instance.

Side Effects:
- Increments the pool's `next-worker-id`.
- Appends a new worker to the pool's `workers` list.
- Starts the new worker process via `loom--abstract-pool-start-worker`."
  (let* ((id (cl-incf (loom-abstract-pool-next-worker-id pool)))
         (worker (%%make-abstract-worker :id id)))
    (loom-log-info (loom-abstract-pool-name pool) "Adding new worker %d." id)
    (add-to-list 'loom-abstract-pool-workers worker :append t)
    (loom--abstract-pool-start-worker worker pool)
    worker))

(defun loom--abstract-pool-remove-worker (worker pool)
  "Stop and remove a WORKER from the POOL.
This function must be called from within the pool's lock.

Arguments:
- `WORKER` (loom-abstract-worker): The worker to remove.
- `POOL` (loom-abstract-pool): The pool owning the worker.

Side Effects:
- Removes the worker from the pool's `workers` list.
- Kills the underlying OS process.
- Sets the worker's status to `:stopped`."
  (let ((worker-id (loom-abstract-worker-id worker)))
    (loom-log-info (loom-abstract-pool-name pool) "Removing worker %d." worker-id)
    (setf (loom-abstract-pool-workers pool)
          (delete worker (loom-abstract-pool-workers pool)))
    (setf (loom-abstract-worker-status worker) :stopping)
    (when-let ((proc (loom-abstract-worker-process worker)))
      (when (process-live-p proc)
        (delete-process proc)))
    (setf (loom-abstract-worker-status worker) :stopped)
    (loom-log-debug worker-id "Worker stopped and removed.")))

(defun loom--abstract-pool-dispatch-next-task (pool)
  "Find an idle worker and dispatch the next task or waiting session.
This is the core dispatch logic. It first tries to find an idle worker for
a pending task. If none are available but the pool can scale up, it will
create a new worker. Must be called inside the pool's lock.

Arguments:
- `POOL` (loom-abstract-pool): The pool to dispatch work for.

Side Effects:
- May dequeue a task or a session waiter.
- May change a worker's status to `:busy` or `:reserved`.
- May create a new worker if scaling up is possible."
  (unless (loom-abstract-pool-shutdown-p pool)
    (let ((worker (cl-find-if (lambda (w)
                                (eq (loom-abstract-worker-status w) :idle))
                              (loom-abstract-pool-workers pool))))
      (cond
       ;; Case 1: An idle worker is available. Dispatch a session or task.
       (worker
        (if-let ((waiter (loom:queue-dequeue
                         (loom-abstract-pool-waiter-queue pool))))
            (progn
              (loom-log-debug (loom-abstract-pool-name pool)
                              "Granting session to worker %d."
                              (loom-abstract-worker-id worker))
              (setf (loom-abstract-worker-status worker) :reserved)
              (funcall (car waiter) worker)) ; Resolve waiter's promise
          (let ((queue (loom-abstract-pool-task-queue pool)))
            (unless (loom:queue-empty-p queue)
              (loom-log-debug (loom-abstract-pool-name pool)
                              "Idle worker %d found for next task."
                              (loom-abstract-worker-id worker))
              (loom--abstract-pool-dispatch-to-task
               (loom:queue-dequeue queue) worker pool)))))
       ;; Case 2: No idle worker, but we can scale up. Create a new worker.
       ((< (length (loom-abstract-pool-workers pool))
           (loom-abstract-pool-max-size pool))
        (unless (loom:queue-empty-p (loom-abstract-pool-task-queue pool))
          (loom-log-info (loom-abstract-pool-name pool)
                         "Scaling up. Creating new worker for pending task.")
          (let ((new-worker (loom--abstract-pool-add-worker pool)))
            (loom--abstract-pool-dispatch-to-task
             (loom:queue-dequeue (loom-abstract-pool-task-queue pool))
             new-worker pool))))))))

(defun loom--abstract-pool-release-worker (worker pool)
  "Release a WORKER back to the POOL, making it available for new tasks.

Arguments:
- `WORKER` (loom-abstract-worker): The worker to release.
- `POOL` (loom-abstract-pool): The pool owning the worker.

Side Effects:
- Sets the worker's status to `:idle` and resets its state.
- Triggers a new dispatch cycle."
  (loom:with-mutex! (loom-abstract-pool-lock pool)
    (loom-log-debug (loom-abstract-worker-id worker)
                    "Worker released, status set to :idle.")
    (setf (loom-abstract-worker-status worker) :idle)
    (setf (loom-abstract-worker-current-task worker) nil)
    (setf (loom-abstract-worker-restart-attempts worker) 0)
    (setf (loom-abstract-worker-last-active-time worker) (float-time))
    (loom--abstract-pool-dispatch-next-task pool)))

(defun loom--abstract-pool-handle-worker-output (worker task output pool)
  "Handle a single parsed OUTPUT from a WORKER for a given TASK.
This function interprets the IPC message from the worker and acts accordingly.

Arguments:
- `WORKER` (loom-abstract-worker): The worker that produced the output.
- `TASK` (loom-abstract-task): The task being executed.
- `OUTPUT` (plist): The parsed output from the worker's filter.
- `POOL` (loom-abstract-pool): The pool instance.

Side Effects:
- Resolves, rejects, or sends messages to the task's promise.
- Increments pool metrics (`tasks-completed`, `tasks-failed`).
- Releases the worker back to the pool on task completion or error."
  (let ((task-id (loom-abstract-task-id task)))
    (pcase (plist-get output :type)
      (:result
       (loom-log-debug task-id "Task completed successfully.")
       (cl-incf (loom-abstract-pool-tasks-completed pool))
       (loom:resolve (loom-abstract-task-promise task)
                     (funcall (loom-abstract-pool-result-parser-fn pool)
                              (plist-get output :payload)))
       (loom--abstract-pool-release-worker worker pool))
      (:error
       (let ((parsed-error (funcall (loom-abstract-pool-error-parser-fn pool)
                                    (plist-get output :payload))))
         (loom-log-warn task-id "Task failed in worker. Reason: %S" parsed-error)
         (cl-incf (loom-abstract-pool-tasks-failed pool))
         (loom:reject
          (loom-abstract-task-promise task)
          (loom:make-error
           :type 'loom-abstract-pool-task-error
           :message "Task failed in worker."
           :cause parsed-error))
         (loom--abstract-pool-release-worker worker pool)))
      (:message
       (loom-log-trace task-id "Received progress message from worker.")
       (when-let ((cb (loom-abstract-task-on-message-fn task)))
         (funcall cb (funcall (loom-abstract-pool-message-parser-fn pool)
                              (plist-get output :payload)))))
      (_ (loom-log-warn (loom-abstract-worker-id worker)
                        "Unknown message type from worker: %S" output)))))

(defun loom--abstract-pool-requeue-or-reject (task pool)
  "Handle a TASK whose worker died. Re-queues or rejects as a poison pill.
If a task causes a worker to crash repeatedly, it is considered a \"poison
pill\" and is rejected to prevent it from taking down the entire pool.

Arguments:
- `TASK` (loom-abstract-task): The task to handle.
- `POOL` (loom-abstract-pool): The pool instance.

Side Effects:
- Increments the task's retry count.
- Re-enqueues the task or rejects its promise with a `poison-pill` error."
  (cl-incf (loom-abstract-task-retries task))
  (let ((task-id (loom-abstract-task-id task)))
    (if (> (loom-abstract-task-retries task)
           loom-abstract-pool-max-worker-restarts)
        (progn
          (loom-log-error task-id
                          "Task is a poison pill, has crashed workers %d times. \
Rejecting."
                          (loom-abstract-task-retries task))
          (cl-incf (loom-abstract-pool-tasks-failed pool))
          (loom:reject (loom-abstract-task-promise task)
                       (loom:make-error
                        :type 'loom-abstract-pool-poison-pill
                        :message "Task repeatedly crashed workers.")))
      (loom-log-warn task-id "Worker died. Re-queuing task (attempt %d)."
                     (loom-abstract-task-retries task))
      (let ((queue (loom-abstract-pool-task-queue pool)))
        (funcall (if (eq (type-of queue) 'loom-priority-queue)
                     #'loom:priority-queue-insert #'loom:queue-enqueue)
                 queue task)))))

(defun loom--abstract-pool-restart-or-fail-worker (worker pool)
  "Restart a dead WORKER or mark it as permanently failed.

Arguments:
- `WORKER` (loom-abstract-worker): The worker to handle.
- `POOL` (loom-abstract-pool): The pool instance.

Side Effects:
- Changes the worker's status to `:dead`, `:restarting`, or `:failed`.
- May start a new process for the worker."
  (let ((worker-id (loom-abstract-worker-id worker)))
    (setf (loom-abstract-worker-status worker) :dead)
    (unless (loom-abstract-pool-shutdown-p pool)
      (cl-incf (loom-abstract-worker-restart-attempts worker))
      (if (> (loom-abstract-worker-restart-attempts worker)
             loom-abstract-pool-max-worker-restarts)
          (progn
            (loom-log-error (loom-abstract-pool-name pool)
                            "Worker %d failed %d consecutive restarts. \
Marking as failed."
                            worker-id
                            (loom-abstract-worker-restart-attempts worker))
            (setf (loom-abstract-worker-status worker) :failed))
        (progn
          (loom-log-warn (loom-abstract-pool-name pool)
                         "Restarting worker %d (attempt %d)."
                         worker-id (loom-abstract-worker-restart-attempts worker))
          (setf (loom-abstract-worker-status worker) :restarting)
          (loom--abstract-pool-start-worker worker pool))))))

(defun loom--abstract-pool-handle-worker-death (worker event pool)
  "Handle WORKER death, managing restarts and re-queuing its task.

Arguments:
- `WORKER` (loom-abstract-worker): The worker that died.
- `EVENT` (string): The sentinel event string.
- `POOL` (loom-abstract-pool): The pool instance.

Side Effects:
- Re-queues the worker's current task if it exists.
- Restarts the worker or marks it as failed.
- Triggers a new dispatch cycle."
  (loom-log-warn (loom-abstract-worker-id worker)
                 "Worker process died unexpectedly. Event: %s" event)
  (when-let ((task (loom-abstract-worker-current-task worker)))
    (loom--abstract-pool-requeue-or-reject task pool))
  (loom:with-mutex! (loom-abstract-pool-lock pool)
    (loom--abstract-pool-restart-or-fail-worker worker pool)
    (loom--abstract-pool-dispatch-next-task pool)))

(defun loom--abstract-pool-dispatch-to-task (task worker pool)
  "Assign a TASK to an idle WORKER.

Arguments:
- `TASK` (loom-abstract-task): The task to dispatch.
- `WORKER` (loom-abstract-worker): The worker to assign the task to.
- `POOL` (loom-abstract-pool): The pool instance.

Side Effects:
- Sets the worker's status to `:busy` and assigns the task.
- Serializes the task and sends it to the worker process.
- If sending fails, re-queues the task and kills the worker."
  (let ((serialized
         (funcall (loom-abstract-pool-task-serializer-fn pool) task))
        (worker-id (loom-abstract-worker-id worker))
        (task-id (loom-abstract-task-id task)))
    (loom-log-debug (loom-abstract-pool-name pool)
                    "Dispatching task %s to worker %d." task-id worker-id)
    (setf (loom-abstract-worker-status worker) :busy)
    (setf (loom-abstract-worker-current-task worker) task)
    (setf (loom-abstract-task-worker task) worker)
    (setf (loom-abstract-task-start-time task) (float-time))
    (condition-case err
        (process-send-string (loom-abstract-worker-process worker)
                             (concat serialized "\n"))
      (error
       ;; If we can't send to the worker, it's probably dead or stuck.
       ;; Re-queue the task at the front and kill the process. The sentinel
       ;; will then handle the restart logic.
       (loom-log-warn (loom-abstract-pool-name pool)
                      "Failed to send task %s to worker %d: %S. \
Re-queuing task and killing worker."
                      task-id worker-id err)
       (let ((queue (loom-abstract-pool-task-queue pool)))
         (funcall (if (eq (type-of queue) 'loom-priority-queue)
                      (lambda (q t) (loom:priority-queue-insert q t 0))
                    #'loom:queue-enqueue-front)
                  queue task))
       (delete-process (loom-abstract-worker-process worker))))))

(defun loom--abstract-pool-manage (pool)
  "Periodically manage the pool: scale down and check for timed-out tasks.
This function is run by a timer.

Arguments:
- `POOL` (loom-abstract-pool): The pool to manage.

Side Effects:
- May kill workers due to task timeouts.
- May remove idle workers to scale the pool down."
  (loom:with-mutex! (loom-abstract-pool-lock pool)
    (unless (loom-abstract-pool-shutdown-p pool)
      (let ((now (float-time))
            (idle-timeout (loom-abstract-pool-worker-idle-timeout pool))
            (pool-name (loom-abstract-pool-name pool)))
        ;; --- Health Check: Find and kill timed-out tasks ---
        (dolist (worker (loom-abstract-pool-workers pool))
          (when-let* ((task (loom-abstract-worker-current-task worker))
                      (timeout (loom-abstract-task-timeout task))
                      (start-time (loom-abstract-task-start-time task)))
            (when (> (- now start-time) timeout)
              (loom-log-warn pool-name
                             "Task %s on worker %d timed out after %.2f seconds. \
Killing worker."
                             (loom-abstract-task-id task)
                             (loom-abstract-worker-id worker)
                             timeout)
              (cl-incf (loom-abstract-pool-tasks-failed pool))
              (loom:reject (loom-abstract-task-promise task)
                           (make-instance 'loom-abstract-pool-task-timeout))
              ;; Killing the process is the most reliable way to stop a
              ;; timed-out task. The sentinel will then handle the cleanup
              ;; and restart logic automatically.
              (delete-process (loom-abstract-worker-process worker)))))

        ;; --- Scale Down: Find and remove excess idle workers ---
        (when idle-timeout
          (let* ((idle-workers (-filter
                                (lambda (w)
                                  (eq (loom-abstract-worker-status w) :idle))
                                (loom-abstract-pool-workers pool)))
                 (num-to-reap (- (length (loom-abstract-pool-workers pool))
                                 (loom-abstract-pool-min-size pool))))
            (dolist (worker idle-workers)
              (when (and (> num-to-reap 0)
                         (> (- now (loom-abstract-worker-last-active-time
                                    worker))
                            idle-timeout))
                (loom-log-info pool-name "Scaling down. Reaping idle worker %d."
                               (loom-abstract-worker-id worker))
                (loom--abstract-pool-remove-worker worker pool)
                (cl-decf num-to-reap)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom-abstract-pool-create (&key name
                                          (min-size
                                           loom-abstract-pool-default-min-size)
                                          (max-size
                                           loom-abstract-pool-default-max-size)
                                          worker-idle-timeout
                                          max-queue-size
                                          (task-queue-type :fifo)
                                          worker-factory-fn
                                          worker-ipc-filter-fn
                                          worker-ipc-sentinel-fn
                                          task-serializer-fn
                                          task-cancel-fn
                                          result-parser-fn
                                          error-parser-fn
                                          message-parser-fn)
  "Create and initialize a new abstract worker pool.
This is the low-level constructor. Users should prefer the constructor
function generated by `loom:defpool!`.

Arguments:
- `:name` (string): A descriptive name for the pool.
- `:min-size` (integer): Minimum number of workers to keep alive.
- `:max-size` (integer): Maximum number of workers to scale up to.
- `:worker-idle-timeout` (number): Seconds a worker can be idle before being
  considered for scale-down.
- `:max-queue-size` (integer): Max tasks in queue before rejecting new ones.
- `:task-queue-type` (keyword): `:fifo` or `:priority`.
- `:worker-factory-fn` (function): `(lambda (worker pool))` to create a process.
- `:worker-ipc-filter-fn` (function): `(lambda (worker chunk pool))` for output.
- `:worker-ipc-sentinel-fn` (function): `(lambda (worker event pool))` for death.
- `:task-serializer-fn` (function): `(lambda (task))` to serialize a task.
- `:task-cancel-fn` (function): `(lambda (worker task pool))` for cancellation.
- `:result-parser-fn` (function): `(lambda (payload))` to parse a success result.
- `:error-parser-fn` (function): `(lambda (payload))` to parse an error result.
- `:message-parser-fn` (function): `(lambda (payload))` for a progress message.

Returns:
A new `loom-abstract-pool` instance.

Side Effects:
- Creates `min-size` worker processes.
- Starts a management timer for scaling and health checks."
  (unless (and (integerp max-size) (> max-size 0) (>= max-size min-size))
    (error "Pool size must be positive, and max-size >= min-size"))
  (let* ((pool-name (or name "abstract-pool"))
         (task-queue (pcase task-queue-type
                       (:fifo (loom:queue))
                       (:priority (loom:priority-queue))
                       (_ (error "Invalid :task-queue-type"))))
         (pool (%%make-abstract-pool
                :name pool-name
                :lock (loom:lock (format "pool-lock-%s" pool-name))
                :task-queue task-queue
                :waiter-queue (loom:queue)
                :min-size min-size :max-size max-size
                :worker-idle-timeout worker-idle-timeout
                :max-queue-size max-queue-size
                :worker-factory-fn worker-factory-fn
                :worker-ipc-filter-fn worker-ipc-filter-fn
                :worker-ipc-sentinel-fn worker-ipc-sentinel-fn
                :task-serializer-fn task-serializer-fn
                :task-cancel-fn (or task-cancel-fn
                                    ;; The default cancellation is to kill the
                                    ;; worker process. This is robust but blunt.
                                    (lambda (worker _task _pool)
                                      (delete-process
                                       (loom-abstract-worker-process worker))))
                :result-parser-fn result-parser-fn
                :error-parser-fn error-parser-fn
                :message-parser-fn message-parser-fn)))
    (loom-log-info pool-name "Pool created. Min size: %d, Max size: %d"
                   min-size max-size)
    ;; Start the initial set of workers.
    (dotimes (_ min-size)
      (loom--abstract-pool-add-worker pool))
    ;; Start the periodic management timer.
    (setf (loom-abstract-pool-management-timer pool)
          (run-with-timer 0 loom-abstract-pool-management-interval
                          #'loom--abstract-pool-manage pool))
    pool))

;;;###autoload
(cl-defun loom-abstract-pool-submit
    (pool payload &key on-message context priority cancel-token timeout worker)
  "Submit a PAYLOAD to the worker POOL (internal use).
Users should prefer the `-submit` function generated by
`loom:defpool!`.

Arguments:
- `POOL` (loom-abstract-pool): The target pool.
- `PAYLOAD` (any): The primary data for the task.
- `:on-message` (function): A callback `(lambda (message))` for progress.
- `:context` (any): Additional data passed to the serializer.
- `:priority` (integer): The task's priority for priority queues.
- `:cancel-token` (loom-cancel-token): A token to cancel the task.
- `:timeout` (number): Seconds before the task is considered failed.
- `:worker` (loom-abstract-worker): A specific worker to run on (for sessions).

Returns:
A `loom-promise` that will resolve with the task's result.

Side Effects:
- Creates a task and enqueues it.
- Triggers the dispatch logic.
- Increments the `tasks-submitted` metric.
- May reject the promise immediately if the pool is shutdown or the queue is full.

Signals:
- `loom-invalid-abstract-pool-error` if POOL is invalid."
  (loom--validate-abstract-pool pool 'loom-abstract-pool-submit)
  (let* ((promise (loom:promise :cancel-token cancel-token))
         (task-id (make-temp-name "task-"))
         (task (%%make-abstract-task
                :promise promise
                :id task-id
                :payload payload
                :context context
                :on-message-fn on-message
                :priority (or priority 50)
                :cancel-token cancel-token
                :timeout timeout
                :worker worker)))
    (loom-log-debug task-id "Task submitted to pool '%s'."
                    (loom-abstract-pool-name pool))
    ;; Set up the cancellation callback.
    (when cancel-token
      (loom:cancel-token-add-callback
       (loom-abstract-task-cancel-token task)
       (lambda (_)
         (loom:with-mutex! (loom-abstract-pool-lock pool)
           ;; Cancellation is a two-step process. First, try to remove the
           ;; task from the queue, in case it hasn't started yet.
           (let* ((queue (loom-abstract-pool-task-queue pool))
                  (was-removed (funcall
                                (if (eq (type-of queue) 'loom-priority-queue)
                                    #'loom:priority-queue-remove
                                  #'loom:queue-remove)
                                queue task)))
             ;; If it wasn't in the queue, it must be running.
             ;; In that case, call the pool's specific cancel function.
             (if was-removed
                 (loom-log-debug task-id "Task cancelled before execution.")
               (when-let* ((w (loom-abstract-task-worker task)))
                 (when (eq (loom-abstract-worker-current-task w) task)
                   (loom-log-debug task-id
                                   "Sending cancellation request to worker %d."
                                   (loom-abstract-worker-id w))
                   (funcall (loom-abstract-pool-task-cancel-fn pool)
                            w task pool)))))))))
    ;; Enqueue the task, respecting backpressure.
    (loom:with-mutex! (loom-abstract-pool-lock pool)
      (cond
       ((loom-abstract-pool-shutdown-p pool)
        (loom-log-warn task-id "Task rejected, pool is shut down.")
        (loom:reject promise (loom:make-error
                              :type 'loom-abstract-pool-shutdown)))
       ((and (loom-abstract-pool-max-queue-size pool)
             (> (loom:queue-length (loom-abstract-pool-task-queue pool))
                (loom-abstract-pool-max-queue-size pool)))
        (loom-log-warn task-id
                       "Task rejected, queue is full (size: %d, max: %d)."
                       (loom:queue-length (loom-abstract-pool-task-queue pool))
                       (loom-abstract-pool-max-queue-size pool))
        (loom:reject promise (loom:make-error
                              :type 'loom-abstract-pool-queue-full)))
       (t
        (cl-incf (loom-abstract-pool-tasks-submitted pool))
        (if worker
            (loom--abstract-pool-dispatch-to-task task worker pool)
          (let ((queue (loom-abstract-pool-task-queue pool)))
            (loom-log-debug task-id "Task enqueued.")
            (funcall (if (eq (type-of queue) 'loom-priority-queue)
                         #'loom:priority-queue-insert #'loom:queue-enqueue)
                     queue task))
          (loom--abstract-pool-dispatch-next-task pool)))))
    promise))

;;;###autoload
(cl-defmacro loom-abstract-pool-session ((session-var &key pool) &rest body)
  "Reserve a single worker from POOL for a sequence of commands.
This macro provides exclusive access to a worker for the duration of BODY.
The worker is automatically released when BODY completes.

Arguments:
- `SESSION-VAR` (symbol): Variable bound to a lambda `(lambda (payload ...))`
  that submits a task to the reserved worker.
- `:pool` (loom-abstract-pool): The pool to reserve a worker from.
- `BODY` (forms): The code to execute with the reserved worker."
  `(let ((pool-instance ,pool))
     (loom--validate-abstract-pool pool-instance 'loom-abstract-pool-session)
     (loom-log-debug (loom-abstract-pool-name pool-instance)
                     "Session requested, enqueuing waiter.")
     (loom:then
      (loom:promise
       :executor
       (lambda (resolve reject)
         (loom:with-mutex! (loom-abstract-pool-lock pool-instance)
           (if (loom-abstract-pool-shutdown-p pool-instance)
               (funcall reject (loom:make-error
                                :type :loom-abstract-pool-shutdown))
             ;; Enqueue a waiter. The dispatcher will resolve this promise
             ;; with a worker when one becomes available.
             (loom:queue-enqueue
              (loom-abstract-pool-waiter-queue pool-instance)
              (cons resolve reject))
             (loom--abstract-pool-dispatch-next-task pool-instance)))))
      (lambda (worker)
        ;; Once we have a worker, bind SESSION-VAR to a submission lambda.
        (loom-log-debug (loom-abstract-worker-id worker)
                        "Session granted to worker.")
        (let ((,session-var
               (lambda (payload &rest context-keys)
                 (apply #'loom-abstract-pool-submit
                        pool-instance payload
                        :worker worker
                        context-keys))))
          ;; Ensure the worker is released, even if BODY has an error.
          (loom:finally (progn ,@body)
                        (lambda ()
                          (loom-log-debug (loom-abstract-worker-id worker)
                                          "Session ended, releasing worker.")
                          (loom--abstract-pool-release-worker
                           worker pool-instance))))))))

;;;###autoload
(defun loom-abstract-pool-shutdown! (pool)
  "Gracefully shut down an abstract worker POOL.
This stops all workers, rejects all pending and in-progress tasks, and
cleans up all associated resources.

Arguments:
- `POOL` (loom-abstract-pool): The pool to shut down.

Returns:
`nil`.

Side Effects:
- Cancels the management timer.
- Kills all worker processes.
- Rejects promises for all tasks in the pool.
- Clears all internal queues."
  (interactive)
  (loom--validate-abstract-pool pool 'loom-abstract-pool-shutdown!)
  (let ((pool-name (loom-abstract-pool-name pool)))
    (loom-log-info pool-name "Shutdown initiated.")
    (when-let ((timer (loom-abstract-pool-management-timer pool)))
      (loom-log-debug pool-name "Cancelling management timer.")
      (cancel-timer timer))
    (loom:with-mutex! (loom-abstract-pool-lock pool)
      (unless (loom-abstract-pool-shutdown-p pool)
        (setf (loom-abstract-pool-shutdown-p pool) t)
        (let ((err (loom:make-error :type :loom-abstract-pool-shutdown)))
          ;; Kill all workers and reject their current tasks.
          (loom-log-debug pool-name "Killing all worker processes.")
          (dolist (worker (loom-abstract-pool-workers pool))
            (when-let ((task (loom-abstract-worker-current-task worker)))
              (loom-log-debug (loom-abstract-task-id task)
                              "Rejecting in-progress task due to shutdown.")
              (loom:reject (loom-abstract-task-promise task) err))
            (when-let ((proc (loom-abstract-worker-process worker)))
              (when (process-live-p proc) (delete-process proc))))
          ;; Reject all tasks remaining in the queue.
          (loom-log-debug pool-name "Rejecting all pending tasks in queue.")
          (let ((task-queue (loom-abstract-pool-task-queue pool)))
            (while-let ((task (ignore-errors (loom:queue-dequeue task-queue))))
              (loom:reject (loom-abstract-task-promise task) err)))
          ;; Reject all waiting session requests.
          (loom-log-debug pool-name "Rejecting all waiting session requests.")
          (while-let ((waiter (loom:queue-dequeue
                               (loom-abstract-pool-waiter-queue pool))))
            (funcall (cdr waiter) err)))
        (setf (loom-abstract-pool-workers pool) nil)
        (loom-log-info pool-name "Shutdown complete.")))
    nil))

;;;###autoload
(defun loom-abstract-pool-status (pool)
  "Return a snapshot of the POOL's status and metrics.

Arguments:
- `POOL` (loom-abstract-pool): The pool to inspect.

Returns:
- A plist containing the pool's configuration, worker status counts,
  queue lengths, and performance metrics."
  (loom--validate-abstract-pool pool 'loom-abstract-pool-status)
  (loom:with-mutex! (loom-abstract-pool-lock pool)
    (let ((worker-statii (mapcar #'loom-abstract-worker-status
                                 (loom-abstract-pool-workers pool))))
      `(:name ,(loom-abstract-pool-name pool)
        :shutdown-p ,(loom-abstract-pool-shutdown-p pool)
        :config (:min-size ,(loom-abstract-pool-min-size pool)
                 :max-size ,(loom-abstract-pool-max-size pool)
                 :worker-idle-timeout
                 ,(loom-abstract-pool-worker-idle-timeout pool)
                 :max-queue-size ,(loom-abstract-pool-max-queue-size pool))
        :workers (:total ,(length worker-statii)
                  :idle ,(cl-count :idle worker-statii)
                  :busy ,(cl-count :busy worker-statii)
                  :other ,(cl-count-if-not (lambda (s) (memq s '(:idle :busy)))
                                           worker-statii))
        :queue (:tasks ,(loom:queue-length (loom-abstract-pool-task-queue pool)))
                :waiters
                ,(loom:queue-length (loom-abstract-pool-waiter-queue pool)))
        :metrics (:submitted ,(loom-abstract-pool-tasks-submitted pool)
                   :completed ,(loom-abstract-pool-tasks-completed pool)
                   :failed ,(loom-abstract-pool-tasks-failed pool))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Pool Type Definition Factory

;;;###autoload
(defmacro loom:defpool! (name &key create submit session shutdown status)
  "Define a new, specialized worker pool type.
This macro generates a standard set of functions for a new pool type
(e.g., `my-pool-create`, `my-pool-submit-task`) that wrap the underlying
abstract pool implementation.

Arguments:
- `NAME` (symbol): The base name for the new pool type (e.g., `my-pool`).
- `:CREATE` (form): A form `(lambda (&rest args))` that evaluates to the
  `loom-abstract-pool` object.
- `:SUBMIT` (form): A form `(lambda (pool payload &rest keys))` for submitting
  a task.
- `:SESSION` (form): A form `(lambda (pool &rest body))` for sessions.
- `:SHUTDOWN` (form): An optional form `(lambda (pool))` for shutdown.
  Defaults to `loom-abstract-pool-shutdown!`.
- `:STATUS` (form): An optional form `(lambda (pool))` for status.
  Defaults to `loom-abstract-pool-status`."
  (declare (indent 1) (debug t))
  (let* ((prefix (symbol-name name))
         (create-fn-name (intern (format "%s-pool-create" prefix)))
         (submit-fn-name (intern (format "%s-pool-submit" prefix)))
         (session-macro-name (intern (format "%s-pool-session" prefix)))
         (shutdown-fn-name (intern (format "%s-pool-shutdown!" prefix)))
         (status-fn-name (intern (format "%s-pool-status" prefix)))
         (default-shutdown `(lambda (pool) (loom-abstract-pool-shutdown! pool)))
         (default-status `(lambda (pool) (loom-abstract-pool-status pool))))
    `(progn
       (cl-defun ,create-fn-name (&rest args)
         ,(format "Create a new `%s` worker pool." prefix)
         (apply ,create args))
       (put ',create-fn-name 'lisp-indent-function 'defun)
       (autoload ',create-fn-name (file-name-nondirectory buffer-file-name))

       (cl-defun ,submit-fn-name (pool payload &rest keys)
         ,(format "Submit a task (`PAYLOAD`) to the `%s` worker pool `POOL`."
                  prefix)
         (apply ,submit pool payload keys))
       (put ',submit-fn-name 'lisp-indent-function 'defun)
       (autoload ',submit-fn-name (file-name-nondirectory buffer-file-name))

       (defmacro ,session-macro-name ((session-var &key pool) &rest body)
         ,(format "Reserve a worker from `%s` POOL for a stateful session."
                  prefix)
         `(loom-abstract-pool-session (,session-var :pool ,pool) ,@body))
       (put ',session-macro-name 'lisp-indent-function 1)
       (autoload ',session-macro-name (file-name-nondirectory buffer-file-name))

       (defun ,shutdown-fn-name (pool)
         ,(format "Gracefully shut down the `%s` worker pool `POOL`." prefix)
         (funcall ,(or shutdown default-shutdown) pool))
       (put ',shutdown-fn-name 'lisp-indent-function 'defun)
       (autoload ',shutdown-fn-name (file-name-nondirectory buffer-file-name))

       (defun ,status-fn-name (pool)
         ,(format "Return a snapshot of the `%s` POOL's status." prefix)
         (funcall ,(or status default-status) pool))
       (put ',status-fn-name 'lisp-indent-function 'defun)
       (autoload ',status-fn-name (file-name-nondirectory buffer-file-name))
       ',name)))

(provide 'loom-abstract-pool)
;;; loom-abstract-pool.el ends here