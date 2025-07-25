;;; loom-semaphore.el --- Counting Semaphore Primitive for Concur -*- lexical-binding: t; -*-

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
;; - **Automatic Cleanup:** All created semaphores are tracked and
;;   automatically closed on Emacs shutdown.
;; - **Metrics:** Comprehensive statistics and monitoring.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'loom-log)
(require 'loom-error)
(require 'loom-lock)
(require 'loom-queue)
(require 'loom-promise)
(require 'loom-primitives)
(require 'loom-cancel)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom:timeout "loom-combinators")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom--all-semaphores '()
  "A list of all active `loom-semaphore` instances.
This list is used by the shutdown hook to ensure all semaphores
are properly cleaned up when Emacs exits.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Constants

(defconst *loom-semaphore-max-permits* 10000
  "Maximum number of permits allowed in a semaphore.
This constant defines an upper bound to prevent accidental allocation
of excessively large or resource-intensive semaphores.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-semaphore (:constructor %%make-semaphore))
  "A semaphore for controlling access to a finite number of resources.
This struct encapsulates all state for a semaphore, including the
current permit count, the maximum capacity, and a queue for tasks
waiting to acquire a permit. All fields are protected by an
internal mutex to ensure thread-safety.

Fields:
- `name` (string): A descriptive name for debugging and logging.
- `lock` (loom-lock): An internal mutex protecting all other fields.
- `count` (integer): The current number of available permits.
- `max-count` (integer): The maximum capacity of the semaphore.
- `wait-queue` (loom-queue): A FIFO queue of `loom-semaphore-waiter` structs.
- `closed-p` (boolean): Whether the semaphore has been closed.
- `stats` (hash-table): A table holding performance metrics."
  (name "" :type string)
  (lock nil :type loom-lock)
  (count 0 :type integer)
  (max-count 0 :type integer)
  (wait-queue nil :type loom-queue)
  (closed-p nil :type boolean)
  (stats (make-hash-table :test 'eq) :type hash-table))

(cl-defstruct (loom-semaphore-waiter (:constructor %%make-semaphore-waiter))
  "Internal struct representing a task waiting for semaphore permits.
When a call to `loom:semaphore-acquire` cannot be satisfied
immediately, a `waiter` struct is created and enqueued. This
struct links the number of permits requested with the promise that
should be resolved once those permits become available.

Fields:
- `promise` (loom-promise): The promise returned by `loom:semaphore-acquire`.
- `permits` (integer): The number of permits this waiter needs."
  (promise nil :type (satisfies loom-promise-p))
  (permits 1 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-semaphore (sem function-name)
  "Signal an error if `SEM` is not a valid `loom-semaphore` object.

Arguments:
- `SEM` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting.

Returns: `nil`.

Signals: `loom-invalid-semaphore-error`."
  (unless (loom-semaphore-p sem)
    (loom:log! :error function-name "Invalid semaphore object: %S" sem)
    (signal 'loom-invalid-semaphore-error
            (list (format "%s: Invalid semaphore object" function-name) sem))))

(defun loom--validate-semaphore-open (sem function-name)
  "Signal an error if `SEM` is not open.

Arguments:
- `SEM` (loom-semaphore): The semaphore to validate.
- `FUNCTION-NAME` (symbol): The calling function's name.

Returns: `nil`.

Signals: `loom-semaphore-closed-error`."
  (loom--validate-semaphore sem function-name)
  (when (loom-semaphore-closed-p sem)
    (loom:log! :warn function-name "Semaphore '%s' is closed."
              (loom-semaphore-name sem))
    (signal 'loom-semaphore-closed-error
            (list (format "%s: Semaphore '%s' is closed"
                          function-name (loom-semaphore-name sem))))))

(defun loom--validate-permit-count (n function-name)
  "Validate that `N` is a valid permit count.

Arguments:
- `N` (integer): The permit count to validate.
- `FUNCTION-NAME` (symbol): The calling function's name.

Returns: `nil`.

Signals: `loom-semaphore-permit-error`."
  (unless (and (integerp n) (> n 0) (<= n *loom-semaphore-max-permits*))
    (loom:log! :error function-name "Invalid permit count %S" n)
    (signal 'loom-semaphore-permit-error
            (list (format "%s: Invalid permit count %S (must be 1-%d)"
                          function-name n *loom-semaphore-max-permits*)))))

(defun loom--update-semaphore-stats (sem acquired released)
  "Update semaphore statistics inside a lock.

Arguments:
- `SEM` (loom-semaphore): The semaphore to update.
- `ACQUIRED` (integer or nil): Number of permits acquired.
- `RELEASED` (integer or nil): Number of permits released.

Returns: `nil`.

Side Effects: Modifies the `stats` hash-table of `SEM`."
  (let ((stats (loom-semaphore-stats sem)))
    (when acquired
      (puthash :total-acquires (1+ (gethash :total-acquires stats 0)) stats)
      (let ((current-usage (- (loom-semaphore-max-count sem)
                               (loom-semaphore-count sem))))
        (puthash :peak-usage (max (gethash :peak-usage stats 0) current-usage)
                 stats)))
    (when released
      (puthash :total-releases (1+ (gethash :total-releases stats 0)) stats))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom:semaphore (n &optional name)
  "Create a semaphore with `N` available slots.

Arguments:
- `N` (integer): The initial (and maximum) number of available slots.
- `NAME` (string, optional): A descriptive name for debugging.

Returns:
A new `loom-semaphore` object.

Side Effects:
- Adds the new semaphore to a global tracking list for automatic
  cleanup on Emacs shutdown.

Signals:
- `loom-semaphore-permit-error`: If `N` is not a valid permit count."
  (loom--validate-permit-count n 'loom:semaphore)
  (let* ((sem-name (or name (format "semaphore-%d" (random 10000))))
         (sem (%%make-semaphore :count n :max-count n :name sem-name
                                :lock (loom:lock (format "%s-lock" sem-name))
                                :wait-queue (loom:queue))))
    (puthash :creation-time (float-time) (loom-semaphore-stats sem))
    ;; Track the new semaphore for automatic cleanup.
    (push sem loom--all-semaphores)
    (loom:log! :info sem-name "Created semaphore with %d permits." n)
    sem))

;;;###autoload
(cl-defun loom:semaphore-try-acquire (sem &optional (permits 1))
  "Attempt to acquire `PERMITS` slots from `SEM` without blocking.

Arguments:
- `SEM` (loom-semaphore): The semaphore to acquire from.
- `PERMITS` (integer, optional): Number of permits to acquire. Defaults to 1.

Returns:
`t` if the permits were acquired, `nil` otherwise.

Side Effects:
- If successful, decrements the semaphore's internal `count` and updates stats.

Signals:
- `loom-invalid-semaphore-error`, `loom-semaphore-closed-error`,
  `loom-semaphore-permit-error`."
  (loom--validate-semaphore-open sem 'loom:semaphore-try-acquire)
  (loom--validate-permit-count permits 'loom:semaphore-try-acquire)
  (let (acquired-p)
    (loom:with-mutex! (loom-semaphore-lock sem)
      (when (>= (loom-semaphore-count sem) permits)
        (cl-decf (loom-semaphore-count sem) permits)
        (loom--update-semaphore-stats sem permits nil)
        (setq acquired-p t)))
    (if acquired-p
        (loom:log! :debug (loom-semaphore-name sem)
                  "Acquired %d permits (non-blocking)." permits)
      (loom:log! :debug (loom-semaphore-name sem)
                "Failed to acquire %d permits (non-blocking), %d available."
                permits (loom-semaphore-count sem)))
    acquired-p))

;;;###autoload
(cl-defun loom:semaphore-acquire (sem &key (permits 1) timeout cancel-token)
  "Acquire `PERMITS` slots from `SEM`, returning a promise for the operation.
If permits are not immediately available, this function enqueues a
waiter and returns a pending promise that will be resolved when
the permits are eventually acquired.

Arguments:
- `SEM` (loom-semaphore): The semaphore to acquire from.
- `:PERMITS` (integer, optional): Number of permits to acquire. Defaults to 1.
- `:TIMEOUT` (number, optional): Max seconds to wait before rejecting.
- `:CANCEL-TOKEN` (loom-cancel-token, optional): Token for cancellation.

Returns:
A `loom-promise` that resolves to the number of `PERMITS` on success.

Side Effects:
- May immediately decrement the semaphore's `count` if permits are available.
- Otherwise, enqueues a waiter in the semaphore's `wait-queue`.

Signals:
- `loom-invalid-semaphore-error`, `loom-semaphore-closed-error`,
  `loom-semaphore-permit-error`."
  (loom--validate-semaphore-open sem 'loom:semaphore-acquire)
  (loom--validate-permit-count permits 'loom:semaphore-acquire)

  (let (acquire-promise)
    (loom:with-mutex! (loom-semaphore-lock sem)
      (if (>= (loom-semaphore-count sem) permits)
          ;; Case 1: Permits are available immediately.
          (progn
            (cl-decf (loom-semaphore-count sem) permits)
            (loom--update-semaphore-stats sem permits nil)
            (setq acquire-promise (loom:resolved! permits))
            (loom:log! :debug (loom-semaphore-name sem)
                      "Acquired %d permits (immediate)." permits))
        ;; Case 2: Not enough permits, must wait.
        (let* ((stats (loom-semaphore-stats sem))
               (waiter-promise (loom:promise
                                :name (format "%s-acquire"
                                              (loom-semaphore-name sem))
                                :cancel-token cancel-token))
               (waiter (%%make-semaphore-waiter :promise waiter-promise
                                                :permits permits)))
          (loom:queue-enqueue (loom-semaphore-wait-queue sem) waiter)
          (puthash :total-waiters (1+ (gethash :total-waiters stats 0)) stats)
          (setq acquire-promise waiter-promise)
          (loom:log! :debug (loom-semaphore-name sem)
                    "Queued for %d permits." permits)

          ;; If a cancel token is provided, set up a callback to remove the
          ;; waiter from the queue if the token is signaled.
          (when cancel-token
            (loom:cancel-token-add-callback
             cancel-token
             (lambda (_reason)
               (loom:with-mutex! (loom-semaphore-lock sem)
                 (loom:log! :debug (loom-semaphore-name sem)
                           "Cancel token triggered for waiter of %d permits."
                           permits)
                 (loom:queue-remove-if (loom-semaphore-wait-queue sem)
                                       (lambda (w)
                                         (eq (loom-semaphore-waiter-promise w)
                                             waiter-promise))))))))))

    ;; Apply timeout wrapper outside the lock.
    (if timeout
        (loom:timeout acquire-promise timeout)
      acquire-promise)))

;;;###autoload
(cl-defun loom:semaphore-release (sem &optional (permits 1))
  "Release `PERMITS` slots in `SEM`, potentially satisfying waiting tasks.

Arguments:
- `SEM` (loom-semaphore): The semaphore to release.
- `PERMITS` (integer, optional): Number of permits to release. Defaults to 1.

Returns: `nil`.

Side Effects:
- Increments the semaphore's internal `count`.
- May resolve promises for tasks waiting in the queue.

Signals:
- `loom-invalid-semaphore-error`, `loom-semaphore-closed-error`,
  `loom-semaphore-permit-error`, `loom-semaphore-capacity-error`."
  (loom--validate-semaphore-open sem 'loom:semaphore-release)
  (loom--validate-permit-count permits 'loom:semaphore-release)

  (let (satisfied-waiters)
    (loom:with-mutex! (loom-semaphore-lock sem)
      ;; 1. Check for capacity errors.
      (when (> (+ (loom-semaphore-count sem) permits)
               (loom-semaphore-max-count sem))
        (loom:log! :error (loom-semaphore-name sem)
                  "Release of %d permits would exceed capacity of %d."
                  permits (loom-semaphore-max-count sem))
        (signal 'loom-semaphore-capacity-error
                (list (format "Release would exceed capacity of %d"
                              (loom-semaphore-max-count sem)))))

      ;; 2. Add the released permits and update stats.
      (cl-incf (loom-semaphore-count sem) permits)
      (loom--update-semaphore-stats sem nil permits)
      (loom:log! :debug (loom-semaphore-name sem)
                "Released %d permits. Available: %d."
                permits (loom-semaphore-count sem))

      ;; 3. Process the wait queue to satisfy waiting tasks.
      (while (and (not (loom:queue-empty-p (loom-semaphore-wait-queue sem)))
                  (>= (loom-semaphore-count sem)
                      (loom-semaphore-waiter-permits
                       (loom:queue-peek (loom-semaphore-wait-queue sem)))))
        (let* ((waiter (loom:queue-dequeue (loom-semaphore-wait-queue sem)))
               (needed-permits (loom-semaphore-waiter-permits waiter)))
          (unless (loom:promise-cancelled-p (loom-semaphore-waiter-promise waiter))
            (cl-decf (loom-semaphore-count sem) needed-permits)
            (loom--update-semaphore-stats sem needed-permits nil)
            (push waiter satisfied-waiters)))))

    ;; 4. Resolve promises for satisfied waiters outside the lock.
    (dolist (waiter satisfied-waiters)
      (loom:log! :debug (loom-semaphore-name sem)
                "Satisfying waiter for %d permits."
                (loom-semaphore-waiter-permits waiter))
      (loom:promise-resolve (loom-semaphore-waiter-promise waiter)
                            (loom-semaphore-waiter-permits waiter)))
    nil))

;;;###autoload
(defmacro loom:with-semaphore! (sem-obj &rest body)
  "Execute `BODY` after acquiring a single permit from `SEM-OBJ`.
This macro ensures the permit is always released.

Arguments:
- `SEM-OBJ` (loom-semaphore): The semaphore to acquire a permit from.
- `BODY` (forms): The Lisp forms to execute.

Returns:
- (loom-promise): A promise that resolves with the result of `BODY`."
  (declare (indent 1) (debug t))
  `(loom:then (loom:semaphore-acquire ,sem-obj)
              (lambda (_)
                (loom:finally (progn ,@body)
                              (lambda () (loom:semaphore-release ,sem-obj))))))

;;;###autoload
(defmacro loom:semaphore-with-permits! (sem-obj permits &rest body)
  "Execute `BODY` after acquiring `PERMITS` slots from `SEM-OBJ`.
This macro ensures the permits are always released.

Arguments:
- `SEM-OBJ` (loom-semaphore): The semaphore to acquire from.
- `PERMITS` (integer): Number of permits to acquire.
- `BODY` (forms): The Lisp forms to execute.

Returns:
- (loom-promise): A promise that resolves with the result of `BODY`."
  (declare (indent 1) (debug t))
  `(loom:then (loom:semaphore-acquire ,sem-obj :permits ,permits)
              (lambda (acquired-permits)
                (loom:finally (progn ,@body)
                              (lambda ()
                                (loom:semaphore-release
                                 ,sem-obj acquired-permits))))))

;;;###autoload
(defun loom:semaphore-drain (sem)
  "Acquire all available permits from `SEM` immediately.

Arguments:
- `SEM` (loom-semaphore): The semaphore to drain.

Returns:
The number of permits that were acquired.

Side Effects:
- Reduces the semaphore's available permit count to 0.

Signals:
- `loom-invalid-semaphore-error`, `loom-semaphore-closed-error`."
  (loom--validate-semaphore-open sem 'loom:semaphore-drain)
  (let (drained-permits)
    (loom:with-mutex! (loom-semaphore-lock sem)
      (setq drained-permits (loom-semaphore-count sem))
      (when (> drained-permits 0)
        (setf (loom-semaphore-count sem) 0)
        (loom--update-semaphore-stats sem drained-permits nil)))
    (when (> drained-permits 0)
      (loom:log! :info (loom-semaphore-name sem)
                "Drained %d permits." drained-permits))
    drained-permits))

;;;###autoload
(defun loom:semaphore-close (sem)
  "Close `SEM`, rejecting all waiting promises.

Arguments:
- `SEM` (loom-semaphore): The semaphore to close.

Returns:
The number of waiting promises that were rejected.

Side Effects:
- Marks the semaphore as closed.
- Rejects all promises for tasks currently waiting in the queue.

Signals:
- `loom-invalid-semaphore-error`."
  (loom--validate-semaphore sem 'loom:semaphore-close)
  (let (waiters-to-reject)
    (loom:with-mutex! (loom-semaphore-lock sem)
      (unless (loom-semaphore-closed-p sem)
        (setf (loom-semaphore-closed-p sem) t)
        (setq waiters-to-reject
              (loom:queue-drain (loom-semaphore-wait-queue sem)))))

    (dolist (waiter waiters-to-reject)
      (loom:log! :debug (loom-semaphore-name sem)
                "Rejecting waiter for %d permits due to closure."
                (loom-semaphore-waiter-permits waiter))
      (loom:promise-reject (loom-semaphore-waiter-promise waiter)
                           (loom:error! 
                            :type :loom-semaphore-closed-error
                            :message (format "Semaphore '%s' was closed"
                                      (loom-semaphore-name sem)))))

    (when waiters-to-reject
      (loom:log! :info (loom-semaphore-name sem)
                "Closed semaphore, rejected %d waiters."
                (length waiters-to-reject)))
    (length waiters-to-reject)))

;;;###autoload
(defun loom:semaphore-cleanup (sem)
  "Close and deregister a semaphore, cleaning up its resources.

Arguments:
- `SEM` (loom-semaphore): The semaphore to clean up.

Returns: `t`.

Side Effects:
- Calls `loom:semaphore-close` to reject all waiters.
- Removes the semaphore from the global tracking list.
- Clears internal fields of the semaphore struct.

Signals:
- `loom-invalid-semaphore-error`."
  (loom--validate-semaphore sem 'loom:semaphore-cleanup)
  (loom:log! :info (loom-semaphore-name sem) "Cleaning up semaphore.")
  (loom:semaphore-close sem)
  (setq loom--all-semaphores (delete sem loom--all-semaphores))
  (setf (loom-semaphore-lock sem) nil
        (loom-semaphore-wait-queue sem) nil
        (loom-semaphore-stats sem) nil)
  t)

;;;###autoload
(defun loom:semaphore-reset (sem)
  "Reset `SEM` to its initial state.
This closes the semaphore (rejecting any waiters), then resets its
permit count and statistics.

Arguments:
- `SEM` (loom-semaphore): The semaphore to reset.

Returns: `nil`.

Side Effects:
- Calls `loom:semaphore-close`.
- Resets the semaphore's permit count to its maximum.
- Clears all collected statistics for the semaphore.

Signals: `loom-invalid-semaphore-error`."
  (loom--validate-semaphore sem 'loom:semaphore-reset)
  (loom:log! :info (loom-semaphore-name sem) "Attempting to reset semaphore.")
  (loom:semaphore-close sem)
  (loom:with-mutex! (loom-semaphore-lock sem)
    (setf (loom-semaphore-count sem) (loom-semaphore-max-count sem)
          (loom-semaphore-closed-p sem) nil)
    (clrhash (loom-semaphore-stats sem))
    (puthash :creation-time (float-time) (loom-semaphore-stats sem)))
  (loom:log! :info (loom-semaphore-name sem) "Reset semaphore complete.")
  nil)

;;;###autoload
(defun loom:semaphore-get-count (sem)
  "Return the current number of available permits in `SEM`.

Arguments:
- `SEM` (loom-semaphore): The semaphore to inspect.

Returns:
The number of available permits.

Signals: `loom-invalid-semaphore-error`."
  (loom--validate-semaphore sem 'loom:semaphore-get-count)
  (loom-semaphore-count sem))

;;;###autoload
(defun loom:semaphore-status (sem)
  "Return a comprehensive status snapshot of `SEM`.

Arguments:
- `SEM` (loom-semaphore): The semaphore to inspect.

Returns:
A property list with semaphore metrics and status.

Signals: `loom-invalid-semaphore-error`."
  (loom--validate-semaphore sem 'loom:semaphore-status)
  (loom:with-mutex! (loom-semaphore-lock sem)
    (let* ((stats (loom-semaphore-stats sem))
           (max-count (loom-semaphore-max-count sem))
           (usage (- max-count (loom-semaphore-count sem))))
      `(:name ,(loom-semaphore-name sem)
        :available ,(loom-semaphore-count sem)
        :max-permits ,max-count
        :in-use ,usage
        :pending-acquirers
        ,(loom:queue-length (loom-semaphore-wait-queue sem))
        :closed-p ,(loom-semaphore-closed-p sem)
        :age ,(- (float-time) (gethash :creation-time stats 0.0))
        :total-acquires ,(gethash :total-acquires stats 0)
        :total-releases ,(gethash :total-releases stats 0)
        :peak-usage ,(gethash :peak-usage stats 0)
        :total-waiters ,(gethash :total-waiters stats 0)
        :utilization ,(if (> max-count 0)
                           (/ (float usage) max-count)
                         0.0)))))

;;;###autoload
(defun loom:semaphore-debug (sem)
  "Print detailed debug information about `SEM` to the *Messages* buffer.

Arguments:
- `SEM` (loom-semaphore): The semaphore to debug.

Returns: `nil`.

Side Effects: Prints information to the *Messages* buffer."
  (interactive)
  (loom--validate-semaphore sem 'loom:semaphore-debug)
  (let ((status (loom:semaphore-status sem)))
    (message "=== Semaphore Debug: %s ===" (plist-get status :name))
    (message "State: %s"
             (if (plist-get status :closed-p) "CLOSED" "OPEN"))
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shutdown Hook

(defun loom--semaphore-shutdown-hook ()
  "Clean up all active `loom-semaphore` instances on Emacs shutdown."
  (when loom--all-semaphores
    (loom:log! :info "Global" "Emacs shutdown: Cleaning up %d active semaphore(s)."
              (length loom--all-semaphores))
    ;; Iterate over a copy, as `loom:semaphore-cleanup` modifies the list.
    (dolist (sem (copy-sequence loom--all-semaphores))
      (loom:semaphore-cleanup sem))))

(add-hook 'kill-emacs-hook #'loom--semaphore-shutdown-hook)

(provide 'loom-semaphore)
;;; loom-semaphore.el ends here
