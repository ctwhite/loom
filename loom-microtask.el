;;; loom-microtask.el --- Microtask Queue for Concur Promises -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file provides a self-scheduling microtask queue for the Concur library,
;; designed to meet the requirements of the Promise/A+ specification.
;;
;; What is a microtask?
;; A microtask is a small piece of work (like executing a promise callback)
;; that must run "as soon as possible" after the current operation finishes,
;; but *before* Emacs handles new user input or other timers. Microtasks execute
;; synchronously within the current call stack until the queue is empty.
;;
;; Why are microtasks necessary for promises?
;; The Promise/A+ specification (section 2.2.4) requires that promise
;; callbacks (`onFulfilled` or `onRejected`) are called asynchronously, never
;; in the same turn of the event loop that settled the promise. For specific
;; high-priority internal tasks (like `await` latch signaling), microtasks
;; ensure immediate processing.
;;
;; This version enhances flexibility by allowing a custom overflow handling
;; function to be provided during queue creation.

;;; Code:

(require 'cl-lib)

(require 'loom-log)
(require 'loom-errors)
(require 'loom-callback)
(require 'loom-lock)
(require 'loom-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-microtask-error
  "A generic error related to the microtask queue."
  'loom-error)

(define-error 'loom-microtask-queue-overflow
  "The microtask queue has exceeded its capacity."
  'loom-microtask-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-microtask-queue-default-capacity 1024
  "Default maximum number of microtasks allowed in a microtask queue.
If the limit is reached, newly added tasks will be handled by the queue's
`overflow-handler`. A capacity of 0 means the queue will always be
considered full, routing all new tasks to the overflow handler."
  :type '(integer :min 0)
  :group 'loom)

(defcustom loom-microtask-default-batch-size 128
  "Default maximum number of microtasks to process in a single drain tick."
  :type '(integer :min 1)
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State & Struct Definition

(cl-defstruct (loom-microtask-queue (:constructor %%make-microtask-queue))
  "Internal structure representing the microtask queue.

Fields:
- `queue` (loom-queue): The underlying FIFO queue holding the callbacks
  to be executed.
- `lock` (loom-lock): A mutex to synchronize access to the queue and
  the scheduler's state flags (`drain-scheduled-p`).
- `drain-scheduled-p` (boolean): A flag that is `t` if a drain operation
  is currently running. This prevents recursive or overlapping drains.
- `drain-tick-counter` (integer): A counter for drain cycles, useful for
  debugging and tracing.
- `executor` (function): The function `(lambda (callback))` that is called
  to execute each individual microtask.
- `capacity` (integer): The maximum number of items the queue can hold
  before triggering the overflow handler.
- `max-batch-size` (integer): The maximum number of microtasks to process
  in a single cycle of the drain loop.
- `overflow-handler` (function): A function `(lambda (queue callbacks))`
  that is called when the queue's capacity is exceeded."
  (queue nil :type (or null loom-queue-p))
  (lock nil :type (or null loom-lock-p))
  (drain-scheduled-p nil :type boolean)
  (drain-tick-counter 0 :type integer)
  (executor nil :type function)
  (capacity loom-microtask-queue-default-capacity :type integer)
  (max-batch-size loom-microtask-default-batch-size :type integer)
  (overflow-handler nil :type function))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Logic

(defun loom--log-overflowed-microtasks (microtask-queue overflowed-callbacks)
  "The default overflow handler, which simply logs a warning message.

This function is used as the `overflow-handler` when no custom handler is
provided during queue creation.

Arguments:
- `microtask-queue` (loom-microtask-queue): The queue that overflowed.
- `overflowed-callbacks` (list): The list of callbacks that were dropped.

Returns:
- `nil`."
  (loom-log :warn (loom-microtask-queue-lock microtask-queue)
              "Microtask queue overflow: %d callbacks dropped. (Capacity: %d)"
              (length overflowed-callbacks)
              (loom-microtask-queue-capacity microtask-queue))
  nil)

(defun loom--drain-microtask-queue (microtask-queue)
  "Process all microtasks from `MICROTASK-QUEUE` until it is empty.
This function runs synchronously and will not return until the queue is
drained. It repeatedly dequeues batches of tasks and executes them.

Arguments:
- `microtask-queue` (loom-microtask-queue): The queue to drain.

Side Effects:
- Executes the callbacks stored in the queue via the queue's `executor`.
- Modifies the queue by dequeuing all its items.
- Sets the queue's `drain-scheduled-p` flag to `nil` upon completion."
  (cl-block loom--drain-microtask-queue
    (cl-incf (loom-microtask-queue-drain-tick-counter microtask-queue))
    (let ((tick (loom-microtask-queue-drain-tick-counter microtask-queue)))
      (loom-log :debug (loom-microtask-queue-lock microtask-queue)
                  "Microtask drain tick %d starting." tick)

      (while t
        (let* ((queue (loom-microtask-queue-queue microtask-queue))
               (executor (loom-microtask-queue-executor microtask-queue))
               (max-batch (loom-microtask-queue-max-batch-size
                           microtask-queue))
               batch)
          ;; 1. Dequeue a batch of tasks under lock.
          (loom:with-mutex! (loom-microtask-queue-lock microtask-queue)
            (let ((batch-size (min (loom:queue-length queue) max-batch)))
              (setq batch (cl-loop repeat batch-size
                                   collect (loom:queue-dequeue queue)))))

          ;; 2. If the queue is empty, mark drain as complete and exit.
          (unless batch
            (loom:with-mutex! (loom-microtask-queue-lock microtask-queue)
              (setf (loom-microtask-queue-drain-scheduled-p
                     microtask-queue) nil))
            (cl-return-from loom--drain-microtask-queue nil))

          (loom-log :debug (loom-microtask-queue-lock microtask-queue)
                      "Processing %d microtasks in tick %d."
                      (length batch) tick)
          ;; 3. Execute the batch outside the lock.
          (dolist (cb batch)
            ;; A failing microtask should not stop others from running.
            (condition-case err
                (funcall executor cb)
              (error (loom-log :error
                                 (loom-microtask-queue-lock microtask-queue)
                                 "Unhandled error in microtask: %S" err)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:microtask-queue
    (&key executor
          (capacity loom-microtask-queue-default-capacity)
          (max-batch-size loom-microtask-default-batch-size)
          (overflow-handler #'loom--log-overflowed-microtasks))
  "Create and return a new `loom-microtask-queue` instance.

Arguments:
- `:executor` (function): A mandatory function `(lambda (callback))` that will
  be invoked to execute each microtask.
- `:capacity` (integer): The maximum number of microtasks the queue can hold
  before the `:overflow-handler` is called.
- `:max-batch-size` (integer): The maximum number of microtasks to process
  in each cycle of the drain loop.
- `:overflow-handler` (function, optional): A function `(lambda (queue
  overflowed-callbacks))` that is called when the queue's capacity is
  exceeded. Defaults to a function that logs a warning.

Returns:
- (loom-microtask-queue): A new, configured microtask queue.

Signals:
- `error` if `:executor` is not a function."
  (unless (functionp executor)
    (error ":executor must be a function"))
  (let ((queue (loom:queue))
        (lock (loom:lock "loom-microtask-queue-lock")))
    (%%make-microtask-queue
     :queue queue
     :lock lock
     :executor executor
     :capacity capacity
     :max-batch-size max-batch-size
     :overflow-handler overflow-handler)))

;;;###autoload
(defun loom:schedule-microtasks (microtask-queue callbacks)
  "Add a list of `CALLBACKS` to `MICROTASK-QUEUE` and trigger a drain.
If a drain is not already in progress, this function will synchronously
drain the entire queue before returning.

If the queue's capacity is exceeded, the `overflow-handler` specified
during queue creation will be invoked with the list of callbacks that
could not be enqueued.

Arguments:
- `MICROTASK-QUEUE` (loom-microtask-queue): The queue to schedule on.
- `CALLBACKS` (list): A list of callbacks to enqueue.

Returns:
- `nil`.

Signals:
- `error` if `CALLBACKS` is not a list."
  (unless (listp callbacks)
    (error "Argument must be a list of callbacks: %S" callbacks))

  (let (overflowed-rev needs-drain)
    ;; 1. Enqueue tasks and identify overflowed items under a lock.
    (loom:with-mutex! (loom-microtask-queue-lock microtask-queue)
      (let* ((capacity (loom-microtask-queue-capacity microtask-queue))
             (queue (loom-microtask-queue-queue microtask-queue)))
        (dolist (cb callbacks)
          (if (and (> capacity 0) (>= (loom:queue-length queue) capacity))
              (push cb overflowed-rev)
            (loom:queue-enqueue queue cb))))

      ;; 2. Check if a drain is needed and set the flags *inside* the lock.
      (unless (loom-microtask-queue-drain-scheduled-p microtask-queue)
        (setf (loom-microtask-queue-drain-scheduled-p microtask-queue) t)
        (setq needs-drain t)))

    ;; 3. Handle any overflowed callbacks outside the lock.
    (when overflowed-rev
      (let ((overflowed (nreverse overflowed-rev)) ; Preserve original order.
            (handler (loom-microtask-queue-overflow-handler
                      microtask-queue)))
        (condition-case err
            (funcall handler microtask-queue overflowed)
          (error
           (loom-log :error nil "Error in microtask overflow handler: %S"
                       err)))))

    ;; 4. Run the drain (if needed) *outside* the lock to prevent deadlock.
    (when needs-drain
      (loom-log :debug (loom-microtask-queue-lock microtask-queue)
                "Scheduling initial microtask drain immediately.")
      (loom--drain-microtask-queue microtask-queue))
    nil))

;;;###autoload
(defun loom:schedule-microtask (microtask-queue cb-or-fn &optional type priority data)
  "Add a single `CB-OR-FN` to `MICROTASK-QUEUE` and trigger a drain.
This is a convenience wrapper around `loom:schedule-microtasks`.

Arguments:
- `MICROTASK-QUEUE` (loom-microtask-queue): The queue to schedule on.
- `CB-OR-FN` (function or loom-callback): The task to enqueue. If a function,
  it will be wrapped in a `loom-callback` struct. If already a `loom-callback`,
  it will be used directly.
- `TYPE` (symbol, optional): The callback's type (e.g., `:deferred`).
  Only applies if `CB-OR-FN` is a function.
- `PRIORITY` (integer, optional): The callback's priority.
  Only applies if `CB-OR-FN` is a function.
- `DATA` (plist, optional): Additional data for the callback.
  Only applies if `CB-OR-FN` is a function.

Returns:
- `nil`.

Signals:
- `wrong-type-argument` if `CB-OR-FN` is neither a function nor a `loom-callback`."
  (let ((final-callback nil))
    (cond
     ((loom-callback-p cb-or-fn)
      ;; If it's already a loom-callback, use it directly.
      (setq final-callback cb-or-fn))
     ((functionp cb-or-fn)
      ;; If it's a function, create a loom-callback from it.
      (setq final-callback (loom:callback
                             cb-or-fn
                            :type (or type :deferred) 
                            :priority (or priority 0) 
                            :data data)))
     (t
      (signal 'wrong-type-argument (list 'function-or-loom-callback-p cb-or-fn))))

    ;; Schedule the single, now-guaranteed-to-be-a-loom-callback.
    (loom:schedule-microtasks microtask-queue (list final-callback))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public Drain Function

;;;###autoload
(defun loom:drain-microtask-queue (microtask-queue)
  "Synchronously drains all pending microtasks from `MICROTASK-QUEUE`.

This function is idempotent: calling it multiple times will only drain
the queue once if it's already being drained or if it's empty.

Arguments:
- `MICROTASK-QUEUE` (loom-microtask-queue): The microtask queue to drain.

Returns:
- `t` if tasks were drained, `nil` otherwise (e.g., if queue was already empty).

Side Effects:
- Executes all pending microtasks in the queue.
- Resets the `drain-scheduled-p` flag once the queue is empty."
  (interactive) 
  (let ((drained-p nil))
    (loom:with-mutex! (loom-microtask-queue-lock microtask-queue)
      (unless (loom-microtask-queue-drain-scheduled-p microtask-queue)
        (setf (loom-microtask-queue-drain-scheduled-p microtask-queue) t)
        (setq drained-p t)))

    (when drained-p
      (loom-log :debug (loom-microtask-queue-lock microtask-queue)
                  "Public drain call: Initiating microtask queue drain.")
      (loom--drain-microtask-queue microtask-queue))
    drained-p)) 

(provide 'loom-microtask)
;;; loom-microtask.el ends here