;;; loom-stream.el --- Asynchronous Data Streams -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides an asynchronous data stream primitive, `loom-stream`.
;; It acts as a non-blocking, promise-based, thread-safe queue designed to
;; facilitate communication between different operations (producers and
;; consumers).
;;
;; Key features include:
;; - Backpressure: Writers can be blocked (by returning a promise) when a
;;   stream's buffer is full, ensuring memory safety and preventing fast
;;   producers from overwhelming slow consumers.
;; - Asynchronous, Cancellable Reads: Readers can `await` data without
;;   blocking, and these pending read operations can be cancelled.
;; - Thread-Safety: All internal state is protected by a `loom-lock`.
;; - Rich Combinators: A suite of functions like `map`, `filter`, `take`, and
;;   `drop` allow for declarative, memory-efficient data processing pipelines.

;;; Code:

(require 'cl-lib)
(require 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors Definitions

(define-error 'loom-stream-error
  "A generic error related to a `loom-stream`."
  'loom-error)

(define-error 'loom-invalid-stream-error
  "An operation was attempted on an invalid stream object."
  'loom-stream-error)

(define-error 'loom-stream-closed-error
  "Attempted to operate on a closed stream." 'loom-stream-error)

(define-error 'loom-stream-errored-error
  "Stream has been put into an error state." 'loom-stream-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-stream (:constructor %%make-stream) (:copier nil))
  "Represents an asynchronous, buffered data stream.

Fields:
- `name` (string): A unique or descriptive name for the stream.
- `buffer` (loom-queue): An internal FIFO queue of data chunks that have
  been written but not yet read.
- `max-buffer-size` (integer): The maximum number of chunks the buffer can
  hold before applying backpressure to writers. 0 means unbounded.
- `waiters` (loom-queue): A queue of promises for pending read operations
  that are waiting for data to be written.
- `writers-waiting` (loom-queue): A queue of promises for pending write
  operations that are blocked due to a full buffer (backpressure).
- `lock` (loom-lock): A mutex protecting all of the stream's internal state.
- `closed-p` (boolean): `t` if the stream has been closed (EOF), meaning
  no more data can be written.
- `error` (loom-error): The error object if the stream has been put into
  an error state."
  (name nil :type string)
  (buffer nil :type loom-queue)
  (max-buffer-size 0 :type integer)
  (waiters nil :type loom-queue)
  (writers-waiting nil :type loom-queue)
  (lock nil :type loom-lock)
  (closed-p nil :type boolean)
  (error nil :type (or null loom-error)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-stream (stream function-name)
  "Signal an error if `STREAM` is not a `loom-stream` object.

Arguments:
- `STREAM`: The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for the error message.

Signals:
- `loom-invalid-stream-error` if STREAM is not a valid stream."
  (unless (loom-stream-p stream)
    (signal 'loom-invalid-stream-error
            (list (format "%s: Invalid stream object" function-name) stream))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Construction & Core Operations

;;;###autoload
(cl-defun loom:stream (&key (name (format "stream-%S" (gensym)))
                            (max-buffer-size 0) (mode :thread))
  "Create and return a new empty `loom-stream`.

Arguments:
- `:NAME` (string, optional): A descriptive name for debugging.
- `:MAX-BUFFER-SIZE` (integer, optional): Maximum chunks the buffer can
  hold before applying backpressure. If 0 (the default), the buffer is
  unbounded.
- `:MODE` (symbol, optional): Concurrency mode for the internal lock.
  Defaults to `:thread` for robust safety.

Returns:
- (loom-stream): A new stream object.

Signals:
- `error` if `MAX-BUFFER-SIZE` is negative."
  (unless (>= max-buffer-size 0)
    (error "MAX-BUFFER-SIZE must be non-negative: %S" max-buffer-size))
  (loom-log-debug name "Stream created. Max buffer size: %d" max-buffer-size)
  (%%make-stream
   :name name
   :buffer (loom:queue)
   :max-buffer-size max-buffer-size
   :waiters (loom:queue)
   :writers-waiting (loom:queue)
   :lock (loom:lock (format "stream-lock-%s" name) :mode mode)))

;;;###autoload
(cl-defun loom:stream-write (stream chunk &key cancel-token)
  "Write a `CHUNK` of data to the `STREAM`.
If the stream's buffer is full, this operation applies backpressure by
returning a pending promise that resolves when space becomes available.

Arguments:
- `STREAM` (loom-stream): The stream to write to.
- `CHUNK` (any): The data chunk to write.
- `:CANCEL-TOKEN` (loom-cancel-token, optional): A token to cancel a
  write operation that is blocked by backpressure.

Returns:
- (loom-promise): A promise that resolves to `t` when the write completes.

Signals:
- Rejects with `loom-stream-closed-error` or
  `loom-stream-errored-error` if writing to a terminated stream."
  (loom--validate-stream stream 'loom:stream-write)
  (let ((stream-name (loom-stream-name stream))
        read-waiter-promise write-promise)
    (loom-log-trace stream-name "Attempting to write chunk.")
    (loom:with-mutex! (loom-stream-lock stream)
      (cond
       ;; If stream has an error, reject immediately.
       ((loom-stream-error stream)
        (loom-log-warn stream-name "Write failed: stream is in an error state.")
        (setq write-promise (loom:rejected! (loom-stream-error stream))))
       ;; If stream is closed, reject immediately.
       ((loom-stream-closed-p stream)
        (loom-log-warn stream-name "Write failed: stream is closed.")
        (setq write-promise (loom:rejected!
                             (loom:make-error
                              :type :loom-stream-closed-error
                              :message "Cannot write to a closed stream."))))
       ;; If a reader is waiting, hand the chunk off directly.
       ((setq read-waiter-promise
              (loom:queue-dequeue (loom-stream-waiters stream)))
        (loom-log-trace stream-name "Directly handing off chunk to a waiting reader.")
        (setq write-promise (loom:resolved! t))) ; Write is instantly successful
       ;; If buffer is full, create a pending promise (backpressure).
       ((and (> (loom-stream-max-buffer-size stream) 0)
             (>= (loom:queue-length (loom-stream-buffer stream))
                 (loom-stream-max-buffer-size stream)))
        (loom-log-debug stream-name "Buffer full. Applying backpressure to writer.")
        (setq write-promise (loom:promise
                             :cancel-token cancel-token
                             :name "stream-write-blocked"))
        (loom:queue-enqueue (loom-stream-writers-waiting stream)
                            (cons chunk write-promise)))
       ;; Otherwise, the buffer has space. Add the chunk to the buffer.
       (t
        (loom-log-trace stream-name "Enqueuing chunk to buffer.")
        (loom:queue-enqueue (loom-stream-buffer stream) chunk)
        (setq write-promise (loom:resolved! t)))))
    ;; Outside the lock, resolve promises to prevent deadlocks.
    (when read-waiter-promise (loom:resolve read-waiter-promise chunk))
    write-promise))

;;;###autoload
(cl-defun loom:stream-read (stream &key cancel-token)
  "Read the next chunk of data from `STREAM`.
If the stream's buffer is empty, this returns a pending promise that
resolves when data is written or the stream is closed/errored.

Arguments:
- `STREAM` (loom-stream): The stream to read from.
- `:CANCEL-TOKEN` (loom-cancel-token, optional): A token to cancel a
  read operation that is waiting for data.

Returns:
- (loom-promise): A promise that resolves with the next data chunk.
  - Resolves to the keyword `:eof` if the stream is closed and empty.
  - Rejects if the stream is in an error state or the read is cancelled."
  (loom--validate-stream stream 'loom:stream-read)
  (let ((read-promise (loom:promise
                       :cancel-token cancel-token :name "stream-read"))
        (stream-name (loom-stream-name stream))
        writer-to-resolve)
    (loom-log-trace stream-name "Attempting to read chunk.")
    ;; Add a cancellation callback that removes the waiter from the queue.
    (when cancel-token
      (loom:cancel-token-add-callback
       cancel-token
       (lambda (_)
         (loom-log-debug stream-name "Read operation cancelled.")
         (loom:with-mutex! (loom-stream-lock stream)
           (loom:queue-remove (loom-stream-waiters stream) read-promise)))))
    (loom:with-mutex! (loom-stream-lock stream)
      (cond
       ;; If stream is already errored, immediately reject.
       ((loom-stream-error stream)
        (loom-log-warn stream-name "Read failed: stream is in an error state.")
        (loom:reject read-promise (loom-stream-error stream)))
       ;; If data is in the buffer, resolve with it.
       ((not (loom:queue-empty-p (loom-stream-buffer stream)))
        (loom-log-trace stream-name "Reading chunk from buffer.")
        (loom:resolve read-promise (loom:queue-dequeue
                                    (loom-stream-buffer stream)))
        ;; Reading freed a spot, so relieve backpressure by waking a writer.
        (setq writer-to-resolve
              (loom:queue-dequeue (loom-stream-writers-waiting stream))))
       ;; If closed and empty, signal end-of-file.
       ((loom-stream-closed-p stream)
        (loom-log-debug stream-name "Read returning :eof; stream is closed and empty.")
        (loom:resolve read-promise :eof))
       ;; Otherwise, queue the read promise to wait for data.
       (t
        (loom-log-trace stream-name "Buffer empty. Waiting for data.")
        (loom:queue-enqueue (loom-stream-waiters stream) read-promise))))
    ;; Outside the lock, resolve the waiting writer's promise.
    ;; We must re-enqueue the chunk they wanted to write first.
    (when-let ((writer-payload (car-safe writer-to-resolve))
               (writer-promise (cdr writer-to-resolve)))
      (loom-log-trace stream-name "Relieving backpressure for one writer.")
      (loom:queue-enqueue (loom-stream-buffer stream) writer-payload)
      (loom:resolve writer-promise t))
    read-promise))

;;;###autoload
(defun loom:stream-close (stream)
  "Close `STREAM`, signaling an end-of-file (EOF) condition.
Any pending reads will resolve with `:eof`. Any blocked writes will be
rejected. Subsequent writes will fail. This operation is idempotent.

Arguments:
- `STREAM` (loom-stream): The stream to close.

Returns:
- `nil`."
  (loom--validate-stream stream 'loom:stream-close)
  (let ((stream-name (loom-stream-name stream))
        waiters-to-resolve writers-to-reject)
    (loom:with-mutex! (loom-stream-lock stream)
      (unless (or (loom-stream-closed-p stream)
                  (loom-stream-error stream))
        (loom-log-info stream-name "Closing stream.")
        (setf (loom-stream-closed-p stream) t)
        ;; Collect all pending readers and writers to notify them.
        (setq waiters-to-resolve
              (loom:queue-drain (loom-stream-waiters stream)))
        (setq writers-to-reject
              (mapcar #'cdr (loom:queue-drain
                             (loom-stream-writers-waiting stream))))
        (when (or waiters-to-resolve writers-to-reject)
          (loom-log-debug stream-name
                          "Notifying %d readers of EOF and rejecting %d writers."
                          (length waiters-to-resolve)
                          (length writers-to-reject))))))
    ;; Resolve/reject promises outside the lock.
    (dolist (p waiters-to-resolve) (loom:resolve p :eof))
    (let ((err (loom:make-error :type :loom-stream-closed-error
                                :message "Stream closed during write.")))
      (dolist (p writers-to-reject) (loom:reject p err))))
  nil)

;;;###autoload
(defun loom:stream-error (stream error-obj)
  "Put `STREAM` into an error state, propagating `ERROR-OBJ`.
Any pending or subsequent operations will be rejected with `ERROR-OBJ`.
This operation is idempotent.

Arguments:
- `STREAM` (loom-stream): The stream to put into an error state.
- `ERROR-OBJ` (loom-error): The error object to propagate.

Returns:
- `nil`."
  (loom--validate-stream stream 'loom:stream-error)
  (unless (loom-error-p error-obj)
    (error "ERROR-OBJ must be a loom-error struct"))
  (let ((stream-name (loom-stream-name stream))
        waiters-to-reject writers-to-reject)
    (loom:with-mutex! (loom-stream-lock stream)
      (unless (or (loom-stream-closed-p stream)
                  (loom-stream-error stream))
        (loom-log-error stream-name "Putting stream into error state: %S"
                        error-obj)
        (setf (loom-stream-error stream) error-obj)
        ;; Collect all pending readers and writers to reject them.
        (setq waiters-to-reject
              (loom:queue-drain (loom-stream-waiters stream)))
        (setq writers-to-reject
              (mapcar #'cdr (loom:queue-drain
                             (loom-stream-writers-waiting stream))))
        (when (or waiters-to-reject writers-to-reject)
          (loom-log-debug stream-name
                          "Rejecting %d pending readers and %d blocked writers."
                          (length waiters-to-reject)
                          (length writers-to-reject))))))
    ;; Reject all pending promises outside the lock.
    (dolist (p (append waiters-to-reject writers-to-reject))
      (loom:reject p error-obj)))
  nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Stream Constructors & Processors

;;;###autoload
(defun loom:stream-from-list (list)
  "Create a new stream and write all items from `LIST` to it.
The returned stream will be closed after all items are written. This is a
convenient way to adapt a static list into a stream for processing.

Arguments:
- `LIST` (list): A list of items to write to the new stream.

Returns:
- (loom-stream): A new stream containing the items from the list."
  (let* ((name "stream-from-list")
         (stream (loom:stream :name name)))
    (loom-log-debug name "Creating stream from list with %d items." (length list))
    (dolist (item list) (loom:stream-write stream item))
    (loom:stream-close stream)
    stream))

;;;###autoload
(cl-defun loom:stream-for-each (stream callback &key cancel-token)
  "Apply `CALLBACK` to each chunk of data from `STREAM` as it arrives.
The processing is sequential: the next chunk is only read after the
promise (if any) returned by the callback for the current chunk resolves.

Arguments:
- `STREAM` (loom-stream): The stream to process.
- `CALLBACK` (function): A function `(lambda (chunk))` called for each item.
  It may return a promise to signal that the next item should not be
  processed until the promise resolves.
- `:CANCEL-TOKEN` (loom-cancel-token, optional): A token to cancel the
  processing loop prematurely.

Returns:
- (loom-promise): A promise that resolves to `t` when the entire stream
  has been processed, or rejects on error or cancellation."
  (loom--validate-stream stream 'loom:stream-for-each)
  (unless (functionp callback) (error "CALLBACK must be a function"))
  (let ((stream-name (loom-stream-name stream)))
    (loom-log-debug stream-name "Starting for-each loop.")
    (cl-labels
        ((read-loop ()
           (if (and cancel-token (loom:cancel-token-cancelled-p cancel-token))
               (loom:rejected! (loom:make-error :type :loom-cancel-error))
             (loom:then
              (loom:stream-read stream :cancel-token cancel-token)
              (lambda (chunk)
                (if (eq chunk :eof)
                    (progn (loom-log-debug stream-name "for-each: finished.") t)
                  (progn
                    (loom-log-trace stream-name "for-each: processing chunk.")
                    (loom:then (funcall callback chunk) #'read-loop))))
              (lambda (err) (loom:rejected! err))))))
      (read-loop))))

;;;###autoload
(defun loom:stream-drain (stream)
  "Read all data from `STREAM` until closed, returning a list of all chunks.
This function collects all stream data into memory and is therefore
unsuitable for very large or infinite streams.

Arguments:
- `STREAM` (loom-stream): The stream to drain.

Returns:
- (loom-promise): A promise that resolves to a list of all chunks."
  (loom--validate-stream stream 'loom:stream-drain)
  (let ((stream-name (loom-stream-name stream)))
    (loom-log-debug stream-name "Draining stream.")
    (cl-labels
        ((drain-loop (acc)
           (loom:then
            (loom:stream-read stream)
            (lambda (chunk)
              (if (eq chunk :eof)
                  (progn
                    (loom-log-debug stream-name "Drain complete. Collected %d items."
                                    (length acc))
                    (nreverse acc))
                (drain-loop (cons chunk acc)))))))
      (drain-loop '()))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Stream Combinators

(defun loom--stream-combinator-helper (source-stream processor-fn)
  "Internal helper to create a derived stream from a source stream.
This function abstracts the common pattern for stream combinators:
1. Create a new destination stream.
2. Use `stream-for-each` to process items from the source.
3. The `processor-fn` decides what to write to the destination.
4. The destination stream's lifecycle (closing, erroring) is linked to
   the source stream's lifecycle.

Arguments:
- `SOURCE-STREAM` (loom-stream): The original stream.
- `PROCESSOR-FN` (function): A function `(lambda (chunk dest-stream))`
  that processes a chunk and writes to the destination stream.

Returns:
- A new, derived `loom-stream`."
  (let* ((source-name (loom-stream-name source-stream))
         (dest-stream (loom:stream
                       :name (format "derived-%s" source-name))))
    (loom-log-debug source-name "Creating derived stream '%s'."
                    (loom-stream-name dest-stream))
    ;; Link the destination stream's lifecycle to the source stream's.
    (let ((processing-promise
           (loom:stream-for-each
            source-stream
            (lambda (chunk) (funcall processor-fn chunk dest-stream)))))
      ;; When `for-each` completes successfully (EOF), close the new stream.
      ;; If `for-each` fails, put the new stream into an error state.
      (loom:then processing-promise
                 (lambda (_) (loom:stream-close dest-stream))
                 (lambda (err) (loom:stream-error dest-stream err))))
    dest-stream))

;;;###autoload
(defun loom:stream-map (source-stream map-fn)
  "Create a new stream by applying an async `MAP-FN` to each item.

Arguments:
- `SOURCE-STREAM` (loom-stream): The stream to read from.
- `MAP-FN` (function): An async function `(lambda (chunk))` whose result
  (or promise for a result) is written to the new stream.

Returns:
- (loom-stream): A new stream containing the mapped items."
  (loom--validate-stream source-stream 'loom:stream-map)
  (loom--stream-combinator-helper
   source-stream
   (lambda (chunk dest-stream)
     (loom:then (funcall map-fn chunk)
                (lambda (mapped-chunk)
                  (loom:stream-write dest-stream mapped-chunk))))))

;;;###autoload
(defun loom:stream-filter (source-stream predicate-fn)
  "Create a new stream with only items that satisfy `PREDICATE-FN`.

Arguments:
- `SOURCE-STREAM` (loom-stream): The stream to read from.
- `PREDICATE-FN` (function): An async function `(lambda (chunk))` that
  returns a promise resolving to a boolean.

Returns:
- (loom-stream): A new stream containing only the filtered items."
  (loom--validate-stream source-stream 'loom:stream-filter)
  (loom--stream-combinator-helper
   source-stream
   (lambda (chunk dest-stream)
     (loom:then (funcall predicate-fn chunk)
                (lambda (should-keep)
                  (when should-keep
                   (loom:stream-write dest-stream chunk)))))))

;;;###autoload
(defun loom:stream-take (source-stream n)
  "Create a new stream that emits only the first `N` items from source.
The new stream closes after `N` items are emitted. The processing loop on the
source stream is cancelled to avoid unnecessary work.

Arguments:
- `SOURCE-STREAM` (loom-stream): The stream to read from.
- `N` (integer): The non-negative number of items to take.

Returns:
- (loom-stream): A new stream containing at most `N` items."
  (loom--validate-stream source-stream 'loom:stream-take)
  (unless (and (integerp n) (>= n 0)) (error "N must be a non-negative integer"))
  (if (zerop n)
      (let ((s (loom:stream))) (loom:stream-close s) s)
    (let* ((dest (loom:stream))
           (counter 0)
           (cancel-token (loom:cancel-token)))
      (loom-log-debug (loom-stream-name source-stream)
                      "Creating 'take' stream for %d items." n)
      (let ((processing-promise
             (loom:stream-for-each
              source-stream
              (lambda (chunk)
                (cl-incf counter)
                (let ((write-promise (loom:stream-write dest chunk)))
                  (loom:finally write-promise
                                (lambda ()
                                  ;; After writing N items, signal cancellation.
                                  (when (>= counter n)
                                    (loom-log-debug (loom-stream-name dest)
                                                    "Take limit reached. Cancelling source.")
                                    (loom:cancel-token-signal cancel-token))))))
              :cancel-token cancel-token)))
        ;; Always close the destination stream when the loop finishes,
        ;; whether by completion, error, or cancellation.
        (loom:finally processing-promise
                      (lambda () (loom:stream-close dest))))
      dest)))

;;;###autoload
(defun loom:stream-drop (source-stream n)
  "Create a new stream that skips the first `N` items from source.
All items after the first `N` are passed through to the new stream.

Arguments:
- `SOURCE-STREAM` (loom-stream): The stream to read from.
- `N` (integer): The non-negative number of items to drop.

Returns:
- (loom-stream): A new stream containing all but the first `N` items."
  (loom--validate-stream source-stream 'loom:stream-drop)
  (unless (and (integerp n) (>= n 0)) (error "N must be a non-negative integer"))
  (let ((dest (loom:stream)) (counter 0))
    (loom-log-debug (loom-stream-name source-stream)
                    "Creating 'drop' stream, skipping %d items." n)
    (let ((processing-promise
           (loom:stream-for-each
            source-stream
            (lambda (chunk)
              (cl-incf counter)
              (when (> counter n)
                (loom:stream-write dest chunk))))))
      (loom:then processing-promise
                 (lambda (_) (loom:stream-close dest))
                 (lambda (err) (loom:stream-error dest err))))
    dest))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Introspection

;;;###autoload
(defun loom:stream-is-closed-p (stream)
  "Return `t` if `STREAM` has been closed.

Arguments:
- `STREAM` (loom-stream): The stream to check.

Returns:
- (boolean): `t` if the stream is closed, `nil` otherwise."
  (loom--validate-stream stream 'loom:stream-is-closed-p)
  (loom-stream-closed-p stream))

;;;###autoload
(defun loom:stream-is-errored-p (stream)
  "Return `t` if `STREAM` is in an error state.

Arguments:
- `STREAM` (loom-stream): The stream to check.

Returns:
- (boolean): `t` if the stream is in an error state, `nil` otherwise."
  (loom--validate-stream stream 'loom:stream-is-errored-p)
  (not (null (loom-stream-error stream))))

;;;###autoload
(defun loom:stream-status (stream)
  "Return a snapshot of the `STREAM`'s current status.

Arguments:
- `STREAM` (loom-stream): The stream to inspect.

Returns:
- (plist): A property list with stream metrics, including buffer length,
  number of pending readers/writers, and closed/errored status."
  (loom--validate-stream stream 'loom:stream-status)
  (loom:with-mutex! (loom-stream-lock stream)
    `(:name ,(loom-stream-name stream)
      :buffer-length ,(loom:queue-length (loom-stream-buffer stream))
      :max-buffer-size ,(loom-stream-max-buffer-size stream)
      :pending-reads ,(loom:queue-length (loom-stream-waiters stream))
      :blocked-writes ,(loom:queue-length
                        (loom-stream-writers-waiting stream))
      :closed-p ,(loom-stream-closed-p stream)
      :errored-p ,(loom:stream-is-errored-p stream)
      :error-object ,(loom-stream-error stream))))

(provide 'loom-stream)
;;; loom-stream.el ends here
