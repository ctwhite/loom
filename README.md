# Loom.el: Asynchronous Programming for Emacs Lisp

Loom.el is an Emacs Lisp library providing a framework for asynchronous and concurrent programming. It implements promise-based patterns, cooperative multitasking, and thread-safe operations, enabling developers to manage complex, long-running tasks efficiently within Emacs.

## Features

* **Promises/A+ Compliant**: At its core, Loom provides `loom-promise` objects that adhere to the Promises/A+ specification. These promises transition through `pending`, `resolved`, and `rejected` states, supporting robust chaining with `loom:then`, `loom:catch`, and `loom:finally`.

* **Intelligent Task Scheduling**:

  * **Macrotasks**: These are standard background operations, scheduled to run when Emacs is idle. This ensures that long-running computations do not block the Emacs UI, keeping your editor responsive.

  * **Microtasks**: Designed for high-priority, immediate execution, microtasks run as soon as the current Emacs Lisp call stack is clear. They are ideal for quick follow-ups and efficient promise chaining.

* **Robust Thread Safety**:

  * **Native Locks**: For multi-threaded scenarios, Loom utilizes Emacs's native mutexes, providing preemptive thread-safety for shared resources.

  * **Main Thread Dispatching**: A clever Inter-Process Communication (IPC) mechanism, leveraging a `cat` process and filters, allows background threads to safely and efficiently dispatch updates to the main Emacs thread. This is crucial for UI interactions and state synchronization.

* **`await` Macro**: The powerful `loom:await` macro enables you to write asynchronous code that reads like synchronous code. It cooperatively pauses execution until a promise settles, simplifying complex asynchronous flows.

* **Cooperative Cancellation**: With `loom-cancel-token`, you can signal cancellation to long-running asynchronous operations. This allows for graceful termination and proper resource cleanup.

* **Futures (Lazy Computations)**: `loom-future` allows you to define computations that are evaluated lazily – only when their result is explicitly requested via `loom:force`. Once evaluated, the result is cached for subsequent access, making it ideal for expensive operations.

* **Promise Combinators**: Loom offers a comprehensive set of tools for managing and coordinating groups of promises:

  * `loom:all`, `loom:race`, `loom:any`, `loom:all-settled` for various strategies of waiting on multiple promises.

  * `loom:map`, `loom:reduce`, `loom:map-series` for asynchronous processing of collections.

* **Semaphores for Concurrency Control**: The `loom-semaphore` primitive acts as a counting semaphore, allowing you to limit the number of concurrent operations. This is highly useful for rate-limiting API calls or managing resource-intensive tasks. It integrates seamlessly with promises, timeouts, and cancellation.

* **Timing Utilities**: `loom:delay` creates promises that resolve after a specified duration, while `loom:timeout` allows you to apply time limits to any promise, rejecting it if it doesn't settle within the given period.

* **Automatic Retries**: `loom:retry` provides a mechanism to automatically re-attempt a function that returns a promise upon failure, with configurable retry limits and delays.

* **Promise Registry & UI**: An introspectable global registry (`loom-registry`) tracks the lifecycle and state of all promises. This powers an interactive UI (`M-x loom:inspect-registry`), offering real-time debugging, filtering by status, name, and tags, and actions like cancelling promises or killing associated processes.

* **Extensible Awaitables**: The `loom-normalize-awaitable-hook` allows other libraries to integrate their custom asynchronous objects into the Loom ecosystem, making them transparently compatible with `loom:await` and promise chaining.

## Installation

Loom.el can be installed via your preferred Emacs package manager.

### straight.el

```elisp
(straight-use-package '(loom :type git :host github :repo "ctwhite/loom"))

```

## Usage

### Basic Promise Usage

```elisp
(require 'loom-primitives)

;; Create a promise that resolves after 0.5 seconds
(let ((my-promise (loom:promise
                   :name "delayed-hello"
                   :executor (lambda (resolve reject)
                               (run-at-time 0.5 nil (lambda () (resolve "Hello, Loom!")))))))

  ;; Attach a handler for successful resolution
  (loom:then my-promise
    (lambda (result)
      (message "Promise resolved with: %s" result)))

  ;; Optionally, attach a handler for rejection
  (loom:catch my-promise
    (lambda (error)
      (message "Promise rejected with: %s" (loom:error-message error))))

  ;; Cooperatively wait for the promise to settle
  (message "Awaiting promise...")
  (let ((final-result (loom:await my-promise 5))) ; Will wait up to 5 seconds
    (message "Awaited result: %s" final-result)))

```

### Cooperative Cancellation

```elisp
(require 'loom-cancel)
(require 'loom-combinators)

(let* ((token (loom:cancel-token "long-operation-token"))
       (long-task-promise (loom:promise
                           :name "long-running-task"
                           :cancel-token token ; Link the token to the promise
                           :executor (lambda (resolve reject)
                                       (message "Long task started...")
                                       ;; Simulate 5 seconds of work
                                       (loom:then (loom:delay 5)
                                                  (lambda (v) (resolve v))
                                                  (lambda (e) (reject e)))))))
  (loom:then long-task-promise
    (lambda (result) (message "Task finished: %s" result))
    (lambda (error) (message "Task failed or cancelled: %s" (loom:error-message error))))

  (run-at-time 1 nil (lambda () ; After 1 second, signal cancellation
                       (message "Signaling cancellation for long task...")
                       (loom:cancel-token-signal token "Operation cancelled by user."))))

```

### Concurrent Operations with Combinators

```elisp
(require 'loom-combinators)

(let* ((p1 (loom:delay 0.5 "First result"))
       (p2 (loom:delay 1.0 "Second result"))
       (p3 (loom:delay 0.2 (error "Operation failed!"))))

  ;; Wait for all promises to settle, regardless of success or failure
  (loom:then (loom:all-settled! p1 p2 p3)
    (lambda (outcomes)
      (message "All tasks settled with outcomes: %S" outcomes)))

  ;; Wait for all promises to succeed (will reject if any fail)
  (loom:then (loom:all! p1 p2)
    (lambda (results) (message "All promises resolved with: %S" results))
    (lambda (error) (message "One or more promises rejected: %S" (loom:error-message error))))

  ;; Wait for the first promise to settle (either resolve or reject)
  (loom:then (loom:race! p1 p3)
    (lambda (result) (message "Race winner (resolved): %S" result))
    (lambda (error) (message "Race winner (rejected): %S" (loom:error-message error))))
  )

```

### Inspecting the Promise UI

To view all active and settled promises in real-time, along with their status, age, and relationships:

```elisp
(require 'loom-ui)
(require 'loom-registry)

;; Ensure the registry is enabled (it is by default)
(setq loom-enable-promise-registry t)

M-x loom:inspect-registry

```

## Configuration

You can customize Loom's behavior using the following `defcustom` variables. These can be configured via `M-x customize-group RET loom RET`.

* `loom-await-default-timeout`: The default timeout duration (in seconds) for `loom:await` operations.

* `loom-await-poll-interval`: The polling interval (in seconds) for cooperative `loom:await` checks.

* `loom-log-value-max-length`: Maximum length for values/errors when logged, to prevent excessively long log entries.

* `loom-enable-promise-registry`: A boolean flag to enable or disable the global promise registry.

* `loom-registry-max-size`: The maximum number of promises the registry will track before evicting older entries.

* `loom-registry-shutdown-on-exit-p`: If non-nil, pending promises will be automatically rejected when Emacs exits.

* `loom-normalize-awaitable-hook`: A hook for functions that convert arbitrary awaitable objects into `loom-promise` instances.

## Module Overview

Loom's functionality is organized into several distinct modules:

* **`loom-core.el`**: Defines the fundamental `loom-promise` structure, core resolution/rejection logic, the `loom:await` macro, and the underlying task scheduling (macrotasks and microtasks), including thread-safe dispatching.

* **`loom-cancel.el`**: Provides the `loom-cancel-token` for managing cooperative cancellation of asynchronous operations.

* **`loom-combinators.el`**: Contains a rich set of functions for working with groups of promises, including concurrency patterns (`loom:all`, `loom:race`, `loom:map`, `loom:retry`) and timing utilities (`loom:delay`, `loom:timeout`).

* **`loom-future.el`**: Implements lazy asynchronous computations through `loom:future` and the `loom:force` function.

* **`loom-lock.el`**: Offers primitives for mutual exclusion locks (`loom:lock`) to ensure thread-safe access to shared resources.

* **`loom-semaphore.el`**: Provides a counting semaphore for controlling concurrency and resource access.

* **`loom-registry.el`**: Manages the global promise registry, enabling introspection and debugging of promise lifecycles.

* **`loom-ui.el`**: The interactive user interface (`M-x loom:inspect-registry`) for visualizing and interacting with the promise registry.

* **`loom-log.el`**: Internal logging utilities for debugging Loom's operations.

* **`loom-errors.el`**: Defines custom error types specific to the Loom library.

* **`loom-microtask.el`**: The low-level implementation of the microtask queue.

* **`loom-scheduler.el`**: A generic framework for scheduling tasks.

* **`loom-primitives.el`**: A collection of common internal helper functions used across the library.

## Contributing

Contributions are highly encouraged! If you have ideas, bug reports, or wish to contribute code, please feel free to open issues or submit pull requests.
