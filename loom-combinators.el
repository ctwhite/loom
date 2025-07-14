;;; loom-combinators.el --- Functions for working with groups of promises -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file provides a suite of combinator functions and macros for managing
;; and coordinating groups of promises. These are the core tools for handling
;; parallel and concurrent operations.
;;
;; Core Features:
;; - `loom:all` & `loom:all!`: Wait for all promises in a collection to
;;   resolve successfully.
;; - `loom:race` & `loom:race!`: Wait for the first promise in a collection
;;   to settle.
;; - `loom:all-settled` & `loom:all-settled!`: Wait for all promises to
;;   settle, regardless of their outcome.
;; - `loom:any`: Wait for the first promise to resolve successfully.
;; - Collection processing: `loom:map`, `loom:reduce`, `loom:map-series`
;; - Timing utilities: `loom:delay`, `loom:timeout`
;; - Retry utilities: `loom:retry`

;;; Code:

(require 'cl-lib)

(require 'loom-core)
(require 'loom-errors)
(require 'loom-primitives)
(require 'loom-cancel)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--normalize-to-promise (value)
  "If VALUE is a promise, return it. Else, wrap it in a resolved promise."
  (if (loom-promise-p value)
      value
    (loom:resolved! value)))

(defun loom--validate-list (arg fn-name)
  "Signal a `loom-type-error` if ARG is not a list."
  (unless (listp arg)
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "%s: Expected a list, got %S" fn-name arg))))))

(defun loom--validate-function (arg fn-name)
  "Signal a `loom-type-error` if ARG is not a function."
  (unless (functionp arg)
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "%s: Expected a function, got %S" fn-name arg))))))

(defun loom--validate-semaphore (arg fn-name)
  "Signal a `loom-type-error` if ARG is not a `loom-semaphore`."
  (unless (loom-semaphore-p arg)
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "%s: Expected a loom-semaphore, got %S" fn-name arg))))))

(defun loom--validate-positive-number (arg fn-name param-name)
  "Signal a `loom-type-error` if ARG is not a positive number."
  (unless (and (numberp arg) (> arg 0))
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "%s: %s must be a positive number, got %S" 
                                    fn-name param-name arg))))))

(defun loom--validate-non-negative-number (arg fn-name param-name)
  "Signal a `loom-type-error` if ARG is not a non-negative number."
  (unless (and (numberp arg) (>= arg 0))
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "%s: %s must be a non-negative number, got %S" 
                                    fn-name param-name arg))))))

(defun loom--determine-strongest-mode (promises default-mode)
  "Return the strongest concurrency mode (:thread > :deferred) from PROMISES."
  (if (cl-some (lambda (p)
                 (and (loom-promise-p p)
                      (eq (loom-promise-mode p) :thread)))
               promises)
      :thread
    default-mode))

(defun loom--wrap-with-semaphore (awaitables semaphore)
  "Wrap each awaitable in AWAITABLES with semaphore acquisition/release.
Each returned promise will first acquire a slot from SEMAPHORE, then
execute the original awaitable, and finally release the slot."
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
  "Return a promise that resolves when all input PROMISES resolve.
The returned promise resolves to a list of values in the same order as the
input list. If any promise in the list rejects, this promise rejects
immediately with that first error. Non-promise values in the list are
treated as already-resolved promises.

Arguments:
- PROMISES (list): A list of promises or plain values.
- :mode (keyword, optional): The concurrency mode (:thread or :deferred)
  for the returned promise. Defaults to the strongest mode found in the
  input promises.
- :semaphore (loom-semaphore, optional): If provided, each task must
  acquire the semaphore before it can start.

Returns:
- (loom-promise): A new promise.

Signals:
- `loom-type-error`: If PROMISES is not a list or SEMAPHORE is not a
  `loom-semaphore`."
  (loom--validate-list promises 'loom:all)
  (when semaphore
    (loom--validate-semaphore semaphore 'loom:all))

  (let ((processed-promises
         (if semaphore
             (loom--wrap-with-semaphore promises semaphore)
           (mapcar #'loom--normalize-to-promise promises))))
    (if (null processed-promises)
        (loom:resolved! '())
      (let* ((len (length processed-promises))
             (results (make-vector len nil))
             (mode (or mode (loom--determine-strongest-mode processed-promises :deferred)))
             (agg-promise (loom:promise :mode mode :name "loom:all"))
             (resolved-count 0)
             (lock (loom:lock "loom-all-lock" :mode mode)))

        (dotimes (i len)
          (let ((index i) ; Explicitly capture the index for this iteration.
                (p (nth i processed-promises)))
            (loom:then p
              (lambda (res)
                (loom:with-mutex! lock
                  (when (loom:pending-p agg-promise)
                    (aset results index res) ; Use the captured `index`.
                    (cl-incf resolved-count)
                    (when (= resolved-count len)
                      (loom:resolve agg-promise (cl-coerce results 'list))))))
              (lambda (err)
                (loom:with-mutex! lock
                  (when (loom:pending-p agg-promise)
                    (loom:reject agg-promise err)))))))
        agg-promise))))

;;;###autoload
(cl-defun loom:all-settled (promises &key mode semaphore)
  "Return a promise that resolves after all input PROMISES have settled.
This function is useful when you want to wait for a group of independent
async operations to complete, regardless of whether they succeed or fail.
The returned promise itself will never reject.

Arguments:
- PROMISES (list): A list of promises or plain values.
- :mode (keyword, optional): The concurrency mode for the returned promise.
- :semaphore (loom-semaphore, optional): If provided, each task must
  acquire the semaphore before it can start.

Returns:
- (loom-promise): A promise that resolves to a list of outcome plists.
  Each plist is of the form `(:status 'fulfilled :value VAL)` or
  `(:status 'rejected :reason ERR)`.

Signals:
- `loom-type-error`: If PROMISES is not a list or SEMAPHORE is not a
  `loom-semaphore`."
  (loom--validate-list promises 'loom:all-settled)
  (when semaphore
    (loom--validate-semaphore semaphore 'loom:all-settled))

  (let* ((processed-promises
          (if semaphore
              (loom--wrap-with-semaphore promises semaphore)
            (mapcar #'loom--normalize-to-promise promises))))
    (if (null processed-promises)
        (loom:resolved! '())
      (let* ((len (length processed-promises))
             (outcomes (make-vector len nil))
             (mode (or mode (loom--determine-strongest-mode processed-promises :deferred)))
             (agg-promise (loom:promise :mode mode :name "loom:all-settled"))
             (settled-count 0)
             (lock (loom:lock "all-settled-lock" :mode mode)))
        
        (dotimes (i len)
          (let ((index i)
                (promise (nth i processed-promises)))
            (loom:finally
             promise
             (lambda ()
               (loom:with-mutex! lock
                 (when (loom:pending-p agg-promise)
                   (aset outcomes index ; Use captured `index`
                         (if (loom:rejected-p promise) ; Use captured `promise`
                             `(:status 'rejected
                               :reason ,(loom:error-value promise))
                           `(:status 'fulfilled
                             :value ,(loom:value promise))))
                   (cl-incf settled-count)
                   (when (= settled-count len)
                     (loom:resolve agg-promise (cl-coerce outcomes 'list)))))))))
        agg-promise))))

;;;###autoload
(cl-defun loom:race (promises &key mode semaphore)
  "Return a promise that settles with the outcome of the first promise to settle.
'Settling' means either resolving or rejecting. As soon as any promise in
PROMISES settles, the returned promise adopts that same outcome.

Arguments:
- PROMISES (list): A list of promises or plain values.
- :mode (keyword, optional): The concurrency mode for the returned promise.
- :semaphore (loom-semaphore, optional): If provided, each task must
  acquire the semaphore before it can be considered in the race.

Returns:
- (loom-promise): A promise that settles with the first outcome from the list.

Signals:
- `loom-type-error`: If PROMISES is not a list or is empty, or
  SEMAPHORE is not a `loom-semaphore`."
  (loom--validate-list promises 'loom:race)
  (when (null promises)
    (signal 'loom-type-error
            (list (loom:make-error 
                   :type :invalid-argument
                   :message "loom:race requires at least one promise"))))
  (when semaphore
    (loom--validate-semaphore semaphore 'loom:race))

  (let* ((processed-promises
          (if semaphore
              (loom--wrap-with-semaphore promises semaphore)
            (mapcar #'loom--normalize-to-promise promises))))
    (let* ((mode (or mode (loom--determine-strongest-mode processed-promises :deferred)))
           (race-promise (loom:promise :mode mode :name "loom:race"))
           (lock (loom:lock "loom-race-lock" :mode mode)))
      (dolist (p processed-promises)
        (loom:then p
          (lambda (res)
            (loom:with-mutex! lock
              (when (loom:pending-p race-promise)
                (loom:resolve race-promise res))))
          (lambda (err)
            (loom:with-mutex! lock
              (when (loom:pending-p race-promise)
                (loom:reject race-promise err))))))
      race-promise)))

;;;###autoload
(cl-defun loom:any (promises &key mode semaphore)
  "Return a promise resolving with the first fulfilled promise from the list.
If all promises in PROMISES reject, the returned promise also rejects with
an :aggregate-error containing a list of all the individual rejection reasons.

Arguments:
- PROMISES (list): A list of promises or plain values.
- :mode (keyword, optional): The concurrency mode for the returned promise.
- :semaphore (loom-semaphore, optional): If provided, each task must
  acquire the semaphore before it can start.

Returns:
- (loom-promise): A new promise.

Signals:
- `loom-type-error`: If PROMISES is not a list or SEMAPHORE is not a
  `loom-semaphore`."
  (loom--validate-list promises 'loom:any)
  (when semaphore
    (loom--validate-semaphore semaphore 'loom:any))

  (let* ((processed-promises
          (if semaphore
              (loom--wrap-with-semaphore promises semaphore)
            (mapcar #'loom--normalize-to-promise promises))))
    (if (null processed-promises)
        (loom:rejected!
         (loom:make-error
          :type :aggregate-error
          :message "No promises provided to `loom:any`."))
      (let* ((len (length processed-promises))
             (errors (make-vector len nil))
             (mode (or mode (loom--determine-strongest-mode processed-promises :deferred)))
             (any-promise (loom:promise :mode mode :name "loom:any"))
             (rejected-count 0)
             (lock (loom:lock "loom-any-lock" :mode mode)))
        
        (dotimes (i len)
          (let ((index i)
                (p (nth i processed-promises)))
            (loom:then p
              ;; on-resolved: The first promise to succeed wins.
              (lambda (res)
                (loom:with-mutex! lock
                  (when (loom:pending-p any-promise)
                    (loom:resolve any-promise res))))
              ;; on-rejected: Store the error and check if all have failed.
              (lambda (err)
                (loom:with-mutex! lock
                  (when (loom:pending-p any-promise)
                    (aset errors index err) ; Use the captured `index`.
                    (cl-incf rejected-count)
                    (when (= rejected-count len)
                      (loom:reject
                       any-promise
                       (loom:make-error
                        :type :aggregate-error
                        :message "All promises rejected in `loom:any`."
                        :cause (cl-coerce errors 'list))))))))))
        any-promise))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Collection Combinators

;;;###autoload
(defun loom:map (items fn)
  "Map a sync or async FN over ITEMS in parallel.
All calls to FN are initiated concurrently. The order of the
results corresponds to the order of ITEMS.

Arguments:
- ITEMS (list): The list of items to process.
- FN (function): A function `(lambda (item))` that can return
  either a direct value or a promise.

Returns:
- (loom-promise): A promise that resolves with a new list of the results.

Signals:
- `loom-type-error`: If ITEMS is not a list or FN is not a function."
  (loom--validate-list items 'loom:map)
  (loom--validate-function fn 'loom:map)
  (loom:all
   (mapcar (lambda (item)
             (loom--normalize-to-promise (funcall fn item)))
           items)))

;;;###autoload
(defun loom:reduce (items fn initial-value)
  "Asynchronously reduce ITEMS to a single value using FN.
The FN is applied sequentially to each item.

Arguments:
- ITEMS (list): The list of items to process.
- FN (function): A function `(lambda (accumulator item))` that can
  return either a direct value or a promise.
- INITIAL-VALUE (any): The initial value for the accumulator.

Returns:
- (loom-promise): A promise that resolves with the final accumulated value.

Signals:
- `loom-type-error`: If ITEMS is not a list or FN is not a function."
  (loom--validate-list items 'loom:reduce)
  (loom--validate-function fn 'loom:reduce)
  (cl-reduce
   (lambda (acc-promise item)
     (loom:then acc-promise
                (lambda (current-acc)
                  (loom--normalize-to-promise (funcall fn current-acc item)))))
   items
   :initial-value (loom--normalize-to-promise initial-value)))

;;;###autoload
(defun loom:map-series (items fn)
  "Map a sync or async FN over ITEMS sequentially.
Each item is passed to FN only after the operation for the
previous item has completed.

Arguments:
- ITEMS (list): The list of items to process.
- FN (function): A function `(lambda (item))` that can return
  either a direct value or a promise.

Returns:
- (loom-promise): A promise that resolves with a new list of the results.

Signals:
- `loom-type-error`: If ITEMS is not a list or FN is not a function."
  (loom--validate-list items 'loom:map-series)
  (loom--validate-function fn 'loom:map-series)
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
  "Return a promise that resolves with VALUE-OR-FORM's result after SECONDS.
If VALUE-OR-FORM is an error-signaling form, its evaluation after
the delay will cause the promise to reject.

Arguments:
- SECONDS (number): The delay duration in seconds. Must be non-negative.
- VALUE-OR-FORM (any, optional): A form to evaluate to get the value.
  Defaults to t.

Returns:
- (loom-promise): A promise that fulfills or rejects after the delay.

Signals:
- `loom-type-error`: If SECONDS is not a non-negative number."
  (declare (indent 1))
  `(let ((secs ,seconds))
     (loom--validate-non-negative-number secs 'loom:delay "SECONDS")
     (loom:promise
      :name (format "delay-%.2fs" secs)
      :executor
      (lambda (resolve reject)
        (run-at-time secs nil
         (lambda ()
           (condition-case err
               ;; This lambda wrapper correctly delays the evaluation of
               ;; the form until the timer fires.
               (funcall resolve (funcall (lambda () ,(or value-or-form t))))
             (error
               (funcall reject err)))))))))

;;;###autoload
(defun loom:timeout (promise timeout-seconds)
  "Return a promise that rejects if PROMISE does not settle in time.

This function creates a race between the input PROMISE and a timer.
If PROMISE resolves or rejects first, its outcome is passed through.
If the timer finishes first, the returned promise rejects with a
:timeout error.

Arguments:
- PROMISE (loom-promise): The promise to apply the timeout to.
- TIMEOUT-SECONDS (number): The timeout duration in seconds.

Returns:
- (loom-promise): A new promise with the timeout applied.

Signals:
- `loom-type-error`: If PROMISE is not a `loom-promise` or
  TIMEOUT-SECONDS is not a positive number."
  (unless (loom-promise-p promise)
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "loom:timeout: Expected a promise, got %S" promise)))))
  (loom--validate-positive-number timeout-seconds 'loom:timeout "TIMEOUT-SECONDS")
  
  (loom:race
   (list
    promise
    (loom:then (loom:delay timeout-seconds)
               (lambda (_)
                 (loom:rejected!
                  (loom:make-error
                   :type :timeout
                   :message (format "Operation timed out after %.3fs" timeout-seconds))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Retry Utilities

;;;###autoload
(cl-defun loom:retry (fn &key (retries 3) (delay 0.1) (pred #'identity))
  "Retry an async function FN upon failure.

Arguments:
- FN (function): A zero-argument function that returns a promise.
- :retries (integer): Maximum number of attempts (default 3).
- :delay (number|function): Seconds to wait between retries. Can be a
  fixed number or a function `(lambda (attempt-num error))` that
  returns a delay in seconds.
- :pred (function): A predicate `(lambda (error))` called on failure.
  A retry is only attempted if it returns non-nil.

Returns:
- (loom-promise): A promise that resolves with the first successful
  result, or rejects with the last error if all retries fail.

Signals:
- `loom-type-error`: For invalid FN, :retries, or :delay arguments."
  (loom--validate-function fn 'loom:retry)
  (unless (and (integerp retries) (>= retries 1))
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "loom:retry: :retries must be an integer >= 1, got %S" retries)))))
  (unless (or (numberp delay) (functionp delay))
    (signal 'loom-type-error
            (list (loom:make-error
                   :type :invalid-argument
                   :message (format "loom:retry: :delay must be a number or function, got %S" delay)))))
  (loom--validate-function pred 'loom:retry)
  
  (loom:promise
   :name "loom:retry"
   :executor
   (lambda (resolve reject)
     (let ((attempt 0))
       (cl-labels
           ((try-once ()
              (cl-incf attempt)
              (loom:then
               (funcall fn)
               resolve
               (lambda (error)
                 (if (and (< attempt retries) (funcall pred error))
                     (let ((delay-sec (if (functionp delay)
                                          (funcall delay attempt error)
                                        delay)))
                       (loom:then (loom:delay delay-sec) #'try-once))
                   (funcall reject error))))))
         (try-once))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Convenience Macros

;;;###autoload
(defmacro loom:all! (&rest promises)
  "Resolve all PROMISES in parallel.
A convenience wrapper for `loom:all`.

Arguments:
- PROMISES: A list of promise-producing forms.

Returns:
- (loom-promise): A promise that resolves to a list of all results."
  (declare (indent 0) (debug t))
  `(loom:all (list ,@promises)))

;;;###autoload
(defmacro loom:race! (&rest promises)
  "Race all PROMISES and resolve with the result of the first to settle.
A convenience wrapper for `loom:race`.

Arguments:
- PROMISES: A list of promise-producing forms.

Returns:
- (loom-promise): A promise that settles with the outcome of the first
  promise in the list to settle."
  (declare (indent 0) (debug t))
  `(loom:race (list ,@promises)))

;;;###autoload
(defmacro loom:all-settled! (&rest promises)
  "Wait for all PROMISES to settle (resolve or reject).
A convenience wrapper for `loom:all-settled`.

Arguments:
- PROMISES: A list of promise-producing forms.

Returns:
- (loom-promise): A promise that resolves to a list of result plists,
  each describing the outcome of one of the input promises."
  (declare (indent 0) (debug t))
  `(loom:all-settled (list ,@promises)))

;;;###autoload
(defmacro loom:any! (&rest promises)
  "Return the first resolved promise from PROMISES.
A convenience wrapper for `loom:any`.

Arguments:
- PROMISES: A list of promise-producing forms.

Returns:
- (loom-promise): A promise that resolves with the first successful result."
  (declare (indent 0) (debug t))
  `(loom:any (list ,@promises)))

(provide 'loom-combinators)
;;; loom-combinators.el ends here