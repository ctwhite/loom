;;; loom-tests.el --- Comprehensive ERT Test Suite for the Loom Library -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file contains the final, comprehensive ERT test suite for the Loom
;; concurrency library. It is structured with a unit-testing philosophy,
;; providing dedicated tests for each public function, followed by tests for
;; more complex scenarios and edge cases.
;;
;; The tests are organized into sections that correspond to the major
;; files in the Loom library.
;;
;; This test suite assumes that all Loom library files (`loom-*.el`) has
;; been loaded or are available in the Emacs `load-path`.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Load all Loom library modules that are being tested
(require 'loom-errors)
(require 'loom-lock)
(require 'loom-queue)
(require 'loom-priority-queue)
(require 'loom-registry)
(require 'loom-microtask)
(require 'loom-scheduler)
(require 'loom-config)
(require 'loom-promise)
(require 'loom-primitives)
(require 'loom-combinators)
(require 'loom-cancel)
(require 'loom-event)
(require 'loom-semaphore)
(require 'loom-future)
(require 'loom-flow)
(require 'loom-poll)
(require 'loom-ipc)
(require 'json)     ; For direct JSON manipulation in IPC tests
(require 's)        ; For string manipulation in IPC tests

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Helper Utilities

(defmacro with-test-schedulers (&rest body)
  "Execute BODY within a clean scheduler environment.
This macro ensures that all internal Loom schedulers (microtask,
macrotask, thread) are reset before and after the `BODY` is run,
providing test isolation and predictability. It's especially
important for tests involving `loom:delay`, `loom:deferred`,
or thread-based promises."
  `(unwind-protect
       (progn
         ;; Initialize once at the beginning of the test
         (loom:init)
         ;; The actual test code goes here
         ,@body)
     ;; Ensure cleanup happens after the test, regardless of success or error.
     ;; This brings the system to a clean, shut-down state, ready for the
     ;; *next* test's reinitialization.
     (loom:shutdown)))

(defmacro loom-deftest (name docstring &rest body)
  "Define an ERT test specifically for Loom, including test scheduler setup.
This macro wraps `ert-deftest` and automatically includes
`with-test-schedulers`, reducing boilerplate for Loom-specific tests.

Arguments:
- `NAME` (symbol): The unique name of the test.
- `DOCSTRING` (string): Documentation string explaining the test's purpose.
- `BODY` (forms): The test body, which will automatically run inside
  `with-test-schedulers`."
  (declare (debug t)) ; Aids in macro expansion debugging
  `(ert-deftest ,name ,docstring
     (with-test-schedulers
       ,@body)))

;; ;; Global variable to accumulate results from `test-process-fn`
;; (defvar test-processed-tasks nil
;;   "Accumulates tasks processed by `test-process-fn` in scheduler tests.")

;; (defun test-process-fn (batch)
;;   "A simple process-fn for `loom-scheduler` tests.
;; Appends the `BATCH` of processed tasks to `test-processed-tasks`."
;;   (setq test-processed-tasks (append test-processed-tasks batch)))

;; ;; A custom priority function for `loom-priority-queue` and `loom-scheduler`
;; ;; tests. Assumes tasks are cons cells like `(value . priority)`.
;; (defun test-priority-fn (task)
;;   "Extracts the priority from a test `TASK` (cdr of a cons cell)."
;;   (cdr task))

;; ;; Global variable to log execution from `test-microtask-executor`
;; (defvar test-microtask-executor-log nil
;;   "Accumulates data from microtasks executed by `test-microtask-executor`.")

;; (defun test-microtask-executor (callback)
;;   "Records the callback's value to `test-microtask-executor-log`."
;;   (push (loom-callback-data callback) test-microtask-executor-log))

;; ;; Global variable to log tasks handled by `test-microtask-overflow-handler`
;; (defvar test-microtask-overflow-log nil
;;   "Accumulates tasks dropped due to overflow in microtask queue tests.")

;; (defun test-microtask-overflow-handler (queue overflowed-callbacks)
;;   "A custom overflow handler for `loom-microtask-queue` tests.
;; Appends `overflowed-callbacks` to `test-microtask-overflow-log`."
;;   (setq test-microtask-overflow-log
;;         (append test-microtask-overflow-log overflowed-callbacks)))

;; ;; Global variable to count periodic task executions for `loom-thread-polling`
;; (defvar test-periodic-task-count 0
;;   "Counts how many times a test periodic task has executed.")

;; ;; Global variable to store errors from `test-faulty-periodic-task`
;; (defvar test-periodic-task-errors nil
;;   "List of errors encountered by `test-faulty-periodic-task`.")

;; (defun test-simple-periodic-task ()
;;   "A simple periodic task that increments `test-periodic-task-count`."
;;   (cl-incf test-periodic-task-count))

;; (defun test-faulty-periodic-task ()
;;   "A periodic task that throws an error every other call."
;;   (cl-incf test-periodic-task-count)
;;   (when (oddp test-periodic-task-count)
;;     (error "Task failed at count %d" test-periodic-task-count)))

;; ;; Global var to store raw IPC messages sent to the process
;; ;; This is still needed for tests that explicitly check the raw string output
;; ;; of the mocked process-send-string, like loom-ipc-filter-partial-lines-test.
;; (defvar test-ipc-sent-strings nil
;;   "Log of raw strings sent to the IPC process via mocked process-send-string.")

;; ;; Removed test-ipc-received-messages as this was for the old mock filter.
;; ;; Removed test-ipc-sentinel-log as we will use the real sentinel.
;; ;; Removed test-mock-ipc-filter and test-mock-ipc-sentinel global definitions.

;; ;; Removed with-mock-ipc-process macro as it's no longer needed.

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ;;; Test Suite: loom-ipc.el

;; (ert-deftest loom-ipc-init-cleanup-test ()
;;   "Tests `loom:ipc-init` for proper initialization and `loom:ipc-cleanup`.
;; Verifies idempotency and correct resource allocation/deallocation.
;; This test does NOT use `loom-deftest` as it directly tests Loom's
;; global initialization and cleanup functions."
;;   ;; Initial state: all IPC globals should be nil
;;   (should (null loom--ipc-process))
;;   (should (null loom--ipc-buffer))
;;   (should (null loom--ipc-queue-mutex))
;;   (should (null loom--ipc-main-thread-queue))

;;   ;; Initialize IPC
;;   (loom:ipc-init)
;;   (should (process-live-p loom--ipc-process))
;;   (should (buffer-live-p loom--ipc-buffer))
;;   (when (fboundp 'make-thread)
;;     (should (loom-lock-p loom--ipc-queue-mutex))
;;     (should (loom-queue-p loom--ipc-main-thread-queue)))

;;   ;; Idempotency: calling init again should not create new resources
;;   (let ((old-process loom--ipc-process)
;;         (old-buffer loom--ipc-buffer)
;;         (old-mutex loom--ipc-queue-mutex))
;;     (loom:ipc-init)
;;     (should (eq old-process loom--ipc-process))
;;     (should (eq old-buffer loom--ipc-buffer))
;;     (should (eq old-mutex loom--ipc-queue-mutex)))

;;   ;; Cleanup IPC
;;   (loom:ipc-cleanup)
;;   (should (null loom--ipc-process))
;;   (should (not (buffer-live-p loom--ipc-buffer))) ; Buffer should be killed
;;   (should (null loom--ipc-queue-mutex))
;;   (should (null loom--ipc-main-thread-queue))

;;   ;; Idempotency: calling cleanup again should be safe
;;   (loom:ipc-cleanup)
;;   (should (null loom--ipc-process)))

;; (loom-deftest loom-ipc-dispatch-main-thread-process-path-test ()
;;   "Tests `loom:dispatch-to-main-thread` when running on main thread,
;; using the real process pipe for async dispatch, including data serialization.
;; This test verifies the end-to-end process communication."
;;   ;; loom-deftest already calls loom:init (which creates loom--ipc-process)
;;   ;; and loom:shutdown in an unwind-protect.

;;   ;; PART 1: Test with a value
;;   (let* ((actual-promise (loom:promise)) ; Create the real promise
;;          (p-id (loom-promise-id actual-promise)) ; Get its auto-generated ID
;;          (payload-data `(:id ,p-id :value "test-value" :data (1 2))))

;;     (sleep-for 0.5)
;;     ;; Dispatch a message. This will use the real loom--ipc-process.
;;     (loom:dispatch-to-main-thread
;;      actual-promise ; Pass the *actual* promise object
;;      nil ; default message-type
;;      payload-data)

;;     ;; Give Emacs time to process the pipe output via the filter function.
;;     ;; The filter will parse the JSON and call loom:process-settled-on-main.
;;     (sleep-for 0.5)

;;     ;; Verify the promise is now resolved
;;     (message "promise status --------------> %s" (loom:status actual-promise))
;;     (should (eq (loom:resolved-p actual-promise) t))
;;     (should (string= (loom:value actual-promise) "test-value")))

;;   ;; PART 2: Test with an error object, ensuring it's serialized and propagated
;;   (let* ((actual-promise-err (loom:promise)) ; Create another real promise for error test
;;          (p-id-err (loom-promise-id actual-promise-err))
;;          (err-obj (loom:make-error :type :test-error :message "IPC error")))

;;     (should (loom:pending-p actual-promise-err)) ; Should be pending initially

;;     (loom:dispatch-to-main-thread
;;      actual-promise-err
;;      nil
;;      `(:error ,err-obj)) ; Pass the error object directly

;;     ;; Give Emacs time to process the pipe output.
;;     (sit-for 0.01)

;;     ;; Verify the promise is now rejected and the error is correct.
;;     (should (loom:rejected-p actual-promise-err))
;;     (should (equal (loom:error-message actual-promise-err) "IPC error"))
;;     (should (equal (loom:error-type actual-promise-err) :test-error))))

;; (ert-deftest loom-ipc-dispatch-main-thread-fallback-test ()
;;   "Tests `loom:dispatch-to-main-thread` falls back to `run-at-time`
;; if no other IPC channel is available (e.g., process not running).
;; This test explicitly ensures Loom is uninitialized to test the fallback path."
;;   ;; Ensure Loom's IPC components are NOT initialized for this test
;;   (loom:ipc-cleanup) ; Defensive cleanup
;;   (let ((loom-promise-registry (make-hash-table :test 'eq)) ; For promise lookup
;;         (loom-enable-promise-registry t)
;;         (promise-resolved-p nil)
;;         (result-value nil))
;;     (loom:clear-registry)

;;     (let* ((p (loom:promise))
;;            (p-id (loom-promise-id p)))
;;       ;; Dispatch the message (should hit the `run-at-time` fallback)
;;       (loom:dispatch-to-main-thread p nil `(:value "fallback-value"))

;;       ;; `run-at-time` schedules for next idle moment; `sit-for` simulates it
;;       (sit-for 0.001)

;;       (should (loom:resolved-p p))
;;       (should (string= (loom:value p) "fallback-value")))))

;; (loom-deftest loom-ipc-drain-queue-test ()
;;   "Tests `loom:ipc-drain-queue` for processing messages from the queue.
;; Verifies message processing order and promise settlement. Uses `loom-deftest`
;; for proper Loom environment initialization."
;;   ;; Ensure IPC is initialized (creates queue and mutex)
;;   (loom:ipc-init)

;;   ;; Simulate promises existing in the registry for processing
;;   (let* ((p1 (loom:promise :name "p1"))
;;          (p2 (loom:promise :name "p2"))
;;          (p3 (loom:promise :name "p3")))
;;     ;; Enqueue some dummy messages directly into the internal queue
;;     (loom:with-mutex! loom--ipc-queue-mutex
;;       (loom:queue-enqueue loom--ipc-main-thread-queue
;;                           `(:id ,(loom-promise-id p1) :value "msg1"))
;;       (loom:queue-enqueue loom--ipc-main-thread-queue
;;                           `(:id ,(loom-promise-id p2) :value "msg2"))
;;       (loom:queue-enqueue loom--ipc-main-thread-queue
;;                           `(:id ,(loom-promise-id p3)
;;                             :error ,(loom:serialize-error ; <--- COMMA ADDED HERE
;;                                     (loom:make-error :message "err3")))))


;;     ;; Drain the queue
;;     (let ((processed-count (loom:ipc-drain-queue)))
;;       (should (eq processed-count 3)))

;;     ;; Verify queue is empty after drain
;;     (should (eq (loom:queue-length loom--ipc-main-thread-queue) 0))

;;     ;; Verify promises are settled as expected
;;     (should (loom:resolved-p p1))
;;     (should (string= (loom:value p1) "msg1"))
;;     (should (loom:resolved-p p2))
;;     (should (string= (loom:value p2) "msg2"))
;;     (should (loom:rejected-p p3))
;;     (should (string= (loom:error-message p3) "err3"))))

;; (loom-deftest loom-ipc-drain-queue-empty-test ()
;;   "Tests `loom:ipc-drain-queue` behaves correctly on an empty queue.
;; Uses `loom-deftest` for proper Loom environment initialization."
;;   (loom:ipc-init)
;;   (should (eq (loom:ipc-drain-queue) 0)))

;; (loom-deftest loom-ipc-parse-pipe-line-test ()
;;   "Tests internal `loom--ipc-parse-pipe-line` with various message types,
;; including JSON serialization/deserialization details.
;; This test manually sets up the minimal required environment and mocks
;; `loom-log` to capture internal messages."
;;   (let ((loom-promise-registry (make-hash-table :test 'eq))
;;         (loom-enable-promise-registry t)
;;         (log-messages '()))
;;     ;; Mock loom-log to capture internal log messages
;;     (cl-letf (((symbol-function 'loom-log)
;;                (lambda (level id format-string &rest args)
;;                  (push (format "%s: %s: %s" level (symbol-name id)
;;                                (apply #'format format-string args))
;;                        log-messages))))
;;       (loom:clear-registry)

;;       ;; Mock a promise to be settled for `promise-settled` messages
;;       (let* ((p (loom:promise :name "test-promise"))
;;              (p-id (loom-promise-id p)))
;;         (should (loom:pending-p p))

;;         ;; Test :promise-settled message (value)
;;         (let* ((payload `(:id ,p-id :type :promise-settled :value "test-val"))
;;                (json-line (json-encode payload)))
;;           (loom--ipc-parse-pipe-line json-line)
;;           (should (loom:resolved-p p))
;;           (should (string= (loom:value p) "test-val")))

;;         ;; Test :promise-settled message (error)
;;         (let* ((p2 (loom:promise :name "err-promise"))
;;                (p2-id (loom-promise-id p2))
;;                (err-data (loom:serialize-error
;;                           (loom:make-error :message "pipe-err"))))
;;           (let* ((payload `(:id ,p2-id :type :promise-settled :error ,err-data))
;;                  (json-line (json-encode payload)))
;;             (loom--ipc-parse-pipe-line json-line)
;;             (should (loom:rejected-p p2))
;;             (should (string= (loom:error-message p2) "pipe-err"))))

;;         ;; Test :log message
;;         (let* ((payload `(:type :log :level :info :message "Hello from pipe"))
;;                (json-line (json-encode payload)))
;;           (loom--ipc-parse-pipe-line json-line)
;;           (should (string-match-p "info: nil: IPC remote log: Hello from pipe"
;;                                   (car log-messages)))
;;           (setq log-messages nil)) ; Clear log for next check

;;         ;; Test unknown message type
;;         (let* ((payload `(:type :unknown-type :data "foo"))
;;                (json-line (json-encode payload)))
;;           (loom--ipc-parse-pipe-line json-line)
;;           (should (string-match-p "warn: nil: IPC filter received unknown message type"
;;                                   (car log-messages)))
;;           (setq log-messages nil))

;;         ;; Test malformed JSON
;;         (loom--ipc-parse-pipe-line "{not json")
;;         (should (string-match-p "error: nil: JSON parse error in IPC"
;;                                 (car log-messages)))))))

;; (loom-deftest loom-ipc-filter-partial-lines-test ()
;;   "Tests `loom--ipc-filter` handles partial lines and concatenates them
;; before parsing a complete line. This test uses a real IPC process
;; and mocks `process-send-string` to simulate partial writes."
;;   (unless (executable-find "cat")
;;     (skip "Skipping loom-ipc-filter-partial-lines-test: 'cat' executable not found."))

;;   ;; loom-deftest already calls loom:init, so loom--ipc-process is a real pipe.
;;   (let* ((process loom--ipc-process) ; Get the real process object
;;          (p (loom:promise :name "partial-line-test-promise"))
;;          (p-id (loom-promise-id p)))

;;     (should (loom:pending-p p))

;;     ;; Temporarily redefine `process-send-string` to intercept and
;;     ;; manually feed chunks to the real `loom--ipc-filter`.
;;     (cl-letf (((symbol-function 'process-send-string)
;;                (lambda (_p _s)
;;                  ;; Instead of sending to the real process, we feed directly to the filter.
;;                  ;; The real filter is already attached to loom--ipc-process.
;;                  ;; We also append to test-ipc-sent-strings for raw content verification.
;;                  (push _s test-ipc-sent-strings)
;;                  (loom--ipc-filter loom--ipc-process _s))))
;;       ;; Clear previous sent strings
;;       (setq test-ipc-sent-strings nil)

;;       ;; Simulate sending data in chunks
;;       (process-send-string process "{\"id\":")
;;       (process-send-string process (format "%S," p-id))
;;       (process-send-string process "\"value\":\"chunked-value\",\"type\":\"promise-settled\"}\n")

;;       ;; Give Emacs time to process the filter output (which happens synchronously here)
;;       (sit-for 0.01)

;;       ;; Verify the promise is resolved by the real filter
;;       (should (loom:resolved-p p))
;;       (should (string= (loom:value p) "chunked-value"))

;;       ;; Verify the raw strings sent via our mocked process-send-string
;;       (should (equal (length test-ipc-sent-strings) 3))
;;       (should (string= (nth 2 test-ipc-sent-strings) "{\"id\":"))
;;       (should (string= (nth 1 test-ipc-sent-strings) (format "%S," p-id)))
;;       (should (string= (nth 0 test-ipc-sent-strings) "\"value\":\"chunked-value\",\"type\":\"promise-settled\"}\n")))))

;; (loom-deftest loom-ipc-sentinel-test ()
;;   "Tests `loom--ipc-sentinel` triggers `loom:ipc-cleanup` on process
;; termination events. This test uses a real IPC process and mocks
;; `delete-process` to simulate termination."
;;   (unless (executable-find "cat")
;;     (skip "Skipping loom-ipc-sentinel-test: 'cat' executable not found."))

;;   ;; loom-deftest already calls loom:init, so loom--ipc-process is a real pipe.
;;   (let* ((process loom--ipc-process) ; Get the real process object
;;          (cleanup-called nil))
;;     ;; Mock `loom:ipc-cleanup` to track calls
;;     (cl-letf (((symbol-function 'loom:ipc-cleanup)
;;                (lambda () (setq cleanup-called t))))
;;       ;; Temporarily redefine `delete-process` to simulate termination
;;       ;; and call the real sentinel.
;;       (cl-letf (((symbol-function 'delete-process)
;;                  (lambda (_p)
;;                    ;; Call the real sentinel attached to the actual loom--ipc-process
;;                    (when-let ((sentinel-fn (process-sentinel loom--ipc-process)))
;;                      (funcall sentinel-fn loom--ipc-process "mock-process exited")))))
;;         ;; Simulate process termination event by calling the mocked delete-process
;;         (delete-process process)
;;         (should cleanup-called)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-semaphore.el

(loom-deftest loom-semaphore-create-test ()
  "Tests `loom:semaphore` creation and initial state."
  (let ((sem (loom:semaphore 5 "test-sem")))
    (should (loom-semaphore-p sem))
    (should (string= (loom-semaphore-name sem) "test-sem"))
    (should (eq (loom:semaphore-get-count sem) 5))
    (should (eq (loom-semaphore-max-count sem) 5))
    (should (not (loom-semaphore-closed-p sem)))
    (should (loom:queue-empty-p (loom-semaphore-wait-queue sem))))
  ;; Test with invalid initial count
  (should-error (loom:semaphore 0) :type 'loom-semaphore-permit-error)
  (should-error (loom:semaphore -1) :type 'loom-semaphore-permit-error)
  (should-error (loom:semaphore (1+ *loom-semaphore-max-permits*))
                :type 'loom-semaphore-permit-error))

(loom-deftest loom-semaphore-try-acquire-test ()
  "Tests `loom:semaphore-try-acquire` for non-blocking acquisition."
  (let ((sem (loom:semaphore 2)))
    ;; Acquire 1 permit
    (should (loom:semaphore-try-acquire sem))
    (should (eq (loom:semaphore-get-count sem) 1))
    ;; Acquire another permit
    (should (loom:semaphore-try-acquire sem 1))
    (should (eq (loom:semaphore-get-count sem) 0))
    ;; Try to acquire when no permits available
    (should (not (loom:semaphore-try-acquire sem)))
    (should (eq (loom:semaphore-get-count sem) 0))
    ;; Invalid permit count
    (should-error (loom:semaphore-try-acquire sem 0)
                  :type 'loom-semaphore-permit-error)
    (should-error (loom:semaphore-try-acquire sem -1)
                  :type 'loom-semaphore-permit-error)))

(loom-deftest loom-semaphore-acquire-immediate-test ()
  "Tests `loom:semaphore-acquire` when permits are immediately available."
  (let* ((sem (loom:semaphore 2))
         (p (loom:semaphore-acquire sem)))
    (should (eq (loom:semaphore-get-count sem) 1))
    (should (eq (loom:await p) 1)))
  (let* ((sem (loom:semaphore 5))
         (p (loom:semaphore-acquire sem :permits 3)))
    (should (eq (loom:semaphore-get-count sem) 2))
    (should (eq (loom:await p) 3))))

(loom-deftest loom-semaphore-acquire-waiting-and-release-test ()
  "Tests `loom:semaphore-acquire` with waiting and `loom:semaphore-release`."
  (let* ((sem (loom:semaphore 1))
         (p1 (loom:semaphore-acquire sem)) ; Acquires immediately
         (p2 (loom:semaphore-acquire sem)) ; Waits
         (p3 (loom:semaphore-acquire sem)) ; Waits
         (resolved-order '()))
    (should (eq (loom:semaphore-get-count sem) 0))
    (should (loom:pending-p p2))
    (should (loom:pending-p p3))
    ;; Attach handlers to capture resolve order
    (loom:then p1 (lambda (v) (push `(p1 . ,v) resolved-order)))
    (loom:then p2 (lambda (v) (push `(p2 . ,v) resolved-order)))
    (loom:then p3 (lambda (v) (push `(p3 . ,v) resolved-order)))

    (should (eq (loom:await p1) 1)) ; p1 resolves first
    (should (equal (nreverse resolved-order) '((p1 . 1))))

    ;; Release permits, p2 should get it
    (loom:semaphore-release sem 1)
    (should (eq (loom:semaphore-get-count sem) 0)) ; P2 re-acquires
    (should (eq (loom:await p2) 1))
    (should (equal (nreverse resolved-order) '((p1 . 1) (p2 . 1))))

    ;; Release permits, p3 should get it
    (loom:semaphore-release sem 1)
    (should (eq (loom:await p3) 1))
    (should (equal (nreverse resolved-order) '((p1 . 1) (p2 . 1) (p3 . 1))))
    (should (eq (loom:semaphore-get-count sem) 1))))

(loom-deftest loom-semaphore-acquire-fairness-test ()
  "Tests `loom:semaphore-acquire` respects FIFO fairness."
  (let* ((sem (loom:semaphore 1))
         (order-log '())
         (p1 (loom:semaphore-acquire sem)) ; Acquires immediately
         (p2 (loom:semaphore-acquire sem)) ; Waits
         (p3 (loom:semaphore-acquire sem))) ; Waits
    ;; Add to log as promises are resolved
    (loom:then p1 (lambda (_v) (push 'p1 order-log)))
    (loom:then p2 (lambda (_v) (push 'p2 order-log)))
    (loom:then p3 (lambda (_v) (push 'p3 order-log)))

    ;; Release multiple times, allowing waiters to proceed
    (loom:semaphore-release sem 1)
    (loom:semaphore-release sem 1)
    (loom:semaphore-release sem 1)

    (loom:await (loom:all (list p1 p2 p3))) ; Wait for all to settle
    (should (equal (nreverse order-log) '(p1 p2 p3))))) ; Verify FIFO order

(loom-deftest loom-semaphore-acquire-timeout-test ()
  "Tests `loom:semaphore-acquire` promise rejection on timeout."
  (let* ((sem (loom:semaphore 0)) ; No permits
         (rejection-error nil)
         (p (loom:semaphore-acquire sem :timeout 0.01)))
    (condition-case err (loom:await p)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (eq (loom-error-type rejection-error) :timeout-error))
    (should (string-match-p "timed out" (loom:error-message rejection-error)))
    ;; Check that the waiter is removed from the queue after timeout
    (should (eq (loom:queue-length (loom-semaphore-wait-queue sem)) 0))))

(loom-deftest loom-semaphore-acquire-cancel-token-test ()
  "Tests `loom:semaphore-acquire` promise rejection on cancellation."
  (let* ((sem (loom:semaphore 0)) ; No permits
         (cancel-token (loom:cancel-token))
         (rejection-error nil)
         (p (loom:semaphore-acquire sem :cancel-token cancel-token)))
    (loom:cancel-token-signal cancel-token "Acquisition cancelled")
    (condition-case err (loom:await p)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (eq (loom-error-type rejection-error) :cancel-error))
    (should (string-match-p "Acquisition cancelled"
                            (loom:error-message rejection-error)))
    ;; Check that the waiter is removed from the queue after cancellation
    (should (eq (loom:queue-length (loom-semaphore-wait-queue sem)) 0))))

(loom-deftest loom-semaphore-release-capacity-error-test ()
  "Tests `loom:semaphore-release` signals error if capacity is exceeded."
  (let ((sem (loom:semaphore 1))) ; Max count 1
    (should-error (loom:semaphore-release sem 2)
                  :type 'loom-semaphore-capacity-error)
    (should (eq (loom:semaphore-get-count sem) 1))))

(loom-deftest loom-semaphore-release-invalid-permits-test ()
  "Tests `loom:semaphore-release` signals error for invalid permits."
  (let ((sem (loom:semaphore 1)))
    (should-error (loom:semaphore-release sem 0)
                  :type 'loom-semaphore-permit-error)
    (should-error (loom:semaphore-release sem -1)
                  :type 'loom-semaphore-permit-error)))

(loom-deftest loom-with-semaphore-test ()
  "Tests `loom:with-semaphore!` macro acquires and releases 1 permit."
  (let ((sem (loom:semaphore 1))
        (body-run-p nil)
        (result nil))
    (setq result (loom:await (loom:with-semaphore! sem
                               (setq body-run-p t)
                               "body-result")))
    (should (eq (loom:semaphore-get-count sem) 1)) ; Permit released
    (should body-run-p)
    (should (string= result "body-result")))

  ;; Test error in body, permit should still be released
  (let ((sem (loom:semaphore 1))
        (rejection-error nil))
    (condition-case err
        (loom:await (loom:with-semaphore! sem (error "Body error")))
      (loom-await-error (setq rejection-error (cadr err))))
    (should (eq (loom:semaphore-get-count sem) 1)) ; Permit released
    (should (string-match-p "Body error" (loom:error-message rejection-error)))))

(loom-deftest loom-semaphore-with-permits-test ()
  "Tests `loom:semaphore-with-permits!` macro acquires and releases N permits."
  (let ((sem (loom:semaphore 3))
        (body-run-p nil)
        (result nil))
    (setq result (loom:await (loom:semaphore-with-permits! sem 2
                               (setq body-run-p t)
                               "multi-permit-result")))
    (should (eq (loom:semaphore-get-count sem) 3)) ; Permits released
    (should body-run-p)
    (should (string= result "multi-permit-result")))

  ;; Test error in body, permits should still be released
  (let ((sem (loom:semaphore 3))
        (rejection-error nil))
    (condition-case err
        (loom:await (loom:semaphore-with-permits! sem 2 (error "Multi-permit error")))
      (loom-await-error (setq rejection-error (cadr err))))
    (should (eq (loom:semaphore-get-count sem) 3)) ; Permits released
    (should (string-match-p "Multi-permit error" (loom:error-message rejection-error)))))

(loom-deftest loom-semaphore-drain-test ()
  "Tests `loom:semaphore-drain` acquires all available permits."
  (let ((sem (loom:semaphore 5)))
    (loom:semaphore-acquire sem 2) ; Acquire some permits
    (should (eq (loom:semaphore-get-count sem) 3))
    (should (eq (loom:semaphore-drain sem) 3)) ; Drain remaining 3
    (should (eq (loom:semaphore-get-count sem) 0))
    ;; Drain again, should return 0
    (should (eq (loom:semaphore-drain sem) 0)))
  ;; Test drain on empty semaphore
  (let ((sem (loom:semaphore 0)))
    (should (eq (loom:semaphore-drain sem) 0))))

(loom-deftest loom-semaphore-close-test ()
  "Tests `loom:semaphore-close` rejects waiting promises and prevents new ops."
  (let* ((sem (loom:semaphore 1))
         (p1 (loom:semaphore-acquire sem)) ; Acquires immediately
         (p2 (loom:semaphore-acquire sem)) ; Waits
         (p3 (loom:semaphore-acquire sem)) ; Waits
         (rejected-waiters-count 0))
    (should (loom:pending-p p2))
    (should (loom:pending-p p3))

    (setq rejected-waiters-count (loom:semaphore-close sem))
    (should (eq rejected-waiters-count 2)) ; p2 and p3 rejected
    (should (loom-semaphore-closed-p sem))

    ;; Await rejected promises to ensure they are indeed rejected
    (should-error (loom:await p2) :type 'loom-await-error)
    (should-error (loom:await p3) :type 'loom-await-error)
    ;; p1 should still resolve
    (should (eq (loom:await p1) 1))

    ;; Trying to acquire/release on a closed semaphore should error
    (should-error (loom:semaphore-acquire sem) :type 'loom-semaphore-closed-error)
    (should-error (loom:semaphore-release sem) :type 'loom-semaphore-closed-error)))

(loom-deftest loom-semaphore-reset-test ()
  "Tests `loom:semaphore-reset` restores initial state and rejects waiters."
  (let* ((sem (loom:semaphore 1 "reset-sem"))
         (p1 (loom:semaphore-acquire sem)) ; Acquires
         (p2 (loom:semaphore-acquire sem)) ; Waits
         (initial-status (loom:semaphore-status sem)))
    (should (loom:pending-p p2))
    (should (not (plist-get initial-status :closed-p)))

    (loom:semaphore-reset sem) ; Resets (and closes first)
    (should (eq (loom:semaphore-get-count sem) 1))
    (should (not (loom-semaphore-closed-p sem))) ; Should be re-opened
    (should-error (loom:await p2) :type 'loom-await-error) ; p2 should be rejected

    ;; Verify stats are cleared
    (let ((status (loom:semaphore-status sem)))
      (should (eq (plist-get status :total-acquires) 0))
      (should (eq (plist-get status :total-releases) 0))
      (should (eq (plist-get status :pending-acquirers) 0))
      (should (eq (plist-get status :peak-usage) 0)))))

(loom-deftest loom-semaphore-get-count-test ()
  "Tests `loom:semaphore-get-count`."
  (let ((sem (loom:semaphore 3)))
    (should (eq (loom:semaphore-get-count sem) 3))
    (loom:semaphore-acquire sem)
    (should (eq (loom:semaphore-get-count sem) 2))
    (loom:semaphore-release sem)
    (should (eq (loom:semaphore-get-count sem) 3)))
  (should-error (loom:semaphore-get-count nil)
                :type 'loom-invalid-semaphore-error))

(loom-deftest loom-semaphore-status-test ()
  "Tests `loom:semaphore-status` for comprehensive metric reporting."
  (let ((sem (loom:semaphore 2 "status-sem")))
    ;; Initial status
    (let ((status (loom:semaphore-status sem)))
      (should (string= (plist-get status :name) "status-sem"))
      (should (eq (plist-get status :available) 2))
      (should (eq (plist-get status :max-permits) 2))
      (should (eq (plist-get status :in-use) 0))
      (should (eq (plist-get status :pending-acquirers) 0))
      (should (not (plist-get status :closed-p)))
      (should (> (plist-get status :age) 0.0))
      (should (eq (plist-get status :total-acquires) 0))
      (should (eq (plist-get status :total-releases) 0))
      (should (eq (plist-get status :peak-usage) 0))
      (should (eq (plist-get status :total-waiters) 0))
      (should (= (plist-get status :utilization) 0.0)))

    ;; After acquire and pending
    (loom:semaphore-acquire sem) ; 1 used
    (loom:semaphore-acquire sem) ; 2 used
    (loom:semaphore-acquire sem) ; 1 pending
    (let ((status (loom:semaphore-status sem)))
      (should (eq (plist-get status :available) 0))
      (should (eq (plist-get status :in-use) 2))
      (should (eq (plist-get status :pending-acquirers) 1))
      (should (eq (plist-get status :total-acquires) 2))
      (should (eq (plist-get status :total-waiters) 1))
      (should (eq (plist-get status :peak-usage) 2))
      (should (= (plist-get status :utilization) 1.0)))

    ;; After release
    (loom:semaphore-release sem 1) ; 1 available, 0 pending
    (let ((status (loom:semaphore-status sem)))
      (should (eq (plist-get status :available) 1))
      (should (eq (plist-get status :in-use) 1))
      (should (eq (plist-get status :pending-acquirers) 0))
      (should (eq (plist-get status :total-releases) 1))
      (should (eq (plist-get status :total-acquires) 3)) ; 2 initial + 1 from wait
      (should (= (plist-get status :utilization) 0.5)))

    ;; After close
    (loom:semaphore-close sem)
    (let ((status (loom:semaphore-status sem)))
      (should (plist-get status :closed-p)))))

(ert-deftest loom-semaphore-debug-test ()
  "Tests `loom:semaphore-debug` (prints to messages, no direct assertion)."
  (let ((sem (loom:semaphore 1 "debug-sem")))
    (loom:semaphore-acquire sem)
    (loom:semaphore-acquire sem) ; Add a waiter
    (loom:semaphore-debug sem) ; Just ensure it runs without error
    (should t))) ; Placeholder assertion

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-thread-polling.el

(ert-deftest loom-poll-with-backoff-success-test ()
  "Tests `loom:poll-with-backoff` successfully when condition met."
  (let ((counter 0) (result nil))
    (setq result
          (loom:poll-with-backoff
           (lambda () (>= (cl-incf counter) 5))
           :poll-interval 0.001
           :debug-id 'poll-success))
    (should (eq counter 5))
    (should (eq result t))))

(ert-deftest loom-poll-with-backoff-work-fn-test ()
  "Tests `loom:poll-with-backoff` executes `work-fn` in each iteration."
  (let ((work-count 0))
    (loom:poll-with-backoff
     (lambda () (> (cl-incf work-count) 5))
     :work-fn (lambda () (message "Work iteration %d" work-count))
     :poll-interval 0.001)
    (should (eq work-count 6)))) ; work-fn runs before condition-fn on first iter

(ert-deftest loom-poll-with-backoff-timeout-test ()
  "Tests `loom:poll-with-backoff` signals `loom-thread-polling-timeout`."
  (should-error
   (loom:poll-with-backoff (lambda () nil) ; Always false
                           :timeout 0.01
                           :poll-interval 0.001
                           :debug-id 'poll-timeout)
   :type 'loom-thread-polling-timeout))

(ert-deftest loom-poll-with-backoff-max-iterations-test ()
  "Tests `loom:poll-with-backoff` respects `max-iterations`."
  (let ((counter 0))
    (loom:poll-with-backoff (lambda () nil) ; Always false
                            :max-iterations 3
                            :poll-interval 0.001
                            :work-fn (lambda () (cl-incf counter))
                            :debug-id 'poll-max-iter)
    ;; Work fn runs 3 times, then condition fn checks, then loop exits
    (should (eq counter 3))))

(ert-deftest loom-poll-with-backoff-error-in-work-fn-test ()
  "Tests `loom:poll-with-backoff` handles errors in `work-fn` gracefully."
  (let ((counter 0) (error-seen nil))
    (loom:poll-with-backoff
     (lambda () (> (cl-incf counter) 5))
     :work-fn (lambda () (if (= counter 3)
                             (error "Work function error")
                           nil))
     :poll-interval 0.001)
    ;; Loop should complete despite internal error
    (should (eq counter 6))))

(ert-deftest loom-poll-with-backoff-invalid-arguments-test ()
  "Tests `loom:poll-with-backoff` signals errors for invalid arguments."
  (should-error (loom:poll-with-backoff nil)
                :type 'loom-thread-polling-invalid-argument)
  (should-error (loom:poll-with-backoff #'identity :work-fn nil)
                :type 'loom-thread-polling-invalid-argument)
  (should-error (loom:poll-with-backoff #'identity :poll-interval -1)
                :type 'loom-thread-polling-invalid-argument)
  (should-error (loom:poll-with-backoff #'identity :max-iterations 0)
                :type 'loom-thread-polling-invalid-argument)
  (should-error (loom:poll-with-backoff #'identity :timeout -1)
                :type 'loom-thread-polling-invalid-argument))

;; Scheduler Thread Management Tests (requires native threads)
(when (fboundp 'make-thread)

  (ert-deftest loom-thread-polling-scheduler-start-stop-test ()
    "Tests `loom:thread-polling-ensure-scheduler-thread` and
  `loom:thread-polling-stop-scheduler-thread`."
    ;; Initial state
    (let ((status (loom:thread-polling-scheduler-status)))
      (should (not (plist-get status :running)))
      (should (not (plist-get status :thread-alive))))

    ;; Start thread
    (should (loom:thread-polling-ensure-scheduler-thread))
    (let ((status (loom:thread-polling-scheduler-status)))
      (should (plist-get status :running))
      (should (plist-get status :thread-alive))) ; Thread should be alive
    (should (loom-lock-p loom--periodic-tasks-mutex)) ; Mutex should be created

    ;; Idempotency of start
    (should (loom:thread-polling-ensure-scheduler-thread)) ; No error, still running

    ;; Stop thread
    (should (loom:thread-polling-stop-scheduler-thread))
    (let ((status (loom:thread-polling-scheduler-status)))
      (should (not (plist-get status :running)))) ; Flag set to nil

    ;; Join (wait for graceful exit)
    (should (loom:thread-polling-join-scheduler-thread 1.0)) ; Wait for 1 second
    (let ((status (loom:thread-polling-scheduler-status)))
      (should (not (plist-get status :running)))
      (should (not (plist-get status :thread-alive)))) ; Thread should be dead

    ;; Idempotency of stop (should return nil if already stopped)
    (should (not (loom:thread-polling-stop-scheduler-thread))))

  (ert-deftest loom-thread-polling-scheduler-join-timeout-test ()
    "Tests `loom:thread-polling-join-scheduler-thread` timeout."
    ;; Ensure thread starts
    (should (loom:thread-polling-ensure-scheduler-thread))

    ;; Stop it (non-blocking)
    (should (loom:thread-polling-stop-scheduler-thread))

    ;; Try to join with a very short timeout, expecting it to fail
    (let ((start-time (float-time)))
      (should (not (loom:thread-polling-join-scheduler-thread 0.001))) ; Too short
      (let ((elapsed (- (float-time) start-time)))
        ;; Verify that it did wait for at least the timeout duration
        (should (>= elapsed 0.001))))
    ;; Thread should eventually die due to previous stop signal
    (loom:thread-polling-join-scheduler-thread 1.0) ; Long join to ensure cleanup
    (should (not (plist-get (loom:thread-polling-scheduler-status)
                           :thread-alive))))

  (ert-deftest loom-thread-polling-periodic-task-management-test ()
    "Tests registration, unregistration, execution, and info retrieval of
  periodic tasks."
    ;; Reset counters and logs
    (setq test-periodic-task-count 0)
    (setq test-periodic-task-errors nil)

    ;; Register a simple task
    (should (loom:thread-polling-register-periodic-task
             'my-task #'test-simple-periodic-task))
    (let ((info (loom:thread-polling-get-task-info 'my-task)))
      (should info)
      (should (eq (plist-get info :error-count) 0))
      (should (eq (plist-get info :total-runs) 0)))

    ;; Give it time to run (it runs every loom-thread-polling-default-interval)
    (sit-for (* loom-thread-polling-default-interval 2.5)) ; Allow multiple runs
    (should (> test-periodic-task-count 0)) ; Should have run at least once

    (let ((info (loom:thread-polling-get-task-info 'my-task)))
      (should info)
      (should (> (plist-get info :total-runs) 0))
      (should (plist-get info :last-run-time))) ; Should have a last run time

    ;; Unregister the task
    (should (loom:thread-polling-unregister-periodic-task 'my-task))
    (should (null (loom:thread-polling-get-task-info 'my-task))) ; Should be gone

    ;; Verify it doesn't run anymore
    (let ((current-count test-periodic-task-count))
      (sit-for (* loom-thread-polling-default-interval 2.5))
      (should (eq test-periodic-task-count current-count))) ; Count should not change

    ;; Test listing tasks
    (should (null (loom:thread-polling-list-periodic-tasks)))
    (loom:thread-polling-register-periodic-task 'task-1 #'identity)
    (loom:thread-polling-register-periodic-task 'task-2 #'identity)
    (should (equal (sort (loom:thread-polling-list-periodic-tasks) #'string<)
                   '(task-1 task-2))))

  (ert-deftest loom-thread-polling-periodic-task-error-handling-test ()
    "Tests that periodic tasks with errors are handled and potentially removed."
    ;; Temporarily set a low max error threshold for quicker testing
    (let ((loom-thread-polling-max-task-errors 2))
      ;; Reset counters and logs
      (setq test-periodic-task-count 0)
      (setq test-periodic-task-errors nil)

      (loom:thread-polling-register-periodic-task 'faulty-task
                                                  #'test-faulty-periodic-task)

      ;; First run: success, then error
      (sit-for (* loom-thread-polling-default-interval 1.5))
      (let ((info (loom:thread-polling-get-task-info 'faulty-task)))
        (should (eq (plist-get info :total-runs) 2)) ; Two runs total
        (should (eq (plist-get info :error-count) 1)) ; One error
        (should (plist-get info :last-error)))

      ;; Second error, should hit threshold and remove task
      (sit-for (* loom-thread-polling-default-interval 1.5))
      (let ((info (loom:thread-polling-get-task-info 'faulty-task)))
        (should (eq (plist-get info :total-runs) 3)) ; Three runs total
        (should (eq (plist-get info :error-count) 2)) ; Two errors
        (should (plist-get info :last-error)))

      ;; Give it one more cycle to be removed by the scheduler
      (sit-for (* loom-thread-polling-default-interval 0.5))
      (should (null (loom:thread-polling-get-task-info 'faulty-task))) ; Task should be removed

      ;; Verify task is no longer running
      (let ((current-count test-periodic-task-count))
        (sit-for (* loom-thread-polling-default-interval 2.5))
        (should (eq test-periodic-task-count current-count))))))

;; Status and Health Reporting Tests
(when (fboundp 'make-thread)
  (ert-deftest loom-thread-polling-scheduler-status-report-test ()
    "Tests `loom:thread-polling-scheduler-status` and
  `loom:thread-polling-system-health-report`."
    ;; Initial state (before starting scheduler)
    (let ((status (loom:thread-polling-scheduler-status)))
      (should (not (plist-get status :running)))
      (should (not (plist-get status :thread-alive)))
      (should (eq (plist-get status :task-count) 0)))
    (let ((report (loom:thread-polling-system-health-report)))
      (should (eq (plist-get report :health-score) 0))
      (should (string= (plist-get report :health-description) "Critical"))
      (should (member "Scheduler is not set to run"
                      (plist-get report :errors)))
      (should (member "Scheduler thread is not alive (crashed?)"
                      (plist-get report :errors)))
      (should (member "No periodic tasks are currently registered"
                      (plist-get report :recommendations))))

    ;; Start scheduler and register a task
    (setq test-periodic-task-count 0)
    (loom:thread-polling-ensure-scheduler-thread)
    (loom:thread-polling-register-periodic-task 'alive-task #'identity)
    (sit-for (* loom-thread-polling-default-interval 1.5)) ; Allow task to run once

    ;; Running state, one task
    (let ((status (loom:thread-polling-scheduler-status)))
      (should (plist-get status :running))
      (should (plist-get status :thread-alive))
      (should (eq (plist-get status :task-count) 1))
      (should (eq (plist-get status :error-tasks) 0)))
    (let ((report (loom:thread-polling-system-health-report)))
      (should (eq (plist-get report :health-score) 100))
      (string= (plist-get report :health-description) "Excellent")
      (should (null (plist-get report :errors)))
      (should (null (plist-get report :warnings)))
      (should (null (plist-get report :recommendations))))

    ;; Register a faulty task to create errors
    (let ((loom-thread-polling-max-task-errors 2)) ; Low threshold for test
      (loom:thread-polling-register-periodic-task
       'error-task #'test-faulty-periodic-task)
      (sit-for (* loom-thread-polling-default-interval 3.5)) ; Allow it to error enough

      ;; State with errors (faulty task should have been removed)
      (let ((status (loom:thread-polling-scheduler-status)))
        (should (plist-get status :running))
        (should (plist-get status :thread-alive))
        (should (eq (plist-get status :task-count) 1)) ; Only 'alive-task' remains
        (should (eq (plist-get status :error-tasks) 0)))
      (let ((report (loom:thread-polling-system-health-report)))
        (should (eq (plist-get report :health-score) 100)) ; Health is good as task removed
        (string= (plist-get report :health-description) "Excellent")))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-priority-queue.el

(ert-deftest loom-priority-queue-create-test ()
  "Tests `loom:priority-queue` creation and initial state."
  ;; Default min-heap creation
  (let ((pq (loom:priority-queue)))
    (should (loom-priority-queue-p pq))
    (should (loom:priority-queue-empty-p pq))
    (should (eq (loom:priority-queue-length pq) 0))
    (should (eq (loom-priority-queue-comparator pq) #'<)))

  ;; Custom max-heap creation with initial capacity
  (let ((pq (loom:priority-queue :comparator #'> :initial-capacity 10)))
    (should (loom-priority-queue-p pq))
    (should (loom:priority-queue-empty-p pq))
    (should (eq (loom-priority-queue-comparator pq) #'>))
    (should (eq (length (loom-priority-queue-heap pq)) 10)))

  ;; Error cases for invalid arguments
  (should-error (loom:priority-queue :comparator "bad") :type 'error)
  (should-error (loom:priority-queue :initial-capacity 0) :type 'error))

(ert-deftest loom-priority-queue-insert-and-peek-test ()
  "Tests `loom:priority-queue-insert` and `loom:priority-queue-peek`
(min-heap behavior)."
  (let ((pq (loom:priority-queue)))
    (should (null (loom:priority-queue-peek pq))) ; Peek on empty queue
    (loom:priority-queue-insert pq 10)
    (should (eq (loom:priority-queue-peek pq) 10))
    (loom:priority-queue-insert pq 5)
    (should (eq (loom:priority-queue-peek pq) 5)) ; 5 has higher priority
    (loom:priority-queue-insert pq 15)
    (should (eq (loom:priority-queue-peek pq) 5))
    (loom:priority-queue-insert pq 2)
    (should (eq (loom:priority-queue-peek pq) 2)) ; 2 is now highest
    (should (eq (loom:priority-queue-length pq) 4))))

(ert-deftest loom-priority-queue-insert-max-heap-test ()
  "Tests `loom:priority-queue-insert` with a max-heap comparator."
  (let ((pq (loom:priority-queue :comparator #'>))) ; Higher number = higher priority
    (loom:priority-queue-insert pq 10)
    (should (eq (loom:priority-queue-peek pq) 10))
    (loom:priority-queue-insert pq 5)
    (should (eq (loom:priority-queue-peek pq) 10))
    (loom:priority-queue-insert pq 15)
    (should (eq (loom:priority-queue-peek pq) 15)) ; 15 is now highest
    (should (eq (loom:priority-queue-length pq) 3))))

(ert-deftest loom-priority-queue-pop-test ()
  "Tests `loom:priority-queue-pop` (min-heap behavior)."
  (let ((pq (loom:priority-queue)))
    (loom:priority-queue-insert pq 10)
    (loom:priority-queue-insert pq 5)
    (loom:priority-queue-insert pq 15)
    (loom:priority-queue-insert pq 2)

    ;; Pop in priority order
    (should (eq (loom:priority-queue-pop pq) 2))
    (should (eq (loom:priority-queue-peek pq) 5))
    (should (eq (loom:priority-queue-pop pq) 5))
    (should (eq (loom:priority-queue-peek pq) 10))
    (should (eq (loom:priority-queue-pop pq) 10))
    (should (eq (loom:priority-queue-peek pq) 15))
    (should (eq (loom:priority-queue-pop pq) 15))
    (should (loom:priority-queue-empty-p pq))
    (should (eq (loom:priority-queue-length pq) 0))

    ;; Popping from an empty queue should signal an error
    (should-error (loom:priority-queue-pop pq) :type 'error)))

(ert-deftest loom-priority-queue-pop-n-test ()
  "Tests `loom:priority-queue-pop-n` for batch removal."
  (let ((pq (loom:priority-queue)))
    (loom:priority-queue-insert pq 10)
    (loom:priority-queue-insert pq 5)
    (loom:priority-queue-insert pq 15)
    (loom:priority-queue-insert pq 2)
    (loom:priority-queue-insert pq 8)

    ;; Pop 2 highest priority items
    (should (equal (loom:priority-queue-pop-n pq 2) '(2 5)))
    (should (eq (loom:priority-queue-length pq) 3))
    ;; Pop more than available items
    (should (equal (loom:priority-queue-pop-n pq 5) '(8 10 15)))
    (should (loom:priority-queue-empty-p pq))

    ;; Popping from an empty queue should return nil
    (should (equal (loom:priority-queue-pop-n pq 1) nil)))

  ;; Error for non-positive N
  (should-error (loom:priority-queue-pop-n (loom:priority-queue) -1)
                :type 'error))

(ert-deftest loom-priority-queue-remove-test ()
  "Tests `loom:priority-queue-remove` for specific item deletion."
  (let ((pq (loom:priority-queue)))
    (loom:priority-queue-insert pq 10)
    (loom:priority-queue-insert pq 5)
    (loom:priority-queue-insert pq 15)
    (loom:priority-queue-insert pq 2)
    (should (eq (loom:priority-queue-length pq) 4))
    (should (eq (loom:priority-queue-peek pq) 2))

    ;; Remove a non-highest priority item
    (should (loom:priority-queue-remove pq 10))
    (should (eq (loom:priority-queue-length pq) 3))
    (should (eq (loom:priority-queue-peek pq) 2)) ; Heap property maintained

    ;; Remove the current highest priority item
    (should (loom:priority-queue-remove pq 2))
    (should (eq (loom:priority-queue-length pq) 2))
    (should (eq (loom:priority-queue-peek pq) 5))

    ;; Attempt to remove a non-existent item
    (should (not (loom:priority-queue-remove pq 99)))
    (should (eq (loom:priority-queue-length pq) 2)) ; Length unchanged

    ;; Remove all remaining items
    (should (loom:priority-queue-remove pq 5))
    (should (loom:priority-queue-remove pq 15))
    (should (loom:priority-queue-empty-p pq))

    ;; Test with a custom equality test for composite items
    (let ((pq-custom (loom:priority-queue)))
      (loom:priority-queue-insert pq-custom '(a . 1))
      (loom:priority-queue-insert pq-custom '(b . 2))
      (should (loom:priority-queue-remove
               pq-custom '(b . 99) :test (lambda (item target)
                                          (eq (car item) (car target)))))
      (should (eq (loom:priority-queue-length pq-custom) 1))
      (should (equal (loom:priority-queue-peek pq-custom) '(a . 1))))))

(ert-deftest loom-priority-queue-clear-test ()
  "Tests `loom:priority-queue-clear` empties the queue."
  (let ((pq (loom:priority-queue)))
    (loom:priority-queue-insert pq 1)
    (loom:priority-queue-insert pq 2)
    (should-not (loom:priority-queue-empty-p pq))
    (should (eq (loom:priority-queue-length pq) 2))

    (loom:priority-queue-clear pq)
    (should (loom:priority-queue-empty-p pq))
    (should (eq (loom:priority-queue-length pq) 0))
    (should (null (loom:priority-queue-peek pq)))))

(ert-deftest loom-priority-queue-resize-test ()
  "Tests that the internal heap array resizes dynamically on insertion."
  (let ((pq (loom:priority-queue :initial-capacity 2))) ; Small initial capacity
    (should (eq (length (loom-priority-queue-heap pq)) 2))
    (loom:priority-queue-insert pq 1)
    (loom:priority-queue-insert pq 2)
    (should (eq (length (loom-priority-queue-heap pq)) 2)) ; Filled, not yet resized
    (loom:priority-queue-insert pq 3)
    (should (> (length (loom-priority-queue-heap pq)) 2)) ; Should have resized (e.g., to 4)
    (should (eq (loom:priority-queue-length pq) 3))
    (should (eq (loom:priority-queue-peek pq) 1))))

(ert-deftest loom-priority-queue-status-test ()
  "Tests `loom:priority-queue-status` for correct metric reporting."
  (let ((pq (loom:priority-queue :initial-capacity 5)))
    (loom:priority-queue-insert pq 10)
    (loom:priority-queue-insert pq 5)
    (let ((status (loom:priority-queue-status pq)))
      (should (eq (plist-get status :length) 2))
      (should (eq (plist-get status :capacity) 5))
      (should (not (plist-get status :is-empty)))))

  (let ((pq (loom:priority-queue)))
    (let ((status (loom:priority-queue-status pq)))
      (should (eq (plist-get status :length) 0))
      (should (eq (plist-get status :capacity) 32)) ; Default capacity
      (should (plist-get status :is-empty)))))

(ert-deftest loom-priority-queue-invalid-argument-test ()
  "Tests that priority queue functions signal errors for invalid queue objects."
  (should-error (loom:priority-queue-length nil)
                :type 'loom-invalid-priority-queue-error)
  (should-error (loom:priority-queue-empty-p "string")
                :type 'loom-invalid-priority-queue-error)
  (should-error (loom:priority-queue-insert (cons 1 2) 10)
                :type 'loom-invalid-priority-queue-error)
  (should-error (loom:priority-queue-peek nil)
                :type 'loom-invalid-priority-queue-error)
  (should-error (loom:priority-queue-pop '(1 2 3))
                :type 'loom-invalid-priority-queue-error)
  (should-error (loom:priority-queue-pop-n (vector) 1)
                :type 'loom-invalid-priority-queue-error)
  (should-error (loom:priority-queue-remove nil 1)
                :type 'loom-invalid-priority-queue-error)
  (should-error (loom:priority-queue-clear '(a b c))
                :type 'loom-invalid-priority-queue-error)
  (should-error (loom:priority-queue-status (hash-table))
                :type 'loom-invalid-priority-queue-error))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-microtask.el

(ert-deftest loom-microtask-queue-create-and-status-test ()
  "Tests `loom:microtask-queue` creation and initial `loom:microtask-status`."
  (let ((queue (loom:microtask-queue :executor #'test-microtask-executor)))
    (should (loom-microtask-queue-p queue))
    (let ((status (loom:microtask-status queue)))
      (should (eq (plist-get status :queue-length) 0))
      (should (not (plist-get status :drain-scheduled-p)))
      (should (eq (plist-get status :drain-tick-counter) 0))
      (should (eq (plist-get status :capacity)
                  loom-microtask-queue-default-capacity))
      (should (eq (plist-get status :max-batch-size)
                  loom-microtask-default-batch-size))))
  ;; Error for non-function executor
  (should-error (loom:microtask-queue :executor nil) :type 'error))

(ert-deftest loom-microtask-enqueue-and-drain-test ()
  "Tests `loom:microtask-enqueue` triggers immediate synchronous drain."
  (setq test-microtask-executor-log nil)
  (let ((queue (loom:microtask-queue :executor #'test-microtask-executor)))
    (loom:microtask-enqueue queue (loom:callback "task1"))
    (loom:microtask-enqueue queue (loom:callback "task2"))

    ;; Tasks should be processed immediately because `enqueue` triggers drain
    (should (equal (nreverse test-microtask-executor-log) '("task1" "task2")))
    (should (eq (plist-get (loom:microtask-status queue) :queue-length) 0))
    (should (not (plist-get (loom:microtask-status queue) :drain-scheduled-p)))
    (should (eq (plist-get (loom:microtask-status queue) :drain-tick-counter) 1)))
  ;; Error for non-callback argument
  (should-error (loom:microtask-enqueue (loom:microtask-queue :executor #'identity)
                                        "not-a-callback")
                :type 'error))

(ert-deftest loom-microtask-drain-idempotency-test ()
  "Tests `loom:microtask-drain` is idempotent and prevents re-entrancy."
  (setq test-microtask-executor-log nil)
  (let ((queue (loom:microtask-queue :executor #'test-microtask-executor)))
    (loom:microtask-enqueue queue (loom:callback "task-A"))
    ;; Queue should be empty and drained by now
    (should (equal (nreverse test-microtask-executor-log) '("task-A")))
    (should (eq (plist-get (loom:microtask-status queue) :drain-tick-counter) 1))

    ;; Calling drain again on an empty queue should do nothing
    (setq test-microtask-executor-log nil)
    (should (not (loom:microtask-drain queue))) ; Should return nil (no new drain initiated)
    (should (null test-microtask-executor-log))
    ;; Counter shouldn't increment
    (should (eq (plist-get (loom:microtask-status queue) :drain-tick-counter) 1))

    ;; Enqueue a new task, it should trigger a drain and increment counter
    (loom:microtask-enqueue queue (loom:callback "task-B"))
    (should (equal (nreverse test-microtask-executor-log) '("task-B")))
    (should (eq (plist-get (loom:microtask-status queue) :drain-tick-counter) 2))))

(ert-deftest loom-microtask-batch-processing-test ()
  "Tests that `loom:microtask-drain` processes tasks in batches internally.
The internal `loom--drain-microtask-queue` loops through batches
until the queue is empty within a single 'drain tick'."
  (setq test-microtask-executor-log nil)
  (let ((queue (loom:microtask-queue :executor #'test-microtask-executor
                                     :max-batch-size 2)))
    (loom:queue-enqueue (loom-microtask-queue-queue queue)
                        (loom:callback "b1"))
    (loom:queue-enqueue (loom-microtask-queue-queue queue)
                        (loom:callback "b2"))
    (loom:queue-enqueue (loom-microtask-queue-queue queue)
                        (loom:callback "b3"))
    (loom:queue-enqueue (loom-microtask-queue-queue queue)
                        (loom:callback "b4"))

    ;; Manually trigger drain; this initiates one 'drain tick'
    (should (loom:microtask-drain queue))
    ;; All tasks processed in the same drain tick, despite batching
    (should (equal (nreverse test-microtask-executor-log)
                   '("b1" "b2" "b3" "b4")))
    (should (eq (plist-get (loom:microtask-status queue) :queue-length) 0))
    ;; Only one drain 'tick' from the `loom:microtask-drain` call
    (should (eq (plist-get (loom:microtask-status queue) :drain-tick-counter)
                1))))

(ert-deftest loom-microtask-queue-overflow-test ()
  "Tests `loom:microtask-enqueue` with queue capacity limits and
an `overflow-handler`."
  (setq test-microtask-executor-log nil)
  (setq test-microtask-overflow-log nil)
  (let ((queue (loom:microtask-queue :executor #'test-microtask-executor
                                     :capacity 1 ; Only 1 task allowed
                                     :overflow-handler
                                     #'test-microtask-overflow-handler)))
    (loom:microtask-enqueue queue (loom:callback "task-in-bounds"))
    (should (equal (nreverse test-microtask-executor-log) '("task-in-bounds")))
    (should (null test-microtask-overflow-log))
    (should (eq (plist-get (loom:microtask-status queue) :queue-length) 0))

    ;; Now enqueue tasks that exceed capacity; they should go to the handler
    (loom:microtask-enqueue queue (loom:callback "task-overflow-1"))
    (loom:microtask-enqueue queue (loom:callback "task-overflow-2"))

    ;; Overflowed tasks should be handled, not executed
    (should (equal (nreverse test-microtask-overflow-log)
                   '("task-overflow-1" "task-overflow-2")))
    (should (equal (nreverse test-microtask-executor-log)
                   '("task-in-bounds"))) ; Executor log unchanged
    ;; Queue should remain empty after initial task drain
    (should (eq (plist-get (loom:microtask-status queue) :queue-length) 0))

    ;; Test capacity 0 means queue is always full, always overflows
    (setq test-microtask-executor-log nil)
    (setq test-microtask-overflow-log nil)
    (let ((zero-capacity-queue (loom:microtask-queue
                                :executor #'test-microtask-executor
                                :capacity 0
                                :overflow-handler
                                #'test-microtask-overflow-handler)))
      (loom:microtask-enqueue zero-capacity-queue (loom:callback "zero-cap-task"))
      (should (null test-microtask-executor-log))
      (should (equal (nreverse test-microtask-overflow-log)
                     '("zero-cap-task"))))))

(ert-deftest loom-microtask-executor-error-handling-test ()
  "Tests that errors within an executor do not stop the queue from draining.
The scheduler should log the error and continue processing subsequent tasks."
  (setq test-microtask-executor-log nil)
  (let ((error-count 0)
        (faulty-executor (lambda (cb)
                           (cl-incf error-count)
                           (error "Executor failed for: %S"
                                  (loom-callback-data cb)))))
    (let ((queue (loom:microtask-queue :executor #'faulty-executor)))
      (loom:microtask-enqueue queue (loom:callback "faulty-task-1"))
      (loom:microtask-enqueue queue (loom:callback "faulty-task-2"))

      ;; Even with errors, all tasks should be attempted and the queue drained
      (should (eq (plist-get (loom:microtask-status queue) :queue-length) 0))
      (should (eq (plist-get (loom:microtask-status queue) :drain-tick-counter) 1))
      (should (eq error-count 2)))))

(ert-deftest loom-microtask-nested-enqueue-test ()
  "Tests enqueuing new microtasks from within a microtask executor.
All tasks, including nested ones, should be processed in the same
synchronous drain tick, respecting run-to-completion."
  (setq test-microtask-executor-log nil)
  (let ((queue (loom:microtask-queue
                :executor (lambda (cb)
                            (push (loom-callback-data cb)
                                  test-microtask-executor-log)
                            (when (string= (loom-callback-data cb) "task1")
                              ;; Enqueue another task from within executor
                              (loom:microtask-enqueue queue
                                                      (loom:callback "nested-task")))))))
    (loom:microtask-enqueue queue (loom:callback "task1"))
    (loom:microtask-enqueue queue (loom:callback "task2"))

    ;; All tasks, including the nested one, should be processed in the same
    ;; drain tick and in FIFO order
    (should (equal (nreverse test-microtask-executor-log)
                   '("task1" "nested-task" "task2")))
    (should (eq (plist-get (loom:microtask-status queue) :queue-length) 0))
    (should (eq (plist-get (loom:microtask-status queue) :drain-tick-counter) 1))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-scheduler.el

(ert-deftest loom-scheduler-create-and-status-test ()
  "Tests `loom:scheduler` creation and initial `loom:scheduler-status`."
  (let ((scheduler (loom:scheduler :name "test-create"
                                   :process-fn #'test-process-fn)))
    (should (loom-scheduler-p scheduler))
    ;; `gensym` creates a unique symbol, so we check for prefix matching
    (should (string-prefix-p "test-create-"
                             (symbol-name (loom-scheduler-id scheduler))))
    (let ((status (loom:scheduler-status scheduler)))
      (should (eq (plist-get status :queue-length) 0))
      (should (not (plist-get status :is-running-p)))
      (should (not (plist-get status :has-timer-p)))
      (should (eq (plist-get status :id) (loom-scheduler-id scheduler))))))

(ert-deftest loom-scheduler-enqueue-and-process-test ()
  "Tests enqueuing tasks and automatic processing via idle timer."
  (loom:clear-registry) ; Clear registry for a clean slate
  (setq test-processed-tasks nil) ; Reset test accumulator
  (let* ((scheduler (loom:scheduler :name "enqueue-process"
                                    :process-fn #'test-process-fn
                                    :batch-size 2
                                    :adaptive-delay-p nil ; Fixed delay for predictability
                                    :min-delay 0.001)))
    ;; Enqueue tasks
    (loom:scheduler-enqueue scheduler "taskA")
    (loom:scheduler-enqueue scheduler "taskB")
    (loom:scheduler-enqueue scheduler "taskC")

    ;; At this point, the timer should be active but no tasks processed yet
    (let ((status (loom:scheduler-status scheduler)))
      (should (eq (plist-get status :queue-length) 3))
      (should (plist-get status :has-timer-p)))

    ;; Force the scheduler to run its timer callback
    ;; `sit-for` with `with-test-schedulers` forces timer execution
    (sit-for 0.001)
    (should (equal test-processed-tasks '("taskA" "taskB"))) ; First batch processed
    (setq test-processed-tasks nil) ; Clear for next batch

    ;; The timer should have re-scheduled itself for the remaining task
    (let ((status (loom:scheduler-status scheduler)))
      (should (eq (plist-get status :queue-length) 1))
      (should (plist-get status :has-timer-p)))

    ;; Process the next (final) batch
    (sit-for 0.001)
    (should (equal test-processed-tasks '("taskC")))

    ;; Queue should now be empty and timer should be inactive
    (let ((status (loom:scheduler-status scheduler)))
      (should (eq (plist-get status :queue-length) 0))
      (should (not (plist-get status :has-timer-p))))))

(ert-deftest loom-scheduler-priority-queue-test ()
  "Tests that tasks are processed according to priority."
  (loom:clear-registry)
  (setq test-processed-tasks nil)
  (let* ((scheduler (loom:scheduler :name "priority-test"
                                    :process-fn #'test-process-fn
                                    :priority-fn #'test-priority-fn
                                    :batch-size 1 ; Process one by one to see order
                                    :adaptive-delay-p nil
                                    :min-delay 0.001)))
    ;; Enqueue tasks with different priorities (lower number = higher priority)
    (loom:scheduler-enqueue scheduler '("task-C" . 3))
    (loom:scheduler-enqueue scheduler '("task-A" . 1))
    (loom:scheduler-enqueue scheduler '("task-B" . 2))

    ;; Process all tasks by repeatedly advancing time
    (sit-for 0.001) ; Process first task
    (sit-for 0.001) ; Process second task
    (sit-for 0.001) ; Process third task

    ;; Verify order of processed tasks
    (should (equal (mapcar #'car test-processed-tasks)
                   '("task-A" "task-B" "task-C")))))

(ert-deftest loom-scheduler-stop-test ()
  "Tests `loom:scheduler-stop` to halt processing."
  (loom:clear-registry)
  (setq test-processed-tasks nil)
  (let* ((scheduler (loom:scheduler :name "stop-test"
                                    :process-fn #'test-process-fn
                                    :batch-size 1
                                    :adaptive-delay-p nil
                                    :min-delay 0.001)))
    (loom:scheduler-enqueue scheduler "task1")
    (loom:scheduler-enqueue scheduler "task2")

    ;; Process first batch
    (sit-for 0.001)
    (should (equal test-processed-tasks '("task1")))
    (setq test-processed-tasks nil)

    ;; Stop the scheduler before the next batch can be processed
    (loom:scheduler-stop scheduler)

    ;; Verify status reflects no timer and tasks still in queue
    (let ((status (loom:scheduler-status scheduler)))
      (should (eq (plist-get status :queue-length) 1))
      (should (not (plist-get status :has-timer-p))))

    ;; Try to force another tick, nothing should happen
    (sit-for 0.001)
    (should (null test-processed-tasks)) ; No new tasks processed
    (should (eq (plist-get (loom:scheduler-status scheduler)
                           :queue-length) 1))))

(ert-deftest loom-scheduler-drain-test ()
  "Tests `loom:scheduler-drain` for manual, single-batch processing."
  (loom:clear-registry)
  (setq test-processed-tasks nil)
  (let* ((scheduler (loom:scheduler :name "drain-test"
                                    :process-fn #'test-process-fn
                                    :batch-size 2
                                    :adaptive-delay-p nil
                                    :min-delay 0.001)))
    (loom:scheduler-enqueue scheduler "D1")
    (loom:scheduler-enqueue scheduler "D2")
    (loom:scheduler-enqueue scheduler "D3")
    (loom:scheduler-enqueue scheduler "D4")

    ;; Initially, timer should be active
    (should (plist-get (loom:scheduler-status scheduler) :has-timer-p))
    (should (eq (plist-get (loom:scheduler-status scheduler) :queue-length)
                4))

    ;; Drain the first batch
    (should (eq (loom:scheduler-drain scheduler) t))
    (should (equal test-processed-tasks '("D1" "D2")))
    (setq test-processed-tasks nil)

    ;; Timer should still be active, as `drain` doesn't stop it
    ;; if tasks remain.
    (should (plist-get (loom:scheduler-status scheduler) :has-timer-p))
    (should (eq (plist-get (loom:scheduler-status scheduler) :queue-length)
                2))

    ;; Drain the second batch
    (should (eq (loom:scheduler-drain scheduler) t))
    (should (equal test-processed-tasks '("D3" "D4")))
    (setq test-processed-tasks nil)

    ;; Queue empty, timer should now be inactive after its callback runs.
    ;; We need `sit-for` to allow the timer callback to run if it was scheduled
    ;; before `drain` emptied the queue.
    (sit-for 0.001)
    (should (eq (plist-get (loom:scheduler-status scheduler) :queue-length)
                0))
    (should (not (plist-get (loom:scheduler-status scheduler) :has-timer-p)))

    ;; Draining an empty queue should return nil and not process anything
    (should (eq (loom:scheduler-drain scheduler) nil))
    (should (null test-processed-tasks))))

(ert-deftest loom-scheduler-adaptive-delay-test ()
  "Tests the adaptive delay strategy.
Asserts that with many tasks, the scheduler attempts to run quickly
(minimum delay), and with few, it takes longer (maximum delay)."
  (loom:clear-registry)
  (setq test-processed-tasks nil)
  (let* ((scheduler (loom:scheduler :name "adaptive-test"
                                    :process-fn #'test-process-fn
                                    :batch-size 1 ; Process one by one to see delay changes
                                    :adaptive-delay-p t
                                    :min-delay 0.001
                                    :max-delay 0.1)) ; Smaller max for observation
         (delays nil))

    ;; Enqueue many tasks to trigger min-delay behavior
    (cl-dotimes (i 20)
      (loom:scheduler-enqueue scheduler (format "task-%d" i)))

    ;; Helper to force timer execution (simulates time passing)
    (cl-flet ((get-delay-and-process ()
                                     (let ((current-timer (loom-scheduler-timer scheduler)))
                                       (when (timerp current-timer)
                                         (let ((remaining-delay
                                                (timer-remaining-time current-timer)))
                                           (push remaining-delay delays)
                                           ;; Smallest tick to ensure timer fires
                                           (sit-for 0.0001)
                                           ;; Directly call the timer's function to simulate it firing
                                           (run-with-timer 0.0 current-timer nil
                                                           'call-timer-function
                                                           current-timer))))))

      ;; Process tasks and collect expected delays
      (dotimes (i 20) ; Process all 20 tasks
        (get-delay-and-process))
      (should (= (length test-processed-tasks) 20))
      (setq test-processed-tasks nil)

      ;; Now, with an empty queue, if we enqueue just one, the initial delay should be max
      (loom:scheduler-enqueue scheduler "single-task")
      (let* ((status (loom:scheduler-status scheduler))
             (scheduled-timer (plist-get status :has-timer-p)))
        (should scheduled-timer)
        ;; The timer's remaining time will be the *initial* delay when scheduled
        (should (approx-equal (timer-remaining-time
                               (loom-scheduler-timer scheduler))
                              0.1 0.005))) ; Max delay value
      ;; Process the single task
      (get-delay-and-process)
      (should (equal test-processed-tasks '("single-task"))))))

(ert-deftest loom-scheduler-invalid-scheduler-error-test ()
  "Tests that scheduler API functions signal errors for invalid objects."
  (should-error (loom:scheduler-enqueue nil "task")
                :type 'loom-invalid-scheduler-error)
  (should-error (loom:scheduler-stop "not-a-scheduler")
                :type 'loom-invalid-scheduler-error)
  (should-error (loom:scheduler-drain (cons 1 2))
                :type 'loom-invalid-scheduler-error)
  (should-error (loom:scheduler-status '(1 2 3))
                :type 'loom-invalid-scheduler-error))

(ert-deftest loom-scheduler-process-fn-error-test ()
  "Tests that errors in `process-fn` do not crash the scheduler.
The scheduler should log the error and continue processing."
  (loom:clear-registry)
  (let* ((error-count 0)
         (faulty-process-fn (lambda (batch)
                              (cl-incf error-count)
                              (error "Error in process-fn: %S" (car batch))))
         (scheduler (loom:scheduler :name "faulty-process"
                                    :process-fn #'faulty-process-fn
                                    :batch-size 1
                                    :adaptive-delay-p nil
                                    :min-delay 0.001)))
    (loom:scheduler-enqueue scheduler "bad-task-1")
    (loom:scheduler-enqueue scheduler "bad-task-2")

    ;; First tick: should encounter error but scheduler recovers
    ;; We catch the error that bubbles up to ERT, but the scheduler's
    ;; internal logic should ensure it doesn't halt.
    (condition-case err
        (sit-for 0.001)
      (error nil))

    (should (eq error-count 1)) ; Error handler was called once
    ;; Scheduler should still be active as tasks remain
    (should (plist-get (loom:scheduler-status scheduler) :has-timer-p))
    (should (eq (plist-get (loom:scheduler-status scheduler) :queue-length)
                1))

    ;; Second tick: another error
    (condition-case err
        (sit-for 0.001)
      (error nil))

    (should (eq error-count 2)) ; Error handler called twice
    (should (eq (plist-get (loom:scheduler-status scheduler) :queue-length)
                0))
    (should (not (plist-get (loom:scheduler-status scheduler) :has-timer-p)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-lock.el

(ert-deftest loom-lock-create-test ()
  "Test `loom:lock` creation with various modes and invalid input."
  (should (loom-lock-p (loom:lock "test-lock" :mode :deferred)))
  (when (fboundp 'make-mutex)
    (should (loom-lock-p (loom:lock "thread-lock" :mode :thread))))
  (should-error (loom:lock "bad-lock" :mode :invalid) :type 'error))

(ert-deftest loom-lock-acquire-release-test ()
  "Test basic lock acquisition and release functionality."
  (let ((lock (loom:lock)))
    (should-not (loom-lock-locked-p lock))
    (should (loom:lock-acquire lock))
    (should (loom-lock-locked-p lock))
    (should (loom:lock-release lock))
    (should-not (loom-lock-locked-p lock))))

(ert-deftest loom-lock-try-acquire-test ()
  "Test `loom:lock-try-acquire` for non-blocking behavior."
  (let ((lock (loom:lock)))
    (should (loom:lock-try-acquire lock))
    (should-not (loom:lock-try-acquire lock)) ; Should fail, already held
    (loom:lock-release lock)
    (should (loom:lock-try-acquire lock))))

(ert-deftest loom-with-mutex-test ()
  "Test the `loom:with-mutex!` macro, including error handling."
  (let ((lock (loom:lock)) (body-run-p nil))
    (loom:with-mutex! lock
      (setq body-run-p t)
      (should (loom-lock-locked-p lock)))
    (should body-run-p)
    (should-not (loom-lock-locked-p lock)))

    (let ((lock (loom:lock)))
      (should-error (loom:with-mutex! lock (error "test error")) :type 'error)
      (should-not (loom-lock-locked-p lock))))

(ert-deftest loom-lock-reentrancy-and-ownership-test ()
  "Test re-entrant acquisition and correct ownership rules."
  (let ((lock (loom:lock)) (owner-a "A") (owner-b "B") (error-caught nil))
    (should (loom:lock-acquire lock owner-a))
    (should (loom:lock-acquire lock owner-a)) ; Re-entrant acquire by same owner
    (should (= 2 (loom-lock-reentrant-count lock)))
    ;; Attempt to release by a different owner should fail
    (condition-case err
        (loom:lock-release lock owner-b)
      (loom-lock-unowned-release-error
       (setq error-caught t)))
    (should error-caught)
    (should (loom:lock-release lock owner-a)) ; First release
    (should (loom:lock-held-p lock))         ; Still held due to re-entrancy
    (should (loom:lock-release lock owner-a)) ; Second release
    (should-not (loom:lock-held-p lock))))

(loom-deftest loom-lock-deferred-contention-test ()
  "Test deferred lock acquisition order under contention (FIFO)."
  (let ((lock (loom:lock "deferred-lock" :mode :deferred))
        (order-list nil))
    (loom:lock-acquire lock "task-a") ; task-a acquires the lock
    ;; task-b requests the lock, deferred
    (loom:deferred (lambda ()
                     (loom:lock-acquire lock "task-b")
                     (push "task-b" order-list)
                     (loom:lock-release lock "task-b")))
    ;; task-c requests the lock, also deferred
    (loom:deferred (lambda ()
                     (loom:lock-acquire lock "task-c")
                     (push "task-c" order-list)
                     (loom:lock-release lock "task-c")))
    ;; Release the lock, allowing deferred tasks to contend
    (loom:lock-release lock "task-a")
    ;; Force schedulers to drain, allowing deferred tasks to run
    (when loom--macrotask-scheduler
      (loom:scheduler-drain loom--macrotask-scheduler)
      (loom:scheduler-drain loom--macrotask-scheduler))
    ;; Verify FIFO order of acquisition
    (should (equal '("task-c" "task-b") order-list))))

(ert-deftest loom-with-mutex-nested-test ()
  "Test nesting of `loom:with-mutex!` ensures correct lock handling."
  (let ((lock1 (loom:lock))
        (lock2 (loom:lock))
        (outer-body-run-p nil)
        (inner-body-run-p nil))
    (loom:with-mutex! lock1
      (setq outer-body-run-p t)
      (should (loom-lock-locked-p lock1))
      (loom:with-mutex! lock2 ; Nested mutex
        (setq inner-body-run-p t)
        (should (loom-lock-locked-p lock1))
        (should (loom-lock-locked-p lock2)))
      (should-not (loom-lock-locked-p lock2))) ; Inner lock released
    (should outer-body-run-p)
    (should inner-body-run-p)
    (should-not (loom-lock-locked-p lock1)))) ; Outer lock released

(ert-deftest loom-with-mutex-throw-catch-test ()
  "Test `loom:with-mutex!` releases lock even on non-error `throw`."
  (let ((lock (loom:lock)))
    (catch 'my-tag
      (loom:with-mutex! lock
        (should (loom-lock-locked-p lock))
        (throw 'my-tag "thrown-value")))
    (should-not (loom-lock-locked-p lock))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-cancel.el

(ert-deftest loom-cancel-token-create-test ()
  "Test `loom:cancel-token` creation and initial state."
  (let ((token (loom:cancel-token "my-token")))
    (should (loom-cancel-token-p token))
    (should (string= "my-token" (loom-cancel-token-name token)))
    (should-not (loom:cancel-token-cancelled-p token))
    (should (null (loom:cancel-token-reason token)))))

(loom-deftest loom-cancel-token-signal-test ()
  "Test `loom:cancel-token-signal` changes token state and is idempotent."
  (let ((token (loom:cancel-token)))
    (should (loom:cancel-token-signal token "signaled"))
    (should (loom:cancel-token-cancelled-p token))
    (should (string= "signaled"
                     (loom:error-message (loom:cancel-token-reason token))))
    ;; Signalling again should return nil and not change the reason
    (should (not (loom:cancel-token-signal token "again")))))

(loom-deftest loom-cancel-token-add-remove-callback-test ()
  "Test adding and removing cancellation callbacks correctly."
  ;; Test adding, removing, and then signaling (callback should not run)
  (let* ((token (loom:cancel-token))
         (run-count 0)
         (cb (lambda (_) (cl-incf run-count))))
    (loom:cancel-token-add-callback token cb)
    (should (loom:cancel-token-remove-callback token cb))
    (loom:cancel-token-signal token)
    (should (= 0 run-count)))

  ;; Test adding callback to an already signaled token (callback runs immediately)
  (let ((token2 (loom:cancel-token)) (cb-run-p nil))
    (loom:cancel-token-signal token2)
    (loom:cancel-token-add-callback token2 (lambda (_) (setq cb-run-p t)))
    ;; Force microtask scheduler drain, as callbacks are enqueued there
    (loom:microtask-drain loom--microtask-scheduler)
    (should cb-run-p)))

(ert-deftest loom-throw-if-cancelled-test ()
  "Test `loom:throw-if-cancelled!` behaves as expected."
  (let ((token (loom:cancel-token))
        (rejection-error nil))
    ;; Should not throw if not cancelled
    (should-not (loom:throw-if-cancelled token))
    ;; Signal cancellation
    (loom:cancel-token-signal token "was-cancelled")
    ;; Should throw `loom-cancel-error` if cancelled
    (condition-case err
        (loom:throw-if-cancelled token)
      (loom-cancel-error
       (setq rejection-error (cadr err))))
    (should (string-match-p "was-cancelled"
                            (loom:error-message rejection-error)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-primitives.el and loom-promise.el

(loom-deftest loom-core-promise-constructor-test ()
  "Test the `loom:promise` constructor and its options."
  ;; Basic pending promise
  (let ((p (loom:promise)))
    (should (loom-promise-p p))
    (should (eq :pending (loom:status p))))

  ;; Resolved promise via executor
  (let ((p (loom:promise :executor (lambda (resolve _)
                                     (funcall resolve "done")))))
    (should (eq :resolved (loom:status p)))
    (should (string= "done" (loom:value p))))

  ;; Rejected promise via executor
  (let ((p (loom:promise :executor (lambda (_ r) (funcall r "fail")))))
    (should (eq :rejected (loom:status p)))
    (should (string-match-p "fail"
                            (loom:error-message (loom:error-value p)))))

  ;; Executor throwing an error should reject the promise
  (let ((p (loom:promise :executor (lambda (_r _j) (error "executor crash")))))
    (should (eq :rejected (loom:status p)))
    (should (string-match-p "executor crash"
                            (loom:error-message (loom:error-value p))))))

(loom-deftest loom-core-resolve-with-promise-test ()
  "Test promise adoption via `loom:resolve` (Promise/A+ Spec 2.3)."
  ;; Adopt a resolved promise
  (let ((p-outer (loom:promise))
        (p-inner (loom:resolved! "inner value")))
    (loom:resolve p-outer p-inner)
    (should (string= "inner value" (loom:await p-outer))))

  ;; Adopt a rejected promise
  (let* ((p-outer (loom:promise))
         (p-inner (loom:rejected! "inner error"))
         (rejection-error nil))
    (loom:resolve p-outer p-inner)
    (condition-case err (loom:await p-outer)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string-match-p "inner error" (loom:error-message rejection-error))))

  ;; Adopt a pending promise (should wait for inner to settle)
  (let ((p-outer (loom:promise))
        (p-inner (loom:promise)))
    (loom:resolve p-outer p-inner)
    (should (loom:pending-p p-outer))
    (loom:resolve p-inner "async value")
    (should (string= "async value" (loom:await p-outer))))

  ;; Self-resolution (cycle detection) should reject
  (let ((p (loom:promise)))
    (loom:resolve p p)
    (should (loom:rejected-p p))
    (should (string-match-p "cycle detected" (loom:error-message p)))))

(loom-deftest loom-then-on-resolved-test ()
  "Test the `on-resolved` handler of `loom:then`."
  (let* ((p1 (loom:resolved! 10))
         (p2 (loom:then p1 (lambda (v) (* v 2)))))
    (should (= 20 (loom:await p2)))))

(loom-deftest loom-then-on-rejected-test ()
  "Test the `on-rejected` handler of `loom:then`."
  (let* ((p1 (loom:rejected! "error"))
         (p2 (loom:then p1
                        (lambda (_v) "not called") ; This handler should be skipped
                        (lambda (_e) "caught"))))
    (should (string= "caught" (loom:await p2)))))

(loom-deftest loom-catch-test ()
  "Test `loom:catch` for handling rejections and passing resolved values."
  ;; Catching a rejected promise
  (let* ((p1 (loom:rejected! "error"))
         (p2 (loom:catch p1 (lambda (_e) "caught error"))))
    (should (string= "caught error" (loom:await p2))))
  ;; Resolved promise should pass through untouched
  (let* ((p1 (loom:resolved! 100))
         (p2 (loom:catch p1 (lambda (_e) "not called"))))
    (should (= 100 (loom:await p2)))))

(loom-deftest loom-finally-test ()
  "Test `loom:finally` runs for both resolved and rejected paths."
  ;; Resolved path
  (let ((finally-run-p nil) (p (loom:resolved! "ok")))
    (let ((p-final (loom:finally p (lambda () (setq finally-run-p t)))))
      (should (string= "ok" (loom:await p-final)))
      (should finally-run-p)))

  ;; Rejected path
  (let ((finally-run-p nil) (rejection-error nil)
        (p (loom:rejected! (loom:make-error :message "err"))))
    (let ((p-final (loom:finally p (lambda () (setq finally-run-p t)))))
      (condition-case err (loom:await p-final)
        (loom-await-error (setq rejection-error (cadr err))))
      (should (string-match-p "err" (loom:error-message rejection-error)))
      (should finally-run-p))))

(loom-deftest loom-promise-chaining-and-adoption-test ()
  "Test more complex promise chaining and state adoption."
  ;; Chain where a handler returns a delayed promise (adoption)
  (let* ((p1 (loom:resolved! 5))
         (p2 (loom:then p1 (lambda (v) (loom:delay 0.01 (* v 10))))))
    (should (= 50 (loom:await p2))))

  ;; Promise resolved with another rejected promise (adoption)
  (let* ((p-inner (loom:rejected! (loom:make-error :message "inner error")))
         (p-outer (loom:promise))
         (rejection-error nil))
    (loom:resolve p-outer p-inner)
    (condition-case err (loom:await p-outer)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string= "inner error" (loom:error-message rejection-error)))))

(loom-deftest loom-promise-handler-errors-test ()
  "Test when a promise handler itself throws an error.
Ensures the resulting promise rejects, and `loom:catch` can handle it."
  (let* ((p1 (loom:resolved! 10))
         (p2 (loom:then p1 (lambda (_v) (error "fail in then"))))
         (p3 (loom:catch p2 (lambda (e) (loom:error-message e)))))
    (should (string-match-p "fail in then" (loom:await p3)))))

(loom-deftest loom-promise-async-resolution-test ()
  "Test asynchronous promise resolution using `loom:deferred`."
  (let* ((p (loom:promise)))
    (loom:deferred (lambda () (loom:resolve p 100)))
    (should (= 100 (loom:await p)))
    (should (loom:resolved-p p))))

(loom-deftest loom-promise-async-rejection-test ()
  "Test asynchronous promise rejection using `loom:deferred`."
  (let ((p (loom:promise)) (rejection-error nil))
    (loom:deferred (lambda ()
                     (loom:reject p (loom:make-error :message "async-fail"))))
    (condition-case err (loom:await p)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string= "async-fail" (loom:error-message rejection-error)))
    (should (loom:rejected-p p))))

(loom-deftest loom-then-lexical-capture-resolved ()
  "Tests that `loom:then`'s `on-resolved` handler correctly captures and
interacts with variables from its lexical environment."
  (let ((outer-resolved-val 0)
        (captured-string "initial"))
    ;; Create a promise that resolves immediately
    (let* ((p1 (loom:resolved! 5))
           ;; Attach an on-resolved handler that modifies outer-resolved-val
           ;; and uses captured-string from the surrounding lexical scope.
           (p2 (loom:then p1
                          (lambda (val)
                            (setq outer-resolved-val (+ outer-resolved-val val 10))
                            (setq captured-string
                                  (concat captured-string "-modified"))
                            ;; Return a value that we can await
                            (list outer-resolved-val captured-string)))))
      ;; Await the result of the chain to ensure the handler executed
      (let ((result (loom:await p2)))
        ;; Verify that the outer variable was modified
        (should (eq outer-resolved-val 15)) ; 0 + 5 + 10 = 15
        ;; Verify that the captured string was modified
        (should (string= captured-string "initial-modified"))
        ;; Verify the value returned by the handler
        (should (equal result '(15 "initial-modified")))))))

(loom-deftest loom-then-lexical-capture-rejected ()
  "Tests that `loom:then`'s `on-rejected` handler correctly captures and
interacts with variables from its lexical environment."
  (let ((outer-rejection-flag nil)
        (captured-error-message ""))
    ;; Create a promise that rejects immediately
    (let* ((p1 (loom:rejected! (loom:make-error :message "Test error")))
           ;; Attach an on-rejected handler that sets outer-rejection-flag
           ;; and captures the error message into captured-error-message.
           (p2 (loom:then p1
                          (lambda (val) (error "Should not resolve: %S" val)) ; Skipped
                          (lambda (err)
                            (setq outer-rejection-flag t)
                            (setq captured-error-message
                                  (loom:error-message err))
                            ;; Return a value on rejection to make the chain resolve
                            (concat "Handled: " (loom:error-message err))))))
      ;; Await the result of the chain (should resolve with handler's return)
      (let ((result (loom:await p2)))
        ;; Verify that the outer flag was set
        (should (eq outer-rejection-flag t))
        ;; Verify that the captured error message is correct
        (should (string= captured-error-message "Test error"))
        ;; Verify the value returned by the handler
        (should (string= result "Handled: Test error"))))))

(loom-deftest loom-then-lexical-capture-chained-scope ()
  "Tests lexical capture across multiple `loom:then` calls in a chain.
Ensures variables from the original lexical scope are accessible by
subsequent handlers in the same logical chain and reflect updates."
  (let ((global-counter 100)
        (status-log nil))
    (setq status-log (list (format "Initial global-counter: %s" global-counter)))

    (let* ((p1 (loom:resolved! 1))
           ;; First then: modifies global-counter and adds to status-log
           (p2 (loom:then p1
                          (lambda (val)
                            (setq global-counter (+ global-counter val))
                            (push (format "After p1: %s" global-counter)
                                  status-log)
                            (1+ val)))) ; Pass 2 to the next handler
           ;; Second then: modifies global-counter again,
           ;; and appends to status-log.
           (p3 (loom:then p2
                          (lambda (val)
                            (setq global-counter (+ global-counter (* val 10)))
                            (push (format "After p2: %s" global-counter)
                                  status-log)
                            val))))
      ;; Await the final promise in the chain
      (loom:await p3)
      ;; Verify the final state of global-counter (100 + 1 + (2 * 10) = 121)
      (should (eq global-counter 121))
      ;; Verify the order and content of the status log
      (should (equal (nreverse status-log)
                     '("Initial global-counter: 100"
                       "After p1: 101"
                       "After p2: 121"))))))

(loom-deftest loom-then-lexical-capture-isolated-chains ()
  "Tests that separate `loom:then` chains correctly capture their own
lexical environments and don't interfere with each other."
  (let ((chain1-result 0)
        (chain2-result 0)
        (common-prefix "Prefix:"))
    ;; First chain modifies `chain1-result`
    (let* ((p-a (loom:resolved! 10))
           (p-b (loom:then p-a
                           (lambda (val)
                             (setq chain1-result (+ val 1))
                             (concat common-prefix
                                     (number-to-string chain1-result))))))
      (should (string= (loom:await p-b) "Prefix:11")))

    ;; Second, independent chain modifies `chain2-result`
    (let* ((p-x (loom:resolved! 20))
           (p-y (loom:then p-x
                           (lambda (val)
                             (setq chain2-result (+ val 2))
                             (concat common-prefix
                                     (number-to-string chain2-result))))))
      (should (string= (loom:await p-y) "Prefix:22")))

    ;; Verify that the results reflect independent captures
    (should (eq chain1-result 11))
    (should (eq chain2-result 22))
    ;; Verify common-prefix remains unchanged
    (should (string= common-prefix "Prefix:"))))

(loom-deftest loom-then-mixed-timing-chain-test ()
  "Test `loom:then` with a mix of immediate and delayed promises."
  (loom:clear-registry)
  ;; Scenario 1: Immediate -> Delayed -> Immediate
  (let* ((p1 (loom:resolved! 1))
         (p2 (loom:then p1 (lambda (v) (loom:delay 0.01 (+ v 1)))))
         (p3 (loom:then p2 (lambda (v) (* v 2)))))
    (should (= 4 (loom:await p3))))

  ;; Scenario 2: Delayed -> Immediate -> Delayed
  (let* ((p1 (loom:delay 0.01 1))
         (p2 (loom:then p1 (lambda (v) (+ v 1))))
         (p3 (loom:then p2 (lambda (v) (loom:delay 0.01 (* v 2))))))
    (should (= 4 (loom:await p3)))))

(loom-deftest loom-error-propagation-deep-chain-test ()
  "Test error propagation through a deep promise chain."
  (let* ((p1 (loom:resolved! 1))
         (p2 (loom:then p1 (lambda (_v) (/ 1 0)))) ; This will throw an error
         (p3 (loom:then p2 (lambda (_v) "should not run"))) ; Skipped
         (rejection-error nil))
    (condition-case err (loom:await p3)
      (loom-await-error (setq rejection-error (cadr err))))
    (let* ((original-cause (loom:error-cause rejection-error))
           (error-type (car original-cause)))
      (should (eq 'arith-error error-type)))))

(loom-deftest loom-thread-mode-basic-resolve-test ()
  "Tests that a simple promise created with `:mode :thread` can be
resolved in a background thread and awaited on the main thread."
  (when (fboundp 'make-thread) ; Only run if Emacs supports threads
    (let ((p (loom:promise
              :mode :thread
              :executor (lambda (resolve _reject)
                          ;; This code is ALREADY running in a background thread.
                          ;; No need to call make-thread here.
                          (message "hello world-------------->")
                          (sleep-for 0.05) ; Simulate work in thread
                          (message "resolving using %s" resolve)
                          (funcall resolve 42)))))
      ;; Await the promise, with a timeout
      (should (equal 42 (loom:await p 4.0))))))

(loom-deftest loom-thread-mode-basic-resolve-test-foo ()
  "Tests that a simple promise created with `:mode :thread` can be
resolved in a background thread and awaited on the main thread."
  (when (fboundp 'make-thread) ; Only run if Emacs supports threads
    (let* ((p (loom:promise
               :mode :thread
               :executor (lambda (resolve _reject)
                           (make-thread
                            (lambda ()
                              (message "hello world-------------->")
                              (sleep-for 0.05) ; Simulate work in thread
                              (message "resolving using %s" resolve)
                              (funcall resolve 42)))))))
      ;; Await the promise, with a timeout
      (should (equal 42 (loom:await p 2.0))))))

(loom-deftest loom-thread-mode-basic-reject-test ()
  "Tests that a promise in `:mode :thread` correctly propagates a
rejection from a background thread to the main thread."
  (when (fboundp 'make-thread)
    (let* ((p (loom:promise
               :mode :thread
               :executor (lambda (_resolve reject)
                           (make-thread
                            (lambda ()
                              (sleep-for 0.05)
                              (funcall reject
                                       (loom:make-error
                                        :type :test-error
                                        :message "Thread failure"))))))))
      ;; We expect `loom:await` to signal a `loom-await-error`
      (should-error (loom:await p 1.0) :type 'loom-await-error))))

(loom-deftest loom-thread-mode-concurrent-resolve-test ()
  "Stress-tests the thread IPC by launching multiple threads that
resolve promises concurrently. Uses `loom:all` to wait for completion."
  (when (fboundp 'make-thread)
    (let* ((num-threads 5)
           (promises (cl-loop for i from 0 below num-threads
                              collect
                              (loom:promise
                               :mode :thread
                               :executor
                               (let ((val i)) ; Capture value for closure
                                 (lambda (resolve _reject)
                                   (make-thread
                                    (lambda ()
                                      (sleep-for (* 0.02 (1+ val)))
                                      (funcall resolve val)))))))))
      ;; `loom:all` will create a new promise that resolves when all
      ;; promises in the list have resolved.
      (let ((all-promise (loom:all promises)))
        (should (equal '(0 1 2 3 4) (loom:await all-promise 2.0)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-combinators.el

(loom-deftest loom-all-test ()
  "Test `loom:all` for success and fail-fast behavior."
  ;; All promises resolve successfully
  (let ((p (loom:all (list (loom:resolved! 1) "two" (loom:delay 0.01 3)))))
    (should (equal '(1 "two" 3) (loom:await p))))
  ;; One promise rejects, `loom:all` should reject immediately
  (let ((p (loom:all (list (loom:delay 0.02 1)
                           (loom:rejected! (loom:make-error :message "fail")))))
        (rejection-error nil))
    (condition-case err (loom:await p)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string= "fail" (loom:error-message rejection-error)))))

(loom-deftest loom-race-test ()
  "Test `loom:race` for the first promise to settle (resolve or reject)."
  ;; First to resolve wins
  (let ((p (loom:race (list (loom:delay 0.05 "slow")
                            (loom:delay 0.01 "fast")))))
    (should (equal "fast" (loom:await p))))
  ;; First to reject wins
  (let ((p (loom:race (list (loom:delay 0.05 "slow")
                            (loom:rejected! (loom:make-error :message "fail")))))
        (rejection-error nil))
    (condition-case err (loom:await p)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string= "fail" (loom:error-message rejection-error)))))

(loom-deftest loom-any-test ()
  "Test `loom:any` for the first fulfillment, or aggregate rejection."
  ;; First fulfillment wins
  (let ((p (loom:any (list (loom:rejected! "e1")
                           (loom:delay 0.01 "ok")))))
    (should (equal "ok" (loom:await p))))
  ;; All promises reject, `loom:any` should return an aggregate error
  (let* ((p (loom:any (list (loom:rejected! "e1")
                            (loom:rejected! "e2"))))
         (aggregate-error nil))
    (condition-case err (loom:await p)
      (loom-await-error (setq aggregate-error (cadr err))))
    (should (eq :aggregate-error (loom-error-type aggregate-error)))
    (let ((causes (loom:error-cause aggregate-error)))
      (should (= 2 (length causes)))
      (should (string= "e1" (loom:error-message (nth 0 causes))))
      (should (string= "e2" (loom:error-message (nth 1 causes)))))))

(loom-deftest loom-all-settled-test ()
  "Test `loom:all-settled` returns status for all promises,
regardless of fulfillment or rejection."
  (let* ((p1 (loom:resolved! "ok"))
         (p2 (loom:rejected! (loom:make-error :message "fail")))
         (p (loom:all-settled (list p1 p2))))
    (let* ((results (loom:await p))
           (first-outcome (nth 0 results))
           (second-outcome (nth 1 results)))
      (should (= 2 (length results)))
      (should (eq 'fulfilled (plist-get first-outcome :status)))
      (should (equal "ok" (plist-get first-outcome :value)))
      (should (eq 'rejected (plist-get second-outcome :status)))
      (should (string= "fail"
                       (plist-get second-outcome :reason))))))

(loom-deftest loom-any-mixed-success-rejection-test ()
  "Test `loom:any` with mixed successes and rejections,
including delayed ones."
  (cl-flet ((loom-test-delayed-rejected (delay-seconds error-value)
             (loom:promise
              :executor (lambda (_resolve reject)
                          (run-at-time delay-seconds nil
                                       (lambda () (funcall reject
                                                           (loom:make-error
                                                            :message error-value))))))))
    ;; One of the successes comes in first
    (let ((p (loom:any (list (loom:rejected! "e1")
                             (loom:delay 0.02 "s1")
                             (loom:rejected! "e2")
                             (loom:delay 0.01 "s2")))))
      (should (equal "s2" (loom:await p))))
    ;; All promises reject, expect aggregate error
    (let* ((p (loom:any (list (loom-test-delayed-rejected 0.02 "e1")
                              (loom-test-delayed-rejected 0.01 "e2"))))
           (aggregate-error nil))
      (condition-case err (loom:await p)
        (loom-await-error (setq aggregate-error (cadr err))))
      (should (eq :aggregate-error (loom-error-type aggregate-error)))
      (let ((causes (loom:error-cause aggregate-error)))
        (should (= 2 (length causes)))
        (should (string= "e1" (loom:error-message (nth 0 causes))))
        (should (string= "e2" (loom:error-message (nth 1 causes))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: Collection Combinators

(loom-deftest loom-map-test ()
  "Test `loom:map` for parallel mapping over a list."
  ;; Test with synchronous function
  (let ((p (loom:map '(1 2 3) (lambda (x) (* x 2)))))
    (should (equal '(2 4 6) (loom:await p))))
  ;; Test with asynchronous function (parallel execution implied)
  (let ((p (loom:map '(1 2 3) (lambda (x) (loom:delay 0.01 (* x 10))))))
    (should (equal '(10 20 30) (loom:await p))))
  ;; Test rejection propagation
  (let ((p (loom:map '(1 2 3) (lambda (x)
                                (if (= x 2)
                                    (loom:rejected! "fail")
                                  x))))
        (rejection-error nil))
    (condition-case err (loom:await p)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string= "fail" (loom:error-message rejection-error))))
  ;; Test with empty list
  (let ((p (loom:map '() #'identity)))
    (should (equal '() (loom:await p)))))

(loom-deftest loom-reduce-test ()
  "Test `loom:reduce` for asynchronous sequential reduction."
  ;; Test with synchronous reducer
  (let ((p (loom:reduce '(1 2 3) #'+ 0)))
    (should (= 6 (loom:await p))))
  ;; Test with asynchronous reducer
  (let ((p (loom:reduce '(1 2 3)
                        (lambda (acc item)
                          (loom:delay 0.01 (+ acc item)))
                        10)))
    (should (= 16 (loom:await p))))
  ;; Test rejection propagation
  (let ((p (loom:reduce '(1 2 3)
                        (lambda (acc item)
                          (if (= item 2)
                              (loom:rejected! "fail")
                            (+ acc item)))
                        0))
        (rejection-error nil))
    (condition-case err (loom:await p)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string= "fail" (loom:error-message rejection-error)))))

(loom-deftest loom-map-series-test ()
  "Test `loom:map-series` for sequential asynchronous mapping."
  ;; Successful sequential execution
  (let ((order '())
        (p (loom:map-series '(a b c)
                            (lambda (item)
                              (loom:then (loom:delay 0.01)
                                         (lambda (_)
                                           (push item order) item))))))
    (should (equal '(a b c) (loom:await p)))
    (should (equal '(c b a) order)))
  ;; Rejection propagation (should stop after first failure)
  (let ((order '())
        (rejection-error nil)
        (p (loom:map-series '(a b c)
                            (lambda (item)
                              (push item order)
                              (if (eq item 'b)
                                  (loom:rejected! "fail")
                                item))))) ; Keep item as return value
    (condition-case err (loom:await p)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string= "fail" (loom:error-message rejection-error)))
    (should (equal '(b a) order))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-registry.el

(loom-deftest loom-registry-find-and-list-test ()
  "Test basic promise registration and filtering by name/status/tags."
  (let ((loom-enable-promise-registry t)) ; Ensure registry is enabled
    (unwind-protect
        (progn
          (loom:clear-registry)
          (let ((p1 (loom:promise :name "Promise-A" :tags '(:db)))
                (p2 (loom:promise :name "Promise-B" :tags '(:ui))))
            (loom:resolve p1 "done") ; p1 becomes resolved
            (should (= 2 (length (loom:list-promises))))
            (should (eq p1 (loom:find-promise "Promise-A")))
            (should (eq p1 (car (loom:list-promises :status :resolved))))
            (should (eq p2 (car (loom:list-promises :tags :ui))))))
      (loom:clear-registry)))) ; Cleanup

(loom-deftest loom-registry-eviction-policy-test ()
  "Verify that the oldest promise is evicted when max size is reached."
  (let ((loom-enable-promise-registry t)
        (loom-registry-max-size 2)) ; Set max size to 2 for easy testing
    (unwind-protect
        (progn
          (loom:clear-registry)
          (let ((p1 (loom:promise :name "oldest"))  ; First added (will be evicted)
                (_  (sit-for 0.01))                  ; Simulate time passing
                (p2 (loom:promise :name "middle"))
                (_  (sit-for 0.01))
                (p3 (loom:promise :name "newest"))) ; Third added (evicts p1)
            (should (= 2 (length (loom:list-promises))))
            (should (null (loom:find-promise "oldest"))) ; Should be evicted
            (should (eq p2 (loom:find-promise "middle")))
            (should (eq p3 (loom:find-promise "newest")))))
      ;; Reset registry settings to default after test
      (loom:clear-registry)
      (setq loom-registry-max-size
            (default-value 'loom-registry-max-size)))))

(loom-deftest loom-registry-combined-filtering-test ()
  "Test `loom:list-promises` with combined status and tag filters."
  (let ((loom-enable-promise-registry t))
    (unwind-protect
        (progn
          (loom:clear-registry)
          (let* ((p1 (loom:resolved! "data" :name "DB-Resolved" :tags '(:db :read)))
                 (p2 (loom:promise :name "UI-Pending" :tags '(:ui)))
                 (p3 (loom:rejected! (loom:make-error :message "API-Failed")
                                     :name "API-Rejected" :tags '(:api :write)))
                 (rejection-error nil))
            ;; Ensure promises are settled for status filtering
            (loom:await p1)
            (condition-case err (loom:await p3)
              (loom-await-error (setq rejection-error (cadr err))))
            (should (string-match-p "API-Failed"
                                    (loom:error-message rejection-error)))
            ;; Combined filters
            (should (= 1 (length (loom:list-promises :status :resolved
                                                     :tags :db))))
            (should (eq p1 (car (loom:list-promises :status :resolved
                                                    :tags :db))))
            (should (= 1 (length (loom:list-promises :status :pending
                                                     :tags :ui))))
            (should (eq p2 (car (loom:list-promises :status :pending
                                                    :tags :ui))))
            (should (= 1 (length (loom:list-promises :status :rejected
                                                     :tags :api))))
            (should (eq p3 (car (loom:list-promises :status :rejected
                                                    :tags :api))))))
      (loom:clear-registry))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-future.el

(loom-deftest loom-future-creation-lazy-evaluation-test ()
  "Test `loom:future` creates a lazy future; thunk runs only on force."
  (let* ((thunk-ran-p nil)
         (future (loom:future (lambda () (setq thunk-ran-p t) 42))))
    (should (loom-future-p future))
    (should-not (loom-future-evaluated-p future)) ; Not evaluated yet
    (should-not thunk-ran-p)                     ; Thunk not run yet
    (should (= 42 (loom:await future)))          ; Forcing evaluation
    (should (loom-future-evaluated-p future))   ; Now evaluated
    (should thunk-ran-p)                         ; Thunk has run
    (setq thunk-ran-p nil)                       ; Reset for re-evaluation check
    (should (= 42 (loom:await future)))          ; Awaiting again
    (should-not thunk-ran-p)))                   ; Thunk should not run again (idempotent)

(defvar loom-test--execution-count 0
  "Dynamic variable for tracking thunk executions in future tests.")

(loom-deftest loom-force-idempotency-thread-safety-test ()
  "Test `loom:force` ensures single thunk execution even with concurrent
calls, leveraging thread safety."
  (when (fboundp 'make-thread) ; Only run if Emacs supports threads
    ;; Bind the dynamic variable for an isolated test run.
    (let ((loom-test--execution-count 0)
          (completion-promises (list (loom:promise) (loom:promise)
                                     (loom:promise)))
          (future (loom:future (lambda ()
                                 ;; The thunk now increments the dynamic var.
                                 (cl-incf loom-test--execution-count)
                                 (sleep-for 0.01) ; Simulate some work
                                 "done")
                               :mode :thread))) ; Force thread mode for concurrency
      ;; Start multiple threads that all force the same future.
      (dotimes (i 3)
        (make-thread (lambda ()
                       (unwind-protect
                           (loom:await future) ; Each thread tries to force
                         (loom:resolve (nth i completion-promises) t)))))
      ;; Wait for all threads to finish attempting to force the future.
      (loom:await (loom:all completion-promises))
      ;; The thunk should only have executed once, despite multiple calls.
      (should (= 1 loom-test--execution-count)))))

(loom-deftest loom-force-thunk-returns-promise-test ()
  "Test `loom:force` correctly handles a thunk returning a promise
(promise adoption)."
  (let* ((inner-promise (loom:promise)) ; A pending promise
         (future (loom:future (lambda () inner-promise)))) ; Thunk returns it
    (let ((force-promise (loom:force future)))
      (should (loom:pending-p force-promise)) ; Still pending, waiting for inner
      (loom:resolve inner-promise "inner-value") ; Resolve the inner promise
      (should (string= "inner-value" (loom:await force-promise)))))) ; Now resolved

(loom-deftest loom-force-thunk-error-test ()
  "Test `loom:force` propagates errors signaled by the thunk."
  (let ((future (loom:future (lambda () (error "Thunk failed!"))))
        (rejection-error nil))
    (condition-case err (loom:await future) ; Forcing execution and awaiting
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string-match-p "Thunk failed!"
                            (loom:error-message rejection-error)))))

(loom-deftest loom-future-get-test ()
  "Test `loom:future-get` for blocking retrieval and timeouts."
  ;; Successful blocking retrieval
  (let ((future (loom:future (lambda () (sleep-for 0.01) 100))))
    (should (= 100 (loom:future-get future)))
    (should (loom-future-evaluated-p future)))

  ;; Blocking retrieval with error
  (let ((future (loom:future (lambda () (error "Sync fail"))))
        (rejection-error nil))
    (condition-case err (loom:future-get future)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string-match-p "Sync fail" (loom:error-message rejection-error))))

  ;; Blocking retrieval with timeout
  (let ((future (loom:future (lambda () (sleep-for .02) "too slow")))
        (timeout-error nil))
    (condition-case err (loom:future-get future 0.01)
      (loom-timeout-error (setq timeout-error (cadr err))))
    (should timeout-error)
    (should (string-match-p "timed out" (loom:error-message timeout-error)))))

(loom-deftest loom-future-resolved!-test ()
  "Test `loom:future-resolved!` creates an already resolved future."
  (let ((future (loom:future-resolved! "pre-resolved-value")))
    (should (loom-future-evaluated-p future))
    (should (loom:resolved-p (loom-future-promise future)))
    (should (string= "pre-resolved-value" (loom:await future)))))

(loom-deftest loom-future-rejected!-test ()
  "Test `loom:future-rejected!` creates an already rejected future."
  (let ((future (loom:future-rejected!
                 (loom:make-error :message "pre-rejected")))
        (rejection-error nil))
    (should (loom-future-evaluated-p future))
    (should (loom:rejected-p (loom-future-promise future)))
    (condition-case err (loom:await future)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string-match-p "pre-rejected" (loom:error-message rejection-error)))))

(loom-deftest loom-future-delay-test ()
  "Test `loom:future-delay`'s lazy nature and correct timing."
  (let* ((start-time (float-time))
         (future (loom:future-delay 0.02 "delayed-value"))
         (before-force-time (float-time)))
    ;; Verify lazy: no delay before `loom:await` (which forces it)
    (should (< (- before-force-time start-time) 0.01))
    (should (string= "delayed-value" (loom:await future)))
    (let ((after-await-time (float-time)))
      ;; Verify delay happened after `loom:await`
      (should (>= (- after-await-time start-time) 0.019)))))

(loom-deftest loom-future-then-test ()
  "Test `loom:future-then` for lazy chaining and error propagation."
  ;; Successful chaining
  (let* ((future1 (loom:future (lambda () 5)))
         (future2 (loom:future-then future1 (lambda (v) (* v 2))))
         (future3 (loom:future-then future2 (lambda (v) (1+ v)))))
    (should (= 11 (loom:await future3)))
    ;; All futures should be evaluated after awaiting the last one
    (should (loom-future-evaluated-p future1))
    (should (loom-future-evaluated-p future2))
    (should (loom-future-evaluated-p future3)))

  ;; Error propagation in chain
  (let* ((future1 (loom:future (lambda () (error "Chain fail"))))
         (future2 (loom:future-then future1 (lambda (_v) "should not run")))
         (rejection-error nil))
    (condition-case err (loom:await future2)
      (loom-await-error (setq rejection-error (cadr err))))
    (should (string-match-p "Chain fail" (loom:error-message rejection-error)))))

(loom-deftest loom-future-catch-test ()
  "Test `loom:future-catch` for error recovery in futures."
  ;; Catching an error
  (let* ((f-error (loom:future (lambda () (error "Future error"))))
         (f-caught (loom:future-catch
                    f-error
                    (lambda (e)
                      (format "Caught: %s" (cadr (loom:error-cause e)))))))
    (should (string-match-p "Caught: Future error" (loom:await f-caught))))

  ;; Resolved future should pass through `future-catch`
  (let* ((f-resolved (loom:future-resolved! 100))
         (f-passed (loom:future-catch
                    f-resolved
                    (lambda (_e) "should not catch"))))
    (should (= 100 (loom:await f-passed)))))

(defvar loom-test--thunk-run-count-for-future-all 0
  "Temporary dynamic variable for `loom-future-all-test` to track thunk runs.")

(loom-deftest loom-future-all-test ()
  "Test `loom:future-all` combines futures lazily and correctly."
  (let ((f1 (loom:future (lambda ()
                           (cl-incf loom-test--thunk-run-count-for-future-all)
                           1)))
        (f2 (loom:future (lambda ()
                           (cl-incf loom-test--thunk-run-count-for-future-all)
                           (loom:delay 0.01 2))))
        (f3 (loom:future-resolved! 3)))
    (let ((loom-test--thunk-run-count-for-future-all 0)) ; Reset for test
      (let ((combined-future (loom:future-all (list f1 f2 f3))))
        ;; Futures are lazy, so thunks should not have run yet (except f3)
        (should (= 0 loom-test--thunk-run-count-for-future-all))
        (should-not (loom-future-evaluated-p f1))
        (should (loom-future-evaluated-p f3)) ; f3 is already resolved, so evaluated
        ;; Awaiting forces evaluation
        (should (equal '(1 2 3) (loom:await combined-future)))
        ;; f1 and f2 thunks should have run once each
        (should (= 2 loom-test--thunk-run-count-for-future-all))
        (should (loom-future-evaluated-p f1))
        (should (loom-future-evaluated-p f2))))))

(loom-deftest loom-future-all-error-test ()
  "Test `loom:future-all` fails fast when one future rejects."
  (let* ((f1 (loom:future-delay 0.02 "slow"))
         (f2 (loom:future (lambda () (error "Error in future 2"))))
         (f3 (loom:future-delay 0.01 "faster-ok"))
         (rejection-error nil))
    (let ((combined-future (loom:future-all (list f1 f2 f3))))
      (condition-case err (loom:await combined-future)
        (loom-await-error (setq rejection-error (cadr err))))
      (should (string-match-p "Error in future 2"
                              (loom:error-message rejection-error))))))

(loom-deftest loom-future-status-test ()
  "Test `loom:future-status` provides correct introspection."
  ;; Pending future status
  (let ((pending-future (loom:future (lambda () (loom:delay 0.01 "done")))))
    (let ((status (loom:future-status pending-future)))
      (should-not (plist-get status :evaluated-p))
      (should (eq :deferred (plist-get status :mode)))
      (should (null (plist-get status :promise-status))))) ; Promise not created yet

  ;; Resolved future status
  (let ((resolved-future (loom:future (lambda () 123))))
    (loom:force resolved-future) ; Force evaluation
    (let ((status (loom:future-status resolved-future)))
      (should (plist-get status :evaluated-p))
      (should (eq :resolved (plist-get status :promise-status)))
      (should (= 123 (plist-get status :promise-value)))
      (should (null (plist-get status :promise-error)))))

  ;; Rejected future status
  (let ((rejected-future (loom:future (lambda () (error "Test rejection")))))
    (condition-case err (loom:await rejected-future) ; Force and await rejection
      (loom-await-error
       (let* ((status (loom:future-status rejected-future))
              (promise-err (plist-get status :promise-error)))
         (should (plist-get status :evaluated-p))
         (should (string-match-p "Test rejection"
                                 (loom:error-message promise-err))))))))

(loom-deftest loom-future-normalize-awaitable-hook-test ()
  "Test futures are correctly normalized by `loom:await` via internal hook.
This confirms `loom:await` knows how to handle future objects."
  (let ((future (loom:future (lambda ()
                               (sleep-for 0.01) "Hello from future"))))
    (should (string= "Hello from future" (loom:await future)))))

(loom-deftest loom-future-mode-propagation-test ()
  "Test that the `mode` setting propagates from future to its underlying
promise upon evaluation."
  (when (fboundp 'make-mutex) ; Requires thread support for `:thread` mode
    (let ((f-deferred (loom:future (lambda () 1) :mode :deferred))
          (f-thread (loom:future (lambda () 2) :mode :thread)))
      (loom:force f-deferred) ; Force evaluation to create promises
      (loom:force f-thread)
      (should (eq :deferred (loom-promise-mode
                             (loom-future-promise f-deferred))))
      (should (eq :thread (loom-promise-mode
                           (loom-future-promise f-thread)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Test Suite: loom-event.el

(loom-deftest loom-event-create-and-initial-state-test ()
  "Test `loom:event` creates a new event in cleared state."
  (let ((event (loom:event "test-event")))
    (should (loom-event-p event))
    (should (string= "test-event" (loom-event-name event)))
    (should-not (loom:event-is-set-p event)) ; Initially cleared
    (should (eq t (loom-event-value event))))) ; Default value is t when cleared

(loom-deftest loom-event-set-basic-test ()
  "Test `loom:event-set` changes state and resolves waiting promises."
  (let* ((event (loom:event))
         (p1 (loom:event-wait event))
         (p2 (loom:event-wait event)))
    (should-not (loom:event-is-set-p event))
    (loom:event-set event "data-payload") ; Set the event with a value
    (should (loom:event-is-set-p event))
    (should (string= "data-payload" (loom-event-value event)))
    ;; Both promises should now resolve with the event's value
    (should (string= "data-payload" (loom:await p1)))
    (should (string= "data-payload" (loom:await p2)))))

(loom-deftest loom-event-set-idempotent-test ()
  "Test `loom:event-set` is idempotent: subsequent calls do not change
the event's value or re-signal."
  (let* ((event (loom:event))
         (p1 (loom:event-wait event)))
    (loom:event-set event "first-set")
    (should (loom:event-is-set-p event))
    (loom:event-set event "second-set") ; This call should be ignored
    (should (string= "first-set" (loom-event-value event)))
    (should (string= "first-set" (loom:await p1)))))

(loom-deftest loom-event-wait-already-set-test ()
  "Test `loom:event-wait` on an already-set event resolves immediately."
  (let* ((event (loom:event)))
    (loom:event-set event "pre-set-data")
    (should (loom:event-is-set-p event))
    (let ((p (loom:event-wait event)))
      (should (string= "pre-set-data" (loom:await p))))))

(loom-deftest loom-event-clear-test ()
  "Test `loom:event-clear` resets the event state, allowing new waiters."
  (let* ((event (loom:event))
         (p1 (loom:event-wait event)))
    (loom:event-set event "initial-value")
    (should (string= "initial-value" (loom:await p1)))
    (loom:event-clear event) ; Clear the event
    (should-not (loom:event-is-set-p event))
    (should (eq t (loom-event-value event))) ; Value resets to default t
    (let ((p2 (loom:event-wait event)))
      (should (loom:pending-p p2)) ; New promise for new event cycle
      (loom:event-set event "new-value")
      (should (string= "new-value" (loom:await p2))))))

(loom-deftest loom-event-concurrent-waiters-test ()
  "Test multiple concurrent waiters for the same event resolve correctly."
  (let* ((event (loom:event))
         (results (make-vector 3 nil)) ; Use a vector for results to avoid order issues
         (p1 (loom:event-wait event))
         (p2 (loom:event-wait event))
         (p3 (loom:event-wait event)))
    ;; Attach handlers to store results
    (loom:then p1 (lambda (val) (aset results 0 val)))
    (loom:then p2 (lambda (val) (aset results 1 val)))
    (loom:then p3 (lambda (val) (aset results 2 val)))
    (loom:event-set event "broadcast-message") ; Set the event, resolving all waiters
    (loom:await (loom:all (list p1 p2 p3))) ; Wait for all promises to resolve
    ;; Verify all results are as expected
    (should (equal (vector "broadcast-message" "broadcast-message"
                           "broadcast-message")
                   results)) ; Directly compare vectors
    ;; Verify future waiters also resolve immediately
    (let ((p4 (loom:event-wait event)))
      (should (string= "broadcast-message" (loom:await p4))))))

(loom-deftest loom-event-reclear-and-reset-test ()
  "Test an event can be cleared and set multiple times,
behaving like distinct event cycles."
  (let* ((event (loom:event)) p1 p2 p3)
    ;; First cycle
    (setq p1 (loom:event-wait event))
    (loom:event-set event "first-round")
    (should (string= "first-round" (loom:await p1)))
    (loom:event-clear event)

    ;; Second cycle
    (setq p2 (loom:event-wait event))
    (loom:event-set event "second-round")
    (should (string= "second-round" (loom:await p2)))
    (loom:event-clear event)

    ;; Third cycle
    (loom:event-set event "third-round")
    (setq p3 (loom:event-wait event))
    (should (string= "third-round" (loom:await p3)))))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ;;; Test Suite: loom-flow.el

;; (loom-deftest loom-flow-let-test ()
;;   "Test `loom:let` for parallel asynchronous binding."
;;   (let ((p (loom:let ((a (loom:delay 0.02 1)) ; Delay a for longer
;;                       (b (loom:delay 0.01 2))) ; Delay b for shorter
;;              (+ a b)))) ; Both evaluated in parallel
;;     (should (= 3 (loom:await p)))))

;; (loom-deftest loom-flow-let-star-test ()
;;   "Test `loom:let*` for sequential asynchronous binding."
;;   (let ((p (loom:let* ((a (loom:resolved! 10)) ; a resolves immediately
;;                        (b (loom:delay 0.01 (* a 2)))) ; b depends on a
;;              b)))
;;     (should (= 20 (loom:await p)))))

;; (loom-deftest loom-flow-if-test ()
;;   "Test `loom:if!`, `loom:when!`, and `loom:unless!`."
;;   ;; Test `loom:if!`
;;   (should (string= "then" (loom:await (loom:if! (loom:resolved! t)
;;                                                  "then" "else"))))
;;   (should (string= "else" (loom:await (loom:if! (loom:resolved! nil)
;;                                                  "then" "else"))))
;;   ;; Test `loom:when!`
;;   (should (string= "body" (loom:await (loom:when! (loom:resolved! t)
;;                                                   "body"))))
;;   (should (null (loom:await (loom:when! (loom:resolved! nil)
;;                                                    "body"))))
;;   ;; Test `loom:unless!`
;;   (should (null (loom:await (loom:unless! (loom:resolved! t)
;;                                                     "body"))))
;;   (should (string= "body" (loom:await (loom:unless! (loom:resolved! nil)
;;                                                     "body")))))

;; (loom-deftest loom-flow-cond-test ()
;;   "Test `loom:cond!` for asynchronous conditional branching."
;;   ;; First condition evaluates to nil, second to t
;;   (let ((p (loom:cond! ((loom:resolved! nil) 'a)
;;                        ((loom:delay 0.01 t) 'b)
;;                        (t 'c))))
;;     (should (eq 'b (loom:await p))))
;;   ;; Both first conditions evaluate to nil, fall through to `t`
;;   (let ((p (loom:cond! ((loom:resolved! nil) 'a)
;;                        ((loom:resolved! nil) 'b)
;;                        (t 'c))))
;;     (should (eq 'c (loom:await p))))
;;   ;; No conditions match, result should be nil
;;   (let ((p (loom:cond! ((loom:resolved! nil) 'a))))
;;     (should (null (loom:await p)))))

;; (loom-deftest loom-flow-looping-constructs-test ()
;;   "Test `loom:while!`, `loom:dolist!`, and `loom:dotimes!`."
;;   ;; Test `loom:while!`
;;   (let ((i 0))
;;     (should (null (loom:await
;;                    (loom:while! (loom:resolved! (< i 3))
;;                                 (cl-incf i)
;;                                 (loom:delay 0.01))))) ; Simulate async work
;;     (should (= 3 i))) ; Loop should run until i is 3
;;   ;; Test `loom:dolist!`
;;   (let ((results '()))
;;     (should (eq 'done (loom:await
;;                        (loom:dolist! (x '(a b c) 'done)
;;                                      (push x results)
;;                                      (loom:delay 0.01)))))
;;     (should (equal '(c b a) results))) ; Order is reverse of iteration
;;   ;; Test `loom:dotimes!`
;;   (let ((counter 0))
;;     (should (eq 'finished (loom:await
;;                            (loom:dotimes! (i 3 'finished)
;;                                           (cl-incf counter)
;;                                           (loom:delay 0.01)))))
;;     (should (= 3 counter))))

;; (loom-deftest loom-flow-loop-break-continue-test ()
;;   "Test `loom:loop!`, `loom:break!`, and `loom:continue!`."
;;   ;; Test `loom:loop!` with `break!`
;;   (let ((counter 0))
;;     (let ((p (loom:loop!
;;               (cl-incf counter)
;;               (loom:when! (loom:resolved! (= counter 3))
;;                           (break "three")))))
;;       (should (string= "three" (loom:await p)))
;;       (should (= 3 counter))))
;;   ;; Test `loom:loop!` with `continue!` and `break!`
;;   (let ((counter 0) (skipped-vals '()))
;;     (let ((p (loom:loop!
;;               (cl-incf counter)
;;               (loom:when! (loom:resolved! (= counter 5))
;;                           (break "five")) ; Break when counter is 5
;;               (loom:when! (loom:resolved! (oddp counter))
;;                           (push counter skipped-vals)
;;                           (continue))))) ; Continue for odd numbers
;;       (should (string= "five" (loom:await p)))
;;       (should (= 5 counter))
;;       (should (equal '(3 1) skipped-vals))))) ; Skipped 1 and 3 (odd)

;; (loom-deftest loom-flow-try-catch-finally-test ()
;;   "Test `loom:try!` with `:catch` and `:finally` clauses."
;;   ;; Successful `try!`, `finally` always runs
;;   (let (finally-run)
;;     (let ((p (loom:try! (loom:resolved! "ok")
;;                         (:finally (setq finally-run t)))))
;;       (should (string= "ok" (loom:await p)))
;;       (should finally-run)))
;;   ;; Rejected `try!`, `catch` and `finally` run
;;   (let (finally-run caught-err)
;;     (let ((p (loom:try! (loom:rejected! "fail")
;;                         (:catch (err)
;;                                 (setq caught-err err)
;;                                 "caught")
;;                         (:finally (setq finally-run t)))))
;;       (should (string= "caught" (loom:await p))) ; `catch` handler transforms rejection
;;       (should (string= "fail" (loom:error-message caught-err)))
;;       (should finally-run))))

(provide 'loom-tests)
;;; loom-tests.el ends here
