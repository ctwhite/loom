;;; loom-promise.el --- Promise Data Structure and Core Operations -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file defines the fundamental `loom-promise` data structure and
;; the core operations for creating, resolving, and rejecting promises. It
;; implements the state machine, internal callback scheduling, and thread-safety
;; primitives directly related to a single promise's lifecycle.
;;
;; This separation from `loom-core.el` improves modularity and clarifies
;; responsibilities within the Concur library.
;;
;;; Code:

(require 'cl-lib)
(require 's) 
(require 'dash) 

(require 'loom-log)
(require 'loom-lock)
(require 'loom-registry)
(require 'loom-microtask)
(require 'loom-scheduler)
(require 'loom-errors)
(require 'loom-callback) 

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations 

(declare-function loom-cancel-token-p "loom-cancel")
(declare-function loom-cancel-token-add-callback "loom-cancel")
(declare-function loom--thread-callback-dispatcher "loom-core") 
(declare-function loom:deferred "loom-core") 

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
- `mode` (symbol): Concurrency mode (`:deferred` or `:thread`).
- `tags` (list): A list of keyword tags for filtering and categorization.
- `created-at` (float): The time (as a float, `float-time`) when the
  promise was created."
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

(cl-defstruct (loom-callback-link (:constructor %%make-callback-link)
                                    (:copier nil))
  "Groups related callbacks that are attached to a promise as a single unit.
This struct ensures that a set of callbacks (e.g., a resolve handler and
a reject handler originating from a single `.then` call) are processed
coherently.

Fields:
- `id` (symbol): A unique ID for debugging this specific callback link.
- `callbacks` (list): A list of `loom-callback` structs that are part
  of this link."
  (id nil :type symbol)
  (callbacks nil :type list))

(cl-defstruct (loom-await-latch (:constructor %%make-await-latch)
                                  (:copier nil))
  "Internal latch for the `loom:await` mechanism.
This struct acts as a shared flag between a waiting `loom:await` call
and the promise callback that signals completion. It allows `loom:await`
to cooperatively block until the promise it's waiting on settles.

Fields:
- `signaled-p` (boolean or `timeout`): The flag indicating completion.
  `t` if signaled by promise settlement, `nil` if still pending, or
  `'timeout` if the `loom:await` operation itself timed out.
- `cond-var` (condition-variable or nil): An optional condition variable
  used for efficient blocking in `:thread` mode promises, allowing threads
  to wait without busy-polling."
  (signaled-p nil)
  (cond-var nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Core Promise Lifecycle

(defun loom--kill-associated-process (promise)
  "Terminates any external process associated with a `PROMISE`.
If the `PROMISE` has an associated external process (e.g., one started
by `loom:process`), this function attempts to kill that process. This
is typically called when a promise is cancelled or otherwise settled
to clean up external resources.

Arguments:
- `PROMISE` (loom-promise): The promise whose associated process should
  be killed.

Returns:
- `nil`.

Side Effects:
- May kill an external Emacs process.
- Sets the `proc` field of `PROMISE` to `nil`."
  (when-let ((proc (loom-promise-proc promise)))
    (when (process-live-p proc)
      (loom-log :info (loom-promise-id promise)
                  "Killing associated process %S." proc)
      (ignore-errors (delete-process proc)))
    (setf (loom-promise-proc promise) nil)))

(defun loom--settle-promise (promise result error is-cancellation)
  "Settles a `PROMISE` to a resolved or rejected state.
This is the core, internal, and idempotent function responsible for
transitioning a promise from `:pending` to `:resolved` or `:rejected`.
It is thread-safe, protected by the promise's internal mutex.

Arguments:
- `PROMISE` (loom-promise): The promise to settle.
- `RESULT` (any): The value to resolve the promise with. This is `nil`
  if the promise is being rejected.
- `ERROR` (loom-error or nil): The error object to reject the promise
  with. This is `nil` if the promise is being resolved.
- `IS-CANCELLATION` (boolean): `t` if the settlement is due to a
  cancellation, `nil` otherwise.

Returns:
- (loom-promise): The original `PROMISE` object.

Side Effects:
- Acquires and releases `loom-lock` for `PROMISE`.
- Updates the promise's `state`, `result`, `error`, and `cancelled-p` fields.
- Clears the promise's `callbacks` list.
- Dispatches callbacks to the main thread (if in `:thread` mode) or
  schedules them for execution.
- Triggers cleanup of associated processes if `IS-CANCELLATION` is `t`.
- Updates the global promise registry for introspection tools."
  (unless (loom-promise-p promise)
    (error "Expected loom-promise, got: %S" promise))
  
  (let ((settled-now nil) (callbacks-to-run '()) (id (loom-promise-id promise)))
    (loom-log :debug id "Attempting to settle promise.")
    (loom:with-mutex! (loom-promise-lock promise)
      ;; Spec 2.1: A promise must be in one of three states.
      ;; Spec 2.1.2 & 2.1.3: It must not transition once fulfilled or rejected.
      (when (eq (loom-promise-state promise) :pending)
        (setq settled-now t)
        (let ((new-state (if error :rejected :resolved)))
          (loom-log :info id "State transition: :pending -> %S" new-state)
          (setf (loom-promise-result promise) result)
          (setf (loom-promise-error promise) error)
          (setf (loom-promise-state promise) new-state)
          (setf (loom-promise-cancelled-p promise) is-cancellation))
        ;; Spec 2.2.6: `then` may be called multiple times on the same promise.
        ;; Callbacks are executed in order of their originating calls to `then`.
        (setq callbacks-to-run (nreverse (loom-promise-callbacks promise)))
        (loom-log :debug id "Moving %d callback link(s) for execution."
                  (length callbacks-to-run))
        (setf (loom-promise-callbacks promise) nil)))

    (when settled-now
      (loom-log :debug id "Promise settled. Proceeding with callbacks.")
      ;; Spec 2.2.4: Handlers must be called after the execution context
      ;; stack contains only platform code. This is achieved by scheduling.
      (if (and (eq (loom-promise-mode promise) :thread)
               (fboundp 'make-thread)
               (fboundp 'main-thread)
               (not (equal (current-thread) (main-thread))))
          ;; If in a thread, dispatch to main thread for UI safety.
          (loom--thread-callback-dispatcher (loom-promise-id promise))
        ;; Otherwise, execute callbacks in the current context via schedulers.
        (progn
          (loom--trigger-callbacks-after-settle promise callbacks-to-run)
          (when is-cancellation (loom--kill-associated-process promise))))
      ;; Update the global registry for debugging tools.
      (when (fboundp 'loom-registry-update-promise-state)
        (loom-registry-update-promise-state promise))))
  promise)

(defun loom--handle-unhandled-rejection (promise)
  "Handles a promise that was rejected without any attached error handlers.
This function is scheduled to run on the next Emacs event loop tick after
a promise is rejected. This delay gives user code a chance to attach a
`.catch` handler before the rejection is considered 'unhandled'.

Arguments:
- `PROMISE` (loom-promise): The promise that may have an unhandled
  rejection.

Returns:
- `nil`.

Signals:
- `loom-unhandled-rejection`: If `loom-on-unhandled-rejection-action`
  is set to `'signal`.

Side Effects:
- May call a custom function defined by
  `loom-on-unhandled-rejection-action`."
  ;; This check happens on the next tick, giving user code a chance to attach
  ;; a `.catch` handler.
  (loom-log :debug (loom-promise-id promise) "Checking for unhandled rejection.")
  (when (and (eq (loom-promise-state promise) :rejected)
             (null (loom-promise-callbacks promise)) ; Should be empty now
             (not (loom-registry-has-downstream-handlers-p promise)))
    (loom-log :warn (loom-promise-id promise)
              "Detected unhandled rejection. Action: %S"
              loom-on-unhandled-rejection-action)
    (let ((error-obj (loom:error-value promise)))
      (condition-case err
          (pcase loom-on-unhandled-rejection-action
            ('log
             (loom-log :warn (loom-promise-id promise)
                       "Unhandled promise rejection: %S" error-obj))
            ('signal
             (signal 'loom-unhandled-rejection
                     (list (loom:error-message error-obj) error-obj)))
            ((pred functionp)
             (funcall loom-on-unhandled-rejection-action error-obj))
            (_ nil))
        (error
         (loom-log :error (loom-promise-id promise)
                   "Error in unhandled rejection handler: %S" err))))))

(defun loom--trigger-callbacks-after-settle (promise callback-links)
  "Schedules a promise's callbacks for execution after it has settled.

This function is central to Loom's asynchronous model. It ensures that
callbacks do not run in the same execution context as the resolving or
rejecting function, adhering to the Promise/A+ standard for predictable
and non-blocking behavior.

It inspects the promise's final state and schedules the appropriate
callbacks (e.g., for `.then` or `.catch`) on the correct queue. It also
ensures that special callbacks like `:finally` and `:await-latch` are
always scheduled to run, regardless of the promise's outcome.

Arguments:
- `PROMISE` (loom-promise): The promise that has settled.
- `CALLBACK-LINKS` (list): A list of `loom-callback-link` objects
  containing the callbacks to be processed.

Returns:
- `nil`.

Side Effects:
- Schedules high-priority callbacks on the `loom--microtask-scheduler`.
- Schedules low-priority callbacks on the `loom--macrotask-scheduler`.
- Schedules a final check for unhandled rejections if the promise
  was rejected."
  (let* ((id (loom-promise-id promise))
         (all-callbacks (-flatten (mapcar #'loom-callback-link-callbacks
                                          callback-links)))
         (state (loom-promise-state promise))
         (type-to-run (if (eq state :resolved) :resolved :rejected)))
    (loom-log :debug id "Triggering callbacks for %S state." state)
    ;; Filter for the correct handler type, plus any special-cased handlers
    ;; that must always run.
    (let ((callbacks-to-run
           (-filter (lambda (cb)
                      (let ((type (loom-callback-type cb)))
                        (or (eq type type-to-run)
                            ;; Always run :await-latch and :finally callbacks
                            ;; regardless of the settlement outcome.
                            (eq type :await-latch)
                            (eq type :finally))))
                    all-callbacks)))
      (loom-log :debug id "Found %d relevant callbacks to schedule."
                (length callbacks-to-run))
      ;; Partition callbacks into high-priority microtasks and lower-priority
      ;; macrotasks.
      (let ((microtasks '()) (macrotasks '()))
        (dolist (cb callbacks-to-run)
          ;; Promise handlers (`:resolved`, `:rejected`, `:finally`) and `await`
          ;; latches are treated as high-priority microtasks to ensure immediate
          ;; and responsive chaining.
          (if (memq (loom-callback-type cb)
                    '(:await-latch :resolved :rejected :finally))
              (push cb microtasks)
            (push cb macrotasks)))
        (when microtasks
          (loom-log :debug id "Scheduling %d microtask(s)."
                    (length microtasks))
          (loom:schedule-microtasks loom--microtask-scheduler
                                    (nreverse microtasks)))
        (when macrotasks
          (loom-log :debug id "Enqueuing %d macrotask(s)."
                    (length macrotasks))
          (dolist (cb (nreverse macrotasks))
            (loom:deferred loom--macrotask-scheduler cb))))))

  ;; If the promise was rejected, schedule a low-priority check to see if the
  ;; rejection was handled. This is done on the macrotask queue for
  ;; consistency with other deferred library tasks.
  (when (eq (loom-promise-state promise) :rejected)
    (loom-log :debug (loom-promise-id promise)
              "Scheduling unhandled rejection check.")
    ;; MODIFIED: Use the library's own macrotask scheduler.
    (loom:deferred (lambda () (loom--handle-unhandled-rejection promise)))))
    
(defun loom--execute-callback (callback)
  "Executes a stored callback with its source promise's result or error.
This function is called by the schedulers. It retrieves the source
and target promises from the registry by their IDs, then invokes
the handler closure with the appropriate arguments.

Arguments:
- `CALLBACK` (loom-callback): The callback struct to execute.

Returns:
- `nil`.

Signals:
- `error`: If `handler-fn` is not a function.
- Any error signaled by the `handler-fn` will cause the target promise
  to reject with a `:callback-error`.

Side Effects:
- Calls the `handler-fn` of the `CALLBACK`.
- May resolve or reject the target promise."
  (let* ((data (loom-callback-data callback))
         (target-promise-id (plist-get data :promise-id)))
    (loom-log :debug target-promise-id "Executing callback of type %S."
              (loom-callback-type callback))
    (condition-case-unless-debug err
        (let* ((handler-fn (loom-callback-handler-fn callback)))
          (unless (functionp handler-fn)
            (error "Invalid callback handler stored in promise: %S" handler-fn))

          (pcase (loom-callback-type callback)
            ;; Await latches and deferred tasks are simple nullary functions.
            ((or :await-latch :deferred :cancel)
             (funcall handler-fn))

            ;; For :resolved and :rejected handlers, they expect
            ;; target-promise and value/error.
            ((or :resolved :rejected)
             (let* ((source-promise-id (plist-get data :source-promise-id))
                    (source-promise (loom-registry-get-promise-by-id
                                     source-promise-id)))
               (unless source-promise
                 (error "Source promise %S not found in registry" source-promise-id))
               (let* ((arg-value (if (loom:rejected-p source-promise)
                                     (loom:error-value source-promise)
                                   (loom:value source-promise)))
                      (target-promise (loom-registry-get-promise-by-id
                                       target-promise-id)))
                 (when target-promise
                   (funcall handler-fn target-promise arg-value)))))

            ;; Handle unknown callback types explicitly
            (_
             (error "Unknown callback type: %S" (loom-callback-type callback)))))
      (error
       (let* ((err-msg (format "Callback failed: %s" (error-message-string err))))
         (loom-log :error target-promise-id "%s" err-msg)
         (when-let ((target-promise (loom-registry-get-promise-by-id
                                     target-promise-id)))
           (loom:reject target-promise
                        (loom:make-error :type :callback-error
                                         :message err-msg :cause err))))))))

(defun loom--await-blocking (promise timeout)
  "Cooperatively blocks execution until a promise settles or a timeout
occurs. This internal function is the core implementation of the
`loom:await` macro. It polls the promise's state using `sit-for` and
manages an optional timer to handle timeouts.

Arguments:
- `PROMISE` (loom-promise): The promise to wait for.
- `TIMEOUT` (number or nil): The maximum time in seconds to wait. If `nil`,
  it waits indefinitely.

Returns:
- (any): The resolved value of the `PROMISE`.

Signals:
- `loom-await-error`: If the `PROMISE` rejects.
- `loom-timeout-error`: If the `TIMEOUT` is exceeded before the promise
  settles.
- `loom-type-error`: If `PROMISE` is not a valid promise object (though
  this should ideally be caught by `loom:await` macro itself).

Side Effects:
- Attaches an `await-latch` callback to `PROMISE`.
- May schedule a timer using `run-at-time`.
- Calls `sit-for` to cooperatively block Emacs.
- May cancel the scheduled timer."
  (let ((id (loom-promise-id promise)))
    (cl-block loom--await-blocking
      (loom-log :debug id "Await: checking initial state.")
      (when (not (eq (loom:status promise) :pending))
        (if-let ((err (loom:error-value promise)))
            (signal 'loom-await-error (list err))
          (cl-return-from loom--await-blocking (loom:value promise))))

      (let ((latch (%%make-await-latch)) 
            (timer nil)
            (start-time (float-time)))
        (unwind-protect
            (progn
              ;; Attach a high-priority callback to the promise.
              (let* ((latch-fn
                      (lambda ()
                        (setf (loom-await-latch-signaled-p latch) t)
                        (when-let ((cv (loom-await-latch-cond-var latch)))
                          (condition-notify cv))))
                     (callback (loom:callback
                                latch-fn ; Handler function as first argument
                                :type :await-latch 
                                :priority 0
                                :promise-id id 
                                :source-promise-id id)))
                (loom-attach-callbacks promise callback))

              ;; Set up an optional timer to race against the promise settlement.
              (when timeout
                (setq timer
                      (run-at-time timeout nil
                                   (lambda ()
                                     (unless (loom-await-latch-signaled-p latch)
                                       (setf (loom-await-latch-signaled-p latch)
                                             'timeout))))))

              ;; Use cooperative polling (`sit-for`) to wait for the latch.
              (loom-log :debug id "Await: entering cooperative wait loop.")
              (let ((poll-count 0)
                    (last-log-time start-time))
                (while (not (loom-await-latch-signaled-p latch))
                  (condition-case err
                      (progn
                        ;; Drain microtasks completely first (higher priority)
                        (when loom--microtask-scheduler
                          (loom:drain-microtask-queue loom--microtask-scheduler))
                        
                        ;; Then drain macrotasks (lower priority, one at a time)
                        (when loom--macrotask-scheduler
                          (loom:scheduler-drain-once loom--macrotask-scheduler)))
                    (error
                     (loom-log :warning id "Error during queue draining: %S" err)))

                  ;; Check if promise settled during queue draining
                  (when (not (eq (loom:status promise) :pending))
                    (setf (loom-await-latch-signaled-p latch) t))

                  ;; Cooperative yield to Emacs
                  (sit-for loom-await-poll-interval)
                  
                  ;; Periodic logging with exponential backoff
                  (let ((current-time (float-time)))
                    (when (and (> (cl-incf poll-count) 50)
                               (> (- current-time last-log-time) 
                                  (* 2 (floor (log poll-count 2)))))
                      (loom-log :debug id "Await: still waiting after %d poll cycles (%.2fs elapsed)." 
                                poll-count (- current-time start-time))
                      (setq last-log-time current-time)))
                  
                  ;; Safety check for manual timeout (in case timer fails)
                  (when (and timeout 
                             (> (- (float-time) start-time) timeout)
                             (not (loom-await-latch-signaled-p latch)))
                    (loom-log :warning id "Manual timeout triggered after %.2fs" 
                              (- (float-time) start-time))
                    (setf (loom-await-latch-signaled-p latch) 'timeout))))
              
              (loom-log :debug id "Await: wait loop exited after %.2fs." 
                        (- (float-time) start-time))

              ;; Determine the final outcome.
              (cond
               ((eq (loom-await-latch-signaled-p latch) 'timeout)
                (signal 'loom-timeout-error
                        (list (format "Await timed out after %s seconds for %S"
                                      timeout (loom:format-promise promise)))))
               ((loom:rejected-p promise)
                (signal 'loom-await-error (list (loom:error-value promise))))
               (t (loom:value promise))))
          ;; Ensure the timer is cancelled, even if an error occurs.
          (when timer 
            (cancel-timer timer)
            (loom-log :debug id "Await: timer cancelled.")))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API (Package Private): Attaching Callbacks

(defun loom-attach-callbacks (promise &rest callbacks)
  "Attaches one or more `CALLBACKS` to a `PROMISE`.

If the `PROMISE` is still in the `:pending` state, the callbacks are
queued to be executed when the promise settles. If the `PROMISE` has
already settled (either `:resolved` or `:rejected`), the callbacks are
immediately scheduled for asynchronous execution.

This function groups related callbacks from a single `loom:then` or
similar operation into a `loom-callback-link` for coherent processing.

Arguments:
- `PROMISE` (loom-promise): The promise to which callbacks are attached.
- `CALLBACKS` (list of `loom-callback`): One or more `loom-callback`
  structures to attach. `nil` elements in this list are ignored.

Returns:
- (loom-promise): The original `PROMISE` object.

Side Effects:
- Acquires and releases `loom-lock` for `PROMISE`.
- Modifies the `callbacks` list of `PROMISE` if pending.
- Calls `loom--trigger-callbacks-after-settle` if `PROMISE` is settled."
  (let* ((id (loom-promise-id promise))
         (non-nil-callbacks (-filter #'identity callbacks)))
    (when non-nil-callbacks
      (let ((link (%%make-callback-link :id (gensym "link-")
                                        :callbacks non-nil-callbacks)))
        (loom-log :debug id "Attaching %d callback(s)." (length non-nil-callbacks))
        (loom:with-mutex! (loom-promise-lock promise)
          (if (eq (loom-promise-state promise) :pending)
              (progn
                (loom-log :debug id "Promise is pending, queuing callbacks.")
                (push link (loom-promise-callbacks promise)))
            ;; If already settled, schedule callbacks asynchronously now.
            (progn
              (loom-log :debug id "Promise already settled, scheduling immediately.")
              (loom--trigger-callbacks-after-settle promise (list link)))))))
  promise))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Promise Creation & Management

;;;###autoload
(cl-defun loom:promise (&key executor (mode :deferred) name cancel-token
                              parent-promise tags)
  "Creates a new, pending `loom-promise`.

If `:executor` is provided, it is a function `(lambda (resolve reject) ...)`
that is called immediately. The promise's fate is controlled by when the
`resolve` or `reject` functions are called.

Arguments:
- `:EXECUTOR` (function, optional): The function to execute.
- `:MODE` (symbol): Concurrency mode (`:deferred` or `:thread`).
- `:NAME` (string): A descriptive name for debugging.
- `:CANCEL-TOKEN` (loom-cancel-token): Optional token for cancellation.
- `:PARENT-PROMISE` (loom-promise, optional): The promise that created
  this one, for registry tracking.
- `:TAGS` (list or symbol, optional): Filter by a tag or list of tags. The
  promise must have at least one of the specified tags.  

Returns:
- (loom-promise): A new promise in the `:pending` state.

Signals:
- `error`: If the `EXECUTOR` function signals an error synchronously.

Side Effects:
- Creates a new `loom-promise` struct.
- Initializes an internal `loom-lock`.
- Registers the promise with the global registry (if enabled).
- Attaches a cancellation callback if `:CANCEL-TOKEN` is provided.
- Executes the `EXECUTOR` function immediately if provided."
  (let* ((promise-id (gensym (or name "promise-")))
         ;; Create the core promise struct with its unique ID, mode, and lock.
         ;; The lock's mode is explicitly set based on the promise's mode.
         (promise (%%make-promise
                   :id promise-id
                   :mode mode
                   :lock (loom:lock (format "promise-lock-%S" promise-id)
                                         :mode (if (eq mode :thread)
                                                   :thread
                                                 :deferred))
                   :tags (cl-delete-duplicates tags)                                                 
                   :cancel-token cancel-token)))
    (loom-log :info promise-id "Created new promise (mode: %s, name: %s)."
              mode (or name "unnamed"))

    ;; Register the promise with the global registry for introspection.
    (when (fboundp 'loom-registry-register-promise)
      (loom-registry-register-promise promise
                                      (or name (symbol-name promise-id))                                      
                                      :parent-promise parent-promise
                                      :tags tags))

    ;; If a cancel token is provided, attach a callback to cancel this promise
    ;; when the token is signaled.
    (when (and cancel-token (fboundp 'loom-cancel-token-add-callback))
      (loom-log :debug promise-id "Attaching cancellation callback.")
      (loom-cancel-token-add-callback
       cancel-token (lambda (reason) (loom:cancel promise reason))))

    ;; If an executor function is provided, execute it immediately.
    ;; The executor is responsible for eventually resolving or rejecting the promise.
    (when executor
      (let ((executor-label (format "Promise Executor (%S)" promise-id)))
        (loom-log :debug promise-id "Executing promise executor function.")
        ;; Rebind `loom-current-async-stack` to include the executor's context.
        ;; This helps in debugging asynchronous call chains.
        (cl-letf (((symbol-value 'loom-current-async-stack)
                   (cons executor-label loom-current-async-stack)))
          (condition-case err
              (funcall executor
                       (lambda (v)
                         (loom-log :debug promise-id "Executor resolving.")
                         (loom:resolve promise v))
                       (lambda (e)
                         (loom-log :debug promise-id "Executor rejecting.")
                         (loom:reject promise e)))
            (error
             (let ((error-msg (format "Promise executor failed: %s"
                                      ;; Prioritize loom-error messages
                                      (cond ((loom-error-p err) (loom:error-message err))
                                            ;; Fallback to standard Emacs error messages
                                            ((error-message-string err))
                                            ;; Last resort: format any Lisp object
                                            (t (format "%S" err))))))
               (loom-log :error promise-id "%s" error-msg)
               (loom:reject promise (loom:make-error
                                       :type :executor-error
                                       :message error-msg
                                       :cause err))))))))
    promise))

;;;###autoload
(defun loom:resolve (promise value)
  "Resolves a `PROMISE` with `VALUE` (implements Promises/A+ Spec 2.3).
If `VALUE` is a promise itself, `PROMISE` will adopt its state, effectively
chaining to it. This operation is idempotent.

Arguments:
- `PROMISE` (loom-promise): The promise to resolve.
- `VALUE` (any): The value to resolve with.

Returns:
- (loom-promise): The original `PROMISE`.

Signals:
- `loom-type-error`: If `PROMISE` is not a promise, or if `PROMISE`
  attempts to resolve with itself (a programming error).

Side Effects:
- Changes `PROMISE`'s state to `:resolved` (if pending).
- Sets `PROMISE`'s `result` field.
- Triggers execution of attached callbacks."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error (list "Expected a promise" promise)))
  (loom-log :debug (loom-promise-id promise)
            "Resolve called with value of type %S."
            (type-of value))
  ;; Spec 2.3.1: A promise cannot be resolved with itself.
  (if (eq promise value)
      (progn
        (loom-log :error (loom-promise-id promise)
                  "Attempted to resolve promise with itself (cycle).")
        (loom:reject
         promise (loom:make-error
                  :type :type-error
                  :message "Promise cannot resolve with itself: cycle detected.")))
    (let ((normalized-value
           (if (loom-promise-p value)
               value
             (run-hook-with-args-until-success
              'loom-normalize-awaitable-hook value))))
      ;; Spec 2.3.2: If value is a promise, adopt its state.
      (if (loom-promise-p normalized-value)
          (progn
            (loom-log :info (loom-promise-id promise)
                      "Chaining to promise %S (Spec 2.3.2)."
                      (loom-promise-id normalized-value))
            (loom-attach-callbacks
             normalized-value
             ;; on-resolved handler for the inner promise
             (loom:callback
              (lambda (target-promise res) ; Handler function as first argument
                ;; Recursively resolve the outer promise. This is safe because
                ;; `res` is guaranteed not to be a promise.
                (loom:resolve target-promise res))
              :type :resolved
              :promise-id (loom-promise-id promise)
              :source-promise-id (loom-promise-id normalized-value)))
             ;; on-rejected handler for the inner promise
             (loom:callback
              (lambda (target-promise err) ; Handler function as first argument
                ;; Reject the outer promise with the inner one's error.
                (loom:reject target-promise err))
              :type :rejected
              :promise-id (loom-promise-id promise)
              :source-promise-id (loom-promise-id normalized-value)))
        ;; Spec 2.3.4: If value is not a promise, fulfill with value.
        (progn
          (loom-log :debug (loom-promise-id promise)
                    "Resolving with final value.")
          (loom--settle-promise promise value nil nil)))))
  promise)

;;;###autoload
(defun loom:reject (promise error)
  "Rejects `PROMISE` with `ERROR`.
If `ERROR` is not already a `loom-error` struct, it will be wrapped in
one. This operation is idempotent.

Arguments:
- `PROMISE` (loom-promise): The promise to reject.
- `ERROR` (any): The reason for rejection.

Returns:
- (loom-promise): The original `PROMISE`.

Signals:
- `loom-type-error`: If `PROMISE` is not a promise.

Side Effects:
- Changes `PROMISE`'s state to `:rejected` (if pending).
- Sets `PROMISE`'s `error` field.
- Triggers execution of attached callbacks."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error (list "Expected a promise" promise)))
  (loom-log :debug (loom-promise-id promise)
            "Reject called with error of type %S."
            (type-of error))
  (let* ((is-cancellation (and (loom-error-p error)
                               (eq (loom-error-type error) :cancel)))
         (final-error (if (loom-error-p error) error
                        (loom:make-error 
                         :type :rejection
                         :message (format "%s" error)
                         :cause error))))
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
    (loom-log :info (loom-promise-id promise)
                "Cancelling (Reason: %s)." (or reason "N/A"))
    (loom:reject promise (loom:make-error
                            :type :cancel
                            :message (or reason "Promise cancelled"))))
  promise)

;;;###autoload
(defmacro loom:resolved! (value-form &rest keys)
  "Create a new promise that is already resolved with `VALUE-FORM`.

Arguments:
- `VALUE-FORM` (form): A Lisp form that evaluates to the value to resolve
  the promise with.
- `KEYS` (plist): Options for `loom:promise` (:mode, :name, etc.).

Returns:
- (loom-promise): A new promise in the `:resolved` state.

Signals:
- Any signals from `VALUE-FORM` during evaluation.
- Any signals from `loom:promise` or `loom:resolve`."
  `(let ((promise (apply #'loom:promise (list ,@keys))))
     (loom-log :info (loom-promise-id promise)
               "Creating pre-resolved promise.")
     (loom:resolve promise ,value-form)))

;;;###autoload
(defmacro loom:rejected! (error-form &rest keys)
  "Create a new promise that is already rejected with `ERROR-FORM`.

Arguments:
- `ERROR-FORM` (form): A Lisp form that evaluates to the reason for
  rejection.
- `KEYS` (plist): Options for `loom:promise` (:mode, :name, etc.).

Returns:
- (loom-promise): A new promise in the `:rejected` state.

Signals:
- Any signals from `ERROR-FORM` during evaluation.
- Any signals from `loom:promise` or `loom:reject`."
  `(let ((promise (apply #'loom:promise (list ,@keys))))
     (loom-log :info (loom-promise-id promise)
               "Creating pre-rejected promise.")
     (loom:reject promise ,error-form)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Promise Status and Introspection

;;;###autoload
(defun loom:status (promise)
  "Return the current state of a `PROMISE` without blocking.

Arguments:
- `PROMISE` (loom-promise): The promise to inspect.

Returns:
- (symbol): The state (`:pending`, `:resolved`, or `:rejected`)."
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
- (string): A descriptive string including its ID, name, mode, and state."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error (list "Expected a promise" promise)))
  (let* ((id (loom-promise-id promise))
         (mode (loom-promise-mode promise))
         (status (loom:status promise))
         (name (if (fboundp 'loom-registry-get-promise-name)
                   (loom-registry-get-promise-name promise (symbol-name id))
                 (symbol-name id))))
    (pcase status
      (:pending (format "#<Promise %s (%s) %s: pending>" name id mode))
      (:resolved
       (format "#<Promise %s (%s) %s: resolved with %s>" name id mode
               (s-truncate (or loom-log-value-max-length 50)
                           (format "%S" (loom:value promise)))))
      (:rejected
       (format "#<Promise %s (%s) %s: rejected with %s>" name id mode
               (s-truncate (or loom-log-value-max-length 50)
                           (loom:error-message promise)))))))

;;;###autoload
(defmacro loom:await (promise-form &optional timeout)
  "Synchronously and cooperatively wait for a promise to settle.
This function blocks the current execution cooperatively until the
promise is resolved or rejected, or a timeout occurs.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a `loom-promise`.
- `TIMEOUT` (number, optional): Seconds to wait before timing out. Defaults
  to `loom-await-default-timeout`.

Returns:
- (any): The resolved value of the promise.

Signals:
- `loom-await-error`: If the promise rejects.
- `loom-timeout-error`: If the timeout is exceeded.
- `loom-type-error`: If `PROMISE-FORM` doesn't yield a promise.

Side Effects:
- Evaluates `PROMISE-FORM`.
- Calls `loom--await-blocking`, which may attach callbacks, schedule
  timers, and cooperatively block Emacs.
- Modifies `loom-current-async-stack` for async context tracking."
  (declare (indent 1) (debug t))
  `(let* ((p-val ,promise-form)
          (promise (if (loom-promise-p p-val) 
                       p-val
                     (run-hook-with-args-until-success
                      'loom-normalize-awaitable-hook p-val))))
     (unless promise (setq promise p-val))
     (unless (loom-promise-p promise)
       (signal 'loom-type-error
               (list "await expected a promise or awaitable" promise)))
     (let ((await-label (format "awaiting %S" (loom-promise-id promise))))
       (cl-letf (((symbol-value 'loom-current-async-stack)
                  (cons await-label loom-current-async-stack)))
         (loom--await-blocking promise (or ,timeout
                                           loom-await-default-timeout))))))

(provide 'loom-promise)
;;; loom-promise.el ends here