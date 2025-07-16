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
;;; Global State & Constants

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

(defvar loom--ipc-filter-max-chunk-size 4096
  "Maximum size of data to process in one filter call to prevent UI freezing.")

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
  "Drains messages from `loom--ipc-main-thread-queue` in a batch.
  Caller **must** hold `loom--ipc-queue-mutex`. Schedules messages
  for main thread processing via `run-at-time`. Returns count of
  messages processed. This function is for internal use by the
  `loom--ipc-drain-thread` exclusively."
  (cl-block loom--ipc-drain-main-thread-queue-batch
    (unless (and (loom-queue-p loom--ipc-main-thread-queue)
                 (not (loom:queue-empty-p loom--ipc-main-thread-queue)))
      (cl-return-from loom--ipc-drain-main-thread-queue-batch 0))

    (let ((processed-count 0)
          (max-batch-size 100)
          (messages-to-process '()))
      (while (and (< processed-count max-batch-size)
                  (not (loom:queue-empty-p loom--ipc-main-thread-queue)))
        (when-let ((message (loom:queue-dequeue loom--ipc-main-thread-queue)))
          (push message messages-to-process)
          (cl-incf processed-count)))

      (when messages-to-process
        (loom-log :debug nil "Scheduling %d messages for main thread."
                  processed-count)
        ;; Schedule processing on main thread. Reversing restores order.
        (dolist (message (reverse messages-to-process))
          (run-at-time 0 nil #'loom:process-settled-on-main message)))
      processed-count)))

(defun loom--ipc-drain-worker-thread ()
  "The main function for the dedicated background drain thread.
  This function runs in an indefinite loop. It efficiently waits for
  messages on `loom--ipc-queue-condition` and, upon waking, drains
  the queue in batches via `loom--ipc-drain-main-thread-queue-batch`.
  This loop terminates only when `loom--ipc-drain-shutdown` is set.
  Handles errors internally to ensure the thread remains robust."
  (loom-log :info nil "Queue drain worker thread started.")
  
  ;; Wait for proper initialization before starting main loop
  (while (and (not loom--ipc-drain-shutdown)
              (not (and loom--ipc-queue-mutex 
                        loom--ipc-queue-condition 
                        loom--ipc-main-thread-queue)))
    (loom-log :debug nil "Worker thread waiting for IPC initialization...")
    (sleep-for 0.1))
  
  (condition-case err
      (while (not loom--ipc-drain-shutdown)
        (condition-case inner-err
            (loom:with-mutex! loom--ipc-queue-mutex
              ;; Wait for signal if queue is empty and not shutting down
              (while (and (not loom--ipc-drain-shutdown)
                          (or (not (loom-queue-p loom--ipc-main-thread-queue))
                              (loom:queue-empty-p loom--ipc-main-thread-queue)))
                (loom-log :debug nil "Drain worker: waiting for signal...")
                (condition-wait loom--ipc-queue-condition))
              
              ;; Process messages if not shutting down
              (unless loom--ipc-drain-shutdown
                (loom--ipc-drain-main-thread-queue-batch)))
          (error
           (loom-log :error nil "Error in drain worker loop: %S" inner-err)
           ;; Longer pause on error to prevent tight error loops
           (sleep-for 0.5))))
    (error
     (loom-log :error nil "Queue drain worker thread crashed: %S" err)))
  
  (loom-log :info nil "Queue drain worker thread exiting."))

(defun loom--ipc-enqueue-with-signal (message)
  "Enqueues `MESSAGE` onto `loom--ipc-main-thread-queue` and signals.
  This is the thread-safe entry point for background threads to send
  a message to the main thread via the drain worker. It acquires the
  mutex, enqueues the message, and notifies the waiting drain thread.

  Arguments:
  - `MESSAGE` (any): The message to enqueue.

  Returns:
  - `nil`. Signals `loom-ipc-queue-uninitialized-error` if queue not init."
  (unless (and loom--ipc-main-thread-queue
               (loom-queue-p loom--ipc-main-thread-queue))
    (signal 'loom-ipc-queue-uninitialized-error
            '(:message "Main thread IPC queue not initialized.")))
  (loom:with-mutex! loom--ipc-queue-mutex
    (loom:queue-enqueue loom--ipc-main-thread-queue message)
    (condition-notify loom--ipc-queue-condition))
  (loom-log :debug (plist-get message :id) "Enqueued message; signaled worker.")
  nil)

(defun loom--ipc-parse-pipe-line (line-text)
  "Parses a single, complete line of JSON from the IPC process.
  This helper for `loom--ipc-filter` expects a newline-trimmed string.
  It decodes the JSON and dispatches the payload based on its `:type`.
  Handles `:promise-settled`, `:log`, and unknown message types.

  Arguments:
  - `LINE-TEXT` (string): A complete JSON string.

  Returns:
  - `nil`. Logs errors on failure."
  (cl-block loom--ipc-parse-pipe-line
    (when (s-blank? line-text)
      (cl-return-from loom--ipc-parse-pipe-line nil)))

  (condition-case err
      (let* ((json-object-type 'plist)
             (json-array-type 'list)
             (json-key-type 'keyword)
             (payload (json-read-from-string line-text))
             (msg-type (plist-get payload :type)))
        (loom-log :debug nil "IPC filter received: %s (Type: %S)"
                  (s-truncate 80 line-text) msg-type)
        (pcase msg-type
          (:promise-settled
           (loom:process-settled-on-main payload))
          (:log
           (let ((level (plist-get payload :level))
                 (message (plist-get payload :message)))
             (when (and level message)
               (loom-log level nil "IPC remote log: %s" message))))
          (_
           (loom-log :warn nil "IPC filter unknown type: %S" msg-type))))
    (json-error
     (loom-log :error nil "JSON parse error in IPC: %S, line: %S" err line-text))
    (error
     (loom-log :error nil "Error parsing IPC message: %S, line: %S" err line-text))))

(defun loom--ipc-filter (process string)
  "Improved filter function that processes data in chunks to prevent UI freezing.
  
  Arguments:
  - `PROCESS` (process): The `make-pipe-process` instance.
  - `STRING` (string): The latest chunk of output from the process.

  Returns: `nil`."
  (condition-case err
      (progn
        (unless (buffer-live-p loom--ipc-buffer)
          (setq loom--ipc-buffer (generate-new-buffer " *loom-ipc-filter*"))
          (with-current-buffer loom--ipc-buffer
            (setq-local enable-multibyte-characters nil)))

        ;; Limit processing chunk size to prevent UI freezing
        (let ((chunk-size (min (length string) loom--ipc-filter-max-chunk-size)))
          (when (< chunk-size (length string))
            (loom-log :debug nil "Large IPC chunk, processing in parts: %d/%d" 
                     chunk-size (length string))
            ;; Schedule remaining data for next iteration
            (run-at-time 0.01 nil 
              (lambda () 
                (loom--ipc-filter process (substring string chunk-size)))))
          
          (setq string (substring string 0 chunk-size)))

        (with-current-buffer loom--ipc-buffer
          (save-excursion (goto-char (point-max)) (insert string)))

        ;; Process complete lines with a limit to prevent blocking
        (with-current-buffer loom--ipc-buffer
          (let ((line-start (point-min))
                (lines-processed 0)
                (max-lines-per-batch 10))
            (goto-char line-start)
            (while (and (< lines-processed max-lines-per-batch)
                        (re-search-forward "\n" nil t))
              (let* ((line-end (match-end 0))
                     (line-text (buffer-substring-no-properties
                                 line-start (1- line-end))))
                (unless (s-blank? line-text)
                  (loom--ipc-parse-pipe-line line-text)
                  (cl-incf lines-processed)))
              (setq line-start (point)))
            
            ;; If we hit the batch limit, schedule continuation
            (when (and (>= lines-processed max-lines-per-batch)
                       (re-search-forward "\n" nil t))
              (loom-log :debug nil "IPC filter batch limit reached, scheduling continuation")
              (run-at-time 0.01 nil 
                (lambda () 
                  (loom--ipc-filter process ""))))
            
            (delete-region (point-min) line-start))))
    (error (loom-log :error nil "Error in IPC filter: %S" err)))
  nil)

(defun loom--ipc-sentinel (process event)
  "The sentinel function for `loom--ipc-process`.
  Monitors for unexpected termination of the IPC process. If the
  process dies, it logs an error and triggers a cleanup to release
  resources and prevent leaks.

  Arguments:
  - `PROCESS` (process): The process whose state changed.
  - `EVENT` (string): Description of the state change.

  Returns: `nil`."
  (loom-log :warn nil "IPC process sentinel: %s" (s-trim event))
  (when (string-match-p "\\(finished\\|exited\\|failed\\)" event)
    (loom-log :error nil "IPC process terminated unexpectedly. Cleaning up.")
    (loom:ipc-cleanup))
  nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public IPC API

(defun loom:process-settled-on-main (payload)
  "Process a settlement message that has arrived on the main thread.
This function is the end-point for messages from both background threads
and external processes. It finds the target promise and settles it.

Arguments:
- `PAYLOAD` (plist): A plist containing settlement data, including `:id`,
  `:value` or `:error`.

Returns:
- `nil`.

Side Effects:
- Resolves or rejects a promise, triggering its callback chain."
  (let* ((id (plist-get payload :id))
         (promise (loom-registry-get-promise-by-id id)))
    (if (and promise (loom:pending-p promise))
        (let ((value (plist-get payload :value))
              (error (plist-get payload :error)))
          (if error
              (loom:reject promise error)
            (loom:resolve promise value)))
      (loom-log :debug id "IPC received settlement for non-pending/unknown promise."))))

;;;###autoload
(defun loom:ipc-init ()
  "Initializes all IPC mechanisms. Idempotent.
  Sets up the thread-safe queue, condition variable, mutex, and starts
  the dedicated drain thread. Also initializes the process-based pipe
  for external communication. This function should be called once on startup.

  Returns: `nil`."
  (loom-log :info nil "Initializing IPC system.")
  
  ;; Initialize thread-based IPC if threading is available
  (when (fboundp 'make-thread)
    (loom-log :info nil "Initializing thread-based IPC.")
    
    ;; Initialize synchronization primitives first
    (unless loom--ipc-queue-mutex
      (setq loom--ipc-queue-mutex (loom:lock "loom-ipc-queue-mutex")))
    (unless loom--ipc-queue-condition
      (setq loom--ipc-queue-condition 
        (make-condition-variable (loom-lock-native-mutex loom--ipc-queue-mutex))))
    
    ;; Initialize queue
    (unless (loom-queue-p loom--ipc-main-thread-queue)
      (setq loom--ipc-main-thread-queue (loom:queue)))

    ;; Only start drain thread after all prerequisites are ready
    (when (and loom--ipc-queue-mutex 
               loom--ipc-queue-condition 
               loom--ipc-main-thread-queue
               (or (null loom--ipc-drain-thread)
                   (not (thread-live-p loom--ipc-drain-thread))))
      (setq loom--ipc-drain-shutdown nil)
      (loom-log :debug nil "Starting IPC drain thread.")
      (setq loom--ipc-drain-thread
            (make-thread #'loom--ipc-drain-worker-thread "loom-ipc-drain-worker"))))

  ;; Initialize process-based IPC
  (unless (and loom--ipc-process (process-live-p loom--ipc-process))
    (loom-log :info nil "Initializing IPC pipe process.")
    (condition-case err
        (progn
          (setq loom--ipc-buffer (generate-new-buffer " *loom-ipc-filter*"))
          (with-current-buffer loom--ipc-buffer
            (setq-local enable-multibyte-characters nil))
          
          ;; Create process with better error handling
          (setq loom--ipc-process
                (make-pipe-process
                 :name "loom-ipc-listener"
                 :buffer nil  ; Don't associate with a buffer to avoid issues
                 :noquery t
                 :coding 'utf-8-emacs-unix
                 :filter #'loom--ipc-filter
                 :sentinel #'loom--ipc-sentinel))
          
          (loom-log :info nil "IPC pipe process initialized successfully."))
      (error
       (loom-log :error nil "Failed to initialize IPC pipe process: %S" err)
       (setq loom--ipc-process nil)
       (when loom--ipc-buffer
         (kill-buffer loom--ipc-buffer)
         (setq loom--ipc-buffer nil)))))
  nil)

;;;###autoload
(defun loom:ipc-cleanup ()
  "Shuts down all IPC resources gracefully without blocking the UI.
  This is safe to call multiple times and won't freeze the main thread.

  Returns: `nil`."
  (loom-log :info nil "Cleaning up IPC resources.")
  
  ;; Shut down the drain thread asynchronously
  (when loom--ipc-drain-thread
    (condition-case err
        (progn
          (loom:with-mutex! loom--ipc-queue-mutex
            (setq loom--ipc-drain-shutdown t)
            (condition-notify loom--ipc-queue-condition))
          
          ;; Use async timer to check thread completion instead of blocking
          (run-at-time 0.1 nil 
            (lambda ()
              (condition-case err
                  (progn
                    ;; Try non-blocking join first
                    (unless (thread-join loom--ipc-drain-thread)
                      (loom-log :warn nil "Drain thread cleanup timeout, forcing quit.")
                      (when (thread-live-p loom--ipc-drain-thread)
                        (thread-signal loom--ipc-drain-thread 'quit nil)))
                    (setq loom--ipc-drain-thread nil))
                (error (loom-log :error nil "Error in async thread cleanup: %S" err))))))
      (error (loom-log :error nil "Error initiating drain thread cleanup: %S" err))))

  ;; Reset thread-related state immediately
  (setq loom--ipc-queue-condition nil)
  (setq loom--ipc-queue-mutex nil)
  (setq loom--ipc-main-thread-queue nil)
  (setq loom--ipc-drain-shutdown nil)

  ;; Shut down the IPC process
  (when loom--ipc-process
    (condition-case err
        (when (process-live-p loom--ipc-process)
          (delete-process loom--ipc-process))
      (error (loom-log :error nil "Error cleaning IPC process: %S" err)))
    (setq loom--ipc-process nil))

  ;; Clean up the IPC buffer
  (when loom--ipc-buffer
    (condition-case err
        (when (buffer-live-p loom--ipc-buffer) (kill-buffer loom--ipc-buffer))
      (error (loom-log :error nil "Error cleaning IPC buffer: %S" err)))
    (setq loom--ipc-buffer nil))
  nil)

;;;###autoload
(defun loom:dispatch-to-main-thread (promise &optional message-type data)
  "Dispatches a message to the main thread with improved error handling.
  
  Arguments:
  - `PROMISE` (loom-promise): The promise object being settled.
  - `MESSAGE-TYPE` (symbol, optional): Type, defaults to `:promise-settled`.
  - `DATA` (plist, optional): Additional message payload.

  Returns: `nil`."
  (unless (loom-promise-p promise)
    (signal 'wrong-type-argument (list 'loom-promise-p promise)))

  (let* ((promise-id (loom-promise-id promise))
         (full-payload (append `(:id ,promise-id
                                 :type ,(or message-type :promise-settled))
                               data)))
    (cond
      ;; Path 1: From background thread, use efficient thread queue
      ((and (fboundp 'current-thread) (not (eq (current-thread) main-thread)))
       (loom-log :debug promise-id "Dispatching via thread queue.")
       (condition-case err
           (loom--ipc-enqueue-with-signal full-payload)
         (error 
          (loom-log :error promise-id "Thread queue dispatch failed: %S" err)
          ;; Fallback to direct call
          (run-at-time 0 nil #'loom:process-settled-on-main full-payload))))

      ;; Path 2: From main thread, use pipe process (async to prevent blocking)
      ((and loom--ipc-process (process-live-p loom--ipc-process))
       (loom-log :debug promise-id "Dispatching via IPC process re-queue.")
       (condition-case err
           (let ((json-message (json-encode full-payload)))
             ;; Use async approach to prevent blocking
             (run-at-time 0.001 nil 
               (lambda ()
                 (condition-case send-err
                     (process-send-string loom--ipc-process 
                                          (format "%s\n" json-message))
                   (error 
                    (loom-log :error promise-id "IPC process send failed: %S" send-err)
                    ;; Fallback to direct processing
                    (loom:process-settled-on-main full-payload))))))
         (error 
          (loom-log :error promise-id "IPC process dispatch setup failed: %S" err)
          ;; Fallback to direct call
          (run-at-time 0 nil #'loom:process-settled-on-main full-payload))))

      ;; Path 3: Fallback for when IPC isn't ready
      (t
       (loom-log :debug promise-id "Dispatching via direct timer fallback.")
       (run-at-time 0 nil #'loom:process-settled-on-main full-payload)))
    nil))

;; Register a hook to ensure cleanup on Emacs exit.
(add-hook 'kill-emacs-hook #'loom:ipc-cleanup)

(provide 'loom-ipc)
;;; loom-ipc.el ends here
