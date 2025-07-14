;;; loom-log.el --- Logging for the Loom async library -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file provides the core logging definitions for the Loom asynchronous
;; library. It offers a centralized and customizable mechanism for emitting
;; internal messages, useful for both debugging and understanding runtime
;; behavior.
;;
;; Key features:
;; - **Customizable Logging Hook**: `loom-log-hook` allows users to
;;   intercept and process all log messages, for example, to redirect them
;;   to a dedicated buffer or file.
;; - **Default Logging Behavior**: If no custom hook is set, messages are
;;   printed to the `*loom*` buffer, controlled by `loom-log-default-level`.
;; - **Log Levels**: Supports standard log levels (`:trace`, `:debug`, `:info`,
;;   `:warn`, `:error`, and `:fatal`).

;;; Code:

(require 'cl-lib)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-log-enabled-p t
  "If non-nil, enable logging messages from the Loom library.
When nil, `loom-log' will do nothing."
  :type 'boolean
  :group 'loom)

(defcustom loom-log-hook nil
  "A hook for intercepting and handling log messages from the Loom library.

Functions added to this hook should accept four arguments:
1. LEVEL (keyword): The log level, e.g., `:debug', `:info'.
2. TARGET-SYMBOL (symbol|nil): An optional symbol for context (like a
   promise ID).
3. FMT (string): The format-control string.
4. ARGS (list): A list containing the arguments for the format string.

Example Hook Function:
  (defun my-loom-log-handler (level _target fmt &rest args)
    (with-current-buffer (get-buffer-create \"*my-loom-log*\")
      (goto-char (point-max))
      (insert (format \"[%s] %s\\n\"
                      level (apply #'format fmt args)))))"
  :type 'hook
  :group 'loom)

(defcustom loom-log-default-level :debug
  "The minimum level for messages shown in `*loom*' buffer.
This setting only applies when `loom-log-hook' is nil.
The levels, from least to most severe, are:
`:trace', `:debug', `:info', `:warn', `:error', `:fatal'."
  :type '(choice (const :tag "Trace" :trace)
                 (const :tag "Debug" :debug)
                 (const :tag "Info" :info)
                 (const :tag "Warning" :warn)
                 (const :tag "Error" :error)
                 (const :tag "Fatal" :fatal))
  :group 'loom)

(defcustom loom-log-buffer-name "*loom*"
  "Name of the buffer used for default logging output."
  :type 'string
  :group 'loom)

(defcustom loom-log-timestamp-format "%Y-%m-%d %H:%M:%S"
  "Format string for timestamps in log messages.
Set to nil to disable timestamps."
  :type '(choice (string :tag "Timestamp format")
                 (const :tag "No timestamp" nil))
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Logic

(defconst loom--log-level-values
  '((:trace . 0) (:debug . 1) (:info . 2) (:warn . 3)
    (:error . 4) (:fatal . 5))
  "Internal alist mapping log level keywords to integers for comparison.")

(defun loom--get-log-level-value (level)
  "Return the integer value for a given log LEVEL keyword."
  (cdr (assoc level loom--log-level-values)))

(defun loom--format-target-symbol (target-symbol)
  "Format TARGET-SYMBOL for display in log messages."
  (cond
   ((null target-symbol) "")
   ((or (stringp target-symbol) (symbolp target-symbol))
    (format "[%s] " target-symbol))
   (t (format "[%S] " target-symbol))))

(defun loom--get-timestamp ()
  "Get current timestamp string, or empty string if timestamps disabled."
  (if loom-log-timestamp-format
      (format-time-string loom-log-timestamp-format)
    ""))

(defun loom--default-log-function (level target-symbol fmt &rest args)
  "Default log function that prints to the loom log buffer.
A message is printed only if its LEVEL is equal to or more severe than
`loom-log-default-level'.

Arguments:
- LEVEL (symbol): The log level of the message.
- TARGET-SYMBOL (symbol|nil): An optional symbol for context.
- FMT (string): The format-control string.
- ARGS (rest): Arguments for the format string."
  (let ((level-val (loom--get-log-level-value level))
        (min-level-val (loom--get-log-level-value loom-log-default-level)))
    (when (and level-val (>= level-val min-level-val))
      (let* ((level-str (upcase (substring (symbol-name level) 1)))
             (target-prefix (loom--format-target-symbol target-symbol))
             (timestamp (loom--get-timestamp))
             (timestamp-prefix (if (string-empty-p timestamp) "" (concat timestamp " ")))
             (message-text (apply #'format fmt args))
             (full-message (format "%sLoom [%s] %s%s\n"
                                   timestamp-prefix level-str target-prefix message-text)))
        (with-current-buffer (get-buffer-create loom-log-buffer-name)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert full-message)
            (set-buffer-modified-p nil)
            (when (get-buffer-window (current-buffer))
              (with-selected-window (get-buffer-window (current-buffer))
                (goto-char (point-max))
                (recenter -1)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

(defun loom-log (level target-symbol fmt &rest args)
  "Log a message for the Loom library.

This is the central entry point for all logging within Loom. It dispatches
the log event to any custom handlers on `loom-log-hook'. If the hook is
empty, it falls back to the default behavior of printing to the loom log
buffer, respecting `loom-log-default-level'.

Arguments:
- LEVEL (symbol): The log level, e.g., `:debug', `:info', `:warn'.
- TARGET-SYMBOL (symbol|nil): An optional symbol for context, such as a
  promise ID or scheduler name.
- FMT (string): The format-control string.
- ARGS (rest): Arguments for the format string."
  (when loom-log-enabled-p
    (if loom-log-hook
        (apply #'run-hook-with-args 'loom-log-hook level target-symbol fmt args)
      (apply #'loom--default-log-function level target-symbol fmt args))))

;;;###autoload
(defun loom-log-clear-buffer ()
  "Clear the loom log buffer."
  (interactive)
  (when (get-buffer loom-log-buffer-name)
    (with-current-buffer loom-log-buffer-name
      (let ((inhibit-read-only t))
        (erase-buffer)
        (set-buffer-modified-p nil)))))

;;;###autoload
(defun loom-log-show-buffer ()
  "Show the loom log buffer in a window."
  (interactive)
  (pop-to-buffer (get-buffer-create loom-log-buffer-name)))

;; Convenience macros for different log levels
(defmacro loom-log-trace (target-symbol fmt &rest args)
  "Log a trace message. See `loom-log' for argument details."
  `(loom-log :trace ,target-symbol ,fmt ,@args))

(defmacro loom-log-debug (target-symbol fmt &rest args)
  "Log a debug message. See `loom-log' for argument details."
  `(loom-log :debug ,target-symbol ,fmt ,@args))

(defmacro loom-log-info (target-symbol fmt &rest args)
  "Log an info message. See `loom-log' for argument details."
  `(loom-log :info ,target-symbol ,fmt ,@args))

(defmacro loom-log-warn (target-symbol fmt &rest args)
  "Log a warning message. See `loom-log' for argument details."
  `(loom-log :warn ,target-symbol ,fmt ,@args))

(defmacro loom-log-error (target-symbol fmt &rest args)
  "Log an error message. See `loom-log' for argument details."
  `(loom-log :error ,target-symbol ,fmt ,@args))

(defmacro loom-log-fatal (target-symbol fmt &rest args)
  "Log a fatal message. See `loom-log' for argument details."
  `(loom-log :fatal ,target-symbol ,fmt ,@args))

(provide 'loom-log)
;;; loom-log.el ends here