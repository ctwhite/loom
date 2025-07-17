;;; loom-promise.el --- Promise Data Structure and Core Operations -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module defines the core `loom-promise` data structure, a powerful
;; primitive for managing asynchronous operations in Emacs Lisp. It provides
;; a standardized way to represent the eventual completion (or failure) of
;; an asynchronous task and to chain dependent operations.
;;
;; This implementation is designed to be compliant with the core principles
;; of the Promise/A+ specification, ensuring predictable and robust behavior.
;;
;; ## Key Architectural Concepts
;;
;; - **Promise/A+ Compliance:** Implements a strict state machine (`:pending`,
;;   `:resolved`, `:rejected`) where a promise can only be settled once. It
;;   guarantees that all callbacks (`.then`, `.catch`, `.finally`) execute
;;   asynchronously, preventing stack overflow and ensuring a consistent
;;   execution order.
;;
;; - **Centralized State Management:** To eliminate race conditions, all state
;;   transitions (settling a promise) for `:thread` and `:process` mode promises
;;   are funneled through the main Emacs thread via the IPC mechanism. A
;;   background thread's attempt to settle a promise dispatches a message to the
;;   main thread, which then performs the actual state change. This makes the
;;   main thread the single source of truth for a promise's lifecycle.
;;
;; - **Cooperative `await`:** The `loom:await` macro provides a way to write
;;   synchronous-looking code that consumes promises. Critically, it does **not**
;;   perform a hard block. Instead, it enters a cooperative polling loop that
;;   repeatedly runs the Loom scheduler and yields control, keeping the Emacs
;;   UI responsive.
;;
;; - **Flexible Concurrency Modes:** Supports promises that encapsulate work
;;   in different contexts:
;;   - `:deferred`: For operations on the main Emacs thread's event loop.
;;   - `:thread`: For tasks offloaded to a native Emacs Lisp thread.
;;   - `:process`: For tasks managed in an external OS process.
;;
;; - **Cancellation:** Integrates with `loom-cancel-token` to allow for the
;;   propagation of cancellation requests through a chain of promises.
;;
;; - **Unhandled Rejection Tracking:** The system can detect when a promise is
;;   rejected but has no error handler attached, helping to identify silent
;;   failures in asynchronous code.

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
(declare-function loom:dispatch-to-main-thread "loom-ipc")
(declare-function loom:serialize-error "loom-errors")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-log-value-max-length 100
  "Maximum length of a value or error string included in log messages.
Longer values will be truncated to keep logs readable."
  :type 'integer
  :group 'loom)

(defcustom loom-await-poll-interval 0.01
  "The polling interval (in seconds) for the cooperative `loom:await` loop.
This determines how frequently `await` checks if the promise has settled
while it is 'blocking'."
  :type 'float
  :group 'loom)

(defcustom loom-await-default-timeout 10.0
  "Default timeout (in seconds) for `loom:await` if one is not specified.
If set to `nil`, `loom:await` will wait indefinitely by default, which may
not be desirable in all contexts."
  :type '(choice (float :min 0.0) (const :tag "Indefinite" nil))
  :group 'loom)

(defcustom loom-normalize-awaitable-hook nil
  "A hook for converting arbitrary objects into `loom-promise` instances.
This allows `loom:await` and `loom:resolve` to work with objects from
other libraries (e.g., `url-retrieve-synchronously`'s request objects)
by wrapping them in a standard promise interface.

Each function on the hook receives one argument, the object to normalize.
If a function recognizes the object type, it should return a new
`loom-promise` that settles when the original object completes its
asynchronous work. If it does not recognize the object, it must return `nil`
to allow other hook functions to run."
  :type 'hook
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-promise (:constructor %%make-promise) (:copier nil))
  "Represents an asynchronous operation that can resolve or reject.
This is the central data structure of the library. Its fields should **never**
be manipulated directly. Use the public API functions (`loom:resolve`,
`loom:reject`, `loom:status`, etc.) to interact with it.

Fields:
- `id` (symbol): A unique identifier (`gensym`) for logging and debugging.
- `result` (any): The value the promise resolved with. Only set if `state`
  is `:resolved`.
- `error` (loom-error or nil): The structured error the promise was
  rejected with.
- `state` (symbol): The current state of the promise: `:pending`, `:resolved`,
  or `:rejected`.
- `callbacks` (list): A list of `loom-callback-link` structs to be executed
  upon settlement.
- `cancel-token` (satisfies loom-cancel-token-p, optional): A token to signal
  cancellation.
- `cancelled-p` (boolean): Set to `t` if rejection was specifically due to
  cancellation.
- `proc` (process or nil): An associated external process, if any
  (`:process` mode).
- `lock` (loom-lock): A mutex protecting the promise's fields from concurrent
  access.
- `mode` (symbol): Concurrency mode (`:deferred`, `:thread`, or `:process`).
- `tags` (list): A list of user-defined keywords for categorization and
  filtering.
- `created-at` (float): The timestamp (`float-time`) when the promise was
  created."
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

(cl-defstruct (loom-callback-link
               (:constructor %%make-callback-link) (:copier nil))
  "Groups related callbacks that are attached to a promise as a single unit.
This struct ensures that a set of callbacks originating from a single
call like `.then(on-resolve, on-reject)` are processed coherently and
their corresponding child promise is correctly tracked for unhandled
rejection detection."
  (id nil :type symbol)
  (callbacks nil :type list))

(cl-defstruct (loom-await-latch
               (:constructor %%make-await-latch) (:copier nil))
  "An internal, thread-safe latch for the `loom:await` mechanism.
This struct acts as a shared flag between a waiting `loom:await` call
and the promise it is waiting on. The promise callback signals completion
by setting `signaled-p` to `t`, while a timeout timer may set it to `'timeout`.

Fields:
- `signaled-p` (`t`, `nil`, or `'timeout`): The flag indicating completion
  status.
- `lock` (loom-lock): A mutex protecting concurrent access to the
  `signaled-p` field."
  (signaled-p nil :type (or boolean symbol))
  (lock nil :type loom-lock))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Core Promise Lifecycle

(defun loom--trigger-callbacks-after-settle (promise callback-links)
  "Schedules a promise's callbacks for execution after it has settled.
This function is central to Loom's asynchronous model. It guarantees that
callbacks are executed on a clean stack, separate from the code that
originally settled the promise. This adheres to the Promise/A+ spec and
prevents unexpected re-entrancy issues.

Arguments:
- `PROMISE` (loom-promise): The promise that has just settled.
- `CALLBACK-LINKS` (list): A list of `loom-callback-link` objects containing
  the callbacks to run.

Returns: `nil`."
  (let* ((id (loom-promise-id promise))
         (all-callbacks (-flatten (mapcar #'loom-callback-link-callbacks
                                          callback-links)))
         (state (loom-promise-state promise))
         (type-to-run (if (eq state :resolved) :resolved :rejected)))
    (loom-log :debug id "Scheduling callbacks for settled promise (state: %S)."
              state)

    ;; Filter the callbacks to run only those matching the settlement state,
    ;; plus universal handlers like `:finally` and `:await-latch`.
    (let ((callbacks-to-run
           (-filter (lambda (cb)
                      (let ((type (loom-callback-type cb)))
                        (or (eq type type-to-run)
                            (memq type '(:await-latch :finally)))))
                    all-callbacks)))
      (loom-log :debug id "Found %d relevant callbacks to schedule."
                (length callbacks-to-run))
      ;; Separate callbacks into high-priority microtasks and regular macrotasks.
      (let ((microtasks '()) (macrotasks '()))
        (dolist (cb callbacks-to-run)
          ;; `:await-latch` and resolution callbacks run as microtasks for
          ;; responsiveness.
          (if (memq (loom-callback-type cb)
                    '(:await-latch :resolved :rejected :finally))
              (push cb microtasks)
            (push cb macrotasks)))
        ;; Schedule the tasks. `nreverse` is used because we `push`ed them.
        (when microtasks
          (dolist (task (nreverse microtasks)) (loom:microtask task)))
        (when macrotasks
          (dolist (task (nreverse macrotasks)) (loom:deferred task))))))

  ;; After any rejection, schedule a deferred check to see if the rejection
  ;; was handled. It's deferred to give user code a chance to attach a `.catch`.
  (when (eq (loom-promise-state promise) :rejected)
    (loom-log :debug (loom-promise-id promise)
              "Scheduling unhandled rejection check for next tick.")
    (loom:deferred (lambda () (loom--handle-unhandled-rejection promise)))))

(defun loom--kill-associated-process (promise)
  "Terminates any external OS process associated with a `PROMISE`.
This is typically called when a promise is cancelled to ensure no orphaned
processes are left running. This function is idempotent.

Arguments:
- `PROMISE` (loom-promise): The promise whose process should be killed.

Returns: `nil`."
  (when-let ((proc (loom-promise-proc promise)))
    (when (process-live-p proc)
      (loom-log :info (loom-promise-id promise)
                "Killing associated process: %S" proc)
      (ignore-errors (delete-process proc)))
    ;; Clear the field to prevent multiple kill attempts.
    (setf (loom-promise-proc promise) nil)))

(defun loom--schedule-or-dispatch-callbacks (promise
                                             callbacks-to-run
                                             is-cancellation)
  "Schedules callbacks for execution, now exclusively on the main thread.
The logic in `loom--settle-promise` ensures that any attempt to settle a
promise from a background thread is delegated to the main thread via IPC.
As a result, this function is only ever called on the main thread, greatly
simplifying the logic for asynchronous callback execution.

Arguments:
- `PROMISE` (loom-promise): The settled promise.
- `CALLBACKS-TO-RUN` (list): The list of `loom-callback-link`s to execute.
- `IS-CANCELLATION` (boolean): Whether the settlement was due to cancellation.

Returns: `nil`."
  (let ((id (loom-promise-id promise)))
    ;; All settlements are now funneled to the main thread, so we can directly
    ;; trigger the async callback scheduler.
    (loom-log :debug id "On main thread, triggering callback scheduling.")
    (loom--trigger-callbacks-after-settle promise callbacks-to-run)
    ;; If the promise was cancelled, also clean up any associated resources.
    (when is-cancellation (loom--kill-associated-process promise))))

(defun loom--settle-promise (promise result error is-cancellation)
  "Settles a `PROMISE` to a resolved or rejected state.
This is the **core internal settlement function**. It is thread-safe and
idempotent, meaning it can be called multiple times but will only change the
promise's state once (from `:pending`).

A key design choice is implemented here: if this function is called from a
background thread for a `:thread` promise, it does **not** settle the promise
directly. Instead, it dispatches a message via `loom-ipc` for the main
thread to perform the settlement. This centralizes all state transitions on
the main thread, eliminating a large class of potential race conditions.

Arguments:
- `PROMISE` (loom-promise): The promise to settle.
- `RESULT` (any): The resolution value (should be `nil` if rejecting).
- `ERROR` (loom-error): The rejection reason (should be `nil` if resolving).
- `IS-CANCELLATION` (boolean): `t` if this rejection is a cancellation.

Returns: The original `PROMISE`."
  (cl-block loom--settle-promise
    (unless (loom-promise-p promise)
      (error "Expected loom-promise, got: %S" promise))

    ;; **CRITICAL SECTION: Thread-Safety Delegation**
    ;; If we are in a background thread and the promise is a `:thread` promise,
    ;; we delegate the actual settlement to the main thread via IPC.
    ;; Process-mode promises are already handled on the main thread by the IPC
    ;; filter.
    (when (and (eq (loom-promise-mode promise) :thread)
               (fboundp 'make-thread)
               (not (equal (current-thread) (thread-main))))
      (let* ((id (loom-promise-id promise))
             (payload-data (if error `(:error ,error) `(:value ,result))))
        (loom-log :debug id
                  "In background thread; dispatching settlement to main thread.")
        (loom:dispatch-to-main-thread promise :promise-settled payload-data))
      ;; Immediately return the promise. The actual settlement will happen
      ;; later on the main thread, which will re-enter this function.
      (cl-return-from loom--settle-promise promise))

    ;; **MAIN THREAD SETTLEMENT LOGIC**
    ;; This code path is now only executed on the main thread.
    (let (settled-now callbacks-to-run (id (loom-promise-id promise)))
      (loom-log :debug id "Attempting to settle promise on main thread.")
      (loom:with-mutex! (loom-promise-lock promise)
        ;; Spec 2.1: A promise must be in one of three states.
        ;; This `when` block ensures it only transitions from :pending once.
        (when (eq (loom-promise-state promise) :pending)
          (setq settled-now t)
          (let ((new-state (if error :rejected :resolved)))
            ;; Spec 2.1.2 & 2.1.3: A promise, once settled, must not change state.
            ;; This is enforced by the surrounding `when (eq ... :pending)` check.
            (loom-log :info id "State transition: :pending -> %S" new-state)
            (setf (loom-promise-result promise) result
                  (loom-promise-error promise) error
                  (loom-promise-state promise) new-state
                  (loom-promise-cancelled-p promise) is-cancellation))
          ;; Spec 2.2.6: `then` may be called multiple times. We atomically
          ;; retrieve all queued callbacks and clear the list.
          (setq callbacks-to-run (nreverse (loom-promise-callbacks promise)))
          (setf (loom-promise-callbacks promise) nil)))

      ;; If we were the ones to settle the promise *just now*...
      (when settled-now
        (loom-log :debug id "Promise successfully settled. Dispatching callbacks.")
        ;; Spec 2.2.4: Handlers must run asynchronously. This function
        ;; schedules them on the appropriate queue (microtask/macrotask).
        (loom--schedule-or-dispatch-callbacks
         promise callbacks-to-run is-cancellation)
        (loom-registry-update-promise-state promise)))
    promise))

(defun loom--handle-unhandled-rejection (promise)
  "Handles a promise that was rejected without any attached error handlers.
This function is scheduled on the next scheduler tick *after* a rejection
occurs. This delay is crucial as it gives user code a chance to attach a
`.catch` or `.then(nil, on-reject)` handler before the rejection is
officially flagged as 'unhandled'.

Arguments:
- `PROMISE` (loom-promise): The rejected promise to check.

Returns: `nil`.

Signals:
- `loom-unhandled-rejection` if `loom-on-unhandled-rejection-action`
  is `'signal`."
  (let ((id (loom-promise-id promise)))
    (loom-log :debug id "Checking for unhandled rejection.")
    ;; Check if the promise is still rejected and if the registry confirms
    ;; that no downstream promise has an error handler.
    (when (and (eq (loom-promise-state promise) :rejected)
               (not (loom-registry-has-downstream-handlers-p promise)))
      (loom-log :warn id "Detected unhandled promise rejection!")
      (let ((error-obj (loom:error-value promise)))
        (condition-case err
            (pcase loom-on-unhandled-rejection-action
              ('log
               (loom-log :warn id "Unhandled Rejection: %S" error-obj))
              ('signal
               (signal 'loom-unhandled-rejection (list error-obj)))
              ((pred functionp)
               (funcall loom-on-unhandled-rejection-action error-obj)))
          (error
           (loom-log :error id
                     "Error occurred within custom unhandled rejection handler: %S"
                     err)))))))

(defun loom--setup-await-latch (promise timeout)
  "Creates and attaches a latch to a promise for use with `loom:await`.
This helper encapsulates the logic of creating a thread-safe latch,
attaching it to the promise as a high-priority callback, and setting up an
optional timeout timer that will \"race\" against the promise's settlement.

Arguments:
- `PROMISE` (loom-promise): The promise to be awaited.
- `TIMEOUT` (number or nil): The timeout duration in seconds.

Returns:
- (cons LATCH . TIMER): A cons cell where `LATCH` is a `loom-await-latch`
  and `TIMER` is a timer object (or nil if no timeout)."
  (let* ((id (loom-promise-id promise))
         (latch (%%make-await-latch :lock (loom:lock (format "latch-%S" id))))
         timer)
    ;; Attach a high-priority callback that will signal the latch upon settlement.
    ;; This callback simply flips the `signaled-p` flag to `t`.
    (loom-attach-callbacks
     promise
     (loom:callback (lambda ()
                      (loom:with-mutex! (loom-await-latch-lock latch)
                        (setf (loom-await-latch-signaled-p latch) t)))
                    :type :await-latch
                    :priority 0 ;; Highest priority
                    :promise-id id
                    :source-promise-id id))
    ;; If a timeout is specified, create a timer that will race the promise.
    (when timeout
      (setq timer
            (run-at-time timeout nil
                         (lambda ()
                           (loom:with-mutex! (loom-await-latch-lock latch)
                             ;; Only set the state to 'timeout if the promise
                             ;; hasn't already signaled completion.
                             (unless (loom-await-latch-signaled-p latch)
                               (loom-log :warn id "Await latch timed out.")
                               (setf (loom-await-latch-signaled-p latch)
                                     'timeout)))))))
    (cons latch timer)))

(defun loom--await-cooperative-blocking (promise timeout)
  "Cooperatively 'blocks' on the main thread until a promise settles.
This is the implementation of `loom:await`. It uses `loom:poll-with-backoff`
which repeatedly calls `sit-for` and runs the Loom scheduler. This keeps
the UI and other background tasks responsive while waiting. For promises
running in background threads, it also explicitly calls `thread-yield`.

Arguments:
- `PROMISE` (loom-promise): The promise to wait for.
- `TIMEOUT` (number or nil): The timeout duration in seconds.

Returns: The resolved value of the promise.
Signals: `loom-timeout-error` or `loom-await-error` on failure."
  (let* ((id (loom-promise-id promise))
         (latch-info (loom--setup-await-latch promise timeout))
         (latch (car latch-info))
         (timer (cdr latch-info))
         (is-thread-promise (and (eq (loom-promise-mode promise) :thread)
                                 (fboundp 'thread-yield))))
    (unwind-protect
        (progn
          (loom-log :debug id
                    "Await: Entering cooperative wait loop (timeout: %s)."
                    timeout)
          ;; The polling loop simply waits for the latch to be signaled by
          ;; either the promise's settlement callback or the timeout timer.
          (loom:poll-with-backoff
           (lambda ()
             ;; For thread promises, we explicitly yield to give the other
             ;; thread a chance to run. This is more robust than relying
             ;; solely on `sit-for`, which may not yield reliably.
             (when is-thread-promise
               (thread-yield))
             (loom-await-latch-signaled-p latch))
           :work-fn (lambda () (loom:scheduler-tick))
           :poll-interval loom-await-poll-interval
           :debug-id id)
          (loom-log :debug id "Await: Exited wait loop.")

          ;; After the loop exits, check the latch's final state to determine
          ;; the outcome.
          (cond
           ((eq (loom-await-latch-signaled-p latch) 'timeout)
            (signal 'loom-timeout-error
                    (list (format "Await timed out for %S" id))))
           ((loom:rejected-p promise)
            (signal 'loom-await-error (list (loom:error-value promise))))
           (t (loom:value promise))))
      ;; Cleanup: This runs regardless of how the block exits. It's crucial
      ;; to cancel the timer to prevent it from firing after we're done.
      (when timer (cancel-timer timer)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API (Package Private): Attaching/Executing Callbacks

(defun loom--execute-simple-callback (callback)
  "Executor for simple, nullary callbacks like `:await-latch` and `:finally`.
These callbacks do not receive the promise's result as an argument.

Arguments:
- `CALLBACK` (loom-callback): The callback to execute.

Returns: The result of the callback's handler function."
  (funcall (loom-callback-handler-fn callback)))

(defun loom--execute-resolution-callback (callback)
  "Executor for standard `:resolved` and `:rejected` callbacks.
These callbacks are part of a promise chain and their execution may settle
a downstream promise.

Arguments:
- `CALLBACK` (loom-callback): The callback to execute.

Returns: The result of the callback's handler function.
Signals: `error` if the source promise for the callback is missing."
  (let* ((data (loom-callback-data callback))
         (source-promise-id (plist-get data :source-promise-id))
         (target-promise-id (plist-get data :promise-id))
         (source-promise (loom-registry-get-promise-by-id source-promise-id))
         (target-promise (loom-registry-get-promise-by-id target-promise-id)))
    (unless source-promise
      (error "Loom internal error: Source promise %S not found in registry during callback execution"
             source-promise-id))

    (when target-promise
      ;; Determine the argument to pass to the handler function:
      ;; the resolution value for a `:resolved` callback, or the error
      ;; object for a `:rejected` callback.
      (let ((arg (if (loom:rejected-p source-promise)
                     (loom:error-value source-promise)
                   (loom:value source-promise))))
        ;; The handler function itself is responsible for settling the
        ;; target-promise.
        (funcall (loom-callback-handler-fn callback) target-promise arg)))))

(defun loom-execute-callback (callback)
  "Executes a stored callback, dispatching to the correct helper.
This function is the entry point called by the Loom schedulers (`microtask`
and `deferred`). It wraps the execution in a `condition-case` to catch
any errors that occur *within* a user-provided callback handler.

Arguments:
- `CALLBACK` (loom-callback): The callback struct to execute.

Returns: `nil`.

Side Effects:
- If the callback handler function itself signals an error, this function
  catches it and rejects the target promise of the callback."
  (let ((id (plist-get (loom-callback-data callback) :promise-id))
        (type (loom-callback-type callback)))
    (loom-log :debug id "Executing callback of type %S." type)
    (condition-case-unless-debug err
        (let ((handler-fn (loom-callback-handler-fn callback)))
          (unless (functionp handler-fn)
            (error "Invalid callback handler: %S" handler-fn))
          (pcase type
            ((or :await-latch :deferred :cancel :finally)
             (loom--execute-simple-callback callback))
            ((or :resolved :rejected)
             (loom--execute-resolution-callback callback))
            (_ (error "Unknown callback type: %S" type))))
      ;; If an error occurs inside the user's callback function...
      (error
       (let ((msg (format "Callback of type %S failed: %s" type
                          (error-message-string err))))
         (loom-log :error id "%s" msg)
         ;; ...we must reject the downstream promise to propagate the failure.
         (when-let ((promise (loom-registry-get-promise-by-id id)))
           (loom:reject promise (loom:make-error :type :callback-error
                                                 :message msg :cause err))))))))

(defun loom-attach-callbacks (promise &rest callbacks)
  "Attaches one or more `CALLBACKS` to a `PROMISE`.
This function implements the core logic of `.then`. If the promise is
still `:pending`, the callbacks are added to a list to be run later. If
the promise has *already* settled, the callbacks are scheduled for
asynchronous execution immediately.

Arguments:
- `PROMISE` (loom-promise): The promise to attach the callbacks to.
- `CALLBACKS` (list of `loom-callback`): A list of callback structs.

Returns: The original `PROMISE`."
  (let* ((id (loom-promise-id promise))
         (non-nil-callbacks (-filter #'identity callbacks)))
    (when non-nil-callbacks
      ;; Group the related callbacks into a single "link" for tracking.
      (let ((link (%%make-callback-link :id (gensym "link-")
                                        :callbacks non-nil-callbacks)))
        (loom-log :debug id "Attaching %d new callback(s)."
                  (length non-nil-callbacks))
        (loom:with-mutex! (loom-promise-lock promise)
          (if (eq (loom-promise-state promise) :pending)
              ;; If pending, just add the callbacks to the queue.
              (push link (loom-promise-callbacks promise))
            ;; If already settled, we can't just run the callbacks now.
            ;; We must schedule them asynchronously to conform to Promise/A+.
            (loom--trigger-callbacks-after-settle promise (list link)))))))
  promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Promise Creation & Management

(defun loom--promise-execute-executor (promise executor)
  "Internal helper to safely run a promise's executor function.
It wraps the execution in a `condition-case` so that if the executor
function itself throws a synchronous error, the newly created promise is
immediately rejected with that error.

Arguments:
- `PROMISE` (loom-promise): The new promise being constructed.
- `EXECUTOR` (function): The user-provided executor `(lambda (resolve reject) ...)`

Returns: `nil`."
  (let ((id (loom-promise-id promise)))
    (loom-log :debug id "Executing promise executor function.")
    (cl-letf (((symbol-value 'loom-current-async-stack)
               (cons (format "Executor (%S)" id) loom-current-async-stack)))
      (condition-case err
          ;; Call the executor with the resolve/reject functions bound to this
          ;; promise.
          (funcall executor
                   (lambda (v) (loom:resolve promise v))
                   (lambda (e) (loom:reject promise e)))
        ;; If the executor itself throws an error...
        (error
         (let ((msg (format "Promise executor function failed synchronously: %s"
                            (error-message-string err))))
           (loom-log :error id "%s" msg)
           ;; ...reject the promise with that error.
           (loom:reject promise (loom:make-error :type :executor-error
                                                 :message msg :cause err))))))))

;;;###autoload
(cl-defun loom:promise (&key executor (mode :deferred) name
                             parent-promise cancel-token tags)
  "Creates a new, pending `loom-promise`. This is the primary constructor.
If an `:executor` function `(lambda (resolve reject) ...)` is provided,
it is called immediately with two functions that control the promise's fate.

Arguments:
- `:EXECUTOR` (function, optional): The function that starts the async work.
- `:MODE` (symbol): Concurrency mode: `:deferred` (main thread),
  `:thread` (background thread), or `:process` (external process).
- `:NAME` (string, optional): A descriptive name for debugging and logging.
- `:PARENT-PROMISE` (loom-promise, internal): Used by `.then` to link promises.
- `:CANCEL-TOKEN` (loom-cancel-token, optional): A token for propagating
  cancellation.
- `:TAGS` (list, optional): A list of keyword symbols for categorization.

Returns: A new `loom-promise` in the `:pending` state."
  (let* ((promise-id (gensym (or name "promise-")))
         (promise (%%make-promise
                   :id promise-id
                   :mode mode
                   :lock (loom:lock (format "promise-%S" promise-id) :mode mode)
                   :tags (cl-delete-duplicates (ensure-list tags))
                   :cancel-token cancel-token)))
    (loom-log :info promise-id "Created new promise (mode: %s, name: %s)"
              mode (or name "unset"))
    (loom-registry-register-promise promise
                                    :parent-promise parent-promise
                                    :tags tags)

    ;; If a cancellation token is provided, register a callback to cancel this
    ;; promise if the token is triggered.
    (when cancel-token
      (loom-cancel-token-add-callback
       cancel-token (lambda (reason) (loom:cancel promise reason))))

    (when executor (loom--promise-execute-executor promise executor))
    promise))

;;;###autoload
(defun loom:resolve (promise value)
  "Resolves a `PROMISE` with `VALUE`, following the Promise/A+ resolution
procedure. This operation is idempotent: once a promise is settled, further
calls to `resolve` or `reject` are ignored.

If `VALUE` is itself a `loom-promise` (or an object normalizable to one),
`PROMISE` will \"adopt\" its state, eventually settling to the same outcome.

Arguments:
- `PROMISE` (loom-promise): The promise to resolve.
- `VALUE` (any): The value to resolve with.

Returns: The original `PROMISE`."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error (list "Expected a promise" promise)))
  (let ((id (loom-promise-id promise)))
    (loom-log :debug id "Resolve called with value of type %S." (type-of value))

    ;; Spec 2.3.1: A promise cannot be resolved with itself. This would
    ;; create an unresolvable cycle.
    (if (eq promise value)
        (loom:reject promise (loom:make-error :type :type-error
                                              :message "Promise resolution cycle detected."))
      ;; Check if the value is a promise or can be converted to one.
      (let ((normalized-value
             (if (loom-promise-p value) value
               (run-hook-with-args-until-success
                'loom-normalize-awaitable-hook value))))
        ;; Spec 2.3.2: If the value is a promise (a "thenable"), adopt its state.
        (if (loom-promise-p normalized-value)
            (let ((outer-promise promise))
              (loom-log :info id "Chaining to inner promise %S."
                        (loom-promise-id normalized-value))
              ;; Attach callbacks to the inner promise. When it settles, it
              ;; will in turn settle this outer promise with the same outcome.
              (loom-attach-callbacks
               normalized-value
               (loom:callback (lambda (_ res) (loom:resolve outer-promise res))
                              :type :resolved
                              :promise-id id
                              :source-promise-id
                              (loom-promise-id normalized-value))
               (loom:callback (lambda (_ err) (loom:reject outer-promise err))
                              :type :rejected
                              :promise-id id
                              :source-promise-id
                              (loom-promise-id normalized-value))))
          ;; Spec 2.3.4: If the value is a normal value, fulfill the promise
          ;; with it.
          (loom--settle-promise promise value nil nil)))))
  promise)

;;;###autoload
(defun loom:reject (promise error)
  "Rejects `PROMISE` with `ERROR`.
This operation is idempotent. If the provided `ERROR` is not already a
`loom-error` struct, it will be wrapped in one automatically.

Arguments:
- `PROMISE` (loom-promise): The promise to reject.
- `ERROR` (any): The reason for the rejection.

Returns: The original `PROMISE`."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error (list "Expected a promise" promise)))
  (let ((id (loom-promise-id promise)))
    (loom-log :debug id "Reject called.")
    ;; Normalize the error into a standard `loom-error` struct.
    ;; Check if the rejection is due to a cancellation signal.
    (let* ((is-cancellation (and (loom-error-p error)
                                 (eq (loom-error-type error) :cancel)))
           (final-error (if (loom-error-p error) error
                          (loom:make-error :type :rejection :cause error))))
      (loom--settle-promise promise nil final-error is-cancellation)))
  promise)

;;;###autoload
(defun loom:cancel (promise &optional reason)
  "Cancels a pending `PROMISE`.
This is a convenience function that rejects the promise with a special
`:cancel` error type. This allows `.catch` handlers to differentiate
between cancellations and other failures.

Arguments:
- `PROMISE` (loom-promise): The promise to cancel.
- `REASON` (string, optional): A descriptive message for the cancellation.

Returns: The original `PROMISE`."
  (when (loom:pending-p promise)
    (let ((msg (or reason "Promise cancelled without a specific reason.")))
      (loom-log :info (loom-promise-id promise) "Cancelling. Reason: %s" msg)
      (loom:reject promise (loom:make-error :type :cancel :message msg))))
  promise)

;;;###autoload
(defmacro loom:resolved! (value-form &rest keys)
  "Creates and returns a new promise that is already resolved.

Arguments:
- `VALUE-FORM`: A Lisp form that evaluates to the resolution value.
- `KEYS`: Keyword arguments to pass to `loom:promise` (e.g., `:name`, `:tags`).

Returns: A new promise in the `:resolved` state."
  (declare (indent 1) (debug t))
  `(let ((promise (apply #'loom:promise (list ,@keys))))
     (loom:resolve promise ,value-form)))

;;;###autoload
(defmacro loom:rejected! (error-form &rest keys)
  "Creates and returns a new promise that is already rejected.

Arguments:
- `ERROR-FORM`: A Lisp form that evaluates to the rejection reason.
- `KEYS`: Keyword arguments to pass to `loom:promise` (e.g., `:name`, `:tags`).

Returns: A new promise in the `:rejected` state."
  (declare (indent 1) (debug t))
  `(let ((promise (apply #'loom:promise (list ,@keys))))
     (loom:reject promise ,error-form)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Promise Status and Introspection

;;;###autoload
(defun loom:status (promise)
  "Returns the current state of a `PROMISE` without blocking.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns:
- (symbol): The state, one of `:pending`, `:resolved`, or `:rejected`.

Signals: `loom-type-error` if `PROMISE` is not a `loom-promise`."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error (list "Expected a promise" promise)))
  (loom-promise-state promise))

;;;###autoload
(defun loom:pending-p (promise)
  "Returns non-nil if `PROMISE` is in the `:pending` state.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns: `t` if pending, `nil` otherwise."
  (eq (loom:status promise) :pending))

;;;###autoload
(defun loom:resolved-p (promise)
  "Returns non-nil if `PROMISE` is in the `:resolved` state.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns: `t` if resolved, `nil` otherwise."
  (eq (loom:status promise) :resolved))

;;;###autoload
(defun loom:rejected-p (promise)
  "Returns non-nil if `PROMISE` is in the `:rejected` state.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns: `t` if rejected, `nil` otherwise."
  (eq (loom:status promise) :rejected))

;;;###autoload
(defun loom:cancelled-p (promise)
  "Returns non-nil if `PROMISE` was specifically cancelled.
This is a subset of `loom:rejected-p`.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns: `t` if cancelled, `nil` otherwise."
  (loom-promise-cancelled-p promise))

;;;###autoload
(defun loom:value (promise)
  "Returns the resolved value of `PROMISE`, or `nil` if not resolved.
This function is non-blocking. If the promise is pending or rejected, it
returns `nil`.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns: The resolved value, or `nil`."
  (when (loom:resolved-p promise)
    (loom-promise-result promise)))

;;;###autoload
(defun loom:error-value (promise)
  "Returns the rejection error of `PROMISE`, or `nil` if not rejected.
This function is non-blocking. If the promise is pending or resolved, it
returns `nil`.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns: The `loom-error` struct, or `nil`."
  (when (loom:rejected-p promise)
    (loom-promise-error promise)))

;;;###autoload
(defun loom:format-promise (promise)
  "Returns a human-readable string representation of a promise's state.

Arguments:
- `PROMISE` (loom-promise): The promise to format.

Returns: A descriptive string like `#<Promise my-task (promise-123)
:thread: resolved with ...>`."
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
                           (loom:error-message (loom:error-value promise))))))))

;;;###autoload
(defmacro loom:await (promise-form &optional timeout)
  "Synchronously and **cooperatively** waits for a promise to settle.
This macro blocks the current line of execution, but it does **not** freeze
Emacs. It enters a polling loop that keeps the UI responsive.

It can wait on a `loom-promise` or any other object that can be converted
to one via `loom-normalize-awaitable-hook`.

Arguments:
- `PROMISE-FORM`: A Lisp form that evaluates to a promise or awaitable object.
- `TIMEOUT` (number, optional): Max seconds to wait. Defaults to
  `loom-await-default-timeout`.

Returns: The resolved value of the promise.

Signals:
- `loom-await-error`: If the promise is rejected. The original error is the
  cause.
- `loom-timeout-error`: If the `TIMEOUT` is exceeded before the promise
  settles.
- `loom-type-error`: If `PROMISE-FORM` does not evaluate to a promise or
  an object that can be normalized into one."
  (declare (indent 1) (debug t))
  `(let* ((p-val ,promise-form)
          ;; Normalize the awaitable into a standard promise, if needed.
          (promise (if (loom-promise-p p-val) p-val
                     (run-hook-with-args-until-success
                      'loom-normalize-awaitable-hook p-val))))
     (unless (loom-promise-p promise)
       (signal 'loom-type-error
               (list "await expected a promise or awaitable object" p-val)))
     (let ((await-label (format "awaiting %S" (loom-promise-id promise))))
       ;; Add context to the async stack for debugging.
       (cl-letf (((symbol-value 'loom-current-async-stack)
                  (cons await-label loom-current-async-stack)))
         (loom--await-cooperative-blocking
          promise (or ,timeout loom-await-default-timeout))))))

(provide 'loom-promise)
;;; loom-promise.el ends here