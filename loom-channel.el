;;; loom-channel.el --- Inter-Process Communication Channel -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This module introduces `loom-channel`, an advanced communication
;; primitive that supports both in-process and cross-process messaging.
;; It functions as a multi-writer, multi-reader broadcast system, making
;; it ideal for building complex event-driven architectures.
;;
;; ## Core Concepts
;;
;; - **Fan-Out/Broadcast:** A channel allows multiple, independent subscribers
;;   to receive the same stream of messages. Each subscriber gets its own
;;   `loom-stream`, ensuring that one slow consumer does not block others.
;;
;; - **Inter-Process Communication (IPC):** By associating a channel with a
;;   filesystem path (a named pipe), it becomes a public endpoint. Any
;;   Emacs process can then "post" messages to the channel, which will be
;;   distributed to all of its subscribers in the main process.
;;
;; - **Backpressure:** Each subscriber's stream manages its own buffer and
;;   applies backpressure independently, ensuring memory safety.

;;; Code:

(require 'cl-lib)
(require 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Section 1: Errors & Structs

(define-error 'loom-channel-error
  "Generic channel error."
  'loom-error)

(define-error 'loom-invalid-channel-error
  "Invalid channel object."
  'loom-channel-error)

(define-error 'loom-channel-closed-error
  "Attempted to operate on a closed channel."
  'loom-channel-error)

(define-error 'loom-channel-errored-error
  "Channel has been put into an error state."
  'loom-channel-error)

(cl-defstruct (loom-channel (:constructor %%make-channel) (:copier nil))
  "Represents a multi-writer, multi-reader asynchronous communication channel.

Fields:
- `name` (string): A descriptive name for the channel.
- `subscribers` (list): A list of `loom-stream` objects, one for each active
  subscriber. Each subscriber gets its own independent message queue.
- `lock` (loom-lock): A mutex protecting the channel's shared state.
- `closed-p` (boolean): `t` if the channel has been closed.
- `error` (loom-error): The error object if the channel is in an error state.
- `ipc-pipe` (loom-pipe): The underlying reader `loom-pipe` used for IPC,
  or `nil` if the channel is in-process only."
  (name nil :type string)
  (subscribers '() :type list)
  (lock nil :type loom-lock)
  (closed-p nil :type boolean)
  (error nil :type (or null loom-error))
  (ipc-pipe nil :type (or null loom-pipe)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Section 2: Internal Logic

(defun loom--validate-channel (channel function-name)
  "Signal an error if CHANNEL is not a `loom-channel` object.

Arguments:
- `CHANNEL`: The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for the error message.

Returns:
- `nil` if the channel is valid.

Signals:
- `loom-invalid-channel-error` if CHANNEL is not a valid channel."
  (unless (loom-channel-p channel)
    (signal 'loom-invalid-channel-error
            (list (format "%s: Invalid channel object" function-name)
                  channel))))

(defun loom--channel-distribute-message (channel message)
  "Distribute a MESSAGE to all active subscribers of the CHANNEL.
This function is called internally when a message is sent to the channel.
It iterates through all subscribers and writes the message to their
individual `loom-stream` queues.

Arguments:
- `CHANNEL` (loom-channel): The channel to distribute messages from.
- `MESSAGE` (any): The message to distribute.

Returns:
- `nil`.

Side Effects:
- Calls `loom:stream-write` for each subscriber, which may apply
  backpressure."
  (let ((channel-name (loom-channel-name channel)))
    (loom-log-trace channel-name "Distributing message to %d subscribers."
                    (length (loom-channel-subscribers channel)))
    (dolist (subscriber-stream (loom-channel-subscribers channel))
      ;; Each subscriber stream handles its own backpressure.
      (loom:stream-write subscriber-stream message))))

(defun loom--channel-propagate-termination (channel terminator-fn)
  "Propagate a termination signal (close or error) to all subscribers.

Arguments:
- `CHANNEL` (loom-channel): The channel to propagate from.
- `TERMINATOR-FN` (function): The function to apply to each subscriber stream
  (e.g., `loom:stream-close` or `(lambda (s) (loom:stream-error s err))` ).

Returns:
- `nil`.

Side Effects:
- Calls `TERMINATOR-FN` on each subscriber stream.
- Clears the channel's list of subscribers."
  (let ((channel-name (loom-channel-name channel)))
    (loom-log-debug channel-name "Propagating termination to subscribers.")
    (dolist (subscriber-stream (loom-channel-subscribers channel))
      (funcall terminator-fn subscriber-stream))
    ;; Clear subscribers after termination
    (setf (loom-channel-subscribers channel) '())))

(defun loom--channel-ipc-filter-fn (proc string channel)
  "The process filter for a channel's IPC pipe.
This function buffers and parses incoming data from the named pipe,
deserializes complete S-expressions, and distributes them as messages to
the channel's subscribers.

Arguments:
- `PROC` (process): The underlying process for the `loom:pipe`.
- `STRING` (string): The chunk of data received from the pipe.
- `CHANNEL` (loom-channel): The channel that owns the pipe.

Returns:
- `nil`.

Side Effects:
- Modifies a temporary buffer attached to the process.
- Calls `loom--channel-distribute-message` when a full message is parsed."
  (let ((buffer (process-get proc 'filter-buffer)))
    (unless buffer
      (setq buffer (generate-new-buffer
                    (format "*%s-ipc-filter*" (process-name proc))))
      (process-put proc 'filter-buffer buffer))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert string)
      (goto-char (point-min))
      ;; This loop robustly parses complete S-expressions from the
      ;; process output buffer as they arrive.
      (while (ignore-errors
               (let ((end (scan-sexps (point) 1)))
                 (when end
                   (let* ((sexp-str (buffer-substring-no-properties (point) end))
                          (message (read-from-string sexp-str)))
                     (delete-region (point) end)
                     (loom-log-trace (loom-channel-name channel)
                                     "Received IPC message.")
                     (loom:with-mutex! (loom-channel-lock channel)
                       (loom--channel-distribute-message channel message)))
                   t)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Section 3: Public API - Core Operations

;;;###autoload
(cl-defun loom:channel (&key (name (format "channel-%S" (gensym)))
                             (mode :thread) ipc-path)
  "Create and return a new empty `loom-channel`.
If `:IPC-PATH` is provided, the channel will listen on a named pipe at
that path, allowing other processes to send messages to it via
`loom:channel-post`.

Arguments:
- `:NAME` (string, optional): A descriptive name for debugging.
- `:MODE` (symbol, optional): Concurrency mode for the internal lock.
  Defaults to `:thread` for robust safety.
- `:IPC-PATH` (string, optional): A file path for the channel's named pipe.

Returns:
- (loom-channel): A new channel object."
  (loom-log-debug name "Channel created.")
  (let ((channel (%%make-channel
                  :name name
                  :subscribers '()
                  :lock (loom:lock (format "channel-lock-%s" name) :mode mode))))
    (when ipc-path
      (loom-log-info name "Initializing IPC listener at '%s'." ipc-path)
      (setf (loom-channel-ipc-pipe channel)
            (loom:pipe :path ipc-path
                       :mode :read
                       :filter (lambda (proc string)
                                 (loom--channel-ipc-filter-fn
                                  proc string channel)))))
    channel))

;;;###autoload
(cl-defun loom:channel-send (channel message)
  "Send a `MESSAGE` to the `CHANNEL` from within the same process.
The message will be delivered to all currently active subscribers. This
function is for in-process communication only. To send a message from a
different process, use `loom:channel-post`.

Arguments:
- `CHANNEL` (loom-channel): The target channel.
- `MESSAGE` (any): The data message to send.

Returns:
- (loom-promise): A promise that resolves to `t` when the message has been
  successfully enqueued for all subscribers."
  (loom--validate-channel channel 'loom:channel-send)
  (let ((channel-name (loom-channel-name channel))
        send-promise)
    (loom:with-mutex! (loom-channel-lock channel)
      (cond
       ((loom-channel-error channel)
        (loom-log-warn channel-name "Send failed: channel is in an error state.")
        (setq send-promise (loom:rejected! (loom-channel-error channel))))
       ((loom-channel-closed-p channel)
        (loom-log-warn channel-name "Send failed: channel is closed.")
        (setq send-promise (loom:rejected!
                             (loom:make-error
                              :type 'loom-channel-closed-error
                              :message "Cannot send to a closed channel."))))
       (t
        (loom-log-trace channel-name "Sending message.")
        (loom--channel-distribute-message channel message)
        (setq send-promise (loom:resolved! t)))))
    send-promise))

;;;###autoload
(cl-defun loom:channel-post (ipc-path message)
  "Post a `MESSAGE` to a channel from another process.
This function connects to the channel's public named pipe at `IPC-PATH`,
sends the serialized `MESSAGE`, and disconnects.

Arguments:
- `IPC-PATH` (string): The file path of the target channel's named pipe.
- `MESSAGE` (any): The serializable data message to send.

Returns:
- `t` on success.

Signals:
- `loom-pipe-error`: If the connection to the channel's pipe fails."
  (loom-log-trace ipc-path "Posting message to remote channel.")
  (let ((pipe (loom:pipe :path ipc-path :mode :write)))
    (unwind-protect
         (loom:pipe-send pipe (prin1-to-string message))
      (loom:pipe-cleanup pipe))))

;;;###autoload
(cl-defun loom:channel-subscribe (channel &key (name (format "subscriber-%S" (gensym)))
                                          (max-buffer-size 100))
  "Subscribe to a `CHANNEL`, returning a new `loom-stream` for reading.
Each subscriber gets an independent view of messages from the point of
subscription onwards. Messages sent before subscription are not received.

Arguments:
- `CHANNEL` (loom-channel): The channel to subscribe to.
- `:NAME` (string, optional): A descriptive name for the subscriber stream.
- `:MAX-BUFFER-SIZE` (integer, optional): Max items in this subscriber's
  buffer before backpressure is applied to the channel.

Returns:
- (loom-stream): A new stream from which the subscriber can read messages."
  (loom--validate-channel channel 'loom:channel-subscribe)
  (let ((channel-name (loom-channel-name channel))
        new-subscriber-stream)
    (loom:with-mutex! (loom-channel-lock channel)
      (cond
       ((loom-channel-error channel)
        (loom-log-warn channel-name "Cannot subscribe: channel is errored.")
        (signal 'loom-channel-errored-error
                (list "Cannot subscribe to an errored channel."
                      (loom-channel-error channel))))
       ((loom-channel-closed-p channel)
        (loom-log-warn channel-name "Cannot subscribe: channel is closed.")
        (signal 'loom-channel-closed-error
                (list "Cannot subscribe to a closed channel.")))
       (t
        (loom-log-info channel-name "New subscriber '%s' added." name)
        (setq new-subscriber-stream
              (loom:stream :name name :max-buffer-size max-buffer-size))
        (push new-subscriber-stream (loom-channel-subscribers channel)))))
    new-subscriber-stream))

;;;###autoload
(cl-defun loom:channel-unsubscribe (channel subscriber-stream)
  "Unsubscribe a `SUBSCRIBER-STREAM` from a `CHANNEL`.
The subscriber stream will be closed, and it will no longer receive messages.

Arguments:
- `CHANNEL` (loom-channel): The channel to unsubscribe from.
- `SUBSCRIBER-STREAM` (loom-stream): The specific stream to remove.

Returns:
- `t` if the subscriber was found and removed, `nil` otherwise."
  (loom--validate-channel channel 'loom:channel-unsubscribe)
  (loom:stream-close subscriber-stream) ; Close the subscriber's stream first
  (loom:with-mutex! (loom-channel-lock channel)
    (let ((initial-length (length (loom-channel-subscribers channel))))
      (setf (loom-channel-subscribers channel)
            (cl-delete subscriber-stream (loom-channel-subscribers channel)))
      (if (< (length (loom-channel-subscribers channel)) initial-length)
          (progn
            (loom-log-info (loom-channel-name channel)
                           "Subscriber '%s' unsubscribed."
                           (loom-stream-name subscriber-stream))
            t)
        (progn
          (loom-log-warn (loom-channel-name channel)
                         "Attempted to unsubscribe unknown stream '%s'."
                         (loom-stream-name subscriber-stream))
          nil)))))

;;;###autoload
(defun loom:channel-close (channel)
  "Close `CHANNEL`, signaling an end-of-file (EOF) condition.
This also cleans up any associated IPC resources. New subscriptions or
sends will be rejected. This operation is idempotent.

Arguments:
- `CHANNEL` (loom-channel): The channel to close.

Returns:
- `nil`."
  (loom--validate-channel channel 'loom:channel-close)
  (let ((channel-name (loom-channel-name channel)))
    (loom:with-mutex! (loom-channel-lock channel)
      (unless (or (loom-channel-closed-p channel)
                  (loom-channel-error channel))
        (loom-log-info channel-name "Closing channel.")
        (setf (loom-channel-closed-p channel) t)
        (when-let ((pipe (loom-channel-ipc-pipe channel)))
          (loom-log-debug channel-name "Cleaning up IPC pipe.")
          (loom:pipe-cleanup pipe))
        (loom--channel-propagate-termination channel #'loom:stream-close))))
  nil)

;;;###autoload
(defun loom:channel-error (channel error-obj)
  "Put `CHANNEL` into an error state, propagating `ERROR-OBJ`.
Any new subscriptions or send operations will be rejected. This operation
is idempotent and also cleans up IPC resources.

Arguments:
- `CHANNEL` (loom-channel): The channel to put into an error state.
- `ERROR-OBJ` (loom-error): The error object to propagate.

Returns:
- `nil`."
  (loom--validate-channel channel 'loom:channel-error)
  (unless (loom-error-p error-obj)
    (error "ERROR-OBJ must be a loom-error struct"))
  (let ((channel-name (loom-channel-name channel)))
    (loom:with-mutex! (loom-channel-lock channel)
      (unless (or (loom-channel-closed-p channel)
                  (loom-channel-error channel))
        (loom-log-error channel-name "Putting channel into error state: %S"
                        error-obj)
        (setf (loom-channel-error channel) error-obj)
        (when-let ((pipe (loom-channel-ipc-pipe channel)))
          (loom-log-debug channel-name "Cleaning up IPC pipe.")
          (loom:pipe-cleanup pipe))
        (loom--channel-propagate-termination
         channel (lambda (s) (loom:stream-error s error-obj))))))
  nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Section 4: Public API - Introspection

;;;###autoload
(defun loom:channel-open-p (channel)
  "Return `t` if `CHANNEL` is open (not closed or errored).

Arguments:
- `CHANNEL` (loom-channel): The channel to check.

Returns:
- (boolean): `t` if the channel is open, `nil` otherwise."
  (loom--validate-channel channel 'loom:channel-open-p)
  (not (or (loom-channel-closed-p channel) (loom-channel-error channel))))

;;;###autoload
(defun loom:channel-name (channel)
  "Return the `NAME` of the `CHANNEL`.

Arguments:
- `CHANNEL` (loom-channel): The channel to inspect.

Returns:
- (string): The name of the channel."
  (loom--validate-channel channel 'loom:channel-name)
  (loom-channel-name channel))

;;;###autoload
(defun loom:channel-status (channel)
  "Return a snapshot of the `CHANNEL`'s current status.

Arguments:
- `CHANNEL` (loom-channel): The channel to inspect.

Returns:
- (plist): A property list with channel metrics."
  (loom--validate-channel channel 'loom:channel-status)
  (loom:with-mutex! (loom-channel-lock channel)
    `(:name ,(loom-channel-name channel)
      :num-subscribers ,(length (loom-channel-subscribers channel))
      :open-p ,(loom:channel-open-p channel)
      :ipc-pipe-path ,(when-let ((pipe (loom-channel-ipc-pipe channel)))
                        (loom-pipe-path pipe))
      :error-object ,(loom-channel-error channel))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Section 5: Public API - High-Level Combinators

;;;###autoload
(cl-defun loom:channel-fan-in (channels &key (name (format "fan-in-stream-%S" (gensym))))
  "Merge messages from multiple `CHANNELS` into a single `loom-stream`.
Each message received on any of the input channels will be written to the
returned stream. The returned stream will close when all input channels
are closed. If any input channel errors, the returned stream will also error.

Arguments:
- `CHANNELS` (list): A list of `loom-channel` instances.
- `:NAME` (string, optional): A descriptive name for the resulting stream.

Returns:
- (loom-stream): A new stream that combines messages from all inputs."
  (unless (cl-every #'loom-channel-p channels)
    (error "All elements in CHANNELS must be `loom-channel` objects."))
  (let* ((output-stream (loom:stream :name name))
         (num-active-channels (length channels))
         (active-channels-lock (loom:lock (format "%s-lock" name))))

    (loom-log-debug name "Fanning-in %d channels." num-active-channels)

    (when (zerop num-active-channels)
      (loom:stream-close output-stream)
      (return-from loom:channel-fan-in output-stream))

    (dolist (ch channels)
      (let ((subscriber-stream (loom:channel-subscribe ch)))
        (let ((processing-promise
               (loom:stream-for-each
                subscriber-stream
                (lambda (message)
                  (loom-log-trace name "Received message from channel '%s'."
                                  (loom-channel-name ch))
                  (loom:stream-write output-stream message)))))
          (loom:finally
           processing-promise
           (lambda ()
             (loom:with-mutex! active-channels-lock
               (cl-decf num-active-channels)
               (loom-log-debug name "Channel '%s' finished. %d remaining."
                               (loom-channel-name ch) num-active-channels)
               (when (zerop num-active-channels)
                 (loom-log-info name (concat "All fanned-in channels closed. "
                                             "Closing output stream."))
                 (loom:stream-close output-stream)))))
          (loom:catch
           processing-promise
           (lambda (err)
             (loom:with-mutex! active-channels-lock
               (loom-log-error name "Channel '%s' errored: %S. Propagating."
                               (loom-channel-name ch) err)
               (loom:stream-error output-stream err)))))))
    output-stream))

(provide 'loom-channel)
;;; loom-channel.el ends here