;;; loom-combinators.el --- Functions for working with groups of promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides a suite of combinator functions and macros for managing
;; and coordinating groups of promises. These are the core tools for handling
;; parallel, concurrent, and sequential asynchronous operations. They allow
;; developers to compose complex asynchronous workflows from simpler promises.
;;
;; ## Core Features
;;
;; - **Parallel Execution:**
;;   - `loom:all` & `loom:all!`: Waits for all promises to resolve successfully.
;;     Rejects if any single promise rejects.
;;   - `loom:race` & `loom:race!`: Settles as soon as the first promise in a
;;     collection settles (resolves or rejects).
;;   - `loom:all-settled` & `loom:all-settled!`: Waits for every promise to
;;     settle, regardless of its outcome. Never rejects.
;;   - `loom:any` & `loom:any!`: Waits for the first promise to resolve
;;     successfully. Rejects only if *all* promises reject.
;;   - `loom:some`: Waits for a specific number of promises to fulfill.
;;
;; - **Collection Processing:**
;;   - `loom:map`: Applies an async function to a list in parallel.
;;   - `loom:filter`: Filters a list using an async predicate in parallel.
;;   - `loom:reduce`: Reduces a list with an async function sequentially.
;;   - `loom:map-series`: Applies an async function to a list sequentially.
;;
;; - **Timing and Control Flow:**
;;   - `loom:delay`: Creates a promise that resolves after a time delay.
;;   - `loom:timeout`: Wraps a promise with a time limit, rejecting if it's
;;     exceeded.
;;   - `loom:retry`: Automatically retries an async operation upon failure.

;;; Code:

(require 'cl-lib)

(require 'loom-errors)
(require 'loom-promise)
(require 'loom-primitives)
(require 'loom-cancel)
(require 'loom-semaphore)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--normalize-to-promise (value)
  "If VALUE is a `loom-promise`, return it. Otherwise, wrap it in a new,
already-resolved promise. This allows combinators to transparently handle
lists containing both promises and plain values."
  (if (loom-promise-p value)
      value
    (loom:resolved! value)))

(defun loom--validate-list (arg fn-name)
  "Signal a `loom-type-error` if `ARG` is not a list for `FN-NAME`."
  (unless (listp arg)
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "%s: Expected a list, got %S" fn-name arg))))))

(defun loom--validate-function (arg fn-name)
  "Signal a `loom-type-error` if `ARG` is not a function for `FN-NAME`."
  (unless (functionp arg)
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "%s: Expected a function, got %S" fn-name arg))))))

(defun loom--validate-semaphore (arg fn-name)
  "Signal a `loom-type-error` if `ARG` is not a `loom-semaphore` for `FN-NAME`."
  (unless (loom-semaphore-p arg)
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "%s: Expected a loom-semaphore, got %S"
                                    fn-name arg))))))

(defun loom--validate-positive-number (arg fn-name param-name)
  "Signal a `loom-type-error` if `ARG` is not a number > 0 for `FN-NAME`."
  (unless (and (numberp arg) (> arg 0))
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "%s: %s must be a positive number, got %S"
                                    fn-name param-name arg))))))

(defun loom--validate-non-negative-number (arg fn-name param-name)
  "Signal a `loom-type-error` if `ARG` is not a number >= 0 for `FN-NAME`."
  (unless (and (numberp arg) (>= arg 0))
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "%s: %s must be a non-negative number, got %S"
                                    fn-name param-name arg))))))

(defun loom--determine-strongest-mode (promises default-mode)
  "Determines the 'strongest' concurrency mode from a list of `PROMISES`.
The hierarchy is `:thread` > `:process` > `:deferred`. If any promise in
the list is `:thread` mode, the aggregate promise should also be `:thread`
mode to ensure its internal lock is thread-safe.

Returns: The strongest mode found, or `DEFAULT-MODE` if none are stronger."
  (if (cl-some (lambda (p)
                 (and (loom-promise-p p)
                      (eq (loom-promise-mode p) :thread)))
               promises)
      :thread
    default-mode))

(defun loom--wrap-with-semaphore (awaitables semaphore)
  "Wraps each awaitable in `AWAITABLES` with semaphore acquisition/release
logic. This is a helper for combinators that support a `:semaphore` argument
to limit concurrency. Each returned promise represents a task that will:
1. First, acquire a permit from the `SEMAPHORE` (this may block).
2. Once acquired, execute the original awaitable.
3. Finally, release the permit back to the semaphore, regardless of whether
   the awaitable succeeded or failed.

Arguments:
- `AWAITABLES` (list): A list of promises or values.
- `SEMAPHORE` (loom-semaphore): The semaphore to use for throttling.

Returns: A new list of promises, each wrapped in semaphore logic."
  (mapcar (lambda (awaitable)
            (loom:then (loom:semaphore-acquire semaphore)
                       (lambda (_)
                         (loom:finally (loom--normalize-to-promise awaitable)
                                       (lambda ()
                                         (loom:semaphore-release semaphore))))))
          awaitables))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Combinators

;;;###autoload
(cl-defun loom:all (promises &key mode semaphore)
  "Returns a promise that resolves when all input `PROMISES` resolve.

The returned promise resolves to a list of the resolved values, maintaining
the same order as the input list. If any promise in the list rejects, the
returned promise rejects *immediately* with that first error, and the results
of other promises are discarded. Non-promise values in the list are treated
as already-resolved promises.

Arguments:
- `PROMISES` (list): A list of promises or plain values.
- `:mode` (keyword, optional): The concurrency mode (`:thread` or `:deferred`)
  for the returned aggregate promise. Defaults to the strongest mode found
  in the input promises.
- `:semaphore` (loom-semaphore, optional): If provided, limits how many of
  the input promises can run concurrently.

Returns:
- (loom-promise): A new promise that resolves with a list of all values.

Signals: `loom-type-error` for invalid arguments."
  (loom--validate-list promises 'loom:all)
  (when semaphore (loom--validate-semaphore semaphore 'loom:all))

  ;; Normalize all items to promises, wrapping with semaphore logic if needed.
  (let ((processed-promises
         (if semaphore
             (loom--wrap-with-semaphore promises semaphore)
           (mapcar #'loom--normalize-to-promise promises))))
    ;; Handle the edge case of an empty input list.
    (if (null processed-promises)
        (loom:resolved! '())
      (let* ((len (length processed-promises))
             (results (make-vector len nil))
             (mode (or mode
                       (loom--determine-strongest-mode processed-promises
                                                       :deferred)))
             (agg-promise (loom:promise :mode mode :name "loom:all"))
             (resolved-count 0)
             (lock (loom:lock "loom-all-lock" :mode mode)))
        (loom-log :debug (loom-promise-id agg-promise)
                  "Waiting for %d promises." len)

        (dotimes (i len)
          (let ((index i) ; Explicitly capture the index for this iteration's closure.
                (p (nth i processed-promises)))
            (loom:then p
              ;; on-resolved: Store result and check if all have resolved.
              (lambda (res)
                (loom:with-mutex! lock
                  (when (loom:pending-p agg-promise)
                    (aset results index res)
                    (cl-incf resolved-count)
                    (when (= resolved-count len)
                      (loom-log :debug (loom-promise-id agg-promise)
                                "All promises resolved.")
                      (loom:resolve agg-promise (cl-coerce results 'list))))))
              ;; on-rejected: Immediately reject the aggregate promise.
              (lambda (err)
                (loom:with-mutex! lock
                  (when (loom:pending-p agg-promise)
                    (loom-log :debug (loom-promise-id agg-promise)
                              "A promise rejected; rejecting all.")
                    (loom:reject agg-promise err)))))))
        agg-promise))))

;;;###autoload
(cl-defun loom:all-settled (promises &key mode semaphore)
  "Returns a promise that resolves after all input `PROMISES` have settled.

This function is useful when you need to wait for a group of independent
async operations to complete, regardless of whether they succeed or fail.
The returned promise itself will **never reject**. Its resolved value is a
list of \"outcome\" plists, each describing the result of one input promise.

Arguments:
- `PROMISES` (list): A list of promises or plain values.
- `:mode` (keyword, optional): The concurrency mode for the returned promise.
- `:semaphore` (loom-semaphore, optional): Limits concurrency.

Returns:
- (loom-promise): A promise that resolves to a list of outcome plists.
  Each plist is `(:status 'fulfilled :value VAL)` or
  `(:status 'rejected :reason ERR)`.

Signals: `loom-type-error` for invalid arguments."
  (loom--validate-list promises 'loom:all-settled)
  (when semaphore (loom--validate-semaphore semaphore 'loom:all-settled))

  (let* ((processed-promises
          (if semaphore
              (loom--wrap-with-semaphore promises semaphore)
            (mapcar #'loom--normalize-to-promise promises))))
    (if (null processed-promises)
        (loom:resolved! '())
      (let* ((len (length processed-promises))
             (outcomes (make-vector len nil))
             (mode (or mode
                       (loom--determine-strongest-mode processed-promises
                                                       :deferred)))
             (agg-promise (loom:promise :mode mode :name "loom:all-settled"))
             (settled-count 0)
             (lock (loom:lock "all-settled-lock" :mode mode)))
        (loom-log :debug (loom-promise-id agg-promise)
                  "Waiting for %d promises to settle." len)

        (dotimes (i len)
          (let ((index i)
                (promise (nth i processed-promises)))
            (loom:finally
             promise
             (lambda ()
               (loom:with-mutex! lock
                 (when (loom:pending-p agg-promise)
                   ;; Record the outcome, whether fulfilled or rejected.
                   (aset outcomes index
                         (if (loom:rejected-p promise)
                             ;; **FIX:** Extract the message string from the error struct.
                             (list :status 'rejected :reason
                                   (loom:error-message (loom:error-value promise)))
                           (list :status 'fulfilled :value
                                 (loom:value promise))))
                   (cl-incf settled-count)
                   (when (= settled-count len)
                     (loom-log :debug (loom-promise-id agg-promise)
                               "All promises have settled.")
                     (loom:resolve agg-promise (cl-coerce outcomes 'list)))))))))
        agg-promise))))

;;;###autoload
(cl-defun loom:race (promises &key mode semaphore)
  "Returns a promise that settles with the outcome of the first promise to
settle.

\"Settling\" means either resolving or rejecting. As soon as any promise in
`PROMISES` settles, the returned promise adopts that same outcome and its
state is locked.

Arguments:
- `PROMISES` (list): A list of promises or plain values.
- `:mode` (keyword, optional): The concurrency mode for the returned promise.
- `:semaphore` (loom-semaphore, optional): Limits how many promises can
  start and be considered in the race concurrently.

Returns:
- (loom-promise): A promise that settles with the first outcome from the list.

Signals: `loom-type-error` if `PROMISES` is not a list, is empty, or for
  other invalid arguments."
  (loom--validate-list promises 'loom:race)
  (when (null promises)
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message "loom:race requires a non-empty list of promises"))))
  (when semaphore (loom--validate-semaphore semaphore 'loom:race))

  (let* ((processed-promises
          (if semaphore
              (loom--wrap-with-semaphore promises semaphore)
            (mapcar #'loom--normalize-to-promise promises))))
    (let* ((mode (or mode
                       (loom--determine-strongest-mode processed-promises
                                                       :deferred)))
           (race-promise (loom:promise :mode mode :name "loom:race"))
           (lock (loom:lock "loom-race-lock" :mode mode)))
      (loom-log :debug (loom-promise-id race-promise)
                "Racing %d promises." (length processed-promises))
      (dolist (p processed-promises)
        (loom:then p
          ;; on-resolved: First one to resolve wins the race.
          (lambda (res)
            (loom:with-mutex! lock
              (when (loom:pending-p race-promise)
                (loom-log :debug (loom-promise-id race-promise)
                          "Race won by a resolving promise.")
                (loom:resolve race-promise res))))
          ;; on-rejected: First one to reject also wins the race.
          (lambda (err)
            (loom:with-mutex! lock
              (when (loom:pending-p race-promise)
                (loom-log :debug (loom-promise-id race-promise)
                          "Race won by a rejecting promise.")
                (loom:reject race-promise err))))))
      race-promise)))

;;;###autoload
(cl-defun loom:any (promises &key mode semaphore)
  "Returns a promise that resolves with the first fulfilled promise from the
list.

If all promises in `PROMISES` reject, the returned promise also rejects, but
with a special `:aggregate-error` whose `:cause` is a list of all the
individual rejection reasons.

Arguments:
- `PROMISES` (list): A list of promises or plain values.
- `:mode` (keyword, optional): The concurrency mode for the returned promise.
- `:semaphore` (loom-semaphore, optional): Limits concurrency.

Returns: A new promise that resolves with the first successful value.
Signals: `loom-type-error` for invalid arguments."
  (loom--validate-list promises 'loom:any)
  (when semaphore (loom--validate-semaphore semaphore 'loom:any))

  (let* ((processed-promises
          (if semaphore
              (loom--wrap-with-semaphore promises semaphore)
            (mapcar #'loom--normalize-to-promise promises))))
    ;; Handle the edge case of an empty input list.
    (if (null processed-promises)
        (loom:rejected!
         (loom:make-error :type :aggregate-error
                          :message "No promises provided to `loom:any`."))
      (let* ((len (length processed-promises))
             (errors (make-vector len nil))
             (mode (or mode
                       (loom--determine-strongest-mode processed-promises
                                                       :deferred)))
             (any-promise (loom:promise :mode mode :name "loom:any"))
             (rejected-count 0)
             (lock (loom:lock "loom-any-lock" :mode mode)))
        (loom-log :debug (loom-promise-id any-promise)
                  "Waiting for any of %d promises to fulfill." len)

        (dotimes (i len)
          (let ((index i)
                (p (nth i processed-promises)))
            (loom:then p
              ;; on-resolved: The first promise to fulfill wins.
              (lambda (res)
                (loom:with-mutex! lock
                  (when (loom:pending-p any-promise)
                    (loom-log :debug (loom-promise-id any-promise)
                              "A promise fulfilled; resolving.")
                    (loom:resolve any-promise res))))
              ;; on-rejected: Store the error and check if all have failed.
              (lambda (_err)
                (loom:with-mutex! lock
                  (when (loom:pending-p any-promise)
                    ;; We explicitly get the error value from the promise `p`
                    ;; that we know has just rejected. This is robust.
                    (aset errors index (loom:error-value p))
                    (cl-incf rejected-count)
                    (when (= rejected-count len)
                      (loom-log :debug (loom-promise-id any-promise)
                                "All promises rejected; rejecting.")
                      (loom:reject
                       any-promise
                       (loom:make-error
                        :type :aggregate-error
                        :message "All promises were rejected."
                        :cause (cl-coerce errors 'list))))))))))
        any-promise))))

;;;###autoload
(cl-defun loom:some (promises &key (count 1) mode semaphore)
  "Returns a promise that resolves when `COUNT` promises from `PROMISES`
fulfill.

The returned promise resolves with a list of the first `COUNT` values that
become available. If it becomes impossible for `COUNT` promises to fulfill
(i.e., too many have rejected), the returned promise rejects with an
`:insufficient-fulfillments` error.

Arguments:
- `PROMISES` (list): A list of promises or plain values.
- `:count` (integer): Number of promises that must fulfill (default 1).
- `:mode` (keyword, optional): The concurrency mode for the returned promise.
- `:semaphore` (loom-semaphore, optional): Limits concurrency.

Returns:
- (loom-promise): A promise that resolves with a list of the first `COUNT`
  fulfilled values, or rejects if this becomes impossible.

Signals: `loom-type-error` for invalid arguments."
  (loom--validate-list promises 'loom:some)
  (loom--validate-positive-number count 'loom:some ":count")
  (when semaphore (loom--validate-semaphore semaphore 'loom:some))

  (let* ((processed-promises
          (if semaphore
              (loom--wrap-with-semaphore promises semaphore)
            (mapcar #'loom--normalize-to-promise promises))))
    (if (< (length processed-promises) count)
        (loom:rejected!
         (loom:make-error
          :type :insufficient-promises
          :message (format "loom:some: Need at least %d promises, but only %d provided"
                           count (length processed-promises))))
      (let* ((len (length processed-promises))
             (results '())
             (errors '())
             (mode (or mode
                       (loom--determine-strongest-mode processed-promises
                                                       :deferred)))
             (some-promise (loom:promise :mode mode :name "loom:some"))
             (fulfilled-count 0)
             (rejected-count 0)
             (lock (loom:lock "loom-some-lock" :mode mode)))
        (loom-log :debug (loom-promise-id some-promise)
                  "Waiting for %d of %d promises to fulfill." count len)

        (dolist (p processed-promises)
          (loom:then p
            ;; on-resolved: Collect result and check if we have enough.
            (lambda (res)
              (loom:with-mutex! lock
                (when (loom:pending-p some-promise)
                  (push res results)
                  (cl-incf fulfilled-count)
                  (when (= fulfilled-count count)
                    (loom-log :debug (loom-promise-id some-promise)
                              "Required count of %d fulfilled." count)
                    (loom:resolve some-promise (nreverse results))))))
            ;; on-rejected: Collect error and check if goal is now impossible.
            (lambda (err)
              (loom:with-mutex! lock
                (when (loom:pending-p some-promise)
                  (push err errors)
                  (cl-incf rejected-count)
                  ;; Check if the number of remaining promises is less than
                  ;; the number we still need to fulfill.
                  (when (> rejected-count (- len count))
                    (loom-log :debug (loom-promise-id some-promise)
                              "Cannot fulfill required count; rejecting.")
                    (loom:reject
                     some-promise
                     (loom:make-error
                      :type :insufficient-fulfillments
                      :message (format "loom:some: Cannot fulfill %d promises."
                                       count)
                      :cause (nreverse errors)))))))))
        some-promise))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Collection Combinators

;;;###autoload
(cl-defun loom:map (items fn &key semaphore)
  "Maps a synchronous or asynchronous function `FN` over `ITEMS` in parallel.

All calls to `FN` are initiated concurrently (up to the limit imposed by
the `:semaphore`, if any). The returned promise resolves with a list of
results in the same order as the input `ITEMS`. If any call to `FN` returns
a promise that rejects, the entire operation rejects.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): A function `(lambda (item))` that can return either a
  direct value or a promise.
- `:semaphore` (loom-semaphore, optional): Limits concurrency.

Returns:
- (loom-promise): A promise that resolves with a new list of the results.

Signals: `loom-type-error` for invalid arguments."
  (loom--validate-list items 'loom:map)
  (loom--validate-function fn 'loom:map)
  (when semaphore (loom--validate-semaphore semaphore 'loom:map))

  ;; `loom:map` is a composition of `mapcar` and `loom:all`.
  ;; First, create a list of promises by applying `fn` to each item.
  (let ((promises (mapcar (lambda (item)
                            (loom--normalize-to-promise (funcall fn item)))
                          items)))
    ;; Then, wait for all of those promises to complete.
    (loom:all promises :semaphore semaphore)))

;;;###autoload
(cl-defun loom:filter (items predicate &key semaphore)
  "Filters `ITEMS` asynchronously using `PREDICATE` in parallel.

All calls to `PREDICATE` are initiated concurrently. The returned promise
resolves with a new list containing only the items for which `PREDICATE`
returned a truthy value.

Arguments:
- `ITEMS` (list): The list of items to filter.
- `PREDICATE` (function): A function `(lambda (item))` that returns a
  boolean or a promise resolving to a boolean.
- `:semaphore` (loom-semaphore, optional): Limits concurrency.

Returns:
- (loom-promise): A promise that resolves with the filtered list.

Signals: `loom-type-error` for invalid arguments."
  (loom--validate-list items 'loom:filter)
  (loom--validate-function predicate 'loom:filter)
  (when semaphore (loom--validate-semaphore semaphore 'loom:filter))

  (loom:then
   ;; Step 1: Create a list of promises, where each promise resolves to
   ;; a pair: `(item keep?)`.
   (loom:all
    (mapcar (lambda (item)
              (loom:then (loom--normalize-to-promise (funcall predicate item))
                         (lambda (keep)
                           (list item keep))))
            items)
    :semaphore semaphore)
   ;; Step 2: Once all pairs are computed, filter them and extract the items.
   (lambda (results)
     (mapcar #'car (cl-remove-if-not #'cadr results)))))

;;;###autoload
(defun loom:reduce (items fn initial-value)
  "Asynchronously reduces `ITEMS` to a single value using `FN`, sequentially.

Unlike `loom:map`, this function applies `FN` to each item in series,
waiting for the promise from one step to complete before starting the next.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): The reducer `(lambda (accumulator item))` which can
  return either a direct value or a promise.
- `INITIAL-VALUE` (any): The initial value for the accumulator.

Returns:
- (loom-promise): A promise that resolves with the final accumulated value.

Signals: `loom-type-error` for invalid arguments."
  (loom--validate-list items 'loom:reduce)
  (loom--validate-function fn 'loom:reduce)
  ;; `cl-reduce` is used to build a sequential chain of promises.
  (cl-reduce
   (lambda (acc-promise item)
     ;; Chain the next operation onto the promise for the previous accumulation.
     (loom:then acc-promise
                (lambda (current-acc)
                  (loom--normalize-to-promise (funcall fn current-acc item)))))
   items
   :initial-value (loom--normalize-to-promise initial-value)))

;;;###autoload
(defun loom:map-series (items fn)
  "Maps a synchronous or asynchronous function `FN` over `ITEMS` sequentially.

Each item is passed to `FN` only after the promise returned for the
previous item has completed.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): A function `(lambda (item))` that can return
  either a direct value or a promise.

Returns:
- (loom-promise): A promise that resolves with a new list containing the
  results.

Signals: `loom-type-error` for invalid arguments."
  (loom--validate-list items 'loom:map-series)
  (loom--validate-function fn 'loom:map-series)
  ;; Implemented via `loom:reduce`. The accumulator builds a list of results
  ;; in reverse order, which is then reversed at the end.
  (loom:then
   (loom:reduce
    items
    (lambda (acc item)
      (loom:then (loom--normalize-to-promise (funcall fn item))
                 (lambda (result)
                   (cons result acc))))
    '())
   #'nreverse))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Timing Utilities

;;;###autoload
(defmacro loom:delay (seconds &optional value-or-form)
  "Returns a promise that resolves after `SECONDS` have passed.

The resolution value is the result of evaluating `VALUE-OR-FORM` *after* the
delay. If `VALUE-OR-FORM` is an error-signaling form, its evaluation will
cause the promise to reject.

Arguments:
- `SECONDS` (number): The delay duration in seconds. Must be non-negative.
- `VALUE-OR-FORM` (any, optional): A form to evaluate to get the value.
  Defaults to `t`.

Returns:
- (loom-promise): A promise that fulfills or rejects after the delay.

Signals: `loom-type-error` if `SECONDS` is not a non-negative number."
  (declare (indent 1))
  `(let ((secs ,seconds))
     (loom--validate-non-negative-number secs 'loom:delay "SECONDS")
     (loom:promise
      :name (format "delay-%.2fs" secs)
      :executor
      (lambda (resolve reject)
        ;; `run-at-time` schedules a function on the main Emacs event loop.
        (message "calling run-at-time: %s" resolve)
        (run-at-time secs nil
                     (lambda ()
                       (condition-case err
                           ;; This inner lambda wrapper is crucial. It ensures
                           ;; `value-or-form` is not evaluated until the timer
                           ;; actually fires.
                           (funcall resolve (funcall (lambda ()
                                                       ,(or value-or-form t))))
                         ;; If evaluating the form signals an error, reject the
                         ;; promise.
                         (error
                         (message "rejecting error..............")
                         (message "calling reject: %s" err)
                         (message "calling reject: %s" reject)     
                          (funcall reject err)))))))))

;;;###autoload
(defun loom:timeout (promise timeout-seconds)
  "Returns a promise that rejects if `PROMISE` does not settle within a time
limit.

This function creates a race between the input `PROMISE` and a timer promise.
- If `PROMISE` resolves or rejects first, its outcome is passed through.
- If the timer finishes first, the returned promise rejects with a `:timeout`
  error.

Arguments:
- `PROMISE` (loom-promise): The promise to apply the timeout to.
- `TIMEOUT-SECONDS` (number): The timeout duration in seconds.

Returns:
- (loom-promise): A new promise with the timeout behavior.

Signals: `loom-type-error` for invalid arguments."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "loom:timeout: Expected a promise, got %S"
                                    promise)))))
  (loom--validate-positive-number timeout-seconds 'loom:timeout
                                  "TIMEOUT-SECONDS")

  ;; The implementation is a simple race between the original promise
  ;; and a new promise that rejects after the timeout.
  (loom:race
   (list
    promise
    (loom:then (loom:delay timeout-seconds)
               (lambda (_)
                 (loom:rejected!
                  (loom:make-error
                   :type :timeout
                   :message (format "Operation timed out after %.3fs"
                                    timeout-seconds))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Retry Utilities

;;;###autoload
(cl-defun loom:retry (fn &key (retries 3) (delay 0.1) (pred #'identity))
  "Retries an asynchronous function `FN` upon failure.

Arguments:
- `FN` (function): A zero-argument function that returns a promise.
- `:retries` (integer): Maximum number of attempts (default 3, minimum 1).
- `:delay` (number|function): Time to wait between retries. Can be a
  fixed number of seconds, or a function `(lambda (attempt-num error))` that
  returns a delay in seconds, allowing for exponential backoff etc.
- `:pred` (function): A predicate `(lambda (error))` called upon failure.
  A retry is only attempted if this function returns a non-nil value. This
  can be used to avoid retrying on certain types of errors.

Returns:
- (loom-promise): A promise that resolves with the first successful
  result, or rejects with the last error if all retries fail.

Signals: `loom-type-error` for invalid arguments."
  (loom--validate-function fn 'loom:retry)
  (unless (and (integerp retries) (>= retries 1))
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "loom:retry: :retries must be an integer >= 1, got %S"
                                    retries)))))
  (unless (or (numberp delay) (functionp delay))
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "loom:retry: :delay must be a number or function, got %S"
                                    delay)))))
  (loom--validate-function pred 'loom:retry)

  (loom:promise
   :name "loom:retry"
   :executor
   (lambda (resolve reject)
     (let ((attempt 0))
       (cl-labels
           ((try-once ()
              (cl-incf attempt)
              (loom-log :debug nil "loom:retry: attempt #%d" attempt)
              (loom:then
               ;; Call the user's async function.
               (funcall fn)
               ;; If it resolves, the whole retry promise resolves.
               resolve
               ;; If it rejects...
               (lambda (error)
                 ;; ...check if we should try again.
                 (if (and (< attempt retries) (funcall pred error))
                     ;; If so, calculate delay and schedule the next attempt.
                     (let* ((delay-sec (if (functionp delay)
                                           (funcall delay attempt error)
                                         delay)))
                       (loom-log :debug nil
                                 "loom:retry: attempt failed, retrying in %.2fs"
                                 delay-sec)
                       (loom:then (loom:delay delay-sec) #'try-once))
                   ;; Otherwise, all retries are exhausted; reject with the
                   ;; final error.
                   (loom-log :warn nil "loom:retry: all attempts failed, rejecting.")
                   (funcall reject error))))))
         ;; Start the first attempt.
         (try-once))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Convenience Macros

;;;###autoload
(defmacro loom:all! (&rest promises)
  "Resolves all `PROMISES` in parallel. A convenience wrapper for `loom:all`.

Arguments:
- `PROMISES`: A list of promise-producing forms.

Returns:
- (loom-promise): A promise that resolves to a list of all results."
  (declare (indent 1) (debug (&rest form)))
  `(loom:all (list ,@promises)))

;;;###autoload
(defmacro loom:race! (&rest promises)
  "Races all `PROMISES`. A convenience wrapper for `loom:race`.

Arguments:
- `PROMISES`: A list of promise-producing forms.

Returns:
- (loom-promise): A promise that settles with the outcome of the first
  promise in the list to settle."
  (declare (indent 1) (debug (&rest form)))
  `(loom:race (list ,@promises)))

;;;###autoload
(defmacro loom:all-settled! (&rest promises)
  "Waits for all `PROMISES` to settle. A convenience wrapper for `loom:all-settled`.

Arguments:
- `PROMISES`: A list of promise-producing forms.

Returns:
- (loom-promise): A promise that resolves to a list of result plists."
  (declare (indent 1) (debug (&rest form)))
  `(loom:all-settled (list ,@promises)))

;;;###autoload
(defmacro loom:any! (&rest promises)
  "Resolves with the first fulfilled promise from `PROMISES`.
A convenience wrapper for `loom:any`.

Arguments:
- `PROMISES`: A list of promise-producing forms.

Returns:
- (loom-promise): A promise that resolves with the first successful result."
  (declare (indent 1) (debug (&rest form)))
  `(loom:any (list ,@promises)))

(provide 'loom-combinators)
;;; loom-combinators.el ends here