;;; loom-priority-queue.el --- Thread-Safe Priority Queue -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides a thread-safe priority queue implementation based on a
;; binary min-heap. It is designed to manage items based on priority levels,
;; ensuring that high-priority items are processed first according to a
;; user-defined comparator.
;;
;; Features:
;; - Efficient priority-based retrieval (O(log n) for insert/pop).
;; - Thread-safe operations via an internal mutex.
;; - Support for removing arbitrary items (O(n) search + O(log n) removal).
;; - Flexible comparator to support min-heaps (default) or max-heaps.

;;; Code:

(require 'cl-lib)

(require 'loom-error)
(require 'loom-lock)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-priority-queue-error
  "A generic error related to a priority queue."
  'loom-error)

(define-error 'loom-invalid-priority-queue-error
  "An operation was attempted on an invalid priority queue object."
  'loom-priority-queue-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-priority-queue (:constructor %%make-priority-queue))
  "A binary heap-based, thread-safe priority queue.

Fields:
- `heap` (vector): A vector that stores the items in binary heap order.
  This array is automatically resized as needed.
- `lock` (loom-lock): A mutex that protects all heap operations, ensuring
  the data structure is safe to use across multiple threads.
- `comparator` (function): A function `(A B)` that returns non-nil if item
  A has higher priority than item B. For a standard min-heap where lower
  numbers are higher priority, this should be `<`. For a max-heap, use `>`.
- `len` (integer): The current number of items stored in the heap."
  (heap (make-vector 32 nil) :type vector)
  (lock (loom:lock) :type loom-lock-p)
  (comparator #'< :type function)
  (len 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-priority-queue (queue function-name)
  "Signal an error if `QUEUE` is not a `loom-priority-queue` object.

Arguments:
- `QUEUE` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting."
  (unless (loom-priority-queue-p queue)
    (signal 'loom-invalid-priority-queue-error
            (list (format "%s: Invalid priority queue object" function-name)
                  queue))))

(defun loom--priority-queue-heapify-up (queue idx)
  "Move the element at `IDX` up the heap to maintain the heap property.
This must be called from within a context that already holds the lock.

Arguments:
- `QUEUE` (loom-priority-queue): The priority queue.
- `IDX` (integer): The index of the element to heapify up."
  (let ((heap (loom-priority-queue-heap queue))
        (comparator (loom-priority-queue-comparator queue)))
    (catch 'done
      (while (> idx 0)
        (let* ((parent-idx (floor (1- idx) 2))
               (current (aref heap idx))
               (parent (aref heap parent-idx)))
          (if (funcall comparator parent current) (throw 'done nil)
            (cl-rotatef (aref heap idx) (aref heap parent-idx))
            (setq idx parent-idx)))))))

(defun loom--priority-queue-heapify-down (queue idx)
  "Move the element at `IDX` down the heap to maintain the heap property.
This must be called from within a context that already holds the lock.

Arguments:
- `QUEUE` (loom-priority-queue): The priority queue.
- `IDX` (integer): The index of the element to heapify down."
  (let ((heap (loom-priority-queue-heap queue))
        (len (loom-priority-queue-len queue))
        (comparator (loom-priority-queue-comparator queue)))
    (catch 'done
      (while t
        (let* ((left (1+ (* 2 idx)))
               (right (1+ left))
               (highest idx))
          (when (and (< left len) (funcall comparator (aref heap left)
                                           (aref heap highest)))
            (setq highest left))
          (when (and (< right len) (funcall comparator (aref heap right)
                                            (aref heap highest)))
            (setq highest right))
          (if (= highest idx) (throw 'done nil)
            (cl-rotatef (aref heap idx) (aref heap highest))
            (setq idx highest)))))))

(defun loom--priority-queue-pop-internal (queue)
  "Non-locking version of `pop` for internal use.
This must be called from within a context that already holds the lock.

Returns: The highest-priority item, or signals an error if empty."
  (if (zerop (loom-priority-queue-len queue))
      (error "Cannot pop from an empty priority queue")
    (let* ((heap (loom-priority-queue-heap queue))
           (top (aref heap 0))
           (new-len (1- (loom-priority-queue-len queue))))
      (aset heap 0 (aref heap new-len))
      (aset heap new-len nil) ; Clear the last element's old position
      (setf (loom-priority-queue-len queue) new-len)
      (when (> new-len 0)
        (loom--priority-queue-heapify-down queue 0))
      top)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:pqueue
    (&key (comparator #'<) (initial-capacity 32))
  "Create and return a new empty, thread-safe `loom-priority-queue`.

Arguments:
- `:COMPARATOR` (function, optional): A function `(A B)` that returns non-nil
  if A has higher priority than B. Defaults to `<` for a min-heap, where
  smaller items have higher priority. Use `>` for a max-heap.
- `:INITIAL-CAPACITY` (integer, optional): The initial size of the internal
  heap vector. Defaults to 32.

Returns:
- (loom-priority-queue): A new priority queue instance."
  (unless (functionp comparator) (error "Comparator must be a function"))
  (unless (and (integerp initial-capacity) (> initial-capacity 0))
    (error "Initial capacity must be a positive integer"))
  (let* ((name (format "pq-lock-%S" (gensym)))
         (queue (%%make-priority-queue
                 :heap (make-vector initial-capacity nil)
                 :comparator comparator
                 :lock (loom:lock name))))
    queue))

;;;###autoload
(defun loom:pqueue-length (queue)
  "Return the number of items in the priority `QUEUE`.
Time complexity: O(1). This operation is thread-safe.

Arguments:
- `QUEUE` (loom-priority-queue): The priority queue to inspect.

Returns:
- (integer): The number of items in the queue."
  (loom--validate-priority-queue queue 'loom:pqueue-length)
  (loom-priority-queue-len queue))

;;;###autoload
(defun loom:pqueue-empty-p (queue)
  "Return non-nil if the priority `QUEUE` is empty.
Time complexity: O(1). This operation is thread-safe.

Arguments:
- `QUEUE` (loom-priority-queue): The priority queue to inspect.

Returns:
- (boolean): `t` if the queue is empty, `nil` otherwise."
  (loom--validate-priority-queue queue 'loom:pqueue-empty-p)
  (zerop (loom-priority-queue-len queue)))

;;;###autoload
(defun loom:pqueue-insert (queue item)
  "Insert `ITEM` into the priority `QUEUE`.
Time complexity: O(log n). This operation is thread-safe. The internal
heap array will automatically resize if capacity is exceeded.

Arguments:
- `QUEUE` (loom-priority-queue): The priority queue to insert into.
- `ITEM` (any): The item to insert.

Returns:
- The `ITEM` that was inserted."
  (loom--validate-priority-queue queue 'loom:pqueue-insert)
  (loom:with-mutex! (loom-priority-queue-lock queue)
    (let* ((len (loom-priority-queue-len queue))
           (capacity (length (loom-priority-queue-heap queue)))
           (heap (loom-priority-queue-heap queue)))
      ;; Resize the heap if full.
      (when (>= len capacity)
        (let* ((new-capacity (if (zerop capacity) 32 (* 2 capacity)))
               (new-heap (make-vector new-capacity nil)))
          (dotimes (i len) (aset new-heap i (aref heap i)))
          (setq heap (setf (loom-priority-queue-heap queue) new-heap))))
      ;; Insert the new item.
      (let ((idx len))
        (aset heap idx item)
        (cl-incf (loom-priority-queue-len queue))
        (loom--priority-queue-heapify-up queue idx))))
  item)

;;;###autoload
(defun loom:pqueue-peek (queue)
  "Return the highest-priority item from `QUEUE` without removing it.
Time complexity: O(1). This operation is thread-safe.

Arguments:
- `QUEUE` (loom-priority-queue): The priority queue to inspect.

Returns:
- (any or nil): The highest-priority item, or `nil` if the queue is empty."
  (loom--validate-priority-queue queue 'loom:pqueue-peek)
  (loom:with-mutex! (loom-priority-queue-lock queue)
    (unless (loom:pqueue-empty-p queue)
      (aref (loom-priority-queue-heap queue) 0))))

;;;###autoload
(defun loom:pqueue-pop (queue)
  "Pop (remove and return) the highest-priority item from `QUEUE`.
Time complexity: O(log n). This operation is thread-safe.

Arguments:
- `QUEUE` (loom-priority-queue): The priority queue to pop from.

Returns:
- (any): The highest-priority item.

Signals:
- `error` if the queue is empty."
  (loom--validate-priority-queue queue 'loom:pqueue-pop)
  (loom:with-mutex! (loom-priority-queue-lock queue)
    (loom--priority-queue-pop-internal queue)))

;;;###autoload
(defun loom:pqueue-pop-n (queue n)
  "Remove and return the `N` highest-priority items from `QUEUE`.
Items are returned in priority order.

Arguments:
- `QUEUE` (loom-priority-queue): The priority queue to pop from.
- `N` (integer): The number of items to pop.

Returns:
- (list): A list of the `N` highest-priority items.

Signals:
- `error` if `N` is not a non-negative integer."
  (loom--validate-priority-queue queue 'loom:pqueue-pop-n)
  (unless (and (integerp n) (>= n 0))
    (error "N must be a non-negative integer"))
  (loom:with-mutex! (loom-priority-queue-lock queue)
    (let ((count (min n (loom:pqueue-length queue))))
      (when (> count 0)
        (cl-loop repeat count
                 collect (loom--priority-queue-pop-internal queue))))))

;;;###autoload
(cl-defun loom:pqueue-remove (queue item &key (test #'eql))
  "Remove `ITEM` from the priority `QUEUE`.
Time complexity: O(n) due to the linear search for the item, plus
O(log n) for removal. This operation is thread-safe.

Arguments:
- `QUEUE` (loom-priority-queue): The priority queue to remove from.
- `ITEM` (any): The item to remove.
- `:TEST` (function, optional): A predicate `(element target-item)` used
  to compare items for equality. Defaults to `eql`.

Returns:
- (boolean): `t` if the item was found and removed, `nil` otherwise."
  (loom--validate-priority-queue queue 'loom:pqueue-remove)
  (loom:with-mutex! (loom-priority-queue-lock queue)
    (let* ((heap (loom-priority-queue-heap queue))
           (len (loom-priority-queue-len queue))
           (idx (cl-position item heap :end len :test test)))
      (when idx
        (let ((last-idx (1- len)))
          ;; Swap the item to be removed with the last item.
          (aset heap idx (aref heap last-idx))
          (aset heap last-idx nil)
          (cl-decf (loom-priority-queue-len queue))
          ;; If the swapped element was not the one we removed, we need to
          ;; restore the heap property from its new position.
          (when (and (> (loom-priority-queue-len queue) 0)
                     (< idx (loom-priority-queue-len queue)))
            (let ((parent-idx (floor (1- idx) 2)))
              ;; The swapped element might need to move up or down.
              ;; Check if it has higher priority than its new parent.
              (if (and (> idx 0)
                       (funcall (loom-priority-queue-comparator queue)
                                (aref heap idx)
                                (aref heap parent-idx))) 
                  (loom--priority-queue-heapify-up queue idx)
                (loom--priority-queue-heapify-down queue idx))))
        t)))))

;;;###autoload
(defun loom:pqueue-clear (queue)
  "Remove all items from the priority `QUEUE`.
Time complexity: O(1). This operation is thread-safe.

Arguments:
- `QUEUE` (loom-priority-queue): The priority queue to clear.

Returns:
- `nil`."
  (loom--validate-priority-queue queue 'loom:pqueue-clear)
  (loom:with-mutex! (loom-priority-queue-lock queue)
    (setf (loom-priority-queue-len queue) 0)
    (setf (loom-priority-queue-heap queue)
          (make-vector (length (loom-priority-queue-heap queue)) nil)))
  nil)

;;;###autoload
(defun loom:pqueue-status (queue)
  "Return a snapshot of the `QUEUE`'s current status.
This function is `interactive` for easy inspection during development.

Arguments:
- `QUEUE` (loom-priority-queue): The priority queue to inspect.

Returns:
- (plist): A property list containing `:length`, `:capacity`, and
  `:is-empty`."
  (interactive)
  (loom--validate-priority-queue queue 'loom:pqueue-status)
  (loom:with-mutex! (loom-priority-queue-lock queue)
    `(:length ,(loom-priority-queue-len queue)
      :capacity ,(length (loom-priority-queue-heap queue))
      :is-empty ,(loom:pqueue-empty-p queue))))

(provide 'loom-priority-queue)
;;; loom-priority-queue.el ends here