;;; loom-event.el --- Event Synchronization Primitive for Concur -*- lexical-binding: t; -*-
;;
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
;; Example Use Case:
;;
;; (let ((init-event (loom:make-event)))
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'loom-event-error
  "A generic error related to a `loom-event`."
  'loom-error)

(define-error 'loom-invalid-event-error
  "An operation was attempted on an invalid event object."
  'loom-event-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
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
  to `loom:event-wait` while the event was in a 'cleared' state."
  (name "" :type string)
  (lock nil :type loom-lock) 
  (is-set-p nil :type boolean)
  (value t :type t)
  (wait-queue nil :type loom-queue)) 

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--validate-event (event function-name)
  "Signal an error if `EVENT` is not a `loom-event` object.

Arguments:
- `EVENT` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The calling function's name for error reporting."
  (unless (loom-event-p event)
    (signal 'loom-invalid-event-error
            (list (format "%s: Invalid event object" function-name) event))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun loom:event (&optional name)
  "Create a new event object, initially in the 'cleared' state.

Arguments:
- `NAME` (string, optional): A descriptive name for debugging.

Returns:
- (loom-event): A new event object.

Side Effects:
- Creates a new `loom-event` struct.
- Initializes an internal `loom-lock` and `loom-queue`.
- Logs a debug message using `loom-log`."
  (let* ((event-name (or name (format "event-%S" (gensym))))
         (lock (loom:lock (format "event-lock-%s" event-name)))
         (event (%%make-event :name event-name
                              :lock lock
                              :wait-queue (loom:queue))))
    (loom-log :debug (loom-event-name event) "Created event.")
    event))

;;;###autoload
(defun loom:event-is-set-p (event)
  "Return non-nil if `EVENT` is currently in the 'set' state.

Arguments:
- `EVENT` (loom-event): The event to check.

Returns:
- (boolean): `t` if the event is set, `nil` otherwise.

Signals:
- `loom-invalid-event-error`: If `EVENT` is not a valid `loom-event` object."
  (loom--validate-event event 'loom:event-is-set-p)
  (loom-event-is-set-p event))

;;;###autoload
(defun loom:event-set (event &optional value)
  "Set `EVENT`, waking up all current and future waiters.
This operation is idempotent; setting an already-set event has no effect.
All waiting promises will resolve with `VALUE`.

Arguments:
- `EVENT` (loom-event): The event to set.
- `VALUE` (any, optional): The value to resolve waiters with. Defaults to `t`.

Returns:
- `nil`.

Signals:
- `loom-invalid-event-error`: If `EVENT` is not a valid `loom-event` object.

Side Effects:
- Changes the `is-set-p` field of `EVENT` to `t`.
- Sets the `value` field of `EVENT`.
- Drains all promises from the `wait-queue` of `EVENT`.
- Resolves all promises that were in the `wait-queue` with `VALUE`."
  (loom--validate-event event 'loom:event-set)
  (let (waiters-to-resolve resolve-value)
    ;; 1. Update state and retrieve waiters under a lock.
    (loom:with-mutex! (loom-event-lock event)
      (unless (loom-event-is-set-p event)
        (setf (loom-event-is-set-p event) t)
        (setf (loom-event-value event) (or value t))
        (setq waiters-to-resolve (loom:queue-drain
                                  (loom-event-wait-queue event)))
        (setq resolve-value (loom-event-value event))
        (loom-log :debug (loom-event-name event)
                    "Event set. Waking up %d waiters."
                    (length waiters-to-resolve))))
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

Returns:
- `nil`.

Signals:
- `loom-invalid-event-error`: If `EVENT` is not a valid `loom-event` object.

Side Effects:
- Changes the `is-set-p` field of `EVENT` to `nil`.
- Resets the `value` field of `EVENT` to `t`."
  (loom--validate-event event 'loom:event-clear)
  (loom:with-mutex! (loom-event-lock event)
    (setf (loom-event-is-set-p event) nil)
    (setf (loom-event-value event) t) ; Reset value to default.
    (loom-log :debug (loom-event-name event) "Event cleared.")))

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
- (loom-promise): A promise that resolves with the event's value or
  rejects on timeout.

Signals:
- `loom-invalid-event-error`: If `EVENT` is not a valid `loom-event` object.
- `loom-timeout-error`: If a `:TIMEOUT` is specified and the event does
  not get set before the timeout expires.

Side Effects:
- If the event is not already set:
    - Creates a new pending `loom-promise`.
    - Enqueues the new promise into the `wait-queue` of `EVENT`."
  (loom--validate-event event 'loom:event-wait)
  (let (wait-promise)
    (loom:with-mutex! (loom-event-lock event)
      (if (loom-event-is-set-p event)
          ;; If already set, return a promise that's already resolved.
          (setq wait-promise (loom:resolved! (loom-event-value event)))
        ;; Otherwise, create a new pending promise and queue it.
        (setq wait-promise (loom:promise :name "event-wait"))
        (loom-log :debug (loom-event-name event)
                    "Task is waiting for event.")
        (loom:queue-enqueue (loom-event-wait-queue event) wait-promise)))
    ;; Apply timeout wrapper outside the lock.
    (if timeout
        (loom:timeout wait-promise timeout)
      wait-promise)))

(provide 'loom-event)
;;; loom-event.el ends here