;;; loom-errors.el --- Error definitions and handling for Loom -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file defines the various error types used throughout the Loom library,
;; provides a standardized way to create error objects (`loom:make-error`),
;; and manages the configuration for how unhandled promise rejections are treated.
;;
;; It encapsulates all error-related concerns, making the core promise
;; implementation cleaner and error handling more consistent and configurable.
;;
;; Key features:
;; - Rich error objects with contextual information
;; - Configurable unhandled rejection handling
;; - Error chaining and inheritance
;; - Async stack trace support
;; - Serialization for IPC
;; - Memory-efficient error tracking

;;; Code:

(require 'cl-lib)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom-promise-p "loom-promise")
(declare-function loom:error-value "loom-promise")
(declare-function loom-log "loom-log")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global Context

(defvar loom-current-async-stack nil
  "A dynamically-scoped list of labels for the current async call stack.
Used to build richer debugging information on promise rejection,
providing context for `loom-error` objects.")

(defvar loom--unhandled-rejections-queue '()
  "A list of unhandled `loom-error` objects for later inspection.")

(defvar loom--error-id-counter 0
  "Counter for generating unique error IDs.")

(defvar loom--error-statistics nil
  "Statistics about error creation and handling.
A plist with keys: :total-errors, :unhandled-count, :by-type.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Constants

(defconst *loom-error-severity-levels*
  '(:debug :info :warning :error :critical)
  "Valid severity levels for loom errors, in increasing order of severity.")

(defconst *loom-error-serializable-slots*
  '(id type severity code message data timestamp buffer major-mode
    cmd args cwd exit-code signal process-status stdout stderr context)
  "A list of `loom-error` slots that can be safely serialized to a plist.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-on-unhandled-rejection-action 'log
  "Action to take when a promise is rejected with no error handler.
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
  :type 'natnum
  :group 'loom)

(defcustom loom-error-max-message-length 1000
  "Maximum length for error messages to prevent excessive memory usage."
  :type 'natnum
  :group 'loom)

(defcustom loom-error-max-unhandled-queue-size 100
  "Maximum number of unhandled rejections to keep in memory.
When this limit is reached, oldest errors are discarded."
  :type 'natnum
  :group 'loom)

(defcustom loom-error-enable-statistics t
  "Whether to collect statistics about error creation and handling.
When enabled, provides insight into error patterns but uses more memory."
  :type 'boolean
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-error 
  "A generic error in the Concur library.")

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
  "Scheduler not initialized." 
  'loom-error)

(define-error 'loom-validation-error
  "A validation check failed." 
  'loom-error)

(define-error 'loom-state-error
  "An invalid state transition was attempted." 
  'loom-error)

(define-error 'loom-resource-error
  "A resource-related error occurred." 
  'loom-error)

(define-error 'loom-network-error
  "A network-related error occurred." 
  'loom-error)

(define-error 'loom-permission-error
  "A permission-related error occurred." 
  'loom-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-error (:constructor %%make-loom-error) (:copier nil))
  "A standardized error object for promise rejections.

Fields:
- `id` (integer): Unique identifier for this error instance.
- `type` (keyword): Keyword identifying the error (`:cancel`, `:timeout`).
- `severity` (symbol): Error severity level (`:debug`, `:info`, `:warning`,
  `:error`, `:critical`).
- `code` (string): Machine-readable error code for programmatic handling.
- `message` (string): A human-readable error message.
- `data` (any): Additional structured data associated with the error.
- `cause` (any): The original Lisp error or reason that triggered this.
- `promise` (loom-promise): The promise instance that rejected.
- `async-stack-trace` (string): Formatted async/Lisp backtrace.
- `timestamp` (float): Time when the error was created.
- `context` (plist): Additional contextual information.
- `handled` (boolean): Whether this error has been handled.
- `chain-depth` (integer): Depth in the error chain."
  (id (cl-incf loom--error-id-counter) :type integer)
  (type :generic :type keyword)
  (severity :error :type symbol)
  (code nil :type (or null string))
  (message "An unspecified Concur error occurred." :type string)
  (data nil)
  (cause nil)
  (promise nil)
  (async-stack-trace nil :type (or null string))
  (timestamp (float-time) :type float)
  (context nil :type (or null list))
  (handled nil :type boolean)
  (chain-depth 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--truncate-string (str max-length)
  "Truncate `STR` to `MAX-LENGTH` characters, adding ellipsis if needed.

Arguments:
- `STR` (string): The string to truncate.
- `MAX-LENGTH` (integer): The maximum allowed length.

Returns:
- (string): The potentially truncated string."
  (if (and (stringp str) (> (length str) max-length))
      (concat (substring str 0 (- max-length 3)) "...")
    str))

(defun loom--format-async-stack ()
  "Format `loom-current-async-stack` into a readable string.

Returns:
- (string or nil): The formatted stack trace, or nil if the stack is empty."
  (when loom-current-async-stack
    (let ((stack (if (> (length loom-current-async-stack)
                        loom-error-max-stack-depth)
                     (append (seq-take loom-current-async-stack
                                       (- loom-error-max-stack-depth 1))
                             (list (format "... (%d more frames)"
                                           (- (length loom-current-async-stack)
                                              loom-error-max-stack-depth))))
                   loom-current-async-stack)))
      (mapconcat #'identity (reverse stack) "\n↳ "))))

(defun loom--validate-error-args (args)
  "Validate error creation arguments and return a normalized plist.

Arguments:
- `ARGS` (plist): The user-provided arguments to `loom:make-error`.

Returns:
- (plist): A validated and normalized plist of arguments.

Signals:
- `loom-validation-error`: If type, severity, or code are invalid."
  (let ((validated-args (copy-sequence args)))
    (when-let ((message-val (plist-get validated-args :message)))
      (let ((message-str (if (stringp message-val) message-val
                           (format "%S" message-val))))
        (setq validated-args (plist-put validated-args :message
                                        (loom--truncate-string
                                         message-str
                                         loom-error-max-message-length)))))
    (when-let ((type (plist-get validated-args :type)))
      (unless (keywordp type)
        (signal 'loom-validation-error
                (list "Error type must be a keyword" :type type))))
    (when-let ((severity (plist-get validated-args :severity)))
      (unless (memq severity *loom-error-severity-levels*)
        (signal 'loom-validation-error
                (list "Invalid severity level" :severity severity))))
    (when-let ((code (plist-get validated-args :code)))
      (unless (stringp code)
        (signal 'loom-validation-error
                (list "Error code must be a string" :code code))))
    validated-args))

(defun loom--inherit-from-cause (cause user-args)
  "Inherit appropriate fields from a `CAUSE` if it's a `loom-error`.

Arguments:
- `CAUSE` (any): The cause to potentially inherit from.
- `USER-ARGS` (plist): User-provided arguments that take precedence.

Returns:
- (plist): A new plist with inherited values added."
  (if (not (loom-error-p cause))
      user-args
    (let ((inherited-args (copy-sequence user-args)))
      (dolist (slot '(type severity code async-stack-trace))
        (let* ((key (intern (format ":%s" slot)))
               (val (funcall (intern (format "loom-error-%s" slot)) cause)))
          (when (and val (not (plist-member inherited-args key)))
            (setq inherited-args (plist-put inherited-args key val)))))
      (let ((parent-depth (loom-error-chain-depth cause)))
        (unless (plist-member inherited-args :chain-depth)
          (setq inherited-args
                (plist-put inherited-args :chain-depth (1+ parent-depth)))))
      inherited-args)))

(defun loom--extract-message-from-cause (cause)
  "Extract a string message from an arbitrary `CAUSE` object.

Arguments:
- `CAUSE` (any): The object from which to extract a message.

Returns:
- (string): The extracted error message."
  (cond
   ((loom-error-p cause) (loom-error-message cause))
   ((and (listp cause) (symbolp (car cause))) (error-message-string cause))
   ((stringp cause) cause)
   (t (format "%S" cause))))

(defun loom--update-error-statistics (error-obj)
  "Update error statistics if enabled.

Arguments:
- `ERROR-OBJ` (loom-error): The newly created error.

Returns: `nil`.
Side Effects: Modifies `loom--error-statistics`."
  (when loom-error-enable-statistics
    (unless loom--error-statistics
      (setq loom--error-statistics `(:total-errors 0 :unhandled-count 0
                                     :by-type ,(make-hash-table :test 'eq))))
    (cl-incf (plist-get loom--error-statistics :total-errors))
    (let ((by-type (plist-get loom--error-statistics :by-type))
          (type (loom-error-type error-obj)))
      (puthash type (1+ (gethash type by-type 0)) by-type))))

(defun loom--manage-unhandled-queue ()
  "Manage the unhandled rejections queue size, removing oldest entries.

Returns: `nil`.
Side Effects: May modify `loom--unhandled-rejections-queue`."
  (while (> (length loom--unhandled-rejections-queue)
            loom-error-max-unhandled-queue-size)
    (setq loom--unhandled-rejections-queue
          (cdr loom--unhandled-rejections-queue))))

(defun loom--handle-unhandled-rejection (error-obj)
  "Handle an unhandled rejection according to configuration.

Arguments:
- `ERROR-OBJ` (loom-error): The unhandled error.

Returns: `nil`.
Side Effects: Adds error to queue and executes the configured action."
  (push error-obj loom--unhandled-rejections-queue)
  (loom--manage-unhandled-queue)
  (when loom-error-enable-statistics
    (cl-incf (plist-get loom--error-statistics :unhandled-count)))
  (pcase loom-on-unhandled-rejection-action
    ('ignore nil)
    ('log (loom-log :warning nil "Unhandled promise rejection [%s]: %s"
                    (loom-error-type error-obj) (loom-error-message error-obj)))
    ('signal (signal 'loom-unhandled-rejection
                     (list "Unhandled promise rejection" error-obj)))
    ((pred functionp)
     (condition-case err (funcall loom-on-unhandled-rejection-action error-obj)
       (error (loom-log :error nil "Error in unhandled rejection handler: %S" err))))))

(defun loom--capture-context ()
  "Capture current execution context for error reporting.

Returns:
- (plist): A plist with relevant contextual information."
  `(:buffer ,(buffer-name (current-buffer))
    :major-mode ,major-mode
    :point ,(point)
    :emacs-version ,emacs-version
    :system-type ,system-type))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom:make-error (&rest user-args)
  "Create a new `loom-error` struct, capturing contextual information.
If the `:cause` is another `loom-error`, its properties are inherited.
Explicitly provided arguments in `USER-ARGS` always take precedence.

Arguments:
- `USER-ARGS` (plist): Key-value pairs for `loom-error` fields.

Returns:
- (loom-error): A new, populated `loom-error` struct.

Signals:
- `loom-validation-error`: If invalid arguments are provided."
  (let* ((validated-args (loom--validate-error-args user-args))
         (cause (plist-get validated-args :cause))
         (defaults `(:async-stack-trace ,(loom--format-async-stack)
                     :context ,(loom--capture-context)))
         (inherited (if cause (loom--inherit-from-cause cause validated-args)
                      '()))
         (derived-message (or (plist-get validated-args :message)
                              (if cause (loom--extract-message-from-cause cause))
                              "An unspecified Concur error occurred."))
         (final-args (append validated-args inherited defaults)))
    (setq final-args (plist-put final-args :message derived-message))
    (let ((error-obj (apply #'%%make-loom-error final-args)))
      (loom--update-error-statistics error-obj)
      error-obj)))

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
         (message (error-message-string condition)))
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
   ((and (loom-error-p cause) (null additional-args)) cause)
   ((loom-error-p cause) (apply #'loom:make-error :cause cause additional-args))
   ((and (listp cause) (symbolp (car cause)))
    (apply #'loom:error-from-condition cause additional-args))
   (t (apply #'loom:make-error :cause cause additional-args))))

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
    (loom--extract-message-from-cause err)))

;;;###autoload
(defun loom:error-cause (err)
  "Return the underlying cause of a `loom-error`.

Arguments:
- `ERR` (loom-error): The error object to inspect.

Returns:
- (any): The underlying cause, or `nil` if none.

Signals:
- `loom-type-error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))
  (loom-error-cause err))

;;;###autoload
(defun loom:error-mark-handled (err)
  "Mark an error as handled.

Arguments:
- `ERR` (loom-error): The error to mark as handled.

Returns:
- (loom-error): The same error object.

Signals:
- `loom-type-error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))
  (setf (loom-error-handled err) t)
  err)

;;;###autoload
(defun loom:error-handled-p (err)
  "Check if an error has been marked as handled.

Arguments:
- `ERR` (loom-error): The error to check.

Returns:
- (boolean): `t` if handled, `nil` otherwise.

Signals:
- `loom-type-error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))
  (loom-error-handled err))

;;;###autoload
(defun loom:serialize-error (err)
  "Serialize a `loom-error` struct into a plist for IPC.

Arguments:
- `ERR` (loom-error): The error object to serialize.

Returns:
- (list): A plist representation of the error.

Signals:
- `loom-type-error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))
  (cl-loop with slots = *loom-error-serializable-slots*
           for slot-name in slots
           for value = (funcall (intern (format "loom-error-%s" slot-name))
                                err)
           when value
           collect (intern (format ":%s" slot-name))
           collect (if (bufferp value) (buffer-name value) value)))

;;;###autoload
(defun loom:deserialize-error (plist)
  "Deserialize a `PLIST` back into a `loom-error` struct.

Arguments:
- `PLIST` (list): A property list created by `loom:serialize-error`.

Returns:
- (loom-error): A new `loom-error` struct.

Signals:
- `loom-type-error`: If `PLIST` is not a list."
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
- (string): A formatted error string.

Signals:
- `loom-type-error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))
  (let ((basic (format "[%s:%s] %s" (loom-error-type err)
                       (loom-error-severity err) (loom-error-message err))))
    (if detailed
        (let ((parts (list basic)))
          (when-let ((code (loom-error-code err)))
            (push (format "Code: %s" code) parts))
          (when-let ((data (loom-error-data err)))
            (push (format "Data: %S" data) parts))
          (when-let ((depth (loom-error-chain-depth err)))
            (when (> depth 0)
              (push (format "Chain Depth: %d" depth) parts)))
          (when-let ((stack (loom-error-async-stack-trace err)))
            (push (format "Async Stack:\n%s" stack) parts))
          (string-join (nreverse parts) "\n"))
      basic)))

;;;###autoload
(defun loom:error-matches-p (err type-or-code)
  "Check if an error matches a given type or code.

Arguments:
- `ERR` (loom-error): The error to check.
- `TYPE-OR-CODE` (keyword or string): The type or code to match against.

Returns:
- (boolean): `t` if the error matches, `nil` otherwise.

Signals:
- `loom-type-error`: If `ERR` is not a `loom-error` struct."
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
- (list): A list of errors from root cause to current error.

Signals:
- `loom-type-error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))
  (let ((chain (list err)) (current err) (max-depth 50))
    (while (and (setq current (loom-error-cause current))
                (loom-error-p current)
                (> (cl-decf max-depth) 0))
      (push current chain))
    (nreverse chain)))

;;;###autoload
(defun loom:error-root-cause (err)
  "Get the root cause of an error chain.

Arguments:
- `ERR` (loom-error): The error to trace back.

Returns:
- (any): The root cause (may not be a loom-error).

Signals:
- `loom-type-error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))
  (let ((current err) (max-depth 50))
    (while (and (loom-error-p (loom-error-cause current))
                (> (cl-decf max-depth) 0))
      (setq current (loom-error-cause current)))
    (or (loom-error-cause current) current)))

;;;###autoload
(defun loom:error-severity-p (err severity)
  "Check if an error has a specific severity level.

Arguments:
- `ERR` (loom-error): The error to check.
- `SEVERITY` (symbol): The severity level to check for.

Returns:
- (boolean): `t` if the error has the specified severity.

Signals:
- `loom-type-error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))
  (eq (loom-error-severity err) severity))

;;;###autoload
(defun loom:error-severity>= (err severity)
  "Check if an error has severity greater than or equal to the given level.

Arguments:
- `ERR` (loom-error): The error to check.
- `SEVERITY` (symbol): The minimum severity level.

Returns:
- (boolean): `t` if the error severity is >= the specified level.

Signals:
- `loom-type-error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err)
    (signal 'loom-type-error (list "Expected loom-error" err)))
  (let ((err-level (cl-position (loom-error-severity err)
                                *loom-error-severity-levels*))
        (check-level (cl-position severity *loom-error-severity-levels*)))
    (and err-level check-level (>= err-level check-level))))

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
  (prog1 (reverse loom--unhandled-rejections-queue)
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

Returns: `nil`.
Signals: `loom-type-error`.
Side Effects: Adds error to queue and triggers unhandled rejection action."
  (unless (loom-error-p error-obj)
    (signal 'loom-type-error (list "Expected loom-error" error-obj)))
  (loom--handle-unhandled-rejection error-obj)
  nil)

;;;###autoload
(defmacro loom:with-error-context (context &rest body)
  "Execute `BODY` with additional error context.
Any `loom-error` created within `BODY` will have the `CONTEXT` plist
merged into its `:context` field.

Arguments:
- `CONTEXT` (plist): Context to add to errors created within `BODY`.
- `BODY` (forms): The forms to execute.

Returns:
- The value of the last form in `BODY`."
  (declare (indent 1) (debug t))
  `(let ((loom-current-async-stack
          (cons (format "Context: %S" ,context) loom-current-async-stack)))
     ,@body))

;;;###autoload
(defun loom:error-statistics ()
  "Return a snapshot of error statistics if enabled.

Returns:
- (plist or nil): A plist of statistics or nil if tracking is disabled."
  (when loom-error-enable-statistics
    (copy-tree loom--error-statistics)))

;;;###autoload
(defun loom:reset-error-statistics ()
  "Reset all error statistics.

Returns: `nil`.
Side Effects: Clears the `loom--error-statistics` variable."
  (when loom-error-enable-statistics
    (setq loom--error-statistics nil)
    (loom-log :info nil "Loom error statistics have been reset."))
  nil)

(provide 'loom-errors)
;;; loom-errors.el ends here