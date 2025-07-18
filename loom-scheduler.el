;;; loom-scheduler.el --- Generalized Task Scheduler for Loom -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file provides a generalized, prioritized, and optionally adaptive
;; scheduler for executing asynchronous tasks in batches. It is designed to
;; serve as the primary **macrotask scheduler** for promise libraries like
;; `Concur`, using Emacs's idle timer system (`run-with-idle-timer`) to defer
;; execution and prevent blocking the user interface during background work.
;;
;; ## Core Design
;;
;; The scheduler is designed for robustness and efficiency. It uses an internal
;; `:running-p` state flag to ensure processing "ticks" are discrete and to
;; prevent re-entrancy issues, which could occur with idle timers. It
;; efficiently manages its internal timer, ensuring it is active only when
;; there is actual work to do in the queue, thereby consuming zero resources
;; when idle.
;;
;; ## Key Features
;;
;; - **Prioritized Queue:** Tasks can be enqueued with a priority (or via a
;;   custom comparator), ensuring higher-priority tasks are processed first.
;; - **Cooperative, Non-Blocking Execution:** It leverages Emacs's
;;   `run-with-idle-timer` to ensure processing happens only when Emacs is
;;   idle. This is ideal for background tasks that should not impact UI
;;   responsiveness.
;; - **Adaptive Delay:** The scheduler can dynamically adjust the delay between
;;   processing cycles based on the queue size, balancing responsiveness
;;   (shorter delay for a busy queue) against CPU usage (longer delay for a
;;   quiet queue).
;; - **Batch Processing:** It processes tasks in configurable batches rather
;;   than one at a time, which is more efficient for handling bursts of tasks.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'loom-log)
(require 'loom-lock)
(require 'loom-priority-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-scheduler-error
  "A generic error related to a `loom-scheduler` instance."
  'loom-error)

(define-error 'loom-invalid-scheduler-error
  "An operation was attempted on an object that is not a valid scheduler."
  'loom-scheduler-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-scheduler-default-batch-size 10
  "The default maximum number of tasks to process in one scheduler cycle."
  :type '(integer :min 1)
  :group 'loom)

(defcustom loom-scheduler-default-adaptive-delay t
  "If non-nil, the scheduler's idle timer will use an adaptive delay by default.
This means the delay between processing batches gets shorter as the queue
grows, improving responsiveness under load."
  :type 'boolean
  :group 'loom)

(defcustom loom-scheduler-default-min-delay 0.001
  "The default minimum delay (in seconds) for an adaptive scheduler's idle
timer."
  :type '(float :min 0.0)
  :group 'loom)

(defcustom loom-scheduler-default-max-delay 0.2
  "The default maximum delay (in seconds) for an adaptive scheduler's idle
timer."
  :type '(float :min 0.0)
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-scheduler (:constructor %%make-scheduler) (:copier nil))
  "A generalized, prioritized task scheduler for deferred execution.

This scheduler is designed to run 'macrotasks'—units of work that can be
deferred to a future idle moment in Emacs, preventing the UI from freezing.

Fields:
- `id` (symbol): A unique identifier (`gensym`) for the scheduler instance,
  used for logging and debugging.
- `queue` (loom-priority-queue): The internal priority queue holding tasks.
- `lock` (loom-lock): A mutex protecting the queue and the `timer` and
  `running-p` state fields from race conditions.
- `timer` (timer or nil): The Emacs `idle-timer` object that drives the
  scheduler's processing ticks. It is `nil` if the scheduler is inactive.
- `running-p` (boolean): A flag that is `t` while the scheduler is actively
  processing a batch. This serves as a re-entrancy guard.
- `batch-size` (integer): The max number of tasks to process in one cycle.
- `adaptive-delay-p` (boolean): If `t`, use a dynamic delay between cycles.
- `min-delay` (float): Minimum delay for the adaptive timer.
- `max-delay` (float): Maximum delay for the adaptive timer.
- `process-fn` (function): A mandatory function `(lambda (batch))` that is
  invoked with a list of tasks dequeued from the queue.
- `delay-strategy-fn` (function): A function `(lambda (scheduler))` that
  computes the next timer delay. Defaults to an adaptive strategy."
  id
  (queue nil :type loom-priority-queue)
  (lock nil :type loom-lock)
  (timer nil)
  (running-p nil :type boolean)
  (batch-size loom-scheduler-default-batch-size :type integer)
  (adaptive-delay-p loom-scheduler-default-adaptive-delay :type boolean)
  (min-delay loom-scheduler-default-min-delay :type float)
  (max-delay loom-scheduler-default-max-delay :type float)
  (process-fn nil :type function)
  (delay-strategy-fn #'loom--scheduler-default-delay-strategy
                     :type function))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Core Logic

(defun loom--validate-scheduler (scheduler function-name)
  "Signals an error if `SCHEDULER` is not a `loom-scheduler` object.

Arguments:
- `SCHEDULER` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting.

Signals: `loom-invalid-scheduler-error` if `SCHEDULER` is invalid."
  (unless (loom-scheduler-p scheduler)
    (signal 'loom-invalid-scheduler-error
            (list (format "%s: Expected a loom-scheduler object, but got: %s"
                          function-name scheduler)
                  scheduler))))

(defun loom--scheduler-default-delay-strategy (scheduler)
  "The default strategy to compute the ideal idle timer delay.

It determines how long the scheduler should wait before processing the next
batch. If adaptive delay is disabled, it returns a fixed minimum delay.
Otherwise, it computes a delay that decreases as the queue size grows,
ensuring responsiveness under heavy load while remaining efficient when idle.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler instance.

Returns: The computed delay in seconds for the next timer."
  (if (not (loom-scheduler-adaptive-delay-p scheduler))
      (loom-scheduler-min-delay scheduler)
    ;; Adaptive logic: Delay is inversely proportional to the logarithm of
    ;; the queue size, ensuring rapid processing for busy queues.
    (let* ((n (loom:priority-queue-length (loom-scheduler-queue scheduler)))
           (min-d (loom-scheduler-min-delay scheduler))
           (max-d (loom-scheduler-max-delay scheduler))
           ;; The formula is tuned to decrease delay quickly as `n` grows from 0.
           (computed-delay (/ 0.1 (max 0.1 (/ (log (1+ n)) (log 2))))))
      ;; Clamp the computed delay within the min/max bounds.
      (max min-d (min max-d computed-delay)))))

(defun loom--scheduler-start-timer-if-needed (scheduler)
  "Starts the idle timer for `SCHEDULER` if it's not already running.

This function is the core of the scheduler's efficient resource management.
It ensures that the timer is only active when there are tasks in the queue
and the scheduler is not already processing a batch.
It **must** be called from within a `loom:with-mutex!` block for the
scheduler's lock to ensure thread-safety.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler instance.

Side Effects: May start or re-schedule the scheduler's internal timer."
  ;; Do nothing if a timer is already active or if we are currently running a
  ;; batch.
  (unless (or (timerp (loom-scheduler-timer scheduler))
              (loom-scheduler-running-p scheduler))
    (let ((delay (funcall (loom-scheduler-delay-strategy-fn scheduler)
                          scheduler)))
      (setf (loom-scheduler-timer scheduler)
            (run-with-idle-timer delay nil #'loom--scheduler-timer-callback
                                 scheduler))
      (loom-log :debug (loom-scheduler-id scheduler)
                "Scheduler timer started with delay %.3fs." delay))))

(defun loom--scheduler-timer-callback (scheduler)
  "The main timer callback that processes a batch of tasks.

This function is the heart of the scheduler, triggered by an Emacs idle timer.
It dequeues a batch of tasks, executes them via the `process-fn`, and then
either reschedules itself if more work remains or stops if the queue is empty.
The \"lock -> unlock for work -> lock to finalize\" pattern is crucial for
preventing deadlocks while maintaining state consistency.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler instance whose timer fired."
  (let (batch-to-process)
    ;; Step 1: Atomically set state to running and dequeue a batch of tasks.
    (loom:with-mutex! (loom-scheduler-lock scheduler)
      (setf (loom-scheduler-running-p scheduler) t)
      (setq batch-to-process
            (loom:priority-queue-pop-n
             (loom-scheduler-queue scheduler)
             (loom-scheduler-batch-size scheduler))))

    ;; Step 2: Process the batch *outside* the lock to avoid blocking other
    ;; operations and to allow the `process-fn` to perform complex work.
    (when batch-to-process
      (loom-log :debug (loom-scheduler-id scheduler)
                "Processing a batch of %d tasks." (length batch-to-process))
      (funcall (loom-scheduler-process-fn scheduler) batch-to-process))

    ;; Step 3: Update state and decide whether to reschedule or stop.
    ;; This is done under the lock to ensure atomicity.
    (loom:with-mutex! (loom-scheduler-lock scheduler)
      (setf (loom-scheduler-running-p scheduler) nil)
      (setf (loom-scheduler-timer scheduler) nil) ; Timer is now considered used up.
      (if (loom:priority-queue-empty-p (loom-scheduler-queue scheduler))
          (progn
            ;; If the queue is empty, we are done. The timer remains nil.
            (loom-log :debug (loom-scheduler-id scheduler)
                      "Scheduler work complete (queue empty)."))
        ;; If work remains, start a new timer for the next batch.
        (loom--scheduler-start-timer-if-needed scheduler)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:scheduler
    (&key name
          process-fn
          (priority-fn #'identity)
          (comparator nil)
          (batch-size loom-scheduler-default-batch-size)
          adaptive-delay-p min-delay max-delay
          delay-strategy-fn)
  "Creates and returns a new `loom-scheduler` instance.

This scheduler processes tasks asynchronously using an idle timer, making it
ideal for background work that should not block the Emacs UI.

Arguments:
- `:NAME` (string): A descriptive name for logging and debugging.
- `:PROCESS-FN` (function): A mandatory function `(lambda (batch))` that will
  be invoked with a list of tasks to process.
- `:PRIORITY-FN` (function): A function `(lambda (task))` returning a numerical
  priority. Lower numbers are higher priority. Used if `:comparator` is not set.
- `:COMPARATOR` (function, optional): A two-argument function `(A B)` that
  returns non-nil if item A has higher priority than item B. Overrides
  `:priority-fn`.
- `:BATCH-SIZE` (integer): Max tasks to process per cycle.
- `:ADAPTIVE-DELAY-P` (boolean): If `t`, the idle timer delay will be dynamic.
- `:MIN-DELAY` (float): Minimum delay in seconds for the timer.
- `:MAX-DELAY` (float): Maximum delay in seconds for the timer.
- `:DELAY-STRATEGY-FN` (function): A function `(lambda (scheduler))` to compute
  the next delay. Overrides the default adaptive strategy.

Returns: A newly created `loom-scheduler` instance."
  (unless (functionp process-fn) (error ":process-fn must be a function"))
  (unless (functionp priority-fn) (error ":priority-fn must be a function"))
  (when (and comparator (not (functionp comparator)))
    (error ":comparator must be a function"))

  (let* ((id (gensym (or name "scheduler-")))
         (scheduler
          (%%make-scheduler
           :id id
           :batch-size batch-size
           :process-fn process-fn
           :adaptive-delay-p (or adaptive-delay-p
                                 loom-scheduler-default-adaptive-delay)
           :min-delay (or min-delay loom-scheduler-default-min-delay)
           :max-delay (or max-delay loom-scheduler-default-max-delay)
           :delay-strategy-fn (or delay-strategy-fn
                                  #'loom--scheduler-default-delay-strategy)
           :lock (loom:lock (format "%S-lock" id)))))
    ;; Set up the internal priority queue with the specified comparator logic.
    (setf (loom-scheduler-queue scheduler)
          (loom:priority-queue
           :comparator (or comparator
                           (lambda (a b) (< (funcall priority-fn a)
                                           (funcall priority-fn b))))))
    (loom-log :info (loom-scheduler-id scheduler)
              "Scheduler created (name: %s)." (or name "unnamed"))
    scheduler))

;;;###autoload
(defun loom:scheduler-enqueue (scheduler task)
  "Adds a `TASK` to the `SCHEDULER`'s queue and starts its timer if needed.
This is the main entry point for submitting work to the scheduler.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler instance.
- `TASK` (any): The task to add (e.g., a `loom-callback` object).

Returns: `nil`.
Signals: `loom-invalid-scheduler-error` if `SCHEDULER` is invalid.
Side Effects: Modifies the scheduler's queue and may start its idle timer."
  (loom--validate-scheduler scheduler 'loom:scheduler-enqueue)
  (loom-log :debug (loom-scheduler-id scheduler) "Enqueuing task.")
  (loom:with-mutex! (loom-scheduler-lock scheduler)
    ;; Add the task to the priority queue.
    (loom:priority-queue-insert (loom-scheduler-queue scheduler) task)
    ;; Ensure the timer is running, now that there's work to do.
    (loom--scheduler-start-timer-if-needed scheduler)))

;;;###autoload
(defun loom:scheduler-stop (scheduler)
  "Stops the `SCHEDULER`'s timer, preventing further automatic processing.
Any tasks remaining in the queue will not be processed unless the scheduler
is started again (e.g., by enqueuing a new task or calling `scheduler-drain`).

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler instance to stop.

Returns: `nil`.
Side Effects: Cancels the scheduler's internal idle timer."
  (loom--validate-scheduler scheduler 'loom:scheduler-stop)
  (loom:with-mutex! (loom-scheduler-lock scheduler)
    (when-let ((timer (loom-scheduler-timer scheduler)))
      (cancel-timer timer)
      (setf (loom-scheduler-timer scheduler) nil)
      (loom-log :info (loom-scheduler-id scheduler)
                "Scheduler timer explicitly stopped."))))

;;;###autoload
(defun loom:scheduler-drain (scheduler)
  "Processes a single batch of tasks from the `SCHEDULER`'s queue.
Unlike `loom:microtask-drain`, this processes at most one batch of tasks.
It is useful for cooperatively yielding inside a long-running function
or a custom wait loop.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler instance.

Returns: `t` if a batch was processed, `nil` otherwise (e.g., if the
  scheduler was already busy processing another batch)."
  (loom--validate-scheduler scheduler 'loom:scheduler-drain)
  (let (batch-to-process)
    ;; Step 1: Dequeue a batch under lock, but only if not already running.
    (loom:with-mutex! (loom-scheduler-lock scheduler)
      (unless (loom-scheduler-running-p scheduler)
        (setq batch-to-process
              (loom:priority-queue-pop-n
               (loom-scheduler-queue scheduler)
               (loom-scheduler-batch-size scheduler)))))
    ;; Step 2: Process the batch outside the lock.
    (when batch-to-process
      (loom-log :debug (loom-scheduler-id scheduler)
                "Explicit drain processing batch of %d tasks."
                (length batch-to-process))
      (funcall (loom-scheduler-process-fn scheduler) batch-to-process)
      t)))

;;;###autoload
(defun loom:scheduler-status (scheduler)
  "Returns a snapshot of the `SCHEDULER`'s current status.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler to inspect.

Returns:
- (plist): A property list containing metrics about the scheduler:
  - `:id`: The unique symbol identifying the scheduler.
  - `:queue-length`: The number of tasks currently waiting.
  - `:is-running-p`: `t` if the scheduler is in the middle of processing a
    batch.
  - `:has-timer-p`: `t` if an idle timer is currently scheduled.

Signals: `loom-invalid-scheduler-error` if `SCHEDULER` is invalid."
  (loom--validate-scheduler scheduler 'loom:scheduler-status)
  (loom:with-mutex! (loom-scheduler-lock scheduler)
    `(:id ,(loom-scheduler-id scheduler)
      :queue-length ,(loom:priority-queue-length (loom-scheduler-queue scheduler))
      :is-running-p ,(loom-scheduler-running-p scheduler)
      :has-timer-p ,(timerp (loom-scheduler-timer scheduler)))))

(provide 'loom-scheduler)
;;; loom-scheduler.el ends here