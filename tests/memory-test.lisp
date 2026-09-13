(in-package #:conversation-protocol/tests)

(defun %sum-backend ()
  (llm-protocol:make-mock-llm-backend
   :handler (lambda (backend turns &key &allow-other-keys)
              (declare (ignore backend turns))
              (llm-protocol:make-llm-response
               :parts (list (llm-protocol:make-llm-text-part :text "SUM"))))))

(deftest token-window-trims-via-count-tokens
  (let ((mem (conversation-protocol:make-token-window-memory :max-tokens 2)))
    (conversation-protocol:remember
     mem
     (list (llm-protocol:user-turn "AAAA")
           (llm-protocol:user-turn "BBBB")
           (llm-protocol:user-turn "CCCC")))
    (let ((next (conversation-protocol:recall mem "DDDD")))
      (ok (equal '("BBBB" "CCCC" "DDDD") (mapcar #'%text next)))
      (ok (equal '(:user :user :user) (%roles next))))))

(deftest token-window-keeps-system
  (let ((mem (conversation-protocol:make-token-window-memory :max-tokens 2)))
    (conversation-protocol:remember
     mem
     (list (llm-protocol:system-turn "sys")
           (llm-protocol:user-turn "AAAA")
           (llm-protocol:user-turn "BBBB")
           (llm-protocol:user-turn "CCCC")))
    (let ((next (conversation-protocol:recall mem "x")))
      (ok (eq :system (first (%roles next))))
      (ok (equal "sys" (%text (first next))))
      (ok (equal "CCCC" (%text (second next)))))))

(deftest token-window-uses-supplied-backend
  (let* ((backend (make-instance 'llm-protocol:llm-backend))
         (mem (conversation-protocol:make-token-window-memory
               :max-tokens 1 :backend backend)))
    (conversation-protocol:remember
     mem
     (list (llm-protocol:user-turn "AAAA")
           (llm-protocol:user-turn "BBBB")))
    (ok (equal '("BBBB")
               (mapcar #'%text
                       (conversation-protocol:load-session
                        (conversation-protocol:memory-store mem)
                        (conversation-protocol:memory-session mem)))))))

(deftest summary-memory-compresses-oldest
  (let ((mem (conversation-protocol:make-summary-memory
              :window-size 2 :backend (%sum-backend) :session "sum")))
    (conversation-protocol:remember
     mem
     (list (llm-protocol:user-turn "u1")
           (llm-protocol:assistant-turn "a1")
           (llm-protocol:user-turn "u2")
           (llm-protocol:assistant-turn "a2")
           (llm-protocol:user-turn "u3")
           (llm-protocol:assistant-turn "a3"))
     :session "sum")
    (let ((stored (conversation-protocol:load-session
                   (conversation-protocol:memory-store mem) "sum")))
      (ok (find-if #'conversation-protocol:summary-turn-p stored))
      (ok (equal "[summary] SUM"
                 (%text (find-if #'conversation-protocol:summary-turn-p stored))))
      (ok (= 3 (length stored)))
      (ok (equal '(:system :user :assistant) (%roles stored)))
      (ok (equal '("[summary] SUM" "u3" "a3") (mapcar #'%text stored)))
      (ok (< (count-if-not #'conversation-protocol:summary-turn-p stored) 6)))))

(deftest summary-memory-under-window-is-identity
  (let ((mem (conversation-protocol:make-summary-memory
              :window-size 10 :backend (%sum-backend))))
    (conversation-protocol:remember
     mem
     (list (llm-protocol:user-turn "u1")
           (llm-protocol:assistant-turn "a1")))
    (let ((stored (conversation-protocol:load-session
                   (conversation-protocol:memory-store mem)
                   (conversation-protocol:memory-session mem))))
      (ok (null (find-if #'conversation-protocol:summary-turn-p stored)))
      (ok (equal '("u1" "a1") (mapcar #'%text stored))))))

(deftest summary-memory-keeps-real-system
  (let ((mem (conversation-protocol:make-summary-memory
              :window-size 2 :backend (%sum-backend))))
    (conversation-protocol:remember
     mem
     (list (llm-protocol:system-turn "sys")
           (llm-protocol:user-turn "u1")
           (llm-protocol:assistant-turn "a1")
           (llm-protocol:user-turn "u2")
           (llm-protocol:assistant-turn "a2")
           (llm-protocol:user-turn "u3")
           (llm-protocol:assistant-turn "a3")))
    (let ((stored (conversation-protocol:load-session
                   (conversation-protocol:memory-store mem)
                   (conversation-protocol:memory-session mem))))
      (ok (equal "sys"
                 (%text (find-if (lambda (tr)
                                   (and (eq (llm-protocol:llm-turn-role tr) :system)
                                        (not (conversation-protocol:summary-turn-p tr))))
                                 stored))))
      (ok (find-if #'conversation-protocol:summary-turn-p stored))
      (ok (equal '("u3" "a3")
                 (mapcar #'%text
                         (remove-if (lambda (tr)
                                      (eq (llm-protocol:llm-turn-role tr) :system))
                                    stored)))))))

(deftest summary-memory-token-budget
  (let ((mem (conversation-protocol:make-summary-memory
              :window-size 100 :max-tokens 2 :backend (%sum-backend))))
    (conversation-protocol:remember
     mem
     (list (llm-protocol:user-turn "AAAA")
           (llm-protocol:user-turn "BBBB")
           (llm-protocol:user-turn "CCCC")))
    (let ((stored (conversation-protocol:load-session
                   (conversation-protocol:memory-store mem)
                   (conversation-protocol:memory-session mem))))
      (ok (find-if #'conversation-protocol:summary-turn-p stored))
      (ok (equal '("[summary] SUM" "BBBB" "CCCC") (mapcar #'%text stored))))))

(deftest summary-memory-missing-backend-signals
  (let ((llm-protocol:*llm-backend* nil)
        (mem (conversation-protocol:make-summary-memory :window-size 1)))
    (ok (signals
         (conversation-protocol:remember
          mem
          (list (llm-protocol:user-turn "u1")
                (llm-protocol:user-turn "u2")))
         'conversation-protocol:conversation-missing-backend))))
