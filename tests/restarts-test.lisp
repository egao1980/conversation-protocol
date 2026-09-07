(in-package #:conversation-protocol/tests)

(deftest missing-store-use-value
  (let* ((store (conversation-protocol:make-in-memory-conversation-store))
         (conversation-protocol:*conversation-store* nil))
    (handler-bind ((conversation-protocol:conversation-missing-backend
                    (lambda (c)
                      (use-value store c))))
      (conversation-protocol:save-session nil "s" (llm-protocol:user-turn "hi")))
    (ok (equal "hi"
               (llm-protocol:turn-text
                (first (conversation-protocol:load-session store "s")))))))

(deftest missing-memory-use-value
  (let* ((mem (conversation-protocol:make-buffer-memory))
         (conversation-protocol:*conversation-memory* nil))
    (handler-bind ((conversation-protocol:conversation-missing-backend
                    (lambda (c)
                      (use-value mem c))))
      (conversation-protocol:remember nil (llm-protocol:user-turn "hi")))
    (ok (equal '("hi" "x")
               (mapcar #'llm-protocol:turn-text
                       (conversation-protocol:recall mem "x"))))))

(deftest delete-missing-signals
  (let ((store (conversation-protocol:make-in-memory-conversation-store)))
    (ok (signals (conversation-protocol:delete-session store "nope")
                 'conversation-protocol:conversation-session-not-found))))

(deftest delete-missing-continue
  (let ((store (conversation-protocol:make-in-memory-conversation-store)))
    (conversation-protocol:save-session store "s" (llm-protocol:user-turn "hi"))
    (handler-bind ((conversation-protocol:conversation-session-not-found
                    (lambda (c)
                      (declare (ignore c))
                      (invoke-restart 'continue))))
      (conversation-protocol:delete-session store "missing"))
    (ok (equal "hi"
               (llm-protocol:turn-text
                (first (conversation-protocol:load-session store "s")))))))

(deftest delete-missing-use-value
  (let ((store (conversation-protocol:make-in-memory-conversation-store))
        (got nil))
    (handler-bind ((conversation-protocol:conversation-session-not-found
                    (lambda (c)
                      (use-value :skipped c))))
      (setf got (conversation-protocol:delete-session store "missing")))
    (ok (eq :skipped got))))
