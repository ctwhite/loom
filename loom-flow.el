;;; loom-flow.el --- High-Level Asynchronous Control Flow -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a suite of high-level asynchronous primitives that
;; build upon the foundational `loom-promise` system. It provides
;; asynchronous, promise-aware versions of common Emacs Lisp control-flow
;; constructs, allowing developers to write complex asynchronous logic in a
;; style that is familiar and readable.
;;
;; Core Features:
;; - `loom:let` & `loom:let*`: Ergonomic, promise-aware versions of `let`.
;; - `loom:progn!`: A simple way to execute promise-returning forms in sequence.
;; - `loom:if!`, `loom:when!`, `loom:unless!`, `loom:cond!`: Async conditionals.
;; - `loom:loop!`, `loom:while!`, `loom:dolist!`, `loom:dotimes!`: Async loops.
;; - `loom:unwind-protect!`: Structured cleanup handling.
;; - `loom:with-timeout!`: A wrapper to enforce a time limit on an operation.
;; - `loom:with-concurrency-limit!`: Control over parallel execution.

;;; Code:

(require 'cl-lib)

(require 'loom-errors)
(require 'loom-promise)
(require 'loom-primitives)
(require 'loom-combinators)
(require 'loom-semaphore)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-flow-timeout-error
  "An operation in an async flow construct timed out."
  'loom-timeout-error)

(define-error 'loom-flow-break-error
  "A special error used to break from a `loom:loop!`."
  'loom-error)

(define-error 'loom-flow-continue-error
  "A special error used to continue a `loom:loop!`."
  'loom-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Asynchronous Bindings & Control Flow

;;;###autoload
(defmacro loom:let (bindings &rest body)
  "Execute `BODY` with `BINDINGS` resolved from promises in parallel.
All promise-forms in `BINDINGS` are initiated concurrently using
`loom:all`. The `BODY` is evaluated only after all of them have
resolved successfully. This is the asynchronous equivalent of a
parallel `let`.

Arguments:
- `BINDINGS` (list): A list of `(VAR PROMISE-FORM)` pairs. `VAR` is
  the symbol to bind, and `PROMISE-FORM` is a form that evaluates
  to a `loom-promise`.
- `BODY` (forms): The forms to execute with the resolved bindings.

Returns:
A `loom-promise` that resolves to the result of the last form in `BODY`."
  (declare (indent 1) (debug ((&rest (symbolp form)) body)))
  (if (null bindings)
      `(loom:resolved! (progn ,@body))
    (let ((vars (mapcar #'car bindings))
          (forms (mapcar #'cadr bindings)))
      ;; Use `loom:all` to wait for all binding forms to resolve in parallel.
      `(loom:then (loom:all (list ,@forms))
                  (lambda (results)
                    ;; Bind the results to the specified variables.
                    (cl-destructuring-bind ,vars results
                      ,@body))))))

;;;###autoload
(defmacro loom:let* (bindings &rest body)
  "Execute `BODY` with `BINDINGS` resolved sequentially.
Each promise in `BINDINGS` is awaited before the next begins, and its
result is bound and available for use in subsequent binding forms.
This is the asynchronous equivalent of a sequential `let*`.

Arguments:
- `BINDINGS` (list): A list of `(VAR PROMISE-FORM)` pairs.
- `BODY` (forms): The forms to execute with the resolved bindings.

Returns:
A `loom-promise` that resolves to the result of the last form in `BODY`."
  (declare (indent 1) (debug ((&rest (symbolp form)) body)))
  (if (null bindings)
      ;; Base case: no more bindings, execute the body.
      `(loom:resolved! (progn ,@body))
    (let* ((binding (car bindings))
           (var (car binding))
           (form (cadr binding)))
      ;; Recursively build a chain of `.then` calls.
      `(loom:then ,form
                  (lambda (,var)
                    (loom:let* ,(cdr bindings) ,@body))))))

;;;###autoload
(defmacro loom:progn! (&rest forms)
  "Execute a sequence of promise-returning FORMS sequentially.
This is the asynchronous equivalent of `progn`. It evaluates each
form in order, waiting for the promise it returns to resolve before
proceeding to the next.

Arguments:
- `FORMS` (list): A list of forms, each of which should evaluate to a
  `loom-promise`.

Returns:
A `loom-promise` that resolves with the value of the last form in `FORMS`."
  (declare (debug t))
  (if (null forms)
      `(loom:resolved! nil)
    `(loom:let* ,(--map `(,(gensym "_") ,it) forms)
       ,(car (last forms)))))

;;;###autoload
(defmacro loom:unwind-protect! (body-form &rest cleanup-forms)
  "Execute `BODY-FORM` and guarantee `CLEANUP-FORMS` run afterward.
This is the asynchronous equivalent of `unwind-protect`, implemented
using `loom:finally`. It ensures that the cleanup logic is executed
regardless of whether the main body's promise resolves or rejects.

Arguments:
- `BODY-FORM` (form): A form that evaluates to a promise.
- `CLEANUP-FORMS` (forms): The synchronous forms to execute upon settlement.

Returns:
A new `loom-promise` that settles with the same outcome as
`BODY-FORM`'s promise, but only after `CLEANUP-FORMS` have run."
  (declare (indent 1) (debug t))
  `(loom:finally ,body-form (lambda () ,@cleanup-forms)))

;;;###autoload
(defmacro loom:if! (condition-promise then-form &optional else-form)
  "Run `THEN-FORM` or `ELSE-FORM` based on the result of `CONDITION-PROMISE`.
This is the asynchronous equivalent of `if`.

Arguments:
- `CONDITION-PROMISE` (form): A form evaluating to a promise.
- `THEN-FORM` (form): The form to execute if the condition resolves to a non-nil value.
- `ELSE-FORM` (form, optional): The form to execute if it resolves to nil.

Returns:
A `loom-promise` that resolves with the result of the executed form."
  (declare (indent 1) (debug t))
  `(loom:then ,condition-promise
              (lambda (result)
                (if result ,then-form ,else-form))))

;;;###autoload
(defmacro loom:when! (condition-promise &rest body)
  "Execute `BODY` if `CONDITION-PROMISE` resolves to non-nil.
This is the asynchronous equivalent of `when`.

Arguments:
- `CONDITION-PROMISE` (form): A form evaluating to a promise.
- `BODY` (forms): The forms to execute if the condition is true.

Returns:
A `loom-promise` that resolves with the result of `BODY`, or `nil` if
the condition was false."
  (declare (indent 1) (debug t))
  `(loom:if! ,condition-promise
             (progn ,@body)
             (loom:resolved! nil)))

;;;###autoload
(defmacro loom:unless! (condition-promise &rest body)
  "Execute `BODY` if `CONDITION-PROMISE` resolves to nil.
This is the asynchronous equivalent of `unless`.

Arguments:
- `CONDITION-PROMISE` (form): A form evaluating to a promise.
- `BODY` (forms): The forms to execute if the condition is false.

Returns:
A `loom-promise` that resolves with the result of `BODY`, or `nil` if
the condition was true."
  (declare (indent 1) (debug t))
  `(loom:if! ,condition-promise
             (loom:resolved! nil)
             (progn ,@body)))

;;;###autoload
(defmacro loom:cond! (&rest clauses)
  "Asynchronous multi-branch conditional, like `cond`.
Each clause is `(CONDITION-PROMISE . BODY)`. The macro evaluates each
`CONDITION-PROMISE` in sequence. The `BODY` of the first clause whose
condition resolves to a non-nil value is executed, and its result becomes
the result of the entire `loom:cond!` expression.

Arguments:
- `CLAUSES` (list): A list of `(CONDITION-PROMISE . BODY)` clauses.

Returns:
A `loom-promise` that resolves with the result of the executed clause's body."
  (declare (indent 0) (debug (&rest (form body))))
  (if (null clauses)
      `(loom:resolved! nil)
    (let ((clause (car clauses)))
      (if (eq (car clause) t)
          ;; If the condition is `t`, it's the final `else` case.
          `(progn ,@(cdr clause))
        ;; Otherwise, create a nested `loom:if!` chain.
        `(loom:if! ,(car clause)
                   (progn ,@(cdr clause))
                   (loom:cond! ,@(cdr clauses)))))))

;;;###autoload
(defmacro loom:while! (condition-promise &rest body)
  "Execute `BODY` repeatedly while `CONDITION-PROMISE` resolves to non-nil.
This is the asynchronous equivalent of `while`. The condition is re-evaluated
before each iteration.

Arguments:
- `CONDITION-PROMISE` (form): A form evaluating to a promise.
- `BODY` (forms): The forms to execute in each iteration.

Returns:
A `loom-promise` that resolves to `nil` when the loop completes."
  (declare (indent 1) (debug t))
  (let ((loop-fn (gensym "loop-fn-")))
    `(let ((,loop-fn nil))
       (setq ,loop-fn
             (lambda ()
               (loom:then ,condition-promise
                          (lambda (result)
                            (if result
                                ;; If condition is true, run body then recurse.
                                (loom:then (progn ,@body)
                                           (lambda (_) (funcall ,loop-fn)))
                              ;; If condition is false, loop is done.
                              (loom:resolved! nil))))))
       (funcall ,loop-fn))))

;;;###autoload
(defmacro loom:dolist! (spec &rest body)
  "Asynchronously iterate over a list, like `dolist`.
The `SPEC` is `(VAR LIST-PROMISE &optional RESULT-FORM)`. The macro
first resolves `LIST-PROMISE` to get the list, then iterates over
each element, executing `BODY` for each one.

Arguments:
- `SPEC` (list): Iteration specification.
- `BODY` (forms): The forms to execute for each element.

Returns:
A `loom-promise` that resolves with the result of `RESULT-FORM`, or `nil`."
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
                                               (funcall ,loop-fn
                                                        (cdr remaining)))))
                              (loom:resolved! ,result-form))))
                    (funcall ,loop-fn ,list-var))))))

;;;###autoload
(defmacro loom:dotimes! (spec &rest body)
  "Asynchronously iterate a specified number of times, like `dotimes`.
The `SPEC` is `(VAR COUNT-PROMISE &optional RESULT-FORM)`. The macro
first resolves `COUNT-PROMISE` to get the count, then iterates from
0 up to (but not including) the count.

Arguments:
- `SPEC` (list): Iteration specification.
- `BODY` (forms): The forms to execute for each iteration.

Returns:
A `loom-promise` that resolves with the result of `RESULT-FORM`, or `nil`."
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
The loop can be exited by calling `loom:break!` from within the body.
`loom:continue!` can be used to skip to the next iteration. This is
implemented by catching special error signals.

Arguments:
- `BODY` (forms): The forms to execute in each iteration.

Returns:
A `loom-promise` that resolves with the value passed to `loom:break!`."
  (declare (indent 1) (debug t))
  (let ((loop-fn (gensym "loop-fn-")))
    `(let ((,loop-fn nil))
       (setq ,loop-fn
             (lambda ()
               (loom:catch
                (loom:then (progn ,@body)
                           (lambda (_) (funcall ,loop-fn)))
                ;; Special handler for break/continue signals.
                'loom-flow-break-error
                (lambda (err) (loom:resolved! (loom:error-data err)))
                'loom-flow-continue-error
                (lambda (_) (funcall ,loop-fn))
                ;; Any other error is propagated.
                (lambda (err) (loom:rejected! err)))))
       (funcall ,loop-fn))))

;;;###autoload
(defmacro loom:break! (&optional value)
  "Break from a `loom:loop!` with an optional return `VALUE`.
This macro works by rejecting a promise with a special, internal
error type that is caught by `loom:loop!`.

Arguments:
- `VALUE` (form, optional): The value to return from the loop.

Returns:
A `loom-promise` that rejects with a special `loom-flow-break-error`."
  `(loom:rejected! (loom:make-error :type 'loom-flow-break-error
                                    :data ,value)))

;;;###autoload
(defmacro loom:continue! ()
  "Continue to the next iteration of a `loom:loop!`.
This macro works by rejecting a promise with a special, internal
error type that is caught by `loom:loop!`.

Returns:
A `loom-promise` that rejects with a special `loom-flow-continue-error`."
  `(loom:rejected! (loom:make-error :type 'loom-flow-continue-error)))

;;;###autoload
(defmacro loom:with-timeout! (timeout-ms body-form &key cancel-token)
  "Run `BODY-FORM`, rejecting if it takes too long.
This macro uses `loom:race` to run the `BODY-FORM`'s promise in
parallel with a delay promise. Whichever settles first determines
the outcome.

Arguments:
- `TIMEOUT-MS` (integer): The timeout in milliseconds.
- `BODY-FORM` (form): A form returning a promise.
- `:CANCEL-TOKEN` (loom-cancel-token, optional): A token to cancel the
  operation.

Returns:
A `loom-promise` that settles with `BODY-FORM`'s result or
rejects with a `loom-flow-timeout-error`."
  (declare (indent 1) (debug t))
  `(let ((timeout-secs (/ (float ,timeout-ms) 1000.0)))
     (loom:race
      ,body-form
      (loom:then (loom:delay timeout-secs :cancel-token ,cancel-token)
                 (lambda (_)
                   (loom:rejected!
                    (loom:make-error
                     :type 'loom-flow-timeout-error
                     :message (format "Operation timed out after %dms"
                                      ,timeout-ms))))))))

;;;###autoload
(defmacro loom:with-concurrency-limit! (limit &rest body-forms)
  "Execute `BODY-FORMS` with a maximum concurrency limit.
Only `LIMIT` forms will be executed concurrently at any time. This is
implemented using a semaphore to control access.

Arguments:
- `LIMIT` (integer): The maximum number of concurrent operations.
- `BODY-FORMS` (forms): Forms that return promises.

Returns:
A `loom-promise` that resolves to a list of all results."
  (declare (indent 1) (debug t))
  (let ((sem (gensym "semaphore-")))
    ;; Create a semaphore with the specified limit.
    `(let ((,sem (loom:semaphore ,limit)))
       ;; Use `loom:all` to wait for all operations to complete.
       (loom:all
        (list
         ,@(mapcar (lambda (form)
                     ;; Wrap each form in a lambda that first acquires a
                     ;; permit from the semaphore, then runs the form, and
                     ;; finally ensures the permit is released.
                     `(loom:then (loom:semaphore-acquire ,sem)
                                 (lambda (_)
                                   (loom:finally (lambda () ,form)
                                                 (lambda () (loom:semaphore-release ,sem))))))
                   body-forms))))))

(provide 'loom-flow)
;;; loom-flow.el ends here
