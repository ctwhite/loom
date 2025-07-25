;;; loom-log.el --- Context-Aware Logging Core Library -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides a core, context-aware logging system for the Loom
;; library. It is designed to be instance-based, allowing for multiple,
;; independent logging configurations within a single Emacs session.
;;
;; Key Features:
;;
;; -   **Instance-Based Configuration:** The system is built around a
;;     `loom-log-server` object. Each server instance encapsulates its
;;     own configuration, message queue, and processing timer.
;; -   **Pluggable Transport:** `loom-log-server` instances can be extended
;;     with external transport mechanisms by setting the `send-raw-fn`
;;     (for outbound log messages) and `start-listener-fn` (for inbound
;;     log messages) slots. This allows modular extensions for distributed
;;     logging (e.g., `warp-log`).
;; -   **Server Address Retrieval:** Provides a mechanism for remote
;;     entities (like Warp workers) to retrieve the active log server's
;;     address via `loom:log-get-server-address`.
;; -   **Extensible Log Entry Data:** Log entries now encapsulate a flexible
;;     `extra-data` plist, allowing modules like Warp to inject additional
;;     context (e.g., worker ID, rank, cluster ID). The default formatter
;;     displays this data generically.
;; -   **Pluggable Appenders/Sinks:** Supports various output destinations
;;     (e.g., Emacs buffer, file with rotation) through a standardized
;;     `loom-log-appender` interface.
;; -   **Advanced Queue Management (Priority Queue):** Integrates a
;;     **thread-safe `loom-priority-queue`** to store log entries. This
;;     ensures that log messages are always processed in **chronological
;;     order by their timestamp**, even if they arrive out-of-order in
;;     distributed environments. It supports burst, idle, and hybrid
;;     flushing strategies.
;; -   **Log Condensing:** Adjacent duplicate log entries (based on
;;     content) are condensed into a single `loom-log-entry` with a
;;     `count` field, reducing redundant output.
;; -   **Rate Limiting (`:throttle` and `:once`):** Provides built-in
;;     mechanisms to suppress high-frequency or one-time messages directly
;;     at the logging call site.
;; -   **Thread-Safety:** All log messages are safely inserted into the
;;     priority queue, ensuring concurrent writes do not corrupt state.
;; -   **Face-based Formatting:** Log output in Emacs buffers uses distinct
;;     faces for different log levels, timestamps, and locations for
;;     enhanced readability.
;;
;; This module is deliberately kept free of direct dependencies on network
;; or inter-process communication (IPC) primitives. These responsibilities
;; are delegated to external modules (like `warp-log`) that "plug in" their
;; transport functions, making `loom-log` a highly abstract and reusable
;; logging core.
;;
;;; Code:

(require 'cl-lib)
(require 's)
(require 'backtrace)
(require 'seq)
(require 'json)

(require 'loom-lock)
(require 'loom-queue)
(require 'loom-priority-queue)
(require 'loom-context)

;; Ensure native-compiler knows about these functions/macros during compilation
(eval-when-compile (require 'cl-lib))
(eval-when-compile (require 'seq))
(eval-when-compile (require 'loom-priority-queue))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 1. Faces for Log Output

(defface loom-log-fatal-face
  '((t :foreground "#cc6666" :weight bold))
  "Face for fatal log messages."
  :group 'loom)

(defface loom-log-error-face
  '((t :foreground "#cc6666"))
  "Face for error log messages."
  :group 'loom)

(defface loom-log-warn-face
  '((t :foreground "#f0c674"))
  "Face for warning log messages."
  :group 'loom)

(defface loom-log-info-face
  '((t :foreground "#b5bd68"))
  "Face for info log messages."
  :group 'loom)

(defface loom-log-debug-face
  '((t :foreground "#81a2be"))
  "Face for debug log messages."
  :group 'loom)

(defface loom-log-trace-face
  '((t :foreground "#b294bb"))
  "Face for trace log messages."
  :group 'loom)

(defface loom-log-timestamp-face
  '((t :foreground "#969896"))
  "Face for log timestamps."
  :group 'loom)

(defface loom-log-location-face
  '((t :foreground "#8abeb7"))
  "Face for log locations."
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 2. Global State

(defvar loom--log-default-server nil
  "The default global `loom-log-server` instance, created on-demand.
This instance is typically used by the `loom:log!` macro when no
specific server is provided.")

(defvar loom--log-once-tracker (make-hash-table :test 'equal)
  "Hash table to store IDs of messages logged with `:once` to ensure they
are logged only once. Keys are the unique IDs, values are `t` once logged.")

(defvar loom--log-throttle-tracker (make-hash-table :test 'equal)
  "Hash table to store timestamps of last log for messages with `:throttle`
to rate-limit them. Keys are the unique IDs, values are float timestamps.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 3. Struct Definitions

(cl-defstruct (loom-log-entry
               (:constructor loom--make-log-entry))
  "Represents a single log message with all its associated context.
This struct acts as the canonical data unit for logging within Loom.

Arguments:
- `level` (keyword): The log severity level (e.g., `:info`, `:debug`).
- `target` (symbol): An explicit target symbol for the message.
- `message` (string): The final, formatted log message content.
- `timestamp` (list): The raw Emacs timestamp (`(high low . usec)`).
- `call-site` (loom-call-site): The captured call site context.
- `extra-data` (plist): Optional, extensible key-value pairs for
  additional context (e.g., `:worker-id`, `:worker-rank`, `:cluster-id`).
- `count` (integer): Number of consecutive identical log entries this
  represents (for deduplication). Defaults to 1.
- `retry-count` (integer): Number of times dispatching this entry has
  been attempted and failed. Defaults to 0.
"
  (level :info :type keyword)
  (target nil :type (or symbol null))
  (message "" :type string)
  (timestamp (current-time) :type list)
  (call-site nil :type (or loom-call-site null))
  (extra-data nil :type (or plist null))
  (count 1 :type integer)
  (retry-count 0 :type integer))

(cl-defstruct (loom-log-appender
               (:constructor loom--make-log-appender))
  "Represents a destination for formatted log output.

Arguments:
- `name` (string): A unique name for the appender.
- `type` (keyword): The type of appender (e.g., `:buffer`, `:file`).
- `config` (plist): Appender-specific configuration (e.g., `:buffer-name`,
  `:file-path`, `:max-size`, `:max-files`).
- `dispatch-fn` (function): A function
  `(appender-instance formatted-log-string)` that writes the
  formatted log string to the appender's destination.
- `state` (plist): Mutable state for the appender (e.g., file handle,
  current file size, rotation counter for file appenders).
- `close-fn` (function): A function `(appender-instance)` for cleanup
  when the appender is shut down.
"
  (name "" :type string)
  (type :buffer :type keyword)
  (config nil :type plist)
  (dispatch-fn nil :type function)
  (state nil :type plist)
  (close-fn nil :type (or function null)))

(cl-defstruct (loom-log-config (:constructor loom--make-log-config))
  "Configuration for a `loom-log-server` instance.

Arguments:
- `level` (keyword): The minimum level a log message must meet to be
  processed and displayed.
- `timestamp-format` (string): A `format-time-string` compliant format
  string for rendering timestamps in log entries.
- `default-formatter` (function): A function `(loom-log-entry)` that
  formats a `loom-log-entry` into a string.
- `appenders` (list): A list of `loom-log-appender` instances.

  Queue Management (inspired by Scribe-queue):
- `queue-size` (integer): Maximum number of log entries retained in
  the priority queue.
- `burst-flush-threshold` (integer): Number of batched entries that,
  when exceeded, triggers an immediate burst flush.
- `idle-timeout` (float): Idle duration in seconds after which an idle
  flush is triggered if no new entries arrive.
- `max-batch-latency` (float): Maximum time in seconds an entry may
  remain in the queue before being flushed.
- `flush-method` (keyword): Strategy for flushing (`:immediate`, `:burst`,
  `:idle`, `:hybrid`).
- `deduplicate-entries` (boolean): If non-nil, collapse consecutive
  identical log entries.
- `use-entry-expiration` (boolean): If non-nil, expired entries are
  periodically purged from the queue.
- `max-entry-age-seconds` (integer): Maximum time (in seconds) to retain
  a log entry in memory before it's considered expired.
- `overflow-strategy` (keyword): Strategy when queue reaches `queue-size`
  (`:drop-oldest`, `:drop-newest`, `:block`).
- `max-dispatch-retries` (integer): Max retries for failed dispatch.
- `min-flush-interval` (float): Minimum interval between burst flushes.
- `expiration-check-interval` (integer): Interval for purging expired entries.
"
  (level :debug :type keyword)
  (timestamp-format "%Y-%m-%d %H:%M:%S.%3N" :type (or null string))
  (default-formatter #'loom--log-default-formatter-impl :type function)
  (appenders nil :type list)
  ;; Queue Management fields
  (queue-size 100 :type integer)
  (burst-flush-threshold 10 :type integer)
  (idle-timeout 2.0 :type float)
  (max-batch-latency 5.0 :type float)
  (flush-method :hybrid :type keyword)
  (deduplicate-entries t :type boolean)
  (use-entry-expiration t :type boolean)
  (max-entry-age-seconds 300 :type integer)
  (overflow-strategy :drop-oldest :type keyword)
  (max-dispatch-retries 3 :type integer)
  (min-flush-interval 0.1 :type float)
  (expiration-check-interval 60 :type integer))

(cl-defstruct (loom-log-server (:constructor loom--make-log-server))
  "Represents an active logging server instance.

Arguments:
- `name` (string): A descriptive name for the server instance.
- `config` (loom-log-config): The configuration object for this server.
- `address` (string): The actual network or IPC address this server
  is listening on.
- `log-queue` (loom-priority-queue): The **thread-safe priority queue**
  where all incoming log entries (local and remote) are enqueued. Items
  are ordered by timestamp (min-heap).
- `lock` (loom-lock): A mutex protecting critical operations, particularly
  during flushing.
- `processing-timer` (timer): An Emacs timer object that periodically
  triggers the draining and flushing of logs from the `log-queue`.
- `idle-flush-timer` (timer): Timer used to trigger idle flushes.
- `expiration-timer` (timer): Timer used to periodically trigger
  expiration checks.
- `last-burst-flush-time` (list): Timestamp of the last time a burst
  flush was actually triggered (raw Emacs timestamp).
- `flushing-in-progress` (boolean): Flag to indicate if a flush
  operation is currently in progress, to prevent re-entrancy.
- `send-raw-fn` (function or nil): An optional function
  `(loom-log-entry)` that, if provided, is called by `loom:log!` to
  dispatch log entries *outbound* (e.g., to a remote log server).
- `start-listener-fn` (function or nil): An optional function `()` that,
  when called, initiates listening for *inbound* raw log entries."
  (name "" :type string)
  (config (loom--make-log-config) :type loom-log-config)
  (address nil :type (or null string))
  (log-queue nil :type (or loom-priority-queue null))
  (lock (loom:lock "loom-log-server") :type loom-lock)
  (processing-timer nil :type (or null timer))
  (idle-flush-timer nil :type (or null timer))
  (expiration-timer nil :type (or null timer))
  (last-burst-flush-time (current-time) :type list)
  (flushing-in-progress nil :type boolean)
  (send-raw-fn nil :type (or null function))
  (start-listener-fn nil :type (or null function)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 4. Internal Helper Functions (Core Logic & Scribe-inspired Queue)

(defconst loom--log-level-values
  '((:trace . 0) (:debug . 1) (:info . 2) (:warn . 3)
    (:error . 4) (:fatal . 5))
  "Internal alist mapping log level keywords to integers for comparison.
Used to determine if a log message's severity meets the configured minimum.")

(defun loom--log-get-level-value (level)
  "Return the integer value for a given log `LEVEL` keyword.

Arguments:
- `LEVEL` (keyword): The log level keyword (e.g., `:info`, `:debug`).

Returns:
- (integer or nil): The corresponding integer value of the level,
  or `nil` if the level keyword is not recognized."
  (cdr (assoc level loom--log-level-values)))

(defun loom--log-default-formatter-impl (log-entry)
  "The default function to format a `loom-log-entry` into a string with color.
This formatter is part of the `loom-log` core. It extracts relevant
information from the `log-entry` including `extra-data` for additional
context. It formats `extra-data` generically as `[KEY:VALUE]` pairs.
It also prepends a `[xN]` prefix if the `count` field is greater than 1.

Arguments:
- `log-entry` (loom-log-entry): The log entry to format.

Returns:
- (string): The fully formatted log line, typically with text properties
  for Emacs faces."
  (let* ((level (loom-log-entry-level log-entry))
         (target (loom-log-entry-target log-entry))
         (message (loom-log-entry-message log-entry))
         (timestamp-raw (loom-log-entry-timestamp log-entry))
         (call-site (loom-log-entry-call-site log-entry))
         (extra-data (loom-log-entry-extra-data log-entry))
         (count (loom-log-entry-count log-entry))
         (level-str (upcase (substring (symbol-name level) 1)))
         (ts-fmt (loom-log-config-timestamp-format
                  (loom-log-server-config loom--log-default-server)))
         (ts-str (if ts-fmt (format-time-string ts-fmt timestamp-raw) ""))
         (fn (and call-site (loom-call-site-fn call-site)))
         (loc (let ((file (and call-site (loom-call-site-file call-site)))
                    (line (and call-site (loom-call-site-line call-site))))
                (if (and file line)
                    (format "(%s:%d)" (file-name-nondirectory file) line)
                  "")))
         (fn-str (if fn (format "[%S] " fn) ""))
         (target-str (if target (format "[%S] " target) ""))
         (extra-parts nil)
         (count-prefix (if (> count 1) (format "[x%d] " count) "")))

    (when extra-data
      (cl-loop for (key val) on extra-data by #'cddr
               do (push (format "[%S:%S]" key val) extra-parts)))

    (let* ((extra-prefix (if (null extra-parts) ""
                           (concat (mapconcat #'identity (nreverse extra-parts) " ")
                                   " "))))
      (concat
       (propertize ts-str 'face 'loom-log-timestamp-face)
       (propertize (format " [%-5s] " level-str)
                   'face (pcase level
                           (:fatal 'loom-log-fatal-face)
                           (:error 'loom-log-error-face)
                           (:warn 'loom-log-warn-face)
                           (:info 'loom-log-info-face)
                           (:debug 'loom-log-debug-face)
                           (:trace 'loom-log-trace-face)))
       (propertize (format "%-25s " loc) 'face 'loom-log-location-face)
       count-prefix extra-prefix fn-str target-str message "\n"))))

(defun loom--log-entry-val-equal-p (entry1 entry2)
  "Compares the core logging values of two `loom-log-entry` objects for
deduplication. This ignores `timestamp`, `call-site`, `count`, and
`retry-count` fields.

Arguments:
- `entry1` (loom-log-entry): The first entry.
- `entry2` (loom-log-entry): The second entry.

Returns: (boolean): `t` if their core values are equal, `nil` otherwise."
  (and (loom-log-entry-p entry1) (loom-log-entry-p entry2)
       (eq (loom-log-entry-level entry1) (loom-log-entry-level entry2))
       (eq (loom-log-entry-target entry1) (loom-log-entry-target entry2))
       (string= (loom-log-entry-message entry1)
                (loom-log-entry-message entry2))
       (equal (loom-log-entry-extra-data entry1)
              (loom-log-entry-extra-data entry2))))

(defun loom--log-init-server-priority-queue (server)
  "Initializes the `loom-priority-queue` for the log server.
This is called when a server is started or re-initialized. The
priority queue is configured as a min-heap based on log entry timestamps
to ensure chronological processing order.

Arguments:
- `server` (loom-log-server): The server instance.

Side Effects:
- Sets `loom-log-server-log-queue`."
  (setf (loom-log-server-log-queue server)
        (loom:pqueue
         :comparator (lambda (entry1 entry2)
                       (time-less-p (loom-log-entry-timestamp entry1)
                                    (loom-log-entry-timestamp entry2)))
         :initial-capacity (loom-log-config-queue-size
                            (loom-log-server-config server)))))

(defun loom--log-deduplicate-batch (server entries)
  "Collapse consecutive `loom-log-entry` objects with the same core values
into a single entry by incrementing its `count` field.
This is used before dispatching a batch to appenders.

Arguments:
- `server` (loom-log-server): The server instance.
- `entries` (list): A list of `loom-log-entry` objects.

Returns: (list): A new list of entries, with duplicates collapsed."
  (let ((config (loom-log-server-config server)))
    (if (loom-log-config-deduplicate-entries config)
        (let ((result nil)
              (last-entry nil))
          (cl-loop for entry in entries do
                   (if (and last-entry
                            (loom--log-entry-val-equal-p entry last-entry))
                       ;; If current entry is a duplicate, merge it.
                       (cl-incf (loom-log-entry-count last-entry))
                     ;; If it's a new unique entry, add it to result.
                     (push entry result)
                     (setq last-entry entry)))
          (nreverse result))
      entries)))

(defun loom--log-dispatch-to-appenders (server log-entry)
  "Dispatches a single `loom-log-entry` to all configured appenders.
This function is responsible for filtering the log entry by level and
then formatting it using the server's `default-formatter`. The formatted
log string is then sent to the `dispatch-fn` of each active appender.

Arguments:
- `SERVER` (loom-log-server): The server instance.
- `log-entry` (loom-log-entry): The log entry to dispatch.

Returns: `nil`.

Side Effects:
- Filters log entry based on server's configured level.
- Calls the server's `default-formatter` to format the entry.
- Calls `dispatch-fn` for each appender, potentially writing to
  Emacs buffers or files."
  (let* ((config (loom-log-server-config server))
         (level-val (loom--log-get-level-value (loom-log-entry-level log-entry)))
         (min-level-val (loom--log-get-level-value
                         (loom-log-config-level config))))
    ;; Only process the log entry if its severity level is high enough.
    (when (and level-val (>= level-val min-level-val))
      (let ((formatted-log (funcall (loom-log-config-default-formatter config)
                                    log-entry)))
        ;; Dispatch to all registered appenders
        (dolist (appender (loom-log-config-appenders config))
          (when (loom-log-appender-p appender)
            (condition-case err
                (funcall (loom-log-appender-dispatch-fn appender)
                         appender formatted-log)
              (error
               ;; Log appender errors using the logging system itself
               ;; to ensure they are captured.
               (loom:log! :error 'loom-log
                          "Appender '%s' failed: %S"
                          (loom-log-appender-name appender) err)))))))))

(defun loom--log-flush-now (server &optional count)
  "Flush accumulated entries from the server's `log-queue` (priority queue).
Pulls `count` items from the priority queue (which are already ordered
by timestamp), deduplicates, formats, and dispatches to all appenders.
Handles re-queuing failed entries. Prevents re-entrant flushes.

Arguments:
- `server` (loom-log-server): The server instance.
- `count` (integer, optional): The maximum number of items to flush.
  If `nil`, flushes all items currently in the queue.

Returns: `nil`.

Side Effects:
- Sets `flushing-in-progress` flag.
- Removes items from `log-queue`.
- Calls `loom--log-dispatch-to-appenders` for each processed item.
- May re-insert failed items back into `log-queue`.
- Updates `last-burst-flush-time`."
  (when (loom-log-server-flushing-in-progress server)
    (cl-return-from loom--log-flush-now nil))

  (unwind-protect
      (progn
        (setf (loom-log-server-flushing-in-progress server) t)
        (let* ((config (loom-log-server-config server))
               (log-queue (loom-log-server-log-queue server))
               (num-to-pull (or count (loom:pqueue-length log-queue)))
               (entries-to-flush (loom:pqueue-pop-n log-queue num-to-pull)))
          (when entries-to-flush
            (let ((deduped (loom--log-deduplicate-batch server entries-to-flush))
                  (failed-entries nil))
              (dolist (entry deduped)
                (condition-case err
                    (loom--log-dispatch-to-appenders server entry)
                  (error
                   (cl-incf (loom-log-entry-retry-count entry))
                   (if (<= (loom-log-entry-retry-count entry)
                           (loom-log-config-max-dispatch-retries config))
                       (push entry failed-entries)))))
              (when failed-entries
                (dolist (entry failed-entries)
                  (loom:pqueue-insert log-queue entry))))
            (setf (loom-log-server-last-burst-flush-time server)
                  (current-time)))))
    (setf (loom-log-server-flushing-in-progress server) nil)))

(defun loom--log-batch-oldest-ts (server)
  "Return the timestamp of the oldest entry (highest priority) in the
server's `log-queue`, or `nil` if queue is empty."
  (when (not (loom:pqueue-empty-p (loom-log-server-log-queue server)))
    (loom-log-entry-timestamp
     (loom:pqueue-peek (loom-log-server-log-queue server)))))

(defun loom--log-flush-if-stale (server)
  "Flush entries if the oldest entry has exceeded max batch latency.
This is primarily for the idle timer in hybrid/idle modes.

Arguments:
- `server` (loom-log-server): The server instance.

Returns: `nil`."
  (let* ((config (loom-log-server-config server))
         (now (current-time))
         (oldest (loom--log-batch-oldest-ts server))
         (diff (if (and oldest (time-less-p oldest now))
                   (time-to-seconds (time-subtract now oldest)) 0)))
    (when (> diff (loom-log-config-max-batch-latency config))
      (loom--log-flush-now server nil))))

(defun loom--log-start-idle-flush-timer (server)
  "Start or restart a persistent timer for flushing entries when idle.
The timer reschedules itself after `idle-timeout`.

Arguments:
- `SERVER` (loom-log-server): The server instance.

Side Effects:
- Creates and stores a new timer in `loom-log-server-idle-flush-timer`."
  (let ((config (loom-log-server-config server)))
    (when (timerp (loom-log-server-idle-flush-timer server))
      (cancel-timer (loom-log-server-idle-flush-timer server)))
    (setf (loom-log-server-idle-flush-timer server)
          (run-with-idle-timer
           (loom-log-config-idle-timeout config) t
           (lambda ()
             (loom:with-mutex (loom-log-server-lock server)
               (loom--log-flush-if-stale server)))))))

(defun loom--log-entry-expired? (server entry)
  "Check if `loom-log-entry` is expired.
An entry is expired if its timestamp is older than
`loom-log-config-max-entry-age-seconds` relative to current time.

Arguments:
- `server` (loom-log-server): The server instance.
- `entry` (loom-log-entry): The log entry to check.

Returns: (boolean): `t` if expired, `nil` otherwise."
  (let ((config (loom-log-server-config server))
        (now (current-time)))
    (and (time-less-p (loom-log-entry-timestamp entry) now)
         (> (time-to-seconds (time-subtract now (loom-log-entry-timestamp entry)))
            (loom-log-config-max-entry-age-seconds config)))))

(defun loom--log-purge-expired (server)
  "Remove expired entries from the server's `log-queue` (priority queue)
and drop them. This function ensures memory is reclaimed for old entries.

Arguments:
- `server` (loom-log-server): The server whose queue to purge.

Side Effects:
- Removes expired entries from `log-queue`."
  (let ((log-queue (loom-log-server-log-queue server))
        (purged-count 0))
    (loom:with-mutex (loom-log-server-lock server)
      (while (and (not (loom:pqueue-empty-p log-queue))
                  (loom--log-entry-expired? server (loom:pqueue-peek log-queue)))
        (loom:pqueue-pop log-queue)
        (cl-incf purged-count)))
    (when (> purged-count 0)
      (loom:log! :debug 'loom-log "Purged %d expired entries." purged-count))))

(defun loom--log-start-expiration-timer (server)
  "Start or restart a persistent timer for periodically purging expired entries."
  (let ((config (loom-log-server-config server)))
    (when (timerp (loom-log-server-expiration-timer server))
      (cancel-timer (loom-log-server-expiration-timer server)))
    (setf (loom-log-server-expiration-timer server)
          (run-with-timer
           (loom-log-config-expiration-check-interval config) t
           (lambda ()
             (loom--log-purge-expired server))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 6. Appender Implementations and Helpers

(defun loom--log-buffer-appender-dispatch (appender formatted-log)
  "Dispatch function for `:buffer` appenders. Writes to an Emacs buffer.

Arguments:
- `appender` (loom-log-appender): The buffer appender instance.
- `formatted-log` (string): The formatted log string to write.

Returns: `nil`.

Side Effects:
- Inserts `formatted-log` into the specified Emacs buffer.
- Optionally scrolls the window to the end if the buffer is currently
  visible in the selected window."
  (let ((buffer-name (plist-get (loom-log-appender-config appender)
                                :buffer-name)))
    (with-current-buffer (get-buffer-create buffer-name)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert formatted-log)
        (when (eq (current-buffer) (window-buffer (selected-window)))
          (set-window-point (selected-window) (point-max)))))))

(cl-defun loom:log-make-buffer-appender (&key name buffer-name (level :debug))
  "Creates a new `:buffer` appender. This appender writes log messages
to a specified Emacs buffer, creating it if it doesn't exist.

Arguments:
- `:name` (string): A unique name for the appender. If `nil`, a name
  is generated from the buffer name.
- `:buffer-name` (string): The name of the Emacs buffer to write to.
  Defaults to `*loom-log*`.
- `:level` (keyword): The minimum log level for messages to be processed
  by this specific appender. Defaults to `:debug`.

Returns:
- (loom-log-appender): A new buffer appender instance."
  (loom--make-log-appender
   :name (or name (format "buffer-%s"
                           (if (string-prefix-p "*" buffer-name)
                               (substring buffer-name 1)
                             buffer-name)))
   :type :buffer
   :config (list :buffer-name (or buffer-name "*loom-log*")
                 :level level)
   :dispatch-fn #'loom--log-buffer-appender-dispatch
   :close-fn nil)) ; Buffer appenders don't need explicit close

(defun loom--log-file-appender-rotate (appender)
  "Performs log file rotation for a `:file` appender.
This function renames the current log file by appending a timestamp,
then creates a new empty one to continue logging. It also purges
older rotated files based on the `max-files` configuration.

Arguments:
- `appender` (loom-log-appender): The file appender instance.

Returns: `nil`.

Side Effects:
- Renames the current log file.
- Deletes old rotated log files.
- Resets internal state (`current-size`, `channel`) to prepare for new file."
  (let* ((config (loom-log-appender-config appender))
         (file-path (plist-get config :file-path))
         (max-files (plist-get config :max-files 5))
         (timestamp (format-time-string "%Y%m%d%H%M%S" (current-time))))
    (when (file-exists-p file-path)
      (let ((rotated-path (format "%s.%s" file-path timestamp)))
        (rename-file file-path rotated-path t))

      (let* ((dir (file-name-directory file-path))
             (base (file-name-nondirectory file-path))
             (rotated-files
              (seq-filter
               (lambda (f)
                 (string-match-p (format "^%s\\.\\([0-9]+\\)" (regexp-quote base))
                                 (file-name-nondirectory f)))
               (directory-files dir t)))
             (sorted (seq-sort #'string< rotated-files)))
        (when (> (length sorted) max-files)
          (dolist (f (seq-take sorted (- (length sorted) max-files)))
            (delete-file f)))))))

(defun loom--log-file-appender-dispatch (appender formatted-log)
  "Dispatch function for `:file` appenders. Writes to a log file
and handles size/daily-based rotation.

Arguments:
- `appender` (loom-log-appender): The file appender instance.
- `formatted-log` (string): The formatted log string to write.

Returns: `nil`.

Side Effects:
- Writes `formatted-log` to the specified file.
- May trigger file rotation and associated file operations (rename/delete)."
  (let* ((config (loom-log-appender-config appender))
         (state (loom-log-appender-state appender))
         (file-path (plist-get config :file-path))
         (max-size (plist-get config :max-size 1048576)) ; 1MB
         (current-size (plist-get state :current-size 0))
         (channel (plist-get state :channel))
         (last-day (plist-get state :last-rotation-day 0))
         (rotation (plist-get config :rotation-strategy :size)))

    (when (and file-path (file-exists-p file-path))
      (pcase rotation
        (:size
         (when (> (+ current-size (length formatted-log)) max-size)
           (loom--log-file-appender-rotate appender)
           (setf (plist-get (loom-log-appender-state appender) :current-size) 0)
           (setq channel nil)))
        (:daily
         (let ((today (nth 6 (decode-time (current-time)))))
           (unless (eq today last-day)
             (loom--log-file-appender-rotate appender)
             (setf (plist-get (loom-log-appender-state appender)
                              :current-size) 0)
             (setf (plist-get (loom-log-appender-state appender)
                              :last-rotation-day) today)
             (setq channel nil))))))

    (unless channel
      (make-directory (file-name-directory file-path) t)
      (setq channel (open-channel file-path "a"))
      (setf (plist-get (loom-log-appender-state appender) :channel) channel)
      (when (file-exists-p file-path)
        (setf (plist-get (loom-log-appender-state appender) :current-size)
              (with-temp-buffer
                (insert-file-contents-literally file-path)
                (point-max)))))

    (channel-insert-string channel formatted-log)
    (setf (plist-get (loom-log-appender-state appender) :current-size)
          (+ current-size (length formatted-log)))
    nil))

(defun loom--log-file-appender-close (appender)
  "Close function for `:file` appenders. Closes the underlying file channel.

Arguments:
- `appender` (loom-log-appender): The file appender instance.

Returns: `nil`.

Side Effects:
- Closes the file channel associated with the appender state."
  (when-let (channel (plist-get (loom-log-appender-state appender) :channel))
    (when (channel-live-p channel)
      (close-channel channel)
      (setf (plist-get (loom-log-appender-state appender) :channel) nil))))

(cl-defun loom:log-make-file-appender (&key name file-path (level :debug)
                                            (max-size 1048576) (max-files 5)
                                            (rotation-strategy :size))
  "Creates a new `:file` appender with configurable log rotation.
This appender writes log messages to a specified file. When the file
reaches `max-size` (or daily rotation if `rotation-strategy` is `:daily`),
it's rotated, and older rotated files are purged to `max-files`.

Arguments:
- `:name` (string): A unique name for the appender. If `nil`, a name
  is generated from the file path.
- `:file-path` (string): The full path to the log file.
- `:level` (keyword): The minimum log level for messages to be processed
  by this specific appender. Defaults to `:debug`.
- `:max-size` (integer): Maximum size in bytes a log file can reach
  before it is rotated. Defaults to 1MB.
- `:max-files` (integer): Maximum number of rotated log files to keep
  in the directory. Older files beyond this limit are purged. Defaults to 5.
- `:rotation-strategy` (keyword): The strategy for log file rotation.
  `:size` rotates when `max-size` is reached. `:daily` rotates once per day.
  Defaults to `:size`.

Returns:
- (loom-log-appender): A new file appender instance."
  (loom--make-log-appender
   :name (or name (format "file-%s" (file-name-nondirectory file-path)))
   :type :file
   :config (list :file-path file-path
                 :max-size max-size
                 :max-files max-files
                 :rotation-strategy rotation-strategy
                 :level level)
   :dispatch-fn #'loom--log-file-appender-dispatch
   :state (list :current-size 0 :channel nil
                :last-rotation-day (nth 6 (decode-time (current-time))))
   :close-fn #'loom--log-file-appender-close))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 7. Public API

;;;###autoload
(cl-defun loom:log-server-process-incoming-message (server raw-payload)
  "Public API for external transport layers to push deserialized log data
to a `loom-log-server`.

This function is intended to be called by a separate module (e.g.,
`warp-log`) that handles the actual network or IPC reception of log
messages. It takes a raw payload (a plist containing log details,
typically representing the fields of a `loom-log-entry`) and constructs
a `loom-log-entry` object before enqueuing it into the given log server
for processing.

Arguments:
- `SERVER` (loom-log-server): The server instance to which to submit the log.
- `RAW-PAYLOAD` (plist): A property list containing log message details.
  It is expected to contain keys matching `loom-log-entry` slots, plus
  any `:extra-data` for additional context.

Returns: `nil`.

Side Effects:
- Creates a `loom-log-entry` from `RAW-PAYLOAD`.
- Inserts the `loom-log-entry` into the server's `log-queue` (priority queue)
  for thread-safe asynchronous processing.
- This operation is thread-safe due to `loom-priority-queue`'s internal lock."
  (let* ((level (plist-get raw-payload :level))
         (target (plist-get raw-payload :target))
         (message (plist-get raw-payload :message))
         (timestamp (or (plist-get raw-payload :timestamp) (current-time)))
         (call-site-plist (plist-get raw-payload :call-site))
         (extra-data (plist-get raw-payload :extra-data))
         (call-site (when call-site-plist
                      (apply #'make-loom-call-site call-site-plist)))
         (log-entry (loom--make-log-entry
                     :level level :target target :message message
                     :timestamp timestamp :call-site call-site
                     :extra-data extra-data)))
    ;; Insert directly into the thread-safe priority queue.
    (loom:pqueue-insert (loom-log-server-log-queue server) log-entry)))

;;;###autoload
(cl-defun loom:log-start-server (&key name (processing-interval 0.2)
                                     (send-raw-fn nil) (start-listener-fn nil)
                                     (address nil)
                                     (level :debug)
                                     (timestamp-format "%Y-%m-%d %H:%M:%S.%3N")
                                     (default-formatter #'loom--log-default-formatter-impl)
                                     (appenders nil)
                                     ;; Queue Management Config
                                     (queue-size 100)
                                     (burst-flush-threshold 10)
                                     (idle-timeout 2.0)
                                     (max-batch-latency 5.0)
                                     (flush-method :hybrid)
                                     (deduplicate-entries t)
                                     (use-entry-expiration t)
                                     (max-entry-age-seconds 300)
                                     (overflow-strategy :drop-oldest)
                                     (max-dispatch-retries 3)
                                     (min-flush-interval 0.1)
                                     (expiration-check-interval 60))
  "Starts a new `loom-log-server` instance.

Arguments:
- `:NAME` (string, optional): A descriptive name for this server instance.
- `:PROCESSING-INTERVAL` (float): Interval to process the log queue.
- `:SEND-RAW-FN` (function or nil, optional): Function to send logs remotely.
- `:START-LISTENER-FN` (function or nil, optional): Function to start
  listening for remote logs.
- `:ADDRESS` (string, optional): The address this server listens on.
- `:LEVEL` (keyword, optional): The minimum log level for this server.
- `:TIMESTAMP-FORMAT` (string, optional): Format string for timestamps.
- `:DEFAULT-FORMATTER` (function, optional): The primary formatter function.
- `:APPENDERS` (list, optional): List of `loom-log-appender` instances.

  Queue Management Configuration (inspired by Scribe):
- `:QUEUE-SIZE` (integer): Maximum number of entries in the priority queue.
- `:BURST-FLUSH-THRESHOLD` (integer): Batch size to trigger immediate flush.
- `:IDLE-TIMEOUT` (float): Seconds of inactivity to trigger flush.
- `:MAX-BATCH-LATENCY` (float): Max seconds an entry can stay in queue.
- `:FLUSH-METHOD` (keyword): `:immediate`, `:burst`, `:idle`, `:hybrid`.
- `:DEDUPLICATE-ENTRIES` (boolean): If `t`, collapse identical consecutive logs.
- `:USE-ENTRY-EXPIRATION` (boolean): If `t`, periodically purge old entries.
- `:MAX-ENTRY-AGE-SECONDS` (integer): Max age for entries before expiration.
- `:OVERFLOW-STRATEGY` (keyword): `:drop-oldest`, `:drop-newest`, `:block`.
- `:MAX-DISPATCH-RETRIES` (integer): Max re-attempts for failed dispatches.
- `:MIN-FLUSH-INTERVAL` (float): Minimum seconds between burst flushes.
- `:EXPIRATION-CHECK-INTERVAL` (integer): Seconds between expiration checks.

Returns:
- (loom-log-server): The newly created and initialized log server object.

Side Effects:
- Creates a new `loom-log-server` instance and starts its processing timers.
- If `START-LISTENER-FN` is provided, it is called to activate the listener."
  (let* ((server-name (or name (format "log-server-%s"
                                       (format-time-string "%Y%m%d%H%M%S"))))
         (final-appenders (or appenders
                              (unless (fboundp 'warp:worker-p)
                                (list (loom:log-make-buffer-appender)))))
         (config (loom--make-log-config
                  :level level :timestamp-format timestamp-format
                  :default-formatter default-formatter
                  :appenders final-appenders :queue-size queue-size
                  :burst-flush-threshold burst-flush-threshold
                  :idle-timeout idle-timeout :max-batch-latency max-batch-latency
                  :flush-method flush-method
                  :deduplicate-entries deduplicate-entries
                  :use-entry-expiration use-entry-expiration
                  :max-entry-age-seconds max-entry-age-seconds
                  :overflow-strategy overflow-strategy
                  :max-dispatch-retries max-dispatch-retries
                  :min-flush-interval min-flush-interval
                  :expiration-check-interval expiration-check-interval))
         (server (loom--make-log-server
                  :name server-name :config config :address address
                  :send-raw-fn send-raw-fn :start-listener-fn start-listener-fn)))

    (loom--log-init-server-priority-queue server)

    (setf (loom-log-server-processing-timer server)
          (run-with-timer 0 processing-interval #'loom--log-flush-now server))

    (when (memq (loom-log-config-flush-method config) '(:idle :hybrid))
      (loom--log-start-idle-flush-timer server))

    (when (loom-log-config-use-entry-expiration config)
      (loom--log-start-expiration-timer server))

    (when start-listener-fn
      (funcall start-listener-fn))
    server))

;;;###autoload
(defun loom:log-shutdown-server (server)
  "Shuts down a `loom-log-server` instance and cleans up its resources.
This function is idempotent. It stops all internal processing timers, performs
a final flush of the queue, and calls the `close-fn` of all appenders.

Arguments:
- `SERVER` (loom-log-server): The server instance to shut down.

Returns: `nil`.

Side Effects:
- Cancels all timers associated with the log server.
- Performs a final, synchronous flush of any remaining log entries.
- Calls the `close-fn` for all registered appenders.
- If `SERVER` is the `loom--log-default-server`, that global is reset."
  (when (and server (loom-log-server-p server)
             (loom-log-server-processing-timer server))
    (loom:log! :info 'loom-log "Shutting down log server '%s'."
               (loom-log-server-name server))
    ;; Cancel all timers
    (cancel-timer (loom-log-server-processing-timer server))
    (setf (loom-log-server-processing-timer server) nil)
    (when-let (timer (loom-log-server-idle-flush-timer server))
      (cancel-timer timer))
    (when-let (timer (loom-log-server-expiration-timer server))
      (cancel-timer timer))

    ;; Perform a final, synchronous flush to clear the queue
    (loom--log-flush-now server nil)

    ;; Call close-fn for all appenders
    (dolist (appender (loom-log-config-appenders (loom-log-server-config server)))
      (when-let (close-fn (loom-log-appender-close-fn appender))
        (ignore-errors (funcall close-fn appender))))

    (when (eq server loom--log-default-server)
      (setq loom--log-default-server nil))))

;;;###autoload
(defmacro loom:log! (level target-symbol fmt &rest args)
  "Logs a message, dispatching via the server's `send-raw-fn` if available,
otherwise queuing locally.

This is the core logging macro. It captures the call site context
(file, line, function) automatically and packages all log data into a
`loom-log-entry` struct.

It supports two special keyword arguments at the end of `ARGS`:
- `:once ID`: Logs this message only the first time for a given `ID`.
- `:throttle SECONDS`: Logs this message at most once every `SECONDS`.

Arguments:
- `level` (keyword): The log severity level (e.g., `:debug`, `:info`).
- `target-symbol` (symbol): An explicit symbol identifying the log's source.
- `fmt` (string): The `format`-control string for the message content.
- `args` (list): Arguments for the format string, optionally ending with
  `:once ID` or `:throttle SECONDS`.

Returns: `nil`.

Side Effects:
- Creates a `loom-log-entry` and dispatches it.
- Captures Emacs Lisp call stack information for context."
  (declare (indent 2) (debug t))
  (let* ((throttle-p (eq (car (last args 2)) :throttle))
         (once-p (eq (car (last args 2)) :once))
         (rate-limit-p (or throttle-p once-p))
         (rate-limit-key (when rate-limit-p (car (last args 1))))
         (main-args (if rate-limit-p (butlast args 2) args)))
    `(let ((server (loom:log-default-server)))
       (when server
         (let* ((call-site (loom-context-capture-call-site))
                ;; Create a stable key for rate-limiting even if target is nil
                (rate-limit-id (or ,rate-limit-key
                                   (cons (or ,target-symbol
                                             (loom-call-site-file call-site))
                                         ,fmt)))
                (should-log t))
           ;; Check rate-limiting conditions
           (cond
            (,once-p
             (unless (gethash rate-limit-id loom--log-once-tracker)
               (puthash rate-limit-id t loom--log-once-tracker))
             (setq should-log (not (gethash rate-limit-id
                                            loom--log-once-tracker))))
            (,throttle-p
             (let ((now (float-time))
                   (last-log (gethash rate-limit-id loom--log-throttle-tracker 0.0)))
               (when (> (- now last-log) ,(car (last args 1)))
                 (puthash rate-limit-id now loom--log-throttle-tracker))
               (setq should-log (> (- now last-log) ,(car (last args 1)))))))

           (when should-log
             (let* ((message-content (format ,fmt ,@main-args))
                    (log-entry
                     (loom--make-log-entry
                      :level ,level
                      :target ,target-symbol
                      :message message-content
                      :timestamp (current-time)
                      :call-site call-site
                      :extra-data nil)))
               (if-let (send-fn (loom-log-server-send-raw-fn server))
                   (funcall send-fn log-entry)
                 (loom:pqueue-insert (loom-log-server-log-queue server)
                                     log-entry)))))))))

;;;###autoload
(defun loom:log-default-server ()
  "Returns the default global `loom-log-server` instance, creating it if needed.

This function ensures that a default log server instance is always available
for `loom:log!` calls. On its first invocation, if no default server
exists, it creates a new one using `loom:log-start-server`.

Arguments: None.

Returns:
- (loom-log-server): The default global log server instance.

Side Effects:
- May create the default log server instance on first call."
  (unless (and loom--log-default-server
               (loom-log-server-p loom--log-default-server)
               (timerp (loom-log-server-processing-timer loom--log-default-server)))
    (setq loom--log-default-server (loom:log-start-server)))
  loom--log-default-server)

;;;###autoload
(defun loom:log-get-server-address ()
  "Retrieves the address of the default global log server.
This function first ensures the default log server is initialized.
It then returns the actual address that the server is listening on.

Arguments: None.

Returns:
- (string or nil): The address of the default log server, or `nil`."
  (let ((server (loom:log-default-server)))
    (loom-log-server-address server)))

;;;###autoload
(defun loom:log-set-level (level &optional server)
  "Set the minimum logging LEVEL for a SERVER at runtime.

Arguments:
- `LEVEL` (keyword): The new minimum log level (e.g., `:info`, `:error`).
- `SERVER` (loom-log-server, optional): The server to configure. Defaults to
  the global default log server.

Returns: `nil`.

Side Effects:
- Modifies the log level configuration of the specified server."
  (let ((server (or server (loom:log-default-server))))
    (when (loom-log-server-p server)
      (loom:with-mutex (loom-log-server-lock server)
        (setf (loom-log-config-level (loom-log-server-config server)) level)
        (loom:log! :info 'loom-log "Log level for server '%s' set to %S."
                   (loom-log-server-name server) level)))))

;;;###autoload
(defun loom:log-flush (&optional server)
  "Manually trigger a synchronous flush of a log server's queue.

Arguments:
- `SERVER` (loom-log-server, optional): The server to flush. Defaults to
  the global default log server.

Returns: `nil`.

Side Effects:
- Drains and processes all currently pending log entries in the queue."
  (let ((server (or server (loom:log-default-server))))
    (when (loom-log-server-p server)
      (loom:with-mutex (loom-log-server-lock server)
        (loom--log-flush-now server nil)))))

(provide 'loom-log)
;;; loom-log.el ends here