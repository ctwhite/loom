;;; loom-registry.el --- Concur Promise Registry for Introspection -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This module provides a global, introspectable registry for
;; `loom-promise` objects. When enabled, it tracks the lifecycle,
;; relationships, and state changes of all promises created within the
;; Concur library. This is crucial for:
;;
;; - **Debugging:** Gaining real-time insight into complex asynchronous workflows.
;; - **Monitoring:** Observing promise activity and performance.
;; - **Resource Management:** Identifying long-lived or leaked promises.
;; - **UI Integration:** Powering interactive tools like `loom-ui.el`.
;; - **Performance Analysis:** Tracking promise creation patterns and timings.
;; - **Memory Management:** Preventing registry bloat with intelligent eviction.

;;; Code:

(require 'cl-lib)
(require 'seq)

(require 'loom-errors)
(require 'loom-lock)
(require 'loom-log)
(require 'loom-priority-queue)
(require 'loom-promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-enable-promise-registry t
  "If non-nil, enable the global promise registry for introspection."
  :type 'boolean
  :group 'loom)

(defcustom loom-registry-shutdown-on-exit-p t
  "If non-nil, automatically reject all pending promises on Emacs exit."
  :type 'boolean
  :group 'loom)

(defcustom loom-registry-max-size 2048
  "Maximum number of promises to keep in the registry.
When this limit is exceeded, the oldest settled promises are evicted."
  :type 'integer
  :group 'loom)

(defcustom loom-registry-enable-metrics t
  "If non-nil, collect detailed performance metrics for the registry."
  :type 'boolean
  :group 'loom)

(defcustom loom-registry-metrics-window 300
  "Time window in seconds for calculating registry metrics."
  :type 'integer
  :group 'loom)

(defcustom loom-registry-auto-cleanup-interval 60
  "Interval in seconds for automatic cleanup of settled promises.
Set to nil to disable automatic cleanup."
  :type '(choice (const :tag "Disabled" nil) (integer :tag "Seconds"))
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-registry-error
  "A generic error related to the promise registry."
  'loom-error)

(define-error 'loom-registry-shutdown-error
  "A promise was rejected because Emacs is shutting down."
  'loom-registry-error)

(define-error 'loom-registry-disabled-error
  "Operation attempted on disabled promise registry."
  'loom-registry-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State

(defvar loom--registry-metrics nil
  "Internal plist for registry performance analysis.")

(defvar loom--registry-cleanup-timer nil
  "Timer for automatic registry cleanup.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-promise-meta (:constructor %%make-promise-meta))
  "Metadata for a promise in the global registry.

Fields:
- `promise` (loom-promise): The promise object this metadata describes.
- `name` (string): A human-readable name for the promise.
- `status-history` (list): An alist of status changes `(timestamp . status)`.
- `settlement-time` (float or nil): The time the promise settled.
- `parent-promise` (loom-promise or nil): The promise that created this one.
- `children-promises` (list): Promises created by this promise's handlers.
- `tags` (list): A list of keyword tags for filtering and categorization.
- `handler-count` (integer): Number of handlers attached to this promise."
  (promise nil :type (satisfies loom-promise-p))
  (name nil :type string)
  (status-history nil :type list)
  (settlement-time nil :type (or null float))
  (parent-promise nil :type (or null (satisfies loom-promise-p)))
  (children-promises nil :type list)
  (tags nil :type list)
  (handler-count 0 :type integer))

(defvar loom--promise-registry (make-hash-table :test 'eq)
  "Global hash table mapping promise objects to `loom-promise-meta` data.")

(defvar loom--promise-id-to-promise-map (make-hash-table :test 'eq)
  "Secondary index mapping a promise's unique ID to the promise object.")

(defvar loom--promise-registry-lock (loom:lock "promise-registry-lock")
  "Mutex protecting all registry data structures for thread-safety.")

(defvar loom--promise-age-pq
  (loom:priority-queue
   :comparator
   (lambda (p1 p2)
     ;; This comparator makes the PQ a min-heap that prioritizes evicting
     ;; settled promises over pending ones. If both have the same status,
     ;; it evicts the one that was created earliest.
     (let ((s1-pending-p (loom:pending-p p1))
           (s2-pending-p (loom:pending-p p2)))
       (if (eq s1-pending-p s2-pending-p)
           ;; Both have same status, compare by creation time (older is smaller).
           (< (or (loom-promise-created-at p1) 0.0)
              (or (loom-promise-created-at p2) 0.0))
         ;; Status differs. Settled (not pending) is smaller (higher priority).
         (not s1-pending-p)))))
  "A priority queue of all promises, ordered by eviction priority.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Utility Functions

(defun loom--registry-enabled-p ()
  "Return non-nil if the promise registry is enabled."
  loom-enable-promise-registry)

(defun loom--registry-ensure-enabled ()
  "Signal an error if the promise registry is disabled.

Returns: `nil`.
Signals: `loom-registry-disabled-error`."
  (unless (loom--registry-enabled-p)
    (signal 'loom-registry-disabled-error
            '("Promise registry is disabled"))))

(defun loom--registry-update-metrics (event)
  "Update registry metrics for `EVENT`.

Arguments:
- `EVENT` (keyword): The event type (e.g., `:promise-registered`).

Returns: `nil`.
Side Effects: Modifies `loom--registry-metrics`."
  (when loom-registry-enable-metrics
    (let ((current-time (float-time)))
      (pcase event
        (:promise-registered
         (cl-incf (plist-get loom--registry-metrics :total-registered))
         (let* ((history (plist-get loom--registry-metrics
                                    :creation-rate-history))
                (new-history (cons current-time
                                   (seq-take-while
                                    (lambda (t) (< (- current-time t)
                                                   loom-registry-metrics-window))
                                    history))))
           (setf (plist-get loom--registry-metrics :creation-rate-history)
                 new-history)))
        (:promise-settled
         (let* ((history (plist-get loom--registry-metrics
                                    :settlement-rate-history))
                (new-history (cons current-time
                                   (seq-take-while
                                    (lambda (t) (< (- current-time t)
                                                   loom-registry-metrics-window))
                                    history))))
           (setf (plist-get loom--registry-metrics :settlement-rate-history)
                 new-history)))
        (:promise-evicted
         (cl-incf (plist-get loom--registry-metrics :total-evicted)))
        (:gc-run
         (cl-incf (plist-get loom--registry-metrics :total-gc-runs))
         (setf (plist-get loom--registry-metrics :last-gc-time)
               current-time))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Registry Management

(defun loom--registry-remove-promise-entry (promise)
  "Remove all registry entries for `PROMISE`.
This must be called from within `loom--promise-registry-lock`.

Arguments:
- `PROMISE` (loom-promise): The promise to remove.

Returns: `nil`.
Side Effects: Modifies registry hash tables and metrics."
  (let ((meta (gethash promise loom--promise-registry)))
    (when meta
      (when-let ((parent (loom-promise-meta-parent-promise meta)))
        (when-let ((parent-meta (gethash parent loom--promise-registry)))
          (setf (loom-promise-meta-children-promises parent-meta)
                (delq promise
                      (loom-promise-meta-children-promises parent-meta)))))
      (remhash (loom-promise-id promise) loom--promise-id-to-promise-map)
      (remhash promise loom--promise-registry)
      (loom--registry-update-metrics :promise-evicted))))

(defun loom--registry-evict ()
  "Evict promises if the registry exceeds `loom-registry-max-size`.
This must be called from within `loom--promise-registry-lock`.

Returns: `nil`.
Side Effects: Removes promises from the registry."
  (while (> (hash-table-count loom--promise-registry)
            loom-registry-max-size)
    (if-let ((evicted-promise (loom:priority-queue-pop loom--promise-age-pq)))
        (progn
          (loom-log :debug nil
                    "Evicting promise '%s' due to registry overflow."
                    (loom:format-promise evicted-promise))
          (loom--registry-remove-promise-entry evicted-promise))
      ;; Should not happen if PQ is consistent with the hash table.
      (loom-log :warn nil
                "Registry overflow, but eviction queue is empty.")
      (cl-return))))

(defun loom-registry-register-promise (promise &key parent-promise tags)
  "Register a new `PROMISE` in the global registry.

Arguments:
- `PROMISE` (loom-promise): The promise object to register.
- `:PARENT-PROMISE` (loom-promise, optional): The promise that created this one.
- `:TAGS` (list, optional): A list of keyword tags for filtering.

Returns:
- (loom-promise-meta or nil): The created metadata object, or nil if disabled."
  (when (loom--registry-enabled-p)
    (loom:with-mutex! loom--promise-registry-lock
      (let* ((name (symbol-name (loom-promise-id promise)))
             (meta (%%make-promise-meta :promise promise :name name
                                        :parent-promise parent-promise
                                        :tags (cl-delete-duplicates tags))))
        (puthash promise meta loom--promise-registry)
        (puthash (loom-promise-id promise) promise
                 loom--promise-id-to-promise-map)
        (loom:priority-queue-insert loom--promise-age-pq promise)
        (push (cons (float-time) (loom-promise-state promise))
              (loom-promise-meta-status-history meta))
        (when (and parent-promise (loom-promise-p parent-promise))
          (when-let ((parent-meta (gethash parent-promise
                                           loom--promise-registry)))
            (push promise
                  (loom-promise-meta-children-promises parent-meta))))
        (loom--registry-update-metrics :promise-registered)
        (loom--registry-evict)
        meta))))

(defun loom-registry-update-promise-state (promise)
  "Update the state of `PROMISE` in the registry when it settles.

Arguments:
- `PROMISE` (loom-promise): The promise that has just settled.

Returns: `nil`.
Side Effects: Updates the promise's metadata in the registry."
  (when (loom--registry-enabled-p)
    (loom:with-mutex! loom--promise-registry-lock
      (when-let ((meta (gethash promise loom--promise-registry)))
        (let ((current-time (float-time)))
          (setf (loom-promise-meta-settlement-time meta) current-time)
          (push (cons current-time (loom-promise-state promise))
                (loom-promise-meta-status-history meta))
          (loom--registry-update-metrics :promise-settled))))))

(defun loom-registry-update-handler-count (promise delta)
  "Update the handler count for `PROMISE` by `DELTA`.

Arguments:
- `PROMISE` (loom-promise): The promise to update.
- `DELTA` (integer): The change in handler count (+1 or -1).

Returns: `nil`.
Side Effects: Modifies the handler count in the promise's metadata."
  (when (loom--registry-enabled-p)
    (loom:with-mutex! loom--promise-registry-lock
      (when-let ((meta (gethash promise loom--promise-registry)))
        (cl-incf (loom-promise-meta-handler-count meta) delta)))))

(defun loom-registry-has-downstream-handlers-p (promise)
  "Return non-nil if `PROMISE` has any downstream handlers registered.

Arguments:
- `PROMISE` (loom-promise): The promise to check.

Returns:
- (boolean): `t` if handlers are attached, `nil` otherwise."
  (when (loom--registry-enabled-p)
    (when-let ((meta (gethash promise loom--promise-registry)))
      (or (> (loom-promise-meta-handler-count meta) 0)
          (loom-promise-meta-children-promises meta)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Introspection

;;;###autoload
(defun loom-registry-get-promise-by-id (promise-id)
  "Return the promise object associated with `PROMISE-ID`.

Arguments:
- `PROMISE-ID` (symbol): The unique `gensym` ID of the promise.

Returns:
- (loom-promise or nil): The promise object, or `nil` if not found."
  (when (and (loom--registry-enabled-p) promise-id)
    (loom:with-mutex! loom--promise-registry-lock
      (gethash promise-id loom--promise-id-to-promise-map))))

;;;###autoload
(defun loom-registry-get-promise-meta (promise)
  "Return the metadata for `PROMISE`.

Arguments:
- `PROMISE` (loom-promise): The promise object.

Returns:
- (loom-promise-meta or nil): The metadata object, or nil if not found."
  (when (loom--registry-enabled-p)
    (loom:with-mutex! loom--promise-registry-lock
      (gethash promise loom--promise-registry))))

;;;###autoload
(defun loom-registry-get-promise-name (promise &optional default)
  "Return the name of a registered promise.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.
- `DEFAULT` (string, optional): A default value if no name is found.

Returns:
- (string or nil): The name of the promise."
  (if-let ((meta (loom-registry-get-promise-meta promise)))
      (loom-promise-meta-name meta)
    default))

;;;###autoload
(cl-defun loom:list-promises (&key status name tags parent-promise created-after created-before)
  "Return a list of promises from the registry, with optional filters.

Arguments:
- `:STATUS` (symbol, optional): `:pending`, `:resolved`, or `:rejected`.
- `:NAME` (string, optional): Substring match in the name.
- `:TAGS` (list or symbol, optional): Promise must have at least one tag.
- `:PARENT-PROMISE` (loom-promise, optional): Filter by parent.
- `:CREATED-AFTER` (float, optional): Filter by creation time.
- `:CREATED-BEFORE` (float, optional): Filter by creation time.

Returns:
- (list): A list of `loom-promise` objects matching the filters."
  (loom--registry-ensure-enabled)
  (let (matching)
    (loom:with-mutex! loom--promise-registry-lock
      (maphash
       (lambda (promise meta)
         (when (and (or (null status) (eq (loom:status promise) status))
                    (or (null name)
                        (and (loom-promise-meta-name meta)
                             (string-match-p (regexp-quote name)
                                             (loom-promise-meta-name meta))))
                    (or (null tags)
                        (let ((p-tags (loom-promise-meta-tags meta)))
                          (cl-some (lambda (tag) (memq tag p-tags))
                                   (if (listp tags) tags (list tags)))))
                    (or (null parent-promise)
                        (eq parent-promise
                            (loom-promise-meta-parent-promise meta)))
                    (or (null created-after)
                        (>= (loom-promise-created-at promise) created-after))
                    (or (null created-before)
                        (<= (loom-promise-created-at promise) created-before)))
           (push promise matching)))
       loom--promise-registry))
    (nreverse matching)))

;;;###autoload
(defun loom:find-promise (id-or-name)
  "Find a promise in the registry by its ID (symbol) or name (string).

Arguments:
- `ID-OR-NAME` (symbol or string): The promise's `gensym` ID or name.

Returns:
- (loom-promise or nil): The matching promise, or `nil`."
  (loom--registry-ensure-enabled)
  (if (symbolp id-or-name)
      (loom-registry-get-promise-by-id id-or-name)
    (loom:with-mutex! loom--promise-registry-lock
      (cl-block find-by-name
        (maphash (lambda (promise meta)
                   (when (string= id-or-name
                                  (loom-promise-meta-name meta))
                     (cl-return-from find-by-name promise)))
                 loom--promise-registry)))))

;;;###autoload
(defun loom:clear-registry (&optional force)
  "Clear all promises from the global registry.
This is primarily for testing or debugging. Use with caution.

Arguments:
- `FORCE` (boolean, optional): If non-nil, clear even if disabled.

Returns: `nil`."
  (interactive "P")
  (when (or force (loom--registry-enabled-p))
    (loom:with-mutex! loom--promise-registry-lock
      (clrhash loom--promise-registry)
      (clrhash loom--promise-id-to-promise-map)
      (loom:priority-queue-clear loom--promise-age-pq))
    (loom-log :warn nil "Concur promise registry cleared.")))

;;;###autoload
(defun loom:registry-status ()
  "Return a snapshot of the global promise registry's current status.

Returns:
- (plist): A property list with registry metrics."
  (interactive)
  (unless (loom--registry-enabled-p)
    (error "Promise registry is disabled"))
  (loom:with-mutex! loom--promise-registry-lock
    (let ((total 0) (pending 0) (resolved 0) (rejected 0))
      (maphash
       (lambda (promise _meta)
         (cl-incf total)
         (pcase (loom:status promise)
           (:pending (cl-incf pending))
           (:resolved (cl-incf resolved))
           (:rejected (cl-incf rejected))))
       loom--promise-registry)
      `(:enabled-p t
        :max-size ,loom-registry-max-size
        :total-promises ,total
        :pending-count ,pending
        :resolved-count ,resolved
        :rejected-count ,rejected))))

;;;###autoload
(defun loom:registry-metrics ()
  "Return a snapshot of the registry's performance metrics.

Returns:
- (plist or nil): A property list with performance data, or nil if disabled."
  (interactive)
  (when loom-registry-enable-metrics
    (loom:with-mutex! loom--promise-registry-lock
      (copy-tree loom--registry-metrics))))

;;;###autoload
(defun loom:reset-registry-metrics ()
  "Reset all registry performance metrics to their initial state.

Returns: `nil`."
  (interactive)
  (when loom-registry-enable-metrics
    (loom:with-mutex! loom--promise-registry-lock
      (setq loom--registry-metrics
            `(:total-registered 0 :total-evicted 0 :total-gc-runs 0
              :last-gc-time nil :creation-rate-history nil
              :settlement-rate-history nil)))
    (loom-log :info nil "Loom registry metrics have been reset.")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Automatic Cleanup and Shutdown

(defun loom--registry-auto-cleanup-fn ()
  "The function called by the automatic cleanup timer."
  (when (loom--registry-enabled-p)
    (loom:with-mutex! loom--promise-registry-lock
      (loom-log :debug nil "Running automatic registry cleanup...")
      (loom--registry-evict))))

(defun loom--registry-start-cleanup-timer ()
  "Start the automatic registry cleanup timer if configured."
  (when (and loom-registry-auto-cleanup-interval
             (not (timerp loom--registry-cleanup-timer)))
    (setq loom--registry-cleanup-timer
          (run-with-timer loom-registry-auto-cleanup-interval
                          loom-registry-auto-cleanup-interval
                          #'loom--registry-auto-cleanup-fn))))

(defun loom--registry-stop-cleanup-timer ()
  "Stop the automatic registry cleanup timer."
  (when (timerp loom--registry-cleanup-timer)
    (cancel-timer loom--registry-cleanup-timer)
    (setq loom--registry-cleanup-timer nil)))

(defun loom--registry-shutdown-hook ()
  "Reject all pending promises on Emacs exit."
  (loom--registry-stop-cleanup-timer)
  (when (and (loom--registry-enabled-p) loom-registry-shutdown-on-exit-p)
    (loom:with-mutex! loom--promise-registry-lock
      (maphash
       (lambda (p _meta)
         (when (loom:pending-p p)
           (loom:reject p
                        (loom:make-error :type 'loom-registry-shutdown-error
                                         :message "Emacs is shutting down."))))
       loom--promise-registry))))

;; Initialize and register hooks
(add-hook 'kill-emacs-hook #'loom--registry-shutdown-hook)
(when (loom--registry-enabled-p)
  (loom--registry-start-cleanup-timer))

(provide 'loom-registry)
;;; loom-registry.el ends here