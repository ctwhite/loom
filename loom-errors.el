;;; loom-errors.el --- Error definitions and handling for Concur -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file defines the various error types used throughout the Concur library,
;; provides a standardized way to create error objects (`loom:make-error`),
;; and manages the configuration for how unhandled promise rejections are treated.
;;
;; It encapsulates all error-related concerns, making the core promise
;; implementation cleaner and error handling more consistent and configurable.

;;; Code:

(require 'cl-lib)

(require 'loom-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom-promise-p "loom-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global Context (Error-Related)

(defvar loom-current-async-stack nil
  "A dynamically-scoped list of labels for the current async call stack.
Used to build richer debugging information on promise rejection,
providing context for `loom-error` objects.")

(defvar loom--unhandled-rejections-queue '()
  "A list of unhandled `loom-error` objects for later inspection.")

(defvar loom--error-id-counter 0
  "Counter for generating unique error IDs.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-on-unhandled-rejection-action 'log
  "Action to take when a promise is rejected with no error handler.
An unhandled rejection occurs when a promise is rejected, but no `:catch`
or `on-rejected` handler is attached to it or any of its descendants in
the promise chain. This can lead to silent failures.

This variable provides a single, unified control for the global
behavior for reporting such events.

Possible values are:
- `ignore`: Do nothing.
- `log`: Log a warning message to the `*Messages*` buffer (default).
- `signal`: Signal a `loom-unhandled-rejection` error.
- A function: A function of one argument `(lambda (error-obj))` that
  will be called with the `loom-error` object."
  :type '(choice (const :tag "Ignore" ignore)
                 (const :tag "Log" log)
                 (const :tag "Signal Error" signal)
                 (function :tag "Custom Function"))
  :group 'loom)

(defcustom loom-error-max-stack-depth 50
  "Maximum depth for async stack traces to prevent excessive memory usage."
  :type 'integer
  :group 'loom)

(defcustom loom-error-max-message-length 1000
  "Maximum length for error messages to prevent excessive memory usage."
  :type 'integer
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-error "A generic error in the Concur library.")

(define-error 'loom-unhandled-rejection
  "A promise was rejected with no attached error handler."
  'loom-error)

(define-error 'loom-await-error
  "An error occurred while awaiting a promise."
  'loom-error)

(define-error 'loom-cancel-error
  "A promise was cancelled."
  'loom-error)

(define-error 'loom-timeout-error
  "An operation timed out."
  'loom-error)

(define-error 'loom-type-error
  "An invalid type was encountered."
  'loom-error)

(define-error 'loom-executor-error
  "An error occurred within a promise executor function."
  'loom-error)

(define-error 'loom-callback-error
  "An error occurred within a promise callback handler."
  'loom-error)

(define-error 'loom-scheduler-not-initialized-error
  "Scheduler not initialized"
  'loom-error)

(define-error 'loom-validation-error
  "A validation check failed"
  'loom-error)

(define-error 'loom-state-error
  "An invalid state transition was attempted"
  'loom-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-error (:constructor %%make-loom-error) (:copier nil))
  "A standardized error object for promise rejections.
This provides a consistent structure for error handling, allowing for
richer introspection than a simple string or Lisp error condition.

Fields:
- `id` (integer): Unique identifier for this error instance.
- `type` (keyword): Keyword identifying the error (`:cancel`, `:timeout`).
- `severity` (symbol): Error severity level (`:debug`, `:info`, `:warning`, `:error`, `:critical`).
- `code` (string): Machine-readable error code for programmatic handling.
- `message` (string): A human-readable error message.
- `data` (any): Additional structured data associated with the error.
- `cause` (any): The original Lisp error or reason that triggered this.
- `promise` (loom-promise): The promise instance that rejected.
- `async-stack-trace` (string): Formatted async/Lisp backtrace.
- `timestamp` (float): Time when the error was created.
- `buffer` (buffer): The buffer active when the error was created.
- `major-mode` (symbol): The major mode active at error creation.
- `cmd` (string): If process-related, the command that was run.
- `args` (list): If process-related, the command arguments.
- `cwd` (string): If process-related, the working directory.
- `exit-code` (integer): If process-related, the process exit code.
- `signal` (string): If process-related, the signal that killed it.
- `process-status` (symbol): If process-related, the process status.
- `stdout` (string): If process-related, collected stdout.
- `stderr` (string): If process-related, collected stderr.
- `context` (plist): Additional contextual information."
  (id (cl-incf loom--error-id-counter) :type integer)
  (type :generic :type keyword)
  (severity :error :type (member :debug :info :warning :error :critical))
  (code nil :type (or null string))
  (message "An unspecific Concur error occurred." :type string)
  (data nil)
  (cause nil)
  (promise nil)
  (async-stack-trace nil :type (or null string))
  (timestamp (float-time) :type float)
  (buffer nil)
  (major-mode nil :type (or null symbol))
  (cmd nil :type (or null string))
  (args nil :type (or null list))
  (cwd nil :type (or null string))
  (exit-code nil :type (or null integer))
  (signal nil :type (or null string))
  (process-status nil :type (or null symbol))
  (stdout nil :type (or null string))
  (stderr nil :type (or null string))
  (context nil :type (or null list)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--truncate-string (str max-length)
  "Truncate STR to MAX-LENGTH characters, adding ellipsis if needed."
  ;; Use `if` instead of `when` to provide an "else" case.
  (if (and (stringp str) (> (length str) max-length))
      ;; If the string is too long, truncate it.
      (concat (substring str 0 (- max-length 3)) "...")
    ;; Otherwise, return the original string unchanged.
    str))

(defun loom--format-async-stack ()
  "Format `loom-current-async-stack` into a readable string."
  (when loom-current-async-stack
    (let ((stack (if (> (length loom-current-async-stack) loom-error-max-stack-depth)
                     (append (seq-take loom-current-async-stack
                                       (- loom-error-max-stack-depth 1))
                             (list (format "... (%d more frames)"
                                           (- (length loom-current-async-stack)
                                              loom-error-max-stack-depth))))
                   loom-current-async-stack)))
      (mapconcat #'identity (reverse stack) "\n↳ "))))

(defun loom--validate-error-args (args)
  "Validate error creation arguments and return normalized args.
This robust version guards against non-string message types."
  (let* ((validated-args args)
         (message-val (plist-get validated-args :message)))

    ;; Process the message only if it's explicitly provided.
    (when message-val
      (let ((message-str (if (stringp message-val)
                             message-val
                           (format "%S" message-val)))) ; Coerce to string if not already
        ;; Put the guaranteed-to-be-a-string back into the plist, after truncation.
        (setq validated-args
              (plist-put validated-args :message
                         (loom--truncate-string message-str loom-error-max-message-length)))))

    (let ((type (plist-get validated-args :type))
          (severity (plist-get validated-args :severity)))

      ;; Validate type and severity...
      (when (and type (not (keywordp type)))
        (signal 'loom-validation-error
                (list "Error type must be a keyword" :type type)))
      (when (and severity (not (memq severity '(:debug :info :warning :error :critical))))
        (signal 'loom-validation-error
                (list "Invalid severity level" :severity severity))))

    validated-args))

(defun loom--inherit-from-cause (cause user-args)
  "Inherit appropriate fields from CAUSE error if it's a loom-error.

Arguments:
- `CAUSE` (any): The cause to potentially inherit from.
- `USER-ARGS` (plist): User-provided arguments that take precedence.

Returns:
- (plist): Arguments with inherited values added."
  (if (not (loom-error-p cause))
      user-args
    (let ((inherited-args user-args))
      ;; Fields that should be inherited if not explicitly provided
      (dolist (slot '(type severity code async-stack-trace buffer major-mode
                      cmd args cwd exit-code signal process-status stdout stderr))
        (let* ((key (intern (format ":%s" slot)))
               (val (funcall (intern (format "loom-error-%s" slot)) cause)))
          (when (and val (not (plist-member inherited-args key)))
            (setq inherited-args (plist-put inherited-args key val)))))
      inherited-args)))

(defun loom--get-message-from-cause (cause)
  "Extracts a string message from an arbitrary CAUSE object.
  Handles loom-errors, standard Emacs Lisp errors, and any other Lisp object."
  (let ((msg nil))
    (cond
     ((loom-error-p cause)
      (setq msg (loom-error-message cause)))
     ;; Handle standard (error "MESSAGE") lists directly.
     ;; (stringp (cadr cause)) ensures it's a string message, not just any data.
     ((and (listp cause) (eq (car cause) 'error) (stringp (cadr cause)))
      (setq msg (cadr cause)))
     ;; Try `error-message-string` for other types of Emacs Lisp errors.
     (t
      (setq msg (error-message-string cause))))

    ;; Ensure `msg` is a non-empty string, otherwise use a fallback.
    (if (and (stringp msg) (not (string-empty-p msg)) (not (string= msg "nil")))
        msg ; Return the good message
      (format "Unknown error cause: %S" cause)))) ; Generic fallback


(defun loom--handle-unhandled-rejection (error-obj)
  "Handle an unhandled rejection according to configuration.

Arguments:
- `ERROR-OBJ` (loom-error): The unhandled error object."
  (push error-obj loom--unhandled-rejections-queue)
  (pcase loom-on-unhandled-rejection-action
    ('ignore nil)
    ('log (loom--log-unhandled-rejection error-obj))
    ('signal (signal 'loom-unhandled-rejection
                     (list "Unhandled promise rejection" error-obj)))
    ((pred functionp)
     (condition-case err
         (funcall loom-on-unhandled-rejection-action error-obj)
       (error (loom-log :error nil "Error in unhandled rejection handler: %S" err))))
    (_ (loom-log :warning nil "Invalid loom-on-unhandled-rejection-action: %S"
                loom-on-unhandled-rejection-action))))

(defun loom--log-unhandled-rejection (error-obj)
  "Log an unhandled rejection to the message buffer.

Arguments:
- `ERROR-OBJ` (loom-error): The error to log."
  (loom-log :warning nil "Unhandled promise rejection [%s]: %s"
           (loom-error-type error-obj)
           (loom-error-message error-obj)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom:make-error (&rest user-args)
  "Create a new `loom-error` struct, capturing contextual information.
This function intelligently builds an error object. If the `:cause`
is another `loom-error`, its properties are inherited. Explicitly
provided arguments in `USER-ARGS` always take precedence.

Arguments:
- `USER-ARGS` (plist): Key-value pairs for `loom-error` fields.
  Common keys include `:type`, `:message`, `:data`, and `:cause`.

Returns:
- (loom-error): A new, populated `loom-error` struct.

Signals:
- `loom-validation-error` if invalid arguments are provided."
  (let* ((validated-args (loom--validate-error-args user-args))
         (cause (plist-get validated-args :cause))
         (user-message (plist-get validated-args :message)) ; This will now be nil if no :message was passed in user-args
         (defaults `(:async-stack-trace ,(loom--format-async-stack)
                     :buffer ,(current-buffer)
                     :major-mode ,major-mode
                     :timestamp ,(float-time)))
         (inherited (when (loom-error-p cause)
                      (loom--inherit-from-cause cause validated-args)))
         (derived-message
          (cond
           (user-message user-message) ; User-provided message has highest priority
           (cause (loom--get-message-from-cause cause)) ; Use the robust helper
           (t "An unspecified Concur error occurred."))))

    ;; (message "cause for %%make-loom-error: %S" cause)        ; Keep for debugging
    ;; (message "derived-message for %%make-loom-error: %S" derived-message) ; Keep for debugging
    (let ((final-args (append validated-args inherited defaults)))
      ;; Ensure the derived message is explicitly set, overriding any default
      ;; This `plist-put` is essential even if `validated-args` has no `:message`
      ;; because we're providing the *final, derived* message.
      (setq final-args (plist-put final-args :message derived-message))

      ;; (message "final-args for %%make-loom-error: %S" final-args) ; Keep for debugging

      (apply #'%%make-loom-error final-args))))

;;;###autoload
(defun loom:error-from-condition (condition &rest additional-args)
  "Create a loom-error from an Emacs Lisp error condition.

Arguments:
- `CONDITION` (list): An error condition from `condition-case`.
- `ADDITIONAL-ARGS` (plist): Additional arguments for the error.

Returns:
- (loom-error): A new error object wrapping the condition."
  (let* ((error-symbol (car condition))
         (error-data (cdr condition))
         (message (if error-data
                      (format "%s: %s" error-symbol (car error-data))
                    (format "%s" error-symbol))))
    (apply #'loom:make-error
           :type (intern (format ":%s" error-symbol))
           :message message
           :cause condition
           :data error-data
           additional-args)))

;;;###autoload
(defun loom:error-wrap (cause &rest additional-args)
  "Wrap an existing error or condition as a loom-error.

Arguments:
- `CAUSE` (any): The original error or cause.
- `ADDITIONAL-ARGS` (plist): Additional arguments for the error.

Returns:
- (loom-error): A new error object wrapping the cause."
  (cond
   ((loom-error-p cause) cause)
   ((and (listp cause) (symbolp (car cause))) ; Error condition
    (apply #'loom:error-from-condition cause additional-args))
   (t
    (apply #'loom:make-error
           :cause cause
           :message (format "Wrapped error: %S" cause) ; This is a default message for unknown cause types
           additional-args))))
    
;;;###autoload
(defun loom:error-message (promise-or-error)
  "Return human-readable message from a promise's error or an error object.

Arguments:
- `PROMISE-OR-ERROR` (loom-promise or loom-error): The item to inspect.

Returns:
- (string): A descriptive error message."
  (let ((err (if (loom-promise-p promise-or-error)
                 (loom:error-value promise-or-error)
               promise-or-error)))
    (cond
     ((loom-error-p err) (loom-error-message err))
     ((stringp err) err)
     (t (format "%S" err)))))

;;;###autoload
(defun loom:error-cause (err)
  "Return the underlying cause of a `loom-error`.

The 'cause' is the original Lisp error or reason that triggered
the creation of this `loom-error` object. This function serves as
the public API accessor for the `:cause` slot.

Arguments:
- ERR (loom-error): The error object to inspect.

Returns:
- (any): The underlying cause, or `nil` if none.

Signals:
- `loom-type-error`: If ERR is not a `loom-error` struct."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))
  ;; This calls the accessor function automatically generated by cl-defstruct.
  (loom-error-cause err))
    
;;;###autoload
(defun loom:serialize-error (err)
  "Serialize a `loom-error` struct into a plist.
This plist can then be safely encoded as JSON for Inter-Process
Communication.

Arguments:
- `ERR` (loom-error): The error object to serialize.

Returns:
- (list): A plist representation of the error."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))

  (cl-loop with slots = '(id type severity code message data cause promise
                             async-stack-trace timestamp buffer major-mode
                             cmd args cwd exit-code signal process-status
                             stdout stderr context)
           for slot-name in slots
           for value = (funcall (intern (format "loom-error-%s" slot-name)) err)
           when value
           collect (intern (format ":%s" slot-name))
           collect (if (bufferp value)
                       (buffer-name value)
                     value)))

;;;###autoload
(defun loom:deserialize-error (plist)
  "Deserialize a `PLIST` back into a `loom-error` struct.

Arguments:
- `PLIST` (list): A property list created by `loom:serialize-error`.

Returns:
- (loom-error): A new `loom-error` struct."
  (unless (listp plist)
    (signal 'loom-type-error (list "Expected plist" plist)))

  (apply #'%%make-loom-error plist))

;;;###autoload
(defun loom:error-format (err &optional detailed)
  "Format a loom-error for display.

Arguments:
- `ERR` (loom-error): The error to format.
- `DETAILED` (boolean): Whether to include detailed information.

Returns:
- (string): A formatted error string."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))

  (let ((basic (format "[%s] %s"
                       (loom-error-type err)
                       (loom-error-message err))))
    (if detailed
        (concat basic
                (when (loom-error-code err)
                  (format "\nCode: %s" (loom-error-code err)))
                (when (loom-error-data err)
                  (format "\nData: %S" (loom-error-data err)))
                (when (loom-error-async-stack-trace err)
                  (format "\nAsync Stack:\n%s" (loom-error-async-stack-trace err))))
      basic)))

;;;###autoload
(defun loom:error-matches-p (err type-or-code)
  "Check if an error matches a given type or code.

Arguments:
- `ERR` (loom-error): The error to check.
- `TYPE-OR-CODE` (keyword or string): The type or code to match against.

Returns:
- (boolean): `t` if the error matches, `nil` otherwise."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))

  (if (keywordp type-or-code)
      (eq (loom-error-type err) type-or-code)
    (string= (loom-error-code err) type-or-code)))

;;;###autoload
(defun loom:error-chain (err)
  "Get the chain of errors by following the cause field.

Arguments:
- `ERR` (loom-error): The error to get the chain for.

Returns:
- (list): A list of errors from root cause to current."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))

  (let ((chain (list err))
        (current err))
    (while (and (loom-error-p (loom-error-cause current))
                (< (length chain) 50)) ; Prevent infinite loops
      (setq current (loom-error-cause current))
      (push current chain))
    (reverse chain)))

;;;###autoload
(defun loom-unhandled-rejections-count ()
  "Return the number of unhandled promise rejections currently queued.

Returns:
- (integer): The count of unhandled rejections."
  (length loom--unhandled-rejections-queue))

;;;###autoload
(defun loom-get-unhandled-rejections ()
  "Return and clear the list of all currently tracked unhandled rejections.

Returns:
- (list): A list of `loom-error` objects, oldest first."
  (prog1 (nreverse loom--unhandled-rejections-queue)
    (setq loom--unhandled-rejections-queue '())))

;;;###autoload
(defun loom-has-unhandled-rejections-p ()
  "Return non-nil if there are any unhandled promise rejections queued.

Returns:
- (boolean): `t` if unhandled rejections exist, `nil` otherwise."
  (not (null loom--unhandled-rejections-queue)))

;;;###autoload
(defun loom-clear-unhandled-rejections ()
  "Clear all tracked unhandled rejections without returning them.

Returns:
- (integer): The number of rejections that were cleared."
  (prog1 (length loom--unhandled-rejections-queue)
    (setq loom--unhandled-rejections-queue '())))

;;;###autoload
(defun loom-report-unhandled-rejection (error-obj)
  "Report an unhandled rejection for tracking and processing.

Arguments:
- `ERROR-OBJ` (loom-error): The error object representing the rejection.

Side Effects:
- Adds the error to the unhandled rejections queue.
- Triggers the configured unhandled rejection action."
  (unless (loom-error-p error-obj)
    (signal 'loom-type-error (list "Expected loom-error" error-obj)))

  (loom--handle-unhandled-rejection error-obj))

;;;###autoload
(defmacro loom:with-error-context (context &rest body)
  "Execute BODY with additional error context.

Arguments:
- `CONTEXT` (plist): Context to add to errors created within BODY.
- `BODY` (forms): The forms to execute.

Returns:
- The value of the last form in BODY."
  (declare (indent 1))
  `(let ((loom-current-async-stack
          (cons (format "Context: %S" ,context)
                loom-current-async-stack)))
     ,@body))

(provide 'loom-errors)
;;; loom-errors.el ends here