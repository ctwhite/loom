;;; loom-callback.el --- Callback structure for Concur Promises -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file defines the `loom-callback` data structure, which encapsulates
;; an asynchronous callback for the Concur Promises library. It also provides
;; the public API for creating these callback objects.
;;
;; Separating this core data structure into its own file improves modularity,
;; reduces inter-module dependencies, and makes the library's architecture
;; clearer.
;;
;;; Code:

(require 'cl-lib)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State

(defvar loom--callback-sequence-counter 0
  "A global counter for assigning unique sequence IDs to callbacks for FIFO
tie-breaking.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definition

(cl-defstruct (loom-callback (:constructor %%make-callback) (:copier nil))
  "An internal struct that encapsulates an asynchronous callback.

Fields:
- `type` (symbol): The callback's purpose or trigger, e.g., `:resolved`,
  `:rejected`, or `:await-latch`.
- `handler-fn` (function): The actual Emacs Lisp function or closure to
  execute when the callback is triggered.
- `data` (plist): A property list containing metadata, typically including
  `:promise-id` (the ID of the target promise to be settled) and
  `:source-promise-id` (the ID of the promise that originated this
  callback).
- `priority` (integer): A scheduling priority, where lower values indicate
  higher priority (e.g., microtasks have higher priority than macrotasks).
- `sequence-id` (integer): A monotonically increasing ID used for FIFO
  tie-breaking when priorities are equal. This ensures that callbacks
  with the same priority are processed in the order they were created."
  (type nil :type symbol)
  (handler-fn nil :type function)
  (data nil :type plist)
  (priority 50 :type integer)
  (sequence-id (cl-incf loom--callback-sequence-counter) :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Callback Creation

;;;###autoload
(cl-defun loom:callback (handler-fn 
                         &rest extra-data
                         &key type 
                              (priority 50) 
                              data
                         &allow-other-keys)
  "Create a new `loom-callback` struct.

This is the public API for constructing `loom-callback` instances.
It automatically assigns a unique `sequence-id` for FIFO tie-breaking
in schedulers, ensuring consistent behavior.

Arguments:
- `HANDLER-FN` (function): The actual Emacs Lisp function or closure to
  execute when the callback is triggered. This is now the first explicit
  argument.
- `:TYPE` (symbol): The callback's purpose or trigger (e.g., `:resolved`,
  `:rejected`, `:await-latch`, `:deferred`).
- `:PRIORITY` (integer, optional): A scheduling priority, where lower values
  indicate higher priority. Defaults to 50.
- `:DATA` (plist, optional): A property list containing base metadata that
  will be merged with any additional key-value pairs.
- Additional key-value pairs: Any other keyword arguments will be added to
  the final data plist, potentially overriding values from `:DATA`.

Returns:
- (loom-callback): A new `loom-callback` struct.

Signals:
- `error`: If `HANDLER-FN` is not a function.

Examples:
  ;; Basic usage with explicit data
  (loom:callback #'my-handler :type :resolved
                 :data '(:foo 1 :bar 2))

  ;; Using additional key-value pairs
  (loom:callback #'my-handler :type :resolved
                 :promise-id 'my-promise
                 :source-promise-id 'source-promise
                 :custom-field 'custom-value)

  ;; Combining base data with additional pairs (additional pairs take 
  precedence)
  (loom:callback #'my-handler :type :resolved
                 :data '(:foo 1 :bar 2)
                 :bar 3  ; This will override :bar 2 from data
                 :baz 4) ; This will be added"
  (unless (functionp handler-fn)
    (error "handler-fn must be a function, got: %S" handler-fn))

  ;; Merge base data with additional key-value pairs
  ;; `extra-data` now contains only the keyword arguments after handler-fn
  (let ((final-data (append extra-data data)))
    (%%make-callback
     :type type
     :handler-fn handler-fn
     :priority priority
     :data final-data)))

(cl-defun loom:ensure-callback (task &key (type :deferred) 
                                          (priority 50) 
                                          data)
  "Ensures `TASK` is a `loom-callback` struct, creating one if not.
This utility function normalizes tasks submitted to schedulers, allowing
users to submit raw functions while the schedulers work with a consistent
`loom-callback` struct internally.

Arguments:
- `TASK` (function or loom-callback): The task to convert or validate.
- `:TYPE` (symbol): The callback type to assign if a new struct is created.
- `:PRIORITY` (integer): The priority to assign if a new struct is created.
- `:DATA` (plist): The data to associate if a new struct is created.

Returns: A valid `loom-callback` struct."
  (cond
   ((loom-callback-p task) task)
   ((functionp task)
    (loom:callback task :type type :priority priority :data data))
   (t (signal 'wrong-type-argument `(or functionp loom-callback-p ,task)))))

(provide 'loom-callback)
;;; loom-callback.el ends here