;;; loom-config.el --- Core functionality for Loom Promises -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Loom Contributors
;; Author: Loom Contributors
;; Version: 2.0.0
;; Package-Requires: ((emacs "28.1") (cl-lib "0.5"))
;; Keywords: concurrency, promises, async, core
;; URL: https://github.com/loom/loom

;;; Commentary:
;;
;; This file defines the core global infrastructure for the Loom
;; concurrency library. It acts as the central orchestrator, responsible
;; for managing the lifecycle and execution environment in which all
;; asynchronous operations based on promises run.
;;
;; ## Core Responsibilities
;;
;; 1.  **Lifecycle Management:** Provides a clear public API (`loom:init`,
;;     `loom:shutdown`) to start up and tear down the library's fundamental
;;     resources. Initialization is idempotent, and shutdown is
;;     automatically handled when Emacs exits.
;;
;; 2.  **Task Scheduling:** Implements and manages two distinct schedulers to
;;     comply with Promise/A+ specifications for execution order:
;;     -   **Microtask Queue:** A high-priority queue for immediate, internal
;;         operations like resolving promise chains. These tasks are
;;         guaranteed to run before any UI updates or macrotasks.
;;     -   **Macrotask Scheduler:** A lower-priority queue for user-provided
;;         callbacks (e.g., from `.then`, `.catch`). These tasks run after
;;         all microtasks are drained in a given event loop tick.
;;
;; 3.  **Extensible Initialization/Shutdown:** Provides hooks for other
;;     Loom subsystems (like logging or distributed processing) to
;;     "plug in" their own initialization and cleanup routines, ensuring
;;     a coordinated startup and shutdown.
;;
;; 4.  **Health Monitoring & Profiling:** Optionally provides periodic
;;     health checks of its core components and can auto-start the
;;     performance profiler for instrumenting user code.
;;
;; This module focuses purely on the asynchronous execution model and
;; core resource management, abstracting away concerns like IPC or
;; distributed logging, which are handled by dedicated extension modules.

;;; Code:

(require 'cl-lib) ; Common Lisp extensions for enhanced programming
(require 'seq)    ; Sequence manipulation functions
(require 's)     ; String manipulation library

(require 'loom-log)       ; For core logging output from loom-config itself
(require 'loom-error)    ; For `loom:error!` and error reporting
(require 'loom-registry)  ; For tracking active promises
(require 'loom-callback)  ; For `loom-callback` struct and `loom:ensure-callback`
(require 'loom-scheduler) ; For `loom:scheduler` and `loom:scheduler-enqueue`
(require 'loom-microtask) ; For `loom:microtask-queue` and `loom:microtask-enqueue`
(require 'loom-profiler)  ; For optional performance profiling

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 1. Forward Declarations
;; Functions that are defined elsewhere but called in this module.

(declare-function loom-execute-callback "loom-promise")
;; loom-promise depends on loom-config for scheduling, and loom-config
;; depends on loom-promise for its executor. This is a circular dependency
;; that Emacs Lisp `declare-function` resolves.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 2. Global State

(defvar loom--initialized nil
  "A boolean flag indicating if the Loom library has been initialized.
This flag prevents re-initialization of core components.")

(defvar loom--macrotask-scheduler nil
  "The global scheduler for standard-priority 'macrotasks'.
These are typically user-defined callbacks from promises or deferred tasks.")

(defvar loom--microtask-scheduler nil
  "The global scheduler for high-priority 'microtasks'.
These are primarily internal promise resolution steps, guaranteed to run
before macrotasks in the same event loop tick.")

(defvar loom--health-check-timer nil
  "Internal Emacs timer for the periodic system health check.
This timer is managed by `loom-config` itself and logs status reports.")

(defvar loom-config-post-init-hook nil
  "Normal hook run after Loom's core initialization is complete.
Functions on this hook should take no arguments. External modules
(e.g., `warp`) can add their initialization routines here.")

(defvar loom-config-pre-shutdown-hook nil
  "Normal hook run before Loom's core shutdown begins.
Functions on this hook should take no arguments. External modules
(e.g., `warp`) can add their cleanup routines here.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 3. Customization Variables

(defcustom loom-health-check-enable nil
  "If non-nil, enable periodic logging of Loom's core system status.
This provides a periodic snapshot of scheduler queues, registry sizes, etc.
Off by default."
  :type 'boolean
  :group 'loom)

(defcustom loom-health-check-interval 30
  "Interval in seconds for the periodic health check output.
Only effective if `loom-health-check-enable` is non-nil."
  :type '(integer :min 1)
  :group 'loom)

(defcustom loom-profiler-autostart-features nil
  "A list of feature symbols to automatically profile when `loom:init` is
called. If non-nil, `loom-profiler` will be started and these features
instrumented. Example: `(my-feature-one my-feature-two)`."
  :type '(repeat symbol)
  :group 'loom)

(defcustom loom-profiler-autostart-interval 10
  "The reporting interval in seconds for the auto-started profiler.
Only effective if `loom-profiler-autostart-features` is non-nil."
  :type 'integer
  :group 'loom)

;; Removed loom-log-autostart-server and its related defcustoms.
;; Log server initialization is now handled externally, e.g., by 'warp-log'.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 4. Internal Helpers: Health Checks (`loom--health-check-*`)

(defun loom--health-check-indent-string (str indent-level)
  "Indent every line of a multi-line string by `INDENT-LEVEL` spaces.
Helper for formatting health check reports."
  (when str
    (let ((indent-prefix (make-string indent-level ?\s)))
      (s-replace-regexp
       "\\`" indent-prefix
       (s-replace-regexp "\n" (concat "\n" indent-prefix) str)))))

(defun loom--health-check-perform ()
  "Collect and log a comprehensive status report of Loom's core components.
This function is the core of the optional health monitoring system. It
gathers status information from schedulers, registries, and logs it.

Arguments: None.

Returns: `nil`.

Side Effects:
- Outputs a multi-line log message to the default log server (`loom:log!`)."
  (let* ((base-indent 4)
         (line-indent 4)
         (total-indent (+ base-indent line-indent))
         ;; Collect status reports from all relevant core subsystems.
         ;; Removed references to loom-poll and loom-ipc related stats.
         (raw-status-lines
          (list
           (format "Error Stats: %S" (loom:error-statistics))
           (format "Lock Stats: %S" (loom:lock-global-stats))
           (format "Microtask Queue Status: %S"
                   (loom:microtask-status loom--microtask-scheduler))
           (format "Macrotask Scheduler Status: %S"
                   (loom:scheduler-status loom--macrotask-scheduler))
           (format "Promise Registry Status: %S" (loom:registry-status))
           (format "Promise Registry Metrics: %S" (loom:registry-metrics)))))
    (let ((indented-report-lines
           (seq-map (lambda (line)
                      (loom--health-check-indent-string line total-indent))
                    raw-status-lines)))
      ;; Combine all generated report lines with a header for clarity.
      (loom:log! :info 'loom-config
                 (string-join
                  (append (list (loom--health-check-indent-string
                                 "--- Loom Core System Health Check ---" base-indent))
                          indented-report-lines
                          (list (loom--health-check-indent-string
                                 "--- End Health Check ---" base-indent)))
                  "\n")))))

(defun loom--health-check-start-timer ()
  "Start the periodic health check timer if enabled via custom variables.

Arguments: None.

Returns: `nil`.

Side Effects:
- Creates a new timer and stores it in `loom--health-check-timer`."
  (when (and loom-health-check-enable
             (not (timerp loom--health-check-timer))
             (> loom-health-check-interval 0))
    (loom:log! :info 'loom-config
               "Starting Loom health check timer (interval: %ds)."
               loom-health-check-interval)
    (setq loom--health-check-timer
          (run-with-timer loom-health-check-interval
                          loom-health-check-interval
                          #'loom--health-check-perform))))

(defun loom--health-check-stop-timer ()
  "Stop the periodic health check timer. This function is idempotent.

Arguments: None.

Returns: `nil`.

Side Effects:
- Cancels the timer stored in `loom--health-check-timer`."
  (when (timerp loom--health-check-timer)
    (loom:log! :info 'loom-config "Stopping Loom health check timer.")
    (cancel-timer loom--health-check-timer)
    (setq loom--health-check-timer nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 5. Internal Helpers: Schedulers (`loom--scheduler-*`)

(defun loom--scheduler-callback-fifo-priority (cb-a cb-b)
  "Comparator for the macrotask scheduler's priority queue.
This function implements a two-level sort. It first compares callbacks by
their `:priority` field, where a lower integer signifies a higher
priority. If two callbacks have the same priority, it uses their
`:sequence-id` as a tie-breaker to ensure FIFO ordering."
  (let ((prio-a (loom-callback-priority cb-a))
        (prio-b (loom-callback-priority cb-b)))
    (if (= prio-a prio-b)
        (< (loom-callback-sequence-id cb-a)
           (loom-callback-sequence-id cb-b))
      (< prio-a prio-b))))

(defun loom--scheduler-microtask-overflow-handler (queue overflowed-cbs)
  "Robustly reject promises associated with overflowed microtasks.
This is a safety net. If the microtask queue fills up, this handler
finds the promise linked to each dropped callback and explicitly rejects
it with an error, ensuring that downstream `.catch` handlers are triggered."
  (let ((msg (format "Microtask queue overflow (capacity: %d, dropped: %d)"
                     (loom-microtask-queue-capacity queue)
                     (length overflowed-cbs))))
    (loom:log! :error 'loom-config "%s" msg)
    (dolist (cb overflowed-cbs)
      (condition-case err
          (when-let* ((data (plist-get (loom-callback-data cb) :promise-id))
                      (promise (loom-registry-get-promise-by-id data)))
            (if promise
                ;; Rejects the promise with a specific overflow error.
                (loom:promise-reject promise (loom:error!
                                    :type 'loom-microtask-queue-overflow
                                    :message msg))
              (loom:log! :warn (or data 'unknown)
                         "Could not find promise for overflowed callback.")))
        (error (loom:log! :error 'loom-config
                          "Error in overflow handler for %S: %S"
                          cb err))))))

(defun loom--scheduler-init-core-schedulers ()
  "Initialize the global microtask and macrotask schedulers.
This function is idempotent and sets up the fundamental asynchronous
execution queues for Loom.

Arguments: None.

Returns: `nil`.

Side Effects:
- Modifies the global `loom--microtask-scheduler` and
  `loom--macrotask-scheduler` variables.

Signals:
- `loom-initialization-error`: On failure to create either scheduler."
  ;; Initialize the high-priority microtask queue for internal operations.
  (unless loom--microtask-scheduler
    (loom:log! :info 'loom-config "Initializing microtask scheduler.")
    (condition-case err
        (setq loom--microtask-scheduler
              (loom:microtask-queue
               :executor #'loom-execute-callback
               :overflow-handler #'loom--scheduler-microtask-overflow-handler))
      (error (signal 'loom-initialization-error
                     `("Microtask scheduler init failed" ,err)))))

  ;; Initialize the standard-priority macrotask scheduler for user callbacks.
  (unless loom--macrotask-scheduler
    (loom:log! :info 'loom-config "Initializing macrotask scheduler.")
    (condition-case err
        (setq loom--macrotask-scheduler
              (loom:scheduler
               :name "loom-macrotask-scheduler"
               :comparator #'loom--scheduler-callback-fifo-priority
               :process-fn
               (lambda (batch)
                 ;; Each item in the batch is a loom-callback.
                 (dolist (item batch)
                   (condition-case e (loom-execute-callback item)
                     (error
                      ;; Report unhandled rejections if the callback itself fails.
                      (let ((error-obj (loom:error-wrap
                                        :message "Macrotask callback failed."
                                        :data `(:callback ,item))))
                        (loom-report-unhandled-rejection error-obj))))))))
      (error (signal 'loom-initialization-error
                     `("Macrotask scheduler init failed" ,err))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 6. Public API: Scheduling

;;;###autoload
(defun loom:scheduler-tick ()
  "Performs one cooperative 'tick' of the global schedulers.
This function is the heartbeat of the Loom concurrency system, enabling
asynchronous operations to progress. It processes tasks in a specific,
priority-driven order to ensure correctness and responsiveness:

1.  **I/O and Timers:** Yields briefly to allow Emacs to process any
    pending I/O events or scheduled timers. This keeps the UI responsive.
2.  **Microtask Queue:** Drains *all* pending microtasks to completion.
    Microtasks have the highest priority and must finish before any
    macrotasks or further I/O in the current tick.
3.  **Macrotask Queue:** Processes *one batch* of macrotasks. Macrotasks
    are lower priority and allow for fair scheduling of user-defined work.

Arguments: None.

Returns: `nil`.

Side Effects:
- Drains and executes tasks from both schedulers, which involves
  invoking user-provided callback functions with their own side effects.
- Can trigger additional `loom:log!` calls for errors or status.

Signals:
- `loom-initialization-error`: If called before `loom:init` has been
  successfully completed."
  (unless loom--initialized
    (signal 'loom-initialization-error
            '("Loom library not initialized. Call `loom:init` first.")))
  (condition-case err
      (progn
        ;; Yield to Emacs's event loop for I/O and timers.
        (accept-process-output nil 0 1)
        ;; No IPC drain here; that's external.
        (when loom--microtask-scheduler
          (loom:microtask-drain loom--microtask-scheduler))
        (when loom--macrotask-scheduler
          (loom:scheduler-drain loom--macrotask-scheduler)))
    (error (loom:log! :error 'loom-config "Error during scheduler tick: %S"
                      err)))
  nil)

;;;###autoload
(cl-defun loom:deferred (task &key (priority 50))
  "Schedules a `TASK` for deferred execution on the macrotask scheduler.
This is the standard way to schedule work that should run on the main
thread without blocking the current flow of execution. It ensures that
the task executes on a clean stack in a future event loop tick.

Arguments:
- `TASK` (function or loom-callback): The task (a function with no
  arguments) to execute. If it's a `loom-callback`, it's used directly.
- `:PRIORITY` (integer, optional): An integer priority for the task,
  where a lower number (e.g., 0) indicates a higher priority. Default is 50.

Returns: `nil`.

Side Effects:
- Enqueues a `loom-callback` onto the `loom--macrotask-scheduler`.

Signals:
- `loom-scheduler-error`: If the macrotask scheduler is not initialized
  or if enqueuing the task fails."
  (unless loom--macrotask-scheduler
    (signal 'loom-scheduler-error '("Macrotask scheduler not initialized.")))
  (let ((callback (loom:ensure-callback task :type :deferred
                                        :priority priority)))
    (condition-case err
        (loom:scheduler-enqueue loom--macrotask-scheduler callback)
      (error (signal 'loom-scheduler-error
                     `("Failed to enqueue deferred task" ,err))))))

;;;###autoload
(cl-defun loom:microtask (task &key (priority 0))
  "Schedules a `TASK` for immediate execution on the microtask queue.
Microtasks are for high-priority, short-lived operations, primarily used
internally by the promise implementation itself to process promise
resolutions or rejections. They are guaranteed to run to completion
before any other event handling (like I/O or macrotasks) occurs within
the current tick of the Emacs event loop.

Arguments:
- `TASK` (function or loom-callback): The task (a function with no
  arguments) to execute. If it's a `loom-callback`, it's used directly.
- `:PRIORITY` (integer, optional): An integer priority for the task.
  Microtasks are typically processed in FIFO order within their priority.
  Default is 0 (highest priority for microtasks).

Returns: `nil`.

Side Effects:
- Enqueues a `loom-callback` onto the `loom--microtask-scheduler`.

Signals:
- `loom-scheduler-error`: If the microtask scheduler is not initialized
  or if enqueuing the task fails."
  (unless loom--microtask-scheduler
    (signal 'loom-scheduler-error '("Microtask scheduler not initialized.")))
  (let ((callback (loom:ensure-callback task :priority priority)))
    (condition-case err
        (loom:microtask-enqueue loom--microtask-scheduler callback)
      (error (signal 'loom-scheduler-error
                     `("Failed to enqueue microtask" ,err))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 7. Public API: Initialization/Shutdown (`loom:init`, `loom:shutdown`)

;;;###autoload
(cl-defun loom:init ()
  "Initializes the core Loom concurrency library.

This function sets up the global microtask and macrotask schedulers,
and other fundamental core resources required for asynchronous
operations. It is idempotent; calling it multiple times will only
perform initialization once.

This function *must* be called before any other Loom API function is
used (e.g., creating promises, scheduling tasks).

Arguments: None.
(Removed :my-id and :listen-for-incoming-p, as these are IPC concerns)

Returns: `nil`.

Side Effects:
- Modifies global state variables (`loom--initialized`, schedulers, etc.).
- Starts core timers (`loom--health-check-timer`).
- Initializes `loom-scheduler` and `loom-microtask` components.
- Runs `loom-config-post-init-hook` for external module initialization.

Signals:
- `loom-initialization-error`: On a non-recoverable failure during
  core Loom setup."
  (unless loom--initialized
    (loom:log! :info 'loom-config "Initializing Loom core library.")
    (condition-case err
        (progn
          ;; 1. Initialize core schedulers (fundamental to Loom's operation).
          (loom--scheduler-init-core-schedulers)

          ;; 2. Start optional core health check timer.
          (loom--health-check-start-timer)

          ;; 3. Mark core initialization as complete.
          (setq loom--initialized t)
          (loom:log! :info 'loom-config
                     "Loom core library initialized successfully.")

          ;; 4. Run post-initialization hooks for external modules.
          ;; This is where modules like 'warp' would plug in their IPC,
          ;; distributed logging, or threading setup.
          (run-hooks 'loom-config-post-init-hook)

          ;; 5. Optionally start the profiler if configured.
          (when loom-profiler-autostart-features
            (loom:log! :info 'loom-config
                       "Auto-starting profiler for features: %s"
                       loom-profiler-autostart-features)
            (loom:profiler-start :interval
                                 loom-profiler-autostart-interval)
            (dolist (feature loom-profiler-autostart-features)
              (loom:profiler-instrument-feature feature))))
      ;; If any step of the initialization fails...
      (error
       (loom:log! :error 'loom-config "Loom core initialization failed: %S" err)
       ;; ...attempt to clean up any resources that may have been
       ;; partially initialized to leave the system in a clean state.
       (loom:shutdown)
       ;; ...and signal a specific error to the caller.
       (signal 'loom-initialization-error
               `("Core library init failed" ,err))))))

;;;###autoload
(defun loom:shutdown ()
  "Shuts down the Loom core library and cleans up all allocated resources.

This function is designed to be robust and idempotent. It systematically
shuts down each core Loom subsystem, wrapping each step in a
`condition-case` so that a failure in one part does not prevent the
cleanup of others. It is automatically registered with `kill-emacs-hook`
to run when Emacs exits, ensuring graceful resource release.

Arguments: None.

Returns: `nil`.

Side Effects:
- Runs `loom-config-pre-shutdown-hook` for external module cleanup.
- Stops all timers managed by `loom-config`.
- Stops and uninitializes core schedulers.
- Cleans up `loom-profiler` if it was active.
- Resets all global state variables (`loom--initialized`, schedulers) to `nil`.
- Can log errors if any cleanup step fails."
  (when loom--initialized
    (loom:log! :info 'loom-config "Shutting down Loom core library.")
    (unwind-protect
        (progn
          ;; 1. Run pre-shutdown hooks for external modules.
          ;; This is where modules like 'warp' would plug in their IPC,
          ;; distributed logging, or threading cleanup.
          (run-hooks 'loom-config-pre-shutdown-hook)

          ;; 2. Stop the profiler if it was running.
          (condition-case e (loom:profiler-stop)
            (error (loom:log! :error 'loom-config
                              "Profiler stop error: %S" e)))

          ;; 3. Stop core health check timer.
          (loom--health-check-stop-timer)

          ;; 4. Stop macrotask scheduler. Microtask queue usually doesn't
          ;; need an explicit stop beyond clearing its global variable.
          (when loom--macrotask-scheduler
            (condition-case e (loom:scheduler-stop loom--macrotask-scheduler)
              (error (loom:log! :error 'loom-config
                                "Macrotask scheduler stop error: %S" e)))))
      ;; Ensure all global state is reset even if errors occur during cleanup.
      (progn
        (setq loom--macrotask-scheduler nil)
        (setq loom--microtask-scheduler nil)
        (setq loom--initialized nil)
        (loom:log! :info 'loom-config "Loom core library shutdown complete.")))))

;; Hook into Emacs shutdown to ensure graceful resource cleanup.
;; This function will run when Emacs exits.
(add-hook 'kill-emacs-hook #'loom:shutdown)

(provide 'loom-config)
;;; loom-config.el ends here