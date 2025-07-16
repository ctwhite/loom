;;; loom-promise.el --- Promise Data Structure and Core Operations -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module defines the core `loom-promise` data structure, a powerful
;; primitive for managing asynchronous operations in Emacs Lisp. It provides
;; a standardized way to represent the eventual completion (or failure) of
;; an asynchronous task and to chain dependent operations.
;;
;; ## Key Features
;;
;; - **Promise/A+ Compliance:** Implements a state machine (`:pending`,
;;   `:resolved`, `:rejected`) and guarantees for predictable behavior,
;;   including asynchronous execution of handlers.
;;
;; - **Flexible Concurrency Modes:** Supports promises resolved in the
;;   main Emacs thread (`:deferred`), in native Emacs Lisp threads
;;   (`:thread`), or via external processes (`:process`).
;;
;; - **Unified Resolution/Rejection:** `loom:resolve` and `loom:reject`
;;   provide idempotent ways to settle a promise.
;;
;; - **`await` Mechanism:** The `loom:await` macro allows for synchronous-like
;;   waiting on promises in a cooperative manner, preventing UI freezes.
;;   It now uses a single cooperative polling strategy for all promise modes
;;   when awaited on the main thread.
;;
;; - **Cancellation Support:** Integration with `loom-cancel-token` for
;;   propagating cancellation signals.
;;
;; - **Error Handling:** Robust error propagation and unhandled rejection
;;   detection.
;;
;; - **Inter-thread Communication (IPC):** Seamlessly integrates with
;;   `loom-config.el` and `loom-thread-polling.el` for safe signaling
;;   across different execution contexts.

;;; Code:

(require 'cl-lib)
(require 's)
(require 'dash)
(require 'subr-x)

(require 'loom-log)
(require 'loom-lock)
(require 'loom-registry)
(require 'loom-errors)
(require 'loom-callback)
(require 'loom-thread-polling)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function loom-cancel-token-p "loom-cancel")
(declare-function loom-cancel-token-add-callback "loom-cancel")
(declare-function loom:deferred "loom-config")
(declare-function loom:microtask "loom-config")
(declare-function loom:scheduler-tick "loom-config")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-log-value-max-length 100
  "Max length of a value/error string in logs before truncation."
  :type 'integer
  :group 'loom)

(defcustom loom-await-poll-interval 0.01
  "The polling interval (in seconds) for cooperative `loom:await` blocking."
  :type 'float
  :group 'loom)

(defcustom loom-await-default-timeout 10.0
  "Default timeout (seconds) for `loom:await` if not specified.
If `nil`, `loom:await` will wait indefinitely by default."
  :type '(choice (float :min 0.0) (const :tag "Indefinite" nil))
  :group 'loom)

(defcustom loom-normalize-awaitable-hook nil
  "Hook to normalize arbitrary awaitable objects into `loom-promise`s.
Functions on this hook receive one argument, the object to normalize.
If a function recognizes the object, it should return a `loom-promise`
that represents the object's asynchronous lifecycle. If it does not
recognize it, it should return `nil`."
  :type 'hook
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-promise (:constructor %%make-promise) (:copier nil))
  "Represents an asynchronous operation that can resolve or reject.
This is the central data structure of the library. Do not
manipulate its fields directly; use the `loom:*` functions.

Fields:
- `id` (symbol): A unique identifier (`gensym`) for logging and debugging.
- `result` (any): The value the promise resolved with.
- `error` (loom-error or nil): The reason the promise was rejected.
- `state` (symbol): The current state: `:pending`, `:resolved`, `:rejected`.
- `callbacks` (list): A list of `loom-callback-link` structs.
- `cancel-token` (satisfies loom-cancel-token-p, optional): Token for
  cancellation.
- `cancelled-p` (boolean): `t` if rejection was due to cancellation.
- `proc` (process or nil): An optional associated external process.
- `lock` (loom-lock): A mutex protecting fields from concurrent access.
- `mode` (symbol): Concurrency mode (`:deferred` or `:thread`)."
  (id nil :type symbol)
  (result nil :type t)
  (error nil :type (or null loom-error))
  (state :pending :type (member :pending :resolved :rejected))
  (callbacks nil :type list)
  (cancel-token nil :type (satisfies loom-cancel-token-p))
  (cancelled-p nil :type boolean)
  (proc nil)
  (lock nil :type loom-lock)
  (mode :deferred :type (member :deferred :thread :process))
  (tags nil :type (or null list))
  (created-at (float-time) :type float))

(cl-defstruct (loom-callback-link (:constructor %%make-callback-link) (:copier nil))
  "Groups related callbacks that are attached to a promise as a single unit.
This struct ensures that a set of callbacks (e.g., a resolve handler and
a reject handler originating from a single `.then` call) are processed
coherently."
  (id nil :type symbol)
  (callbacks nil :type list))

(cl-defstruct (loom-await-latch (:constructor %%make-await-latch) (:copier nil))
  "Internal latch for the `loom:await` mechanism.
This struct acts as a shared, thread-safe flag between a waiting
`loom:await` call and the promise callback that signals completion.

Fields:
- `signaled-p` (boolean or `timeout`): The flag indicating completion.
- `lock` (loom-lock): A mutex protecting the `signaled-p` field."
  (signaled-p nil :type (or boolean symbol))
  (lock nil :type loom-lock))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Core Promise Lifecycle

(defun loom--trigger-callbacks-after-settle (promise callback-links)
  "Schedules a promise's callbacks for execution after it has settled.
This function is central to Loom's asynchronous model. It ensures that
callbacks do not run in the same execution context as the resolving or
rejecting function, adhering to the Promise/A+ standard.

Arguments:
- `PROMISE` (loom-promise): The promise that has settled.
- `CALLBACK-LINKS` (list): A list of `loom-callback-link` objects.

Returns:
- `nil`.

Side Effects:
- Enqueues tasks on the microtask and macrotask schedulers.
- Schedules an unhandled rejection check if the promise was rejected."
  (let* ((id (loom-promise-id promise))
         (all-callbacks (-flatten (mapcar #'loom-callback-link-callbacks
                                          callback-links)))
         (state (loom-promise-state promise))
         (type-to-run (if (eq state :resolved) :resolved :rejected)))
    (loom-log :debug id "Triggering callbacks for %S state." state)
    (let ((callbacks-to-run
           (-filter (lambda (cb)
                      (let ((type (loom-callback-type cb)))
                        (or (eq type type-to-run)
                            (memq type '(:await-latch :finally)))))
                    all-callbacks)))
      (loom-log :debug id "Scheduling %d relevant callbacks."
                (length callbacks-to-run))
      (let ((microtasks '()) (macrotasks '()))
        (dolist (cb callbacks-to-run)
          (if (memq (loom-callback-type cb)
                    '(:await-latch :resolved :rejected :finally))
              (push cb microtasks)
            (push cb macrotasks)))
        (when microtasks
          (dolist (task (nreverse microtasks)) (loom:microtask task)))
        (when macrotasks
          (dolist (task (nreverse macrotasks)) (loom:deferred task))))))

  (when (eq (loom-promise-state promise) :rejected)
    (loom-log :debug (loom-promise-id promise)
              "Scheduling unhandled rejection check.")
    (loom:deferred (lambda () (loom--handle-unhandled-rejection promise)))))

(defun loom--kill-associated-process (promise)
  "Terminates any external process associated with a `PROMISE`.
This is typically called when a promise is cancelled to clean up resources.

Arguments:
- `PROMISE` (loom-promise): The promise whose process should be killed.

Returns:
- `nil`.

Side Effects:
- May kill an external process via `delete-process`.
- Sets the `proc` field of `PROMISE` to `nil`."
  (when-let ((proc (loom-promise-proc promise)))
    (when (process-live-p proc)
      (loom-log :info (loom-promise-id promise)
                "Killing associated process %S." proc)
      (ignore-errors (delete-process proc)))
    (setf (loom-promise-proc promise) nil)))

(defun loom--schedule-or-dispatch-callbacks (promise
                                             callbacks-to-run
                                             is-cancellation)
  "Decides how to execute callbacks based on the current execution context.
If in a background thread, it dispatches a message to the main thread via
IPC. If on the main thread, it schedules the callbacks directly. This
entire mechanism ensures compliance with Promise/A+ Spec 2.2.4, which
mandates that callbacks execute asynchronously.

Arguments:
- `PROMISE` (loom-promise): The settled promise.
- `CALLBACKS-TO-RUN` (list): The list of `loom-callback-link`s.
- `IS-CANCELLATION` (boolean): Whether the settlement was a cancellation.

Returns:
- `nil`.

Side Effects:
- May call `loom:dispatch-to-main-thread` for IPC.
- May call `loom--trigger-callbacks-after-settle` to schedule tasks."
  (let ((id (loom-promise-id promise)))
    (if (and (fboundp 'make-thread) (not (equal (current-thread) main-thread)))
        ;; From a background thread, always dispatch to the main thread's
        ;; event loop. This ensures all user promise code executes in a
        ;; single, predictable thread, preventing race conditions.
        (progn
          (loom-log :debug id
                    "Dispatching settlement from worker thread to main.")
          (loom:dispatch-to-main-thread promise))
      ;; From the main thread, schedule callbacks via our internal schedulers.
      (progn
        (loom-log :debug id "Scheduling callbacks from main thread.")
        (loom--trigger-callbacks-after-settle promise callbacks-to-run)
        (when is-cancellation (loom--kill-associated-process promise))))))

(defun loom--settle-promise (promise result error is-cancellation)
  "Settles a `PROMISE` to a resolved or rejected state.
This is the core, internal, and idempotent function for transitioning a
promise from `:pending`. It is thread-safe.

Arguments:
- `PROMISE` (loom-promise): The promise to settle.
- `RESULT` (any): The resolution value (nil if rejecting).
- `ERROR` (loom-error): The rejection error (nil if resolving).
- `IS-CANCELLATION` (boolean): `t` if this is a cancellation.

Returns:
- (loom-promise): The original `PROMISE`.

Signals:
- `error`: If `PROMISE` is not a `loom-promise`.

Side Effects:
- Acquires and releases the promise's lock.
- Mutates the promise's state, result, and error fields if it was pending.
- Dispatches or schedules all attached callbacks for execution.
- Updates the global promise registry."
  (unless (loom-promise-p promise)
    (error "Expected loom-promise, got: %S" promise))

  (let (settled-now callbacks-to-run (id (loom-promise-id promise)))
    (loom-log :debug id "Attempting to settle promise.")
    (loom:with-mutex! (loom-promise-lock promise)
      ;; Spec 2.1: A promise must be in one of three states.
      ;; This block ensures it only transitions from :pending once.
      (when (eq (loom-promise-state promise) :pending)
        (setq settled-now t)
        (let ((new-state (if error :rejected :resolved)))
          ;; Spec 2.1.2 & 2.1.3: Once fulfilled or rejected, a promise must
          ;; not transition to any other state. This `when` block enforces
          ;; this.
          (loom-log :info id "State transition: :pending -> %S" new-state)
          (setf (loom-promise-result promise) result
                (loom-promise-error promise) error
                (loom-promise-state promise) new-state
                (loom-promise-cancelled-p promise) is-cancellation))
        ;; Spec 2.2.6: `then` may be called multiple times. We retrieve all
        ;; queued callbacks for execution.
        (setq callbacks-to-run (nreverse (loom-promise-callbacks promise)))
        (setf (loom-promise-callbacks promise) nil)))

    (when settled-now
      (loom-log :debug id "Promise settled. Dispatching callbacks.")
      ;; Spec 2.2.4: Handlers must run asynchronously. This function handles
      ;; the logic to schedule them appropriately.
      (loom--schedule-or-dispatch-callbacks
       promise callbacks-to-run is-cancellation)
      (loom-registry-update-promise-state promise)))
  promise)

(defun loom--handle-unhandled-rejection (promise)
  "Handles a promise rejected without any attached error handlers.
This is scheduled on the next tick after rejection, giving user code a
chance to attach a `.catch` handler before it's deemed 'unhandled'.

Arguments:
- `PROMISE` (loom-promise): The rejected promise to check.

Returns:
- `nil`.

Signals:
- `loom-unhandled-rejection`: If `loom-on-unhandled-rejection-action`
  is 'signal.

Side Effects:
- May log a warning or call a user-defined function based on
  `loom-on-unhandled-rejection-action`."
  (loom-log :debug (loom-promise-id promise)
            "Checking for unhandled rejection.")
  (when (and (eq (loom-promise-state promise) :rejected)
             (not (loom-registry-has-downstream-handlers-p promise)))
    (loom-log :warn (loom-promise-id promise) "Detected unhandled rejection.")
    (let ((error-obj (loom:error-value promise)))
      (condition-case err
          (pcase loom-on-unhandled-rejection-action
            ('log (loom-log :warn (loom-promise-id promise)
                            "Unhandled: %S" error-obj))
            ('signal (signal 'loom-unhandled-rejection (list error-obj)))
            ((pred functionp)
             (funcall loom-on-unhandled-rejection-action error-obj)))
        (error
          (loom-log :error (loom-promise-id promise)
                    "Error in unhandled rejection handler: %S" err))))))

(defun loom--setup-await-latch (promise timeout)
  "Create and attach a latch to a promise for `await`.
This helper encapsulates the logic of creating a latch, attaching it to the
promise as a high-priority callback, and setting up an optional timeout
timer that races against the promise's settlement.

Arguments:
- `PROMISE` (loom-promise): The promise to await.
- `TIMEOUT` (number or nil): The timeout in seconds.

Returns:
- (cons): A cons cell `(LATCH . TIMER)` where `LATCH` is a
  `loom-await-latch` and `TIMER` is a timer object or nil."
  (let* ((id (loom-promise-id promise))
         (latch (%%make-await-latch
                 :lock (loom:lock (format "latch-%S" id))))
         timer)
    ;; Attach a high-priority callback to signal the latch on settlement.
    (loom-attach-callbacks
      promise
      (loom:callback (lambda ()
                       (loom:with-mutex! (loom-await-latch-lock latch)
                         (setf (loom-await-latch-signaled-p latch) t)))
                     :type :await-latch
                     :priority 0
                     :promise-id id
                     :source-promise-id id))
    ;; Set up an optional timer to race against the promise settlement.
    (when timeout
      (setq timer
            (run-at-time timeout nil
                         (lambda ()
                           (loom:with-mutex! (loom-await-latch-lock latch)
                             ;; Only set to 'timeout if it hasn't already been
                             ;; signaled by the promise settlement.
                             (unless (loom-await-latch-signaled-p latch)
                               (setf (loom-await-latch-signaled-p latch)
                                     'timeout)))))))
    (cons latch timer)))

(defun loom--await-cooperative-blocking (promise timeout)
  "Cooperatively blocks on the main thread until a promise settles.
This function uses `sit-for` and scheduler ticks, ensuring UI responsiveness.

Arguments:
- `PROMISE` (loom-promise): The promise to wait for.
- `TIMEOUT` (number or nil): The maximum time in seconds to wait.

Returns:
- (any): The resolved value of the `PROMISE`.

Signals:
- `loom-await-error`: If the `PROMISE` rejects.
- `loom-timeout-error`: If the `TIMEOUT` is exceeded."
  (let* ((id (loom-promise-id promise))
         (latch-info (loom--setup-await-latch promise timeout))
         (latch (car latch-info))
         (timer (cdr latch-info)))
    (unwind-protect
        (progn
          (loom-log :debug id "Await: Entering cooperative wait loop.")
          ;; The polling loop's only job is to tick the scheduler and wait
          ;; for the latch to be signaled by either the promise or the timer.
          (loom:poll-with-backoff
           (lambda () (loom-await-latch-signaled-p latch)) ; Condition
           (lambda () (loom:scheduler-tick))               ; Work
           loom-await-poll-interval
           id)

          ;; After the loop exits, check the latch to determine the outcome.
          (cond
            ((eq (loom-await-latch-signaled-p latch) 'timeout)
             (signal 'loom-timeout-error
                     (list (format "Await timed out for %S" id))))
            ((loom:rejected-p promise)
             (signal 'loom-await-error
                     (list (loom:error-value promise))))
            (t (loom:value promise))))
      ;; Cleanup: always cancel the timer if it exists.
      (when timer (cancel-timer timer)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API (Package Private): Attaching/Executing Callbacks

(defun loom--execute-simple-callback (callback)
  "Executor for simple, nullary callbacks like :await-latch and :finally.

Arguments:
- `CALLBACK` (loom-callback): The callback to execute.

Returns:
- (any): The result of the callback's handler function.

Side Effects:
- Executes the handler function, which may have its own side effects."
  (funcall (loom-callback-handler-fn callback)))

(defun loom--execute-resolution-callback (callback)
  "Executor for :resolved and :rejected callbacks.

Arguments:
- `CALLBACK` (loom-callback): The callback to execute.

Returns:
- (any): The result of the callback's handler function.

Signals:
- `error`: If the source promise for the callback is not in the registry.

Side Effects:
- Executes the handler function, which may resolve or reject a target promise."
  (let* ((data (loom-callback-data callback))
         (source-promise-id (plist-get data :source-promise-id))
         (target-promise-id (plist-get data :promise-id))
         (source-promise (loom-registry-get-promise-by-id source-promise-id))
         (target-promise (loom-registry-get-promise-by-id target-promise-id)))
    (unless source-promise
      (error "Source promise %S not found in registry" source-promise-id))
    (when target-promise
      (let ((arg (if (loom:rejected-p source-promise)
                     (loom:error-value source-promise)
                   (loom:value source-promise))))
        (funcall (loom-callback-handler-fn callback) target-promise arg)))))

(defun loom-execute-callback (callback)
  "Executes a stored callback with its source promise's result or error.
This function is called by the schedulers. It dispatches to a helper
based on the callback type.

Arguments:
- `CALLBACK` (loom-callback): The callback struct to execute.

Returns:
- `nil`.

Signals:
- `error`: If the callback handler is not a function or type is unknown.

Side Effects:
- Rejects the target promise if the callback handler itself signals an error."
  (let ((id (plist-get (loom-callback-data callback) :promise-id)))
    (loom-log :debug id "Executing callback of type %S."
              (loom-callback-type callback))
    (condition-case-unless-debug err
        (let ((handler-fn (loom-callback-handler-fn callback)))
          (unless (functionp handler-fn)
            (error "Invalid callback handler: %S" handler-fn))
          (pcase (loom-callback-type callback)
            ((or :await-latch :deferred :cancel :finally)
             (loom--execute-simple-callback callback))
            ((or :resolved :rejected)
             (loom--execute-resolution-callback callback))
            (_ (error "Unknown callback type: %S"
                      (loom-callback-type callback)))))
      (error
        (let ((msg (format "Callback failed: %s"
                           (error-message-string err))))
          (loom-log :error id "%s" msg)
          (when-let ((promise (loom-registry-get-promise-by-id id)))
            (loom:reject promise (loom:make-error :type :callback-error
                                                  :message msg :cause err))))))))

(defun loom-attach-callbacks (promise &rest callbacks)
  "Attaches one or more `CALLBACKS` to a `PROMISE`.
If the promise is pending, callbacks are queued. If already settled, they
are scheduled for asynchronous execution immediately.

Arguments:
- `PROMISE` (loom-promise): The promise to attach to.
- `CALLBACKS` (list of `loom-callback`): Callbacks to attach.

Returns:
- (loom-promise): The original `PROMISE`.

Side Effects:
- Acquires and releases the promise's lock.
- Modifies the promise's internal callback list if pending.
- Schedules callbacks for execution if the promise is already settled."
  (let* ((id (loom-promise-id promise))
         (non-nil-callbacks (-filter #'identity callbacks)))
    (when non-nil-callbacks
      (let ((link (%%make-callback-link :id (gensym "link-")
                                        :callbacks non-nil-callbacks)))
        (loom-log :debug id "Attaching %d callback(s)."
                  (length non-nil-callbacks))
        (loom:with-mutex! (loom-promise-lock promise)
          (if (eq (loom-promise-state promise) :pending)
              (push link (loom-promise-callbacks promise))
            ;; If already settled, schedule callbacks asynchronously now.
            (loom--trigger-callbacks-after-settle promise (list link)))))))
  promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Promise Creation & Management

(defun loom--promise-execute-executor (promise executor)
  "Internal helper to run the promise executor function safely.

Arguments:
- `PROMISE` (loom-promise): The promise being constructed.
- `EXECUTOR` (function): The executor function `(lambda (resolve reject) ...)`

Returns:
- `nil`.

Side Effects:
- Calls the `EXECUTOR` function.
- Rejects `PROMISE` if the `EXECUTOR` signals an error synchronously."
  (let ((id (loom-promise-id promise)))
    (loom-log :debug id "Executing promise executor function.")
    (cl-letf (((symbol-value 'loom-current-async-stack)
               (cons (format "Executor (%S)" id) loom-current-async-stack)))
      (condition-case err
          (funcall executor
                   (lambda (v) (loom:resolve promise v))
                   (lambda (e) (loom:reject promise e)))
        (error
          (let ((msg (format "Executor failed: %s"
                             (error-message-string err))))
            (loom-log :error id "%s" msg)
            (loom:reject promise (loom:make-error :type :executor-error
                                                  :message msg :cause err))))))))

;;;###autoload
(cl-defun loom:promise (&key executor (mode :deferred) name cancel-token tags)
  "Creates a new, pending `loom-promise`.
If `:executor` is provided, it is a function `(lambda (resolve reject) ...)`
that is called immediately to control the promise's fate.

Arguments:
- `:EXECUTOR` (function, optional): The function to execute.
- `:MODE` (symbol): Concurrency mode (`:deferred` or `:thread`).
- `:NAME` (string): A descriptive name for debugging.
- `:CANCEL-TOKEN` (loom-cancel-token): Optional token for cancellation.
- `:TAGS` (list): A list of keyword tags for filtering.

Returns:
- (loom-promise): A new `loom-promise` in the `:pending` state."
  (let* ((promise-id (gensym (or name "promise-")))
         (promise (%%make-promise
                   :id promise-id
                   :mode mode
                   :lock (loom:lock (format "promise-%S" promise-id)
                                    :mode (if (eq mode :thread)
                                              :thread :deferred))
                   :tags (cl-delete-duplicates (ensure-list tags))
                   :cancel-token cancel-token)))
    (loom-log :info promise-id "Created new promise (mode: %s)." mode)
    (loom-registry-register-promise promise)

    (when cancel-token
      (loom-cancel-token-add-callback
       cancel-token (lambda (reason) (loom:cancel promise reason))))

    (when executor (loom--promise-execute-executor promise executor))
    promise))

;;;###autoload
(defun loom:resolve (promise value)
  "Resolves a `PROMISE` with `VALUE` (implements Promises/A+ Spec 2.3).
If `VALUE` is a promise itself, `PROMISE` will adopt its state. This
operation is idempotent.

Arguments:
- `PROMISE` (loom-promise): The promise to resolve.
- `VALUE` (any): The value to resolve with.

Returns:
- (loom-promise): The original `PROMISE`.

Signals:
- `loom-type-error`: If `PROMISE` is not a promise.

Side Effects:
- May reject the promise if a resolution cycle is detected.
- May attach callbacks if `VALUE` is another promise.
- May settle the promise by calling `loom--settle-promise`."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error (list "Expected a promise" promise)))
  (loom-log :debug (loom-promise-id promise)
            "Resolve called with type %S." (type-of value))

  ;; Spec 2.3.1: A promise cannot be resolved with itself.
  (if (eq promise value)
      (loom:reject promise (loom:make-error :type :type-error
                                            :message
                                            "Promise resolution cycle detected."))
    (let ((normalized-value
           (if (loom-promise-p value) value
             (run-hook-with-args-until-success
              'loom-normalize-awaitable-hook value))))
      ;; Spec 2.3.2: If value is a promise, adopt its state.
      (if (loom-promise-p normalized-value)
          (let ((outer-promise promise))
            (loom-log :info (loom-promise-id outer-promise)
                      "Chaining to promise %S."
                      (loom-promise-id normalized-value))
            (loom-attach-callbacks
             normalized-value
             (loom:callback (lambda (_ res) (loom:resolve outer-promise res))
                            :type :resolved
                            :promise-id (loom-promise-id outer-promise)
                            :source-promise-id
                            (loom-promise-id normalized-value))
             (loom:callback (lambda (_ err) (loom:reject outer-promise err))
                            :type :rejected
                            :promise-id (loom-promise-id outer-promise)
                            :source-promise-id
                            (loom-promise-id normalized-value))))
        ;; Spec 2.3.4: If value is not a promise, fulfill with value.
        (loom--settle-promise promise value nil nil))))
  promise)

;;;###autoload
(defun loom:reject (promise error)
  "Rejects `PROMISE` with `ERROR`.
If `ERROR` is not already a `loom-error` struct, it will be wrapped.
This operation is idempotent.

Arguments:
- `PROMISE` (loom-promise): The promise to reject.
- `ERROR` (any): The reason for rejection.

Returns:
- (loom-promise): The original `PROMISE`.

Signals:
- `loom-type-error`: If `PROMISE` is not a promise.

Side Effects:
- Settles the promise by calling `loom--settle-promise`."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error (list "Expected a promise" promise)))
  (loom-log :debug (loom-promise-id promise) "Reject called with error.")
  (let* ((is-cancellation (and (loom-error-p error)
                               (eq (loom-error-type error) :cancel)))
         (final-error (if (loom-error-p error) error
                        (loom:make-error :type :rejection :cause error))))
    (loom--settle-promise promise nil final-error is-cancellation))
  promise)

;;;###autoload
(defun loom:cancel (promise &optional reason)
  "Cancels a pending `PROMISE`.
This is a convenience function that rejects the promise with a special
`:cancel` error type.

Arguments:
- `PROMISE` (loom-promise): The promise to cancel.
- `REASON` (string, optional): A message explaining the cancellation.

Returns:
- (loom-promise): The original `PROMISE`.

Side Effects:
- Calls `loom:reject` on `PROMISE` if it is pending."
  (when (loom:pending-p promise)
    (loom-log :info (loom-promise-id promise) "Cancelling (Reason: %s)."
              (or reason "N/A"))
    (loom:reject promise (loom:make-error :type :cancel
                                          :message (or reason
                                                       "Promise cancelled"))))
  promise)

;;;###autoload
(defmacro loom:resolved! (value-form &rest keys)
  "Create a new promise that is already resolved with `VALUE-FORM`.

Arguments:
- `VALUE-FORM`: A Lisp form that evaluates to the resolution value.
- `KEYS`: Options for `loom:promise` (:mode, :name, etc.).

Returns:
- (loom-promise): A new promise in the `:resolved` state."
  (declare (indent 1) (debug t))
  `(let ((promise (apply #'loom:promise (list ,@keys))))
     (loom:resolve promise ,value-form)))

;;;###autoload
(defmacro loom:rejected! (error-form &rest keys)
  "Create a new promise that is already rejected with `ERROR-FORM`.

Arguments:
- `ERROR-FORM`: A Lisp form that evaluates to the rejection reason.
- `KEYS`: Options for `loom:promise` (:mode, :name, etc.).

Returns:
- (loom-promise): A new promise in the `:rejected` state."
  (declare (indent 1) (debug t))
  `(let ((promise (apply #'loom:promise (list ,@keys))))
     (loom:reject promise ,error-form)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Promise Status and Introspection

;;;###autoload
(defun loom:status (promise)
  "Return the current state of a `PROMISE` without blocking.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns:
- (symbol): The state (`:pending`, `:resolved`, or `:rejected`).

Signals:
- `loom-type-error`: If `PROMISE` is not a promise."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error (list "Expected a promise" promise)))
  (loom-promise-state promise))

;;;###autoload
(defun loom:pending-p (promise)
  "Return non-nil if `PROMISE` is pending.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns:
- (boolean): `t` if pending, `nil` otherwise."
  (eq (loom:status promise) :pending))

;;;###autoload
(defun loom:resolved-p (promise)
  "Return non-nil if `PROMISE` is resolved.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns:
- (boolean): `t` if resolved, `nil` otherwise."
  (eq (loom:status promise) :resolved))

;;;###autoload
(defun loom:rejected-p (promise)
  "Return non-nil if `PROMISE` is rejected.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns:
- (boolean): `t` if rejected, `nil` otherwise."
  (eq (loom:status promise) :rejected))

;;;###autoload
(defun loom:cancelled-p (promise)
  "Return non-nil if `PROMISE` was cancelled.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns:
- (boolean): `t` if cancelled, `nil` otherwise."
  (loom-promise-cancelled-p promise))

;;;###autoload
(defun loom:value (promise)
  "Return the resolved value of `PROMISE`, or `nil` if not resolved.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns:
- (any or nil): The resolved value, or `nil`."
  (when (loom:resolved-p promise)
    (loom-promise-result promise)))

;;;###autoload
(defun loom:error-value (promise)
  "Return the rejection error of `PROMISE`, or `nil` if not rejected.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns:
- (loom-error or nil): The error object, or `nil`."
  (when (loom:rejected-p promise)
    (loom-promise-error promise)))

;;;###autoload
(defun loom:format-promise (promise)
  "Return a human-readable string representation of a promise.

Arguments:
- `PROMISE` (loom-promise): The promise to format.

Returns:
- (string): A descriptive string including its ID, name, mode, and state.

Signals:
- `loom-type-error`: If `PROMISE` is not a promise."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error (list "Expected a promise" promise)))
  (let* ((id (loom-promise-id promise))
         (mode (loom-promise-mode promise))
         (status (loom:status promise))
         (name (loom-registry-get-promise-name promise)))
    (pcase status
      (:pending (format "#<Promise %s (%s) %s: pending>" name id mode))
      (:resolved
       (format "#<Promise %s (%s) %s: resolved with %s>" name id mode
               (s-truncate loom-log-value-max-length
                           (format "%S" (loom:value promise)))))
      (:rejected
       (format "#<Promise %s (%s) %s: rejected with %s>" name id mode
               (s-truncate loom-log-value-max-length
                           (loom:error-message
                            (loom:error-value promise))))))))

;;;###autoload
(defmacro loom:await (promise-form &optional timeout)
  "Synchronously and cooperatively wait for a promise to settle.
This function blocks the current execution cooperatively until the
promise is resolved or rejected, or a timeout occurs.

Arguments:
- `PROMISE-FORM`: A form that evaluates to a `loom-promise`.
- `TIMEOUT` (number, optional): Seconds to wait before timing out.

Returns:
- (any): The resolved value of the promise.

Signals:
- `loom-await-error`: If the promise rejects.
- `loom-timeout-error`: If the `TIMEOUT` is exceeded.
- `loom-type-error`: If `PROMISE-FORM` doesn't yield a promise."
  (declare (indent 1) (debug t))
  `(let* ((p-val ,promise-form)
          (promise (if (loom-promise-p p-val) p-val
                     (run-hook-with-args-until-success
                      'loom-normalize-awaitable-hook p-val))))
     (unless (loom-promise-p promise)
       (signal 'loom-type-error (list "await expected a promise" p-val)))
     (let ((await-label (format "awaiting %S" (loom-promise-id promise))))
       (cl-letf (((symbol-value 'loom-current-async-stack)
                  (cons await-label loom-current-async-stack)))
         (loom--await-cooperative-blocking
          promise (or ,timeout loom-await-default-timeout))))))

(provide 'loom-promise)
;;; loom-promise.el ends here