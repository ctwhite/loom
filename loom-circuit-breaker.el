;;; loom-circuit-breaker.el --- Circuit Breaker Pattern Implementation -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides a robust, thread-safe implementation of the Circuit
;; Breaker pattern, a fundamental resilience mechanism in distributed systems.
;; It is designed to prevent cascading failures by monitoring the health
;; of a service and temporarily "tripping" (opening the circuit) when
;; failures exceed a predefined threshold.
;;
;; ## Core Concepts:
;;
;; - **States:** A circuit breaker operates in three distinct states:
;;   - **:closed:** This is the normal operating state. Requests are allowed
;;     to pass through to the protected service. If failures occur, they
;;     are counted. If the consecutive failure count exceeds the
;;     `failure-threshold`, the circuit transitions to `:open`. Any success
;;     resets the consecutive failure count.
;;   - **:open:** In this state, requests are immediately rejected without
;;     calling the service, preventing further load on a potentially
;;     failing system. After a `timeout` period, the circuit transitions
;;     to `:half-open` to probe the service's health.
;;   - **:half-open:** A limited number of test requests (determined by
;;     `success-threshold`) are allowed to pass through. If they succeed,
;;     the circuit transitions back to `:closed`. If any test request fails,
;;     the circuit immediately re-opens, restarting the timeout period.
;;
;; - **Global Registry:** A central, thread-safe registry maintains all active
;;   circuit breaker instances, identified by a unique service ID. This
;;   ensures that all parts of an application share the same state for a
;;   given protected service.
;;
;; ## Key Features:
;;
;; - **Granular Locking:** Each circuit breaker has its own mutex, allowing
;;   for high-concurrency operations without contention between different
;;   breakers. A separate global lock protects only the registry itself.
;; - **Configurable Thresholds:** Easily configure failure and success
;;   thresholds, as well as the open-state timeout, on a per-breaker basis.
;; - **Full API:** Provides functions to get, check, and update breaker
;;   states, as well as to reset them manually for administrative purposes.
;;
;; This module is intended to be used by higher-level communication
;; components (like `loom-distributed`) to add resilience to their
;; interactions with external or internal services.

;;; Code:

(require 'cl-lib)
(require 'loom-errors)
(require 'loom-log)
(require 'loom-lock)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Constants and Customization

(defcustom loom-circuit-breaker-default-threshold 5
  "Default number of consecutive failures before opening a circuit breaker."
  :type 'integer
  :group 'loom)

(defcustom loom-circuit-breaker-default-timeout 60.0
  "Default timeout in seconds before an open circuit transitions to half-open."
  :type 'number
  :group 'loom)

(defcustom loom-circuit-breaker-default-success-threshold 1
  "Default number of successes in half-open state to close the circuit."
  :type 'integer
  :group 'loom)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom-circuit-breaker--registry (make-hash-table :test 'equal)
  "Global registry mapping service-id to `loom-circuit-breaker` instances.")

(defvar loom-circuit-breaker--registry-lock (loom:make-lock)
  "Mutex protecting only the `loom-circuit-breaker--registry` hash table.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definition

(cl-defstruct (loom-circuit-breaker
               (:constructor %%make-circuit-breaker))
  "Represents a single circuit breaker instance for fault tolerance.
Each instance is self-contained and manages its own state and lock,
allowing for high concurrency across different protected services.

Fields:
- `service-id` (string): Unique identifier of the protected service.
- `lock` (loom-lock): A dedicated mutex for this specific breaker instance.
- `state` (symbol): Current state (`:closed`, `:open`, `:half-open`).
- `failure-count` (integer): Number of consecutive failures.
- `failure-threshold` (integer): Failures required to open the circuit.
- `last-failure-time` (float): Timestamp of the most recent failure.
- `timeout` (float): Seconds to wait in the `:open` state.
- `success-count` (integer): Consecutive successes in `:half-open` state.
- `success-threshold` (integer): Successes needed to close the circuit.
- `total-requests` (integer): Lifetime count of total requests processed.
- `total-failures` (integer): Lifetime count of total failures recorded."
  (service-id (cl-assert nil) :type string)
  (lock (loom:make-lock) :type loom-lock)
  (state :closed :type symbol)
  (failure-count 0 :type integer)
  (failure-threshold loom-circuit-breaker-default-threshold :type integer)
  (last-failure-time 0.0 :type float)
  (timeout loom-circuit-breaker-default-timeout :type float)
  (success-count 0 :type integer)
  (success-threshold loom-circuit-breaker-default-success-threshold :type integer)
  (total-requests 0 :type integer)
  (total-failures 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun loom-circuit-breaker--current-time ()
  "Get the current time as a float for consistent timestamping.

Returns:
- (float): Current time in seconds since the epoch."
  (float-time))

(defun loom-circuit-breaker--log-target (service-id)
  "Generate a standardized logging target string for a circuit breaker.

Arguments:
- `SERVICE-ID` (string): The unique identifier of the service.

Returns:
- (string): A string suitable for use as a logging category."
  (format "circuit-breaker-%s" service-id))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun loom:circuit-breaker-get
    (service-id &key (threshold loom-circuit-breaker-default-threshold)
                (timeout loom-circuit-breaker-default-timeout)
                (success-threshold
                 loom-circuit-breaker-default-success-threshold))
  "Retrieve or create a circuit breaker for the specified `SERVICE-ID`.
This function acts as a factory and registry. If a circuit breaker for
`SERVICE-ID` already exists, it is returned. Otherwise, a new one is
created, initialized, and registered for future calls. This operation
is thread-safe.

Arguments:
- `SERVICE-ID` (string): A unique identifier for the service being protected.
- `:threshold` (integer): Number of consecutive failures to open the circuit.
- `:timeout` (float): Time in seconds to stay in the `:open` state.
- `:success-threshold` (integer): Consecutive successes in the `:half-open`
  state required to fully close the circuit.

Returns:
- (loom-circuit-breaker): The circuit breaker instance for the service.

Side Effects:
- May create and register a new `loom-circuit-breaker` instance if one
  does not already exist for the given `SERVICE-ID`."
  (loom:with-mutex! loom-circuit-breaker--registry-lock
    (or (gethash service-id loom-circuit-breaker--registry)
        (let ((breaker (%%make-circuit-breaker
                        :service-id service-id
                        :failure-threshold threshold
                        :timeout timeout
                        :success-threshold success-threshold)))
          (puthash service-id breaker loom-circuit-breaker--registry)
          (loom:log! :info (loom-circuit-breaker--log-target service-id)
                     "New circuit breaker created for '%s'." service-id)
          breaker))))

;;;###autoload
(defun loom:circuit-breaker-can-execute-p (breaker)
  "Check if the circuit breaker allows a request to be executed.
This is the primary gatekeeper function. It returns `t` if the circuit is
`:closed` or `:half-open`. If the circuit is `:open`, it checks if the
timeout has expired. If it has, this function transitions the state to
`:half-open` to permit a single test request and returns `t`.

Arguments:
- `BREAKER` (loom-circuit-breaker): The circuit breaker instance.

Returns:
- (boolean): Non-nil if the request should be allowed, `nil` otherwise.

Side Effects:
- May transition the circuit breaker state from `:open` to `:half-open`
  if the timeout period has elapsed."
  (loom:with-mutex! (loom-circuit-breaker-lock breaker)
    (pcase (loom-circuit-breaker-state breaker)
      ;; State: CLOSED. Always allow requests.
      (:closed t)
      ;; State: OPEN. Reject requests unless the timeout has expired.
      (:open
       (let ((time-since-failure
              (- (loom-circuit-breaker--current-time)
                 (loom-circuit-breaker-last-failure-time breaker))))
         ;; Check if enough time has passed to try again.
         (when (>= time-since-failure (loom-circuit-breaker-timeout breaker))
           ;; Timeout has passed. Transition to HALF-OPEN to allow one
           ;; test request through.
           (setf (loom-circuit-breaker-state breaker) :half-open)
           (setf (loom-circuit-breaker-success-count breaker) 0)
           (loom:log! :info
                      (loom-circuit-breaker--log-target
                       (loom-circuit-breaker-service-id breaker))
                      "Transitioning to :half-open.")
           t))) ; Allow this single test request.
      ;; State: HALF-OPEN. The check has already allowed one request.
      ;; Subsequent checks will also pass until a success/failure is
      ;; recorded, which will then change the state.
      (:half-open t))))

;;;###autoload
(defun loom:circuit-breaker-record-success (breaker)
  "Record a successful operation for the circuit breaker.
This function should be called after a protected operation completes
successfully. It updates the breaker's state accordingly.

Arguments:
- `BREAKER` (loom-circuit-breaker): The circuit breaker instance.

Returns:
- `nil`.

Side Effects:
- In the `:closed` state, it resets the consecutive failure count.
- In the `:half-open` state, it increments the success count. If the
  `success-threshold` is met, it transitions the state to `:closed`."
  (loom:with-mutex! (loom-circuit-breaker-lock breaker)
    (cl-incf (loom-circuit-breaker-total-requests breaker))
    (pcase (loom-circuit-breaker-state breaker)
      (:closed
       ;; A success in the closed state resets any previous failures.
       (setf (loom-circuit-breaker-failure-count breaker) 0))
      (:half-open
       ;; A success in the half-open state contributes to recovery.
       (cl-incf (loom-circuit-breaker-success-count breaker))
       (when (>= (loom-circuit-breaker-success-count breaker)
                 (loom-circuit-breaker-success-threshold breaker))
         ;; Success threshold met. The service is healthy again. Close the circuit.
         (setf (loom-circuit-breaker-state breaker) :closed)
         (setf (loom-circuit-breaker-failure-count breaker) 0)
         (loom:log! :info
                    (loom-circuit-breaker--log-target
                     (loom-circuit-breaker-service-id breaker))
                    "Closed after successful recovery."))))))

;;;###autoload
(defun loom:circuit-breaker-record-failure (breaker)
  "Record a failed operation for the circuit breaker.
This function should be called when a protected operation fails. It
updates the failure counters and may trip the circuit to the `:open` state.

Arguments:
- `BREAKER` (loom-circuit-breaker): The circuit breaker instance.

Returns:
- `nil`.

Side Effects:
- Increments failure counters.
- Sets the `last-failure-time`.
- In the `:half-open` state, a single failure immediately re-opens the circuit.
- In the `:closed` state, if the `failure-threshold` is met, it opens the
  circuit."
  (loom:with-mutex! (loom-circuit-breaker-lock breaker)
    (cl-incf (loom-circuit-breaker-total-requests breaker))
    (cl-incf (loom-circuit-breaker-total-failures breaker))
    (let ((service-id (loom-circuit-breaker-service-id breaker)))
      (pcase (loom-circuit-breaker-state breaker)
        (:half-open
         ;; Any failure in the half-open state immediately re-opens the circuit.
         (setf (loom-circuit-breaker-state breaker) :open)
         (setf (loom-circuit-breaker-last-failure-time breaker)
               (loom-circuit-breaker--current-time))
         (loom:log! :warn (loom-circuit-breaker--log-target service-id)
                    "Re-opened from :half-open due to test failure."))
        (:closed
         (cl-incf (loom-circuit-breaker-failure-count breaker))
         (setf (loom-circuit-breaker-last-failure-time breaker)
               (loom-circuit-breaker--current-time))
         ;; Check if the failure threshold has been reached.
         (when (>= (loom-circuit-breaker-failure-count breaker)
                   (loom-circuit-breaker-failure-threshold breaker))
           ;; Trip the circuit.
           (setf (loom-circuit-breaker-state breaker) :open)
           (loom:log! :warn (loom-circuit-breaker--log-target service-id)
                      "Opened due to repeated failures.")))))))

;;;###autoload
(defun loom:circuit-breaker-status (service-id)
  "Retrieve the current status of a specific circuit breaker for monitoring.

Arguments:
- `SERVICE-ID` (string): The unique identifier of the service.

Returns:
- (plist or nil): A property list containing a snapshot of the circuit
  breaker's state, counts, and thresholds, or `nil` if not found."
  (loom:with-mutex! loom-circuit-breaker--registry-lock
    (when-let ((breaker (gethash service-id loom-circuit-breaker--registry)))
      (loom:with-mutex! (loom-circuit-breaker-lock breaker)
        `(:service-id ,(loom-circuit-breaker-service-id breaker)
          :state ,(loom-circuit-breaker-state breaker)
          :failure-count ,(loom-circuit-breaker-failure-count breaker)
          :failure-threshold ,(loom-circuit-breaker-failure-threshold breaker)
          :last-failure-time ,(loom-circuit-breaker-last-failure-time breaker)
          :timeout ,(loom-circuit-breaker-timeout breaker)
          :success-count ,(loom-circuit-breaker-success-count breaker)
          :success-threshold ,(loom-circuit-breaker-success-threshold breaker)
          :total-requests ,(loom-circuit-breaker-total-requests breaker)
          :total-failures ,(loom-circuit-breaker-total-failures breaker))))))

;;;###autoload
(defun loom:circuit-breaker-reset (service-id)
  "Forcefully reset a circuit breaker to the `:closed` state.
This function provides a mechanism for manual administrative intervention,
allowing an operator or a management system to force a circuit closed
even if it was open, bypassing the normal timeout and recovery logic.

Arguments:
- `SERVICE-ID` (string): The unique identifier of the service.

Returns:
- (boolean): `t` if the breaker was found and reset, `nil` otherwise.

Side Effects:
- If found, the circuit breaker's state is set to `:closed`.
- The `failure-count` and `success-count` are reset to 0."
  (loom:with-mutex! loom-circuit-breaker--registry-lock
    (when-let ((breaker (gethash service-id loom-circuit-breaker--registry)))
      (loom:with-mutex! (loom-circuit-breaker-lock breaker)
        (setf (loom-circuit-breaker-state breaker) :closed)
        (setf (loom-circuit-breaker-failure-count breaker) 0)
        (setf (loom-circuit-breaker-success-count breaker) 0)
        (loom:log! :info (loom-circuit-breaker--log-target service-id)
                   "Forcefully reset to :closed.")
        t))))

;;;###autoload
(defun loom:circuit-breaker-cleanup ()
  "Performs global cleanup for all circuit breaker instances.
This function is intended for use in a shutdown hook (`kill-emacs-hook`)
to ensure that the global registry of circuit breakers is cleared,
releasing memory and ensuring a clean state for the next session.

Returns:
- `nil`.

Side Effects:
- Clears the global `loom-circuit-breaker--registry` hash table."
  (loom:with-mutex! loom-circuit-breaker--registry-lock
    (loom:log! :info "loom-circuit-breaker" "Cleaning up all circuit breakers.")
    (clrhash loom-circuit-breaker--registry))
  nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Module Finalization

;; Register the cleanup function to be called when Emacs is exiting.
(add-hook 'kill-emacs-hook #'loom:circuit-breaker-cleanup)

(provide 'loom-circuit-breaker)
;;; loom-circuit-breaker.el ends here