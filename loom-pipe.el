;;; loom-pipe.el --- Named Pipe (FIFO) Implementation -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides a robust, low-level abstraction for named pipes (FIFOs)
;; in Emacs Lisp, primarily for inter-process communication (IPC). It is
;; especially useful for communicating between separate Emacs instances.
;;
;; It encapsulates the creation, reading from, writing to, and cleanup of
;; FIFOs, leveraging standard shell commands (`mkfifo`, `cat`) and Emacs's
;; process management primitives.
;;
;; ## Key Features
;;
;; - **`loom-pipe` struct:** Represents a named pipe instance, managing its
;;   path, mode (read/write), and associated Emacs process.
;; - **`loom:pipe` constructor:** Initializes a `loom-pipe` instance,
;;   creating the FIFO file if necessary and starting the underlying
;;   process (reader or writer).
;; - **`loom:pipe-send`:** Sends a string to a `loom-pipe` configured for
;;   writing.
;; - **`loom:pipe-cleanup`:** Properly shuts down the associated process and
;;   deletes the FIFO file.
;; - **Automatic Cleanup:** All created pipes are tracked and automatically
;;   cleaned up when Emacs exits, preventing orphaned FIFO files or processes.

;;; Code:

(require 'cl-lib)

(require 'loom-log)
(require 'loom-errors)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom--all-pipes '()
  "A list of all active `loom-pipe` instances created in the session.
This list is used by the `loom--pipe-shutdown-hook` to ensure that
all pipes are properly cleaned up when Emacs exits, preventing
orphaned FIFO files and background processes.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-pipe-error
  "A generic error related to a `loom-pipe` operation."
  'loom-error)

(define-error 'loom-pipe-creation-error
  "Error signaled when a named pipe (FIFO) cannot be created.
This can occur if the `mkfifo` command is not found in the system's
PATH, or if there are insufficient permissions to create a file at
the specified path."
  'loom-pipe-error)

(define-error 'loom-pipe-process-error
  "Error signaled when the underlying process for a `loom-pipe` fails.
This can happen during initialization if the `cat` or `sh` process
fails to start, or during operation if the process terminates
unexpectedly."
  'loom-pipe-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definition

(cl-defstruct (loom-pipe (:constructor %%make-loom-pipe) (:copier nil))
  "Represents a named pipe (FIFO) instance for IPC.
This struct encapsulates all the state associated with a single named
pipe endpoint, including its filesystem path, its mode of operation,
and the underlying Emacs process that reads from or writes to it.

Do not create or modify instances of this struct directly. Use the
public API functions `loom:pipe`, `loom:pipe-send`, and `loom:pipe-cleanup`.

Fields:
- `path` (string): The full file path to the named pipe.
- `mode` (symbol): The mode of this pipe instance: `:read` or `:write`.
- `process` (process): The underlying Emacs process (e.g., `cat`).
- `buffer` (buffer or nil): The buffer for reading process output.
- `filter` (function or nil): The filter function for the process.
- `sentinel` (function or nil): The sentinel function for the process."
  (path     nil :type string)
  (mode     nil :type (member :read :write))
  (process  nil)
  (buffer   nil)
  (filter   nil :type (or function null))
  (sentinel nil :type (or function null)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom--pipe-create-fifo (path)
  "Create a named pipe (FIFO) at PATH using `mkfifo`.
This is a low-level helper that executes the external `mkfifo`
command to create the special file required for named pipe
communication.

Arguments:
- `PATH` (string): The full path where the FIFO will be created.

Returns:
`t` on successful creation.

Signals:
- `loom-pipe-creation-error`: If `mkfifo` is not found in the
  system's PATH, or if the command returns a non-zero exit status,
  indicating a failure (e.g., due to permissions)."
  (unless (executable-find "mkfifo")
    (signal 'loom-pipe-creation-error
            '(:message "mkfifo executable not found")))
  (let ((status (call-process "mkfifo" nil nil nil path)))
    (unless (zerop status)
      (signal 'loom-pipe-creation-error
              `(:message ,(format "Failed to create pipe at %s (status: %d)"
                                  path status))))
    (loom-log :debug nil "Created FIFO at: %s" path)
    t))

(defun loom--pipe-get-cat-command ()
  "Determine the best `cat` command for unbuffered I/O.
This helper attempts to find the `stdbuf` utility. If available, it
uses `stdbuf -i0 -o0 -e0 cat` to completely disable buffering on
stdin, stdout, and stderr, which is critical for low-latency IPC.
If `stdbuf` is not found, it falls back to plain `cat` and logs a
warning.

Returns:
A list of strings representing the program and its arguments."
  (if (executable-find "stdbuf")
      '("stdbuf" "-i0" "-o0" "-e0" "cat")
    (loom-log :warn nil (concat "`stdbuf` not found, using plain `cat`. "
                                "IPC might be buffered."))
    '("cat")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:pipe (&key path mode filter sentinel buffer)
  "Create and initialize a `loom-pipe` instance.
This function is the primary constructor for named pipes. It sets up a
FIFO at the specified PATH and starts a background process to either
read from it (`:read` mode) or write to it (`:write` mode).

Arguments:
- `:PATH` (string): The mandatory file path for the named pipe.
- `:MODE` (symbol): The mandatory mode of operation: `:read` or `:write`.
- `:FILTER` (function, optional): A process filter function to handle
  incoming data. Only valid for `:read` mode.
- `:SENTINEL` (function, optional): A process sentinel function to
  monitor the state of the underlying process.
- `:BUFFER` (buffer or string, optional): The buffer to associate with
  the process for reading output. Required for `:read` mode; if `nil`,
  a new buffer is generated automatically.

Returns:
A new `loom-pipe` struct instance on success.

Side Effects:
- Creates a FIFO file on the filesystem (if in `:read` mode and the
  file does not already exist).
- Starts a background process (`cat` or `sh`).
- Creates a new Emacs buffer if one is not provided for `:read` mode.
- Adds the new pipe instance to the global `loom--all-pipes` list for
  automatic cleanup on shutdown.

Signals:
- `error`: If required arguments like `:path` or `:mode` are missing
  or have invalid types.
- `loom-pipe-process-error`: If the underlying process fails to start.
- `loom-pipe-creation-error`: If the FIFO file cannot be created."
  (unless (and path (stringp path))
    (error "A valid string :path is required for loom:pipe"))
  (unless (memq mode '(:read :write))
    (error "Invalid :mode '%S'. Must be :read or :write" mode))
  (when (and (eq mode :write) filter)
    (error "A :filter is only valid for pipes in :read mode"))

  (loom-log :info nil "Initializing pipe '%s' in :%s mode." path mode)

  ;; Use `unwind-protect` to guarantee cleanup of partial resources if an error
  ;; occurs anywhere during the initialization process.
  (let (pipe-process pipe-buffer successful-p)
    (unwind-protect
        ;; Main body: Attempt to create all resources.
        (progn
          (setq pipe-buffer
                (and (eq mode :read)
                     (or buffer
                         (generate-new-buffer
                          (format " *loom-pipe-reader: %s*"
                                  (file-name-nondirectory path))))))
          (let ((cat-command (loom--pipe-get-cat-command)))
            (condition-case err
                (progn
                  (pcase mode
                    (:read
                     ;; The reader creates the FIFO if it doesn't exist.
                     (unless (file-exists-p path)
                       (loom--pipe-create-fifo path))
                     (setq pipe-process
                           (apply #'start-process
                                  (format "loom-pipe-reader-%s"
                                          (file-name-nondirectory path))
                                  pipe-buffer
                                  (car cat-command)
                                  (append (cdr cat-command) (list path)))))
                    (:write
                     ;; FIX: Check that the FIFO exists and is the correct
                     ;; file type to prevent a race condition.
                     (unless (file-exists-p path)
                       (error (concat "Pipe writer for '%s' cannot start: "
                                      "FIFO does not exist.") path))
                     (unless (eq 'fifo (nth 2 (file-attributes path)))
                       (error "Pipe writer for '%s' cannot start: a file exists but is not a FIFO."
                              path))
                     ;; The `sh -c 'cmd > fifo'` pattern opens a pipe for
                     ;; writing without the shell command itself closing it.
                     (let ((sh-command
                            (format "%s > %s"
                                    (string-join cat-command " ")
                                    (shell-quote-argument path))))
                       (setq pipe-process
                             (start-process
                              (format "loom-pipe-writer-%s"
                                      (file-name-nondirectory path))
                              nil "sh" "-c" sh-command)))))

                  ;; After starting, verify the process is live.
                  (unless (process-live-p pipe-process)
                    (error "Failed to start underlying process.")))
              (error
               (loom-log :error nil "Failed to initialize pipe '%s': %S"
                         path err)
               (signal 'loom-pipe-process-error
                       `(:message ,(format "Pipe init failed for %s" path)
                         :cause ,err)))))

          ;; Attach filter and sentinel after process is live.
          (when filter (set-process-filter pipe-process filter))
          (when sentinel (set-process-sentinel pipe-process sentinel))

          (loom-log :info nil "Pipe '%s' initialized successfully." path)
          (let ((new-pipe (%%make-loom-pipe :path path
                                            :mode mode
                                            :process pipe-process
                                            :buffer pipe-buffer
                                            :filter filter
                                            :sentinel sentinel)))
            ;; Track the new pipe for automatic cleanup.
            (push new-pipe loom--all-pipes)
            ;; Mark as successful ONLY at the very end.
            (setq successful-p t)
            new-pipe))

      ;; Cleanup form: Runs if an error occurred above.
      (unless successful-p
        (loom-log :warn nil
                  (concat "Init of pipe '%s' failed. "
                          "Cleaning up partial resources.")
                  path)
        (when (and pipe-process (process-live-p pipe-process))
          (delete-process pipe-process))
        ;; The reader creates the file, so only it should clean it up.
        (when (and (eq mode :read) (file-exists-p path))
          (ignore-errors (delete-file path)))
        (when (and pipe-buffer (buffer-live-p buffer))
          (kill-buffer buffer))))))
          
;;;###autoload
(defun loom:pipe-send (pipe string)
  "Send a STRING to a `loom-pipe` configured for writing.

Arguments:
- `PIPE` (loom-pipe): The pipe instance to send data through.
- `STRING` (string): The data to send. It is sent as-is.

Returns: `t` on success.

Signals:
- `error`: If `PIPE` is not a valid `loom-pipe` instance, is not in
  `:write` mode, or its underlying process is not live."
  (unless (loom-pipe-p pipe)
    (error "Argument must be a loom-pipe instance, got: %S" pipe))
  (unless (eq (loom-pipe-mode pipe) :write)
    (error "Pipe '%s' is in :read mode, cannot send" (loom-pipe-path pipe)))
  (unless (process-live-p (loom-pipe-process pipe))
    (error "Process for pipe '%s' is not live" (loom-pipe-path pipe)))

  (loom-log :debug nil "Sending to pipe '%s': %S" (loom-pipe-path pipe) string)
  (process-send-string (loom-pipe-process pipe) string)
  t)

;;;###autoload
(defun loom:pipe-cleanup (pipe)
  "Shut down the process and clean up resources for a `loom-pipe`.
This function is idempotent, meaning it is safe to call multiple
times on the same pipe instance. It ensures all associated
resources (process, buffer, file) are released.

Arguments:
- `PIPE` (loom-pipe): The pipe instance to clean up.

Returns: `t`.

Side Effects:
- Deletes the underlying OS process.
- Deletes the FIFO file from the filesystem.
- Kills the associated Emacs buffer (if any).
- Removes the pipe from the global `loom--all-pipes` tracking list.
- Clears all fields of the `PIPE` struct to `nil`."
  (unless (loom-pipe-p pipe)
    (error "Argument must be a loom-pipe instance, got: %S" pipe))

  (let ((path (loom-pipe-path pipe))
        (process (loom-pipe-process pipe))
        (buffer (loom-pipe-buffer pipe)))
    (loom-log :info nil "Cleaning up pipe '%s'." path)

    ;; Shut down the process.
    (when (and process (process-live-p process))
      (delete-process process)
      (loom-log :debug nil "Deleted process for pipe '%s'." path))

    ;; Delete the FIFO file.
    (when (and path (file-exists-p path))
      (ignore-errors (delete-file path))
      (loom-log :debug nil "Deleted FIFO file: %s" path))

    ;; Kill the associated buffer.
    (when (and buffer (buffer-live-p buffer))
      (kill-buffer buffer)
      (loom-log :debug nil "Killed buffer for pipe '%s'." path))

    ;; Clear struct fields to mark the instance as defunct.
    (setf (loom-pipe-process pipe) nil
          (loom-pipe-buffer pipe) nil
          (loom-pipe-path pipe) nil
          (loom-pipe-mode pipe) nil
          (loom-pipe-filter pipe) nil
          (loom-pipe-sentinel pipe) nil)

    ;; Remove from global tracking list.
    (setq loom--all-pipes (delete pipe loom--all-pipes))
    (loom-log :info nil "Pipe '%s' cleanup complete." path))
  t)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Shutdown Hook

(defun loom--pipe-shutdown-hook ()
  "Clean up all active `loom-pipe` instances on Emacs shutdown."
  (when loom--all-pipes
    (loom-log :info nil "Emacs shutdown: Cleaning up %d active pipe(s)."
              (length loom--all-pipes))
    ;; Iterate over a copy of the list, because `loom:pipe-cleanup`
    ;; modifies the original `loom--all-pipes` list, which would
    ;; corrupt the iteration.
    (dolist (pipe (copy-sequence loom--all-pipes))
      (loom:pipe-cleanup pipe))))

(add-hook 'kill-emacs-hook #'loom--pipe-shutdown-hook)

(provide 'loom-pipe)
;;; loom-pipe.el ends here
