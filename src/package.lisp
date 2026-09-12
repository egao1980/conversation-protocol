(defpackage #:conversation-protocol
  (:use #:cl)
  (:nicknames #:stack-conversation)
  (:export #:conversation-error
           #:conversation-error-message
           #:conversation-missing-backend
           #:conversation-missing-backend-role
           #:conversation-session-not-found
           #:conversation-session-not-found-session

           #:conversation-store
           #:conversation-memory
           #:*conversation-store*
           #:*conversation-memory*

           #:load-session
           #:save-session
           #:delete-session
           #:recall
           #:remember
           #:clear-memory

           #:coerce-session
           #:window-turns

           #:in-memory-conversation-store
           #:make-in-memory-conversation-store

           #:buffer-memory
           #:make-buffer-memory
           #:window-memory
           #:make-window-memory
           #:window-memory-size

           #:token-window-memory
           #:make-token-window-memory
           #:token-window-memory-max-tokens
           #:token-window-memory-backend
           #:token-window-memory-reserve
           #:token-window-memory-model
           #:use-token-window-memory

           #:summary-memory
           #:make-summary-memory
           #:summary-memory-window-size
           #:summary-memory-max-tokens
           #:summary-memory-backend
           #:summary-memory-reserve
           #:summary-memory-model
           #:summary-memory-prompt
           #:use-summary-memory
           #:summary-turn-p
           #:+summary-prefix+

           #:memory-store
           #:memory-session

           #:use-buffer-memory
           #:use-window-memory))

(in-package #:conversation-protocol)
