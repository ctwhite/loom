;;; loom-ipc.el --- Inter-Process/Thread Communication (IPC) for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the core Inter-Process/Thread Communication (IPC)
;; mechanisms for the Loom concurrency library. It enables safe and
;; efficient message passing between different Emacs Lisp threads and
;; external processes, ensuring that asynchronous operations can
;; communicate their results back to the main Emacs thread without blocking
;; the UI.
;;
;; This module now **owns and manages all its global IPC state**, making it
;; a self-contained and robust subsystem. The design centers on two primary
;; communication pathways, both dispatching to the main Emacs event loop.
;;
;; ## Key Features
;;
;; - **Thread-Safe Queue:** When running in an Emacs with thread support, a
;;   dedicated, mutex-protected queue (`loom--ipc-main-thread-queue`) is
;;   used for messages from background threads. This provides a direct,
;;   low-overhead in-memory communication channel.
;;
;; - **Process-Based IPC:** A long-lived pipe process (`loom--ipc-process`)
;;   serves as a general-purpose event source. It is used to asynchronously
;;   re-queue work onto the main thread's event loop, even from the main
;;   thread itself. This ensures a consistent, non-blocking asynchronous
;;   workflow. Data sent through the pipe is JSON-serialized.
;;
;; - **Polling-Based Draining:** The main thread is responsible for
;;   draining the in-memory queue by periodically calling
;;   `loom:ipc-drain-queue`. This is typically done within the main
;;   scheduler tick. This polling design avoids the complexity of a
;;   dedicated drain thread.
;;
;; - **Unified Dispatcher:** The function `loom:dispatch-to-main-thread`
;;   acts as a single, intelligent entry point. It automatically selects the
;;   correct communication channel (in-memory queue or process pipe) based
;;   on the execution context (background thread vs. main thread).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 's)

(require 'loom-log)
(require 'loom-lock)
(require 'loom-queue)
(require 'loom-errors)
(require 'loom-registry)
(require 'loom-promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom-promise-p "loom-promise")
(declare-function loom:pending-p "loom-promise")
(declare-function loom:resolve "loom-promise")
(declare-function loom:reject "loom-promise")
(declare-function loom-registry-get-promise-by-id "loom-registry")
(declare-function loom:deserialize-error "loom-errors")
(declare-function loom-error-p "loom-errors")
(declare-function loom:serialize-error "loom-errors")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State & Constants

(defvar loom--ipc-queue-mutex nil
  "A `loom:lock` (mutex) that provides thread-safe, exclusive access to
the `loom--ipc-main-thread-queue`. This is essential for preventing race
conditions when multiple threads enqueue messages simultaneously.

It is initialized by `loom:ipc-init` and is private to this module.")

(defvar loom--ipc-main-thread-queue nil
  "A thread-safe `loom:queue` for messages originating from background
threads and destined for the main Emacs thread. It is drained
periodically by `loom:ipc-drain-queue` on the main thread.

It is initialized by `loom:ipc-init` and is private to this module.")

(defvar loom--ipc-process nil
  "The long-lived `make-pipe-process` instance used for IPC. This process
acts as an event source for the main Emacs event loop. Messages sent to it
are received by the filter function (`loom--ipc-filter`) on the main
thread, providing a mechanism for asynchronous execution.

It is managed by `loom:ipc-init` and `loom:ipc-cleanup` and is private.")

(defvar loom--ipc-buffer nil
  "A dedicated temporary buffer used by the process filter function
`loom--ipc-filter` to accumulate incoming data chunks. This is necessary
because process output can arrive in arbitrary fragments, and this buffer
ensures we only process complete, newline-terminated lines.

It is managed by `loom:ipc-init` and `loom:ipc-cleanup` and is private.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-ipc-queue-uninitialized-error
  "Error signaled when an operation is attempted on the IPC queue
before it has been properly initialized by `loom:ipc-init`."
  'loom-error)

(define-error 'loom-ipc-process-error
  "Error signaled when the underlying IPC pipe process encounters a
fatal error or fails to initialize."
  'loom-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal IPC Helpers

(defun loom--ipc-enqueue (message)
  "Thread-safely enqueues a `MESSAGE` onto the main thread's IPC queue.

This is the primary entry point for a background thread to send data to
the main thread. It acquires a mutex lock to ensure that the queue
operation is atomic and safe from race conditions.

Arguments:
- `MESSAGE` (any): The message to enqueue, typically a plist.

Returns:
- `nil`.

Signals:
- `loom-ipc-queue-uninitialized-error`: If the IPC queue or its
  mutex has not been initialized via `loom:ipc-init`."
  ;; Ensure the core IPC components for threading are ready.
  (unless (and loom--ipc-queue-mutex loom--ipc-main-thread-queue)
    (signal 'loom-ipc-queue-uninitialized-error
            '(:message "Main thread IPC queue/mutex not initialized.")))
  ;; Lock the mutex, enqueue the message, and release the lock.
  (loom:with-mutex! loom--ipc-queue-mutex
    (loom:queue-enqueue loom--ipc-main-thread-queue message))
  (loom-log :debug (plist-get message :id) "Enqueued message for main thread.")
  nil)

(defun loom--ipc-parse-pipe-line (line-text)
  "Parses a single, newline-terminated JSON string from the IPC process.

This function decodes the JSON payload and dispatches it based on the
message `:type`. It is designed to be robust against malformed JSON
or unexpected message types.

Arguments:
- `LINE-TEXT` (string): A complete JSON string received from the pipe.

Returns: `nil`. Errors are logged but not re-thrown."
  (cl-block loom--ipc-parse-pipe-line
    ;; Ignore empty or whitespace-only lines.
    (when (s-blank? line-text)
      (cl-return-from loom--ipc-parse-pipe-line nil)))

  ;; Use a condition-case to gracefully handle parsing errors.
  (condition-case err
      ;; Configure JSON parsing to use plists and keywords for consistency.
      (let* ((json-object-type 'plist)
             (json-array-type 'list)
             (json-key-type 'keyword)
             (payload (json-read-from-string line-text))
             (msg-type (plist-get payload :type)))
        ;; Dispatch the message based on its type.
        (pcase msg-type
          (:promise-settled
           (loom:process-settled-on-main payload))
          (:log
           (let ((level (plist-get payload :level))
                 (message (plist-get payload :message)))
             (when (and level message)
               (loom-log level nil "IPC remote log: %s" message))))
          (_
           (loom-log :warn nil
                     "IPC filter received unknown message type: %S" msg-type))))
    (json-error
     (loom-log :error nil "JSON parse error in IPC: %S, line: %S"
               err line-text))
    (error
     (loom-log :error nil "General error parsing IPC message: %S, line: %S"
               err line-text))))

(defun loom--ipc-filter (process string)
  "Process filter function for `loom--ipc-process`.

This function is called by Emacs whenever `loom--ipc-process` writes to
its standard output. Since data can arrive in arbitrary chunks, this
function appends the incoming `STRING` to a dedicated buffer,
`loom--ipc-buffer`, and then processes any complete, newline-terminated
lines found in that buffer.

Arguments:
- `PROCESS` (process): The `make-pipe-process` instance (unused).
- `STRING` (string): The latest chunk of output from the process.

Returns: `nil`."
  (condition-case err
      (progn
        ;; Ensure the dedicated buffer for this filter is alive.
        (unless (buffer-live-p loom--ipc-buffer)
          (setq loom--ipc-buffer (generate-new-buffer " *loom-ipc-filter*"))
          (with-current-buffer loom--ipc-buffer
            ;; Disable multibyte chars for raw data processing.
            (setq-local enable-multibyte-characters nil)))

        ;; 1. Append the new chunk of data to our buffer.
        (with-current-buffer loom--ipc-buffer
          (save-excursion (goto-char (point-max)) (insert string)))

        ;; 2. Process all complete lines in the buffer.
        (with-current-buffer loom--ipc-buffer
          (let ((line-start (point-min)))
            (goto-char line-start)
            ;; Search for the next newline character.
            (while (re-search-forward "\n" nil t)
              (let* ((line-end (match-end 0))
                     ;; Extract the complete line without the newline.
                     (line-text (buffer-substring-no-properties
                                 line-start (1- line-end))))
                ;; Parse the line if it contains content.
                (unless (s-blank? line-text)
                  (loom--ipc-parse-pipe-line line-text)))
              ;; Move the start pointer to the beginning of the next line.
              (setq line-start (point)))
            ;; 3. Delete the processed lines from the buffer, leaving any
            ;;    partial line for the next invocation.
            (delete-region (point-min) line-start))))
    (error (loom-log :error nil "Error in IPC filter: %S" err)))
  nil)

(defun loom--ipc-sentinel (process event)
  "Sentinel function for `loom--ipc-process`.

This function is called by Emacs when the state of `loom--ipc-process`
changes (e.g., it exits or crashes). Its primary purpose is to detect
unexpected termination and trigger a cleanup and re-initialization
cycle to maintain system stability.

Arguments:
- `PROCESS` (process): The process whose state changed.
- `EVENT` (string): A string describing the state change event.

Returns: `nil`."
  (loom-log :warn nil "IPC process sentinel triggered: %s" (s-trim event))
  ;; If the process terminated unexpectedly, it's a critical failure.
  (when (string-match-p "\\(finished\\|exited\\|failed\\)" event)
    (loom-log :error nil "IPC process terminated unexpectedly. Cleaning up.")
    ;; Clean up all IPC resources to prevent a broken state.
    (loom:ipc-cleanup))
  nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public IPC API

(defun loom:process-settled-on-main (payload)
  "Processes a settlement message that has arrived on the main thread.

This function is the final destination for promise settlement messages,
whether they arrive from the thread queue or the process pipe. It finds the
target promise in the global registry and settles it with the provided
value or error.

Arguments:
- `PAYLOAD` (plist): A plist containing settlement data. Must include `:id`
  and either `:value` or `:error`. May also include `:value-is-json` hint.

Returns:
- `nil`.

Side Effects:
- Resolves or rejects a registered `loom-promise`, which will trigger its
  callback chain to execute on the main thread."
  (let* ((id (plist-get payload :id))
         (promise (loom-registry-get-promise-by-id id)))
    (if (and promise (loom:pending-p promise))
        ;; The promise exists and is waiting for settlement.
        (let* ((value (plist-get payload :value))
               (error-data (plist-get payload :error))
               (value-is-json (plist-get payload :value-is-json))
               ;; If value was JSON-encoded for transport, decode it now.
               (final-value (if (and value-is-json (stringp value))
                                (json-read-from-string value)
                              value))
               ;; If the error was serialized for transport, deserialize it.
               (final-error (if (and error-data (not (loom-error-p error-data)))
                                (loom:deserialize-error error-data)
                              error-data)))
          ;; Settle the promise with either the final value or the final error.
          (if final-error
              (loom:reject promise final-error)
            (loom:resolve promise final-value)))
      ;; This can happen if a promise was cancelled or timed out before
      ;; the settlement message arrived. It's not necessarily an error.
      (loom-log :debug id
                "IPC received settlement for non-pending/unknown promise."))))

;;;###autoload
(defun loom:ipc-init ()
  "Initializes all IPC mechanisms, including the thread queue and the
process pipe. This function is idempotent and safe to call multiple times.

Returns: `nil`."
  (loom-log :info nil "Initializing Loom IPC system.")

  ;; Section 1: Initialize components for thread-based communication.
  ;; This only runs if the current Emacs supports `make-thread`.
  (when (fboundp 'make-thread)
    (unless loom--ipc-queue-mutex
      (setq loom--ipc-queue-mutex
            (loom:lock "loom-ipc-queue-mutex" :mode :thread)))
    (unless (loom-queue-p loom--ipc-main-thread-queue)
      (setq loom--ipc-main-thread-queue (loom:queue))))

  ;; Section 2: Initialize the process-based communication channel.
  ;; This runs on all Emacs versions and is the primary async mechanism.
  (unless (and loom--ipc-process (process-live-p loom--ipc-process))
    (condition-case err
        (progn
          (setq loom--ipc-buffer
                (generate-new-buffer " *loom-ipc-filter*"))
          (setq loom--ipc-process
                (make-pipe-process
                 :name "loom-ipc-listener"
                 :noquery t
                 :coding 'utf-8-emacs-unix
                 :filter #'loom--ipc-filter
                 :sentinel #'loom--ipc-sentinel)))
      (error
       ;; If process creation fails, log the error and ensure a clean state.
       (loom-log :error nil "Failed to initialize IPC pipe process: %S" err)
       (when loom--ipc-buffer (kill-buffer loom--ipc-buffer))
       (setq loom--ipc-process nil loom--ipc-buffer nil)
       (signal 'loom-ipc-process-error (list err)))))
  nil)

;;;###autoload
(defun loom:ipc-cleanup ()
  "Shuts down and cleans up all IPC resources.

This function stops the IPC process, kills its associated buffer, and
resets all global state variables. It is idempotent and safe to call
even if the system is already clean. It is hooked into `kill-emacs-hook`
to ensure graceful shutdown.

Returns: `nil`."
  (loom-log :info nil "Cleaning up IPC resources.")
  ;; Reset thread-related state variables.
  (setq loom--ipc-queue-mutex nil)
  (setq loom--ipc-main-thread-queue nil)

  ;; Shut down the long-lived IPC process.
  (when (and loom--ipc-process (process-live-p loom--ipc-process))
    (delete-process loom--ipc-process))
  (setq loom--ipc-process nil)

  ;; Clean up the dedicated IPC filter buffer.
  (when (and loom--ipc-buffer (buffer-live-p loom--ipc-buffer))
    (kill-buffer loom--ipc-buffer))
  (setq loom--ipc-buffer nil)
  nil)

;;;###autoload
(defun loom:ipc-drain-queue ()
  "Drains and processes all messages from the in-memory IPC queue.

This function should be called periodically from the main thread,
typically as part of a central scheduler's tick. It performs a two-step
process to minimize the time a mutex is held:
1. Atomically transfer all messages from the global queue to a local list.
2. Process the messages from the local list, now that the lock is released.

Returns:
- (integer): The number of messages that were processed."
  (let ((messages-to-process '())
        (processed-count 0))
    ;; Step 1: Atomically grab all messages from the shared queue. This
    ;; block is kept as short as possible to avoid blocking producer threads.
    (when (and loom--ipc-queue-mutex loom--ipc-main-thread-queue)
      (loom:with-mutex! loom--ipc-queue-mutex
        (while (not (loom:queue-empty-p loom--ipc-main-thread-queue))
          (push (loom:queue-dequeue loom--ipc-main-thread-queue)
                messages-to-process))))

    ;; Step 2: Process the collected messages outside the mutex lock.
    ;; This allows other threads to enqueue new messages while we work.
    (when messages-to-process
      ;; Messages were pushed onto the list, so nreverse restores FIFO order.
      (setq messages-to-process (nreverse messages-to-process))
      (setq processed-count (length messages-to-process))
      (loom-log :debug nil
                "Draining %d messages from IPC queue." processed-count)
      ;; Process each message, which typically involves settling a promise.
      (dolist (message messages-to-process)
        (loom:process-settled-on-main message)))
    processed-count))

;;;###autoload
(defun loom:dispatch-to-main-thread (promise &optional message-type data)
  "Dispatches a settlement message for a `PROMISE` to the main thread.

This is the universal function for sending a promise result back for
processing on the main Emacs event loop. It intelligently chooses the
correct communication channel based on the current context.

Arguments:
- `PROMISE` (loom-promise): The promise object being settled.
- `MESSAGE-TYPE` (symbol, optional): The message type, which defaults to
  `:promise-settled`.
- `DATA` (plist, optional): The message payload, typically `(:value ...)`
  or `(:error ...)`.

Returns: `nil`."
  (unless (loom-promise-p promise)
    (signal 'wrong-type-argument (list 'loom-promise-p promise)))

  ;; Construct the full message payload.
  (let* ((promise-id (loom-promise-id promise))
         (full-payload (append `(:id ,promise-id
                                 :type ,(or message-type :promise-settled))
                               data)))
    (cond
      ;; Path 1: Executing in a background thread.
      ;; Use the fast, in-memory, thread-safe queue. Data is passed directly
      ;; as a Lisp object, as we are in the same Emacs process.
      ((and (fboundp 'current-thread) (not (eq (current-thread) (thread-main))))
       (condition-case err
           (loom--ipc-enqueue full-payload)
         (error (loom-log :error promise-id
                          "Thread queue dispatch failed: %S" err))))

      ;; Path 2: Executing on the main thread or in a process context.
      ;; Use the pipe process to schedule the work asynchronously on the
      ;; main event loop. This is crucial for maintaining a non-blocking
      ;; pattern even when an async operation finishes immediately.
      ((and loom--ipc-process (process-live-p loom--ipc-process))
       (condition-case err
           (let* ((payload-to-send (copy-sequence full-payload))
                  (error-data (plist-get payload-to-send :error))
                  (value-data (plist-get payload-to-send :value)))

             ;; If the payload contains a structured error, it must be
             ;; serialized into a plist before JSON encoding.
             (when (and error-data (loom-error-p error-data))
               (setf (plist-get payload-to-send :error)
                     (loom:serialize-error error-data)))

             ;; If the value is a complex Lisp type (list/hash), it must
             ;; be serialized to a JSON string. We add a hint so the receiver
             ;; knows to parse it.
             (when (or (listp value-data) (hash-table-p value-data))
               (setf (plist-get payload-to-send :value)
                     (json-encode value-data))
               (setf (plist-get payload-to-send :value-is-json) t))

             ;; Encode the final payload to a JSON string and send it to the
             ;; pipe, followed by a newline to mark the end of the message.
             (let ((json-message (json-encode payload-to-send)))
               (process-send-string loom--ipc-process
                                    (format "%s\n" json-message))))
         (error (loom-log :error promise-id
                          "IPC process dispatch failed: %S" err))))

      ;; Path 3: Fallback for when the IPC process isn't ready.
      ;; This is a last resort to prevent losing the message. It uses
      ;; `run-at-time` to schedule the processing on a future tick of the
      ;; event loop, simulating the asynchronicity of the pipe.
      (t
       (loom-log :warn promise-id "IPC dispatch falling back to run-at-time.")
       (run-at-time 0 nil #'loom:process-settled-on-main full-payload)))
    nil))

;; Register a hook to ensure IPC resources are released when Emacs exits.
;; This prevents orphaned processes or memory leaks.
(add-hook 'kill-emacs-hook #'loom:ipc-cleanup)

(provide 'loom-ipc)
;;; loom-ipc.el ends here