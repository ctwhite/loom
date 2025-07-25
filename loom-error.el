;;; loom-error.el --- Error definitions and handling for Loom -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file defines the various error types used throughout the Loom
;; library, provides a standardized way to create error objects
;; (`loom:error!`), and manages the configuration for how unhandled
;; promise rejections are treated.
;;
;; It encapsulates all error-related concerns, making the core promise
;; implementation cleaner and error handling more consistent and
;; configurable.
;;
;; ## Key Features:
;;
;; - **Rich Error Objects:** The `loom-error` struct captures a wealth of
;;   contextual information, including a unique ID, severity, a machine-
;;   readable code, and the original Lisp error that caused it.
;;
;; - **Comprehensive Stack Traces:** The error object automatically captures
;;   and combines the standard Emacs Lisp backtrace with Loom's async
;;   stack trace, providing unparalleled debugging insight into chained
;;   asynchronous operations.
;;
;; - **Configurable Unhandled Rejection Handling:** Provides a `defcustom`
;;   (`loom-on-unhandled-rejection-action`) to control how the system
;;   reacts to promises that are rejected but have no `.catch` handler.
;;
;; - **Serialization for IPC:** Includes functions to safely serialize and
;;   deserialize `loom-error` objects into plists, allowing them to be
;;   passed between different Emacs processes.

;;; Code:

(require 'cl-lib)
(require 'backtrace)
(require 's)
(require 'seq)

(require 'loom-context)
(require 'loom-promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom--unhandled-rejections-queue '()
  "A list of unhandled `loom-error` objects for later inspection.
Oldest errors are at the head of the list.")

(defvar loom--error-id-counter 0
  "Counter for generating unique error IDs, incremented with each new error.")

(defvar loom--error-statistics nil
  "Statistics about error creation and handling.
A plist with keys: `:total-errors`, `:unhandled-count`, `:by-type`
(a hash table mapping error types to counts).")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Constants

(defconst *loom-error-severity-levels*
  '(:debug :info :warning :error :critical)
  "Valid severity levels for loom errors, in increasing order of severity.")

(defconst *loom-error-serializable-slots*
  '(id type severity code message data timestamp
    async-stack-trace call-site system-context)
  "A list of `loom-error` slots that can be safely serialized to a plist.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-on-unhandled-rejection-action 'log
  "Action to take when a promise is rejected with no error handler.
Possible values are:
- `ignore`: Do nothing.
- `log`: Log a warning message (default).
- `signal`: Signal a `loom-unhandled-rejection` error.
- A function: A function of one argument `(lambda (error-obj))` that
  will be called with the `loom-error` object."
  :type '(choice (const :tag "Ignore" ignore)
                 (const :tag "Log" log)
                 (const :tag "Signal Error" signal)
                 (function :tag "Custom Function"))
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
  "A generic error in the Loom library.")

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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-error (:constructor %%make-loom-error))
  "A standardized error object for promise rejections.

Fields:
- `id` (integer): Unique identifier for this error instance.
- `type` (keyword): Keyword identifying the error (`:cancel`, `:timeout`).
- `severity` (symbol): Error severity level (`:warning`, `:error`, etc.).
- `code` (string): Machine-readable error code for programmatic handling.
- `message` (string): A human-readable error message.
- `data` (any): Additional structured data associated with the error.
- `cause` (any): The original Lisp error or reason that triggered this.
- `async-stack-trace` (string): Formatted combined async and Lisp backtrace.
- `timestamp` (float): Time when the error was created.
- `system-context` (loom-system-context): System context information.
- `handled` (boolean): Whether this error has been marked as handled.
- `call-site` (loom-call-site): The captured Lisp call site."
  (id (cl-incf loom--error-id-counter) :type integer)
  (type :generic :type keyword)
  (severity :error :type symbol)
  (code nil :type (or null string))
  (message "An unspecified Loom error occurred." :type string)
  (data nil)
  (cause nil)
  (async-stack-trace nil :type (or null string))
  (call-site nil :type (or loom-call-site null))
  (timestamp (float-time) :type float)
  (system-context nil :type (or loom-system-context null))
  (handled nil :type boolean))

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

(defun loom--validate-error-args (args)
  "Validate error creation arguments and return a normalized plist.

Arguments:
- `ARGS` (plist): The user-provided arguments to `loom:error!`.

Returns:
- (plist): A validated and normalized plist of arguments.

Signals:
- `error`: If type, severity, or code are invalid."
  (let ((validated-args (copy-sequence args)))
    (when-let ((message-val (plist-get validated-args :message)))
      (let ((message-str (if (stringp message-val) message-val
                           (format "%S" message-val))))
        (setf (plist-get validated-args :message)
              (loom--truncate-string message-str
                                     loom-error-max-message-length))))
    (when-let ((type (plist-get validated-args :type)))
      (unless (keywordp type)
        (error "Error type must be a keyword: %S" type)))
    (when-let ((severity (plist-get validated-args :severity)))
      (unless (memq severity *loom-error-severity-levels*)
        (error "Invalid severity level: %S" severity)))
    (when-let ((code (plist-get validated-args :code)))
      (unless (stringp code)
        (error "Error code must be a string: %S" code)))
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
      ;; Inherit relevant fields from the cause, if not already provided.
      (dolist (slot '(type severity code async-stack-trace))
        (let* ((key (intern (format ":%s" slot)))
               (val (funcall (intern (format "loom-error-%s" slot)) cause)))
          (unless (plist-member inherited-args key)
            (setf (plist-get inherited-args key) val))))
      ;; Inherit context if not provided
      (unless (plist-member inherited-args :call-site)
        (setf (plist-get inherited-args :call-site)
              (loom-error-call-site cause)))
      (unless (plist-member inherited-args :system-context)
        (setf (plist-get inherited-args :system-context)
              (loom-error-system-context cause)))
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

Side Effects:
- Modifies `loom--error-statistics`."
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

Side Effects:
- May modify `loom--unhandled-rejections-queue`."
  (while (> (length loom--unhandled-rejections-queue)
            loom-error-max-unhandled-queue-size)
    ;; Remove the oldest entry (at the tail of the list).
    (setq loom--unhandled-rejections-queue
          (nbutlast loom--unhandled-rejections-queue))))

(defun loom--handle-unhandled-rejection (error-obj)
  "Handle an unhandled rejection according to configuration.

Arguments:
- `ERROR-OBJ` (loom-error): The unhandled error.

Returns: `nil`.

Side Effects:
- Adds error to queue and executes the configured action."
  (push error-obj loom--unhandled-rejections-queue)
  (loom--manage-unhandled-queue)
  (when loom--error-statistics
    (cl-incf (plist-get loom--error-statistics :unhandled-count)))
  ;; Execute the user-configured action for this unhandled rejection.
  (pcase loom-on-unhandled-rejection-action
    ('ignore nil) ; Do nothing.
    ('log (loom:log! :warn nil "Unhandled promise rejection [%s]: %s"
                     (loom-error-type error-obj)
                     (loom-error-message error-obj)))
    ('signal (signal 'loom-unhandled-rejection (list error-obj)))
    ((pred functionp)
     (condition-case err
         (funcall loom-on-unhandled-rejection-action error-obj)
       (error (loom:log! :error nil
                         "Error in unhandled rejection handler: %S" err))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defmacro loom:error! (&rest user-args)
  "Create a new `loom-error` struct, capturing contextual information.
If the `:cause` is another `loom-error`, its properties are inherited.
Explicitly provided arguments in `USER-ARGS` always take precedence.

This macro automatically captures the Emacs Lisp call site where it is
invoked, providing more accurate debugging information.

Arguments:
- `USER-ARGS` (plist): Key-value pairs for `loom-error` fields.
  Common keys include: `:type`, `:message`, `:cause`, `:data`, `:severity`.

Returns:
- (loom-error): A new, populated `loom-error` struct.

Side Effects:
- Increments `loom--error-id-counter` and updates statistics."
  (declare (debug t))
  `(let* ((full-context (loom:context-current))
          (call-site (plist-get full-context :call-site))
          (system-context (plist-get full-context :system-context))
          (validated-args (loom--validate-error-args (list ,@user-args)))
          (cause (plist-get validated-args :cause))
          (async-stack (loom-context-format-async-labels))
          (lisp-stack (loom-context-capture-and-format-emacs-backtrace))
          (combined-stack (loom-context-combine-stack-traces
                           async-stack lisp-stack))
          (inherited (if cause
                         (loom--inherit-from-cause cause validated-args)
                       '()))
          (derived-message (or (plist-get validated-args :message)
                               (if cause
                                   (loom--extract-message-from-cause cause))
                               "An unspecified Loom error occurred."))
          (final-args (append validated-args inherited
                              `(:async-stack-trace ,combined-stack
                                :system-context ,system-context
                                :call-site ,call-site))))
     (setf (plist-get final-args :message) derived-message)
     (let ((error-obj (apply #'%%make-loom-error final-args)))
       (loom--update-error-statistics error-obj)
       error-obj)))

;;;###autoload
(defun loom:serialize-error (err)
  "Serialize a `loom-error` struct into a plist for IPC.

Arguments:
- `ERR` (loom-error): The error object to serialize.

Returns:
- (list): A plist representation of the error, containing only
  serializable slots defined in `*loom-error-serializable-slots*`.

Signals:
- `error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err) (error "Expected loom-error, got %S" err))
  (cl-loop with slots = *loom-error-serializable-slots*
           for slot-name in slots
           for value = (funcall (intern (format "loom-error-%s" slot-name))
                                err)
           when value
           nconc (list (intern (format ":%s" slot-name))
                       (cond
                        ((bufferp value) (buffer-name value))
                        ;; Serialize nested context structs into plists.
                        ((loom-call-site-p value)
                         `(:file ,(loom-call-site-file value)
                           :line ,(loom-call-site-line value)
                           :fn ,(loom-call-site-fn value)))
                        ((loom-system-context-p value)
                         `(:buffer ,(loom-system-context-buffer value)
                           :major-mode
                           ,(loom-system-context-major-mode value)))
                        (t value)))))

;;;###autoload
(defun loom:deserialize-error (plist)
  "Deserialize a `PLIST` back into a `loom-error` struct.

Arguments:
- `PLIST` (list): A property list created by `loom:serialize-error`.

Returns:
- (loom-error): A new `loom-error` struct.

Signals:
- `error`: If `PLIST` is not a list."
  (unless (listp plist) (error "Expected plist, got %S" plist))
  (let ((processed-plist (copy-sequence plist)))
    ;; Reconstruct the nested context structs from their plist representations.
    (when-let (cs-plist (plist-get processed-plist :call-site))
      (setf (plist-get processed-plist :call-site)
            (apply #'make-loom-call-site cs-plist)))
    (when-let (sc-plist (plist-get processed-plist :system-context))
      (setf (plist-get processed-plist :system-context)
            (apply #'make-loom-system-context sc-plist)))
    (apply #'%%make-loom-error processed-plist)))

;;;###autoload
(defun loom-report-unhandled-rejection (error-obj)
  "Report an unhandled rejection for tracking and processing.

Arguments:
- `ERROR-OBJ` (loom-error): The error object representing the rejection.

Returns: `nil`.

Side Effects:
- Adds error to queue and triggers unhandled rejection action.

Signals:
- `error` if `ERROR-OBJ` is not a `loom-error`."
  (unless (loom-error-p error-obj)
    (error "Expected loom-error, got %S" error-obj))
  (loom--handle-unhandled-rejection error-obj)
  nil)

;;;###autoload
(defun loom:error-statistics ()
  "Return a snapshot of error statistics if enabled.

Arguments: None.

Returns:
- (plist or nil): A plist of statistics or nil if tracking is disabled."
  (when loom--error-statistics
    ;; Copy the hash table to prevent external modification of internal state.
    (let ((stats (copy-tree loom--error-statistics)))
      (when (plist-get stats :by-type)
        (plist-put stats :by-type
                   (copy-hash-table (plist-get stats :by-type))))
      stats)))

;;;###autoload
(defun loom:error-message (promise-or-error)
  "Return human-readable message from a promise's error or an error object.

Arguments:
- `PROMISE-OR-ERROR` (loom-promise or loom-error): The item to inspect.

Returns:
- (string): A descriptive error message."
  (let ((err (if (loom-promise-p promise-or-error)
                 (loom:promise-error-value promise-or-error)
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
- `error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err) (error "Expected loom-error, got %S" err))
  (loom-error-cause err))

;;;###autoload
(defun loom:error-mark-handled (err)
  "Mark an error as handled.

Arguments:
- `ERR` (loom-error): The error to mark as handled.

Returns:
- (loom-error): The same error object (modified in place).

Signals:
- `error`: If `ERR` is not a `loom-error` struct.

Side Effects:
- Modifies the `handled` slot of `ERR`."
  (unless (loom-error-p err) (error "Expected loom-error, got %S" err))
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
- `error`: If `ERR` is not a `loom-error` struct."
  (unless (loom-error-p err) (error "Expected loom-error, got %S" err))
  (loom-error-handled err))

(provide 'loom-error)
;;; loom-error.el ends here
