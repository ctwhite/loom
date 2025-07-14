;;; loom-registry.el --- Concur Promise Registry for Introspection -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This module provides a global, introspectable registry for
;; `loom-promise` objects. When enabled, it tracks the lifecycle,
;; relationships, and state changes of all promises created within the
;; Concur library. This is crucial for:
;;
;; - **Debugging:** Gaining real-time insight into complex asynchronous
;;   workflows.
;; - **Monitoring:** Observing promise activity and performance.
;; - **Resource Management:** Identifying long-lived or leaked promises.
;; - **UI Integration:** Powering interactive tools like `loom-ui.el`.
;;
;; Architectural Highlights:
;;
;; - **Capped Size:** To prevent unbounded memory growth, the registry
;;   is capped by `loom-registry-max-size`. It uses a priority queue
;;   (`loom-priority-queue`) to efficiently evict the oldest promises
;;   (based on `created-at` time) when the limit is reached.
;; - **O(1) ID Lookup:** A secondary hash table (`loom--promise-id-to-promise-map`)
;;   provides instantaneous retrieval of promises by their unique ID.
;; - **Rich Metadata:** `loom-promise-meta` structs capture detailed
;;   context for each promise, including parent/child relationships,
;;   status history, and associated resources.
;; - **Thread-Safety:** All internal operations are protected by a mutex
;;   (`loom--promise-registry-lock`) to ensure safe concurrent access.

;;; Code:

(require 'cl-lib)

(require 'loom-errors)
(require 'loom-lock)
(require 'loom-log)
(require 'loom-priority-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom-promise-p "loom-promise")
(declare-function loom-promise-id "loom-promise")
(declare-function loom-promise-state "loom-promise")
(declare-function loom-promise-created-at "loom-promise")
(declare-function loom:status "loom-promise")
(declare-function loom:pending-p "loom-promise")
(declare-function loom:format-promise "loom-promise")
(declare-function loom:reject "loom-promise")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-registry-error
  "A generic error related to the promise registry."
  'loom-error)

(define-error 'loom-registry-shutdown-error
  "A promise was rejected because Emacs is shutting down."
  'loom-registry-error)

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
  "Maximum number of *total* promises (pending or settled) to keep in the
registry. This prevents the registry from growing indefinitely. When the
number of promises exceeds this limit, the oldest ones (based on creation
time) are evicted, prioritizing settled promises first."
  :type 'integer
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State

(defvar loom-resource-tracking-function nil
  "A function called by primitives when a resource is acquired or released.
The function should accept two arguments: `ACTION` (a keyword like
`:acquire` or `:release`) and `RESOURCE` (the primitive object itself).
This is intended to be dynamically bound by a higher-level library
(e.g., a promise executor) to associate resource management with a
specific task.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-promise-meta (:constructor %%make-promise-meta))
  "Metadata for a promise in the global registry.

Fields:
- `promise` (loom-promise): The promise object this metadata describes.
- `name` (string): A human-readable name for the promise.
- `status-history` (list): An alist of status changes `(timestamp . status)`.
- `settlement-time` (float or nil): The time the promise settled, or `nil`.
- `parent-promise` (loom-promise or nil): The promise that created this one.
- `children-promises` (list): Promises created by this promise's handlers.
- `resources-held` (list): External resources currently held by this promise
  (e.g., locks), for debugging deadlocks.
- `tags` (list): A list of keyword tags for filtering and categorization."
  (promise nil :type (satisfies loom-promise-p))
  (name nil :type string)
  (status-history nil :type list)
  (settlement-time nil :type (or null float))
  (parent-promise nil :type (or null (satisfies loom-promise-p)))
  (children-promises nil :type list)
  (resources-held nil :type list)
  (tags nil :type list))

(defvar loom--promise-registry (make-hash-table :test 'eq)
  "Global hash table mapping promise objects to `loom-promise-meta` data.")

(defvar loom--promise-id-to-promise-map (make-hash-table :test 'eq)
  "Secondary index mapping a promise's unique ID to the promise object.")

(defvar loom--promise-registry-lock
  (loom:lock "promise-registry-lock")
  "Mutex protecting all registry data structures for thread-safety.")

(defvar loom--promise-age-pq
  (loom:priority-queue
   :comparator 
   (lambda (p1 p2)
     (< (or (loom-promise-created-at p1) 0.0)
        (or (loom-promise-created-at p2) 0.0))))
  "A priority queue (min-heap) of all promises, ordered by their `created-at` time.
Used to efficiently find and evict the oldest promises.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Registry Management

(defun loom--registry-remove-promise-entry (promise)
  "Remove all registry entries for `PROMISE`.
This must be called from within `loom--promise-registry-lock`."
  (remhash (loom-promise-id promise)
           loom--promise-id-to-promise-map)
  (remhash promise loom--promise-registry))

(defun loom--registry-evict ()
  "Evict promises if the registry exceeds `loom-registry-max-size`.
Eviction prioritizes the oldest promises based on `created-at` time.
It continuously pops from the priority queue until the registry size
is within limits, ensuring that only promises still present in the
main registry are actually removed.
This must be called from within the `loom--promise-registry-lock`."
  (cl-block loom--registry-evict
    (while (> (hash-table-count loom--promise-registry)
              loom-registry-max-size)
      (let ((evicted-promise nil))
        ;; Keep popping from PQ until we find a promise that's still in the registry.
        ;; A promise might have been removed by other means (e.g., manual clear)
        ;; or might not have been properly added to the PQ if registry was disabled.
        (while (and (not (loom:priority-queue-empty-p loom--promise-age-pq))
                    (null evicted-promise))
          (let* ((potential-oldest (loom:priority-queue-pop
                                    loom--promise-age-pq)))
            ;; Verify this promise still exists in the main registry
            (when (gethash potential-oldest loom--promise-registry)
              (setq evicted-promise potential-oldest))))

        (when evicted-promise
          (loom-log :debug nil
                    "Evicting promise '%S' (ID: %S) due to registry overflow."
                    (loom-promise-meta-name
                     (gethash evicted-promise loom--promise-registry))
                    (loom-promise-id evicted-promise))
          (loom--registry-remove-promise-entry evicted-promise))
        ;; If we failed to evict, and the registry is still over capacity,
        ;; something is wrong.
        (unless evicted-promise
          (loom-log :warn nil
                    "Registry overflow, but no promise could be evicted. Breaking eviction loop.")
          (cl-return-from loom--registry-evict nil))))))

(cl-defun loom-registry-register-promise
    (promise name &key parent-promise tags)
  "Register a new `PROMISE` in the global registry.
This function is called by `loom:promise`.

Arguments:
- `PROMISE` (loom-promise): The promise object to register.
- `NAME` (string): A human-readable name for the promise.
- `:PARENT-PROMISE` (loom-promise, optional): The promise that created this one.
- `:TAGS` (list, optional): A list of keyword tags for filtering."
  (when loom-enable-promise-registry
    (loom:with-mutex! loom--promise-registry-lock
      (let ((meta (%%make-promise-meta :promise promise 
                                       :name name
                                       :parent-promise parent-promise
                                       :tags (cl-delete-duplicates tags))))
        (puthash promise meta loom--promise-registry)
        (puthash (loom-promise-id promise) promise
                 loom--promise-id-to-promise-map)
        ;; Add promise to the age-based priority queue
        (loom:priority-queue-insert loom--promise-age-pq promise)
        ;; Update status history for the meta object
        (push (cons (float-time) (loom-promise-state promise))
              (loom-promise-meta-status-history meta))
        (when (and parent-promise (loom-promise-p parent-promise))
          (when-let ((parent-meta (gethash parent-promise
                                           loom--promise-registry)))
            (push promise
                  (loom-promise-meta-children-promises parent-meta))))
        ;; Call eviction logic after adding
        (loom--registry-evict)))))

(defun loom-registry-update-promise-state (promise)
  "Update the state of `PROMISE` in the registry when it settles.
This function is called by the core promise settlement logic.

Arguments:
- `PROMISE` (loom-promise): The promise that has just settled."
  (when loom-enable-promise-registry
    (loom:with-mutex! loom--promise-registry-lock
      (when-let ((meta (gethash promise loom--promise-registry)))
        (let ((current-time (float-time)))
          (setf (loom-promise-meta-settlement-time meta) current-time)
          (push (cons current-time (loom-promise-state promise))
                (loom-promise-meta-status-history meta))
          ;; No longer enqueueing to a FIFO queue for eviction;
          ;; the priority queue handles overall age-based eviction.
          )))))

(defun loom-registry-register-resource-hold (promise resource)
  "Record that `PROMISE` has acquired `RESOURCE`."
  (when loom-enable-promise-registry
    (loom:with-mutex! loom--promise-registry-lock
      (when-let ((meta (gethash promise loom--promise-registry)))
        (cl-pushnew resource (loom-promise-meta-resources-held meta))))))

(defun loom-registry-release-resource-hold (promise resource)
  "Record that `PROMISE` has released `RESOURCE`."
  (when loom-enable-promise-registry
    (loom:with-mutex! loom--promise-registry-lock
      (when-let ((meta (gethash promise loom--promise-registry)))
        (setf (loom-promise-meta-resources-held meta)
              (cl-delete resource
                         (loom-promise-meta-resources-held meta)))))))

(defun loom-registry-has-downstream-handlers-p (promise)
  "Return non-nil if `PROMISE` has any downstream handlers registered."
  (when-let ((meta (gethash promise loom--promise-registry)))
    (loom-promise-meta-children-promises meta)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Introspection

;;;###autoload
(defun loom-registry-get-promise-by-id (promise-id)
  "Return the promise object associated with `PROMISE-ID`.
Time complexity: O(1). This operation is thread-safe.

Arguments:
- `PROMISE-ID` (symbol): The unique `gensym` ID of the promise.

Returns:
- (loom-promise or nil): The promise object, or `nil` if not found."
  (when (and loom-enable-promise-registry promise-id)
    (loom:with-mutex! loom--promise-registry-lock
      (gethash promise-id loom--promise-id-to-promise-map))))

;;;###autoload
(cl-defun loom:list-promises (&key status name tags)
  "Return a list of promises from the registry, with optional filters.

Arguments:
- `:STATUS` (symbol, optional): Filter by status: `:pending`, `:resolved`,
  or `:rejected`.
- `:NAME` (string, optional): Filter by a substring match in the name.
- `:TAGS` (list or symbol, optional): Filter by a tag or list of tags. The
  promise must have at least one of the specified tags.

Returns:
- (list): A list of `loom-promise` objects matching the filters, or nil
  if the registry is disabled."
  (when loom-enable-promise-registry
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
                                     (if (listp tags) tags (list tags))))))
             (push promise matching)))
         loom--promise-registry))
      (nreverse matching))))

;;;###autoload
(defun loom:find-promise (id-or-name)
  "Find a promise in the registry by its ID (symbol) or name (string).

Arguments:
- `ID-OR-NAME` (symbol or string): The promise's `gensym` ID or registered name.

Returns:
- (loom-promise or nil): The matching promise, or `nil`."
  (when loom-enable-promise-registry
    (if (symbolp id-or-name)
        (loom-registry-get-promise-by-id id-or-name)
      (loom:with-mutex! loom--promise-registry-lock
        (cl-block find-by-name
          (maphash (lambda (promise meta)
                     (when (string= id-or-name (loom-promise-meta-name meta))
                       (cl-return-from find-by-name promise)))
                   loom--promise-registry))))))

;;;###autoload
(defun loom:clear-registry ()
  "Clear all promises from the global registry.
This is primarily for testing or debugging. Use with caution.

Returns:
- `nil`."
  (interactive)
  (when loom-enable-promise-registry
    (loom:with-mutex! loom--promise-registry-lock
      (clrhash loom--promise-registry)
      (clrhash loom--promise-id-to-promise-map)
      ;; Re-initialize the priority queue
      (setq loom--promise-age-pq
            (loom:priority-queue
             :comparator
             (lambda (p1 p2)
               (< (or (loom-promise-created-at p1) 0.0)
                  (or (loom-promise-created-at p2) 0.0))))))
    (loom-log :warn nil "Concur promise registry cleared.")))

;;;###autoload
(defun loom:registry-status ()
  "Return a snapshot of the global promise registry's current status.

Returns:
- (plist): A property list with registry metrics, including the number of
  total, pending, resolved, and rejected promises currently tracked."
  (interactive)
  (unless loom-enable-promise-registry (error "Promise registry is disabled"))
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
      `(:enabled-p ,loom-enable-promise-registry
        :total-promises ,total
        :pending-count ,pending
        :resolved-count ,resolved
        :rejected-count ,rejected))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Emacs Exit Hook

(add-hook 'kill-emacs-hook
          (lambda ()
            (when (and loom-enable-promise-registry
                       loom-registry-shutdown-on-exit-p)
              (loom:with-mutex! loom--promise-registry-lock
                (cl-loop for p being the hash-keys of loom--promise-registry
                         when (loom:pending-p p) do
                         (loom:reject p
                          (loom:make-error
                           :type :loom-registry-shutdown-error
                           :message "Emacs is shutting down.")))))))

(provide 'loom-registry)
;;; loom-registry.el ends here