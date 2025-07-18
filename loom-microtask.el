;;; loom-microtask.el --- Microtask Queue for Loom Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides a self-scheduling microtask queue, a fundamental
;; component for ensuring the correct, asynchronous execution of promise
;; callbacks as required by the Promise/A+ specification.
;;
;; ## What is a microtask?
;;
;; A microtask is a small, high-priority piece of work that must run "as soon
;; as possible" after the current operation finishes. Crucially, it must
;; execute *before* Emacs yields to its main event loop to handle new user
;; input, timers, or other I/O. When a microtask is enqueued, this module
;; ensures the entire queue is drained synchronously within the current call
;; stack before execution continues.
;;
;; ## Why are microtasks necessary for promises?
;;
;; The Promise/A+ specification (section 2.2.4) requires that promise
;; callbacks (like those in `.then`) are never called in the same turn of
;; the event loop that settled the promise. This prevents synchronous,
;; recursive callback chains and ensures predictable behavior. The microtask
;; queue provides this "asynchronous but immediate" execution guarantee. It's
;; used for high-priority internal tasks like propagating a promise's
;; resolution to its children or signaling an `await` latch.
;;
;; This implementation is designed for robustness, featuring a configurable
;; capacity and a customizable overflow handler to gracefully manage situations
;; where the queue might grow unexpectedly large.

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
  "The microtask queue has exceeded its configured capacity."
  'loom-microtask-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-microtask-queue-default-capacity 1024
  "The default maximum number of tasks a microtask queue can hold.
If this limit is reached, newly enqueued tasks are passed to the queue's
`overflow-handler` instead of being added. This prevents unbounded memory
growth from a runaway microtask-producing loop. A capacity of 0 means the
queue will always be considered full, routing all new tasks to the handler."
  :type '(integer :min 0)
  :group 'loom)

(defcustom loom-microtask-default-batch-size 128
  "The default maximum number of microtasks to process in a single drain cycle.
The drain loop processes tasks in batches to avoid holding the lock for
an excessively long time while dequeuing if the queue is very large."
  :type '(integer :min 1)
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-microtask-queue (:constructor %%make-microtask-queue))
  "Represents a self-scheduling, synchronous microtask queue.

Fields:
- `queue` (loom-queue): The underlying FIFO queue holding the callback tasks.
- `lock` (loom-lock): A mutex to synchronize access to the queue and the
  `drain-scheduled-p` flag, ensuring thread-safe operations.
- `drain-tick-counter` (integer): A counter for drain cycles, useful for
  debugging and tracing complex asynchronous flows.
- `executor` (function): The function `(lambda (callback))` that is called
  to execute each individual microtask from the queue.
- `capacity` (integer): The maximum number of items the queue can hold.
- `max-batch-size` (integer): The maximum number of microtasks to process
  in a single cycle of the internal drain loop.
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
provided during queue creation. It serves as a basic safety net to ensure
that queue overflows are not silent failures.

Arguments:
- `microtask-queue` (loom-microtask-queue): The queue that overflowed.
- `overflowed-callbacks` (list): The list of callbacks that were dropped.

Returns: `nil`."
  (loom-log :warn (loom-microtask-queue-lock microtask-queue)
            "Microtask queue overflow: %d callbacks dropped. (Capacity: %d)"
            (length overflowed-callbacks)
            (loom-microtask-queue-capacity microtask-queue))
  nil)

(defun loom--drain-microtask-queue (microtask-queue)
  "Processes all microtasks from `MICROTASK-QUEUE` until it is empty.
This function runs synchronously and will not return until the queue is
drained. It repeatedly dequeues batches of tasks and executes them. This
is the core workhorse of the microtask system.

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

      ;; Loop until the queue is completely empty. Microtasks can enqueue
      ;; more microtasks, so we must continue until none are left.
      (while t
        (let* ((queue (loom-microtask-queue-queue microtask-queue))
               (executor (loom-microtask-queue-executor microtask-queue))
               (max-batch (loom-microtask-queue-max-batch-size microtask-queue))
               batch)
          ;; Step 1: Dequeue a batch of tasks. This is done under a lock to
          ;; ensure safe access to the queue's internal state.
          (loom:with-mutex! (loom-microtask-queue-lock microtask-queue)
            (let ((batch-size (min (loom:queue-length queue) max-batch)))
              (when (> batch-size 0)
                (setq batch (cl-loop repeat batch-size
                                     collect (loom:queue-dequeue queue))))))

          ;; Step 2: If the queue is empty, the drain is complete.
          ;; Mark it as no longer scheduled and exit the loop.
          (unless batch
            (loom:with-mutex! (loom-microtask-queue-lock microtask-queue)
              (setf (loom-microtask-queue-drain-scheduled-p microtask-queue) nil))
            (loom-log :debug (loom-microtask-queue-lock microtask-queue)
                      "Microtask drain tick %d finished, queue is empty." tick)
            (cl-return-from loom--drain-microtask-queue nil))

          (loom-log :debug (loom-microtask-queue-lock microtask-queue)
                    "Processing a batch of %d microtasks in tick %d."
                    (length batch) tick)
          ;; Step 3: Execute the batch of tasks *outside* the lock. This is
          ;; crucial to prevent deadlocks if a callback tries to acquire a lock.
          (dolist (cb batch)
            ;; A failing microtask should not stop others in the batch from running.
            (condition-case err
                (funcall executor cb)
              (error (loom-log :error
                               (loom-microtask-queue-lock microtask-queue)
                               "Unhandled error in microtask executor: %S" err)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:microtask-queue
    (&key executor
          (capacity loom-microtask-queue-default-capacity)
          (max-batch-size loom-microtask-default-batch-size)
          (overflow-handler #'loom--log-overflowed-microtasks))
  "Creates and returns a new `loom-microtask-queue` instance.

Arguments:
- `:executor` (function): A mandatory function `(lambda (callback))` that will
  be invoked to execute each microtask.
- `:capacity` (integer): The max number of tasks the queue can hold before
  the `:overflow-handler` is called.
- `:max-batch-size` (integer): The max number of tasks to process in each
  cycle of the drain loop.
- `:overflow-handler` (function, optional): A function of two arguments,
  `(lambda (queue overflowed-callbacks))`, called when capacity is exceeded.
  Defaults to a handler that logs a warning.

Returns: A new, configured `loom-microtask-queue` instance.
Signals: `error` if `:executor` is not a function."
  (unless (functionp executor)
    (error ":executor argument must be a function"))
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
(defun loom:microtask-enqueue (microtask-queue callback)
  "Adds a `CALLBACK` to `MICROTASK-QUEUE` and triggers a synchronous drain.

If a drain operation is not already in progress, this function will
synchronously drain the *entire* queue before returning. This ensures the
\"run-to-completion\" semantics of microtasks.

If the queue's capacity is exceeded, the configured `overflow-handler` will
be invoked with a list containing the rejected `CALLBACK`.

Arguments:
- `MICROTASK-QUEUE` (loom-microtask-queue): The queue to schedule on.
- `CALLBACK` (loom-callback): The single callback to enqueue.

Returns: `nil`.
Signals: `error` if `CALLBACK` is not a `loom-callback`."
  (unless (loom-callback-p callback)
    (error "Argument must be a loom-callback struct, but got: %S" callback))

  (let (overflowed-rev needs-drain)
    ;; Step 1: Enqueue the task under a lock.
    ;; We check for overflow here and collect any tasks that don't fit.
    (loom:with-mutex! (loom-microtask-queue-lock microtask-queue)
      (let* ((capacity (loom-microtask-queue-capacity microtask-queue))
             (queue (loom-microtask-queue-queue microtask-queue)))
        (if (and (> capacity 0) (>= (loom:queue-length queue) capacity))
            (push callback overflowed-rev)
          (loom:queue-enqueue queue callback))))

    ;; Step 2: Check if a drain needs to be started. This is done in a
    ;; separate lock acquisition to minimize hold time. The `drain-scheduled-p`
    ;; flag prevents recursive drains.
    (loom:with-mutex! (loom-microtask-queue-lock microtask-queue)
      (unless (loom-microtask-queue-drain-scheduled-p microtask-queue)
        (setf (loom-microtask-queue-drain-scheduled-p microtask-queue) t)
        (setq needs-drain t)))

    ;; Step 3: Handle any overflowed callbacks outside the lock.
    (when overflowed-rev
      (let ((overflowed (nreverse overflowed-rev)) ; Preserve original order.
            (handler (loom-microtask-queue-overflow-handler microtask-queue)))
        (condition-case err
            (funcall handler microtask-queue overflowed)
          (error
           (loom-log :error nil
                     "Error occurred within custom microtask overflow handler: %S"
                     err)))))

    ;; Step 4: Run the drain if we are responsible for starting it.
    ;; This is done *outside* the lock to prevent deadlocks.
    (when needs-drain
      (loom-log :debug (loom-microtask-queue-lock microtask-queue)
                "Enqueue triggered an immediate, synchronous microtask drain.")
      (loom--drain-microtask-queue microtask-queue))
    nil))

;;;###autoload
(defun loom:microtask-drain (microtask-queue)
  "Synchronously drains all pending microtasks from `MICROTASK-QUEUE`.

This function is idempotent due to the internal `drain-scheduled-p` flag.
Calling it multiple times while a drain is in progress will have no
additional effect. This is the public entry point for explicitly flushing
the microtask queue, often used by the main scheduler tick.

Arguments:
- `MICROTASK-QUEUE` (loom-microtask-queue): The queue to drain.

Returns: `t` if a new drain was initiated, `nil` otherwise (if a drain was
  already in progress or the queue was empty).

Side Effects: Executes all pending microtasks in the queue."
  (interactive)
  (let ((initiated-drain-p nil))
    ;; Atomically check and set the drain flag.
    (loom:with-mutex! (loom-microtask-queue-lock microtask-queue)
      (unless (or (loom-microtask-queue-drain-scheduled-p microtask-queue)
                  (loom:queue-empty-p (loom-microtask-queue-queue microtask-queue)))
        (setf (loom-microtask-queue-drain-scheduled-p microtask-queue) t)
        (setq initiated-drain-p t)))

    ;; If we were the ones to start the drain, run the drain loop.
    (when initiated-drain-p
      (loom-log :debug (loom-microtask-queue-lock microtask-queue)
                "Explicit call to `loom:microtask-drain` initiated a drain.")
      (loom--drain-microtask-queue microtask-queue))
    initiated-drain-p))

;;;###autoload
(defun loom:microtask-status (microtask-queue)
  "Returns a snapshot of the `MICROTASK-QUEUE`'s current status.
This is useful for debugging and introspection.

Arguments:
- `MICROTASK-QUEUE` (loom-microtask-queue): The queue to inspect.

Returns:
- (plist): A property list containing metrics about the queue, such as
  `:queue-length`, `:drain-scheduled-p`, `:capacity`, etc.

Signals: `error` if argument is not a `loom-microtask-queue`."
  (unless (loom-microtask-queue-p microtask-queue)
    (error "Argument must be a loom-microtask-queue, but got: %S"
           microtask-queue))
  (loom:with-mutex! (loom-microtask-queue-lock microtask-queue)
    `(:queue-length ,(loom:queue-length (loom-microtask-queue-queue microtask-queue))
      :drain-scheduled-p ,(loom-microtask-queue-drain-scheduled-p microtask-queue)
      :drain-tick-counter ,(loom-microtask-queue-drain-tick-counter microtask-queue)
      :capacity ,(loom-microtask-queue-capacity microtask-queue)
      :max-batch-size ,(loom-microtask-queue-max-batch-size microtask-queue))))

(provide 'loom-microtask)
;;; loom-microtask.el ends here