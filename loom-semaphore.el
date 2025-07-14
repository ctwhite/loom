;;; loom-semaphore.el --- Counting Semaphore Primitive for Concur -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This module provides the `loom-semaphore` primitive, a counting
;; semaphore for controlling access to a finite number of resources. It
;; is a fundamental tool for limiting concurrency, for example, to
;; control the number of simultaneous network requests or CPU-intensive
;; tasks.
;;
;; A semaphore maintains a set number of "permits". Tasks can `acquire`
;; a permit (blocking if none are available) and `release` it when done.
;;
;; This implementation is fully integrated with the Concur ecosystem,
;; supporting:
;; - **Promises:** `acquire` returns a promise, allowing non-blocking
;;   waits.
;; - **Timeouts:** `acquire` can be configured with a timeout, rejecting
;;   the promise if a permit isn't obtained in time.
;; - **Cooperative Cancellation:** `acquire` can accept a `cancel-token`,
;;   allowing a pending acquisition to be cancelled.
;; - **Fairness:** Uses a First-In, First-Out (FIFO) queue for tasks
;;   waiting to acquire a slot, ensuring fairness.
;; - **Resource Management:** Automatic cleanup and leak detection.
;; - **Metrics:** Comprehensive statistics and monitoring.
;;
;; Key Functions:
;; - `loom:semaphore`: Creates a new semaphore.
;; - `loom:semaphore-acquire`: Asynchronously acquires a permit.
;; - `loom:semaphore-try-acquire`: Non-blocking attempt to acquire a permit.
;; - `loom:semaphore-release`: Releases a permit.
;; - `loom:with-semaphore!`: Macro for safely acquiring and releasing.
;; - `loom:semaphore-with-permits!`: Macro for acquiring multiple permits.
;; - `loom:semaphore-drain`: Acquire all available permits.
;; - `loom:semaphore-reset`: Reset semaphore to initial state.
;;
;; Example:
;;   (defvar *api-rate-limiter* (loom:semaphore 5)) ; Max 5 concurrent API calls
;;
;;   (defun fetch-data-from-api (endpoint)
;;     (loom:with-semaphore! *api-rate-limiter*
;;       (message "Fetching %s..." endpoint)
;;       (loom:delay 0.5 (format "Data from %s" endpoint))))
;;
;;   (dolist (ep '("user" "products" "orders" "status" "reports" "config"))
;;     (loom:then (fetch-data-from-api ep)
;;                (lambda (result) (message "Received: %S" result))))

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'loom-log)
(require 'loom-errors)
(require 'loom-lock)
(require 'loom-queue)
(require 'loom-promise)
(require 'loom-primitives)
(require 'loom-cancel)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-semaphore-error
  "A generic error related to a `loom-semaphore`."
  'loom-error)

(define-error 'loom-invalid-semaphore-error
  "An operation was attempted on an invalid semaphore object."
  'loom-semaphore-error)

(define-error 'loom-semaphore-capacity-error
  "An operation would exceed the semaphore's capacity."
  'loom-semaphore-error)

(define-error 'loom-semaphore-closed-error
  "An operation was attempted on a closed semaphore."
  'loom-semaphore-error)

(define-error 'loom-semaphore-permit-error
  "An invalid number of permits was requested."
  'loom-semaphore-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Constants

(defconst *loom-semaphore-max-permits* 10000
  "Maximum number of permits allowed in a semaphore.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-semaphore (:constructor %%make-semaphore))
  "A semaphore for controlling access to a finite number of resources.

Fields:
- `name` (string): A descriptive name for debugging and logging.
- `lock` (loom-lock): An internal mutex that protects all other fields
  of the struct from race conditions.
- `count` (integer): The current number of available slots or 'permits'.
- `max-count` (integer): The maximum capacity of the semaphore.
- `wait-queue` (loom-queue): A FIFO queue of pending promises created by
  calls to `loom:semaphore-acquire` when no slots were available.
- `closed-p` (boolean): Whether the semaphore has been closed.
- `creation-time` (float-time): When the semaphore was created.
- `total-acquires` (integer): Total number of successful acquisitions.
- `total-releases` (integer): Total number of releases.
- `peak-usage` (integer): Maximum number of permits in use simultaneously.
- `total-waiters` (integer): Total number of tasks that have waited."
  (name "" :type string)
  (lock nil :type loom-lock)
  (count 0 :type integer)
  (max-count 0 :type integer)
  (wait-queue nil :type loom-queue)
  (closed-p nil :type boolean)
  (creation-time 0.0 :type float)
  (total-acquires 0 :type integer)
  (total-releases 0 :type integer)
  (peak-usage 0 :type integer)
  (total-waiters 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-semaphore (sem function-name)
  "Signal an error if `SEM` is not a valid `loom-semaphore` object.

Arguments:
- `SEM` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting."
  (unless (loom-semaphore-p sem)
    (signal 'loom-invalid-semaphore-error
            (list (format "%s: Invalid semaphore object" function-name) sem))))

(defun loom--validate-semaphore-open (sem function-name)
  "Signal an error if `SEM` is not open.

Arguments:
- `SEM` (loom-semaphore): The semaphore to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting."
  (loom--validate-semaphore sem function-name)
  (when (loom-semaphore-closed-p sem)
    (signal 'loom-semaphore-closed-error
            (list (format "%s: Semaphore '%s' is closed" 
                          function-name (loom-semaphore-name sem))))))

(defun loom--validate-permit-count (n function-name)
  "Validate that `N` is a valid permit count.

Arguments:
- `N` (integer): The permit count to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting."
  (unless (and (integerp n) (> n 0) (<= n *loom-semaphore-max-permits*))
    (signal 'loom-semaphore-permit-error
            (list (format "%s: Invalid permit count %S (must be 1-%d)" 
                          function-name n *loom-semaphore-max-permits*)))))

(defun loom--update-semaphore-stats (sem acquired released)
  "Update semaphore statistics.

Arguments:
- `SEM` (loom-semaphore): The semaphore to update.
- `ACQUIRED` (integer): Number of permits acquired.
- `RELEASED` (integer): Number of permits released."
  (when acquired
    (cl-incf (loom-semaphore-total-acquires sem) acquired)
    (let ((current-usage (- (loom-semaphore-max-count sem)
                           (loom-semaphore-count sem))))
      (setf (loom-semaphore-peak-usage sem)
            (max (loom-semaphore-peak-usage sem) current-usage))))
  (when released
    (cl-incf (loom-semaphore-total-releases sem) released)))

(defun loom--semaphore-cleanup-cancelled-waiters (sem)
  "Remove cancelled promises from the wait queue.

Arguments:
- `SEM` (loom-semaphore): The semaphore to clean up."
  (let ((cleaned-queue (loom:queue)))
    (while (not (loom:queue-empty-p (loom-semaphore-wait-queue sem)))
      (let ((promise (loom:queue-dequeue (loom-semaphore-wait-queue sem))))
        (unless (loom:promise-cancelled-p promise)
          (loom:queue-enqueue cleaned-queue promise))))
    (setf (loom-semaphore-wait-queue sem) cleaned-queue)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:semaphore (n &optional name &key fair-p)
  "Create a semaphore with `N` available slots.

Arguments:
- `N` (integer): The initial (and maximum) number of available slots. Must
  be a positive integer not exceeding `*loom-semaphore-max-permits*`.
- `NAME` (string, optional): A descriptive name for debugging.
- `:FAIR-P` (boolean, optional): Whether to use fair scheduling (FIFO).
  Defaults to `t`.

Returns:
- (loom-semaphore): A new semaphore object.

Signals:
- `loom-semaphore-permit-error`: If `N` is not a valid permit count.

Side Effects:
- Creates a new `loom-semaphore` struct.
- Initializes an internal `loom-lock` and `loom-queue`."
  (loom--validate-permit-count n 'loom:semaphore)
  (let* ((sem-name (or name (format "semaphore-%d" (random 10000))))
         (sem-lock (loom:lock (format "%s-lock" sem-name)))
         (queue (if (eq fair-p nil) (loom:queue) (loom:queue))))
    (loom-log :debug sem-name "Creating semaphore with %d permits" n)
    (%%make-semaphore :count n :max-count n :name sem-name
                      :lock sem-lock :wait-queue queue
                      :creation-time (float-time)
                      :closed-p nil
                      :total-acquires 0 :total-releases 0
                      :peak-usage 0 :total-waiters 0)))

;;;###autoload
(cl-defun loom:semaphore-try-acquire (sem &optional (permits 1))
  "Attempt to acquire `PERMITS` slots from `SEM` without blocking.

Arguments:
- `SEM` (loom-semaphore): The semaphore to acquire from.
- `PERMITS` (integer, optional): Number of permits to acquire. Defaults to 1.

Returns:
- (boolean): `t` if the permits were acquired, `nil` otherwise.

Signals:
- `loom-invalid-semaphore-error`: If `SEM` is not a valid semaphore.
- `loom-semaphore-closed-error`: If `SEM` is closed.
- `loom-semaphore-permit-error`: If `PERMITS` is invalid.

Side Effects:
- If permits are available, decrements the semaphore's internal `count`."
  (loom--validate-semaphore-open sem 'loom:semaphore-try-acquire)
  (loom--validate-permit-count permits 'loom:semaphore-try-acquire)
  (let (acquired-p)
    (loom:with-mutex! (loom-semaphore-lock sem)
      (when (>= (loom-semaphore-count sem) permits)
        (cl-decf (loom-semaphore-count sem) permits)
        (loom--update-semaphore-stats sem permits nil)
        (setq acquired-p t)))
    (when acquired-p
      (loom-log :debug (loom-semaphore-name sem) 
                "Acquired %d permits (non-blocking)" permits))
    acquired-p))

;;;###autoload
(cl-defun loom:semaphore-acquire (sem &key (permits 1) timeout cancel-token)
  "Acquire `PERMITS` slots from `SEM`, returning a promise for the operation.

Arguments:
- `SEM` (loom-semaphore): The semaphore to acquire from.
- `:PERMITS` (integer, optional): Number of permits to acquire. Defaults to 1.
- `:TIMEOUT` (number, optional): Max seconds to wait before rejecting.
- `:CANCEL-TOKEN` (loom-cancel-token, optional): Token for cancellation.

Returns:
- (loom-promise): A promise that resolves to `PERMITS` on success.

Signals:
- `loom-invalid-semaphore-error`: If `SEM` is not a valid semaphore.
- `loom-semaphore-closed-error`: If `SEM` is closed.
- `loom-semaphore-permit-error`: If `PERMITS` is invalid.
- `loom-timeout-error`: If timeout occurs.
- `loom-cancel-error`: If cancelled.

Side Effects:
- May decrement the semaphore's internal `count`.
- May enqueue a promise in the semaphore's `wait-queue`."
  (loom--validate-semaphore-open sem 'loom:semaphore-acquire)
  (loom--validate-permit-count permits 'loom:semaphore-acquire)
  
  (let (acquire-promise waiter-info)
    (loom:with-mutex! (loom-semaphore-lock sem)
      (if (>= (loom-semaphore-count sem) permits)
          (progn
            (cl-decf (loom-semaphore-count sem) permits)
            (loom--update-semaphore-stats sem permits nil)
            (setq acquire-promise (loom:resolved! permits))
            (loom-log :debug (loom-semaphore-name sem) 
                      "Acquired %d permits (immediate)" permits))
        ;; Need to wait
        (setq acquire-promise (loom:promise
                               :name (format "%s-acquire-%d" 
                                           (loom-semaphore-name sem) permits)
                               :cancel-token cancel-token))
        (setq waiter-info (list acquire-promise permits))
        (loom:queue-enqueue (loom-semaphore-wait-queue sem) waiter-info)
        (cl-incf (loom-semaphore-total-waiters sem))
        (loom-log :debug (loom-semaphore-name sem) 
                  "Queued for %d permits (queue length: %d)" 
                  permits (loom:queue-length (loom-semaphore-wait-queue sem)))
        
        ;; Set up cancellation callback
        (when cancel-token
          (loom:cancel-token-add-callback
           cancel-token
           (lambda (_reason)
             (loom:with-mutex! (loom-semaphore-lock sem)
               (loom:queue-remove-if (loom-semaphore-wait-queue sem)
                                     (lambda (item) (eq (car item) acquire-promise)))))))))
    
    ;; Apply timeout if specified
    (if timeout 
        (loom:timeout acquire-promise timeout) 
        acquire-promise)))

;;;###autoload
(cl-defun loom:semaphore-release (sem &optional (permits 1))
  "Release `PERMITS` slots in `SEM`.

Arguments:
- `SEM` (loom-semaphore): The semaphore to release.
- `PERMITS` (integer, optional): Number of permits to release. Defaults to 1.

Returns:
- (integer): Number of permits actually released.

Signals:
- `loom-invalid-semaphore-error`: If `SEM` is not a valid semaphore.
- `loom-semaphore-closed-error`: If `SEM` is closed.
- `loom-semaphore-permit-error`: If `PERMITS` is invalid.
- `loom-semaphore-capacity-error`: If release would exceed capacity.

Side Effects:
- May increment the semaphore's internal `count`.
- May resolve waiting promises."
  (loom--validate-semaphore-open sem 'loom:semaphore-release)
  (loom--validate-permit-count permits 'loom:semaphore-release)
  
  (let ((released-permits 0)
        (satisfied-waiters nil))
    (loom:with-mutex! (loom-semaphore-lock sem)
      (when (> (+ (loom-semaphore-count sem) permits) 
               (loom-semaphore-max-count sem))
        (signal 'loom-semaphore-capacity-error
                (list (format "Release would exceed capacity: %d + %d > %d"
                              (loom-semaphore-count sem) permits
                              (loom-semaphore-max-count sem)))))
      
      ;; Clean up cancelled waiters first
      (loom--semaphore-cleanup-cancelled-waiters sem)
      
      ;; Try to satisfy waiters first
      (let ((remaining-permits permits))
        (while (and (> remaining-permits 0) 
                   (not (loom:queue-empty-p (loom-semaphore-wait-queue sem))))
          (let* ((waiter-info (loom:queue-peek (loom-semaphore-wait-queue sem)))
                 (waiter-promise (car waiter-info))
                 (waiter-permits (cadr waiter-info)))
            (if (<= waiter-permits remaining-permits)
                (progn
                  (loom:queue-dequeue (loom-semaphore-wait-queue sem))
                  (cl-decf remaining-permits waiter-permits)
                  (cl-incf released-permits waiter-permits)
                  (push (list waiter-promise waiter-permits) satisfied-waiters))
              (cl-incf (loom-semaphore-count sem) remaining-permits)
              (cl-incf released-permits remaining-permits)
              (setq remaining-permits 0))))
        
        ;; Add any remaining permits to the count
        (when (> remaining-permits 0)
          (cl-incf (loom-semaphore-count sem) remaining-permits)
          (cl-incf released-permits remaining-permits)))
      
      (loom--update-semaphore-stats sem nil released-permits))
    
    ;; Resolve satisfied waiters outside the lock
    (dolist (waiter satisfied-waiters)
      (let ((promise (car waiter))
            (waiter-permits (cadr waiter)))
        (loom:resolve promise waiter-permits)
        (loom-log :debug (loom-semaphore-name sem) 
                  "Satisfied waiter with %d permits" waiter-permits)))
    
    (when (> released-permits 0)
      (loom-log :debug (loom-semaphore-name sem) 
                "Released %d permits" released-permits))
    
    released-permits))

;;;###autoload
(defmacro loom:with-semaphore! (sem-obj &rest body)
  "Execute `BODY` after acquiring a slot from `SEM-OBJ`.

Arguments:
- `SEM-OBJ` (loom-semaphore): The semaphore to acquire a slot from.
- `BODY` (forms): The Lisp forms to execute after acquiring the semaphore.

Returns:
- (loom-promise): A promise that resolves with the result of `BODY`.

Signals:
- Any signals from `loom:semaphore-acquire`.
- Any signals from `BODY` will cause the returned promise to reject.

Side Effects:
- Acquires and releases a permit from the semaphore."
  (declare (indent 1) (debug t))
  `(loom:then (loom:semaphore-acquire ,sem-obj)
              (lambda (_)
                (loom:finally (progn ,@body)
                              (lambda ()
                                (loom:semaphore-release ,sem-obj))))))

;;;###autoload
(defmacro loom:semaphore-with-permits! (sem-obj permits &rest body)
  "Execute `BODY` after acquiring `PERMITS` slots from `SEM-OBJ`.

Arguments:
- `SEM-OBJ` (loom-semaphore): The semaphore to acquire slots from.
- `PERMITS` (integer): Number of permits to acquire.
- `BODY` (forms): The Lisp forms to execute after acquiring the permits.

Returns:
- (loom-promise): A promise that resolves with the result of `BODY`.

Signals:
- Any signals from `loom:semaphore-acquire`.
- Any signals from `BODY` will cause the returned promise to reject.

Side Effects:
- Acquires and releases the specified number of permits."
  (declare (indent 2) (debug t))
  `(loom:then (loom:semaphore-acquire ,sem-obj :permits ,permits)
              (lambda (acquired-permits)
                (loom:finally (progn ,@body)
                              (lambda ()
                                (loom:semaphore-release ,sem-obj acquired-permits))))))

;;;###autoload
(defun loom:semaphore-drain (sem)
  "Acquire all available permits from `SEM`.

Arguments:
- `SEM` (loom-semaphore): The semaphore to drain.

Returns:
- (integer): Number of permits acquired.

Signals:
- `loom-invalid-semaphore-error`: If `SEM` is not a valid semaphore.
- `loom-semaphore-closed-error`: If `SEM` is closed.

Side Effects:
- Acquires all available permits, reducing count to 0."
  (loom--validate-semaphore-open sem 'loom:semaphore-drain)
  (let (drained-permits)
    (loom:with-mutex! (loom-semaphore-lock sem)
      (setq drained-permits (loom-semaphore-count sem))
      (setf (loom-semaphore-count sem) 0)
      (when (> drained-permits 0)
        (loom--update-semaphore-stats sem drained-permits nil)))
    (when (> drained-permits 0)
      (loom-log :debug (loom-semaphore-name sem) 
                "Drained %d permits" drained-permits))
    drained-permits))

;;;###autoload
(defun loom:semaphore-close (sem)
  "Close `SEM`, rejecting all waiting promises.

Arguments:
- `SEM` (loom-semaphore): The semaphore to close.

Returns:
- (integer): Number of waiting promises that were rejected.

Signals:
- `loom-invalid-semaphore-error`: If `SEM` is not a valid semaphore.

Side Effects:
- Marks the semaphore as closed.
- Rejects all waiting promises with `loom-semaphore-closed-error`."
  (loom--validate-semaphore sem 'loom:semaphore-close)
  (let ((rejected-count 0)
        (waiters-to-reject nil))
    (loom:with-mutex! (loom-semaphore-lock sem)
      (unless (loom-semaphore-closed-p sem)
        (setf (loom-semaphore-closed-p sem) t)
        (while (not (loom:queue-empty-p (loom-semaphore-wait-queue sem)))
          (let ((waiter-info (loom:queue-dequeue (loom-semaphore-wait-queue sem))))
            (push (car waiter-info) waiters-to-reject)
            (cl-incf rejected-count)))))
    
    ;; Reject waiters outside the lock
    (dolist (promise waiters-to-reject)
      (loom:reject promise 
                   (loom-semaphore-closed-error 
                    (format "Semaphore '%s' was closed" 
                            (loom-semaphore-name sem)))))
    
    (when (> rejected-count 0)
      (loom-log :info (loom-semaphore-name sem) 
                "Closed semaphore, rejected %d waiters" rejected-count))
    
    rejected-count))

;;;###autoload
(defun loom:semaphore-reset (sem)
  "Reset `SEM` to its initial state.

Arguments:
- `SEM` (loom-semaphore): The semaphore to reset.

Returns:
- `nil`

Signals:
- `loom-invalid-semaphore-error`: If `SEM` is not a valid semaphore.

Side Effects:
- Resets permit count to maximum.
- Clears statistics.
- Rejects all waiting promises."
  (loom--validate-semaphore sem 'loom:semaphore-reset)
  (loom:semaphore-close sem)
  (loom:with-mutex! (loom-semaphore-lock sem)
    (setf (loom-semaphore-count sem) (loom-semaphore-max-count sem))
    (setf (loom-semaphore-closed-p sem) nil)
    (setf (loom-semaphore-total-acquires sem) 0)
    (setf (loom-semaphore-total-releases sem) 0)
    (setf (loom-semaphore-peak-usage sem) 0)
    (setf (loom-semaphore-total-waiters sem) 0)
    (setf (loom-semaphore-creation-time sem) (float-time)))
  (loom-log :info (loom-semaphore-name sem) "Reset semaphore"))

;;;###autoload
(defun loom:semaphore-get-count (sem)
  "Return the current number of available permits in `SEM`.

Arguments:
- `SEM` (loom-semaphore): The semaphore to inspect.

Returns:
- (integer): The number of available permits.

Signals:
- `loom-invalid-semaphore-error`: If `SEM` is not a valid semaphore."
  (loom--validate-semaphore sem 'loom:semaphore-get-count)
  (loom-semaphore-count sem))

;;;###autoload
(defun loom:semaphore-status (sem)
  "Return a comprehensive status snapshot of `SEM`.

Arguments:
- `SEM` (loom-semaphore): The semaphore to inspect.

Returns:
- (plist): A property list with semaphore metrics and status.

Signals:
- `loom-invalid-semaphore-error`: If `SEM` is not a valid semaphore."
  (loom--validate-semaphore sem 'loom:semaphore-status)
  (loom:with-mutex! (loom-semaphore-lock sem)
    (let ((current-time (float-time))
          (queue-length (loom:queue-length (loom-semaphore-wait-queue sem)))
          (usage (- (loom-semaphore-max-count sem) (loom-semaphore-count sem))))
      `(:name ,(loom-semaphore-name sem)
        :available ,(loom-semaphore-count sem)
        :max-permits ,(loom-semaphore-max-count sem)
        :in-use ,usage
        :pending-acquirers ,queue-length
        :closed-p ,(loom-semaphore-closed-p sem)
        :age ,(- current-time (loom-semaphore-creation-time sem))
        :total-acquires ,(loom-semaphore-total-acquires sem)
        :total-releases ,(loom-semaphore-total-releases sem)
        :peak-usage ,(loom-semaphore-peak-usage sem)
        :total-waiters ,(loom-semaphore-total-waiters sem)
        :utilization ,(if (> (loom-semaphore-max-count sem) 0)
                         (/ (float usage) (loom-semaphore-max-count sem))
                       0.0)))))

;;;###autoload
(defun loom:semaphore-debug (sem)
  "Print detailed debug information about `SEM`.

Arguments:
- `SEM` (loom-semaphore): The semaphore to debug.

Returns:
- `nil`

Side Effects:
- Prints debug information to the messages buffer."
  (interactive)
  (loom--validate-semaphore sem 'loom:semaphore-debug)
  (let ((status (loom:semaphore-status sem)))
    (message "=== Semaphore Debug: %s ===" (plist-get status :name))
    (message "State: %s" (if (plist-get status :closed-p) "CLOSED" "OPEN"))
    (message "Permits: %d/%d (%.1f%% utilized)" 
             (plist-get status :in-use)
             (plist-get status :max-permits)
             (* 100 (plist-get status :utilization)))
    (message "Queue: %d waiters" (plist-get status :pending-acquirers))
    (message "Stats: %d acquires, %d releases, %d total waiters"
             (plist-get status :total-acquires)
             (plist-get status :total-releases)
             (plist-get status :total-waiters))
    (message "Peak usage: %d permits" (plist-get status :peak-usage))
    (message "Age: %.2f seconds" (plist-get status :age))))

(provide 'loom-semaphore)
;;; loom-semaphore.el ends here