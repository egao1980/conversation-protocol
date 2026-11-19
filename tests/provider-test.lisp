(in-package #:conversation-protocol/tests)

(defun %native (&optional (summary "PSUM") seen)
  (llm-protocol:make-mock-llm-backend
   :compactor (lambda (turns &key instructions)
                (when seen (setf (car seen) (list turns instructions)))
                summary)))

(defun %talk ()
  (list (llm-protocol:system-turn "sys")
        (llm-protocol:user-turn "q1")
        (llm-protocol:assistant-turn "a1")
        (llm-protocol:user-turn "q2")))

(deftest provider-compaction-memory-compacts-on-the-provider
  (let* ((seen (list nil))
         (mem (conversation-protocol:make-provider-compaction-memory
               :instructions "keep names")))
    (multiple-value-bind (turns did)
        (conversation-protocol:compact-turns mem (%talk) :backend (%native "PSUM" seen))
      (ok did)
      (ok (equal "keep names" (second (car seen))) "instructions reach the provider")
      (ok (= 2 (length turns)))
      (ok (equal "PSUM" (llm-protocol:compaction-part-text
                         (first (llm-protocol:llm-turn-parts (second turns)))))))
    (testing "no summary from the provider: not compacted"
      (multiple-value-bind (turns did)
          (conversation-protocol:compact-turns mem (%talk) :backend (%native nil))
        (ng did)
        (ok (= 4 (length turns)))))))

(deftest provider-compaction-memory-falls-back
  (let ((mem (conversation-protocol:make-provider-compaction-memory
              :fallback (conversation-protocol:make-summary-memory
                         :backend (%sum-backend) :tail-tokens 1))))
    (testing "a backend without compaction uses the fallback"
      (multiple-value-bind (turns did)
          (conversation-protocol:compact-turns mem (%talk)
                                               :backend (llm-protocol:make-mock-llm-backend))
        (ok did)
        (ok (find-if #'conversation-protocol:summary-turn-p turns))))
    (testing "an earlier provider summary reaches the fallback as text"
      (multiple-value-bind (turns did)
          (conversation-protocol:compact-turns
           mem
           (append (llm-protocol:server-compact (%native "OLD") (%talk))
                   (list (llm-protocol:user-turn "q3")
                         (llm-protocol:assistant-turn "a3")
                         (llm-protocol:user-turn "q4")))
           :backend (llm-protocol:make-mock-llm-backend))
        (ok did)
        (ok (notany (lambda (turn)
                      (some #'llm-protocol:compaction-part-p
                            (llm-protocol:llm-turn-parts turn)))
                    turns)
            "no provider part is left for a backend that cannot read it")
        (ok (find-if (lambda (turn) (search "OLD" (llm-protocol:turn-text turn))) turns)
            "the provider summary is not lost"))))
  (testing "no fallback: llm-unsupported, USE-VALUE recovers"
    (let ((mem (conversation-protocol:make-provider-compaction-memory)))
      (ok (signals (conversation-protocol:compact-turns
                    mem (%talk) :backend (llm-protocol:make-mock-llm-backend))
            'llm-protocol:llm-unsupported))
      (multiple-value-bind (turns did)
          (handler-bind ((llm-protocol:llm-unsupported
                          (lambda (c) (use-value (list (llm-protocol:user-turn "x")) c))))
            (conversation-protocol:compact-turns
             mem (%talk) :backend (llm-protocol:make-mock-llm-backend)))
        (ok did)
        (ok (= 1 (length turns)))))))
