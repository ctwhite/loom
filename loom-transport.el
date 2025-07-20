;;; loom-transport.el --- Abstract Communication Transport Protocol -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the `loom:defprotocol!` macro, a declarative
;; mechanism for defining and registering abstract communication
;; **transports** within the Loom concurrency framework.
;;
;; It allows different underlying transport mechanisms (like named pipes,
;; WebSockets, or TCP sockets) to conform to a unified interface,
;; reducing boilerplate and simplifying interactions at higher levels
;; of the Loom stack (e.g., `loom-channel`, `loom-distributed`).
;;
;; ## Core Concepts:
;;
;; - **Abstract Protocol Interface:** Defines a set of standard operations
;;   (e.g., `open`, `close`, `send`, `receive`, `bridge`, `health-check`)
;;   that any communication protocol should implement. These operations
;;   are exposed via `loom:transport-*` functions.
;;
;; - **`loom-transport-protocol` Struct:** A runtime representation that
;;   holds the concrete Emacs Lisp functions implementing the abstract
;;   interface for a specific transport (e.g., for `:pipe` or `:tcp`).
;;
;; - **Protocol Resolution:** The `loom-transport` module can automatically
;;   determine the correct transport implementation based on a flexible
;;   matcher function for addresses (e.g., "ipc://", "ws://", "tcp://").
;;   Connection objects returned by transports are expected to derive
;;   from `loom-transport-connection` or carry their associated protocol name.
;;
;; - **`loom-transport-connection` Struct:** A common base struct for all
;;   connection objects, ensuring they consistently carry their protocol
;;   name and address.
;;
;; - **`loom:defprotocol!` Macro:** The primary tool for transport authors.
;;   This macro generates the necessary plumbing to register a new
;;   transport implementation.
;;
;; This abstraction allows higher-level modules to interact with any
;; registered transport in a generalized manner, without needing to know
;; the low-level details of each underlying communication method.

;;; Code:

(require 'cl-lib)

(require 'loom-errors)
(require 'loom-log)
(require 'loom-promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'loom-transport-error
  "Generic transport protocol error."
  'loom-error)

(define-error 'loom-unsupported-protocol-operation
  "An operation is not supported by the current transport protocol."
  'loom-transport-error
  :protocol keyword
  :operation symbol)

(define-error 'loom-unknown-protocol-error
  "No transport protocol implementation found for the given context."
  'loom-transport-error
  :context t)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global State

(defvar loom-transport--registry (make-hash-table :test 'eq)
  "Global registry mapping protocol keywords to `loom-transport-protocol`
structs.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (loom-transport-connection
               (:constructor %%make-transport-connection)
               (:copier nil))
  "Base struct for all transport connection objects.

All concrete connection objects returned by transport implementations
(e.g., for pipes, WebSockets, TCP) should `:include` this struct.
This ensures a standardized way to retrieve the connection's protocol
and address for dispatching generic `loom:transport-*` calls.

Fields:

- `protocol-name` (keyword): The keyword name of the protocol that owns
  this connection (e.g., `:pipe`, `:websocket`, `:tcp`).

- `address` (string): The address string associated with this connection
  (e.g., the pipe path, URL, or host:port)."
  (protocol-name (cl-assert nil "Protocol name is required") :type keyword)
  (address (cl-assert nil "Address is required") :type string))

(cl-defstruct (loom-transport-protocol
               (:constructor %%make-transport-protocol)
               (:copier nil))
  "Represents the implementation of an abstract communication protocol.

Each field holds a function that implements a specific protocol operation.
If an operation is not supported, its field should be `nil`. Calling
the corresponding `loom:transport-*` function will then signal a
`loom-unsupported-protocol-operation` error.

Fields:
- `protocol-name` (keyword): The unique name of the protocol (e.g., `:pipe`).
- `protocol-matcher-fn` (function): `(lambda (address-string))` -> `boolean`
  A predicate that returns non-`nil` if `address-string` matches this protocol.
- `open-fn` (function): `(lambda (address options))` -> `promise<connection>`
  Establishes a connection or starts a listener.
- `close-fn` (function): `(lambda (connection))` -> `promise<t>`
  Closes a connection or stops a listener.
- `send-fn` (function): `(lambda (connection data))` -> `promise<t>`
  Sends data over an established connection.
- `receive-fn` (function): `(lambda (connection))` -> `promise<data>`
  Asynchronously receives data from a connection.
- `bridge-to-channel-fn` (function): `(lambda (connection channel))` -> `promise<t>`
  Bridges incoming data from a connection to a `loom-channel`.
- `health-check-fn` (function): `(lambda (connection))` -> `boolean`
  Checks the health of the connection or listener.
- `get-connection-fn` (function): `(lambda (address options))` -> `promise<connection>`
  (Optional) For client pools, gets an existing or new connection.
- `cleanup-fn` (function): `(lambda ())` -> `void`
  (Optional) Performs global cleanup for the protocol (e.g., shuts down pools)."
  (protocol-name (cl-assert nil "Protocol name is required") :type keyword)
  (protocol-matcher-fn (cl-assert nil "Protocol matcher is required") :type function)
  (open-fn nil :type (or null function))
  (close-fn nil :type (or null function))
  (send-fn nil :type (or null function))
  (receive-fn nil :type (or null function))
  (bridge-to-channel-fn nil :type (or null function))
  (health-check-fn nil :type (or null function))
  (get-connection-fn nil :type (or null function))
  (cleanup-fn nil :type (or null function)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Implementation

(defconst loom-transport--protocol-property 'loom-transport-protocol-name
  "The property name used to associate a process object with a protocol.
This is a fallback for connection objects that are raw `processp` types
and cannot `:include` the `loom-transport-connection` struct.")

(defun loom-transport--get-protocol-impl-by-name (protocol-name)
  "Retrieve the `loom-transport-protocol` struct by its keyword name.

Arguments:

- `PROTOCOL-NAME` (keyword): The name of the protocol (e.g., `:pipe`).

Returns:

- The protocol implementation struct, or `nil` if not found."
  (declare (pure t) (side-effect-free t))
  (gethash protocol-name loom-transport--registry))

(defun loom-transport--get-protocol-impl-by-connection (connection)
  "Retrieve the protocol implementation associated with a `CONNECTION`.

It determines the protocol based on the type of `CONNECTION`:
- If it is a `loom-transport-connection` (or a struct that includes it),
  it reads the `protocol-name` slot.
- If it is a raw Emacs `process`, it checks for the
  `loom-transport--protocol-property`.

Arguments:

- `CONNECTION` (any): The connection object.

Returns:

- The protocol implementation, or `nil` if it cannot be determined."
  (let ((protocol-name
         (cond
           ;; Most robust check: does it conform to the base struct type?
           ((cl-typep connection 'loom-transport-connection)
            (loom-transport-connection-protocol-name connection))
           ;; Fallback for raw process objects.
           ((processp connection)
            (process-get connection loom-transport--protocol-property))
           (t nil))))
    (when protocol-name
      (loom-transport--get-protocol-impl-by-name protocol-name))))

(defun loom-transport--resolve-protocol (context)
  "Resolve the transport protocol implementation from a `CONTEXT`.

`CONTEXT` can be a protocol keyword, an address string, or a connection
object. This is the central resolver for the transport system.

Arguments:

- `CONTEXT`: The object used to identify the protocol.

Returns:

- A `loom-transport-protocol` struct.

Signals:

- `loom-unknown-protocol-error`: If no implementation is found."
  (let ((impl (cond
                ((keywordp context)
                 (loom-transport--get-protocol-impl-by-name context))
                ((stringp context)
                 (loom:transport-get-protocol-impl-by-address context))
                (t (loom-transport--get-protocol-impl-by-connection context)))))
    (or impl
        (signal 'loom-unknown-protocol-error
                (list :context context
                      :message (format "No protocol for context: %S"
                                       context))))))

(defun loom-transport--call-protocol-fn (context fn-slot &rest args)
  "Resolve a protocol from `CONTEXT` and invoke its function in `FN-SLOT`.
This is the primary internal dispatcher.

Arguments:
- `CONTEXT` (keyword|string|connection): Determines which protocol to use.
- `FN-SLOT` (symbol): The slot in `loom-transport-protocol` holding the
  function to call.
- `ARGS`: Arguments to pass to the resolved function.

Returns:
- The result of the function call.

Signals:
- `loom-unknown-protocol-error`: If the protocol cannot be resolved.
- `loom-unsupported-protocol-operation`: If the protocol is found but does
  not implement the requested `FN-SLOT`."
  (let* ((impl (loom-transport--resolve-protocol context))
         (fn (cl-struct-slot-value 'loom-transport-protocol fn-slot impl)))
    (unless fn
      (signal 'loom-unsupported-protocol-operation
              (list :protocol (loom-transport-protocol-protocol-name impl)
                    :operation fn-slot
                    :message (format "Protocol '%s' does not support: %s"
                                     (loom-transport-protocol-protocol-name impl)
                                     fn-slot))))
    (apply fn args)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API (Abstract Interface)

;;;###autoload
(defun loom:transport-get-protocol-impl-by-address (address)
  "Find a protocol implementation by matching its `protocol-matcher-fn`.
This function iterates through all registered transport protocols and returns
the first one whose matcher function returns true for the given `ADDRESS`.

Arguments:

- `ADDRESS` (string): The address string (e.g., \"ipc:///tmp/foo\").

Returns:

- (loom-transport-protocol or nil): The first matching protocol
  implementation struct, or `nil` if no protocol matches the address."
  (cl-loop for impl being the hash-values of loom-transport--registry
           when (funcall (loom-transport-protocol-protocol-matcher-fn impl)
                         address)
           return impl))

;;;###autoload
(defun loom:transport-listen (address &rest options)
  "Start a listener for incoming connections on the given `ADDRESS`.
The protocol is derived from the `ADDRESS` (e.g., \"tcp://localhost:8080\").
This dispatches to the underlying transport's `:open-fn` implementation.

Arguments:

- `ADDRESS` (string): The address to listen on, with protocol prefix.
- `OPTIONS` (plist): Transport-specific options for listening.

Returns:

- (loom-promise): A promise that resolves to a listener connection object."
  (apply #'loom-transport--call-protocol-fn address 'open-fn address options))

;;;###autoload
(defun loom:transport-connect (address &rest options)
  "Establish an outgoing client connection to the given `ADDRESS`.
The protocol is derived from `ADDRESS` (e.g., \"ws://example.com/socket\").
This dispatches to the underlying transport's `:open-fn` implementation.

Arguments:

- `ADDRESS` (string): The address of the remote endpoint.
- `OPTIONS` (plist): Transport-specific options for connecting.

Returns:

- (loom-promise): A promise that resolves to a client connection object."
  (apply #'loom-transport--call-protocol-fn address 'open-fn address options))

;;;###autoload
(defun loom:transport-get-connection (address &rest options)
  "Get an existing or establish a new client connection to the `ADDRESS`.
This dispatches to the protocol's `:get-connection-fn` if available (for
connection pooling). If not, it falls back to `:open-fn`.

Arguments:

- `ADDRESS` (string): The address of the remote endpoint.
- `OPTIONS` (plist): Options passed to `:get-connection-fn` or `:open-fn`.

Returns:

- (loom-promise): A promise that resolves to a connection object."
  (let* ((impl (loom-transport--resolve-protocol address))
         (get-conn-fn (loom-transport-protocol-get-connection-fn impl)))
    (if get-conn-fn
        ;; Use the specialized get-connection function if it exists.
        (apply get-conn-fn address options)
      ;; Otherwise, fallback to the standard connect function.
      (progn
        (loom:log-debug! (loom-transport-protocol-protocol-name impl)
                         "No :get-connection-fn for '%s', using :open-fn."
                         (loom-transport-protocol-protocol-name impl))
        (apply #'loom:transport-connect address options)))))

;;;###autoload
(defun loom:transport-close-connection (connection)
  "Close a specific `CONNECTION`.
The protocol is derived from the `CONNECTION` object. This function
dispatches to the underlying transport's `:close-fn` implementation.

Arguments:

- `CONNECTION` (any): The connection object to close.

Returns:

- (loom-promise): A promise that resolves to `t` on successful closure."
  (loom-transport--call-protocol-fn connection 'close-fn connection))

;;;###autoload
(defun loom:transport-send-on-connection (connection data)
  "Send `DATA` over an established `CONNECTION`.
This dispatches to the underlying transport's `:send-fn` implementation.

Arguments:

- `CONNECTION` (any): The established connection object.
- `DATA`: The data to send. The format is defined by the protocol.

Returns:

- (loom-promise): A promise that resolves to `t` on successful send."
  (loom-transport--call-protocol-fn connection 'send-fn connection data))

;;;###autoload
(defun loom:transport-send-to-address (address data &rest options)
  "Establish a connection and send `DATA` to `ADDRESS`.
This is a convenience function that chains `get-connection` and `send`.

Arguments:

- `ADDRESS` (string): The target address.
- `DATA`: The data to send.
- `OPTIONS` (plist): Options passed to `loom:transport-get-connection`.

Returns:

- (loom-promise): A promise that resolves to `t` on successful send."
  (loom:then (apply #'loom:transport-get-connection address options)
              (lambda (conn)
                (loom:transport-send-on-connection conn data))))

;;;###autoload
(defun loom:transport-receive-on-connection (connection)
  "Receive data from a `CONNECTION`.
This dispatches to the underlying transport's `:receive-fn` implementation.

Arguments:

- `CONNECTION` (any): The connection object to receive from.

Returns:

- (loom-promise): A promise that resolves to the received data."
  (loom-transport--call-protocol-fn connection 'receive-fn connection))

;;;###autoload
(defun loom:transport-bridge-connection-to-channel (connection channel)
  "Bridge incoming data from `CONNECTION` to a `CHANNEL`.
This dispatches to the protocol's `:bridge-to-channel-fn`. It's used for
continuous data flows into a `loom-channel`.

Arguments:

- `CONNECTION` (any): The connection object to bridge from.
- `CHANNEL` (loom-channel): The target `loom-channel` to receive data.

Returns:

- (loom-promise): A promise that resolves when the bridge is set up."
  (loom-transport--call-protocol-fn
   connection 'bridge-to-channel-fn connection channel))

;;;###autoload
(defun loom:transport-check-connection-health (connection)
  "Check the health of a `CONNECTION`.
This dispatches to the transport's `:health-check-fn` implementation.

Arguments:

- `CONNECTION` (any): The connection or listener object to check.

Returns:

- (boolean): `t` if the connection is healthy, `nil` otherwise."
  (loom-transport--call-protocol-fn connection 'health-check-fn connection))

;;;###autoload
(defun loom:transport-cleanup-protocol (protocol-name)
  "Perform global cleanup for a specific `PROTOCOL-NAME`.
This dispatches to the transport's `:cleanup-fn`, which should release
any global resources held by that protocol (e.g., connection pools).

Arguments:

- `PROTOCOL-NAME` (keyword): The protocol to clean up (e.g., `:tcp`).

Returns:

- `nil`."
  (loom-transport--call-protocol-fn protocol-name 'cleanup-fn))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Macro for Transport Protocol Definition

;;;###autoload
(cl-defmacro loom:defprotocol! (protocol-name 
                                &key (protocol-matcher-fn
                                       (cl-assert nil "A :protocol-matcher-fn is required."))
                                     open-fn
                                     close-fn
                                     send-fn
                                     receive-fn
                                     bridge-to-channel-fn
                                     health-check-fn
                                     get-connection-fn
                                     cleanup-fn)
  "Define and register a new communication transport protocol.

This macro creates a `loom-transport-protocol` struct and registers it
globally under `PROTOCOL-NAME`. If an optional function (e.g., `:send-fn`)
is not provided, calls to its corresponding API function will signal a
`loom-unsupported-protocol-operation` error at runtime.

Example:

  (loom:defprotocol! :my-ipc
    :protocol-matcher-fn (lambda (addr) (string-prefix-p \"my-ipc://\" addr))
    :open-fn #'my-ipc-open
    :close-fn #'my-ipc-close
    :send-fn #'my-ipc-send)

Arguments:
- `PROTOCOL-NAME` (keyword): The unique name for the protocol (e.g., `:pipe`).
- `:protocol-matcher-fn` (function): (Required) A predicate that takes an
  address string and returns non-`nil` if it belongs to this protocol.
  Signature: `(lambda (address-string))` -> `boolean`.
- `:open-fn` (function): Opens connections or starts listeners.
  Signature: `(lambda (address options))` -> `promise<connection>`.
- `:close-fn` (function): Closes connections or listeners.
  Signature: `(lambda (connection))` -> `promise<t>`.
- `:send-fn` (function): Sends data over a connection.
  Signature: `(lambda (connection data))` -> `promise<t>`.
- `:receive-fn` (function): Receives data from a connection.
  Signature: `(lambda (connection))` -> `promise<data>`.
- `:bridge-to-channel-fn` (function): Bridges a connection to a `loom-channel`.
  Signature: `(lambda (connection channel))` -> `promise<t>`.
- `:health-check-fn` (function): Checks connection health.
  Signature: `(lambda (connection))` -> `boolean`.
- `:get-connection-fn` (function): (Client-side) Retrieves a pooled connection.
  Signature: `(lambda (target-address options))` -> `promise<connection>`.
- `:cleanup-fn` (function): Performs global cleanup for the protocol.
  Signature: `(lambda ())` -> `void`."
  (declare (indent 1)
           (debug (protocol-name &rest _ (backquote (progn &body)))))
  `(progn
     (setf (gethash ,protocol-name loom-transport--registry)
           (%%make-transport-protocol
            :protocol-name ,protocol-name
            :protocol-matcher-fn ,protocol-matcher-fn
            :open-fn ,open-fn
            :close-fn ,close-fn
            :send-fn ,send-fn
            :receive-fn ,receive-fn
            :bridge-to-channel-fn ,bridge-to-channel-fn
            :health-check-fn ,health-check-fn
            :get-connection-fn ,get-connection-fn
            :cleanup-fn ,cleanup-fn))
     (loom:log-debug! ,protocol-name "Protocol '%s' registered." ,protocol-name)
     ',protocol-name))

(provide 'loom-transport)
;;; loom-transport.el ends here
