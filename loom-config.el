;;; loom-config.el --- Core functionality for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file defines the global infrastructure for the Loom concurrency library.
;; It acts as the central orchestrator, responsible for managing the lifecycle
;; and execution environment in which all asynchronous operations run.
;;
;; ## Core Responsibilities
;;
;; 1.  **Lifecycle Management:** Provides a clear public API (`loom:init`,
;;     `loom:shutdown`) to start up and tear down the library's global
;;     resources. Initialization is idempotent, and shutdown is automatically
;;     handled when Emacs exits.
;;
;; 2.  **Task Scheduling:** Implements and manages two distinct schedulers to
;;     comply with Promise/A+ specifications for execution order:
;;     - **Microtask Queue:** A high-priority queue for immediate, internal
;;       operations like resolving a promise chain. This queue is always drained
;;       completely before handling I/O or other tasks, ensuring that promise
;;       state propagates without delay.
;;     - **Macrotask Scheduler:** A lower-priority queue for user-provided
;;       callbacks (e.g., from `.then`, `.catch`). These tasks are processed
;;       in batches during idle time to avoid blocking the user interface.
;;
;; 3.  **System Coordination:** It initializes and coordinates with other Loom
;;     subsystems, particularly the Inter-Process/Thread Communication (IPC)
;;     module (`loom-ipc.el`), which is essential for settling promises from
;;     background threads or external processes.
;;
;; ## Basic Usage
;;
;; Before using any promise features, the library must be initialized once:
;;
;;   (loom:init)
;;
;; The library will automatically register a hook to call `loom:shutdown`
;; when Emacs exits, ensuring all resources are cleaned up gracefully.

;;; Code:

(require 'cl-lib)

(require 'loom-log)
(require 'loom-errors)
(require 'loom-registry)
(require 'loom-callback)
(require 'loom-promise)
(require 'loom-scheduler)
(require 'loom-microtask)
(require 'loom-ipc)
(require 'loom-thread-polling)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom-execute-callback "loom-callback")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom--initialized nil
  "A boolean flag indicating if the Loom library has been initialized.
This is used to make `loom:init` idempotent and to guard against API usage
before the system is ready.")

(defvar loom--macrotask-scheduler nil
  "The global scheduler for standard-priority 'macrotasks'.
This scheduler manages user-provided callbacks from `.then`, `.catch`, and
`.finally`. It is designed as a lower-priority queue that runs tasks
cooperatively during idle time, ensuring that long-running callback chains
do not block the user interface. It processes tasks in batches via
`loom:scheduler-tick`.")

(defvar loom--microtask-scheduler nil
  "The global scheduler for high-priority 'microtasks'.
This queue handles immediate, critical operations that are fundamental to
the promise-chaining mechanism, such as propagating a resolution to a
downstream promise or signaling an `await` latch. According to event loop
specifications (like those for JavaScript and Promise/A+), the microtask
queue must be drained completely before processing any other events,
ensuring the atomicity of promise state transitions.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(cl-defun loom--ensure-callback (task &key (type :deferred) (priority 50) data)
  "Ensures `TASK` is a `loom-callback` struct, creating one if not.
This utility function normalizes tasks submitted to schedulers, allowing
users to submit raw functions while the schedulers work with a consistent
`loom-callback` struct internally.

Arguments:
- `TASK` (function or loom-callback): The task to convert or validate.
- `:TYPE` (symbol): The callback type to assign if a new struct is created.
- `:PRIORITY` (integer): The priority to assign if a new struct is created.
- `:DATA` (plist): The data to associate if a new struct is created.

Returns: A valid `loom-callback` struct."
  (cond
   ((loom-callback-p task) task)
   ((functionp task)
    (loom:callback task :type type :priority priority :data data))
   (t (signal 'wrong-type-argument `(or functionp loom-callback-p ,task)))))

(defun loom--callback-fifo-priority (cb-a cb-b)
  "A comparator function for the macrotask scheduler's priority queue.
It first compares callbacks by their `:priority` field (lower integer means
higher priority). If priorities are equal, it falls back to comparing their
`sequence-id`, which is a monotonically increasing integer assigned on
creation. This guarantees that tasks of the same priority are executed in
the First-In, First-Out (FIFO) order they were enqueued.

Arguments:
- `CB-A` (loom-callback): The first callback.
- `CB-B` (loom-callback): The second callback.

Returns: `t` if `CB-A` has a higher priority than `CB-B`."
  (let ((prio-a (loom-callback-priority cb-a))
        (prio-b (loom-callback-priority cb-b)))
    (if (= prio-a prio-b)
        ;; Lower sequence ID means it was created earlier.
        (< (loom-callback-sequence-id cb-a) (loom-callback-sequence-id cb-b))
      ;; Lower priority number means higher actual priority.
      (< prio-a prio-b))))

(defun loom--promise-microtask-overflow-handler (queue overflowed-cbs)
  "A robust handler for microtask queue overflow.
When the microtask queue exceeds its capacity, this function is called
with the callbacks that were dropped. It attempts to gracefully fail by
rejecting the associated promise for each dropped callback, preventing the
system from getting into an inconsistent state.

Arguments:
- `QUEUE` (loom-microtask-queue): The queue instance that overflowed.
- `OVERFLOWED-CBS` (list): The list of `loom-callback` structs that were dropped.

Returns: `nil`."
  (let ((msg (format "Microtask queue overflow (capacity: %d, dropped: %d)"
                     (loom-microtask-queue-capacity queue)
                     (length overflowed-cbs))))
    (loom-log :error nil "%s" msg)
    ;; Iterate through each dropped callback and try to reject its promise.
    (dolist (cb overflowed-cbs)
      (condition-case err
          (when-let* ((data (loom-callback-data cb))
                      (promise-id (plist-get data :promise-id))
                      (promise (loom-registry-get-promise-by-id promise-id)))
            (if promise
                (progn
                  (loom-log :error promise-id
                            "Rejecting promise due to microtask overflow.")
                  (loom:reject promise (loom:make-error
                                        :type 'loom-microtask-queue-overflow
                                        :message msg)))
              (loom-log :warn (or promise-id 'unknown)
                        "Could not find promise to reject for overflowed callback.")))
        ;; This inner condition-case makes the handler itself robust.
        (error
         (loom-log :error nil
                   "Error while handling overflow for callback %S: %S" cb err))))
  nil)

(defun loom--init-schedulers ()
  "Initializes the global microtask and macrotask schedulers.
This function is idempotent; it will not re-initialize schedulers that
already exist.

Returns: `nil`.
Signals: `loom-initialization-error` on failure."
  ;; Initialize the high-priority microtask queue.
  (unless loom--microtask-scheduler
    (loom-log :info nil "Initializing microtask scheduler.")
    (condition-case err
        (setq loom--microtask-scheduler
              (loom:microtask-queue
               :executor #'loom-execute-callback
               :overflow-handler #'loom--promise-microtask-overflow-handler))
      ;; If initialization fails, wrap the low-level error in our specific type.
      (error
       (signal 'loom-initialization-error
               `("Microtask scheduler init failed" ,err)))))

  ;; Initialize the standard-priority macrotask scheduler.
  (unless loom--macrotask-scheduler
    (loom-log :info nil "Initializing macrotask scheduler.")
    (condition-case err
        (setq loom--macrotask-scheduler
              (loom:scheduler
               :name "loom-macrotask-scheduler"
               :comparator #'loom--callback-fifo-priority
               ;; The processing function wraps callback execution in a
               ;; condition-case to prevent one failing callback from
               ;; halting the entire scheduler.
               :process-fn (lambda (batch)
                             (dolist (item batch)
                               (condition-case e (loom-execute-callback item)
                                 (error (loom-log :error
                                                  (loom-callback-promise-id item)
                                                  "Error in macrotask callback: %S"
                                                  e)))))))
      (error
       (signal 'loom-initialization-error
               `("Macrotask scheduler init failed" ,err)))))
  nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom:scheduler-tick ()
  "Performs one cooperative 'tick' of the global schedulers.
This function is the heartbeat of the Loom concurrency system and should be
called periodically from the main Emacs event loop (e.g., via a timer or
in `post-command-hook`). It executes tasks in a specific order to ensure
both responsiveness and correctness.

The execution order is:
1.  **I/O and Timers:** Yield to process pending I/O and timers.
2.  **IPC Queue:** Drain messages from background threads/processes.
3.  **Microtask Queue:** Drain *all* pending microtasks.
4.  **Macrotask Queue:** Process *one batch* of macrotasks.

Returns: `nil`.
Signals: `loom-initialization-error` if called before `loom:init`."
  (unless loom--initialized
    (signal 'loom-initialization-error
            '("Loom library not initialized. Call `loom:init` first.")))
  (loom-log :debug nil "Scheduler tick started.")
  (condition-case err
      (progn
        ;; 1. Yield to process I/O and other Emacs timers. This keeps Emacs
        ;; responsive to external events and user input.
        (accept-process-output nil 0 1)

        ;; 2. Drain messages from background threads via the IPC module.
        ;; This is how promise settlements from threads arrive on the main thread.
        (loom:ipc-drain-queue)

        ;; 3. Drain all high-priority microtasks. This must happen before
        ;; macrotasks to ensure promise state propagates immediately.
        (when loom--microtask-scheduler
          (loom:microtask-drain loom--microtask-scheduler))

        ;; 4. Process one batch of lower-priority macrotasks. Draining only
        ;; one batch per tick prevents a long queue of macrotasks from
        ;; starving the UI.
        (when loom--macrotask-scheduler
          (loom:scheduler-drain loom--macrotask-scheduler)))
    (error (loom-log :error nil "Error during scheduler tick: %S" err)))
  nil)

;;;###autoload
(cl-defun loom:deferred (task &key (priority 50))
  "Schedules a `TASK` for deferred execution on the macrotask scheduler.
This is the standard way to schedule work that should run on the main
thread without blocking, after the current chain of operations has
completed.

Arguments:
- `TASK` (function or loom-callback): The task to execute.
- `:PRIORITY` (integer): An optional priority (lower number is higher).

Returns: `nil`.
Signals: `loom-scheduler-error` if the scheduler is not initialized."
  (unless loom--macrotask-scheduler
    (signal 'loom-scheduler-error '("Macrotask scheduler not initialized.")))
  ;; Ensure the task is a callback struct before enqueuing.
  (let ((callback (loom--ensure-callback task
                                         :type :deferred
                                         :priority priority)))
    (condition-case err
        (loom:scheduler-enqueue loom--macrotask-scheduler callback)
      (error (signal 'loom-scheduler-error
                     `("Failed to enqueue deferred task" ,err)))))
  nil)

;;;###autoload
(cl-defun loom:microtask (task &key (priority 0))
  "Schedules a `TASK` for immediate execution on the microtask queue.
Microtasks are for high-priority, short-lived operations, primarily used
internally by the promise implementation itself. They run to completion
before any other event handling.

Arguments:
- `TASK` (function or loom-callback): The task to execute.
- `:PRIORITY` (integer): An optional priority (lower number is higher).

Returns: `nil`.
Signals: `loom-scheduler-error` if the scheduler is not initialized."
  (unless loom--microtask-scheduler
    (signal 'loom-scheduler-error '("Microtask scheduler not initialized.")))
  (let ((callback (loom--ensure-callback task :priority priority)))
    (condition-case err
        (loom:microtask-enqueue loom--microtask-scheduler callback)
      (error (signal 'loom-scheduler-error `("Failed to enqueue microtask" ,err)))))
  nil)

;;;###autoload
(defun loom:init ()
  "Initializes the entire Loom concurrency library.
This function sets up the global schedulers, IPC mechanisms, and other
core resources. It is idempotent, meaning it is safe to call multiple times;
it will only perform the initialization once.

Returns: `nil`.
Signals: `loom-initialization-error` on a non-recoverable failure."
  (unless loom--initialized
    (loom-log :info nil "Initializing Loom library.")
    (condition-case err
        (progn
          ;; Initialize subsystems in order of dependency.
          (loom--init-schedulers)
          (loom:ipc-init)

          ;; Mark initialization as complete.
          (setq loom--initialized t)
          (loom-log :info nil "Loom library initialized successfully."))
      ;; If any step of the initialization fails...
      (error
       (loom-log :error nil "Loom initialization failed: %S" err)
       ;; ...attempt to clean up any resources that may have been
       ;; partially initialized to leave the system in a clean state.
       (loom:shutdown)
       ;; ...and signal a specific error to the caller.
       (signal 'loom-initial-ization-error `("Library init failed" ,err)))))
  nil)

;;;###autoload
(defun loom:shutdown ()
  "Shuts down the Loom library and cleans up all allocated resources.
This function is designed to be robust and idempotent. It systematically
shuts down each subsystem, wrapping each step in a `condition-case` so that
a failure in one part does not prevent the cleanup of others.

Returns: `nil`."
  (when loom--initialized
    (loom-log :info nil "Shutting down Loom library.")
    ;; The unwind-protect ensures that the final state variables are reset
    ;; even if the cleanup process itself encounters an error.
    (unwind-protect
        (progn
          ;; The following cleanup steps are individually wrapped to maximize
          ;; the chance of a complete shutdown.

          ;; 1. Signal the generic thread polling scheduler to stop.
          (condition-case e (loom:thread-polling-stop-scheduler-thread)
            (error (loom-log :error nil "Polling scheduler stop error: %S" e)))

          ;; 2. Clean up IPC resources (e.g., kill the pipe process).
          (condition-case e (loom:ipc-cleanup)
            (error (loom-log :error nil "IPC cleanup error: %S" e)))

          ;; 3. Stop and reset the macrotask scheduler.
          (when loom--macrotask-scheduler
            (condition-case e (loom:scheduler-stop loom--macrotask-scheduler)
              (error (loom-log :error nil
                               "Macrotask scheduler stop error: %S" e)))))
      ;; This `progn` block is the cleanup form of unwind-protect. It
      ;; will run no matter what happens above.
      (progn
        (setq loom--macrotask-scheduler nil)
        (setq loom--microtask-scheduler nil)
        (setq loom--initialized nil)
        (loom-log :info nil "Loom library shutdown complete."))))
  nil)

;; Hook into Emacs shutdown to ensure graceful resource cleanup. This is crucial
;; for preventing orphaned processes or timers when Emacs is closed.
(add-hook 'kill-emacs-hook #'loom:shutdown)

(provide 'loom-config)
;;; loom-config.el ends here