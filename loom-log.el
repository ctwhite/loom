;;; loom-log.el --- Logging for the Loom async library -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides the core logging definitions for the Loom asynchronous
;; library. It offers a centralized, customizable, and thread-safe mechanism
;; for emitting internal messages, useful for both debugging and understanding
;; runtime behavior.
;;
;; Key features:
;; - **Thread-Safe**: Log messages from any background thread are safely
;;   enqueued and processed on the main thread, preventing errors.
;; - **Customizable Logging Hook**: `loom-log-hook` allows users to
;;   intercept and process all log messages, for example, to redirect them
;;   to a dedicated buffer or file.
;; - **Flexible Default Logger**: If no custom hook is set, messages are
;;   printed to a dedicated buffer, with fine-grained control over format,
;;   timestamps, and log levels via `defcustom` variables.
;; - **Log Levels**: Supports standard log levels (`:trace`, `:debug`, `:info`,
;;   `:warn`, `:error`, and `:fatal`).
;; - **Automatic Buffer Management**: The log buffer can be automatically
;;   trimmed to a maximum size to prevent memory issues.

;;; Code:

(require 'cl-lib)

(require 'loom-lock)
(require 'loom-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom:lock "loom-lock")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom--log-message-queue nil
  "A thread-safe queue for log messages from background threads.
This queue is necessary because logging operations (like running hooks
or modifying buffers) can only be done safely on the main thread.
Background threads enqueue their log requests here, and the queue is
drained on the main thread by `loom:log-process-queue`.")

(defvar loom--log-queue-mutex (loom:lock "loom-log-queue-mutex")
  "A mutex protecting `loom--log-message-queue` from concurrent access.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-log-enabled-p t
  "If non-nil, enable logging messages from the Loom library.
When nil, `loom-log' will do nothing, incurring zero performance cost."
  :type 'boolean
  :group 'loom)

(defcustom loom-log-hook nil
  "A hook for intercepting and handling all log messages from Loom.

Functions added to this hook should accept four arguments:
1. LEVEL (keyword): The log level, e.g., `:debug`, `:info`.
2. TARGET-SYMBOL (symbol|nil): An optional symbol for context.
3. FMT (string): The format-control string.
4. ARGS (list): A list containing the arguments for the format string."
  :type 'hook
  :group 'loom)

(defcustom loom-log-default-level :debug
  "The minimum level for messages shown in the default log buffer.
This setting only applies when `loom-log-hook' is nil.
Levels are: `:trace`, `:debug`, `:info`, `:warn`, `:error`, `:fatal`."
  :type '(choice (const :tag "Trace" :trace)
                 (const :tag "Debug" :debug)
                 (const :tag "Info" :info)
                 (const :tag "Warning" :warn)
                 (const :tag "Error" :error)
                 (const :tag "Fatal" :fatal))
  :group 'loom)

(defcustom loom-log-buffer-name "*loom-log*"
  "Name of the buffer used for default logging output."
  :type 'string
  :group 'loom)

(defcustom loom-log-timestamp-format "%Y-%m-%d %H:%M:%S.%3N"
  "Format string for timestamps in log messages.
See `format-time-string` for details. Set to nil to disable timestamps."
  :type '(choice (string :tag "Timestamp format")
                 (const :tag "No timestamp" nil))
  :group 'loom)

(defcustom loom-log-max-buffer-size 500000
  "Maximum size in characters for the log buffer.
When the buffer exceeds this size, the oldest lines are removed.
Set to nil to disable automatic trimming."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Max characters"))
  :group 'loom)

(defcustom loom-log-format-function #'loom--default-log-formatter
  "A function to format a log entry into a final string.
The function should accept three arguments:
1. TIMESTAMP (string): The formatted timestamp.
2. LEVEL (keyword): The log level.
3. TARGET (string): The formatted target symbol.
4. MESSAGE (string): The formatted message content.

This allows complete customization of the log line format."
  :type 'function
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Logic

(defconst *loom-log-level-values*
  '((:trace . 0) (:debug . 1) (:info . 2) (:warn . 3)
    (:error . 4) (:fatal . 5))
  "Internal alist mapping log level keywords to integers for comparison.")

(defun loom--get-log-level-value (level)
  "Return the integer value for a given log `LEVEL` keyword."
  (cdr (assoc level *loom-log-level-values*)))

(defun loom--default-log-formatter (timestamp level target message)
  "The default function to format a log entry into a string."
  (let ((timestamp-prefix (if (string-empty-p timestamp) ""
                            (concat timestamp " ")))
        (level-str (upcase (substring (symbol-name level) 1))))
    (format "%s[%-5s] %s%s\n" timestamp-prefix level-str target message)))

(defun loom--default-log-function (level target-symbol fmt &rest args)
  "Default log function that prints to the loom log buffer."
  (let ((level-val (loom--get-log-level-value level))
        (min-level-val (loom--get-log-level-value loom-log-default-level)))
    (when (and level-val (>= level-val min-level-val))
      (let* ((target-prefix (if target-symbol
                                (format "[%S] " target-symbol)
                              ""))
             (timestamp (if loom-log-timestamp-format
                            (format-time-string loom-log-timestamp-format)
                          ""))
             (message-text (apply #'format fmt args))
             (full-message (funcall loom-log-format-function
                                    timestamp level target-prefix message-text)))
        (with-current-buffer (get-buffer-create loom-log-buffer-name)
          (let ((inhibit-read-only t)
                (moving-to-end (> (point) (point-min))))
            (goto-char (point-max))
            (insert full-message)
            (when (and loom-log-max-buffer-size
                       (> (point) loom-log-max-buffer-size))
              (goto-char (point-min))
              (delete-region (point-min)
                             (- (point-max) loom-log-max-buffer-size)))
            (when (and moving-to-end (get-buffer-window (current-buffer)))
              (with-selected-window (get-buffer-window (current-buffer))
                (goto-char (point-max))))))))))

(defun loom--log-dispatch (level target-symbol fmt args)
  "Dispatch a single log message to the configured sink.
This is the core logic that either runs the custom hook or calls
the default logging function. It is intended to be called only on
the main thread.

Arguments:
- `LEVEL` (keyword): The log level.
- `TARGET-SYMBOL` (symbol|nil): The context symbol.
- `FMT` (string): The format string.
- `ARGS` (list): The format arguments."
  (if loom-log-hook
      (apply #'run-hook-with-args 'loom-log-hook level target-symbol fmt args)
    (apply #'loom--default-log-function level target-symbol fmt args)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom-log (level target-symbol fmt &rest args)
  "Log a message for the Loom library. This function is thread-safe.
If called from a background thread, it enqueues the message for
later processing on the main thread. If called from the main
thread, it dispatches the message immediately.

Arguments:
- `LEVEL` (keyword): The log level, e.g., `:debug`, `:info`, `:warn`.
- `TARGET-SYMBOL` (symbol|nil): An optional symbol for context.
- `FMT` (string): The format-control string.
- `ARGS` (list): Arguments for the format string.

Returns: `nil`."
  (when loom-log-enabled-p
    ;; Initialize queue on first use.
    (unless loom--log-queue-mutex
      (setq loom--log-queue-mutex (loom:lock "loom-log-queue-mutex")))
    (unless loom--log-message-queue
      (setq loom--log-message-queue (loom:queue)))

    ;; Check if we are running in a background thread.
    (if (and (fboundp 'make-thread) (not (eq (current-thread) main-thread)))
        ;; If so, enqueue the message for the main thread to process later.
        (loom:with-mutex! loom--log-queue-mutex
          (loom:queue-enqueue loom--log-message-queue
                              (list level target-symbol fmt args)))
      ;; Otherwise, we are on the main thread, so dispatch immediately.
      (loom--log-dispatch level target-symbol fmt args))))

;;;###autoload
(defun loom:log-process-queue ()
  "Process all pending log messages from background threads.
This function should be called periodically from the main thread's
event loop (e.g., the scheduler tick). It drains the message queue
and dispatches each message to the configured logging sink.

Returns: `nil`.

Side Effects:
- Drains `loom--log-message-queue`.
- Calls the logging hook or default logger for each message."
  (when loom--log-message-queue
    (let (messages-to-process)
      ;; Atomically grab all messages to hold the lock for a minimal time.
      (loom:with-mutex! loom--log-queue-mutex
        (while (not (loom:queue-empty-p loom--log-message-queue))
          (push (loom:queue-dequeue loom--log-message-queue)
                messages-to-process)))
      ;; Process the collected messages on the main thread.
      (when messages-to-process
        (dolist (msg (nreverse messages-to-process))
          (apply #'loom--log-dispatch (car msg) (cadr msg) (caddr msg) (cadddr msg)))))))

;;;###autoload
(defun loom/log-clear-buffer ()
  "Clear the loom log buffer."
  (interactive)
  (when (get-buffer loom-log-buffer-name)
    (with-current-buffer loom-log-buffer-name
      (let ((inhibit-read-only t))
        (erase-buffer)))))

;;;###autoload
(defun loom/log-show-buffer ()
  "Show the loom log buffer in another window."
  (interactive)
  (pop-to-buffer (get-buffer-create loom-log-buffer-name)))

;;;###autoload
(defmacro loom-log-trace (target-symbol fmt &rest args)
  "Log a trace message. See `loom-log` for argument details."
  (declare (indent 2) (debug t))
  `(loom-log :trace ,target-symbol ,fmt ,@args))

;;;###autoload
(defmacro loom-log-debug (target-symbol fmt &rest args)
  "Log a debug message. See `loom-log` for argument details."
  (declare (indent 2) (debug t))
  `(loom-log :debug ,target-symbol ,fmt ,@args))

;;;###autoload
(defmacro loom-log-info (target-symbol fmt &rest args)
  "Log an info message. See `loom-log` for argument details."
  (declare (indent 2) (debug t))
  `(loom-log :info ,target-symbol ,fmt ,@args))

;;;###autoload
(defmacro loom-log-warn (target-symbol fmt &rest args)
  "Log a warning message. See `loom-log` for argument details."
  (declare (indent 2) (debug t))
  `(loom-log :warn ,target-symbol ,fmt ,@args))

;;;###autoload
(defmacro loom-log-error (target-symbol fmt &rest args)
  "Log an error message. See `loom-log` for argument details."
  (declare (indent 2) (debug t))
  `(loom-log :error ,target-symbol ,fmt ,@args))

;;;###autoload
(defmacro loom-log-fatal (target-symbol fmt &rest args)
  "Log a fatal message. See `loom-log` for argument details."
  (declare (indent 2) (debug t))
  `(loom-log :fatal ,target-symbol ,fmt ,@args))

(provide 'loom-log)
;;; loom-log.el ends here