(defsystem "conversation-protocol"
  :version "0.2.0"
  :description "CLOS conversation memory protocol for cl-stack (session store + buffer/window/token-window)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("llm-protocol")
  :properties (:cl-repo
               (:ci (:with ("conversation-protocol/summary"))))
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "protocol")
               (:file "memory"))
  :in-order-to ((test-op (test-op "conversation-protocol/tests"))))

(defsystem "conversation-protocol/summary"
  :version "0.2.0"
  :description "LLM summary-memory for conversation-protocol (generate isolated from core)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("conversation-protocol" "llm-protocol")
  :serial t
  :pathname "src/summary"
  :components ((:file "memory"))
  :in-order-to ((test-op (test-op "conversation-protocol/tests"))))

(defsystem "conversation-protocol/tests"
  :depends-on ("conversation-protocol" "conversation-protocol/summary" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "protocol-test")
               (:file "memory-test")
               (:file "restarts-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
