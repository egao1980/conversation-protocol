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

           #:memory-store
           #:memory-session

           #:use-buffer-memory
           #:use-window-memory))

(in-package #:conversation-protocol)
