;;; loom-combinators.el --- Functions for composing groups of promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides a suite of combinator functions and macros for managing
;; and coordinating groups of promises. These are the core tools for composing
;; complex asynchronous workflows from simpler promises.
;;
;; Unlike `loom-async.el`, which focuses on starting and parallelizing new
;; tasks, this module operates on existing promises.
;;
;; ## Core Features
;;
;; - **Group Synchronization:**
;;   - `loom:all`: Waits for all promises to resolve successfully.
;;   - `loom:race`: Settles as soon as the first promise settles.
;;   - `loom:all-settled`: Waits for all promises to settle, regardless of outcome.
;;   - `loom:any`: Waits for the first promise to resolve successfully.
;;
;; - **Sequential Collection Processing:**
;;   - `loom:reduce`: Reduces a list with an async function sequentially.
;;   - `loom:map-series`: Applies an async function to a list sequentially.
;;
;; - **Timing and Control Flow:**
;;   - `loom:delay!`: Creates a promise that resolves after a time delay.
;;   - `loom:timeout`: Wraps a promise with a time limit.
;;   - `loom:retry`: Automatically retries an async operation upon failure.
;;   - `loom:as-completed`: Convert a list of promises to a stream of results.
;;   - `loom:wait`: Advanced control for racing operations.

;;; Code:

(require 'cl-lib)

(require 'loom-error)
(require 'loom-promise)
(require 'loom-primitives)
(require 'loom-cancel)
(require 'loom-semaphore)
(require 'loom-async)
(require 'loom-stream)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--normalize-to-promise (value)
  "If VALUE is a `loom-promise`, return it. Otherwise, wrap it."
  (if (loom-promise-p value) value (loom:resolved! value)))

(defun loom--validate-list (arg fn-name)
  "Signal a `loom-type-error` if `ARG` is not a list for `FN-NAME`."
  (unless (listp arg)
    (signal 'loom-type-error
            (list (format "%s: Expected a list, got %S" fn-name arg)))))

(defun loom--validate-function (arg fn-name)
  "Signal a `loom-type-error` if `ARG` is not a function for `FN-NAME`."
  (unless (functionp arg)
    (signal 'loom-type-error
            (list (format "%s: Expected a function, got %S" fn-name arg)))))

(defun loom--validate-non-negative-number (arg fn-name param-name)
  "Signal a `loom-type-error` if `ARG` is not a number >= 0 for `FN-NAME`."
  (unless (and (numberp arg) (>= arg 0))
    (signal 'loom-type-error
            (list (format "%s: %s must be a non-negative number, got %S"
                          fn-name param-name arg)))))

(defun loom--wrap-with-semaphore (awaitables semaphore)
  "Wrap each awaitable with semaphore acquisition/release logic."
  (mapcar (lambda (awaitable)
            (loom:then (loom:semaphore-acquire semaphore)
                       (lambda (_)
                         (loom:finally (loom--normalize-to-promise awaitable)
                                       (lambda ()
                                         (loom:semaphore-release semaphore))))))
          awaitables))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Core Combinators

;;;###autoload
(cl-defun loom:all (promises &rest keys)
  "Return a promise that resolves when all input `PROMISES` resolve.
The returned promise resolves to a list of the resolved values, in the same
order as the input list. If any promise rejects, the returned promise
rejects *immediately* with that first error.

Arguments:
- `PROMISES` (list): A list of promises or plain values.
- `KEYS` (plist): Keyword arguments.
  - `:semaphore` (loom-semaphore, optional): Limits concurrency.

Returns:
- (loom-promise): A new promise that resolves with a list of all values."
  (loom--validate-list promises 'loom:all)
  (let* ((semaphore (plist-get keys :semaphore))
         (normalized (mapcar #'loom--normalize-to-promise promises))
         (tasks (if semaphore
                    (loom--wrap-with-semaphore normalized semaphore)
                  normalized)))
    (if (null tasks)
        (loom:resolved! '())
      (let* ((len (length tasks))
             (results (make-vector len nil))
             (agg-promise (loom:promise :name "loom:all"))
             (resolved-count 0)
             (lock (loom:lock "loom-all-lock")))
        (dotimes (i len)
          (let ((index i) (p (nth i tasks)))
            (loom:then p
              (lambda (res)
                (loom:with-mutex! lock
                  (when (loom:promise-pending-p agg-promise)
                    (aset results index res)
                    (cl-incf resolved-count)
                    (when (= resolved-count len)
                      (loom:promise-resolve agg-promise (cl-coerce results 'list))))))
              (lambda (err)
                (loom:with-mutex! lock
                  (when (loom:promise-pending-p agg-promise)
                    (loom:promise-reject agg-promise err)))))))
        agg-promise))))

;;;###autoload
(cl-defun loom:all-settled (promises &rest keys)
  "Return a promise that resolves after all input `PROMISES` have settled.
This function is useful when you need to wait for a group of independent
operations to complete, regardless of whether they succeed or fail.
The returned promise itself will **never reject**.

Arguments:
- `PROMISES` (list): A list of promises or plain values.
- `KEYS` (plist): Keyword arguments.
  - `:semaphore` (loom-semaphore, optional): Limits concurrency.

Returns:
- (loom-promise): A promise that resolves to a list of outcome plists.
  Each plist is `(:status 'fulfilled :value VAL)` or
  `(:status 'rejected :reason ERR)`."
  (loom--validate-list promises 'loom:all-settled)
  (let* ((semaphore (plist-get keys :semaphore))
         (normalized (mapcar #'loom--normalize-to-promise promises))
         (tasks (if semaphore
                    (loom--wrap-with-semaphore normalized semaphore)
                  normalized)))
    (if (null tasks)
        (loom:resolved! '())
      (let* ((len (length tasks))
             (outcomes (make-vector len nil))
             (agg-promise (loom:promise :name "loom:all-settled"))
             (settled-count 0)
             (lock (loom:lock "all-settled-lock")))
        (dotimes (i len)
          (let ((index i) (p (nth i tasks)))
            (loom:finally
             p
             (lambda ()
               (loom:with-mutex! lock
                 (when (loom:promise-pending-p agg-promise)
                   (aset outcomes index
                         (if (loom:promise-rejected-p p)
                             `(:status 'rejected :reason ,(loom:promise-error-value p))
                           `(:status 'fulfilled :value ,(loom:promise-value p))))
                   (cl-incf settled-count)
                   (when (= settled-count len)
                     (loom:promise-resolve agg-promise (cl-coerce outcomes 'list)))))))))
        agg-promise))))

;;;###autoload
(cl-defun loom:race (promises &rest keys)
  "Return a promise that settles with the outcome of the first promise to settle.
\"Settling\" means either resolving or rejecting. As soon as any promise in
`PROMISES` settles, the returned promise adopts that same outcome.

Arguments:
- `PROMISES` (list): A list of promises or plain values.
- `KEYS` (plist): Keyword arguments.
  - `:semaphore` (loom-semaphore, optional): Limits concurrency.

Returns:
- (loom-promise): A promise that settles with the first outcome from the list.

Signals:
- `loom-type-error`: If `PROMISES` is not a non-empty list."
  (loom--validate-list promises 'loom:race)
  (when (null promises) (error "loom:race requires a non-empty list"))
  (let* ((semaphore (plist-get keys :semaphore))
         (normalized (mapcar #'loom--normalize-to-promise promises))
         (tasks (if semaphore
                    (loom--wrap-with-semaphore normalized semaphore)
                  normalized))
         (race-promise (loom:promise :name "loom:race"))
         (lock (loom:lock "loom-race-lock")))
    (dolist (p tasks)
      (loom:finally p
        (lambda ()
          (loom:with-mutex! lock
            (when (loom:promise-pending-p race-promise)
              (if (loom:promise-rejected-p p)
                  (loom:promise-reject race-promise (loom:promise-error-value p))
                (loom:promise-resolve race-promise (loom:promise-value p))))))))
    race-promise))

;;;###autoload
(cl-defun loom:any (promises &rest keys)
  "Return a promise that resolves with the first fulfilled promise.
If all promises in `PROMISES` reject, the returned promise also rejects with
a special `:aggregate-error` whose `:cause` is a list of all the individual
rejection reasons.

Arguments:
- `PROMISES` (list): A list of promises or plain values.
- `KEYS` (plist): Keyword arguments.
  - `:semaphore` (loom-semaphore, optional): Limits concurrency.

Returns:
- (loom-promise): A new promise that resolves with the first success."
  (loom--validate-list promises 'loom:any)
  (let* ((semaphore (plist-get keys :semaphore))
         (normalized (mapcar #'loom--normalize-to-promise promises))
         (tasks (if semaphore
                    (loom--wrap-with-semaphore normalized semaphore)
                  normalized)))
    (if (null tasks)
        (loom:rejected!
         (loom:error! :type :aggregate-error
                      :message "No promises provided to `loom:any`."))
      (let* ((len (length tasks))
             (errors (make-vector len nil))
             (any-promise (loom:promise :name "loom:any"))
             (rejected-count 0)
             (lock (loom:lock "loom-any-lock")))
        (dotimes (i len)
          (let ((index i) (p (nth i tasks)))
            (loom:then p
              (lambda (res)
                (loom:with-mutex! lock
                  (when (loom:promise-pending-p any-promise)
                    (loom:promise-resolve any-promise res))))
              (lambda (err)
                (loom:with-mutex! lock
                  (when (loom:promise-pending-p any-promise)
                    (aset errors index err)
                    (cl-incf rejected-count)
                    (when (= rejected-count len)
                      (loom:promise-reject
                       any-promise
                       (loom:error!
                        :type :aggregate-error
                        :message "All promises were rejected."
                        :cause (cl-coerce errors 'list))))))))))
        any-promise))))

;;;###autoload
(cl-defun loom:wait (promises &key (return-when :all-completed) cancel-token)
  "Wait for `PROMISES` to complete according to `RETURN-WHEN` condition.

Arguments:
- `PROMISES` (list): A list of promises to wait for.
- `:RETURN-WHEN` (keyword): Specifies the completion condition:
  - `:all-completed`: (Default) Wait for all promises to settle.
  - `:first-completed`: Wait for the first promise to resolve successfully.
  - `:first-exception`: Wait for the first promise to be rejected.
- `:CANCEL-TOKEN` (loom-cancel-token): A token to cancel the wait.

Returns:
- (loom-promise): A promise that settles according to the condition."
  (let ((master-promise (loom:promise :cancel-token cancel-token))
        (internal-token (loom:cancel-token "wait-internal")))
    (pcase return-when
      (:all-completed
       (loom:then (loom:all-settled promises)
                  (lambda (results) (loom:promise-resolve master-promise results))))
      (:first-completed
       (dolist (p promises)
         (loom:then p (lambda (res)
                        (unless (loom:promise-settled-p master-promise)
                          (loom:cancel-token-signal internal-token)
                          (loom:promise-resolve master-promise res)))))
       (loom:catch (loom:all-settled promises) (lambda (_) nil)))
      (:first-exception
       (dolist (p promises)
         (loom:catch p (lambda (err)
                         (unless (loom:promise-settled-p master-promise)
                           (loom:cancel-token-signal internal-token)
                           (loom:promise-reject master-promise err)))))
       (loom:then (loom:all-settled promises) (lambda (_) nil))))
    master-promise))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Sequential Collection Combinators

;;;###autoload
(defun loom:reduce (items fn initial-value)
  "Asynchronously reduce `ITEMS` to a single value using `FN`, sequentially.
This function applies `FN` to each item in series, waiting for the promise
from one step to complete before starting the next.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): The reducer `(lambda (accumulator item))` which can
  return either a direct value or a promise.
- `INITIAL-VALUE` (any): The initial value for the accumulator.

Returns:
- (loom-promise): A promise that resolves with the final accumulated value."
  (loom--validate-list items 'loom:reduce)
  (loom--validate-function fn 'loom:reduce)
  (cl-reduce
   (lambda (acc-promise item)
     (loom:then acc-promise
                (lambda (current-acc)
                  (funcall fn current-acc item))))
   items
   :initial-value (loom--normalize-to-promise initial-value)))

;;;###autoload
(defun loom:map-series (items fn)
  "Map an async `FN` over `ITEMS` sequentially.
Each item is passed to `FN` only after the promise returned for the
previous item has completed.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): A function `(lambda (item))` that returns a value or promise.

Returns:
- (loom-promise): A promise that resolves with the list of results."
  (loom--validate-list items 'loom:map-series)
  (loom--validate-function fn 'loom:map-series)
  (loom:then
   (loom:reduce
    items
    (lambda (acc item)
      (loom:then (funcall fn item)
                 (lambda (result) (cons result acc))))
    '())
   #'nreverse))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Timing and Control Flow

;;;###autoload
(defmacro loom:delay! (seconds &optional value-or-form)
  "Return a promise that resolves after `SECONDS`.
The resolution value is the result of evaluating `VALUE-OR-FORM` *after* the
delay.

Arguments:
- `SECONDS` (number): The delay duration. Must be non-negative.
- `VALUE-OR-FORM` (any, optional): A form to evaluate to get the value.

Returns:
- (loom-promise): A promise that fulfills or rejects after the delay."
  (declare (indent 1)
           (debug (seconds &optional value-or-form)))
  `(let ((secs ,seconds))
     (loom--validate-non-negative-number secs 'loom:delay! "SECONDS")
     (loom:promise
      :name (format "delay-%.2fs" secs)
      :executor
      (lambda (resolve reject)
        (run-at-time secs nil
                     (lambda ()
                       (condition-case err
                           (funcall resolve (funcall (lambda ()
                                                       ,(or value-or-form t))))
                         (error (funcall reject err)))))))))

;;;###autoload
(defun loom:timeout (promise timeout-seconds)
  "Return a promise that rejects if `PROMISE` does not settle within a time
limit. This creates a race between the input `PROMISE` and a timer.

Arguments:
- `PROMISE` (loom-promise): The promise to apply the timeout to.
- `TIMEOUT-SECONDS` (number): The timeout duration in seconds.

Returns:
- (loom-promise): A new promise with the timeout behavior."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error (list "loom:timeout: Expected a promise")))
  (loom--validate-non-negative-number timeout-seconds 'loom:timeout
                                      "TIMEOUT-SECONDS")
  (loom:race
   (list
    promise
    (loom:then (loom:delay! timeout-seconds)
               (lambda (_)
                 (loom:rejected!
                  (loom:error!
                   :type :timeout
                   :message (format "Operation timed out after %.3fs"
                                    timeout-seconds))))))))

;;;###autoload
(cl-defun loom:retry (fn &key (retries 3) (delay 0.1) (pred #'identity))
  "Retry an asynchronous function `FN` upon failure.

Arguments:
- `FN` (function): A zero-argument function that returns a promise.
- `:retries` (integer): Maximum number of attempts (default 3, minimum 1).
- `:delay` (number|function): Seconds to wait between retries. Can be a
  fixed number or a function `(lambda (attempt-num error))` for backoff.
- `:pred` (function): A predicate `(lambda (error))` called upon failure.
  A retry is only attempted if this function returns non-nil.

Returns:
- (loom-promise): A promise that resolves with the first successful
  result, or rejects with the last error if all retries fail."
  (loom--validate-function fn 'loom:retry)
  (let ((master-promise (loom:promise :name "loom:retry")))
    (cl-labels
        ((try-once (attempt)
           (loom:then
            (funcall fn)
            (lambda (result) (loom:promise-resolve master-promise result))
            (lambda (err)
              (if (and (< attempt retries) (funcall pred err))
                  (let ((delay-sec (if (functionp delay)
                                       (funcall delay attempt err)
                                     delay)))
                    (loom:then (loom:delay! delay-sec)
                               (lambda () (try-once (1+ attempt)))))
                (loom:promise-reject master-promise err))))))
      (try-once 1))
    master-promise))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Convenience Macros

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
  "Waits for all `PROMISES` to settle. A convenience wrapper for 
  `loom:all-settled`.

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