(in-package #:conversation-protocol)

(define-condition conversation-error (error)
  ((message :initarg :message :reader conversation-error-message :initform nil))
  (:report (lambda (c s)
             (format s "conversation error~@[: ~a~]" (conversation-error-message c)))))

(define-condition conversation-missing-backend (conversation-error)
  ((role :initarg :role :reader conversation-missing-backend-role :initform nil))
  (:report (lambda (c s)
             (format s "conversation ~a missing~@[: ~a~]"
                     (or (conversation-missing-backend-role c) "backend")
                     (conversation-error-message c)))))

(define-condition conversation-session-not-found (conversation-error)
  ((session :initarg :session :reader conversation-session-not-found-session
            :initform nil))
  (:report (lambda (c s)
             (format s "conversation session not found: ~s~@[: ~a~]"
                     (conversation-session-not-found-session c)
                     (conversation-error-message c)))))
