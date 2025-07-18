;;; loom-process.el --- Low-Level Asynchronous Primitives -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides foundational primitives for launching and managing
;; background Emacs Lisp processes. It offers a robust, self-contained
;; system for running code in parallel, isolating it from the main UI thread.
;;
;; The module provides three main entry points for process execution:
;;
;; 1. `loom:process-start`: For single-shot background tasks. It launches a
;;    worker process that is fully integrated with the Loom IPC system,
;;    computes one result, returns it via a promise, and then terminates.
;;
;; 2. `loom:process-spawn-worker`: For creating persistent, long-lived worker
;;    processes, typically for use in a pool. It launches a worker that
;;    initializes IPC and then runs a specified main loop function.
;;
;; 3. `loom:process-stream`: For background tasks that produce a continuous
;;    stream of data. It returns a `loom-stream` that emits items as the
;;    worker produces them.

;;; Code:

(require 'cl-lib)
(require 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-process-error
  "A generic error during an asynchronous process operation."
  'loom-error)

(define-error 'loom-process-worker-error
  "An error occurred within a background worker process."
  'loom-process-error)

(define-error 'loom-process-exec-not-found
  "The 'emacs' executable could not be found."
  'loom-process-error)

(define-error 'loom-process-timeout
  "An asynchronous worker process timed out."
  'loom-process-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom loom-process-emacs-executable (executable-find "emacs")
  "The path to the Emacs executable to use for worker processes."
  :type 'string
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Worker Entry Points

(defun loom-process--prepare-worker-env (task-lisp)
  "Configure a worker's environment from a task payload.
This function runs inside the subordinate worker process. It sets up the
`load-path` and `require`s specified by the parent process in the
TASK-LISP payload, ensuring the worker has the necessary libraries loaded
to execute its task.

Arguments:
- `TASK-LISP` (plist): The payload sent from the parent process.

Returns:
- `nil`.

Side Effects:
- Modifies the worker's `load-path`.
- Loads features via `require`."
  (let ((load-path (plist-get task-lisp :load-path))
        (features (plist-get task-lisp :require)))
    (setq load-path (append load-path (symbol-value 'load-path)))
    (dolist (feature features) (require feature))))

(defun loom-process--handle-fatal-worker-error (err)
  "Report a fatal, unexpected error from within a worker process.
This function serializes the error ERR and prints it to stdout for the
parent process to capture. It then terminates the worker with a non-zero
exit code to signal a critical failure. This is a last-resort error
handler for when the standard IPC mechanism may not be available.

Arguments:
- `ERR` (error): The error condition to report.

Returns:
- This function does not return; it terminates the process.

Side Effects:
- Prints a serialized error to stdout.
- Terminates the current Emacs process with exit code 1."
  (let ((fatal-error
         (loom:make-error
          :type :loom-process-worker-error
          :message "Fatal error during worker initialization."
          :cause err)))
    ;; Attempt to send a structured error back to the parent via stdout.
    (princ (prin1-to-string
            `(:error ,(loom:serialize-error fatal-error))))
    (finish-output (standard-output))
    (kill-emacs 1)))

(defun loom-process-stream-invoke ()
  "Entry-point for a streaming worker (`loom:process-stream`).
This function runs in a batch Emacs process. It reads a single task
payload from stdin, then evaluates the user's form. The form is
responsible for printing S-expressions to stdout. This function prints a
final `:eof` sexp on clean exit, or an `:error` sexp if an unhandled
error occurs.

Arguments:
- None. Reads its configuration from stdin.

Returns:
- This function does not return; it terminates the process.

Side Effects:
- Prints multiple S-expressions to stdout.
- Exits the Emacs process."
  (let ((coding-system-for-write 'utf-8-emacs-unix)
        (print-escape-nonascii t))
    (condition-case err
        (let* ((task-lisp (read))
               (form (plist-get task-lisp :form))
               (vars (plist-get task-lisp :vars)))
          (loom-process--prepare-worker-env task-lisp)
          (eval `(let ,vars ,form) t)
          ;; IPC Protocol: Signal clean exit with :eof.
          (prin1 :eof (standard-output)))
      (error (loom-process--handle-fatal-worker-error err)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Process Management

(defun loom--process-cleanup-process (proc)
  "Clean up resources associated with a worker process PROC.
This is called in the main Emacs instance. It idempotently cancels any
timeout timer and kills the filter and stderr buffers associated with the
process to prevent resource leaks.

Arguments:
- `PROC` (process): The process object whose resources need cleaning.

Returns:
- `nil`.

Side Effects:
- Cancels any active timer associated with the process.
- Kills the process's filter and stderr buffers if they exist."
  (loom-log-trace (process-name proc) "Cleaning up worker process resources.")
  (when-let (timer (process-get proc 'timeout-timer))
    (cancel-timer timer)
    (process-put proc 'timeout-timer nil))
  (when-let (filter-buf (process-get proc 'filter-buffer))
    (when (buffer-live-p filter-buf) (kill-buffer filter-buf))
    (process-put proc 'filter-buffer nil))
  (when-let (stderr-buf (process-get proc 'stderr-buffer))
    (when (buffer-live-p stderr-buf) (kill-buffer stderr-buf))
    (process-put proc 'stderr-buffer nil)))

(defun loom--process-build-command (&key start-func eval-string emacs-path
                                        load-path require)
  "Construct the command list for `make-process`.
This helper function assembles the full command-line invocation required
to start a subordinate Emacs worker process with the correct environment.

Arguments:
- `:START-FUNC` (symbol): The worker's entry point function.
- `:EVAL-STRING` (string): A string of Lisp code to evaluate.
- `:EMACS-PATH` (string): Path to the emacs executable.
- `:LOAD-PATH` (list): List of paths to add to worker's `load-path`.
- `:REQUIRE` (list): List of features for the worker to `require`.

Returns:
- (list): A list of strings representing the command to execute.

Signals:
- `loom-process-exec-not-found`: If the emacs executable is not found."
  (let ((exec (or emacs-path loom-process-emacs-executable)))
    (unless (and exec (executable-find exec))
      (signal 'loom-process-exec-not-found (list exec)))
    (let* ((all-paths (cl-delete-duplicates
                       (append load-path (symbol-value 'load-path))
                       :test #'string-equal))
           (load-path-args (cl-loop for p in all-paths when p
                                    nconc `("-L" ,p)))
           (require-args (cl-loop for f in require nconc `("-l" ,f))))
      `(,exec "-Q" "-batch"
              ,@load-path-args
              ,@require-args
              ,@(cond
                 (eval-string `("--eval" ,eval-string))
                 (start-func `("--eval" ,(format "(funcall '%S)" start-func)))
                 (t (error "Either :start-func or :eval-string is required")))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:process-launch
    (&key name filter sentinel emacs-path start-func eval-string
         (load-path '()) (require '()) env)
  "Launch a subordinate Emacs process (low-level primitive).
This is the core function for creating background workers. It constructs the
command-line arguments to spawn a new Emacs process in batch mode.

Arguments:
- `:NAME` (string): A descriptive name for the subprocess.
- `:FILTER` (function): The process filter for handling stdout.
- `:SENTINEL` (function): The sentinel for handling process exit.
- `:EMACS-PATH` (string): Path to the Emacs executable to use.
- `:START-FUNC` (symbol): Function for the worker to `funcall` on startup.
- `:EVAL-STRING` (string): A string of Lisp code for the worker to evaluate.
- `:LOAD-PATH` (list): Paths to add to the worker's `load-path`.
- `:REQUIRE` (list): Features for the worker to `require`.
- `:ENV` (alist): Environment variables `(\"KEY\" . \"VAL\")`.

Returns:
- (process): The newly created Emacs worker `process` object.

Side Effects:
- Starts a new operating system process.
- Creates a new buffer for the process's stderr output.
- Modifies `process-environment` for the new process if `:ENV` is provided.

Signals:
- `loom-process-exec-not-found`: If `emacs-path` is not found."
  (let* ((proc-name (or name "loom-worker"))
         (command (loom--process-build-command
                   :start-func start-func :eval-string eval-string
                   :emacs-path emacs-path :load-path load-path
                   :require require))
         (stderr-buffer (generate-new-buffer (format "*%s-stderr*" proc-name)))
         (process-environment
          (if env
              (append (mapcar (lambda (x) (format "%s=%s" (car x) (cdr x))) env)
                      process-environment)
            process-environment)))
    (loom-log-info proc-name "Launching worker process.")
    (let ((proc (make-process
                 :name proc-name :command command :connection-type 'pipe
                 :noquery t :coding 'utf-8-emacs-unix
                 :stderr stderr-buffer :filter filter :sentinel sentinel)))
      (process-put proc 'stderr-buffer stderr-buffer)
      (loom-log-debug proc-name "Worker process launched. PID: %d"
                      (process-id proc))
      proc)))

;;;###autoload
(cl-defun loom:process-spawn-worker (&key name worker-id main-loop-fn
                                          (load-path '()) (require '()) env)
  "Launch a persistent, IPC-enabled worker process.
This function is for creating long-lived workers, typically for a pool.
The worker initializes its Loom IPC connection and then calls `MAIN-LOOP-FN`.

Arguments:
- `:NAME` (string): A descriptive name for the worker process.
- `:WORKER-ID` (string): A unique ID for the worker's IPC channel.
- `:MAIN-LOOP-FN` (symbol): The function for the worker to run after init.
- `:LOAD-PATH` (list): Paths to add to the worker's `load-path`.
- `:REQUIRE` (list): Features for the worker to `require`.
- `:ENV` (alist): Environment variables `(\"KEY\" . \"VAL\")`.

Returns:
- (process): The newly created Emacs worker `process` object.

Side Effects:
- Launches a new Emacs process via `loom:process-launch`.

Signals:
- `loom-process-exec-not-found`: If the Emacs executable cannot be found."
  (let* ((parent-id (or loom--ipc-my-id (format "%d" (emacs-pid))))
         (eval-string
          (prin1-to-string
           `(progn
              ;; 1. Load required libraries.
              (require 'loom)
              (require 'loom-process)
              ;; 2. Initialize the worker's IPC, connecting back to the parent.
              (loom:init :my-id ,worker-id :target-instance-id ,parent-id)
              ;; 3. Start the persistent task processing loop.
              (funcall ',main-loop-fn)))))
    (loom:process-launch :name name
                         :eval-string eval-string
                         :filter nil
                         :sentinel nil
                         :load-path load-path
                         :require (append '(loom loom-process) require)
                         :env env)))

;;;###autoload
(cl-defun loom:process-start
    (form &key vars cancel-token (load-path '()) (require '()) timeout env)
  "Execute `FORM` in a subordinate Emacs process, returning a promise.
This is for a single-shot task. The worker process initializes a Loom
IPC connection, computes a single result, sends it back, and terminates.

NOTE: This creates a new process for each call and is inefficient for
high-frequency tasks. For such cases, a persistent process pool is
recommended via `loom:multiprocess!`.

Arguments:
- `FORM` (form): The Lisp form to execute in the background.
- `:VARS` (alist): `(symbol . value)` pairs to `let`-bind around `FORM`.
- `:CANCEL-TOKEN` (loom-cancel-token): A token to cancel the operation.
- `:LOAD-PATH` (list): Paths to add to the worker's `load-path`.
- `:REQUIRE` (list): Features to `require` in the worker.
- `:TIMEOUT` (number): Seconds to wait before killing the process.
- `:ENV` (alist): Environment variables `(\"KEY\" . \"VAL\")`.

Returns:
- (loom-promise): A promise that resolves with the result of `FORM`.

Side Effects:
- Launches a new Emacs process via `loom:process-launch`.
- Starts a timer if `:timeout` is specified.
- Adds a cancellation callback if `:cancel-token` is provided.

Signals:
- `error`: If the main Loom library is not initialized."
  (unless loom--initialized
    (error (concat "Parent Loom instance must be initialized with "
                   "`loom:init` before launching a worker")))

  (let* ((promise-name (format "process-%S" form))
         (promise (loom:promise :cancel-token cancel-token :name promise-name))
         (proc nil)
         (parent-id (or loom--ipc-my-id (format "%d" (emacs-pid))))
         (worker-id (format "worker-%s" (make-symbol "t")))
         (promise-id (loom-promise-id promise))
         (worker-lisp
          `(progn
             (require 'loom)
             (require 'loom-process)
             (loom:init :my-id ,worker-id :target-instance-id ,parent-id)
             (let ((response
                    (condition-case task-err
                        (list :result (let ,vars ,form))
                      (error
                       (list :error
                             (loom:serialize-error
                              (loom:make-error
                               :type :loom-process-worker-error
                               :cause task-err)))))))
               (let ((proxy-promise (%%make-promise :id ',promise-id)))
                 (loom:dispatch-to-main-thread
                  proxy-promise :promise-settled response)))
             (kill-emacs 0)))
         (eval-string (prin1-to-string worker-lisp)))

    (setq proc
          (loom:process-launch
           :name promise-name
           :eval-string eval-string
           :filter nil
           :sentinel
           (lambda (p event)
             (when (loom:pending-p promise)
               (let* ((stderr-buf (process-get p 'stderr-buffer))
                      (stderr (and stderr-buf
                                   (buffer-string-no-properties))))
                 (loom-log-error (process-name p)
                                 "Worker died unexpectedly: %s" event)
                 (loom:reject
                  promise
                  (loom:make-error
                   :type :loom-process-worker-error
                   :message (format "Worker died unexpectedly: %s" event)
                   :stderr stderr)))
               (loom--process-cleanup-process p)))
           :load-path load-path
           :require (append '(loom loom-process) require)
           :env env))

    (setf (loom-promise-proc promise) proc)

    (when timeout
      (loom-log-trace promise-name "Setting timeout for %.2f seconds." timeout)
      (process-put proc 'timeout-timer
                   (run-at-time timeout nil
                                (lambda ()
                                  (when (process-live-p proc)
                                    (kill-process proc))
                                  (loom:reject
                                   promise
                                   (make-instance 'loom-process-timeout))))))

    (when cancel-token
        (loom-log-trace promise-name "Setting up cancellation.")
        (loom:cancel-token-add-callback
         cancel-token (lambda (_)
                        (loom-log-debug promise-name "Cancellation triggered.")
                        (delete-process proc))))
    promise))

;;;###autoload
(cl-defun loom:process-stream
    (form &key vars cancel-token (load-path '()) (require '()) timeout env)
  "Execute `FORM` in a worker, returning a stream of its stdout.
Each S-expression `prin1`'d to stdout by the worker becomes an item in
the returned stream. This method of IPC is distinct from the main
`loom-ipc` system and is suitable for continuous data flows.

Arguments:
- `FORM` (form): The Lisp form to execute in the background.
- `:VARS` (alist): `(symbol . value)` pairs to `let`-bind around `FORM`.
- `:CANCEL-TOKEN` (loom-cancel-token): A token to cancel the operation.
- `:LOAD-PATH` (list): Paths to add to the worker's `load-path`.
- `:REQUIRE` (list): Features to `require` in the worker.
- `:TIMEOUT` (number): Seconds to wait before killing the process.
- `:ENV` (alist): Environment variables `(\"KEY\" . \"VAL\")`.

Returns:
- (loom-stream): A stream that emits items from the worker.

Side Effects:
- Launches a new Emacs process via `loom:process-launch`.
- Creates a buffer to parse the worker's streaming response.
- Sends the task payload to the worker process via stdin.
- Starts a timer if `:timeout` is specified.
- Adds a cancellation callback if `:cancel-token` is provided."
  (let* ((stream-name (format "process-stream-%S" form))
         (stream (loom:stream :name stream-name))
         (proc nil))
    (loom-log-debug stream-name "Initiating streaming process.")
    (setq proc
          (loom:process-launch
           :start-func 'loom-process-stream-invoke
           :name stream-name
           :filter
           (lambda (p string)
             (let ((buffer (process-get p 'filter-buffer)))
               (unless buffer
                 (setq buffer (generate-new-buffer
                               (format "*%s-filter*" (process-name p))))
                 (process-put p 'filter-buffer buffer))
               (with-current-buffer buffer
                 (goto-char (point-max))
                 (insert string)
                 (goto-char (point-min))
                 ;; This loop robustly parses complete S-expressions from the
                 ;; process output buffer as they arrive.
                 (while (ignore-errors
                          (let ((end (scan-sexps (point) 1)))
                            (when end
                              (let* ((sexp-str
                                      (buffer-substring-no-properties
                                       (point) end))
                                     (chunk (read-from-string sexp-str)))
                                (delete-region (point) end)
                                (cond
                                 ((eq chunk :eof)
                                  (loom-log-debug stream-name "EOF received.")
                                  (loom:stream-close stream))
                                 ((and (consp chunk) (eq (car chunk) :error))
                                  (loom-log-warn stream-name "Error received.")
                                  (loom:stream-error
                                   stream
                                   (loom:deserialize-error (cadr chunk))))
                                 (t
                                  (loom-log-trace stream-name "Item received.")
                                  (loom:stream-write stream chunk))))
                              t)))))))
           :sentinel
           (lambda (p event)
             (if (string-match-p "finished" event)
                 (progn
                   (loom-log-debug (process-name p) "Stream process finished.")
                   (loom:stream-close stream))
               (let* ((stderr-buf (process-get p 'stderr-buffer))
                      (stderr (and stderr-buf
                                   (buffer-string-no-properties))))
                 (loom-log-error (process-name p)
                                 "Stream worker died: %s" event)
                 (loom:stream-error
                  stream (loom:make-error
                          :type :loom-process-worker-error
                          :message (format "Worker died: %s" event)
                          :stderr stderr))))
             (loom--process-cleanup-process p))
           :load-path load-path
           :require (cons 'loom-process require)
           :env env))

    (when timeout
      (loom-log-trace stream-name "Setting timeout for %.2f seconds." timeout)
      (process-put proc 'timeout-timer
                   (run-at-time timeout nil (lambda ()
                                              (when (process-live-p proc)
                                                 (delete-process proc))))))
    (when cancel-token
      (loom-log-trace stream-name "Setting up cancellation.")
      (loom:cancel-token-add-callback
       cancel-token (lambda (_)
                      (loom-log-debug stream-name "Cancellation triggered.")
                      (delete-process proc))))

    (let ((payload (prin1-to-string `(:form ,form :vars ,vars
                                            :load-path ,load-path
                                            :require ,require))))
      (loom-log-trace stream-name "Sending payload to worker.")
      (process-send-string proc payload))
    stream))

(provide 'loom-process)
;;; loom-process.el ends here