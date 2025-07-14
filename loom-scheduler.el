;;; loom-scheduler.el --- Generalized Task Scheduler for Concur -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file provides a generalized, prioritized, and optionally adaptive
;; scheduler for executing asynchronous tasks in batches. It primarily serves
;; as the **macrotask scheduler** for the `Concur` promise library, using
;; Emacs's idle timer to defer execution and prevent UI blocking while
;; performing background work.
;;
;; The scheduler is designed for robustness. It uses an internal `:running-p`
;; state flag to ensure processing ticks are discrete and to prevent
;; re-entrancy issues. It efficiently manages its internal timer, ensuring
;; it is active only when there is actual work to do in the queue.
;;
;; Key functionalities:
;; - **Prioritized Queue:** Tasks can be enqueued with a priority, ensuring
;;   higher-priority tasks are processed first.
;; - **Adaptive Delay:** Can dynamically adjust the delay between processing
;;   cycles based on the queue size, optimizing responsiveness versus CPU usage.
;; - **Non-Blocking Execution:** Leverages Emacs's idle timer
;;   (`run-with-idle-timer`) to ensure processing happens cooperatively when
;;   Emacs is idle, preserving UI responsiveness during long-running tasks.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'loom-log)
(require 'loom-lock)
(require 'loom-priority-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-scheduler-error
  "A generic error related to a `loom-scheduler`."
  'loom-error)

(define-error 'loom-invalid-scheduler-error
  "An operation was attempted on an invalid scheduler object."
  'loom-scheduler-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-scheduler-default-batch-size 10
  "Default maximum number of tasks to process in one scheduler cycle."
  :type '(integer :min 1)
  :group 'loom)

(defcustom loom-scheduler-default-adaptive-delay t
  "If non-nil, use an adaptive delay for scheduler timers by default."
  :type 'boolean
  :group 'loom)

(defcustom loom-scheduler-default-min-delay 0.001
  "Default minimum delay (in seconds) for the adaptive scheduler."
  :type '(float :min 0.0)
  :group 'loom)

(defcustom loom-scheduler-default-max-delay 0.2
  "Default maximum delay (in seconds) for the adaptive scheduler."
  :type '(float :min 0.0)
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-scheduler (:constructor %%make-scheduler) (:copier nil))
  "A generalized, prioritized task scheduler for deferred execution.

This scheduler is designed to run 'macrotasks'—units of work that can be
deferred to a future idle moment in Emacs, preventing the UI from freezing.

Fields:
- `id` (symbol): A unique identifier for the scheduler instance, used for
  logging and debugging.
- `queue` (loom-priority-queue): The internal priority queue that holds
  the tasks waiting for execution.
- `lock` (loom-lock): A mutex that protects the queue and other internal
  state fields (`timer`, `running-p`) from race conditions.
- `timer` (timer or nil): The Emacs `idle-timer` object that drives the
  scheduler's processing ticks. It is `nil` if the scheduler is inactive.
- `running-p` (boolean): A flag that is `t` while the scheduler is actively
  processing a batch of tasks. This prevents re-entrant timer calls.
- `batch-size` (integer): The maximum number of tasks to process in a
  single execution cycle.
- `adaptive-delay-p` (boolean): If `t`, the scheduler uses a dynamic delay
  between cycles based on queue size.
- `min-delay` (float): The minimum delay in seconds for the timer when
  adaptive delay is enabled.
- `max-delay` (float): The maximum delay in seconds for the timer when
  adaptive delay is enabled.
- `process-fn` (function): A mandatory function `(lambda (batch))` that is
  invoked with a list of tasks to process.
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
  "Signal an error if `SCHEDULER` is not a `loom-scheduler` object.

Arguments:
- `SCHEDULER` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting.

Signals:
- `loom-invalid-scheduler-error` if `SCHEDULER` is invalid."
  (unless (loom-scheduler-p scheduler)
    (signal 'loom-invalid-scheduler-error
            (list (format "%s: Invalid scheduler object" function-name)
                  scheduler))))

(defun loom--scheduler-default-delay-strategy (scheduler)
  "Default strategy to compute the ideal idle timer delay.
It determines how long the scheduler should wait before processing the next
batch of tasks. If adaptive delay is disabled, it returns a fixed minimum
delay. Otherwise, it computes a delay that decreases as the queue size
grows, ensuring responsiveness under heavy load.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler instance.

Returns:
- (float): The computed delay in seconds for the next timer tick."
  (if (not (loom-scheduler-adaptive-delay-p scheduler))
      (loom-scheduler-min-delay scheduler)
    ;; Adaptive logic: Delay decreases as queue size (n) increases.
    (let* ((n (loom:priority-queue-length
               (loom-scheduler-queue scheduler)))
           (min-d (loom-scheduler-min-delay scheduler))
           (max-d (loom-scheduler-max-delay scheduler))
           (computed-delay (/ 0.1 (max 0.1 (/ (log (1+ n)) (log 2))))))
      (max min-d (min max-d computed-delay)))))

(defun loom--scheduler-start-timer-if-needed (scheduler)
  "Start the idle timer for `SCHEDULER` if it's not already running.
This function ensures that the scheduler's timer is active if there are
tasks in the queue and the scheduler is not already processing a batch.
It MUST be called from within the scheduler's lock to ensure thread-safety.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler instance.

Side Effects:
- May start or re-schedule the `scheduler`'s internal timer.
- Updates the `scheduler-timer` field of the scheduler struct."
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
  "The main timer callback that processes batches of macrotasks.
This function is the heart of the scheduler. It is triggered by an Emacs
idle timer. It dequeues a batch of tasks, executes them, and then either
reschedules itself if more work remains or stops if the queue is empty.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler instance whose timer fired.

Side Effects:
- Processes tasks by calling the scheduler's `process-fn`.
- Modifies the scheduler's `running-p` and `timer` state fields."
  (let (batch-to-process)
    ;; 1. Dequeue a batch of tasks under lock.
    (loom:with-mutex! (loom-scheduler-lock scheduler)
      (setf (loom-scheduler-running-p scheduler) t)
      (setq batch-to-process
            (loom:priority-queue-pop-n
             (loom-scheduler-queue scheduler)
             (loom-scheduler-batch-size scheduler))))

    ;; 2. Process the batch outside the lock to avoid blocking other threads.
    (when batch-to-process
      (funcall (loom-scheduler-process-fn scheduler) batch-to-process))

    ;; 3. Update state and reschedule or stop, again under lock.
    (loom:with-mutex! (loom-scheduler-lock scheduler)
      (setf (loom-scheduler-running-p scheduler) nil)
      (if (loom:priority-queue-empty-p (loom-scheduler-queue scheduler))
          (when-let ((timer (loom-scheduler-timer scheduler)))
            (cancel-timer timer)
            (setf (loom-scheduler-timer scheduler) nil)
            (loom-log :debug (loom-scheduler-id scheduler)
                        "Scheduler timer cancelled (queue empty)."))
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
  "Create and return a new `loom-scheduler` instance.
This scheduler is designed to process tasks asynchronously using an idle timer,
making it ideal for background work that should not block the Emacs UI.

Arguments:
- `:NAME` (string): A descriptive name for logging and debugging.
- `:PROCESS-FN` (function): A mandatory function `(lambda (batch))` that will
  be invoked with a list of tasks to process.
- `:PRIORITY-FN` (function): A function `(lambda (task))` that returns a
  numerical priority for a task. Lower numbers are higher priority. This is
  now primarily for backward compatibility if a `comparator` is not provided.
- `:COMPARATOR` (function, optional): A function `(A B)` that returns non-nil
  if item A has higher priority than item B. If provided, this overrides
  `:priority-fn` for the internal priority queue.
- `:BATCH-SIZE` (integer): The maximum number of tasks to process per cycle.
- `:ADAPTIVE-DELAY-P` (boolean): If `t`, the idle timer delay will be
  dynamically adjusted based on the queue size.
- `:MIN-DELAY` (float): The minimum delay in seconds for the scheduler.
- `:MAX-DELAY` (float): The maximum delay in seconds for the scheduler.
- `:DELAY-STRATEGY-FN` (function): An optional function `(lambda (scheduler))`
  to compute the next delay. Overrides the default adaptive strategy.

Returns:
- (loom-scheduler): A newly created scheduler instance."
  (unless (functionp process-fn) (error ":process-fn must be a function"))
  ;; If a comparator is provided, priority-fn is less critical, but still check for type.
  (unless (functionp priority-fn) (error ":priority-fn must be a function"))
  (when (and comparator (not (functionp comparator))) (error ":comparator must be a function"))

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
    (setf (loom-scheduler-queue scheduler)
          (loom:priority-queue
           :comparator (or comparator ; Use direct comparator if provided
                           (lambda (a b) (< (funcall priority-fn a) ; Fallback to priority-fn
                                            (funcall priority-fn b))))))
    (loom-log :info (loom-scheduler-id scheduler) "Scheduler created.")
    scheduler))

;;;###autoload
(defun loom:scheduler-enqueue (scheduler task)
  "Add a `TASK` to the `SCHEDULER`'s queue and start its timer if needed.
This is the main entry point for adding work to the scheduler.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler instance.
- `TASK` (any): The task to add (e.g., a `loom-callback` object).

Returns:
- `nil`.

Signals:
- `loom-invalid-scheduler-error` if `SCHEDULER` is not a valid scheduler.

Side Effects:
- Modifies the `scheduler`'s internal priority queue.
- May start the `scheduler`'s idle timer if it is not already running."
  (loom--validate-scheduler scheduler 'loom:scheduler-enqueue)
  (loom:with-mutex! (loom-scheduler-lock scheduler)
    (loom:priority-queue-insert (loom-scheduler-queue scheduler) task)
    (loom--scheduler-start-timer-if-needed scheduler)))

;;;###autoload
(defun loom:scheduler-stop (scheduler)
  "Stop the `SCHEDULER`'s timer, preventing further processing.
Any tasks remaining in the queue will not be processed unless the
scheduler is started again by enqueuing a new task.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler instance to stop.

Returns:
- `nil`.

Side Effects:
- Cancels the `scheduler`'s internal idle timer.
- Clears the `scheduler`'s `timer` field."
  (loom--validate-scheduler scheduler 'loom:scheduler-stop)
  (loom:with-mutex! (loom-scheduler-lock scheduler)
    (when-let ((timer (loom-scheduler-timer scheduler)))
      (cancel-timer timer)
      (setf (loom-scheduler-timer scheduler) nil)
      (loom-log :info (loom-scheduler-id scheduler) "Scheduler stopped."))))

;;;###autoload
(defun loom:scheduler-drain-once (scheduler)
  "Process a single batch of tasks from the SCHEDULER, if not already running.
This is useful for cooperatively yielding inside a blocking wait.

Arguments:
- SCHEDULER (loom-scheduler): The scheduler instance.

Returns:
- `t` if a batch was processed, `nil` otherwise."
  (loom--validate-scheduler scheduler 'loom:scheduler-drain-once)
  (let (batch-to-process)
    ;; 1. Dequeue a batch of tasks under lock, but only if not already running.
    (loom:with-mutex! (loom-scheduler-lock scheduler)
      (unless (loom-scheduler-running-p scheduler)
        (setq batch-to-process
              (loom:priority-queue-pop-n
               (loom-scheduler-queue scheduler)
               (loom-scheduler-batch-size scheduler)))))
    ;; 2. Process the batch outside the lock.
    (when batch-to-process
      (funcall (loom-scheduler-process-fn scheduler) batch-to-process)
      t)))

;;;###autoload
(defun loom:scheduler-status (scheduler)
  "Return a snapshot of the `SCHEDULER`'s current status.

Arguments:
- `SCHEDULER` (loom-scheduler): The scheduler to inspect.

Returns:
- (plist): A property list containing metrics about the scheduler, including
  `:id`, `:queue-length`, `:is-running-p`, and `:has-timer-p`.

Signals:
- `loom-invalid-scheduler-error` if `SCHEDULER` is invalid."
  (loom--validate-scheduler scheduler 'loom:scheduler-status)
  (loom:with-mutex! (loom-scheduler-lock scheduler)
    `(:id ,(loom-scheduler-id scheduler)
      :queue-length ,(loom:priority-queue-length
                      (loom-scheduler-queue scheduler))
      :is-running-p ,(loom-scheduler-running-p scheduler)
      :has-timer-p ,(timerp (loom-scheduler-timer scheduler)))))

(provide 'loom-scheduler)
;;; loom-scheduler.el ends here