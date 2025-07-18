;;; loom-event.el --- Event Synchronization Primitive for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the `loom-event` primitive, a lightweight and
;; flexible tool for coordinating asynchronous tasks. It is similar to event
;; objects found in many other concurrency frameworks.
;;
;; An event is a synchronization flag that can be in one of two states:
;; "set" or "cleared". Tasks can wait for an event to become "set".
;; When a task calls `loom:event-set`, all current and future waiters
;; are woken up and their promises resolve with the value provided.
;;
;; This makes it useful for one-to-many signals, such as broadcasting that
;; "initialization is complete" or "data is now available".
;;
;; Key Features:
;; - **Promise-Based Waiting:** `loom:event-wait` returns a promise,
;;   integrating seamlessly with the rest of the Loom ecosystem.
;; - **Thread-Safety:** All operations on an event are protected by an
;;   internal mutex, making them safe to call from any thread.
;; - **Automatic Cleanup:** All created events are tracked and automatically
;;   cleaned up when Emacs exits.
;; - **Introspection:** Provides functions to check the state and get
;;   detailed statistics about an event's lifecycle.
;;
;; Example Use Case:
;;
;; (let ((init-event (loom:event "initialization")))
;;
;;   ;; Task A waits for initialization
;;   (loom:then (loom:event-wait init-event)
;;                (lambda (config) (message "A: Init done with: %S" config)))
;;
;;   ;; Task B also waits
;;   (loom:then (loom:event-wait init-event)
;;                (lambda (config) (message "B: Init done with: %S" config)))
;;
;;   ;; Another task performs initialization and then sets the event
;;   (loom:then (loom:delay 1) ; Simulate work
;;                (lambda (_) (loom:event-set init-event '(:user "admin")))))

;;; Code:

(require 'cl-lib)

(require 'loom-log)
(require 'loom-errors)
(require 'loom-lock)
(require 'loom-queue)
(require 'loom-promise)
(require 'loom-primitives)
(require 'loom-combinators)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom--all-events '()
  "A list of all active `loom-event` instances.
This list is used by the shutdown hook to ensure all events are
properly cleaned up when Emacs exits.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'loom-event-error
  "A generic error related to a `loom-event`."
  'loom-error)

(define-error 'loom-invalid-event-error
  "An operation was attempted on an invalid event object."
  'loom-event-error)

(define-error 'loom-event-destroyed-error
  "An operation was attempted on a destroyed event object."
  'loom-event-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (loom-event (:constructor %%make-event))
  "Represents a settable event for asynchronous task coordination.

Fields:
- `name` (string): A descriptive name for debugging and logging.
- `lock` (loom-lock): An internal mutex that protects all other fields
  of the struct from race conditions.
- `is-set-p` (boolean): The core state of the event. It is `t` if the
  event is currently in the 'set' state, and `nil` if 'cleared'.
- `value` (any): The value that waiting promises will be resolved with when
  the event is set.
- `wait-queue` (loom-queue): A queue of pending promises created by calls
  to `loom:event-wait` while the event was in a 'cleared' state.
- `destroyed-p` (boolean): Flag indicating whether the event has been destroyed.
- `creation-time` (float): Timestamp when the event was created.
- `set-time` (float): Timestamp when the event was last set, or nil if never set.
- `wait-count` (integer): Total number of waiters that have been queued.
- `resolve-count` (integer): Total number of waiters that have been resolved."
  (name "" :type string)
  (lock nil :type loom-lock)
  (is-set-p nil :type boolean)
  (value t :type t)
  (wait-queue nil :type loom-queue)
  (destroyed-p nil :type boolean)
  (creation-time 0.0 :type float)
  (set-time nil :type (or null float))
  (wait-count 0 :type integer)
  (resolve-count 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-event (event function-name)
  "Signal an error if `EVENT` is not a `loom-event` object.

Arguments:
- `EVENT` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting.

Returns: `nil`.

Signals: `loom-invalid-event-error`."
  (unless (loom-event-p event)
    (signal 'loom-invalid-event-error
            (list (format "%s: Invalid event object" function-name) event))))

(defun loom--validate-event-not-destroyed (event function-name)
  "Signal an error if `EVENT` is destroyed.

Arguments:
- `EVENT` (loom-event): The event to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting.

Returns: `nil`.

Signals: `loom-event-destroyed-error`."
  (when (loom-event-destroyed-p event)
    (signal 'loom-event-destroyed-error
            (list (format "%s: Event has been destroyed" function-name) event))))

(defun loom--event-full-validate (event function-name)
  "Perform full validation of `EVENT`.

Arguments:
- `EVENT` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting.

Returns: `nil`."
  (loom--validate-event event function-name)
  (loom--validate-event-not-destroyed event function-name))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom:event (&optional name)
  "Create a new event object, initially in the 'cleared' state.

Arguments:
- `NAME` (string, optional): A descriptive name for debugging.

Returns:
A new `loom-event` object.

Side Effects:
- Creates a new `loom-event` struct.
- Initializes an internal `loom-lock` and `loom-queue`.
- Adds the new event to a global tracking list for automatic
  cleanup on Emacs shutdown."
  (let* ((event-name (or name (format "event-%S" (gensym))))
         (lock (loom:lock (format "event-lock-%s" event-name)))
         (event (%%make-event :name event-name
                              :lock lock
                              :wait-queue (loom:queue)
                              :creation-time (float-time))))
    (push event loom--all-events)
    (loom-log :debug (loom-event-name event) "Created event.")
    event))

;;;###autoload
(defun loom:event-is-set-p (event)
  "Return non-nil if `EVENT` is currently in the 'set' state.

Arguments:
- `EVENT` (loom-event): The event to check.

Returns:
`t` if the event is set, `nil` otherwise.

Signals:
- `loom-invalid-event-error`: If `EVENT` is not a valid `loom-event` object.
- `loom-event-destroyed-error`: If `EVENT` has been destroyed."
  (loom--event-full-validate event 'loom:event-is-set-p)
  ;; The state is read inside the lock to ensure we get the most up-to-date
  ;; value in a multi-threaded context.
  (loom:with-mutex! (loom-event-lock event)
    (loom-event-is-set-p event)))

;;;###autoload
(defun loom:event-value (event)
  "Return the current value of `EVENT`.
This is the value that waiters will receive when the event is set.

Arguments:
- `EVENT` (loom-event): The event to query.

Returns:
The current value of the event.

Signals:
- `loom-invalid-event-error`: If `EVENT` is not a valid `loom-event` object.
- `loom-event-destroyed-error`: If `EVENT` has been destroyed."
  (loom--event-full-validate event 'loom:event-value)
  (loom:with-mutex! (loom-event-lock event)
    (loom-event-value event)))

;;;###autoload
(defun loom:event-set (event &optional value)
  "Set `EVENT`, waking up all current and future waiters.
This operation is idempotent; setting an already-set event has no effect.
All waiting promises will resolve with `VALUE`.

Arguments:
- `EVENT` (loom-event): The event to set.
- `VALUE` (any, optional): The value to resolve waiters with. Defaults to `t`.

Returns: `nil`.

Side Effects:
- Changes the `is-set-p` field of `EVENT` to `t`.
- Sets the `value` field of `EVENT`.
- Drains all promises from the `wait-queue` of `EVENT`.
- Resolves all promises that were in the `wait-queue` with `VALUE`.

Signals:
- `loom-invalid-event-error`: If `EVENT` is not a valid `loom-event` object.
- `loom-event-destroyed-error`: If `EVENT` has been destroyed."
  (loom--event-full-validate event 'loom:event-set)
  (let (waiters-to-resolve resolve-value waiter-count)
    ;; 1. Update state and retrieve waiters under a lock.
    (loom:with-mutex! (loom-event-lock event)
      (unless (loom-event-is-set-p event)
        (setf (loom-event-is-set-p event) t)
        (setf (loom-event-value event) (or value t))
        (setf (loom-event-set-time event) (float-time))
        (setq waiters-to-resolve (loom:queue-drain
                                  (loom-event-wait-queue event)))
        (setq waiter-count (length waiters-to-resolve))
        (setq resolve-value (loom-event-value event))
        (cl-incf (loom-event-resolve-count event) waiter-count)
        (loom-log :debug (loom-event-name event)
                    "Event set. Waking up %d waiters."
                    waiter-count)))
    ;; 2. Resolve waiters outside the lock to prevent deadlocks if a
    ;;    waiter's callback tries to acquire this or another lock.
    (dolist (promise waiters-to-resolve)
      (loom:resolve promise resolve-value))))

;;;###autoload
(defun loom:event-clear (event)
  "Clear `EVENT`, resetting it to its initial 'cleared' state.
After an event is cleared, subsequent calls to `loom:event-wait` will
once again create pending promises until the event is set again.

Arguments:
- `EVENT` (loom-event): The event to clear.

Returns: `nil`.

Side Effects:
- Changes the `is-set-p` field of `EVENT` to `nil`.
- Resets the `value` field of `EVENT` to `t`.

Signals:
- `loom-invalid-event-error`: If `EVENT` is not a valid `loom-event` object.
- `loom-event-destroyed-error`: If `EVENT` has been destroyed."
  (loom--event-full-validate event 'loom:event-clear)
  (loom:with-mutex! (loom-event-lock event)
    (when (loom-event-is-set-p event)
      (setf (loom-event-is-set-p event) nil)
      (setf (loom-event-value event) t) ; Reset value to default.
      (setf (loom-event-set-time event) nil)
      (loom-log :debug (loom-event-name event) "Event cleared."))))

;;;###autoload
(defun loom:event-toggle (event &optional value)
  "Toggle the state of `EVENT`.
If the event is set, it will be cleared. If it is cleared, it will
be set with the optional `VALUE`.

Arguments:
- `EVENT` (loom-event): The event to toggle.
- `VALUE` (any, optional): The value to use if the event is being set.

Returns: `nil`.

Side Effects:
- Calls either `loom:event-set` or `loom:event-clear`.

Signals:
- `loom-invalid-event-error`, `loom-event-destroyed-error`."
  (loom--event-full-validate event 'loom:event-toggle)
  (if (loom:event-is-set-p event)
      (loom:event-clear event)
    (loom:event-set event value)))

;;;###autoload
(cl-defun loom:event-wait (event &key timeout)
  "Return a promise that resolves when `EVENT` is set.
If the event is already set, the returned promise resolves immediately
with the event's stored value. Otherwise, the promise is queued and will
resolve when `loom:event-set` is eventually called.

Arguments:
- `EVENT` (loom-event): The event to wait for.
- `:TIMEOUT` (number, optional): If provided, the returned promise will
  reject with a `loom-timeout-error` if the event is not set within
  this many seconds.

Returns:
A `loom-promise` that resolves with the event's value or
rejects on timeout.

Side Effects:
- If the event is not already set, creates a new pending `loom-promise`
  and enqueues it into the `wait-queue` of `EVENT`.

Signals:
- `loom-invalid-event-error`: If `EVENT` is not a valid `loom-event` object.
- `loom-event-destroyed-error`: If `EVENT` has been destroyed."
  (loom--event-full-validate event 'loom:event-wait)
  (let (wait-promise)
    (loom:with-mutex! (loom-event-lock event)
      (if (loom-event-is-set-p event)
          ;; If already set, return a promise that's already resolved.
          (setq wait-promise (loom:resolved! (loom-event-value event)))
        ;; Otherwise, create a new pending promise and queue it.
        (setq wait-promise (loom:promise :name "event-wait"))
        (cl-incf (loom-event-wait-count event))
        (loom-log :debug (loom-event-name event)
                    "Task is waiting for event.")
        (loom:queue-enqueue (loom-event-wait-queue event) wait-promise)))
    ;; Apply timeout wrapper outside the lock.
    (if timeout
        (loom:timeout wait-promise timeout)
      wait-promise)))

;;;###autoload
(defun loom:event-cleanup (event)
  "Destroy `EVENT`, rejecting all pending waiters and preventing further use.
This is useful for cleanup when an event is no longer needed, and is
called automatically for all events on Emacs shutdown.

Arguments:
- `EVENT` (loom-event): The event to destroy.

Returns: `nil`.

Side Effects:
- Marks the event as destroyed.
- Rejects all pending waiters with `loom-event-destroyed-error`.
- Clears the wait queue.
- Removes the event from the global tracking list.

Signals:
- `loom-invalid-event-error`: If `EVENT` is not a valid `loom-event` object."
  (loom--validate-event event 'loom:event-cleanup)
  (let (waiters-to-reject)
    (loom:with-mutex! (loom-event-lock event)
      (unless (loom-event-destroyed-p event)
        (setf (loom-event-destroyed-p event) t)
        (setq waiters-to-reject (loom:queue-drain
                                 (loom-event-wait-queue event)))
        (setq loom--all-events (delete event loom--all-events))
        (loom-log :debug (loom-event-name event)
                    "Event destroyed. Rejecting %d waiters."
                    (length waiters-to-reject))))
    ;; Reject waiters outside the lock.
    (dolist (promise waiters-to-reject)
      (loom:reject promise (list 'loom-event-destroyed-error
                                 "Event was destroyed" event)))))

;;;###autoload
(defun loom:event-stats (event)
  "Return statistics about `EVENT`.

Arguments:
- `EVENT` (loom-event): The event to query.

Returns:
A property list containing statistics:
  - `:name`: The event name.
  - `:is-set-p`: Whether the event is currently set.
  - `:destroyed-p`: Whether the event has been destroyed.
  - `:creation-time`: When the event was created.
  - `:set-time`: When the event was last set (or nil).
  - `:wait-count`: Total number of waiters queued.
  - `:resolve-count`: Total number of waiters resolved.
  - `:pending-count`: Current number of pending waiters.

Signals:
- `loom-invalid-event-error`: If `EVENT` is not a valid `loom-event` object."
  (loom--validate-event event 'loom:event-stats)
  (loom:with-mutex! (loom-event-lock event)
    (list :name (loom-event-name event)
          :is-set-p (loom-event-is-set-p event)
          :destroyed-p (loom-event-destroyed-p event)
          :creation-time (loom-event-creation-time event)
          :set-time (loom-event-set-time event)
          :wait-count (loom-event-wait-count event)
          :resolve-count (loom-event-resolve-count event)
          :pending-count (loom:queue-length (loom-event-wait-queue event)))))

;;;###autoload
(defun loom:event-wait-all (events &optional timeout)
  "Wait for all `EVENTS` to be set.

Arguments:
- `EVENTS` (list of loom-event): The events to wait for.
- `TIMEOUT` (number, optional): Maximum time to wait in seconds.

Returns:
A `loom-promise` that resolves with a list of all event values
when all events are set, or rejects on timeout.

Signals:
- `loom-invalid-event-error`: If any element in `EVENTS` is not a valid event.
- `loom-timeout-error`: If timeout is specified and exceeded."
  (unless (listp events)
    (signal 'loom-invalid-event-error
            (list "loom:event-wait-all: EVENTS must be a list" events)))
  (dolist (event events)
    (loom--validate-event event 'loom:event-wait-all))

  (if (null events)
      (loom:resolved! nil)
    (let ((wait-promises (mapcar (lambda (event)
                                   (loom:event-wait event))
                                 events)))
      (if timeout
          (loom:timeout (loom:all wait-promises) timeout)
        (loom:all wait-promises)))))

;;;###autoload
(defun loom:event-wait-any (events &optional timeout)
  "Wait for any of `EVENTS` to be set.

Arguments:
- `EVENTS` (list of loom-event): The events to wait for.
- `TIMEOUT` (number, optional): Maximum time to wait in seconds.

Returns:
A `loom-promise` that resolves with the value of the first
event that gets set, or rejects on timeout.

Signals:
- `loom-invalid-event-error`: If any element in `EVENTS` is not a valid event.
- `loom-timeout-error`: If timeout is specified and exceeded."
  (unless (listp events)
    (signal 'loom-invalid-event-error
            (list "loom:event-wait-any: EVENTS must be a list" events)))
  (dolist (event events)
    (loom--validate-event event 'loom:event-wait-any))

  (if (null events)
      (loom:rejected! (list 'loom-invalid-event-error
                            "loom:event-wait-any: Empty events list"))
    (let ((wait-promises (mapcar (lambda (event)
                                   (loom:event-wait event))
                                 events)))
      (if timeout
          (loom:timeout (loom:race wait-promises) timeout)
        (loom:race wait-promises)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shutdown Hook

(defun loom--event-shutdown-hook ()
  "Clean up all active `loom-event` instances on Emacs shutdown."
  (when loom--all-events
    (loom-log :info "Global" "Emacs shutdown: Cleaning up %d active event(s)."
              (length loom--all-events))
    ;; Iterate over a copy, as `loom:event-cleanup` modifies the list.
    (dolist (event (copy-sequence loom--all-events))
      (loom:event-cleanup event))))

(add-hook 'kill-emacs-hook #'loom--event-shutdown-hook)

(provide 'loom-event)
;;; loom-event.el ends here