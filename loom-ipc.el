;;; loom-ipc.el --- Inter-Process/Thread Communication (IPC) for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the core Inter-Process/Thread Communication (IPC)
;; mechanisms for the Loom concurrency library. It enables safe and efficient
;; message passing between different Emacs Lisp threads and external processes,
;; ensuring that asynchronous operations can communicate their results back
;; to the main Emacs thread without blocking the UI.
;;
;; This module now **owns and manages all its global IPC state**, making it
;; a self-contained and robust subsystem.
;;
;; ## Key Features
;;
;; - **Thread-Safe Queue Interaction:** Provides functions to enqueue/dequeue
;;   messages from the global main thread queue defined in `loom-config.el`.
;; - **Dedicated Drain Thread:** A background worker thread (`loom:ipc-drain-thread`)
;;   that efficiently processes messages from the global thread-safe queue.
;; - **Process-based IPC:** Uses `make-pipe-process` for communication with
;;   external OS processes or for asynchronous re-queuing on the main thread.
;; - **Unified Dispatch:** `loom:dispatch-to-main-thread` provides a single
;;   entry point for sending messages to the main thread, intelligently
;;   choosing the best communication path.
;; - **Robust Error Handling:** Includes error definitions and logging for
;;   IPC-specific issues.
;;
;; This module is designed to be highly efficient and robust, preventing
;; busy-waiting and ensuring proper resource management during shutdown.
;;
;;; Code:

(require 'cl-lib)
(require 'json)
(require 's)

(require 'loom-log)
(require 'loom-lock)
(require 'loom-queue)
(require 'loom-errors) 
(require 'loom-registry)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom-promise-p "loom-promise")
(declare-function loom-promise-id "loom-promise")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom--ipc-queue-mutex nil
  "A `loom:lock` object providing thread-safe, exclusive access to
  `loom--ipc-main-thread-queue`. Essential for coordinating producers
  and consumers, preventing race conditions. Private to loom-ipc.el.")

(defvar loom--ipc-queue-condition nil
  "A `condition-variable` used with `loom--ipc-queue-mutex`. The
  `loom--ipc-drain-thread` waits on this, sleeping efficiently until
  new messages are added to the queue. Private to loom-ipc.el.")

(defvar loom--ipc-main-thread-queue nil
  "A thread-safe `loom:queue` for messages destined for the main Emacs
  thread. This is the primary low-overhead communication channel for
  background threads to signal events (e.g., promise settlements).
  Private to loom-ipc.el.")

(defvar loom--ipc-drain-thread nil
  "The dedicated background thread responsible for processing
  inter-thread messages enqueued in `loom--ipc-main-thread-queue`. It
  waits on `loom--ipc-queue-condition` and, upon being signaled, drains
  the queue and schedules work on the main Emacs thread. Private to
  loom-ipc.el.")

(defvar loom--ipc-drain-shutdown nil
  "A boolean flag used to signal `loom--ipc-drain-thread` to terminate
  gracefully. When `t`, the drain thread's main loop will exit. Private to
  loom-ipc.el.")

(defvar loom--ipc-process nil
  "The long-lived `make-pipe-process` instance used for external IPC
  and for main thread re-queuing. Acts as a message loopback. Private to
  loom-ipc.el.")

(defvar loom--ipc-buffer nil
  "A dedicated temporary buffer used by `loom--ipc-filter` for
  accumulating partial JSON messages from `loom--ipc-process`. Ensures
  complete JSON lines are reassembled before parsing. Private to
  loom-ipc.el.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions 

(define-error 'loom-ipc-queue-uninitialized-error
  "Attempted to use an uninitialized IPC queue."
  'loom-error)

(define-error 'loom-ipc-process-error
  "An error occurred with the IPC pipe process."
  'loom-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal IPC Helpers

(defun loom--ipc-drain-main-thread-queue-batch ()
  "Drains a batch of messages from `loom--ipc-main-thread-queue`.
  This function is called exclusively from the `loom--ipc-drain-thread`
  while `loom--ipc-queue-mutex` is already held. It retrieves a batch of
  messages (up to `max-batch-size`) from the queue atomically. These messages
  are then scheduled to be processed on the main Emacs thread using
  `run-at-time 0 nil`, ensuring that promise settlements and related
  operations occur in the correct context and do not block the worker thread.

  Returns:
  - (integer): Number of messages processed."
  (cl-block loom--ipc-drain-main-thread-queue-batch
    (unless (and (bound-and-true-p loom--ipc-main-thread-queue) ; Ensure queue exists.
                 (loom-queue-p loom--ipc-main-thread-queue)
                 (not (loom:queue-empty-p loom--ipc-main-thread-queue)))
      (cl-return-from loom--ipc-drain-main-thread-queue-batch 0)))

  (loom-log :debug nil "Worker thread draining main queue batch...")
  (let ((processed-count 0)
        (max-batch-size 100) ; Limit batch size to prevent excessive main
                             ; thread blocking.
        (messages-to-process '()))
    (loom:with-mutex! loom--ipc-queue-mutex ; Acquire mutex for queue access.
      (while (and (< processed-count max-batch-size)
                  (not (loom:queue-empty-p loom--ipc-main-thread-queue)))
        (when-let ((message (loom:queue-dequeue loom--ipc-main-thread-queue)))
          (push message messages-to-process)
          (cl-incf processed-count))))

    (when messages-to-process
      (loom-log :debug nil "Scheduling %d messages for main thread processing."
                processed-count)
      ;; Schedule processing on main thread outside the mutex, for efficiency.
      ;; `run-at-time 0 nil` schedules the function to run at the next
      ;; available idle moment in the main Emacs event loop.
      (dolist (message (reverse messages-to-process))
        (run-at-time 0 nil #'loom:process-settled-on-main message)))
    processed-count))

(defun loom--ipc-drain-worker-thread ()
  "The main function for the dedicated background drain thread.
  This thread runs indefinitely in a separate Emacs Lisp thread for the
  lifetime of the Loom library session. Its primary role is to efficiently
  wait for and process messages enqueued by other threads for the main
  thread. It uses a condition variable (`loom--ipc-queue-condition`) to sleep
  when the queue is empty, waking up only when new messages are added or
  a shutdown signal (`loom--ipc-drain-shutdown`) is received. Upon waking,
  it acquires `loom--ipc-queue-mutex` to safely drain messages in batches
  via `loom--ipc-drain-main-thread-queue-batch`.

  Error handling is included to log any unexpected issues within the worker
  thread, ensuring robustness and preventing thread crashes.

  Arguments:
  - None.

  Returns:
  - This function runs in an infinite loop until `loom--ipc-drain-shutdown`
    is set to `t`, and thus does not return a value under normal operation.
    It prints log messages indicating its start and graceful exit."
  (loom-log :info nil "Queue drain worker thread started.")
  (condition-case err
      (while (not loom--ipc-drain-shutdown)
        (condition-case inner-err
            ;; Ensure mutex and condition are bound before use. This check
            ;; is vital as the thread might start before full IPC initialization.
            (unless (and (bound-and-true-p loom--ipc-queue-mutex)
                         (bound-and-true-p loom--ipc-queue-condition))
              (loom-log :error nil "IPC worker: Queue mutex/condition not bound.")
              (signal 'loom-ipc-queue-uninitialized-error
                      (loom:make-error
                       :type :loom-ipc-queue-uninitialized-error
                       :message "IPC queue mutex/condition not initialized.")))

            (loom:with-mutex! loom--ipc-queue-mutex ; Acquire mutex for waiting.
              (while (and (not loom--ipc-drain-shutdown)
                          (or (not (loom-queue-p loom--ipc-main-thread-queue))
                              (loom:queue-empty-p loom--ipc-main-thread-queue)))
                (loom-log :debug nil "Drain worker: waiting for condition signal...")
                ;; `condition-wait` automatically releases the mutex while
                ;; waiting and re-acquires it before returning.
                (condition-wait loom--ipc-queue-condition))
              ;; Process messages if not shutting down.
              (unless loom--ipc-drain-shutdown
                (loom--ipc-drain-main-thread-queue-batch)))
          (error
           ;; Catch and log errors within the inner loop to prevent the worker
           ;; thread from crashing entirely on transient issues.
           (loom-log :error nil "Error in drain worker inner loop: %S" inner-err)
           (sleep-for 0.1)))) ; Brief pause before retrying.
    (error
     ;; Catch and log errors from the top-level loop, indicating a thread crash.
     (loom-log :error nil "Queue drain worker thread crashed: %S" err)))
  (loom-log :info nil "Queue drain worker thread exiting."))

(defun loom--ipc-enqueue-with-signal (message)
  "Enqueues `MESSAGE` onto `loom--ipc-main-thread-queue` and signals the
  `loom--ipc-queue-condition` variable. This function is used by background
  Emacs Lisp threads to safely and efficiently send messages (e.g., promise
  settlement notifications) to the `loom--ipc-drain-thread` for eventual
  processing on the main Emacs thread. It acquires `loom--ipc-queue-mutex`
  to ensure thread-safe access to the queue, enqueues the message, and then
  notifies the waiting drain thread.

  Arguments:
  - `MESSAGE` (any): The message (typically a plist representing a promise
    settlement) to be enqueued.

  Returns:
  - `nil`. Signals `loom-ipc-queue-uninitialized-error` if queue is not init."
  (unless (and (bound-and-true-p loom--ipc-main-thread-queue) ; Check if queue exists.
               (loom-queue-p loom--ipc-main-thread-queue))
    (signal 'loom-ipc-queue-uninitialized-error
            (loom:make-error
             :type :loom-ipc-queue-uninitialized-error
             :message "Main thread queue not initialized.")))
  (loom:with-mutex! loom--ipc-queue-mutex ; Acquire mutex for queue access.
    (loom:queue-enqueue loom--ipc-main-thread-queue message) ; Enqueue message.
    (condition-notify loom--ipc-queue-condition)) ; Wake up the drain thread.
  (loom-log :debug (plist-get message :id) "Enqueued message and signaled worker.")
  nil)

(defun loom--ipc-parse-pipe-line (line-text)
  "Parses a single, complete line of JSON received from the IPC process.
  This function is a helper for `loom--ipc-filter`. It expects `LINE-TEXT`
  to be a newline-trimmed string containing a valid JSON object.
  It attempts to parse the JSON and then dispatches the payload based on
  its `:type` field.
  - For `:promise-settled` types, it calls `loom:ipc-process-settled-on-main`.
  - For `:log` types, it re-logs the message using `loom-log`.
  - Unknown message types are logged as warnings.

  Error handling is included to catch JSON parsing errors or unexpected
  issues during message processing.

  Arguments:
  - `LINE-TEXT` (string): A complete JSON string, typically ending with a
    newline which has already been trimmed.

  Returns:
  - `nil`.
  - Logs errors if JSON parsing fails or the message type is unknown."
  (cl-block loom--ipc-parse-pipe-line
    (when (string-empty-p (string-trim line-text))
      (cl-return-from loom--ipc-parse-pipe-line nil)))

  (condition-case err
      (let* ((json-object-type 'plist) ; Parse JSON objects as plists.
             (json-array-type 'list)   ; Parse JSON arrays as lists.
             (json-key-type 'keyword)  ; Parse JSON object keys as keywords.
             (payload (json-read-from-string line-text))
             (msg-type (plist-get payload :type)))
        (loom-log :debug nil "IPC filter processing: %s (Type: %S)"
                  (s-truncate 100 line-text) msg-type)
        (pcase msg-type
          (:promise-settled
           (loom:process-settled-on-main payload)) ; Call public function.
          (:log
           (let ((level (plist-get payload :level))
                 (message (plist-get payload :message)))
             (when (and level message)
               (loom-log level nil "IPC remote log: %s" message))))
          (_
           (loom-log :warn nil "IPC filter received unknown message type: %S"
                     msg-type))))
    (json-error
     (loom-log :error nil "JSON parse error in IPC message: %S, line: %S"
               err line-text))
    (error
     (loom-log :error nil "Unexpected error parsing IPC message: %S, line: %S"
               err line-text))))

(defun loom--ipc-filter (process string)
  "The filter function for `loom--ipc-process`.
  This function is called asynchronously by Emacs whenever
  `loom--ipc-process` outputs data. It is responsible for incrementally
  accumulating incoming `STRING` chunks into `loom--ipc-buffer`, then
  detecting and parsing complete newline-terminated JSON lines. Each
  complete line is passed to `loom--ipc-parse-pipe-line` for processing.

  This approach robustly handles fragmented incoming data streams from
  the pipe process, ensuring that only complete JSON messages are parsed.

  Arguments:
  - `PROCESS` (process): The `make-pipe-process` instance.
  - `STRING` (string): The latest chunk of output received from the process.

  Returns:
  - `nil`. Logs errors if processing fails at any stage."
  (condition-case err
      (progn
        ;; Ensure buffer exists and is live for accumulation.
        (unless (buffer-live-p loom--ipc-buffer)
          (setq loom--ipc-buffer (generate-new-buffer " *loom-ipc-filter*"))
          (with-current-buffer loom--ipc-buffer
            ;; This is crucial for handling raw byte streams that might not
            ;; be valid multibyte characters until a full JSON object is
            ;; received.
            (setq-local enable-multibyte-characters nil)))

        ;; Append incoming string to the buffer.
        (with-current-buffer loom--ipc-buffer
          (save-excursion
            (goto-char (point-max))
            (insert string)))

        ;; Process complete lines from the buffer.
        (with-current-buffer loom--ipc-buffer
          (let ((line-start (point-min)))
            (goto-char line-start)
            ;; Loop until no more newlines are found, processing one line
            ;; at a time.
            (while (re-search-forward "\n" nil t)
              (let* ((line-end (match-end 0))
                     ;; Extract the line content, excluding the newline character.
                     (line-text (buffer-substring-no-properties line-start
                                                                (1- line-end))))
                (unless (string-empty-p (string-trim line-text))
                  (loom--ipc-parse-pipe-line line-text)))
              (setq line-start (point)))

            ;; Remove processed lines from the buffer to keep it clean.
            ;; Any remaining text is an incomplete line and will be processed
            ;; when more data arrives.
            (delete-region (point-min) line-start))))
    (error
     (loom-log :error nil "Error in IPC filter: %S" err)))
  nil)

(defun loom--ipc-sentinel (process event)
  "The sentinel function for `loom--ipc-process`.
  This function is called by Emacs whenever the state of `loom--ipc-process`
  changes (e.g., it starts, stops, or exits). It primarily monitors for
  unexpected termination of the IPC process (e.g., \"finished\", \"exited\",
  \"failed\"). If the process terminates, it logs an error and triggers
  `loom:ipc-cleanup` to release associated resources, preventing leaks
  and attempting recovery.

  Arguments:
  - `PROCESS` (process): The `make-pipe-process` instance whose state changed.
  - `EVENT` (string): A descriptive string indicating the state change
    (e.g., \"finished\\n\", \"exited abnormally\\n\").

  Returns:
  - `nil`.
  - Logs warnings or errors based on the event."
  (loom-log :warn nil "IPC process sentinel triggered: %s" (string-trim event))
  (when (string-match-p "\\(finished\\|exited\\|failed\\)" event)
    (loom-log :error nil "IPC process terminated unexpectedly. Cleaning up.")
    (loom:ipc-cleanup))
  nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public IPC API

;;;###autoload
(defun loom:ipc-init ()
  "Initializes the inter-thread and inter-process communication (IPC)
  mechanisms. Sets up the thread-based message queue and drain thread,
  and the process-based pipe for external communication. Idempotent.

  Returns:
  - `nil`. Logs info/errors."
  (when (fboundp 'make-thread)
    (loom-log :info nil "Initializing condition variable-based IPC.")
    ;; Initialize queue, mutex, condition variable if not already.
    (unless loom--ipc-queue-mutex
      (setq loom--ipc-queue-mutex (loom:lock "loom-ipc-queue-mutex" :mode :thread)))
    (unless loom--ipc-queue-condition
      (setq loom--ipc-queue-condition
            (make-condition-variable (loom-lock-native-mutex loom--ipc-queue-mutex)
                                     "loom-ipc-queue-cond")))
    (unless (loom-queue-p loom--ipc-main-thread-queue)
      (loom:with-mutex! loom--ipc-queue-mutex
        (setq loom--ipc-main-thread-queue (loom:queue))))

    (when (or (null loom--ipc-drain-thread)
              (not (thread-live-p loom--ipc-drain-thread)))
      (setq loom--ipc-drain-shutdown nil)
      (setq loom--ipc-drain-thread
            (make-thread #'loom--ipc-drain-worker-thread "loom-ipc-drain-worker"))))

  (unless (and loom--ipc-process (process-live-p loom--ipc-process))
    (loom-log :info nil "Initializing IPC pipe process.")
    (condition-case err
        (setq loom--ipc-process
              (make-pipe-process
               :name "loom-ipc-listener"
               :buffer nil
               :noquery t
               :coding 'utf-8-emacs-unix
               :filter #'loom--ipc-filter
               :sentinel #'loom--ipc-sentinel))
      (error
       (loom-log :error nil "Failed to initialize IPC pipe process: %S" err)
       (setq loom--ipc-process nil))))
  nil)

;;;###autoload
(defun loom:ipc-cleanup ()
  "Shuts down all IPC resources.
  Terminates the drain thread and IPC pipe process, and frees associated
  buffers, mutexes, and condition variables.

  Returns:
  - `nil`. Logs info/errors."
  (loom-log :info nil "Cleaning up IPC resources.")
  (when loom--ipc-drain-thread
    (condition-case err
        (progn
          ;; Acquire this module's mutex to signal shutdown to the drain thread.
          (when (bound-and-true-p loom--ipc-queue-mutex)
            (loom:with-mutex! loom--ipc-queue-mutex
              (setq loom--ipc-drain-shutdown t)
              (when (bound-and-true-p loom--ipc-queue-condition)
                (condition-notify loom--ipc-queue-condition))))
          ;; Wait for graceful shutdown with a timeout.
          (let ((timeout-count 0))
            (while (and (thread-live-p loom--ipc-drain-thread) (< timeout-count 50))
              (sleep-for 0.02)
              (cl-incf timeout-count)))
          ;; Force shutdown if it's still alive after timeout.
          (when (thread-live-p loom--ipc-drain-thread)
            (loom-log :warn nil "Drain thread did not exit cleanly, signaling quit.")
            (thread-signal loom--ipc-drain-thread 'quit nil)))
      (error
       (loom-log :error nil "Error during drain thread cleanup: %S" err)))
    (setq loom--ipc-drain-thread nil))

  ;; Reset this module's global state variables.
  (setq loom--ipc-queue-condition nil)
  (setq loom--ipc-queue-mutex nil)
  (setq loom--ipc-main-thread-queue nil)
  (setq loom--ipc-drain-shutdown nil)

  (when loom--ipc-process
    (condition-case err
        (when (process-live-p loom--ipc-process)
          (delete-process loom--ipc-process))
      (error
       (loom-log :error nil "Error cleaning up IPC process: %S" err)))
    (setq loom--ipc-process nil))

  (when loom--ipc-buffer
    (condition-case err
        (when (buffer-live-p loom--ipc-buffer)
          (kill-buffer loom--ipc-buffer))
      (error
       (loom-log :error nil "Error cleaning up IPC buffer: %S" err)))
    (setq loom--ipc-buffer nil))
  nil)

;;;###autoload
(defun loom:dispatch-to-main-thread (promise &optional message-type data)
  "Dispatches a message (e.g., promise settlement) to the main Emacs thread.
  Intelligently selects the most efficient IPC path: thread-based,
  process-based, or direct fallback.

  Arguments:
  - `PROMISE` (loom-promise): The promise object.
  - `MESSAGE-TYPE` (symbol, optional): Message type. Defaults to
    `:promise-settled`.
  - `DATA` (plist, optional): Additional message payload.

  Returns:
  - `nil`. Signals `wrong-type-argument` if `PROMISE` is not a `loom-promise`."
  (unless (loom-promise-p promise)
    (signal 'wrong-type-argument '(loom-promise-p promise)))

  (let* ((promise-id (loom-promise-id promise))
         (full-payload (append `(:id ,promise-id
                                 :type ,(or message-type :promise-settled))
                               data)))
    (loom-log :debug promise-id "Dispatching message to main thread: %S"
              full-payload)
    (cond
      ((and (fboundp 'make-thread)
            (fboundp 'current-thread)
            (not (eq (current-thread) (main-thread))))
       (loom-log :debug promise-id "Using threaded dispatch path.")
       (loom--ipc-enqueue-with-signal full-payload))

      ((and loom--ipc-process (process-live-p loom--ipc-process))
       (loom-log :debug promise-id "Using IPC process for main thread re-queue.")
       (condition-case err
           (let ((json-message (json-encode full-payload)))
             (process-send-string loom--ipc-process (format "%s\n" json-message)))
         (error
          (loom-log :error promise-id "Failed to dispatch via IPC process: %S"
                    err))))

      (t
       (loom-log :debug promise-id "Using direct processing fallback.")
       (run-at-time 0 nil #'loom:ipc-process-settled-on-main full-payload)))
    nil))

;;;###autoload
(defun loom:ipc-drain-main-thread-queue ()
  "Public function to drain the main thread IPC queue.
  This is typically called by `loom:scheduler-tick` to process messages
  from background threads on the main Emacs thread.

  Returns:
  - `t` if messages were processed, `nil` if the queue was empty."
  ;; This function is designed to be called from the main thread's event loop.
  ;; It needs to acquire the mutex to safely access the queue.
  (cl-block loom:ipc-drain-main-thread-queue
    (unless (bound-and-true-p loom--ipc-queue-mutex) 
      (loom-log :warn nil "loom:ipc-drain-main-thread-queue called before IPC init.")
      (cl-return-from loom:ipc-drain-main-thread-queue nil)))

  (loom:with-mutex! loom--ipc-queue-mutex 
    (loom--ipc-drain-main-thread-queue-batch)))

;; Register shutdown hook for IPC module.
(add-hook 'kill-emacs-hook #'loom:ipc-cleanup)

(provide 'loom-ipc)
;;; loom-ipc.el ends here