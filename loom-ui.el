;;; loom-ui.el --- Interactive UI for Concur Promise Introspection -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library provides an interactive user interface for inspecting the
;; `loom` promise registry. It offers developers a real-time, filterable
;; overview of all active and settled promises, aiding in debugging complex
;; asynchronous workflows and interactively managing tasks.
;;
;; To use, call the command `M-x loom:inspect-registry`.
;;
;;; Code:

(require 'tabulated-list)
(require 's)       ;; For s-blank?, s-join, s-chop-prefix
(require 'cl-lib)  ;; For cl-loop, plist-put, plist-remq, when-let
(require 'pp)      ;; For pretty-printing complex values in inspection buffer

(require 'loom-cancel)
(require 'loom-core)
(require 'loom-registry)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Mode Definition & Customization

(defconst loom-ui-buffer-name "*Concur Registry*"
  "Name of the buffer used for the promise registry UI.")

(defcustom loom-ui-auto-refresh-interval 2
  "Interval in seconds for auto-refreshing the `loom-ui-mode` buffer."
  :type 'integer
  :group 'loom)

(defconst loom-ui-action-refresh-delay 0.01
  "Delay in seconds before refreshing UI after an action (e.g., cancel, kill).")

(defvar-local loom-ui--current-filter nil
  "Buffer-local variable holding the current filter property list for `loom-ui-mode`.")
(defvar-local loom-ui--auto-refresh-timer nil
  "Buffer-local variable holding the auto-refresh timer object for `loom-ui-mode`.")

(defvar loom-ui-mode-map nil
  "Keymap for `loom-ui-mode`.")

(setq loom-ui-mode-map
      (define-keymap
        :parent tabulated-list-mode-map
        "r" #'loom-ui-refresh
        "g" #'loom-ui-refresh
        "i" #'loom-ui-inspect-promise
        "RET" #'loom-ui-inspect-promise
        "c" #'loom-ui-cancel-promise
        "k" #'loom-ui-kill-process
        "a" #'loom-ui-toggle-auto-refresh
        "f" (let ((map (make-sparse-keymap "Filter")))
              (define-key map "s" #'loom-ui-filter-by-status)
              (define-key map "n" #'loom-ui-filter-by-name)
              (define-key map "t" #'loom-ui-filter-by-tag)
              (define-key map "c" #'loom-ui-clear-filters)
              map)
        "q" #'quit-window))

(define-derived-mode loom-ui-mode tabulated-list-mode "ConcurUI"
  "Major mode for inspecting the Concur promise registry.

This mode provides a live, filterable view of all promises tracked by
`loom-registry`. It allows for inspecting promise details, cancelling pending
promises, and killing associated OS processes.

\\<loom-ui-mode-map>
Keybindings:
  r, g    Refresh the list of promises.
  i, <RET>  Inspect the promise at point in a separate buffer.
  c       Cancel the pending promise at point.
  k       Kill the OS process associated with the promise at point.
  a       Toggle auto-refresh mode on or off.
  q       Quit the window.

Filtering (prefix `f`):
  f s     Filter by promise status (`:pending`, `:resolved`, `:rejected`).
  f n     Filter by a substring in the promise name.
  f t     Filter by a tag (symbol).
  f c     Clear all active filters."
  ;; Explicitly set major-mode-map to loom-ui-mode-map within the mode's setup.
  (setq-local major-mode-map loom-ui-mode-map)
  (setq tabulated-list-format
        [("Status" 10 :left)
         ("Name" 35 :left)
         ("ID" 18 :left)
         ("Age (s)" 10 :right)
         ("Parent ID" 18 :left)])
  (setq tabulated-list-sort-key '("Age (s)" . t)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal UI Helpers

(defun loom-ui--get-promise-at-point ()
  "Get the `loom-promise` object corresponding to the current line.
Returns `nil` if no promise is found or the ID is invalid."
  (let ((id (tabulated-list-get-id)))
    (when (loom-promise-p id) id)))

(defun loom-ui--format-promise-entry (promise)
  "Format a `PROMISE` into an entry for `tabulated-list-mode`.

`PROMISE` is a `loom-promise` object.

Returns a vector suitable for `tabulated-list-entries`."
  (when-let ((meta (loom-registry-get-promise-meta promise)))
    (let* ((status (loom:status promise))
           (age (format "%.2f" (- (float-time)
                                  (loom-promise-meta-creation-time meta))))
           (parent-id (when-let ((p (loom-promise-meta-parent-promise meta)))
                        (format "%S" (loom-promise-id p)))))
      (vector
       ;; The ID for tabulated-list is the promise object itself.
       promise
       ;; The list of strings to display in the columns.
       (list (propertize (format "%S" status) 'face
                         (pcase status
                           (:pending 'font-lock-warning-face)
                           (:resolved 'font-lock-function-name-face)
                           (:rejected 'error)))
             (format "%s" (or (loom-promise-meta-name meta) "--"))
             (format "%S" (loom-promise-id promise))
             age
             (or parent-id "--"))))))

(defun loom-ui--update-mode-line ()
  "Update the `loom-ui-mode` mode-line with current filter and refresh status."
  (let* ((filter-str
          (when loom-ui--current-filter
            (s-join ", "
                    (cl-loop for (k v) on loom-ui--current-filter by #'cddr
                             collect (format "%s: %S"
                                             (s-chop-prefix ":" (symbol-name k))
                                             v)))))
         (refresh-str (if loom-ui--auto-refresh-timer "[Auto]" "[Manual]"))
         (status-str (if filter-str
                         (format " Filter: %s" filter-str)
                       " Filter: None")))
    (setq mode-line-process (format " %s %s" refresh-str status-str))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Interactive Commands

(defun loom-ui-refresh (&optional _arg)
  "Refresh the list of promises, applying current filters.
This command is bound to `r` and `g` in `loom-ui-mode`."
  (interactive)
  (let ((inhibit-read-only t)
        (current-id (tabulated-list-get-id)))
    (erase-buffer)
    (let ((promises (apply #'loom:list-promises loom-ui--current-filter)))
      (setq tabulated-list-entries
            (delq nil (mapcar #'loom-ui--format-promise-entry promises))))
    (tabulated-list-init-header)
    (tabulated-list-print)
    (goto-char (point-min))
    (when current-id
      (tabulated-list-position-to-id current-id)))
  (loom-ui--update-mode-line)
  (message "Registry refreshed at %s" (format-time-string "%T")))

(defun loom-ui-inspect-promise ()
  "Show detailed, formatted metadata for the promise at point.
Opens a new buffer `*Concur Promise Details*`.
This command is bound to `i` and `<RET>` in `loom-ui-mode`."
  (interactive)
  (when-let ((promise (loom-ui--get-promise-at-point)))
    (with-current-buffer (get-buffer-create "*Concur Promise Details*")
      (let ((inhibit-read-only t)
            (meta (loom-registry-get-promise-meta promise)))
        (erase-buffer)
        (insert (format "--- Details for Promise: %S ---\n\n"
                        (loom-promise-id promise)))
        (insert "** Name:**\t" (or (loom-promise-meta-name meta) "N/A") "\n")
        (insert "** Status:**\t" (format "%S" (loom:status promise)) "\n")
        (insert "** Mode:**\t" (format "%S" (loom-promise-mode promise)) "\n")
        ;; Use pp for values and errors for better readability of complex objects
        (when-let ((val (loom:value promise)))
          (insert "** Value:**\n")
          (with-temp-buffer
            (pp val (current-buffer))
            (insert-buffer-substring (current-buffer)))
          (insert "\n"))
        (when-let ((err (loom:error-value promise)))
          (insert "** Error:**\n")
          (with-temp-buffer
            (pp err (current-buffer))
            (insert-buffer-substring (current-buffer)))
          (insert "\n"))
        (insert "\n** Timeline **\n")
        (insert "- Created: \t"
                (format-time-string
                 "%T" (loom-promise-meta-creation-time meta)) "\n")
        (when-let ((time (loom-promise-meta-settlement-time meta)))
          (insert "- Settled: \t" (format-time-string "%T" time) "\n"))
        (insert "\n** Relationships **\n")
        (when-let ((parent (loom-promise-meta-parent-promise meta)))
          (insert "- Parent:\t" (format "%S" (loom-promise-id parent)) "\n"))
        (when-let ((children (loom-promise-meta-children-promises meta)))
          (insert "- Children:\n")
          (dolist (child children)
            (insert "  - " (format "%S" (loom-promise-id child)) "\n")))
        (display-buffer (current-buffer))))))

(defun loom-ui-cancel-promise ()
  "Cancel the pending promise at point.
This command is bound to `c` in `loom-ui-mode`."
  (interactive)
  (if-let ((promise (loom-ui--get-promise-at-point)))
      (if (loom:pending-p promise)
          (progn
            (loom:cancel promise "Cancelled via UI")
            (message "Cancelled promise: %s" (loom-promise-id promise))
            (run-with-timer loom-ui-action-refresh-delay nil #'loom-ui-refresh))
        (message "Cannot cancel a promise that is not pending."))
    (message "No promise at point.")))

(defun loom-ui-kill-process ()
  "Kill the OS process associated with the promise at point, if any.
This command is bound to `k` in `loom-ui-mode`."
  (interactive)
  (if-let* ((promise (loom-ui--get-promise-at-point))
            (proc (loom-promise-proc promise)))
      (if (and proc (process-live-p proc))
          (progn
            (delete-process proc)
            (message "Killed process for promise: %s" (loom-promise-id promise))
            (run-with-timer loom-ui-action-refresh-delay nil #'loom-ui-refresh))
        (message "No live process associated with this promise."))
    (message "No promise at point.")))

(defun loom-ui-toggle-auto-refresh ()
  "Toggle periodic refreshing of the promise registry view.
The refresh interval is controlled by `loom-ui-auto-refresh-interval`.
This command is bound to `a` in `loom-ui-mode`."
  (interactive)
  (if loom-ui--auto-refresh-timer
      (progn
        (cancel-timer loom-ui--auto-refresh-timer)
        (setq loom-ui--auto-refresh-timer nil)
        (message "Auto-refresh disabled."))
    (setq loom-ui--auto-refresh-timer
          (run-with-timer 0 loom-ui-auto-refresh-interval
                          #'loom-ui-refresh))
    (message "Auto-refresh enabled (every %d seconds)."
             loom-ui-auto-refresh-interval))
  (loom-ui--update-mode-line))

(defun loom-ui-filter-by-status ()
  "Interactively filter the promise list by status.
Prompts for one of `:pending`, `:resolved`, or `:rejected`.
This command is bound to `f s` in `loom-ui-mode`."
  (interactive)
  (let ((status-str (completing-read "Filter by status: "
                                     '("pending" "resolved" "rejected"))))
    (setf loom-ui--current-filter
          (plist-put loom-ui--current-filter :status (intern (concat ":" status-str))))
    (loom-ui-refresh)))

(defun loom-ui-filter-by-name ()
  "Interactively filter the promise list by a substring in the promise name.
An empty input clears the name filter.
This command is bound to `f n` in `loom-ui-mode`."
  (interactive)
  (let ((name (read-string "Filter by name contains: ")))
    (if (s-blank? name)
        (setq loom-ui--current-filter
              (plist-remq loom-ui--current-filter :name))
      (setf loom-ui--current-filter
            (plist-put loom-ui--current-filter :name name)))
    (loom-ui-refresh)))

(defun loom-ui-filter-by-tag ()
  "Interactively filter the promise list by tag.
Prompts for a tag (e.g., `my-tag`). An empty input clears the tag filter.
This command is bound to `f t` in `loom-ui-mode`."
  (interactive)
  (let ((tag-str (read-string "Filter by tag: ")))
    (if (s-blank? tag-str)
        (setq loom-ui--current-filter
              (plist-remq loom-ui--current-filter :tags))
      (setf loom-ui--current-filter
            (plist-put loom-ui--current-filter :tags
                       (intern (concat ":" tag-str)))))
    (loom-ui-refresh)))

(defun loom-ui-clear-filters ()
  "Clear all active filters and refresh the view.
This command is bound to `f c` in `loom-ui-mode`."
  (interactive)
  (setq loom-ui--current-filter nil)
  (loom-ui-refresh)
  (message "All filters cleared."))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public Entry Point

;;;###autoload
(defun loom:inspect-registry ()
  "Open an interactive buffer to inspect the `loom` promise registry.

If the promise registry is not enabled via `loom-enable-promise-registry`,
an error is signaled. The UI will reset any existing filters and
auto-refresh settings when opened."
  (interactive)
  (message "Opening Concur Promise Registry...")
  (unless loom-enable-promise-registry
    (error "Promise registry is not enabled (`loom-enable-promise-registry`)"))
  (let ((buf (get-buffer-create loom-ui-buffer-name)))
    (with-current-buffer buf
      (loom-ui-mode)
      ;; Reset state when opening the UI.
      (setq loom-ui--current-filter nil)
      (when-let (timer loom-ui--auto-refresh-timer) (cancel-timer timer))
      (setq loom-ui--auto-refresh-timer nil)
      (loom-ui-refresh))
    (display-buffer buf)))

(provide 'loom-ui)
;;; loom-ui.el ends here