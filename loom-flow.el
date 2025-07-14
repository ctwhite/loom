;;; loom-flow.el --- High-Level Asynchronous Control Flow -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library provides a suite of high-level asynchronous primitives that
;; build upon the foundational `loom-promise` system. It provides
;; asynchronous, promise-aware versions of common Emacs Lisp control-flow
;; constructs.
;;
;; Core Features:
;; - `loom:let` & `loom:let*`: Ergonomic, promise-aware versions of `let`
;;   that handle parallel and sequential resolution of asynchronous bindings.
;; - `loom:if!`: Asynchronous conditional evaluation.
;; - `loom:when!` & `loom:unless!`: Asynchronous conditional execution.
;; - `loom:cond!`: Asynchronous multi-branch conditional.
;; - `loom:loop!`: Asynchronous looping construct.
;; - `loom:try!`, `loom:unwind-protect!`: Structured error and cleanup handling
;;   for asynchronous operations.
;; - `loom:with-timeout!`, `loom:with-retries!`: Robust wrappers for adding
;;   common resilience patterns to any asynchronous operation.
;; - `loom:while!`: Asynchronous while loop.
;; - `loom:dolist!`: Asynchronous list iteration.
;; - `loom:dotimes!`: Asynchronous numeric iteration.

;;; Code:

(require 'cl-lib)

(require 'loom-errors)
(require 'loom-core)
(require 'loom-primitives)
(require 'loom-combinators)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'loom-flow-timeout-error
  "Operation timed out." 
  'loom-error)

(define-error 'loom-flow-break-error
  "Break from async loop."
  'loom-error)

(define-error 'loom-flow-continue-error
  "Continue in async loop."
  'loom-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Asynchronous Bindings & Control Flow

;;;###autoload
(defmacro loom:let (bindings &rest body)
  "Execute `BODY` with `BINDINGS` resolved from promises in parallel.
All promises in `BINDINGS` are initiated concurrently. The `BODY` is
evaluated only after all of them have resolved successfully.

`BINDINGS` is a list of `(VAR PROMISE-FORM)` pairs.

Arguments:
- `BINDINGS` (list): A list of `(VAR VAL-FORM)` bindings.
- `BODY` (forms): The forms to execute with the resolved bindings.

Returns:
- (loom-promise): A promise resolving to the result of `BODY`."
  (declare (indent 1) (debug ((&rest (symbolp form)) body)))
  (if (null bindings)
      `(loom:resolved! (progn ,@body))
    (let ((vars (mapcar #'car bindings))
          (forms (mapcar #'cadr bindings)))
      `(loom:then (loom:all (list ,@forms))
                  (lambda (results)
                    (cl-destructuring-bind ,vars results
                      ,@body))))))

;;;###autoload
(defmacro loom:let* (bindings &rest body)
  "Execute `BODY` with `BINDINGS` resolved sequentially.
Each promise in `BINDINGS` is awaited before the next begins, and its result
is bound and available for use in subsequent binding forms.

`BINDINGS` is a list of `(VAR PROMISE-FORM)` pairs.

Arguments:
- `BINDINGS` (list): A list of `(VAR VAL-FORM)` bindings.
- `BODY` (forms): The forms to execute with the resolved bindings.

Returns:
- (loom-promise): A promise resolving to the result of `BODY`."
  (declare (indent 1) (debug ((&rest (symbolp form)) body)))
  (if (null bindings)
      `(loom:resolved! (progn ,@body))
    (let* ((binding (car bindings))
           (var (car binding))
           (form (cadr binding)))
      `(loom:then ,form
                  (lambda (,var)
                    (loom:let* ,(cdr bindings) ,@body))))))

;;;###autoload
(defmacro loom:unwind-protect! (body-form &rest cleanup-forms)
  "Execute `BODY-FORM` and guarantee `CLEANUP-FORMS` run afterward.
This is the asynchronous equivalent of `unwind-protect`.

Arguments:
- `BODY-FORM` (form): A form that evaluates to a promise.
- `CLEANUP-FORMS` (forms): The forms to execute upon settlement.

Returns:
- `(loom-promise)`: A new promise that settles with the same outcome as
  `BODY-FORM`'s promise, but only after `CLEANUP-FORMS` have run."
  (declare (indent 1) (debug t))
  `(loom:finally ,body-form (lambda () ,@cleanup-forms)))

;;;###autoload
(defmacro loom:if! (condition-promise then-form &optional else-form)
  "Run `THEN-FORM` or `ELSE-FORM` based on the result of `CONDITION-PROMISE`.
This is the asynchronous equivalent of `if`. It waits for `CONDITION-PROMISE`
to resolve, and if the result is non-nil, evaluates `THEN-FORM`;
otherwise it evaluates `ELSE-FORM`.

Arguments:
- `CONDITION-PROMISE` (form): A form evaluating to a promise for a boolean.
- `THEN-FORM` (form): The form to execute if the condition is true.
- `ELSE-FORM` (form, optional): The form to execute if the condition is false.

Returns:
- `(loom-promise)`: A promise for the result of the executed form."
  (declare (indent 1) (debug t))
  `(loom:then ,condition-promise
              (lambda (result)
                (if result ,then-form ,else-form))))

;;;###autoload
(defmacro loom:when! (condition-promise &rest body)
  "Execute `BODY` if `CONDITION-PROMISE` resolves to non-nil.
This is the asynchronous equivalent of `when`.

Arguments:
- `CONDITION-PROMISE` (form): A form evaluating to a promise for a boolean.
- `BODY` (forms): The forms to execute if the condition is true.

Returns:
- `(loom-promise)`: A promise for the result of `BODY` or nil."
  (declare (indent 1) (debug t))
  `(loom:if! ,condition-promise
             (progn ,@body)
             nil))

;;;###autoload
(defmacro loom:unless! (condition-promise &rest body)
  "Execute `BODY` if `CONDITION-PROMISE` resolves to nil.
This is the asynchronous equivalent of `unless`.

Arguments:
- `CONDITION-PROMISE` (form): A form evaluating to a promise for a boolean.
- `BODY` (forms): The forms to execute if the condition is false.

Returns:
- `(loom-promise)`: A promise for the result of `BODY` or nil."
  (declare (indent 1) (debug t))
  `(loom:if! ,condition-promise
             nil
             (progn ,@body)))

;;;###autoload
(defmacro loom:cond! (&rest clauses)
  "Asynchronous multi-branch conditional.
Each clause is `(CONDITION-PROMISE . BODY)`. The first clause whose
condition resolves to non-nil has its body executed.

Arguments:
- `CLAUSES` (list): A list of `(CONDITION-PROMISE . BODY)` clauses.

Returns:
- `(loom-promise)`: A promise for the result of the executed clause's body."
  (declare (indent 0) (debug (&rest (form body))))
  (if (null clauses)
      `(loom:resolved! nil)
    (let ((clause (car clauses)))
      (if (eq (car clause) t)
          `(loom:resolved! (progn ,@(cdr clause)))
        `(loom:if! ,(car clause)
                   (progn ,@(cdr clause))
                   (loom:cond! ,@(cdr clauses)))))))

;;;###autoload
(defmacro loom:while! (condition-promise &rest body)
  "Execute `BODY` repeatedly while `CONDITION-PROMISE` resolves to non-nil.
This is the asynchronous equivalent of `while`.

Arguments:
- `CONDITION-PROMISE` (form): A form evaluating to a promise for a boolean.
- `BODY` (forms): The forms to execute in each iteration.

Returns:
- `(loom-promise)`: A promise that resolves to nil when the loop completes."
  (declare (indent 1) (debug t))
  (let ((loop-fn (gensym "loop-fn-")))
    `(let ((,loop-fn nil))
       (setq ,loop-fn
             (lambda ()
               (loom:then ,condition-promise
                         (lambda (result)
                           (if result
                               (loom:then (progn ,@body)
                                         (lambda (_) (funcall ,loop-fn)))
                             (loom:resolved! nil))))))
       (funcall ,loop-fn))))

;;;###autoload
(defmacro loom:dolist! (spec &rest body)
  "Asynchronously iterate over a list.
`SPEC` is `(VAR LIST-PROMISE &optional RESULT-FORM)`.

Arguments:
- `SPEC` (list): Iteration specification.
- `BODY` (forms): The forms to execute for each element.

Returns:
- `(loom-promise)`: A promise for the result of `RESULT-FORM` or nil."
  (declare (indent 1) (debug ((symbolp form &optional form) body)))
  (let ((var (car spec))
        (list-form (cadr spec))
        (result-form (caddr spec))
        (list-var (gensym "list-"))
        (loop-fn (gensym "loop-fn-")))
    `(loom:then ,list-form
                (lambda (,list-var)
                  (let ((,loop-fn nil))
                    (setq ,loop-fn
                          (lambda (remaining)
                            (if remaining
                                (let ((,var (car remaining)))
                                  (loom:then (progn ,@body)
                                            (lambda (_)
                                              (funcall ,loop-fn (cdr remaining)))))
                              (loom:resolved! ,result-form))))
                    (funcall ,loop-fn ,list-var))))))

;;;###autoload
(defmacro loom:dotimes! (spec &rest body)
  "Asynchronously iterate a specified number of times.
`SPEC` is `(VAR COUNT-PROMISE &optional RESULT-FORM)`.

Arguments:
- `SPEC` (list): Iteration specification.
- `BODY` (forms): The forms to execute for each iteration.

Returns:
- `(loom-promise)`: A promise for the result of `RESULT-FORM` or nil."
  (declare (indent 1) (debug ((symbolp form &optional form) body)))
  (let ((var (car spec))
        (count-form (cadr spec))
        (result-form (caddr spec))
        (count-var (gensym "count-"))
        (loop-fn (gensym "loop-fn-")))
    `(loom:then ,count-form
                (lambda (,count-var)
                  (let ((,loop-fn nil))
                    (setq ,loop-fn
                          (lambda (,var)
                            (if (< ,var ,count-var)
                                (loom:then (progn ,@body)
                                          (lambda (_)
                                            (funcall ,loop-fn (1+ ,var))))
                              (loom:resolved! ,result-form))))
                    (funcall ,loop-fn 0))))))

;;;###autoload
(defmacro loom:loop! (&rest body)
  "Create an infinite asynchronous loop.
The loop can be exited using `loom:break!` or `loom:continue!`.

Arguments:
- `BODY` (forms): The forms to execute in each iteration.

Returns:
- `(loom-promise)`: A promise that resolves when the loop is broken."
  (declare (indent 0) (debug t))
  (let ((loop-fn (gensym "loop-fn-"))
        (result-var (gensym "result-")))
    `(let ((,loop-fn nil)
           (,result-var nil))
       (setq ,loop-fn
             (lambda ()
               (loom:catch
                (progn ,@body)
                (lambda (err)
                  (cond
                   ((eq (loom:error-type err) 'loom-flow-break-error)
                    (loom:resolved! (loom:error-data err)))
                   ((eq (loom:error-type err) 'loom-flow-continue-error)
                    (funcall ,loop-fn))
                   (t (loom:rejected! err)))))))
       (funcall ,loop-fn))))

;;;###autoload
(defmacro loom:break! (&optional value)
  "Break from an asynchronous loop with optional return value.

Arguments:
- `VALUE` (form, optional): The value to return from the loop.

Returns:
- Never returns; signals a break error."
  `(loom:rejected! (loom:make-error
                    :type 'loom-flow-break-error
                    :data ,value)))

;;;###autoload
(defmacro loom:continue! ()
  "Continue to the next iteration of an asynchronous loop.

Returns:
- Never returns; signals a continue error."
  `(loom:rejected! (loom:make-error
                    :type 'loom-flow-continue-error)))

;;;###autoload
(defmacro loom:with-timeout! (timeout-ms body-form &key cancel-token)
  "Run `BODY-FORM`, rejecting with a timeout error if it takes too long.
Races the promise from `BODY-FORM` against a timer. The returned promise
can be cancelled via the optional `:cancel-token`.

Arguments:
- `TIMEOUT-MS` (integer): The timeout in milliseconds.
- `BODY-FORM` (form): A form returning a promise.
- `:CANCEL-TOKEN` (loom-cancel-token, optional): A token to cancel the operation.

Returns:
- (loom-promise): A promise that settles with `BODY-FORM`'s result or
  rejects with a `loom-flow-timeout-error` or `loom-cancel-error`."
  (declare (indent 1) (debug t))
  (let ((timeout-secs (/ (float timeout-ms) 1000.0)))
    `(loom:race!
      ,body-form
      (loom:then (loom:delay ,timeout-secs :cancel-token ,cancel-token)
                 (lambda (_)
                   (loom:rejected!
                    (loom:make-error
                     :type 'loom-flow-timeout-error
                     :message (format "Operation timed out after %dms"
                                      ,timeout-ms))))))))

;;;###autoload
(defmacro loom:with-retries! (options body-form)
  "Retry `BODY-FORM` upon failure.
`OPTIONS` is a plist that can contain `:retries`, `:delay`, and `:pred`.
See `loom:retry` for details.

Arguments:
- `OPTIONS` (plist): A plist of retry options.
- `BODY-FORM` (form): A form returning a promise.

Returns:
- (loom-promise): A promise that resolves with the first successful
  result, or rejects with the last error if all retries fail."
  (declare (indent 1) (debug t))
  `(apply #'loom:retry (lambda () ,body-form) ,options))

;;;###autoload
(defmacro loom:with-deadline! (deadline-time body-form &key cancel-token)
  "Run `BODY-FORM`, rejecting if it doesn't complete by `DEADLINE-TIME`.
Unlike `loom:with-timeout!`, this uses an absolute deadline rather than
a relative timeout.

Arguments:
- `DEADLINE-TIME` (float): The absolute time deadline (seconds since epoch).
- `BODY-FORM` (form): A form returning a promise.
- `:CANCEL-TOKEN` (loom-cancel-token, optional): A token to cancel the operation.

Returns:
- (loom-promise): A promise that settles with `BODY-FORM`'s result or
  rejects with a `loom-flow-timeout-error`."
  (declare (indent 1) (debug t))
  (let ((remaining-time `(max 0 (- ,deadline-time (float-time)))))
    `(loom:with-timeout! (* 1000 ,remaining-time) ,body-form
                         :cancel-token ,cancel-token)))

;;;###autoload
(defmacro loom:with-concurrency-limit! (limit body-forms)
  "Execute `BODY-FORMS` with a maximum concurrency limit.
Only `LIMIT` forms will be executed concurrently at any time.

Arguments:
- `LIMIT` (integer): The maximum number of concurrent operations.
- `BODY-FORMS` (list): A list of forms that return promises.

Returns:
- (loom-promise): A promise that resolves to a list of all results."
  (declare (indent 1) (debug t))
  (let ((forms-var (gensym "forms-"))
        (limit-var (gensym "limit-"))
        (results-var (gensym "results-"))
        (running-var (gensym "running-"))
        (process-fn (gensym "process-fn-")))
    `(let ((,forms-var ,body-forms)
           (,limit-var ,limit)
           (,results-var (make-vector (length ,body-forms) nil))
           (,running-var 0)
           (,process-fn nil))
       (setq ,process-fn
             (lambda (index)
               (if (>= index (length ,forms-var))
                   (loom:resolved! (append ,results-var nil))
                 (if (< ,running-var ,limit-var)
                     (progn
                       (setq ,running-var (1+ ,running-var))
                       (loom:then (nth index ,forms-var)
                                 (lambda (result)
                                   (aset ,results-var index result)
                                   (setq ,running-var (1- ,running-var))
                                   (funcall ,process-fn (1+ index)))))
                   (loom:then (loom:delay 0.001)
                             (lambda (_) (funcall ,process-fn index)))))))
       (funcall ,process-fn 0))))

;;;###autoload
(defmacro loom:try! (body-form &rest clauses)
  "Run `BODY-FORM` with optional `:catch` and `:finally` handlers.
This is a more structured way to combine `loom:catch` and `loom:finally`.

Clauses:
- `(:catch (ERR) &rest BODY)`: Handler if `BODY-FORM` rejects.
- `(:catch TYPE (ERR) &rest BODY)`: Handler for specific error types.
- `(:finally &rest BODY)`: Handler that runs after `BODY-FORM` settles.

Returns:
- (loom-promise): The final promise from the chain."
  (declare (indent 1) (debug t))
  (let ((catch-clauses (cl-remove-if-not (lambda (c) (eq (car c) :catch)) clauses))
        (finally-clause (cl-find :finally clauses :key #'car))
        (p (gensym "promise-")))
    `(let ((,p (if (loom-promise-p ,body-form)
                   ,body-form (loom:resolved! ,body-form))))
       ,@(when finally-clause
           `((setq ,p (loom:finally ,p (lambda () ,@(cdr finally-clause))))))
       ,@(when catch-clauses
           `((setq ,p (loom:catch ,p
                        (lambda (err)
                          (cond
                          ,@(mapcar (lambda (clause)
                                      (let ((spec (cadr clause)))
                                        (if (symbolp spec)
                                            ;; Simple catch: (:catch (err) ...)
                                            `(t (let ((,spec err)) ,@(cddr clause)))
                                          ;; Typed catch: (:catch type (err) ...)
                                          (let ((type (car spec))
                                                (var (cadr spec)))
                                            `((eq (loom:error-type err) ',type)
                                              (let ((,var err)) ,@(cddr clause)))))))
                                    catch-clauses)
                          (t (loom:rejected! err))))))))
       ,p)))

;;;###autoload
(defmacro loom:switch! (value-promise &rest cases)
  "Asynchronous switch statement.
Each case is `(VALUE-OR-PRED . BODY)` or `(:default . BODY)`.

Arguments:
- `VALUE-PROMISE` (form): A form evaluating to a promise for the switch value.
- `CASES` (list): A list of switch cases.

Returns:
- `(loom-promise)`: A promise for the result of the matching case's body."
  (declare (indent 1) (debug t))
  (let ((value-var (gensym "value-"))
        (default-case (cl-find :default cases :key #'car)))
    `(loom:then ,value-promise
                (lambda (,value-var)
                  (cond
                   ,@(mapcar (lambda (case)
                               (let ((test (car case))
                                     (body (cdr case)))
                                 (cond
                                  ((eq test :default) nil) ; Skip default case
                                  ((functionp test)
                                   `((funcall ,test ,value-var) ,@body))
                                  (t `((equal ,value-var ,test) ,@body)))))
                             (cl-remove :default cases :key #'car))
                   ,@(when default-case
                       `((t ,@(cdr default-case))))
                   (t nil))))))

(provide 'loom-flow)
;;; loom-flow.el ends here