;;; loom-context.el --- Context capture for Loom -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file centralizes all logic for capturing and managing execution
;; context within the Loom library. This includes Emacs Lisp call sites,
;; dynamic async stack labels, and system-level context.
;;
;; It provides a standardized way to enrich log messages and error objects
;; with comprehensive debugging information.
;;
;; Key features:
;; - Captures function name, file, and line number of call sites.
;; - Manages a dynamic async stack for tracing promise chains.
;; - Provides a mechanism to attach arbitrary context data.
;; - Configurable options for backtrace depth and capture.
;;
;;; Code:

(require 'cl-lib)
(require 's)
(require 'backtrace)
(require 'seq)
(require 'macroexp) 

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-context-max-async-stack-depth 50
  "Maximum depth for async stack trace labels to prevent excessive memory
and formatting time usage. This limit applies only to the async labels,
not the full Emacs Lisp backtrace."
  :type 'natnum
  :group 'loom)

(defcustom loom-context-capture-emacs-backtrace-p t
  "If non-nil, capture a full Emacs Lisp backtrace when a call site is
captured. This backtrace can then be appended to traces.
Setting this to `nil` can reduce memory usage and context capture time."
  :type 'boolean
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom-current-async-stack nil
  "A dynamically-scoped list of labels for the current async call stack.
Used to build richer debugging information for logs and error objects,
providing context for `loom-error` objects.")

(defvar loom--context-line-number-cache (make-hash-table :test 'equal)
  "A cache for memoizing `loom-context--find-function-start-line`.")
  
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct loom-call-site
  "A structure representing the Emacs Lisp call site.

Fields:
- `file` (string or nil): The file name where the code was defined.
- `line` (integer or nil): The *starting line number* of the function.
- `fn` (symbol or nil): The function name where the context was captured."
  (file nil :type (or string null))
  (line nil :type (or integer null))
  (fn nil :type (or symbol null)))

(cl-defstruct (loom-system-context (:constructor %%make-loom-system-context)
                                   (:copier nil))
  "A structure representing a snapshot of the Emacs Lisp system environment.

Fields:
- `buffer` (string): The name of the current buffer.
- `major-mode` (symbol): The current major mode.
- `point` (integer): The current buffer point.
- `emacs-version` (string): The Emacs version string.
- `system-type` (symbol): The operating system type."
  (buffer (buffer-name (current-buffer)) :type string)
  (major-mode major-mode :type symbol)
  (point (point) :type integer)
  (emacs-version emacs-version :type string)
  (system-type system-type :type symbol))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers - Call Site Capture (macro-expanded)

(defun loom-context--find-function-start-line (function-name file)
  "Uncached worker for `loom-context--find-function-start-line-memo`.

Arguments:
- `function-name` (string): The name of the function to find.
- `file` (string): The path to the file where the function is defined.

Returns:
- (integer or nil): The starting line number, or `nil`."
  (cl-block nil
    (unless (and (stringp function-name)
                 (stringp file)
                 (file-readable-p file)) 
      (cl-return nil))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          ;; Regex for `defun`, `defmacro`, `cl-defstruct`, `define-*`.
          (let ((regex (format (concat "^(\\s-*\\(defun\\|defmacro\\"
                                       "|cl-defstruct\\|define-\\w+\\)"
                                       "\\s-+%s\\_>")
                               (regexp-quote function-name))))
            (if (re-search-forward regex nil t)
                (line-number-at-pos (match-beginning 0))
              ;; Also check for `;;;###autoload` directly preceding defuns.
              (goto-char (point-min))
              (let ((autoload-regex
                     (format (concat ";;;###autoload[[:space:]\n]+"
                                     "(\\(defun\\|defmacro\\)"
                                     "\\s-+%s\\_>")
                             (regexp-quote function-name))))
                (if (re-search-forward autoload-regex nil t)
                    (line-number-at-pos (match-beginning 0))
                  nil)))))
      (error nil))))

(defun loom-context--find-function-start-line-memo (function-name file)
  "Return the line number of `FUNCTION-NAME` in `FILE`, with memoization.

Arguments:
- `function-name` (string): The name of the function to find.
- `file` (string): The path to the file where the function is defined.

Returns:
- (integer or nil): The starting line number, or `nil`."
  (let ((key (cons function-name file)))
    (or (gethash key loom--context-line-number-cache)
        (puthash key
                 (loom-context--find-function-start-line function-name file)
                 loom--context-line-number-cache))))

(defmacro loom-context--capture-fn-name! ()
  "Return the name of the calling function as a string at compile time.
This looks through the backtrace for the first non-macro form that is
a function definition (e.g., `defun`, `defmacro`) or `defalias`."
  (declare (indent 1) (debug t))
  (let ((frames nil)
        (index 5)) ; Skip macroexpansion layers to find user's code.
    ;; Collect frames
    (while (let ((frame (backtrace-frame index)))
             (when frame
               (push frame frames)
               (cl-incf index))))
    ;; Find the first relevant form and extract its name
    (let ((name (thread-last 
                   (reverse frames)
                   (seq-find (lambda (f)
                               (ignore-errors
                                 (let ((form (macroexp-unquote-all
                                              (cadr f))))
                                   (or (and (listp form)
                                            (memq (car form)
                                                  '(defun defmacro
                                                    cl-defstruct)))
                                       (and (listp form)
                                            (eq (car form) 'defalias)
                                            (listp (cadr form))))))))
                   (lambda (found-frame)
                     (when found-frame
                       (let ((form (macroexp-unquote-all (cadr found-frame))))
                         (cl-case (car form)
                           ((defun defmacro cl-defstruct) (cadr form))
                           (defalias
                            (when (and (listp (cadr form))
                                       (eq (car (cadr form)) 'quote))
                              (cadr (cadr form))))
                           (t nil))))))))
      (cond
       ((symbolp name) (symbol-name name))
       ((stringp name) name)
       (t nil)))))

(defmacro loom-context--capture-file-name! ()
  "Return the file name of the current source file at compile time."
  (declare (indent 1) (debug t))
  (let ((file (or (when (fboundp 'macroexp-file-name)
                    (macroexp-file-name))
                  (bound-and-true-p byte-compile-current-file)
                  (bound-and-true-p load-file-name))))
    (when (stringp file)
      file)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Context Building

;;;###autoload
(defmacro loom-context-capture-call-site ()
  "Capture the current Emacs Lisp call site at macroexpansion time.

Returns:
- (loom-call-site): A `loom-call-site` struct with file, line, and function."
  `(let* ((fn-name-str (loom-context--capture-fn-name!))
          (file-name (loom-context--capture-file-name!)))
     (make-loom-call-site
      :fn (when fn-name-str (intern fn-name-str))
      :file file-name
      :line (when (and fn-name-str file-name)
              (loom-context--find-function-start-line-memo fn-name-str
                                                            file-name)))))

;;;###autoload
(defun loom-context-capture-system-context ()
  "Capture current Emacs Lisp execution context for reporting.

Returns:
- (loom-system-context): A `loom-system-context` struct with relevant
  contextual information."
  (%%make-loom-system-context)) ; Use the auto-generated constructor

;;;###autoload
(defun loom-context-format-async-labels ()
  "Format `loom-current-async-stack` into a readable string.

Returns:
- (string or nil): The formatted stack labels, or nil if empty."
  (when loom-current-async-stack
    (let ((stack (if (> (length loom-current-async-stack)
                        loom-context-max-async-stack-depth)
                     ;; Use seq-take and append for truncation
                     (append
                      (seq-take loom-current-async-stack
                                loom-context-max-async-stack-depth)
                      (list (format "... (%d more frames)"
                                    (- (length loom-current-async-stack)
                                       loom-context-max-async-stack-depth))))
                   loom-current-async-stack)))
      (mapconcat #'identity (reverse stack) "\n↳ "))))

;;;###autoload
(defun loom-context-capture-and-format-emacs-backtrace ()
  "Captures and filters the current Emacs Lisp backtrace.

Returns:
- (string or nil): The formatted backtrace string, or nil if capture
  is disabled or backtrace is empty/irrelevant.
Side Effects: Invokes `backtrace-string`."
  (when loom-context-capture-emacs-backtrace-p
    (let* ((bt-raw (with-output-to-string (backtrace)))
           (bt-lines (s-lines bt-raw))
           ;; Heuristic to remove internal Loom context frames
           ;; and other direct callers to keep the trace relevant.
           (filtered-lines
            (seq-drop-while (lambda (l)
                              (or (s-contains-p "loom-context--" l)
                                  (s-contains-p "loom:with-context!" l)
                                  (s-contains-p "macroexp-" l)
                                  (s-contains-p "eval" l)
                                  (s-contains-p "cl-macflet" l)
                                  (s-contains-p "cl-macrolet" l)))
                            bt-lines)))
      (unless (null filtered-lines)
        (s-join "\n" (mapcar #'s-trim filtered-lines))))))

;;;###autoload
(defun loom-context-combine-stack-traces (async-labels-str emacs-bt-str)
  "Combine async labels and Emacs backtrace into a single string.

Arguments:
- `async-labels-str` (string or nil): Formatted async labels.
- `emacs-bt-str` (string or nil): Formatted Emacs backtrace.

Returns:
- (string or nil): Combined string, or nil if both are nil."
  (cond
   ((and async-labels-str emacs-bt-str)
    (format "Async Stack:\n%s\n\nEmacs Backtrace:\n%s"
            async-labels-str emacs-bt-str))
   (async-labels-str (format "Async Stack:\n%s" async-labels-str))
   (emacs-bt-str (format "Emacs Backtrace:\n%s" emacs-bt-str))
   (t nil)))

;;;###autoload
(defun loom:context-current ()
  "Generate a comprehensive context snapshot including call site and
system context.

Returns:
- (plist): A plist containing a `loom-call-site` struct and a
  `loom-system-context` struct.
  Keys: `:call-site` and `:system-context`."
  `(:call-site ,(loom-context-capture-call-site)
    :system-context ,(loom-context-capture-system-context)))

;;;###autoload
(defmacro loom:with-context! (context-label &rest body)
  "Execute `BODY` with `loom-current-async-stack` updated with
`CONTEXT-LABEL`.
This macro adds `CONTEXT-LABEL` to the dynamic async stack for any
subsequent `loom-context-format-async-labels` calls within `BODY`.

Arguments:
- `CONTEXT-LABEL` (string): A descriptive string to add to the async stack.
- `BODY` (forms): The forms to execute.

Returns:
- The value of the last form in `BODY`.
Side Effects: Dynamically binds `loom-current-async-stack`."
  (declare (indent 1)
           (debug (context-label &rest body)))
  `(let ((loom-current-async-stack
          (cons ,context-label loom-current-async-stack)))
     ,@body))

(provide 'loom-context)
;;; loom-context.el ends here