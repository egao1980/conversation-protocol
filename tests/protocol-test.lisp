(in-package #:conversation-protocol/tests)

(defun %text (turn)
  (llm-protocol:turn-text turn))

(defun %roles (turns)
  (mapcar #'llm-protocol:llm-turn-role turns))

(deftest coerce-session-shapes
  (ok (equal "default" (conversation-protocol:coerce-session nil)))
  (ok (equal "s1" (conversation-protocol:coerce-session "s1")))
  (ok (equal "FOO" (conversation-protocol:coerce-session :foo))))

(deftest buffer-recall-remember
  (let ((mem (conversation-protocol:make-buffer-memory :session "s1")))
    (ok (equal '(:user)
               (%roles (conversation-protocol:recall mem "hi" :session "s1"))))
    (conversation-protocol:remember mem (list (llm-protocol:user-turn "hi")
                                              (llm-protocol:assistant-turn "yo"))
                                    :session "s1")
    (let ((next (conversation-protocol:recall mem "again" :session "s1")))
      (ok (equal '(:user :assistant :user) (%roles next)))
      (ok (equal '("hi" "yo" "again") (mapcar #'%text next))))))

(deftest remember-replace
  (let ((mem (conversation-protocol:make-buffer-memory)))
    (conversation-protocol:remember mem (list (llm-protocol:user-turn "old")
                                              (llm-protocol:assistant-turn "a")))
    (conversation-protocol:remember mem (list (llm-protocol:user-turn "new")
                                              (llm-protocol:assistant-turn "b"))
                                    :replace t)
    (let ((next (conversation-protocol:recall mem "x")))
      (ok (equal '("new" "b" "x") (mapcar #'%text next))))))

(deftest sessions-isolated
  (let* ((store (conversation-protocol:make-in-memory-conversation-store))
         (mem (conversation-protocol:make-buffer-memory :store store)))
    (conversation-protocol:remember mem (llm-protocol:user-turn "a") :session "one")
    (conversation-protocol:remember mem (llm-protocol:user-turn "b") :session "two")
    (ok (equal '("a" "c")
               (mapcar #'%text (conversation-protocol:recall mem "c" :session "one"))))
    (ok (equal '("b" "d")
               (mapcar #'%text (conversation-protocol:recall mem "d" :session "two"))))))

(deftest window-keeps-system-and-last-n
  (let ((mem (conversation-protocol:make-window-memory :window-size 2)))
    (conversation-protocol:remember
     mem
     (list (llm-protocol:system-turn "sys")
           (llm-protocol:user-turn "u1")
           (llm-protocol:assistant-turn "a1")
           (llm-protocol:user-turn "u2")
           (llm-protocol:assistant-turn "a2")
           (llm-protocol:user-turn "u3")
           (llm-protocol:assistant-turn "a3")))
    (let ((next (conversation-protocol:recall mem "u4")))
      (ok (equal '(:system :user :assistant :user) (%roles next)))
      (ok (equal '("sys" "u3" "a3" "u4") (mapcar #'%text next))))))

(deftest window-size-zero-keeps-system
  (let ((mem (conversation-protocol:make-window-memory :window-size 0)))
    (conversation-protocol:remember
     mem
     (list (llm-protocol:system-turn "sys")
           (llm-protocol:user-turn "u1")
           (llm-protocol:assistant-turn "a1")))
    (ok (equal '("sys" "x")
               (mapcar #'%text (conversation-protocol:recall mem "x"))))))

(deftest window-shared-store-with-buffer
  (let* ((store (conversation-protocol:make-in-memory-conversation-store))
         (buf (conversation-protocol:make-buffer-memory :store store :session "chat"))
         (win (conversation-protocol:make-window-memory :store store :session "chat"
                                                        :window-size 1)))
    (conversation-protocol:remember buf (list (llm-protocol:user-turn "u1")
                                              (llm-protocol:assistant-turn "a1")
                                              (llm-protocol:user-turn "u2")
                                              (llm-protocol:assistant-turn "a2")))
    (conversation-protocol:remember win nil)
    (ok (equal '("a2" "z")
               (mapcar #'%text (conversation-protocol:recall win "z"))))))

(deftest store-roundtrip
  (let ((store (conversation-protocol:make-in-memory-conversation-store)))
    (ok (null (conversation-protocol:load-session store "s")))
    (conversation-protocol:save-session store "s" (llm-protocol:user-turn "hi"))
    (ok (equal '("hi")
               (mapcar #'%text (conversation-protocol:load-session store "s"))))
    (conversation-protocol:delete-session store "s")
    (ok (null (conversation-protocol:load-session store "s")))))

(deftest clear-memory-empty-ok
  (let ((mem (conversation-protocol:make-buffer-memory)))
    (conversation-protocol:clear-memory mem)
    (conversation-protocol:remember mem "hi")
    (conversation-protocol:clear-memory mem)
    (ok (equal '(:user)
               (%roles (conversation-protocol:recall mem "x"))))))

(deftest incoming-not-persisted-until-remember
  (let ((mem (conversation-protocol:make-buffer-memory)))
    (conversation-protocol:recall mem "ghost")
    (ok (equal '("later")
               (mapcar #'%text (conversation-protocol:recall mem "later"))))))

(deftest no-store-signals
  (let ((conversation-protocol:*conversation-store* nil))
    (ok (signals (conversation-protocol:load-session nil "s")
                 'conversation-protocol:conversation-missing-backend))))

(deftest no-memory-signals
  (let ((conversation-protocol:*conversation-memory* nil))
    (ok (signals (conversation-protocol:recall nil "hi")
                 'conversation-protocol:conversation-missing-backend))))
