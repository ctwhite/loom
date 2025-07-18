;;; loom-config.el --- Core functionality for Loom Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file defines the global infrastructure for the Loom concurrency library.
;; It acts as the central orchestrator, responsible for managing the lifecycle
;; and execution environment in which all asynchronous operations run.
;;
;; ## Core Responsibilities
;;
;; 1.  **Lifecycle Management:** Provides a clear public API (`loom:init`,
;;     `loom:shutdown`) to start up and tear down the library's global
;;     resources. Initialization is idempotent, and shutdown is automatically
;;     handled when Emacs exits.
;;
;; 2.  **Task Scheduling:** Implements and manages two distinct schedulers to
;;     comply with Promise/A+ specifications for execution order:
;;     - **Microtask Queue:** A high-priority queue for immediate, internal
;;       operations like resolving a promise chain. This queue is always drained
;;       completely before handling I/O or other tasks, ensuring that promise
;;       state propagates without delay.
;;     - **Macrotask Scheduler:** A lower-priority queue for user-provided
;;       callbacks (e.g., from `.then`, `.catch`). These tasks are processed
;;       in batches during idle time to avoid blocking the user interface.
;;
;; 3.  **System Coordination:** It initializes and coordinates with other Loom
;;     subsystems, particularly the Inter-Process/Thread Communication (IPC)
;;     module (`loom-ipc.el`), which is essential for settling promises from
;;     background threads or external processes.
;;
;; 4.  **Health Monitoring:** Optionally provides periodic health checks,
;;     outputting a consolidated status report of various Loom components
;;     to the `*Messages*` buffer. This aids in debugging and system oversight.
;;
;; ## Basic Usage
;;
;; Before using any promise features, the library must be initialized once.
;; This can be a simple call for in-process concurrency, or it can be
;; configured for communication with other Emacs instances.
;;
;; (loom:init) ;; For standard, in-process use.
;;
;; (loom:init :my-id "server" :listen-for-incoming-p t) ;; As an IPC server.
;;
;; (loom:init :my-id "client" :target-instance-id "server") ;; As an IPC client.

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
(require 'loom-poll)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom-execute-callback "loom-promise")
(declare-function loom-report-unhandled-rejection "loom-errors")
(declare-function loom:error-wrap "loom-errors")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom--initialized nil
  "A boolean flag indicating if the Loom library has been initialized.
This is used to make `loom:init` idempotent and to guard against API usage
before the system is ready. It is set to `t` at the end of a successful
`loom:init` call and reset to `nil` during `loom:shutdown`.")

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

(defvar loom--health-check-timer nil
  "Internal timer for the periodic health check.
This timer is created by `loom--start-health-check-timer` if health
checks are enabled, and it is cancelled by `loom--stop-health-check-timer`
during shutdown.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-health-check-enable nil
  "If non-nil, periodically output Loom's system status. Off by default."
  :type 'boolean
  :group 'loom)

(defcustom loom-health-check-interval 30
  "Interval in seconds for the periodic health check output."
  :type '(integer :min 1)
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers: Health Checks

(defun loom--indent-multiline-string (str indent-level)
  "Indent every line of a multi-line string by `INDENT-LEVEL` spaces.
This is a small formatting utility used exclusively by
`loom--perform-health-check` to make its output readable by ensuring
all lines in the final report are properly aligned.

Arguments:
- `STR` (string): The string to indent, which may contain newlines.
- `INDENT-LEVEL` (integer): The number of spaces to prepend to each line.

Returns:
A new, indented string, or `nil` if `STR` is `nil`."
  (when str
    (let ((indent-prefix (make-string indent-level ?\s)))
      (s-replace-regexp
       "\\`" indent-prefix
       (s-replace-regexp "\n" (concat "\n" indent-prefix) str)))))

(defun loom--perform-health-check ()
  "Collect and log a comprehensive status report of Loom's components.
This function is the core of the optional health monitoring system. It
gathers status information from all major subsystems (schedulers,
registries, thread pools, etc.) and formats it into a single,
easy-to-read log message. This is invaluable for debugging live
systems to understand the current state of all concurrent operations.

Side Effects:
- Outputs a multi-line log message to the `*Messages*` buffer or
  the buffer configured via `loom-log-buffer`."
  (let* ((base-indent 4)
         (line-indent 4)
         (total-indent (+ base-indent line-indent))
         ;; Collect status reports from all relevant subsystems.
         (raw-status-lines
          (list
           (format "Error Stats: %S" (loom:error-statistics))
           (format "Lock Stats: %S" (loom:lock-global-stats))
           (format "Microtask Queue Status: %S"
                   (loom:microtask-status loom--microtask-scheduler))
           (format "Macrotask Scheduler Status: %S"
                   (loom:scheduler-status loom--macrotask-scheduler))
           (format "Thread Polling Scheduler Status: %S"
                   (loom:poll-scheduler-status))
           (format "Thread Polling System Health: %S"
                   (loom:poll-system-health-report))
           (format "Thread Pool Status: %S"
                   (loom:thread-pool-status))
           (format "Promise Registry Status: %S" (loom:registry-status))
           (format "Promise Registry Metrics: %S" (loom:registry-metrics)))))
    (let ((indented-report-lines
           (--map (loom--indent-multiline-string it total-indent)
                  raw-status-lines)))
      ;; Combine all generated report lines with a header and footer for clarity.
      (loom-log :info nil
                (string-join
                 (append (list (loom--indent-multiline-string
                                "--- Loom System Health Check ---" base-indent))
                         indented-report-lines
                         (list (loom--indent-multiline-string
                                "--- End Health Check ---" base-indent)))
                 "\n")))))

(defun loom--start-health-check-timer ()
  "Start the periodic health check timer if enabled via custom variables.
This function checks `loom-health-check-enable` and ensures a timer
is not already running before creating a new one.

Side Effects:
- Creates a new timer and stores it in `loom--health-check-timer`.
- Logs a message indicating the timer has started."
  (when (and loom-health-check-enable
             (not (timerp loom--health-check-timer))
             (> loom-health-check-interval 0))
    (loom-log :info nil "Starting Loom health check timer (interval: %ds)."
              loom-health-check-interval)
    (setq loom--health-check-timer
          (run-with-timer loom-health-check-interval
                          loom-health-check-interval
                          #'loom--perform-health-check))))

(defun loom--stop-health-check-timer ()
  "Stop the periodic health check timer.
This function is idempotent; it is safe to call even if no timer
is currently active.

Side Effects:
- Cancels the timer stored in `loom--health-check-timer`.
- Resets `loom--health-check-timer` to `nil`."
  (when (timerp loom--health-check-timer)
    (loom-log :info nil "Stopping Loom health check timer.")
    (cancel-timer loom--health-check-timer)
    (setq loom--health-check-timer nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers: Schedulers

(defun loom--callback-fifo-priority (cb-a cb-b)
  "Comparator for the macrotask scheduler's priority queue.
This function implements a two-level sort. It first compares callbacks by
their `:priority` field, where a lower integer signifies a higher
priority. If two callbacks have the same priority, it uses their
`:sequence-id` as a tie-breaker. This secondary check is crucial for
guaranteeing that callbacks of the same priority are executed in the
First-In, First-Out (FIFO) order in which they were enqueued.

Arguments:
- `CB-A` (loom-callback): The first callback to compare.
- `CB-B` (loom-callback): The second callback to compare.

Returns:
`t` if `CB-A` has a higher priority than `CB-B`, `nil` otherwise."
  (let ((prio-a (loom-callback-priority cb-a))
        (prio-b (loom-callback-priority cb-b)))
    (if (= prio-a prio-b)
        ;; If priorities are equal, the one created first (lower ID) wins.
        (< (loom-callback-sequence-id cb-a)
           (loom-callback-sequence-id cb-b))
      ;; Otherwise, the one with the lower priority number wins.
      (< prio-a prio-b))))

(defun loom--promise-microtask-overflow-handler (queue overflowed-cbs)
  "Robustly reject promises associated with overflowed microtasks.
This function is a critical safety net. If the microtask queue ever
fills up (which should be rare), this handler is invoked. Its job is to
prevent the system from getting into an inconsistent state where promise
callbacks are silently dropped. It does this by finding the promise
linked to each dropped callback and explicitly rejecting it with an
error, ensuring that downstream `.catch` handlers are triggered.

Arguments:
- `QUEUE` (loom-microtask-queue): The queue instance that overflowed.
- `OVERFLOWED-CBS` (list): The list of `loom-callback` structs that were dropped.

Returns: `nil`.

Side Effects:
- Logs an error to the `*Messages*` buffer.
- Attempts to find and reject the promise associated with each
  overflowed callback, which will trigger further promise chain execution."
  (let ((msg (format "Microtask queue overflow (capacity: %d, dropped: %d)"
                     (loom-microtask-queue-capacity queue)
                     (length overflowed-cbs))))
    (loom-log :error nil "%s" msg)
    (dolist (cb overflowed-cbs)
      (condition-case err
          (when-let* ((data (loom-callback-data cb))
                      (promise-id (plist-get data :promise-id))
                      (promise (loom-registry-get-promise-by-id promise-id)))
            (if promise
                (loom:reject promise (loom:make-error
                                      :type 'loom-microtask-queue-overflow
                                      :message msg))
              (loom-log :warn (or promise-id 'unknown)
                        "Could not find promise for overflowed callback.")))
        (error (loom-log :error nil "Error in overflow handler for %S: %S"
                         cb err))))))

(defun loom--init-schedulers ()
  "Initialize the global microtask and macrotask schedulers.
This function creates the two core schedulers required by the Loom
event loop. The microtask scheduler handles high-priority internal
operations essential for promise mechanics, while the macrotask
scheduler handles lower-priority user-provided callbacks. This
separation is fundamental to the library's design and compliance
with Promise/A+ standards. This function is idempotent.

Returns: `nil`.

Side Effects:
- Modifies the global `loom--microtask-scheduler` and
  `loom--macrotask-scheduler` variables, assigning them new
  scheduler instances.

Signals:
- `loom-initialization-error`: On failure to create either scheduler."
  ;; Initialize the high-priority microtask queue for internal operations.
  (unless loom--microtask-scheduler
    (loom-log :info nil "Initializing microtask scheduler.")
    (condition-case err
        (setq loom--microtask-scheduler
              (loom:microtask-queue
               :executor #'loom-execute-callback
               :overflow-handler #'loom--promise-microtask-overflow-handler))
      (error (signal 'loom-initialization-error
                     `("Microtask scheduler init failed" ,err)))))

  ;; Initialize the standard-priority macrotask scheduler for user callbacks.
  (unless loom--macrotask-scheduler
    (loom-log :info nil "Initializing macrotask scheduler.")
    (condition-case err
        (setq loom--macrotask-scheduler
              (loom:scheduler
               :name "loom-macrotask-scheduler"
               :comparator #'loom--callback-fifo-priority
               :process-fn
               (lambda (batch)
                 (dolist (item batch)
                   (condition-case e (loom-execute-callback item)
                     ;; If a callback execution fails, it constitutes an
                     ;; unhandled rejection. We wrap the error and report it
                     ;; to the centralized handler in `loom-errors.el`.
                     (error
                      (let ((error-obj (loom:error-wrap
                                         :data `(:callback ,item))))
                        (loom-report-unhandled-rejection error-obj))))))))
      (error (signal 'loom-initialization-error
                     `("Macrotask scheduler init failed" ,err))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Scheduling

;;;###autoload
(defun loom:scheduler-tick ()
  "Perform one cooperative 'tick' of the global schedulers.
This function is the heartbeat of the Loom concurrency system. It is
called cooperatively by the promise machinery when asynchronous
work completes.

The execution order is:
1.  **I/O and Timers:** Yield to process pending I/O and timers.
2.  **IPC Queue:** Drain messages from background threads.
3.  **Microtask Queue:** Drain *all* pending microtasks.
4.  **Macrotask Queue:** Process *one batch* of macrotasks.

Returns: `nil`.

Side Effects:
- Calls `accept-process-output` to handle I/O from subprocesses.
- Drains and executes tasks from both schedulers, which involves
  invoking user-provided callback functions with their own side effects.

Signals:
- `loom-initialization-error`: If called before `loom:init`."
  (unless loom--initialized
    (signal 'loom-initialization-error
            '("Loom library not initialized. Call `loom:init` first.")))
  (condition-case err
      (progn
        ;; Yield to other Emacs processes first to keep the UI responsive.
        (accept-process-output nil 0 1)
        ;; Drain messages from background threads to the main thread.
        (loom:ipc-drain-queue)
        ;; Drain high-priority tasks immediately and completely, as per spec.
        (when loom--microtask-scheduler
          (loom:microtask-drain loom--microtask-scheduler))
        ;; Cooperatively process one batch of standard tasks to avoid starving the UI.
        (when loom--macrotask-scheduler
          (loom:scheduler-drain loom--macrotask-scheduler)))
    (error (loom-log :error nil "Error during scheduler tick: %S" err)))
  nil)

;;;###autoload
(cl-defun loom:deferred (task &key (priority 50))
  "Schedule a `TASK` for deferred execution on the macrotask scheduler.
This is the standard way to schedule work that should run on the main
thread without blocking, after the current chain of operations has
completed. It ensures that the task executes on a clean stack.

Arguments:
- `TASK` (function or loom-callback): The task to execute. If a raw
  function is provided, it will be wrapped in a `loom-callback` struct.
- `:PRIORITY` (integer): An optional priority for the task, where a
  lower number signifies higher priority. Defaults to 50.

Returns: `nil`.

Side Effects:
- Enqueues a callback onto the `loom--macrotask-scheduler`.

Signals:
- `loom-scheduler-error`: If the scheduler is not initialized or if
  enqueuing fails."
  (unless loom--macrotask-scheduler
    (signal 'loom-scheduler-error '("Macrotask scheduler not initialized.")))
  (let ((callback (loom:ensure-callback task :type :deferred :priority priority)))
    (condition-case err (loom:scheduler-enqueue loom--macrotask-scheduler callback)
      (error (signal 'loom-scheduler-error
                     `("Failed to enqueue deferred task" ,err))))))

;;;###autoload
(cl-defun loom:microtask (task &key (priority 0))
  "Schedule a `TASK` for immediate execution on the microtask queue.
Microtasks are for high-priority, short-lived operations, primarily used
internally by the promise implementation itself. They are guaranteed to
run to completion before any other event handling (like I/O or macrotasks)
occurs in the current tick of the event loop.

Arguments:
- `TASK` (function or loom-callback): The task to execute. If a raw
  function is provided, it will be wrapped in a `loom-callback` struct.
- `:PRIORITY` (integer): An optional priority for the task. Defaults to 0.

Returns: `nil`.

Side Effects:
- Enqueues a callback onto the `loom--microtask-scheduler`.

Signals:
- `loom-scheduler-error`: If the scheduler is not initialized or if
  enqueuing fails."
  (unless loom--microtask-scheduler
    (signal 'loom-scheduler-error '("Microtask scheduler not initialized.")))
  (let ((callback (loom:ensure-callback task :priority priority)))
    (condition-case err (loom:microtask-enqueue loom--microtask-scheduler callback)
      (error (signal 'loom-scheduler-error
                     `("Failed to enqueue microtask" ,err))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Initialization/Shutdown

;;;###autoload
(cl-defun loom:init (&key my-id target-instance-id (listen-for-incoming-p t))
  "Initialize the entire Loom concurrency library.
This function sets up the global schedulers, IPC mechanisms, and other
core resources required for asynchronous operations. It is idempotent,
meaning it is safe to call multiple times; it will only perform the
initialization once. This function must be called before any other
Loom API function is used.

Arguments:
- `:MY-ID` (string, optional): A unique string identifier for this
  Emacs instance, used for naming its input FIFO. Defaults to the
  current process ID.
- `:TARGET-INSTANCE-ID` (string, optional): The ID of the target Emacs
  instance for sending messages. If non-nil, an output pipe is created.
- `:LISTEN-FOR-INCOMING-P` (boolean, optional): If t (the default),
  create an input pipe to receive messages from other processes.

Returns:
- `nil`.

Side Effects:
- Modifies global state variables (`loom--initialized`, schedulers, etc.).
- Starts timers (`loom--health-check-timer`).
- Starts threads and processes via `loom:ipc-init` and `loom:poll`.
- May create files on the filesystem via `loom:ipc-init`.

Signals:
- `loom-initialization-error`: On a non-recoverable failure during setup.
  If this occurs, the function will attempt to clean up any partially
  initialized resources before signaling."
  (unless loom--initialized
    (loom-log :info nil "Initializing Loom library.")
    (condition-case err
        (progn
          ;; Initialize subsystems in order of dependency.
          (loom--init-schedulers)
          (loom:ipc-init :my-id my-id
                         :target-instance-id target-instance-id
                         :listen-for-incoming-p listen-for-incoming-p)
          (when (fboundp 'make-thread)
            (loom:poll-ensure-scheduler-thread))
          (loom--start-health-check-timer)

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
       (signal 'loom-initialization-error `("Library init failed" ,err))))))

;;;###autoload
(defun loom:shutdown ()
  "Shut down the Loom library and clean up all allocated resources.
This function is designed to be robust and idempotent. It systematically
shuts down each subsystem, wrapping each step in a `condition-case` so that
a failure in one part does not prevent the cleanup of others. It is
automatically registered with `kill-emacs-hook` to run when Emacs exits.

Returns: `nil`.

Side Effects:
- Stops all timers, threads, and processes started by Loom.
- Cleans up IPC resources, including deleting FIFO files.
- Resets all global state variables to `nil`."
  (when loom--initialized
    (loom-log :info nil "Shutting down Loom library.")
    ;; The unwind-protect ensures that the final state variables are reset
    ;; even if the cleanup process itself encounters an error.
    (unwind-protect
        (progn
          ;; The following cleanup steps are individually wrapped to maximize
          ;; the chance of a complete shutdown.

          ;; Stop and clean up the health check timer
          (loom--stop-health-check-timer)

          ;; 1. Signal the generic thread polling scheduler to stop.
          (condition-case e (loom:poll-stop-scheduler-thread)
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
        (loom-log :info nil "Loom library shutdown complete.")))))

;; Hook into Emacs shutdown to ensure graceful resource cleanup. This is crucial
;; for preventing orphaned processes or timers when Emacs is closed.
(add-hook 'kill-emacs-hook #'loom:shutdown)

(provide 'loom-config)
;;; loom-config.el ends here