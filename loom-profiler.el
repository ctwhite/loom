;;; loom-profiler.el --- A Non-Intrusive Sampling Profiler
;;; -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides a non-intrusive profiler for the Loom library,
;; leveraging Emacs's advising capabilities for data collection and
;; `loom-poll` for periodic, automatic reporting.
;;
;; By advising functions, this profiler can measure execution time
;; without modifying the original source code. The `loom-poll` integration
;; allows for live, background reporting of performance metrics, giving
;; developers continuous insight into their application's hotspots.
;;
;; ## Key Features:
;;
;; - **Advice-Based:** Uses Emacs's `advice-add` to wrap functions,
;;   ensuring that the profiler is non-intrusive and does not require
;;   any changes to the code being profiled.
;;
;; - **Thread-Safe Data Collection:** All profiling data is stored in a
;;   hash table protected by a `loom-lock`, making it safe to use in
;;   multi-threaded applications.
;;
;; - **Live Reporting:** Integrates with `loom-poll` to periodically
;;   print a summary of the collected performance data, allowing for
;;   real-time monitoring of application hotspots.
;;
;; - **Feature-Level Instrumentation:** Provides convenience functions to
;;   instrument all functions defined within a given Emacs Lisp feature
;;   (library).

;;; Code:

(require 'cl-lib)

(require 'loom-poll)
(require 'loom-lock)
(require 'loom-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom--profiler-active-p nil
  "A boolean flag indicating if the profiler is currently collecting data.")

(defvar loom--profiler-samples (make-hash-table :test 'eq)
  "A hash table to store profiling data.
Keys are function symbols. Values are plists with `:count` and `:total-time`.")

(defvar loom--profiler-lock (loom:make-lock)
  "A mutex to protect thread-safe access to `loom--profiler-samples`.")

(defvar loom--profiler-poll-task-id nil
  "The symbol ID of the periodic reporting task registered with `loom-poll`.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defface loom-profiler-report-face
  '((t :foreground "#8abeb7"))
  "Face for the profiler report headers (Cyan)."
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Implementation

(defun loom--profiler-advice (original-fn &rest args)
  "The 'around' advice function that measures execution time.
This function wraps an instrumented function. It only collects data if
the `loom--profiler-active-p` flag is set.

Arguments:
- `ORIGINAL-FN` (function): The original function being advised.
- `ARGS` (&rest): The arguments passed to the original function.

Returns:
- The return value of `ORIGINAL-FN`."
  (if loom--profiler-active-p
      ;; If profiling is active, measure the execution time.
      (let ((start-time (float-time)))
        (unwind-protect
             ;; Execute the original function with its arguments.
             (apply original-fn args)
          ;; This cleanup block runs even if the original function errors.
          (let* ((end-time (float-time))
                 (duration (- end-time start-time)))
            ;; Update the profiling data for this function in a thread-safe manner.
            (loom:with-mutex! loom--profiler-lock
              (let* ((data (gethash original-fn loom--profiler-samples
                                    '(:count 0 :total-time 0.0)))
                     (new-count (1+ (plist-get data :count)))
                     (new-time (+ (plist-get data :total-time) duration)))
                (puthash original-fn `(:count ,new-count
                                       :total-time ,new-time)
                         loom--profiler-samples))))))
    ;; If profiling is not active, just call the original function
    ;; with no overhead.
    (apply original-fn args)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:profiler-start (&key (interval 5))
  "Start the profiler and begin collecting data.
This activates the profiling advice and starts a background polling
task to report summaries periodically.

Arguments:
- `:INTERVAL` (number): The interval in seconds for the
  background reporting task. Defaults to 5 seconds.

Returns: `nil`.

Side Effects:
- Sets `loom--profiler-active-p` to `t`.
- Registers a periodic task with `loom-poll`."
  (interactive)
  (loom:log! :info 'loom-profiler "Starting profiler...")
  (setq loom--profiler-active-p t)
  ;; Register a periodic task to print a summary to the log.
  (when-let (poll (loom:poll-default))
    (setq loom--profiler-poll-task-id
          (make-symbol "loom-profiler-reporting-task"))
    (loom:poll-register-periodic-task
     poll loom--profiler-poll-task-id
     (lambda () (loom:log! :info 'loom-profiler
                           "Live Profile Report:\n%s"
                           (loom:profiler-report :no-header t)))
     interval))
  (message "Loom profiler started."))

;;;###autoload
(defun loom:profiler-stop ()
  "Stop the profiler from collecting data and halt the reporting task.
Previously collected data is retained until cleared.

Arguments: None.

Returns: `nil`.

Side Effects:
- Sets `loom--profiler-active-p` to `nil`.
- Removes the periodic reporting task from `loom-poll`."
  (interactive)
  (loom:log! :info 'loom-profiler "Stopping profiler...")
  (setq loom--profiler-active-p nil)
  ;; Remove the periodic reporting task.
  (when-let (poll (loom:poll-default))
    (when loom--profiler-poll-task-id
      (loom:poll-unregister-periodic-task poll loom--profiler-poll-task-id)
      (setq loom--profiler-poll-task-id nil)))
  (message "Loom profiler stopped."))

;;;###autoload
(defun loom:profiler-instrument-function (function-symbol)
  "Add profiling advice to a single FUNCTION-SYMBOL.

Arguments:
- `FUNCTION-SYMBOL` (symbol): The function to instrument.

Returns: `nil`.

Side Effects:
- Adds 'around' advice to the specified function."
  (interactive (list (intern (completing-read "Instrument function: "
                                              obarray 'fboundp t))))
  (loom:log! :debug 'loom-profiler "Instrumenting function: %s"
             function-symbol)
  (advice-add function-symbol :around #'loom--profiler-advice))

;;;###autoload
(defun loom:profiler-uninstrument-function (function-symbol)
  "Remove profiling advice from a single FUNCTION-SYMBOL.

Arguments:
- `FUNCTION-SYMBOL` (symbol): The function to uninstrument.

Returns: `nil`.

Side Effects:
- Removes the profiling advice from the specified function."
  (interactive (list (intern (completing-read "Uninstrument function: "
                                              obarray 'fboundp t))))
  (loom:log! :debug 'loom-profiler "Uninstrumenting function: %s"
             function-symbol)
  (advice-remove function-symbol #'loom--profiler-advice))

;;;###autoload
(defun loom:profiler-instrument-feature (feature)
  "Add profiling advice to all functions defined in a FEATURE.

Arguments:
- `FEATURE` (symbol): The feature (library) to instrument.

Returns: `nil`.

Side Effects:
- Adds 'around' advice to all functions defined in the feature's file."
  (interactive (list (intern (completing-read "Instrument feature: "
                                              features))))
  (loom:log! :info 'loom-profiler
             "Instrumenting all functions in feature: %s" feature)
  (let ((file (find-library-name (symbol-name feature))))
    (if file
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          ;; This regex finds functions defined with defun, defmacro,
          ;; cl-defun, or cl-defmacro.
          (while (re-search-forward
                  "^[ \t]*((?:cl-)?def(?:un|macro)[ \t\n]+\
\([a-zA-Z0-9:/-]+\\)"
                  nil t)
            (let ((fn-name (intern-soft (match-string 2))))
              (when (and fn-name (fboundp fn-name))
                (loom:profiler-instrument-function fn-name)))))
      (loom:log! :warn 'loom-profiler
                 "Could not find library file for feature '%s'."
                 feature))
    (message "Instrumented feature %s" feature)))

;;;###autoload
(cl-defun loom:profiler-report (&key (sort-by :total-time) no-header)
  "Generate and return a formatted string report of the profiling data.

Arguments:
- `:SORT-BY` (keyword): The metric to sort by. Can be
  `:total-time` (default), `:count`, or `:avg-time`.
- `:NO-HEADER` (boolean): If t, omit the report header.

Returns:
- (string): The formatted report."
  (interactive)
  (let* ((header (unless no-header
                   (propertize
                    (format "--- Loom Profiler Report (Sorted by %s) ---"
                            sort-by)
                    'face 'loom-profiler-report-face)))
         ;; Safely copy the data from the shared hash table.
         (data (loom:with-mutex! loom--profiler-lock
                 (let (res)
                   (maphash (lambda (k v) (push (cons k v) res))
                            loom--profiler-samples)
                   res)))
         ;; Sort the data according to the specified key.
         (sorted-data
          (sort data
                (pcase sort-by
                  (:count (lambda (a b) (> (plist-get (cdr a) :count)
                                           (plist-get (cdr b) :count))))
                  (:avg-time (lambda (a b)
                               (let ((avg-a (/ (plist-get (cdr a) :total-time)
                                               (plist-get (cdr a) :count)))
                                     (avg-b (/ (plist-get (cdr b) :total-time)
                                               (plist-get (cdr b) :count))))
                                 (> avg-a avg-b))))
                  (_ (lambda (a b) (> (plist-get (cdr a) :total-time)
                                      (plist-get (cdr b) :total-time)))))))
         (report-lines
          (mapcar
           (lambda (item)
             (let* ((fn (car item))
                    (count (plist-get (cdr item) :count))
                    (total-time (plist-get (cdr item) :total-time))
                    (avg-time (if (zerop count) 0
                                (/ total-time count))))
               (format "%-40s Count: %-8d Total: %-10.4fms Avg: %.4fms"
                       fn count (* total-time 1000) (* avg-time 1000))))
           sorted-data)))
    (string-join (cons header report-lines) "\n")))

;;;###autoload
(defun loom:profiler-clear ()
  "Clear all collected profiling data.

Arguments: None.

Returns: `nil`.

Side Effects:
- Clears the `loom--profiler-samples` hash table."
  (interactive)
  (loom:with-mutex! loom--profiler-lock
    (clrhash loom--profiler-samples))
  (loom:log! :info 'loom-profiler "Profiler data cleared.")
  (message "Loom profiler data cleared."))

(provide 'loom-profiler)
;;; loom-profiler.el ends here