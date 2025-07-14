;;; loom.el --- Composable concurrency primitives for Emacs -*- lexical-binding: t -*-
;;
;; Author: Christian White <christiantwhite@protonmail.com>
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1") (cl-lib "0.5") (s "1.12.0")
;;                    (dash "2.19.1") (f "0.20.0"))
;; Homepage: https://github.com/ctwhite/loom
;; Keywords: loomrency, async, promises, futures, tasks, lisp, emacs

;;; Commentary:
;;
;; `loom.el` provides a suite of composable loomrency primitives for
;; Emacs Lisp, inspired by asynchronous patterns found in modern programming
;; languages. The goal is to simplify reasoning about and managing
;; asynchronous workflows within the cooperative multitasking environment of
;; Emacs.
;;
;; The library is structured into modular components, each addressing a
;; specific aspect of loomrency:
;;
;; - Foundational Data Structures:
;;   - `loom-log`: Centralized logging.
;;   - `loom-errors`: Standardized error objects and handling.
;;   - `loom-lock`: Thread-safe mutexes.
;;   - `loom-queue`, `loom-priority-queue`: Core queue implementations.
;;
;; - Core Promise System:
;;   - `loom-microtask`, `loom-scheduler`: Queues for immediate and
;;     deferred execution of callbacks.
;;   - `loom-registry`: An optional global registry for introspection.
;;   - `loom-core`: The foundational `loom-promise` data structure.
;;   - `loom-primitives`: `loom:then`, `loom:catch`, `loom:finally`.
;;   - `loom-cancel`: Primitives for cooperative task cancellation.
;;
;; - High-Level Primitives & Combinators:
;;   - `loom-combinators`: `loom:all`, `loom:race`, `loom:retry`, etc.
;;   - `loom-event`, `loom-semaphore`: Classic synchronization primitives.
;;   - `loom-future`: For lazy, deferred computations.
;;   - `loom-flow`: Asynchronous control flow primitives.
;;

;;; Code:

;;;###autoload
(defconst loom-version "1.0.0"
  "The version number of the loom.el library.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Concur Modules Loading

;; NOTE: The load order here is critical to satisfy dependencies.

;; Foundational Data Structures
(require 'loom-log)
(require 'loom-errors)
(require 'loom-callback)
(require 'loom-lock)
(require 'loom-queue)
(require 'loom-priority-queue)

;; Schedulers and Core Promise System
(require 'loom-microtask)
(require 'loom-scheduler)
(require 'loom-registry)
(require 'loom-config)
(require 'loom-promise)
(require 'loom-primitives)
(require 'loom-cancel)

;; High-Level Primitives and Combinators
(require 'loom-combinators)
(require 'loom-event)
(require 'loom-future)
(require 'loom-semaphore)
(require 'loom-flow)
  
(provide 'loom)
;;; loom.el ends here