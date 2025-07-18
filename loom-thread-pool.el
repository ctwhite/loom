;;; loom-thread-pool.el --- Promise-Based Thread Pool -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides a generic, thread-safe, and promise-based
;; mechanism for executing tasks in a pool of background threads. It is
;; a high-level utility for offloading computations from the main Emacs
;; thread without blocking the UI.
;;
;; Each submitted task returns a `loom-promise`, which will be settled
;; with the task's result or any error it produces. This allows for
;; seamless integration with the rest of the Loom concurrency ecosystem.
;;
;; ## Key Features
;;
;; - **Promise-Based API:** `loom:thread-pool-submit` immediately returns
;;   a promise for the result of the submitted task.
;; - **Robust Error Handling:** Errors within worker threads are caught
;;   and used to reject the corresponding promise, preventing silent failures.
;; - **Event-Driven Processing:** Threads wait on a shared condition variable,
;;   waking only when new tasks are submitted.
;; - **Thread-Safe:** All queue operations are protected by a mutex.
;; - **Graceful Shutdown:** All pools are tracked and automatically shut
;;   down when Emacs exits.
;; - **Status Inspection:** Provides a function to query a pool's current state.

;;; Code:

(require 'cl-lib)
(require 'thread)

(require 'loom-log)
(require 'loom-lock)
(require 'loom-queue)
(require 'loom-errors)
(require 'loom-promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom--all-thread-pools '()
  "A list of all active `loom-thread-pool` instances.
This is used by the shutdown hook to ensure all pools are cleanly
terminated when Emacs exits.")

(defvar loom--default-thread-pool-instance nil
  "The default `loom-thread-pool` instance, managed by
`loom:thread-pool-default`.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-thread-pool-default-size (max 1 (num-processors))
  "Default number of worker threads for the default thread pool.
Defaults to the number of CPU cores on the system (minimum 1)."
  :type 'integer
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-thread-pool-error
  "A generic error related to a `loom-thread-pool`."
  'loom-error)

(define-error 'loom-thread-pool-uninitialized-error
  "Error signaled when an operation is attempted on an invalid pool."
  'loom-thread-pool-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-thread-pool-task (:constructor %%make-thread-pool-task))
  "Internal struct representing a task to be executed by the pool.
This struct links a promise with the function that should be executed
to settle it.

Fields:
- `promise` (loom-promise): The promise that will be settled with the
  result of the task.
- `task-fn` (function): The function to execute in a worker thread.
- `task-args` (list): A list of arguments to pass to `task-fn`."
  (promise nil :type (satisfies loom-promise-p))
  (task-fn nil :type function)
  (task-args nil :type list))

(cl-defstruct (loom-thread-pool (:constructor %%make-loom-thread-pool)
                                (:copier nil))
  "Represents an asynchronous, promise-based thread pool instance.

Fields:
- `name` (string): A descriptive name for the pool, used in logs.
- `threads` (list): The list of worker `thread` objects.
- `queue` (loom-queue): The shared queue for incoming tasks.
- `lock` (loom-lock): A mutex protecting the queue and condition variable.
- `condition-var` (condition-variable): Signals waiting threads about
  new tasks or shutdown.
- `running` (boolean): A flag indicating if the pool is active."
  (name             nil :type string)
  (threads          nil :type list)
  (queue            nil :type loom-queue)
  (lock             nil :type loom-lock)
  (condition-var    nil :type condition-variable)
  (running          nil :type boolean))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Functions

(defun loom--thread-pool-worker-loop-fn (pool)
  "The main loop for each thread in the `loom-thread-pool`.
It continuously dequeues and processes tasks from the shared queue.
For each task, it executes the associated function and uses its
result or error to settle the task's promise.

Arguments:
- `POOL` (loom-thread-pool): The pool instance this thread belongs to.

Side Effects:
- Blocks waiting for tasks on the pool's condition variable.
- Dequeues items from the pool's shared queue.
- Executes task functions.
- Calls `loom:resolve` or `loom:reject`, which dispatches a message
  to the main thread to settle the promise."
  (let ((thread-name (thread-name (current-thread)))
        (pool-name (loom-thread-pool-name pool)))
    (loom-log :info nil "Thread '%s' started for pool '%s'."
              thread-name pool-name)
    (cl-block worker-loop
      (while (loom-thread-pool-running pool)
        (let (task-to-process)
          ;; Acquire lock to safely check queue and wait.
          (loom:with-mutex! (loom-thread-pool-lock pool)
            ;; Wait only if the pool is running and the queue is empty.
            (while (and (loom-thread-pool-running pool)
                        (loom:queue-empty-p (loom-thread-pool-queue pool)))
              (condition-wait (loom-thread-pool-condition-var pool)))

            (if (not (loom-thread-pool-running pool))
                (cl-return-from worker-loop) ; Exit loop if pool stopped.
              (setq task-to-process
                    (loom:queue-dequeue (loom-thread-pool-queue pool)))))

          ;; Process the task outside the mutex to maximize concurrency.
          (when task-to-process
            (let* ((promise (loom-thread-pool-task-promise task-to-process))
                   (task-fn (loom-thread-pool-task-task-fn task-to-process))
                   (task-args (loom-thread-pool-task-task-args task-to-process)))
              (loom-log :debug nil "Thread '%s' processing task for promise %S"
                        thread-name (loom-promise-id promise))
              ;; Execute the task and settle the promise with the outcome.
              (condition-case err
                  (let ((result (apply task-fn task-args)))
                    (loom:resolve promise result))
                (error
                 (loom:reject promise err))))))
        ;; Cooperatively yield to other threads.
        (thread-yield)))
    (loom-log :info nil "Thread '%s' stopping for pool '%s'."
              thread-name pool-name)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:thread-pool-init (&key name (pool-size 1))
  "Initialize and start a new background thread pool instance.

Arguments:
- `:NAME` (string, optional): A descriptive name for the pool, used in logs.
  Defaults to a unique generated name like \"pool-NNN\".
- `:POOL-SIZE` (integer, optional): The number of worker threads in the pool.
  Defaults to 1.

Returns:
A new, running `loom-thread-pool` struct instance.

Side Effects:
- Creates and starts `POOL-SIZE` new background threads.
- Adds the new pool to a global tracking list for automatic cleanup.

Signals:
- `error`: If Emacs lacks thread support or `POOL-SIZE` is invalid."
  (unless (fboundp 'make-thread)
    (error "Emacs lacks native thread support required by loom-thread-pool"))
  (unless (and (integerp pool-size) (> pool-size 0))
    (error "POOL-SIZE must be a positive integer"))

  (let* ((pool-name (or name (format "pool-%s" (make-symbol "t"))))
         (lock (loom:lock (format "%s-mutex" pool-name) :mode :thread))
         (pool (%%make-loom-thread-pool
                :name pool-name
                :queue (loom:queue)
                :lock lock
                :condition-var (make-condition-variable
                                (loom-lock-native-mutex lock)
                                (format "%s-cv" pool-name))
                :running t)))

    (loom-log :info nil "Initializing pool '%s' with %d thread(s)."
              pool-name pool-size)

    ;; Start worker threads.
    (dotimes (i pool-size)
      (let ((thread-name (format "%s-worker-%d" pool-name i)))
        (push (make-thread (lambda () (loom--thread-pool-worker-loop-fn pool))
                           thread-name)
              (loom-thread-pool-threads pool))))

    ;; Verify that all threads started successfully.
    (sleep-for 0.01)
    (unless (cl-every #'thread-live-p (loom-thread-pool-threads pool))
      (loom-log :error nil "Pool '%s': Some worker threads failed to start."
                pool-name)
      (loom:thread-pool-cleanup pool) ; Clean up partially started pool.
      (signal 'loom-thread-pool-error
              `(:message ,(format "Failed to start all threads for pool '%s'"
                                  pool-name))))

    ;; Track the new pool for automatic cleanup.
    (push pool loom--all-thread-pools)
    (loom-log :info nil "Pool '%s' initialized and running." pool-name)
    pool))

;;;###autoload
(defun loom:thread-pool-submit (pool task-fn &rest task-args)
  "Submit a `TASK-FN` to be executed by the `POOL` with `TASK-ARGS`.
This function is the primary way to add work to a thread pool. It
is thread-safe.

Arguments:
- `POOL` (loom-thread-pool): The pool instance to submit the task to.
- `TASK-FN` (function): The function to execute in a worker thread.
- `TASK-ARGS` (list): A list of arguments to pass to `TASK-FN`.

Returns:
A `loom-promise` that will be settled with the return value of
`TASK-FN`, or rejected if `TASK-FN` signals an error.

Side Effects:
- Creates a new `loom-promise`.
- Enqueues a task onto the pool's internal queue.
- Notifies one waiting worker thread.

Signals:
- `loom-thread-pool-uninitialized-error`: If the pool is not running."
  (unless (and (loom-thread-pool-p pool) (loom-thread-pool-running pool))
    (signal 'loom-thread-pool-uninitialized-error
            `(:message ,(format "Pool '%s' is not running or invalid"
                                (if (loom-thread-pool-p pool)
                                    (loom-thread-pool-name pool) "<?>")))))
  (let ((promise (loom:promise :mode :thread
                               :name (format "pool-task-%S" (loom-thread-pool-name pool)))))
    (let ((task (%%make-thread-pool-task :promise promise
                                         :task-fn task-fn
                                         :task-args task-args)))
      (loom:with-mutex! (loom-thread-pool-lock pool)
        (loom:queue-enqueue (loom-thread-pool-queue pool) task)
        ;; Wake up one waiting thread to process the new task.
        (condition-notify (loom-thread-pool-condition-var pool)))
      (loom-log :debug nil "Submitted task to pool '%s' for promise %S"
                (loom-thread-pool-name pool) (loom-promise-id promise))
      promise)))

;;;###autoload
(defun loom:thread-pool-cleanup (pool)
  "Shut down a thread `POOL`, waiting for all threads to terminate.
This function is idempotent and thread-safe.

Arguments:
- `POOL` (loom-thread-pool): The pool instance to clean up.

Returns: `t`.

Side Effects:
- Signals all worker threads to stop.
- Joins all worker threads, blocking until they exit.
- Clears the pool's internal resources.
- Removes the pool from the global tracking list."
  (unless (loom-thread-pool-p pool)
    (error "Argument must be a loom-thread-pool instance, got: %S" pool))

  (let ((pool-name (loom-thread-pool-name pool)))
    (when (loom-thread-pool-running pool)
      (loom-log :info nil "Shutting down pool '%s'." pool-name)
      (setf (loom-thread-pool-running pool) nil)
      (loom:with-mutex! (loom-thread-pool-lock pool)
        (condition-notify (loom-thread-pool-condition-var pool) t))
      (dolist (thread (loom-thread-pool-threads pool))
        (when (thread-live-p thread)
          (loom-log :debug nil "Joining thread '%s' for pool '%s'."
                    (thread-name thread) pool-name)
          (thread-join thread)))
      (loom-log :info nil "All threads for pool '%s' have stopped." pool-name)))

  ;; Clear resources and remove from global tracking.
  (setf (loom-thread-pool-threads pool) nil
        (loom-thread-pool-queue pool) nil
        (loom-thread-pool-lock pool) nil
        (loom-thread-pool-condition-var pool) nil)
  (setq loom--all-thread-pools (delete pool loom--all-thread-pools))
  (when (eq pool loom--default-thread-pool-instance)
    (setq loom--default-thread-pool-instance nil))
  t)

;;;###autoload
(defun loom:thread-pool-status (&optional pool)
  "Return a plist with the current status of a thread `POOL`.
If `POOL` is nil, returns the status of the default pool instance.

Arguments:
- `POOL` (loom-thread-pool, optional): The pool instance to inspect.

Returns:
A plist containing status information, or `nil` if the specified
pool is not initialized or invalid."
  (let ((target-pool (or pool loom--default-thread-pool-instance)))
    (when (and (loom-thread-pool-p target-pool)
               (loom-thread-pool-lock target-pool))
      (let* ((threads (loom-thread-pool-threads target-pool))
             (queue (loom-thread-pool-queue target-pool)))
        `(:name ,(loom-thread-pool-name target-pool)
          :running ,(loom-thread-pool-running target-pool)
          :pool-size ,(length threads)
          :live-threads ,(cl-count-if #'thread-live-p threads)
          :pending-tasks ,(if queue (loom:queue-length queue) 0))))))

;;;###autoload
(cl-defun loom:thread-pool-default (&key name pool-size)
  "Return the default `loom-thread-pool`, initializing it if needed.
This function is idempotent; subsequent calls return the existing
instance without re-initializing, ignoring any new arguments.

Arguments:
- `:NAME` (string, optional): Used only on first-time init. Defaults to
  \"default-pool\".
- `:POOL-SIZE` (integer, optional): Used only on first-time init. Defaults
  to `loom-thread-pool-default-size`.

Returns:
The default `loom-thread-pool` instance.

Side Effects:
- May create the default thread pool instance if it doesn't exist."
  (unless (and loom--default-thread-pool-instance
               (loom-thread-pool-running loom--default-thread-pool-instance))
    (loom-log :info nil "Initializing default thread pool.")
    (setq loom--default-thread-pool-instance
          (loom:thread-pool-init
           :name (or name "default-pool")
           :pool-size (or pool-size loom-thread-pool-default-size))))
  loom--default-thread-pool-instance)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shutdown Hook

(defun loom--thread-pool-shutdown-hook ()
  "Clean up all active `loom-thread-pool` instances on Emacs shutdown."
  (when loom--all-thread-pools
    (loom-log :info "Global" "Emacs shutdown: Cleaning up %d active thread pool(s)."
              (length loom--all-thread-pools))
    ;; Iterate over a copy, as `loom:thread-pool-cleanup` modifies the list.
    (dolist (pool (copy-list loom--all-thread-pools))
      (loom:thread-pool-cleanup pool))))

(add-hook 'kill-emacs-hook #'loom--thread-pool-shutdown-hook)

(provide 'loom-thread-pool)
;;; loom-thread-pool.el ends here