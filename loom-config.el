;;; loom-config.el --- Core functionality for Concur Promises -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file defines the global infrastructure for the Concur Promises library,
;; including the inter-thread communication mechanism and the global schedulers
;; for microtasks and macrotasks. It acts as the central orchestrator,
;; coordinating between different modules.
;;
;; The `loom-promise` data structure and its direct lifecycle operations
;; have been moved to `loom-promise.el` for better modularity.
;;
;; Architectural Highlights:
;;
;; - Promise/A+ Compliant Scheduling: Separates macrotasks (for `.then`
;;   callbacks, run on an idle timer) and microtasks (for `await` and
;;   internal chaining, run immediately) to ensure a responsive and
;;   predictable execution order.
;;
;; - True Thread-Safe Signaling: For promises in `:thread` mode, a dedicated
;;   pipe and process sentinel are used. This allows background threads to
;;   safely and efficiently schedule callbacks on the main Emacs thread
;;   without polling.

;;; Code:

(require 'cl-lib)
(require 'dash) 
(require 's) 
(require 'json)

(require 'loom-log)
(require 'loom-lock)
(require 'loom-registry)
(require 'loom-microtask)
(require 'loom-scheduler)
(require 'loom-errors)
(require 'loom-callback)
(require 'loom-promise) 

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization 

(defgroup loom nil "Asynchronous programming primitives for Emacs."
  :group 'emacs)

(defcustom loom-log-value-max-length 100
  "Max length of a value/error string in logs before truncation."
  :type 'integer
  :group 'loom)

(defcustom loom-await-poll-interval 0.01
  "The polling interval (in seconds) for cooperative `loom:await` blocking."
  :type 'float
  :group 'loom)

(defcustom loom-await-default-timeout 10.0
  "Default timeout (seconds) for `loom:await` if not specified.
If `nil`, `loom:await` will wait indefinitely by default."
  :type '(choice (float :min 0.0) (const :tag "Indefinite" nil))
  :group 'loom)

(defcustom loom-normalize-awaitable-hook nil
  "Hook to normalize arbitrary awaitable objects into `loom-promise`s.
Functions on this hook receive one argument, the object to normalize.
If a function recognizes the object, it should return a `loom-promise`
that represents the object's asynchronous lifecycle. If it does not
recognize it, it should return `nil`."
  :type 'hook
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; True Thread-Safe Signaling Mechanism

(defvar loom--thread-ipc-process nil
  "A long-lived process used for thread-to-main-thread communication.")

(defvar loom--thread-ipc-buffer nil
  "Buffer used for accumulating partial JSON messages from IPC process.")

(defun loom--thread-callback-dispatcher (promise-id)
  "Dispatches a promise settlement from a background thread to the main
Emacs thread. This function sends the `PROMISE-ID` of a settled promise
to the main Emacs thread via a dedicated Inter-Process Communication (IPC)
process. This is essential for safely updating Emacs's UI and internal
state from background threads, as most Emacs Lisp functions are not
thread-safe.

Arguments:
- `PROMISE-ID` (symbol): The unique identifier of the promise that has
  settled.

Returns:
- `nil`.

Side Effects:
- Sends a JSON-encoded message containing `PROMISE-ID` to the IPC process."
  (loom-log :debug promise-id "Dispatching settlement from thread to main thread.")
  (when (and loom--thread-ipc-process
             (process-live-p loom--thread-ipc-process))
    (condition-case err
        (process-send-string
         loom--thread-ipc-process
         (format "%s\n" (json-encode `(:id ,promise-id))))
      (error
       (loom-log :error promise-id
                 "Failed to dispatch to main thread: %S" err)))))

(defun loom--process-settled-on-main (promise-id)
  "Processes a settled promise on the main Emacs thread.
This function is called by the `loom--thread-ipc-filter` when a promise
settlement message is received from a background thread. It looks up the
promise by its `PROMISE-ID` and then triggers its registered callbacks.

Arguments:
- `PROMISE-ID` (symbol): The unique identifier of the promise to process.

Returns:
- `t` if the promise was found and processed, `nil` otherwise.

Side Effects:
- Retrieves the promise from the registry.
- Clears the promise's callbacks.
- Triggers the promise's callbacks."
  (loom-log :debug promise-id "Received settlement signal on main thread.")
  (if-let ((promise (loom-registry-get-promise-by-id promise-id)))
      (progn
        (let ((callbacks (loom-promise-callbacks promise)))
          (setf (loom-promise-callbacks promise) nil)
          ;; Call the function now defined in loom-promise.el
          (loom--trigger-callbacks-after-settle promise callbacks))
        t)
    (loom-log :warn nil "Main-thread cb: couldn't find promise ID %S"
              promise-id)
    nil))

(defun loom--thread-ipc-filter (process string)
  "Filters and dispatches promise IDs received from background threads.
This function is attached as a filter to the `loom--thread-ipc-process`.
It runs on the main Emacs thread whenever output is received from the IPC
process. It parses incoming JSON messages, extracts promise IDs, and
dispatches them for main-thread processing.

Arguments:
- `PROCESS` (process): The IPC process that generated the output.
- `STRING` (string): The output string received from the process.

Returns:
- `nil`.

Signals:
- `error`: If JSON parsing fails for a line.

Side Effects:
- Creates a temporary buffer for processing.
- Parses JSON strings from the input `STRING`.
- Calls `loom--process-settled-on-main` for each valid promise ID."
  (unless loom--thread-ipc-buffer
    (setq loom--thread-ipc-buffer (generate-new-buffer "*loom-ipc-filter*")))
  
  (with-current-buffer loom--thread-ipc-buffer
    (goto-char (point-max))
    (insert string)
    (goto-char (point-min))
    ;; Process line by line, as each line is a separate JSON message.
    (while (re-search-forward "\n" nil t)
      (let* ((line (buffer-substring-no-properties (point-min)
                                                   (match-beginning 0)))
             (json-object-type 'plist)) ; Ensure JSON parsing returns plists
        (delete-region (point-min) (point))
        (condition-case err
            (when-let* ((payload (json-read-from-string line))
                        (id (plist-get payload :id)))
              (loom-log :debug id "IPC filter processing line: %s" (s-trim line))
              (loom--process-settled-on-main id))
          (error
           (loom-log :error nil "Failed to parse IPC message: %S, line: %S"
                     err line)))))))

(defun loom--cleanup-thread-ipc ()
  "Cleans up thread IPC resources."
  (when loom--thread-ipc-process
    (ignore-errors (delete-process loom--thread-ipc-process))
    (setq loom--thread-ipc-process nil))
  (when loom--thread-ipc-buffer
    (ignore-errors (kill-buffer loom--thread-ipc-buffer))
    (setq loom--thread-ipc-buffer nil)))

(defun loom--init-thread-signaling ()
  "Initializes the inter-thread communication process and filter.
This function sets up a dedicated `cat` process and a filter to enable
safe and efficient communication from background Emacs threads back to
the main Emacs thread. This replaces a previous, more complex two-process
design with a single, robust message relay.

The `cat` process simply echoes its standard input to its standard output,
acting as a pipe. The `loom--thread-ipc-filter` then reads from this pipe
on the main thread. A sentinel is also set up to handle process termination
and attempt restarts.

This mechanism is crucial for ensuring thread-safety when promise callbacks
need to interact with Emacs's main thread (e.g., updating UI or internal
state) from a `:thread` mode promise.

Arguments:
- None.

Returns:
- `nil`.

Side Effects:
- Creates a new Emacs process named 'loom-thread-ipc'.
- Sets the process filter to `loom--thread-ipc-filter`.
- Sets a sentinel on the process to restart it upon termination.
- Sets the `loom--thread-ipc-process` global variable."
  (when (and (fboundp 'make-thread) (not loom--thread-ipc-process))
    (loom-log :info nil "Initializing thread signaling mechanism.")
    (condition-case err
        (setq loom--thread-ipc-process
              (make-process
               :name "loom-thread-ipc"
               ;; Using "cat" is a simple and effective way to create a relay.
               ;; It just echoes its stdin to its stdout.
               :command '("cat")
               :connection-type 'pipe
               :noquery t
               :coding 'utf-8-emacs-unix
               :filter #'loom--thread-ipc-filter
               :sentinel (lambda (proc event)
                           (when (memq (process-status proc) '(exit signal))
                             (loom-log :error nil
                                       "Thread IPC process died: %s. Will restart."
                                       event)
                             (setq loom--thread-ipc-process nil)
                             ;; Attempt to restart it on the next idle tick.
                             (run-with-idle-timer
                              0.1 nil #'loom--init-thread-signaling)))))
      (error
       (loom-log :error nil "Failed to initialize thread signaling: %S" err)
       (setq loom--thread-ipc-process nil)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State and Schedulers

(defvar loom--macrotask-scheduler nil
  "The global scheduler instance for standard promise callbacks (macrotasks).")

(defvar loom--microtask-scheduler nil
  "The global scheduler for high-priority callbacks (microtasks).")

(defun loom--promise-microtask-overflow-handler (queue overflowed-cbs)
  "Handles the overflow of the microtask queue by rejecting affected
promises. When the `loom-microtask-queue` exceeds its capacity, this
handler is invoked. It creates a `loom-error` of type
`:loom-microtask-queue-overflow` and rejects each promise whose
callback was dropped due to the overflow.

Arguments:
- `QUEUE` (loom-microtask-queue): The microtask queue that overflowed.
- `OVERFLOWED-CBS` (list of loom-callback): The list of callbacks that
  were dropped from the queue.

Returns:
- `nil`.

Side Effects:
- Rejects promises associated with `OVERFLOWED-CBS`."
  (let ((msg (format "Microtask queue overflow on %S (%d dropped)."
                     (loom-microtask-queue-capacity queue)
                     (length overflowed-cbs))))
    (loom-log :error nil "%s" msg)
    (dolist (cb overflowed-cbs)
      (when-let* ((data (loom-callback-data cb))
                  (promise-id (plist-get data :promise-id))
                  (promise (loom-registry-get-promise-by-id promise-id)))
        (loom-log :error promise-id "Rejecting due to microtask overflow.")
        (loom:reject promise (loom:make-error
                                :type 'loom-microtask-queue-overflow
                                :message msg))))))

(defun loom--callback-fifo-priority (cb-a cb-b)
  "Comparator for loom-callbacks, prioritizing by `priority` then `sequence-id`.
Returns non-nil if CB-A has higher priority than CB-B.
Lower `priority` value is higher priority.
For equal `priority`, lower `sequence-id` (earlier creation) is higher priority.

Arguments:
- `CB-A` (loom-callback): The first callback to compare.
- `CB-B` (loom-callback): The second callback to compare.

Returns:
- (boolean): `t` if `CB-A` has higher priority than `CB-B`, `nil` otherwise."
  (let ((prio-a (loom-callback-priority cb-a))
        (prio-b (loom-callback-priority cb-b)))
    (cond
     ((< prio-a prio-b) t) ; CB-A has higher priority (lower value)
     ((> prio-a prio-b) nil) ; CB-B has higher priority
     (t ; Priorities are equal, use sequence-id for FIFO tie-breaking
      (< (loom-callback-sequence-id cb-a)
         (loom-callback-sequence-id cb-b))))))

(defun loom--init-schedulers ()
  "Initializes the global microtask and macrotask schedulers if they are
not already set up. This function ensures that the
`loom--microtask-scheduler` and `loom--macrotask-scheduler` global
variables are bound to active scheduler instances.

- **Microtask Queue**: The microtask queue (`loom--microtask-scheduler`)
  is designed for high-priority, immediate execution of callbacks, such as
  `await` latches and promise chaining. These run as soon as the current
  Emacs Lisp call stack is clear.
- **Macrotask Scheduler**: The macrotask scheduler
  (`loom--macrotask-scheduler`) handles standard `.then` and `.catch`
  callbacks. These are typically scheduled to run on Emacs's idle timer,
  ensuring that long-running callback chains do not block the Emacs UI.

Each scheduler is configured with `loom--execute-callback` as its
executor and appropriate overflow handling for microtasks.

This function is called once during the library's initialization.

Arguments:
- None.

Returns:
- `nil`.

Side Effects:
- Creates and initializes `loom--microtask-scheduler` and
  `loom--macrotask-scheduler` global variables."
  (unless loom--microtask-scheduler
    (loom-log :info nil "Initializing microtask scheduler.")
    (setq loom--microtask-scheduler
          (loom:microtask-queue
           :executor #'loom--execute-callback
           :overflow-handler #'loom--promise-microtask-overflow-handler)))

  (unless loom--macrotask-scheduler
    (loom-log :info nil "Initializing macrotask scheduler.")
    (setq loom--macrotask-scheduler
          (loom:scheduler
           :name "loom-macrotask-scheduler"
           ;; The scheduler will now pass a comparator directly to the priority queue.
           ;; The :priority-fn argument is effectively ignored/unused by the scheduler
           ;; itself, but it needs to be present in the loom:scheduler constructor.
           :priority-fn #'identity ; Placeholder, as the comparator is now direct
           :comparator #'loom--callback-fifo-priority ; Pass the custom comparator
           :process-fn (lambda (batch)
                         (loom-log :debug nil
                                   "Processing macrotask batch of size %d."
                                   (length batch))
                         (dolist (item batch)
                           (loom--execute-callback item)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global Deferred Task API

;;;###autoload
(defun loom:deferred (task)
  "Schedule TASK for deferred execution on the global macrotask scheduler.

This function adds TASK to the main macrotask queue, which is processed
cooperatively when Emacs is idle. It is the standard way to yield
execution and perform background work without blocking the UI.

This is distinct from `loom:schedule-microtask`, which executes
immediately after the current operation without yielding to the main
event loop.

Arguments:
- TASK (function or loom-callback): The task to execute. If TASK is a
  function, it will be wrapped in a standard `:deferred` callback struct
  with a default low priority.

Returns:
- The scheduled callback struct, allowing for potential cancellation
  or inspection.

Signals:
- `loom-scheduler-not-initialized`: If the global scheduler is not available.
- `wrong-type-argument`: If TASK is not a function or loom-callback struct.

Side Effects:
- Enqueues TASK on the global `loom--macrotask-scheduler`."
  (unless loom--macrotask-scheduler
    (signal 'loom-scheduler-not-initialized-error
            '("Global macrotask scheduler not initialized")))
  
  (let ((callback-to-schedule
         (cond
          ((loom-callback-p task)
           ;; If it's already a loom-callback, ensure it has a sequence-id.
           ;; This handles cases where a loom-callback might be created directly
           ;; and then deferred, ensuring it still gets a sequence-id.
           (if (loom-callback-sequence-id task)
               task
             (loom:callback (loom-callback-handler-fn task) ; Handler function as first argument
                            :type (loom-callback-type task)
                            :priority (loom-callback-priority task)
                            :data (loom-callback-data task))))
          ((functionp task)
           (loom:callback task ; Handler function as first argument
                          :type :deferred
                          :priority 50
                          :data nil))
          (t (signal 'wrong-type-argument 
                     (list 'function-or-loom-callback-p task))))))
    
      (loom:scheduler-enqueue loom--macrotask-scheduler callback-to-schedule)
    callback-to-schedule))

;; Initialize critical infrastructure on library load.
(loom--init-thread-signaling)
(loom--init-schedulers)

(provide 'loom-config)
;;; loom-config.el ends here