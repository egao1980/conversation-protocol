(defsystem "conversation-protocol"
  :version "0.1.0"
  :description "CLOS conversation memory protocol for cl-stack (session store + buffer/window)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("llm-protocol")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "protocol")
               (:file "memory"))
  :in-order-to ((test-op (test-op "conversation-protocol/tests"))))

(defsystem "conversation-protocol/tests"
  :depends-on ("conversation-protocol" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "protocol-test")
               (:file "restarts-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
