;;; loom-ipc.el --- Inter-Process/Thread Communication (IPC) -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the core Inter-Process/Thread Communication (IPC)
;; mechanisms for the Loom concurrency library. It enables safe and
;; efficient message passing between different Emacs Lisp threads and
;; external processes.
;;
;; The central design principle is that all state-changing operations, such as
;; settling a promise, must occur on the main Emacs thread. This module
;; provides the transport layer to make that happen. Messages from background
;; threads are placed on a queue that is periodically drained by the main
;; thread's scheduler, ensuring thread safety and preventing race conditions.
;;
;; ## Key Features
;;
;; - **Main Thread Queue:** A dedicated, thread-safe queue
;;   (`loom--ipc-main-thread-queue`) serves as the single inbox for all
;;   messages from background threads destined for the main thread.
;;
;; - **Inter-Emacs-Process Communication (IEPC):** A robust mechanism for
;;   two or more Emacs instances to communicate using named pipes (FIFOs),
;;   managed by the `loom-pipe` module. Data is JSON-serialized for transit.
;;
;; - **Intelligent Dispatcher:** The function `loom:dispatch-to-main-thread`
;;   acts as a single entry point, automatically selecting the correct
;;   communication channel (main thread queue or named pipe) based on the
;;   execution context.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 's)

(require 'loom-log)
(require 'loom-errors)
(require 'loom-pipe)
(require 'loom-lock)
(require 'loom-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom:deferred "loom-config")
(declare-function loom:deserialize-error "loom-errors")
(declare-function loom:resolve "loom-promise")
(declare-function loom:reject "loom-promise")
(declare-function loom:pending-p "loom-promise")
(declare-function loom-registry-get-promise-by-id "loom-registry")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State & Constants

(defvar loom--ipc-main-thread-queue nil
  "A thread-safe `loom:queue` for messages from background threads.
This queue is the primary mechanism for background threads to send
promise settlement messages to the main Emacs thread for safe
processing. It is protected by `loom--ipc-queue-mutex` and is
drained by `loom:ipc-drain-queue` during the main scheduler tick.")

(defvar loom--ipc-queue-mutex nil
  "A mutex protecting `loom--ipc-main-thread-queue`.
This lock ensures that multiple background threads can enqueue
messages concurrently without corrupting the queue's internal state.")

;; IEPC specific loom-pipe instances
(defvar loom--ipc-input-pipe nil
  "The `loom-pipe` instance for reading from this Emacs instance's
named input pipe (FIFO). When messages arrive from another Emacs
process, they are read through this pipe, parsed, and enqueued to
the `loom--ipc-main-thread-queue` for processing.")

(defvar loom--ipc-output-pipe nil
  "The `loom-pipe` instance for writing to a target Emacs instance's
named input pipe (FIFO). This is used to send serialized
settlement messages to another Emacs process.")

(defvar loom--ipc-my-id nil
  "A unique string identifier for this Emacs instance.
This ID is used to construct the filename for this instance's
input FIFO. It is set during `loom:ipc-init`.")

(defvar loom--ipc-target-instance-id nil
  "The string identifier of the target Emacs instance for IEPC.
This is used to construct the path to the target's input FIFO,
allowing this instance to send messages to it. It is set during
`loom:ipc-init`.")

(defvar loom--ipc-listen-for-incoming-p nil
  "A boolean indicating if this instance should listen for IEPC messages.
If non-nil, an input pipe is created during `loom:ipc-init`,
allowing other Emacs processes to send messages to this one.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-ipc-error
  "Generic IPC error."
  'loom-error)

(define-error 'loom-ipc-uninitialized-error
  "IPC not initialized."
  'loom-ipc-error)

(define-error 'loom-ipc-process-error
  "IPC process failed."
  'loom-ipc-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal IPC Helpers

(defun loom--ipc-get-fifo-path (instance-id)
  "Construct the full, predictable path for an INSTANCE-ID's FIFO.
This helper function centralizes the logic for creating named pipe
paths. It uses Emacs's `temporary-file-directory` variable to
ensure the pipes are created in a portable, system-appropriate
location, rather than hardcoding `/tmp/`.

Arguments:
- `INSTANCE-ID` (string): The unique identifier for the Emacs instance.

Returns:
A string containing the full, absolute path for the FIFO file."
  (expand-file-name (format "loom-ipc-%s-in.fifo" instance-id)
                    temporary-file-directory))

(defun loom--ipc-settle-promise-from-payload (payload)
  "Settle a promise using the data from a PAYLOAD on the main thread.
This function is the final destination for messages that have arrived
via IPC and have been drained from the queue by the main scheduler.
It looks up the promise by its ID in the global registry and
settles it with the provided value or error, which in turn
triggers the promise's callback chain.

Arguments:
- `PAYLOAD` (plist): A fully deserialized message payload,
  containing at least an `:id` and either a `:value` or `:error`.

Returns: `nil`.

Side Effects:
- Calls `loom:resolve` or `loom:reject` on a registered promise. This
  alters the promise's state and schedules its callbacks for
  asynchronous execution on the schedulers."
  (let* ((id (plist-get payload :id))
         (promise (loom-registry-get-promise-by-id id)))
    (if (and promise (loom:pending-p promise))
        (let ((value (plist-get payload :value))
              (error-data (plist-get payload :error)))
          (if error-data
              (loom:reject promise error-data)
            (loom:resolve promise value)))
      ;; This is a normal, expected condition if a promise was cancelled or
      ;; timed out before its settlement message arrived from a thread.
      (loom-log :debug id "IPC received settlement for non-pending promise."))))

(defun loom--ipc-fully-deserialize-payload (payload)
  "Fully deserialize a raw PAYLOAD from an IEPC pipe.
This function is responsible for the second layer of deserialization
that is necessary for messages received over IEPC. Because JSON
cannot natively represent all Lisp types (like `loom-error` structs
or complex lists), such values are first encoded into a JSON string
and embedded within the main JSON payload. This function reverses
that process.

Arguments:
- `PAYLOAD` (plist): A plist parsed from the top-level JSON message.

Returns:
A new plist with all values fully deserialized into proper Lisp objects."
  (let* ((value (plist-get payload :value))
         (error-data (plist-get payload :error))
         (value-is-json (plist-get payload :value-is-json))
         (final-payload (copy-sequence payload)))

    ;; If the `:value-is-json` hint is present, parse the value string.
    (when (and value-is-json (stringp value))
      (setf (plist-get final-payload :value) (json-read-from-string value)))

    ;; If the error data is a plist (indicating it was a serialized
    ;; `loom-error`), deserialize it back into a struct.
    (when (and error-data (plistp error-data))
      (setf (plist-get final-payload :error) (loom:deserialize-error error-data)))

    ;; Remove the hint, as it's no longer needed.
    (setf (plist-get final-payload :value-is-json) nil)
    final-payload))

(defun loom--ipc-parse-and-process-line (line-text)
  "Parse a JSON string from an IEPC pipe and enqueue it for processing.
This function acts as the entry point for raw data coming from an
external Emacs process. It is designed to be robust, logging any
parsing errors without propagating them, which prevents a single
malformed message from crashing the entire IPC listener.

Arguments:
- `LINE-TEXT` (string): A complete, newline-terminated JSON string
  received from the pipe.

Returns: `nil`.

Side Effects:
- Enqueues a fully deserialized payload to the main thread queue,
  which makes it available to the main scheduler."
  (when-let ((trimmed-line (s-trim line-text)))
    (condition-case err
        (let* ((json-object-type 'plist)
               (json-array-type 'list)
               (json-key-type 'keyword)
               (raw-payload (json-read-from-string trimmed-line))
               (final-payload (loom--ipc-fully-deserialize-payload raw-payload)))
          (loom-log :debug nil "IPC: Deserialized payload: %S" final-payload)
          ;; Enqueue the parsed message onto the main thread's queue.
          (loom:with-mutex! loom--ipc-queue-mutex
            (loom:queue-enqueue loom--ipc-main-thread-queue final-payload)))
      (json-error (loom-log :error nil "IPC: JSON parse error: %S" err))
      (error (loom-log :error nil "IPC: Error processing line: %S" err)))))

(defun loom--ipc-filter (process string)
  "Process filter for an IEPC input pipe. Buffers and processes lines.
This function is attached to the pipe's underlying process and is
called by Emacs whenever new data arrives. Because data can arrive
in arbitrary chunks, this function appends the data to a buffer and
processes only complete, newline-terminated lines.

Arguments:
- `PROCESS` (process): The process that produced the output.
- `STRING` (string): The latest chunk of output from the process.

Returns: `nil`.

Side Effects:
- Modifies the buffer associated with `PROCESS`.
- Calls `loom--ipc-parse-and-process-line`, which enqueues tasks."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-max))
          (insert string))
        (while (string-match "\n" (buffer-string))
          (let* ((line (buffer-substring-no-properties
                        (point-min) (match-beginning 0))))
            (delete-region (point-min) (match-end 0))
            (loom--ipc-parse-and-process-line line)))))))

(defun loom--ipc-sentinel (process event)
  "Sentinel for an IPC pipe process. Cleans up on unexpected termination.
This function is attached to the pipe's process to monitor its
state. If the process dies unexpectedly, it triggers a full IPC
cleanup to prevent the system from being left in a broken state.

Arguments:
- `PROCESS` (process): The process whose state changed.
- `EVENT` (string): A string describing the state change event.

Returns: `nil`.

Side Effects:
- Calls `loom:ipc-cleanup` if the process terminates unexpectedly."
  (loom-log :warn nil "IPC sentinel for process %S: %s" process (s-trim event))
  (when (string-match-p "\\(finished\\|exited\\|failed\\)" event)
    (loom-log :error nil "IPC process terminated unexpectedly. Cleaning up.")
    (loom:ipc-cleanup)))

(defun loom--ipc-init-thread-components ()
  "Initialize the components for thread-based communication.
This sets up the mutex and queue used to receive messages from
background threads. It only runs if the Emacs instance supports
native threads.

Returns: `nil`.

Side Effects:
- Modifies the global `loom--ipc-queue-mutex` and
  `loom--ipc-main-thread-queue` variables."
  (when (fboundp 'make-thread)
    (unless loom--ipc-queue-mutex
      (setq loom--ipc-queue-mutex (loom:lock "loom-ipc-queue-mutex")))
    (unless loom--ipc-main-thread-queue
      (setq loom--ipc-main-thread-queue (loom:queue)))))

(defun loom--ipc-init-iepc-pipes ()
  "Initialize the Inter-Emacs-Process Communication (IEPC) pipes.
This function creates the named pipes (FIFOs) and starts the
underlying `cat` processes needed for communication between
separate Emacs instances.

Returns: `nil`.

Side Effects:
- Creates FIFO files on the filesystem.
- Starts external processes via `loom:pipe`.
- Modifies global pipe variables (`loom--ipc-input-pipe`, etc.).

Signals:
- `loom-ipc-process-error`: If `loom:pipe` fails."
  (let ((my-input-path (loom--ipc-get-fifo-path loom--ipc-my-id))
        (target-output-path (when loom--ipc-target-instance-id
                              (loom--ipc-get-fifo-path loom--ipc-target-instance-id))))
    (loom-log :info nil "IPC: Setting up IEPC for instance '%s'." loom--ipc-my-id)
    (condition-case err
        (progn
          (when loom--ipc-listen-for-incoming-p
            (loom-log :info nil "IPC: Listening on pipe: %s" my-input-path)
            (setq loom--ipc-input-pipe
                  (loom:pipe :path my-input-path :mode :read
                             :filter #'loom--ipc-filter
                             :sentinel #'loom--ipc-sentinel)))
          (when loom--ipc-target-instance-id
            (loom-log :info nil "IPC: Targeting pipe: %s" target-output-path)
            (setq loom--ipc-output-pipe
                  (loom:pipe :path target-output-path :mode :write
                             :sentinel #'loom--ipc-sentinel))))
      (error
       (loom-log :error nil "IPC: Failed to initialize IEPC pipes: %S" err)
       (loom:ipc-cleanup)
       (signal 'loom-ipc-process-error
               `(:message "Failed to init IEPC pipes" :cause ,err))))))

(defun loom--ipc-serialize-payload-for-dispatch (payload)
  "Serialize PAYLOAD for dispatch via an IEPC pipe.
This is the counterpart to `loom--ipc-fully-deserialize-payload`.
It prepares a Lisp plist for transport over a text-based medium
by encoding complex values into JSON strings.

Arguments:
- `PAYLOAD` (plist): The original Lisp message payload.

Returns:
A JSON-encoded string ready for dispatch."
  (let* ((payload-copy (copy-sequence payload))
         (error-data (plist-get payload-copy :error))
         (value-data (plist-get payload-copy :value)))
    (when (and error-data (loom-error-p error-data))
      (setf (plist-get payload-copy :error)
            (loom:serialize-error error-data)))
    (when (or (listp value-data) (hash-table-p value-data))
      (setf (plist-get payload-copy :value) (json-encode value-data))
      (setf (plist-get payload-copy :value-is-json) t))
    (json-encode payload-copy)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public IPC API

;;;###autoload
(cl-defun loom:ipc-init (&key my-id target-instance-id
                             (listen-for-incoming-p t))
  "Initialize all IPC mechanisms. This function is idempotent.
This function sets up the necessary infrastructure for both
inter-thread communication (if supported) and inter-process
communication via named pipes.

Arguments:
- `:MY-ID` (string, optional): A unique string identifier for this
  Emacs instance, used for naming its input FIFO. Defaults to the
  current process ID.
- `:TARGET-INSTANCE-ID` (string, optional): The ID of the target Emacs
  instance for sending messages. If non-nil, an output pipe is created.
- `:LISTEN-FOR-INCOMING-P` (boolean, optional): If t (the default),
  create an input pipe to receive messages from other processes.

Returns: `nil`.

Side Effects:
- Modifies global state variables (`loom--ipc-my-id`, etc.).
- Initializes the main thread queue and its mutex.
- May create FIFO files on the filesystem.
- May start external `cat` processes to manage the FIFOs.

Signals:
- `loom-ipc-process-error`: If a required underlying process (e.g.,
  for a pipe) fails to initialize."
  (loom-log :info nil "IPC: Initializing Loom IPC system.")
  (setq loom--ipc-my-id (or my-id (format "%d" (emacs-pid)))
        loom--ipc-target-instance-id target-instance-id
        loom--ipc-listen-for-incoming-p listen-for-incoming-p)

  (loom--ipc-init-thread-components)
  (when (or listen-for-incoming-p target-instance-id)
    (loom--ipc-init-iepc-pipes))

  (loom-log :info nil "IPC: System initialized.")
  nil)

;;;###autoload
(defun loom:ipc-cleanup ()
  "Shut down and clean up all IPC resources. This function is idempotent.
It is automatically called on Emacs shutdown via a hook.

Returns: `nil`.

Side Effects:
- Terminates all IPC-related processes via `loom:pipe-cleanup`.
- Deletes any created FIFO files from the filesystem.
- Kills any associated buffers.
- Resets all global IPC state variables to `nil`."
  (loom-log :info nil "IPC: Cleaning up resources.")
  (setq loom--ipc-main-thread-queue nil loom--ipc-queue-mutex nil)
  (when loom--ipc-input-pipe (loom:pipe-cleanup loom--ipc-input-pipe))
  (setq loom--ipc-input-pipe nil)
  (when loom--ipc-output-pipe (loom:pipe-cleanup loom--ipc-output-pipe))
  (setq loom--ipc-output-pipe nil)
  (setq loom--ipc-my-id nil
        loom--ipc-target-instance-id nil
        loom--ipc-listen-for-incoming-p nil)
  (loom-log :info nil "IPC: Cleanup complete.")
  nil)

;;;###autoload
(defun loom:ipc-drain-queue ()
  "Drain and process all messages from the main thread IPC queue.
This function is a critical part of the main scheduler tick. It
safely transfers all pending messages from the shared, thread-safe
queue to a local list and then processes them one by one on the
main thread. This design ensures that the mutex protecting the
queue is held for the shortest possible time, minimizing contention.

Returns: `nil`.

Side Effects:
- Dequeues all items from `loom--ipc-main-thread-queue`.
- Calls `loom--ipc-settle-promise-from-payload` for each message,
  which in turn settles promises and triggers their callbacks."
  (when loom--ipc-main-thread-queue
    (let (messages-to-process)
      ;; Atomically grab all messages from the shared queue.
      (loom:with-mutex! loom--ipc-queue-mutex
        (while (not (loom:queue-empty-p loom--ipc-main-thread-queue))
          (push (loom:queue-dequeue loom--ipc-main-thread-queue)
                messages-to-process)))
      ;; Process the collected messages on the main thread.
      (when messages-to-process
        (dolist (payload (nreverse messages-to-process))
          (loom--ipc-settle-promise-from-payload payload))))))

;;;###autoload
(defun loom:dispatch-to-main-thread (promise &optional message-type data)
  "Dispatch a settlement message for a PROMISE to be processed.
This is the universal function for sending a promise result back
for processing on the main Emacs event loop. It intelligently
chooses the correct communication channel based on the current
execution context, ensuring all paths are asynchronous.

The function determines the dispatch path as follows:
1.  If called from a background thread, it enqueues the payload
    to the thread-safe `loom--ipc-main-thread-queue`.
2.  If called from the main thread with an active IEPC output pipe,
    it serializes the payload and sends it to the external process.
3.  As a fallback (e.g., on the main thread with no IEPC), it
    schedules the settlement for a future tick of the event loop
    using `loom:deferred` to maintain asynchronicity.

Arguments:
- `PROMISE` (loom-promise): The promise object being settled. This
  is used to construct the message payload.
- `MESSAGE-TYPE` (symbol, optional): The type of message, which
  defaults to `:promise-settled`. This is for potential future
  expansion with other message types.
- `DATA` (plist, optional): The core message payload, typically
  containing a `:value` or `:error` key for settlement.

Returns: `nil`. The function's purpose is to initiate an
asynchronous action, not to return a value.

Side Effects:
- Enqueues a Lisp object onto the `loom--ipc-main-thread-queue`.
- OR sends a serialized JSON string to an external OS process.
- OR schedules a lambda function on the macrotask scheduler.

Signals:
- `wrong-type-argument`: If `PROMISE` is not a `loom-promise` object."
  (unless (loom-promise-p promise)
    (signal 'wrong-type-argument (list 'loom-promise-p promise)))

  (let* ((promise-id (loom-promise-id promise))
         (payload (append `(:id ,promise-id
                            :type ,(or message-type :promise-settled))
                          data)))
    (cond
     ;; Path 1: In a background thread. Enqueue to the main thread queue.
     ((and (fboundp 'make-thread) (not (eq (current-thread) main-thread)))
      (loom-log :info promise-id "IPC: Dispatching from background thread.")
      (loom:with-mutex! loom--ipc-queue-mutex
        (loom:queue-enqueue loom--ipc-main-thread-queue payload)))

     ;; Path 2: In main thread with an active IEPC output pipe. Send via pipe.
     ((and loom--ipc-output-pipe
           (process-live-p (loom-pipe-process loom--ipc-output-pipe)))
      (loom-log :info promise-id "IPC: Dispatching via IEPC to target '%s'."
                loom--ipc-target-instance-id)
      (let ((json-msg (loom--ipc-serialize-payload-for-dispatch payload)))
        (loom:pipe-send loom--ipc-output-pipe (format "%s\n" json-msg))))

     ;; Path 3: Fallback. Schedule for a future tick on the main thread.
     (t
      (loom-log :warn promise-id
                "IPC: No async channel. Scheduling for deferred processing.")
      (loom:deferred (lambda () (loom--ipc-settle-promise-from-payload payload)))))
    nil))

;; Register a hook to ensure IPC resources are released when Emacs exits.
(add-hook 'kill-emacs-hook #'loom:ipc-cleanup)

(provide 'loom-ipc)
;;; loom-ipc.el ends here