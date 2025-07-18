;;; loom-queue.el --- Thread-Safe FIFO Queue for Concur -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This module provides a generic, thread-safe First-In, First-Out (FIFO)
;; queue implementation based on a singly linked list. It offers efficient
;; (amortized O(1)) enqueueing, dequeueing, and length tracking, making it
;; suitable for use in asynchronous and concurrent contexts.
;;
;; This queue is designed to be a fundamental, reusable data structure
;; within the Concur library. All operations are atomic and safe to call
;; from multiple threads.

;;; Code:

(require 'cl-lib)

(require 'loom-errors)
(require 'loom-lock)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-queue-error
  "A generic error related to a `loom-queue`."
  'loom-error)

(define-error 'loom-invalid-queue-error
  "An operation was attempted on an invalid queue object."
  'loom-queue-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-queue-node (:constructor %%make-queue-node))
  "Represents a single node in the queue's internal linked list.

Fields:
- `data` (any): The value stored in this node.
- `next` (loom-queue-node or nil): A pointer to the next node in the
  queue, or `nil` if this is the last node."
  data
  (next nil :type (or null loom-queue-node))) 

(cl-defstruct (loom-queue (:constructor %%make-queue))
  "A thread-safe FIFO queue using explicit head and tail pointers.

Fields:
- `head` (loom-queue-node): The first node in the queue, from which
  items are dequeued.
- `tail` (loom-queue-node): The last node in the queue, to which new
  items are enqueued.
- `lock` (loom-lock): A mutex that protects all queue operations,
  ensuring thread-safety.
- `count` (integer): The number of items currently in the queue, allowing
  for O(1) length checks."
  (head nil :type (or null loom-queue-node)) 
  (tail nil :type (or null loom-queue-node)) 
  (lock (loom:lock) :type loom-lock)
  (count 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-queue (queue function-name)
  "Signal an error if `QUEUE` is not a `loom-queue` object.

Arguments:
- `QUEUE` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting."
  (unless (loom-queue-p queue)
    (signal 'loom-invalid-queue-error
            (list (format "%s: Invalid queue object" function-name) queue))))

(defun loom--queue-dequeue-internal (queue)
  "Non-locking version of `dequeue` for internal use.
This must be called from within a context that already holds the lock."
  (when-let ((head-node (loom-queue-head queue)))
    (let ((item (loom-queue-node-data head-node)))
      (setf (loom-queue-head queue) (loom-queue-node-next head-node))
      ;; If the queue is now empty, the tail must also be nilled.
      (when (zerop (cl-decf (loom-queue-count queue)))
        (setf (loom-queue-tail queue) nil))
      item)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom:queue ()
  "Create a new, empty, thread-safe queue.

Returns:
- (loom-queue): A new `loom-queue` instance."
  (let* ((name (format "queue-lock-%S" (gensym)))
         (queue (%%make-queue :lock (loom:lock name))))
    queue))

;;;###autoload
(defun loom:queue-enqueue (queue item)
  "Add `ITEM` to the end of the `QUEUE`.
Time complexity: O(1). This operation is thread-safe.

Arguments:
- `QUEUE` (loom-queue): The queue instance.
- `ITEM` (any): The item to add.

Returns:
- The enqueued `ITEM`."
  (loom--validate-queue queue 'loom:queue-enqueue)
  (loom:with-mutex! (loom-queue-lock queue)
    (let ((new-node (%%make-queue-node :data item)))
      (if (zerop (loom-queue-count queue))
          (setf (loom-queue-head queue) new-node
                (loom-queue-tail queue) new-node)
        (setf (loom-queue-node-next (loom-queue-tail queue)) new-node
              (loom-queue-tail queue) new-node)))
    (cl-incf (loom-queue-count queue)))
  item)

;;;###autoload
(defun loom:queue-enqueue-front (queue item)
  "Add `ITEM` to the front of the `QUEUE`.
This is useful for adding high-priority items to a FIFO queue.
Time complexity: O(1). This operation is thread-safe.

Arguments:
- `QUEUE` (loom-queue): The queue instance.
- `ITEM` (any): The item to add to the front.

Returns:
- The enqueued `ITEM`."
  (loom--validate-queue queue 'loom:queue-enqueue-front)
  (loom:with-mutex! (loom-queue-lock queue)
    (let ((new-node (%%make-queue-node :data item)))
      (if (zerop (loom-queue-count queue))
          (setf (loom-queue-head queue) new-node
                (loom-queue-tail queue) new-node)
        (setf (loom-queue-node-next new-node) (loom-queue-head queue)
              (loom-queue-head queue) new-node))
      (cl-incf (loom-queue-count queue))))
  item)

;;;###autoload
(defun loom:queue-dequeue (queue)
  "Remove and return the first item from `QUEUE`.
Time complexity: O(1). This operation is thread-safe.

Arguments:
- `QUEUE` (loom-queue): The queue instance.

Returns:
- (any or nil): The dequeued item, or `nil` if the queue is empty."
  (loom--validate-queue queue 'loom:queue-dequeue)
  (loom:with-mutex! (loom-queue-lock queue)
    (loom--queue-dequeue-internal queue)))

;;;###autoload
(cl-defun loom:queue-remove (queue item &key (test #'eql))
  "Remove a specific `ITEM` from anywhere in the `QUEUE`.
Time complexity: O(n) due to the linear search. This operation is
thread-safe.

Arguments:
- `QUEUE` (loom-queue): The queue instance.
- `ITEM` (any): The item to remove.
- `:TEST` (function, optional): The equality test. Defaults to `#'eql`.

Returns:
- (boolean): `t` if the item was found and removed, `nil` otherwise."
  (loom--validate-queue queue 'loom:queue-remove)
  (loom:with-mutex! (loom-queue-lock queue)
    (let ((head (loom-queue-head queue))
          (found nil))
      (cond
       ((null head) nil) ; Queue is empty
       ((funcall test item (loom-queue-node-data head))
        (loom--queue-dequeue-internal queue)
        t)
       (t
        (let ((prev head) (curr (loom-queue-node-next head)))
          (while (and curr (not found))
            (if (funcall test item (loom-queue-node-data curr))
                (progn
                  (setf found t)
                  (setf (loom-queue-node-next prev)
                        (loom-queue-node-next curr))
                  ;; If we removed the tail, update the tail pointer.
                  (when (eq curr (loom-queue-tail queue))
                    (setf (loom-queue-tail queue) prev))
                  (cl-decf (loom-queue-count queue)))
              (setq prev curr curr (loom-queue-node-next curr)))))
        found)))))

;;;###autoload
(defun loom:queue-peek (queue)
  "Return the first item from `QUEUE` without removing it.
Time complexity: O(1). This operation is thread-safe.

Arguments:
- `QUEUE` (loom-queue): The queue instance.

Returns:
- (any or nil): The first item, or `nil` if the queue is empty."
  (loom--validate-queue queue 'loom:queue-peek)
  (loom:with-mutex! (loom-queue-lock queue)
    (when-let ((head (loom-queue-head queue)))
      (loom-queue-node-data head))))

;;;###autoload
(defun loom:queue-drain (queue)
  "Remove and return all items from `QUEUE` as a list.
This empties the queue. This operation is thread-safe.

Arguments:
- `QUEUE` (loom-queue): The queue instance.

Returns:
- (list): A list of all items that were in the queue, in order."
  (loom--validate-queue queue 'loom:queue-drain)
  (loom:with-mutex! (loom-queue-lock queue)
    (let (items)
      (while (not (zerop (loom-queue-count queue)))
        (push (loom--queue-dequeue-internal queue) items))
      (nreverse items))))

;;;###autoload
(cl-defun loom:queue-remove-if (queue predicate)
  "Remove all items from `QUEUE` for which `PREDICATE` returns non-nil.
The `PREDICATE` function is called with one argument: the item in the queue.
Time complexity: O(n) due to the linear traversal. This operation is
thread-safe.

Arguments:
- `QUEUE` (loom-queue): The queue instance.
- `PREDICATE` (function): A function that takes one argument (an item)
  and returns non-nil if the item should be removed.

Returns:
- (integer): The number of items removed from the queue."
  (loom--validate-queue queue 'loom:queue-remove-if)
  (loom:with-mutex! (loom-queue-lock queue)
    (let* ((head (loom-queue-head queue))
           (removed-count 0)
           (prev nil)
           (curr head))

      ;; Handle removal from the head of the queue
      (while (and curr (funcall predicate (loom-queue-node-data curr)))
        (setf (loom-queue-head queue) (loom-queue-node-next curr))
        (cl-decf (loom-queue-count queue))
        (cl-incf removed-count)
        (setq curr (loom-queue-head queue)))

      ;; After potentially removing head elements, update tail if queue is now empty
      (when (zerop (loom-queue-count queue))
        (setf (loom-queue-tail queue) nil))

      ;; Now, iterate through the rest of the list
      (setq prev curr) ; 'curr' is now the new head or nil
      (when prev
        (setq curr (loom-queue-node-next prev))
        (while curr
          (if (funcall predicate (loom-queue-node-data curr))
              (progn
                ;; Skip the current node by linking previous to current's next
                (setf (loom-queue-node-next prev) (loom-queue-node-next curr))
                ;; If we removed the tail, update the tail pointer.
                ;; The new tail is 'prev' because 'curr' was removed.
                (when (eq curr (loom-queue-tail queue))
                  (setf (loom-queue-tail queue) prev))
                (cl-decf (loom-queue-count queue))
                (cl-incf removed-count)
                ;; Don't advance 'prev', as the new 'curr' is now its next
                (setq curr (loom-queue-node-next prev)))
            (setq prev curr
                  curr (loom-queue-node-next curr)))))
    removed-count)))
    
;;;###autoload
(defun loom:queue-length (queue)
  "Return the number of items in `QUEUE`.
Time complexity: O(1). This operation is thread-safe.

Arguments:
- `QUEUE` (loom-queue): The queue instance.

Returns:
- (integer): The number of items."
  (loom--validate-queue queue 'loom:queue-length)
  (loom-queue-count queue))

;;;###autoload
(defun loom:queue-empty-p (queue)
  "Return `t` if `QUEUE` is empty.
Time complexity: O(1). This operation is thread-safe.

Arguments:
- `QUEUE` (loom-queue): The queue instance.

Returns:
- (boolean): `t` if the queue is empty, `nil` otherwise."
  (loom--validate-queue queue 'loom:queue-empty-p)
  (zerop (loom-queue-count queue)))

;;;###autoload
(defun loom:queue-status (queue)
  "Return a snapshot of the `QUEUE`'s current status.

Arguments:
- `QUEUE` (loom-queue): The queue to inspect.

Returns:
- (plist): A property list with queue metrics."
  (interactive)
  (loom--validate-queue queue 'loom:queue-status)
  (loom:with-mutex! (loom-queue-lock queue)
    `(:length ,(loom-queue-count queue)
      :is-empty ,(zerop (loom-queue-count queue)))))

(provide 'loom-queue)
;;; loom-queue.el ends here
