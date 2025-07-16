;;; loom-config.el --- Core functionality for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file defines the global infrastructure for the Loom concurrency library.
;; It is the central orchestrator, responsible for managing the execution
;; environment in which promises operate. Its primary duties include:
;;
;; 1. Providing a clear public API (`loom:init`, `loom:shutdown`) to manage
;;    the library's lifecycle.
;;
;; 2. Initializing and managing global task schedulers for both high-priority
;;    "microtasks" (e.g., promise chaining) and standard "macrotasks"
;;    (e.g., `.then` callbacks), ensuring Promise/A+ compliance.
;;
;; 3. Coordinating with the Inter-Process Communication (IPC) mechanisms
;;    from `loom-ipc.el` to allow promises to be settled from different
;;    execution contexts (threads or processes) safely.
;;
;; ## Usage
;;
;; Before using any promise features, the library must be initialized:
;;
;;   (loom:init)
;;
;; The library will automatically shut down its resources when Emacs exits.

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
;;; Global State

(defvar loom--initialized nil
  "A boolean flag indicating if the Loom library has been initialized.
This prevents redundant initializations of global resources.")

(defvar loom--macrotask-scheduler nil
  "The global scheduler for standard-priority macrotasks.
This handles callbacks for `.then`, `.catch`, and `.finally`. Macrotasks
run during idle time to avoid blocking the user interface.")

(defvar loom--microtask-scheduler nil
  "The global scheduler for high-priority microtasks.
This queue handles immediate, critical operations like promise chaining
and `await` latches. It is drained completely before macrotasks, per
the Promise/A+ specification.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(cl-defun loom--ensure-callback (task &key (type :deferred) (priority 50) data)
  "Ensure `TASK` is a `loom-callback` struct, wrapping it if necessary.
This normalizes inputs for the scheduling functions.

Arguments:
- `TASK` (function or loom-callback): The task to convert or validate.
- `:TYPE` (symbol): Type for a new `loom-callback`.
- `:PRIORITY` (integer): Priority for a new `loom-callback`.
- `:DATA` (plist): Data to associate with a new `loom-callback`.

Returns a valid `loom-callback` struct."
  (cond
   ((loom-callback-p task) task)
   ((functionp task)
    (loom:callback task :type type :priority priority :data data))
   (t (signal 'wrong-type-argument `(or functionp loom-callback-p ,task)))))

(defun loom--callback-fifo-priority (cb-a cb-b)
  "Comparator for the macrotask scheduler's priority queue.
Prioritizes by `PRIORITY` (lower is higher), then `SEQUENCE-ID`
to ensure FIFO order for same-priority tasks.

Returns `t` if `CB-A` has higher priority than `CB-B`."
  (let ((prio-a (loom-callback-priority cb-a))
        (prio-b (loom-callback-priority cb-b)))
    (if (= prio-a prio-b)
        (< (loom-callback-sequence-id cb-a) (loom-callback-sequence-id cb-b))
      (< prio-a prio-b))))

(defun loom--promise-microtask-overflow-handler (queue overflowed-cbs)
  "Handle microtask queue overflow by rejecting affected promises.
This prevents promises from hanging indefinitely if the queue is full.

Arguments:
- `QUEUE` (loom-microtask-queue): The queue instance.
- `OVERFLOWED-CBS` (list): Callbacks dropped due to overflow."
  (let ((msg (format "Microtask queue overflow (capacity: %d, dropped: %d)"
                     (loom-microtask-queue-capacity queue)
                     (length overflowed-cbs))))
    (loom-log :error nil "%s" msg)
    (dolist (cb overflowed-cbs)
      (condition-case err
          (when-let* ((data (loom-callback-data cb))
                      (promise-id (plist-get data :promise-id))
                      (promise (loom-registry-get-promise-by-id promise-id)))
            (loom-log :error promise-id "Rejecting promise due to overflow.")
            (loom:reject promise (loom:make-error
                                  :type 'loom-microtask-queue-overflow
                                  :message msg)))
        (error
         (loom-log :error nil "Error handling overflow for %S: %S" cb err))))
  nil)

(defun loom--init-schedulers ()
  "Initialize the global microtask and macrotask schedulers. Idempotent."
  (unless loom--microtask-scheduler
    (loom-log :info nil "Initializing microtask scheduler.")
    (condition-case err
        (setq loom--microtask-scheduler
              (loom:microtask-queue
               :executor #'loom-execute-callback
               :overflow-handler #'loom--promise-microtask-overflow-handler))
      (error
       (signal 'loom-initialization-error
               `("Microtask scheduler init failed" ,err)))))

  (unless loom--macrotask-scheduler
    (loom-log :info nil "Initializing macrotask scheduler.")
    (condition-case err
        (setq loom--macrotask-scheduler
              (loom:scheduler
               :name "loom-macrotask-scheduler"
               :comparator #'loom--callback-fifo-priority
               :process-fn (lambda (batch)
                             (dolist (item batch)
                               (condition-case e (loom-execute-callback item)
                                 (error (loom-log :error nil "Callback err: %S" e)))))))
      (error
       (signal 'loom-initialization-error
               `("Macrotask scheduler init failed" ,err)))))
  nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

(defun loom:scheduler-tick ()
  "Perform one cooperative 'tick' of the global schedulers.
This is the heartbeat of the cooperative multitasking system. It
drains high-priority microtasks, then processes a single batch of
lower-priority macrotasks. It should be called periodically from the
main Emacs event loop (e.g., via a timer).

Returns `nil`. Signals `loom-initialization-error` if not initialized."
  (unless loom--initialized
    (signal 'loom-initialization-error
            '("Loom library not initialized. Call `loom:init` first.")))
  (loom-log :debug nil "Scheduler tick.")
  (condition-case err
      (progn
        ;; 1. Yield to process I/O and timers for responsiveness.
        (accept-process-output nil 0 1)
        ;; 2. Drain all high-priority microtasks first.
        (when loom--microtask-scheduler
          (loom:microtask-drain loom--microtask-scheduler))
        ;; 3. Process one batch of low-priority macrotasks.
        (when loom--macrotask-scheduler
          (loom:scheduler-drain loom--macrotask-scheduler)))
    (error (loom-log :error nil "Error during scheduler tick: %S" err)))
  nil)

(cl-defun loom:deferred (task &key (priority 50))
  "Schedule a `TASK` for deferred execution on the macrotask scheduler.

Arguments:
- `TASK` (function or loom-callback): The task to execute.
- `:PRIORITY` (integer): Optional priority (lower is higher).

Returns `nil`. Signals `loom-scheduler-error` if not initialized."
  (unless loom--macrotask-scheduler
    (signal 'loom-scheduler-error '("Macrotask scheduler not initialized.")))
  (let ((callback (loom--ensure-callback task :type :deferred :priority priority)))
    (condition-case err (loom:scheduler-enqueue loom--macrotask-scheduler callback)
      (error (signal 'loom-scheduler-error
                     `("Failed to enqueue deferred task" ,err)))))
  nil)

(cl-defun loom:microtask (task &key (priority 0))
  "Schedule a `TASK` for immediate execution on the microtask queue.

Arguments:
- `TASK` (function or loom-callback): The task to execute.
- `:PRIORITY` (integer): Optional priority (lower is higher).

Returns `nil`. Signals `loom-scheduler-error` if not initialized."
  (unless loom--microtask-scheduler
    (signal 'loom-scheduler-error '("Microtask scheduler not initialized.")))
  (let ((callback (loom--ensure-callback task :priority priority)))
    (condition-case err (loom:microtask-enqueue loom--microtask-scheduler callback)
      (error (signal 'loom-scheduler-error `("Failed to enqueue microtask" ,err)))))
  nil)

(defun loom:init ()
  "Initialize the entire Loom concurrency library.
This function sets up global schedulers, IPC mechanisms, and other
resources. It is idempotent and safe to call multiple times.

Returns `nil`. Signals `loom-initialization-error` on failure."
  (unless loom--initialized
    (loom-log :info nil "Initializing Loom library.")
    (condition-case err
        (progn
          (loom--init-schedulers)
          (loom:ipc-init)
          (setq loom--initialized t)
          (loom-log :info nil "Loom library initialized successfully."))
      (error
       (loom-log :error nil "Loom initialization failed: %S" err)
       ;; Attempt to clean up any partially initialized resources.
       (loom:shutdown)
       (signal 'loom-initialization-error `("Library init failed" ,err)))))
  nil)

(defun loom:shutdown ()
  "Shut down the Loom library and clean up all allocated resources.
Cleans up IPC, stops schedulers, and resets the library state. This
function is idempotent and robust to partial failures.

Returns `nil`."
  (when loom--initialized
    (loom-log :info nil "Shutting down Loom library.")
    (unwind-protect
        (progn
          ;; The following cleanup steps are individually wrapped in
          ;; condition-case to ensure that a failure in one step does
          ;; not prevent the others from running.

          ;; Stop the generic thread polling scheduler first.
          (condition-case e (loom:thread-polling-stop-scheduler-thread)
            (error (loom-log :error nil "Polling scheduler stop err: %S" e)))

          ;; Clean up IPC resources (including its drain thread).
          (condition-case e (loom:ipc-cleanup)
            (error (loom-log :error nil "IPC cleanup err: %S" e)))

          ;; Stop and reset macrotask scheduler.
          (when loom--macrotask-scheduler
            (condition-case e (loom:scheduler-stop loom--macrotask-scheduler)
              (error (loom-log :error nil "Macrotask scheduler stop err: %S" e)))))
      ;; This cleanup form runs regardless of errors above.
      (progn
        (setq loom--macrotask-scheduler nil)
        (setq loom--microtask-scheduler nil)
        (setq loom--initialized nil)
        (loom-log :info nil "Loom library shutdown complete.")))))
  nil)

;; Hook into Emacs shutdown to ensure graceful resource cleanup.
(add-hook 'kill-emacs-hook #'loom:shutdown)

(loom:init)

(provide 'loom-config)
;;; loom-config.el ends here