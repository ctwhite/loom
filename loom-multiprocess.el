;;; loom-multiprocess.el --- Persistent Lisp Worker Pool -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library provides a high-performance, persistent worker pool for
;; executing asynchronous Emacs Lisp evaluation tasks. It is built upon the
;; generic `loom-abstract-pool` framework, specializing it for Lisp code.
;;
;; By maintaining a pool of ready-to-use background Emacs processes, it
;; avoids the overhead of starting a new process for each task. This makes
;; it ideal for parallelizing CPU-bound Lisp computations without freezing
;; the user interface. Each worker is a fully independent Emacs process
;; that communicates with the main instance via the robust `loom-ipc` system.
;;
;; Key Features:
;; - Low-overhead execution of arbitrary Lisp forms in persistent workers.
;; - Full integration with `loom-ipc` for robust, standardized communication.
;; - A default, on-demand pool for easy, configuration-free use.
;; - Priority-based task queue for managing workloads.

;;; Code:

(require 'cl-lib)

(require 'loom-abstract-pool)
(require 'loom-process)
(require 'loom-log)
(require 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-multiprocess-error
  "A Lisp-specific worker pool error occurred."
  'loom-abstract-pool-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Logic & State

(defvar loom--default-multiprocess-pool nil
  "The global default instance of the Lisp worker pool.
This pool is created on-demand when `loom:multiprocess!` is first called.")

(defun loom--multiprocess-persistent-worker-loop ()
  "The main entry point and loop for a persistent Lisp worker process.
This function runs inside the background Emacs process. It continuously
reads tasks from stdin, executes the Lisp form, and then uses
`loom:dispatch-to-main-thread` to send the result or error back to the
parent process via the standard IPC named pipe. This ensures all
communication is handled by the robust, centralized `loom` system.

This function never returns; it loops until its process is killed or its
stdin stream is closed by the parent, at which point `read` will signal
an `end-of-file` error and the process will terminate."
  (let ((print-escape-nonascii t))
    ;; Loop indefinitely, processing one task at a time until stdin is closed
    ;; or the process is killed.
    (while t
      (let* ((task-data (read)) ; Read a sexp task from the parent.
             (promise-id (plist-get task-data :promise-id))
             (payload (plist-get task-data :payload))
             (context (plist-get task-data :context))
             (vars (plist-get context :vars))
             ;; Create a lightweight "proxy" promise. This object only needs
             ;; the ID of the real promise in the parent process.
             (proxy-promise (%%make-promise :id promise-id)))
        (let ((response
               (condition-case err
                   ;; Evaluate the form with the provided lexical bindings.
                   (list :result (eval `(let ,vars ,payload) t))
                 ;; If an error occurs during evaluation, serialize it.
                 (error
                  (list :error (loom:serialize-error
                                (loom:make-error :cause err)))))))
          ;; Use the standard Loom IPC mechanism to send the result back.
          (loom:dispatch-to-main-thread
           proxy-promise :promise-settled response))))))

(defun loom--multiprocess-worker-factory-fn (worker pool)
  "Create a new Emacs worker process for the Lisp pool.
This function is called by the abstract pool to spawn a new worker.
It delegates to `loom:process-spawn-worker` to handle the low-level
details of process creation and IPC initialization.

Arguments:
- `WORKER` (loom-abstract-worker): The worker struct to populate.
- `POOL` (loom-abstract-pool): The parent pool.

Returns:
- `nil`.

Side Effects:
- Populates the `process` slot of `WORKER` with a new process."
  (ignore pool)
  (let* ((worker-id (format "mp-worker-%d" (loom-abstract-worker-id worker)))
         (worker-name (format "multiprocess-worker-%d"
                              (loom-abstract-worker-id worker))))
    (loom-log-info worker-name "Creating new Lisp worker process.")
    (setf (loom-abstract-worker-process worker)
          (loom:process-spawn-worker
           :name worker-name
           :worker-id worker-id
           :main-loop-fn 'loom--multiprocess-persistent-worker-loop
           :require '(loom-multiprocess loom)))))

(cl-defun loom--multiprocess-pool-creator (&rest args
                                          &key (name "default-multiprocess-pool")
                                          &allow-other-keys)
  "The underlying function that creates a new Lisp pool instance.
This is wrapped by the public `loom:multiprocess-pool-create` function.

Arguments:
- `ARGS` (plist): A property list of configuration options for the pool.

Returns:
- (loom-abstract-pool): A new instance configured for Lisp evaluation."
  (loom-log-info name "Creating new Lisp multiprocess pool.")
  (apply #'loom-abstract-pool-create
         :name name
         :task-queue-type :priority ; Use a priority queue for Lisp tasks.
         :worker-factory-fn #'loom--multiprocess-worker-factory-fn
         ;; The sentinel is handled by the abstract pool's generic logic.
         :worker-ipc-sentinel-fn #'loom--abstract-pool-handle-worker-death
         ;; The task serializer must now include the promise ID for the worker.
         :task-serializer-fn (lambda (task)
                               (prin1-to-string
                                `(:promise-id
                                  ,(loom-promise-id
                                    (loom-abstract-task-promise task))
                                  :payload
                                  ,(loom-abstract-task-payload task)
                                  :context
                                  ,(loom-abstract-task-context task))))
         ;; No custom filter or parsers are needed, as all communication
         ;; is now handled by the main `loom-ipc` system.
         :worker-ipc-filter-fn nil
         :result-parser-fn nil
         :error-parser-fn nil
         :message-parser-fn nil
         args))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;; Use the factory macro from the abstract pool to generate our public API.
(loom:defpool! loom-multiprocess
  :create #'loom--multiprocess-pool-creator
  :submit #'loom-abstract-pool-submit
  :shutdown #'loom-abstract-pool-shutdown!
  :status #'loom-abstract-pool-status)

;;;###autoload
(defun loom:multiprocess-pool-default ()
  "Return the default `loom-multiprocess-pool`, initializing it if needed.
This function is idempotent; subsequent calls return the existing
instance without re-initializing.

Returns:
- (loom-abstract-pool): The default instance for multiprocessing.

Side Effects:
- May create the default multiprocess pool instance if it doesn't exist."
  (unless (and loom--default-multiprocess-pool
               (loom-abstract-pool-p loom--default-multiprocess-pool)
               (not (loom-abstract-pool-shutdown-p
                     loom--default-multiprocess-pool)))
    (loom-log-info 'default-pool (concat "Default multiprocess pool not found "
                                         "or shut down. Creating new one."))
    (setq loom--default-multiprocess-pool (loom:multiprocess-pool-create)))
  loom--default-multiprocess-pool)

;;;###autoload
(defmacro loom:multiprocess! (form &key vars cancel-token priority timeout)
  "Execute a Lisp `FORM` in the default background process pool.
This is the simplest, high-level way to run a parallel Lisp computation.
It automatically uses a shared pool of persistent Emacs worker processes
to execute tasks with low overhead.

The `FORM` must be a serializable Lisp form (a list, symbol, string, etc.).
It cannot be a lambda or contain a closure, as functions cannot be sent
to another process.

Arguments:
- `FORM` (sexp): The Lisp form to evaluate in the background worker.
- `:VARS` (alist, optional): An alist of `(symbol . value)` pairs that will
  be `let`-bound around the `FORM` in the worker process. All values in
  the alist must also be serializable.
- `:CANCEL-TOKEN` (loom-cancel-token, optional): A token for cancelling
  the operation before or during execution.
- `:PRIORITY` (integer, optional): The task's priority (lower is higher).
- `:TIMEOUT` (number, optional): Seconds before the task is timed out.

Returns:
- (loom-promise): A promise that will be settled with the result of `FORM`."
  (declare (debug t))
  `(let ((pool (loom:multiprocess-pool-default)))
     (loom:multiprocess-pool-submit pool ,form
                                    :context '((:vars . ,vars))
                                    :cancel-token ,cancel-token
                                    :priority ,priority
                                    :timeout ,timeout)))

(provide 'loom-multiprocess)
;;; loom-multiprocess.el ends here