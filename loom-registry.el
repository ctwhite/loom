;;; loom-registry.el --- Concur Promise Registry for Introspection -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides a global, introspectable registry for
;; `loom-promise` objects. When enabled, it tracks the lifecycle,
;; relationships, and state changes of all promises created within the
;; Loom library. This is crucial for:
;;
;; -   **Debugging:** Gaining real-time insight into complex asynchronous
;;     workflows by inspecting promise states, values, and relationships.
;; -   **Monitoring:** Observing promise activity, identifying bottlenecks,
;;     and understanding overall asynchronous task flow.
;; -   **Resource Management:** Helping identify long-lived or leaked
;;     promises that might consume excessive memory if not handled.
;; -   **UI Integration:** Powering interactive tools (like a future
;;     `loom-ui.el`) that provide visual representations of promise chains.
;; -   **Memory Management:** Preventing the registry itself from bloating
;;     unboundedly by implementing intelligent eviction policies for old
;;     or settled promises.

;;; Code:

(require 'cl-lib)
(require 'seq)

(require 'loom-error)
(require 'loom-lock)
(require 'loom-log)
(require 'loom-priority-queue)
(require 'loom-promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defgroup loom-registry nil
  "Promise registry configuration for the Loom library."
  :group 'loom)

(defcustom loom-enable-promise-registry t
  "If non-nil, enable the global promise registry for introspection.
When disabled, promises are not tracked, saving memory and CPU overhead,
but debugging and monitoring features are unavailable."
  :type 'boolean
  :group 'loom-registry)

(defcustom loom-registry-shutdown-on-exit-p t
  "If non-nil, automatically reject all pending promises on Emacs exit.
This ensures that applications waiting on these promises are notified
of the shutdown, preventing indefinite hangs."
  :type 'boolean
  :group 'loom-registry)

(defcustom loom-registry-max-size 2048
  "Maximum number of promises to keep in the registry.
When this limit is exceeded, the oldest settled promises are evicted
to prevent unbounded memory growth. A value of 0 means no limit."
  :type 'integer
  :group 'loom-registry)

(defcustom loom-registry-auto-cleanup-interval 60
  "Interval in seconds for automatic cleanup of settled promises.
This timer periodically triggers eviction of old, settled promises
from the registry. Set to `nil` to disable automatic cleanup."
  :type '(choice (const :tag "Disabled" nil) (integer :tag "Seconds"))
  :group 'loom-registry)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-registry-error
  "A generic error related to the promise registry."
  'loom-error)

(define-error 'loom-registry-disabled-error
  "Operation attempted on disabled promise registry.
This error is signaled when a function requiring the registry to be enabled
is called while `loom-enable-promise-registry` is nil."
  'loom-registry-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State

(defvar loom--registry-cleanup-timer nil
  "Timer object for the automatic registry cleanup process.
This timer is active when `loom-registry-auto-cleanup-interval` is set
and `loom-enable-promise-registry` is non-nil.")

(defvar loom--promise-registry (make-hash-table :test 'eq)
  "Global hash table mapping promise objects to their `loom-promise-meta` data.
The keys are `loom-promise` objects themselves.")

(defvar loom--promise-id-to-promise-map (make-hash-table :test 'eq)
  "Secondary index, a hash table mapping a promise's unique `id` (a `gensym`
symbol) to the actual `loom-promise` object. This allows efficient lookup
by ID, for example, from IPC messages.")

(defvar loom--promise-registry-lock (loom:make-lock)
  "Mutex protecting all registry data structures for thread-safety.")

(defvar loom--promise-age-pq
  (loom:priority-queue
   :comparator
   (lambda (p1 p2)
     ;; This comparator defines the eviction priority for the
     ;; `loom--promise-age-pq` (a min-heap). It prioritizes evicting
     ;; promises that are:
     ;; 1. Settled (not pending) - these are generally less critical to keep.
     ;; 2. Older (earlier creation time) - for promises of the same status.
     (let ((p1-pending-p (loom:promise-pending-p p1))
           (p2-pending-p (loom:promise-pending-p p2)))
       (cond
        ;; Case A: One is pending, the other is not. Prioritize evicting the
        ;; one that is NOT pending (settled promise has higher eviction priority).
        ((and p1-pending-p (not p2-pending-p)) nil)
        ((and (not p1-pending-p) p2-pending-p) t)
        ;; Case B: Both have the same status (both pending or both settled).
        ;; Prioritize evicting the older promise (smaller creation time).
        (t (< (or (loom-promise-created-at p1) 0.0)
              (or (loom-promise-created-at p2) 0.0)))))))
  "A priority queue of all promises, ordered by their eviction
  priority. Used to efficiently select which promises to remove
  when `loom-registry-max-size` is exceeded.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-promise-meta (:constructor %%make-promise-meta))
  "Metadata for a promise stored in the global registry.
This struct holds additional information about a promise's lifecycle
and relationships, used for introspection and debugging.

Fields:
- `promise` (loom-promise): The actual promise object this metadata describes.
- `name` (string): A human-readable name for the promise.
- `status-history` (list): An alist of status changes `(timestamp . status)`.
- `settlement-time` (float or nil): The `float-time` when the promise
  transitioned from `:pending` to `:resolved` or `:rejected`.
- `parent-promise` (loom-promise or nil): The promise that created this one.
- `children-promises` (list): A list of promises created by this
  promise's handlers.
- `tags` (list): A list of keyword tags for categorization.
- `handler-count` (integer): The number of handlers currently attached."
  (promise nil :type (satisfies loom-promise-p))
  (name nil :type string)
  (status-history nil :type list)
  (settlement-time nil :type (or null float))
  (parent-promise nil :type (or null (satisfies loom-promise-p)))
  (children-promises nil :type list)
  (tags nil :type list)
  (handler-count 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Utility Functions

(defun loom--registry-enabled-p ()
  "Returns non-nil if the promise registry is currently enabled.

Arguments: None.

Returns:
- (boolean): `t` if `loom-enable-promise-registry` is non-nil."
  loom-enable-promise-registry)

(defun loom--registry-ensure-enabled ()
  "Signals a `loom-registry-disabled-error` if the promise registry is disabled.
This function is used as a guard for public API calls that require the
registry to be active.

Arguments: None.

Returns: `nil`.

Signals:
- `loom-registry-disabled-error` if the registry is disabled."
  (unless (loom--registry-enabled-p)
    (signal 'loom-registry-disabled-error
            '("Promise registry is disabled"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Registry Management

(defun loom--registry-remove-promise-entry (promise)
  "Removes all internal registry entries for `PROMISE`.
This function must be called from within `loom--promise-registry-lock`
to ensure thread-safety. It cleans up references in the main hash table,
ID map, and updates parent/child relationships.

Arguments:
- `PROMISE` (loom-promise): The promise object to remove from the registry.

Returns: `nil`.

Side Effects:
- Modifies `loom--promise-registry`, `loom--promise-id-to-promise-map`,
  and updates metadata of related promises (parents)."
  (let ((meta (gethash promise loom--promise-registry)))
    (when meta ; Ensure metadata exists before attempting to remove.
      ;; Remove promise from its parent's children list, if a parent exists.
      (when-let ((parent (loom-promise-meta-parent-promise meta)))
        (when (loom-promise-p parent)
          (when-let ((parent-meta (gethash parent loom--promise-registry)))
            (setf (loom-promise-meta-children-promises parent-meta)
                  (delq promise
                        (loom-promise-meta-children-promises
                         parent-meta))))))
      ;; Remove the promise from the main registry hash table.
      (remhash promise loom--promise-registry)
      ;; Remove the promise from the ID-to-promise map.
      (remhash (loom-promise-id promise) loom--promise-id-to-promise-map)
      (loom:log! :debug (loom-promise-id promise)
                 "Removed promise from registry."))))

(defun loom--registry-evict ()
  "Evicts promises from the registry if `loom-registry-max-size` is exceeded.
This function is called after a new promise is registered or during automatic
cleanup. It uses `loom--promise-age-pq` to efficiently select which promises
to remove based on their status (settled preferred) and age (older preferred).
This must be called from within `loom--promise-registry-lock`.

Arguments: None.

Returns: `nil`.

Side Effects:
- Removes promises from the registry hash tables."
  (cl-block loom--registry-evict
    (while (> (hash-table-count loom--promise-registry)
              loom-registry-max-size)
      ;; Pop the highest-priority promise for eviction from the PQ.
      (if-let ((evicted-promise (loom:priority-queue-pop
                                 loom--promise-age-pq)))
          (progn
            (loom:log! :debug (loom-promise-id evicted-promise)
                       "Evicting promise '%s' due to registry overflow."
                       (loom:format-promise evicted-promise))
            ;; Remove all associated entries for the evicted promise.
            (loom--registry-remove-promise-entry evicted-promise))
        ;; This case should ideally not happen if the PQ and hash table
        ;; remain consistent, but it's a safeguard.
        (loom:log! :warn nil
                   (concat "Registry overflow, but eviction queue is empty. "
                           "This indicates a potential inconsistency."))
        (cl-return-from loom--registry-evict nil)))))

(cl-defun loom-registry-register-promise (promise &key parent-promise name tags)
  "Registers a new `PROMISE` in the global registry.
This function creates and stores metadata for the promise, linking it to
its parent promise and adding it to the eviction queue. It's a no-op if
the registry is disabled.

Arguments:
- `PROMISE` (loom-promise): The promise object to register.
- `:PARENT-PROMISE` (loom-promise): The promise that created this one.
- `:NAME` (string): A human-readable name for the promise.
- `:TAGS` (list): A list of keyword tags for filtering.

Returns:
- (loom-promise-meta or nil): The newly created metadata object, or `nil`
  if the registry is disabled.

Side Effects:
- Adds entries to `loom--promise-registry`, `loom--promise-id-to-promise-map`,
  `loom--promise-age-pq`.
- Updates `parent-promise`'s metadata.
- May trigger `loom--registry-evict` if `loom-registry-max-size` is exceeded."
  (when (loom--registry-enabled-p)
    (loom:with-mutex! loom--promise-registry-lock
      (let* ((promise-id (loom-promise-id promise))
             ;; Create the metadata struct for this promise.
             (meta (%%make-promise-meta
                    :promise promise :name name
                    :parent-promise parent-promise
                    :tags (cl-delete-duplicates (if (listp tags) tags
                                                  (list tags))))))
        ;; Store the metadata, indexed by the promise object itself.
        (puthash promise meta loom--promise-registry)
        ;; Store a secondary index, mapping promise ID to the promise object.
        (puthash promise-id promise loom--promise-id-to-promise-map)
        ;; Insert the promise into the age-based priority queue for eviction.
        (loom:priority-queue-insert loom--promise-age-pq promise)
        ;; Record the initial status in the history.
        (push (cons (float-time) (loom-promise-state promise))
              (loom-promise-meta-status-history meta))
        ;; Link to parent promise's children list.
        (when (and parent-promise (loom-promise-p parent-promise))
          (when-let ((parent-meta (gethash parent-promise
                                           loom--promise-registry)))
            (push promise (loom-promise-meta-children-promises parent-meta))))
        ;; Trigger eviction if max size is exceeded.
        (loom--registry-evict)
        meta))))

(defun loom-registry-update-promise-state (promise)
  "Updates the state of `PROMISE` in the registry when it settles.
This function is called internally by `loom-promise.el` after a promise
transitions from `:pending` to `:resolved` or `:rejected`. It updates the
promise's metadata with its final settlement time and status history.

Arguments:
- `PROMISE` (loom-promise): The promise that has just settled.

Returns: `nil`.

Side Effects:
- Modifies the promise's `loom-promise-meta` in `loom--promise-registry`."
  (when (loom--registry-enabled-p)
    (loom:with-mutex! loom--promise-registry-lock
      (when-let ((meta (gethash promise loom--promise-registry)))
        (let ((current-time (float-time)))
          ;; Record the settlement time.
          (setf (loom-promise-meta-settlement-time meta) current-time)
          ;; Add the final status to the history.
          (push (cons current-time (loom-promise-state promise))
                (loom-promise-meta-status-history meta)))))))

(defun loom-registry-has-downstream-handlers-p (promise)
  "Returns non-nil if `PROMISE` has any downstream handlers registered.
This includes direct handlers (tracked by `handler-count`) and any promises
that directly branched off from this one (`children-promises`). This is
a crucial check for the unhandled rejection detection mechanism.

Arguments:
- `PROMISE` (loom-promise): The promise to check for downstream handlers.

Returns:
- (boolean): `t` if there are any attached handlers or child promises,
  `nil` otherwise."
  (when (loom--registry-enabled-p)
    (loom:with-mutex! loom--promise-registry-lock
      (when-let ((meta (gethash promise loom--promise-registry)))
        (or (> (loom-promise-meta-handler-count meta) 0)
            (not (null (loom-promise-meta-children-promises meta))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Introspection

;;;###autoload
(defun loom-registry-get-promise-by-id (promise-id)
  "Returns the promise object associated with `PROMISE-ID`.
This is an efficient lookup method, primarily used for internal IPC
(Inter-Process Communication) and debugging tools where only a promise's
unique ID is known.

Arguments:
- `PROMISE-ID` (symbol): The unique `gensym` ID of the promise.

Returns:
- (loom-promise or nil): The promise object, or `nil` if no promise
  with that ID is found in the registry."
  (when (and (loom--registry-enabled-p) promise-id)
    (loom:with-mutex! loom--promise-registry-lock
      (gethash promise-id loom--promise-id-to-promise-map))))

;;;###autoload
(defun loom-registry-get-promise-meta (promise)
  "Returns the full metadata object for `PROMISE` from the registry.
This function provides direct access to the `loom-promise-meta` struct,
which contains detailed information about the promise's lifecycle,
relationships, and statistics.

Arguments:
- `PROMISE` (loom-promise): The promise object for which to retrieve metadata.

Returns:
- (loom-promise-meta or nil): The metadata object, or `nil` if the
  promise is not found in the registry or the registry is disabled."
  (when (loom--registry-enabled-p)
    (loom:with-mutex! loom--promise-registry-lock
      (gethash promise loom--promise-registry))))

;;;###autoload
(defun loom-registry-get-promise-name (promise &optional default)
  "Returns the human-readable name of a registered promise.
If the promise is not in the registry or has no explicit name, an optional
`DEFAULT` value can be returned.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.
- `DEFAULT` (string, optional): A default value to return if no name is found.

Returns:
- (string or nil): The name of the promise, or `DEFAULT` if provided,
  otherwise `nil`."
  (if-let ((meta (loom-registry-get-promise-meta promise)))
      (loom-promise-meta-name meta)
    default))

;;;###autoload
(cl-defun loom:list-promises (&key status name tags parent-promise)
  "Returns a list of promises from the registry, filtered by criteria.
This function is a powerful tool for inspecting the state of asynchronous
operations in your Emacs session.

Arguments:
- `:STATUS` (symbol): Filter by promise state: `:pending`, `:resolved`, etc.
- `:NAME` (string): Filter by a substring match in the promise's name.
- `:TAGS` (list or symbol): Filter by one or more keyword tags.
- `:PARENT-PROMISE` (loom-promise): Filter by the promise's direct parent.

Returns:
- (list): A list of `loom-promise` objects matching all applied filters.

Signals: `loom-registry-disabled-error` if the registry is not enabled."
  (loom--registry-ensure-enabled)
  (let (matching)
    (loom:with-mutex! loom--promise-registry-lock
      (maphash
       (lambda (promise meta)
         (when (and (or (null status)
                        (eq (loom:promise-status promise) status))
                    (or (null name)
                        (and (stringp (loom-promise-meta-name meta))
                             (string-match-p (regexp-quote name)
                                             (loom-promise-meta-name meta))))
                    (or (null tags)
                        (let ((p-tags (loom-promise-meta-tags meta)))
                          (cl-some (lambda (tag) (memq tag p-tags))
                                   (if (listp tags) tags (list tags)))))
                    (or (null parent-promise)
                        (eq parent-promise
                            (loom-promise-meta-parent-promise meta))))
           (push promise matching)))
       loom--promise-registry))
    (nreverse matching)))

;;;###autoload
(defun loom:clear-registry (&optional force)
  "Clears all promises from the global registry.
This function removes all promises, their metadata, and clears the eviction
queue. It's primarily intended for testing or debugging scenarios where
a complete reset of the registry state is required.

Arguments:
- `FORCE` (boolean): If non-nil, clear the registry even if
  `loom-enable-promise-registry` is currently `nil`.

Returns: `nil`.

Side Effects:
- Empties `loom--promise-registry`, `loom--promise-id-to-promise-map`,
  and `loom--promise-age-pq`."
  (interactive "P")
  (when (or force (loom--registry-enabled-p))
    (loom:with-mutex! loom--promise-registry-lock
      (clrhash loom--promise-registry)
      (clrhash loom--promise-id-to-promise-map)
      (loom:priority-queue-clear loom--promise-age-pq))
    (loom:log! :warn nil "Loom promise registry cleared.")))

;;;###autoload
(defun loom:registry-status ()
  "Returns a snapshot of the global promise registry's current status.
This function provides quick metrics about the promises currently being
tracked, such as total count, and counts by state.

Returns:
- (plist): A property list with registry metrics.

Signals: `loom-registry-disabled-error` if the registry is not enabled."
  (interactive)
  (loom--registry-ensure-enabled)
  (loom:with-mutex! loom--promise-registry-lock
    (let ((total 0) (pending 0) (resolved 0) (rejected 0))
      (maphash
       (lambda (promise _meta)
         (cl-incf total)
         (pcase (loom:promise-status promise)
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Automatic Cleanup and Shutdown

(defun loom--registry-auto-cleanup-fn ()
  "The function called by the automatic cleanup timer.
This function is responsible for triggering the `loom--registry-evict`
process periodically if the registry is enabled.

Arguments: None.

Returns: `nil`.

Side Effects:
- May evict old, settled promises from the registry."
  (when (loom--registry-enabled-p)
    (loom:with-mutex! loom--promise-registry-lock
      (loom:log! :debug nil "Running automatic registry cleanup...")
      (loom--registry-evict))))

(defun loom--registry-start-cleanup-timer ()
  "Starts the automatic registry cleanup timer if configured.

Arguments: None.

Returns: `nil`.

Side Effects:
- Creates and starts `loom--registry-cleanup-timer`."
  (when (and loom-registry-auto-cleanup-interval
             (> loom-registry-auto-cleanup-interval 0)
             (not (timerp loom--registry-cleanup-timer)))
    (loom:log! :info nil
               "Starting registry auto-cleanup timer (interval: %ds)."
               loom-registry-auto-cleanup-interval)
    (setq loom--registry-cleanup-timer
          (run-with-timer loom-registry-auto-cleanup-interval
                          loom-registry-auto-cleanup-interval
                          #'loom--registry-auto-cleanup-fn))))

(defun loom--registry-shutdown-hook ()
  "A `kill-emacs-hook` function to ensure graceful shutdown of the registry.
This hook stops the cleanup timer and, if configured by
`loom-registry-shutdown-on-exit-p`, rejects all still-pending promises
in the registry.

Arguments: None.

Returns: `nil`.

Side Effects:
- Stops the cleanup timer.
- May reject all pending promises."
  (when (timerp loom--registry-cleanup-timer)
    (cancel-timer loom--registry-cleanup-timer))
  (when (and (loom--registry-enabled-p) loom-registry-shutdown-on-exit-p)
    (loom:with-mutex! loom--promise-registry-lock
      (loom:log! :info nil
                 "Emacs shutdown: Rejecting pending promises in registry.")
      (maphash
       (lambda (p _meta)
         (when (loom:promise-pending-p p)
           (loom:promise-reject p
                        (loom:error! :type 'loom-registry-shutdown-error
                                     :message "Emacs is shutting down."))))
       loom--promise-registry))))

;; Initialize and register hooks
(add-hook 'kill-emacs-hook #'loom--registry-shutdown-hook)
(when (loom--registry-enabled-p)
  (loom--registry-start-cleanup-timer))

(provide 'loom-registry)
;;; loom-registry.el ends here