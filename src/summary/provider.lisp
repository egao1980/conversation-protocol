(in-package #:conversation-protocol)

;;; PROVIDER-COMPACTION-MEMORY: COMPACT-TURNS asks the backend to summarize
;;; (LLM-PROTOCOL:SERVER-COMPACT — Anthropic compaction on demand). The summary
;;; is the provider's own part, which only that provider reads natively; other
;;; backends get it as text (LLM-PROTOCOL:PORTABLE-TURNS). On a backend that
;;; cannot compact, FALLBACK (e.g. a SUMMARY-MEMORY) compacts instead.

(defclass provider-compaction-memory (conversation-memory)
  ((backend :initarg :backend :accessor provider-compaction-backend :initform nil
            :documentation "Backend that compacts; NIL → the :BACKEND COMPACT-TURNS gets.")
   (model :initarg :model :accessor provider-compaction-model :initform nil)
   (instructions :initarg :instructions :accessor provider-compaction-instructions
                 :initform nil
                 :documentation "Replaces the provider's summarization prompt.")
   (tools :initarg :tools :accessor provider-compaction-tools :initform nil
          :documentation "Tool descriptors of the conversation (the summarizer reads them).")
   (fallback :initarg :fallback :accessor provider-compaction-fallback :initform nil
             :documentation "Memory that compacts when the backend cannot, or NIL.")))

(defun make-provider-compaction-memory (&key store (session "default") backend model
                                          instructions tools fallback)
  (check-type instructions (or null string))
  (make-instance 'provider-compaction-memory
                 :store store :session session :backend backend :model model
                 :instructions instructions :tools tools :fallback fallback))

(defun provider-compaction-memory-p (x)
  (typep x 'provider-compaction-memory))

(defmethod compact-turns ((memory provider-compaction-memory) turns &key backend)
  "→ (values new-turns compacted-p). No summary from the provider (cut off,
refused, …) is NIL: the caller goes on and compacts later. A backend without
provider compaction uses FALLBACK on the portable turns, or signals
LLM-PROTOCOL:LLM-UNSUPPORTED (with USE-VALUE to give new turns)."
  (let ((b (or (provider-compaction-backend memory) backend llm-protocol:*llm-backend*))
        (turns (llm-protocol:coerce-turns turns)))
    (cond
      ((and b (llm-protocol:backend-supports-p b :compaction))
       (multiple-value-bind (new did)
           (llm-protocol:server-compact b turns
                                        :model (provider-compaction-model memory)
                                        :tools (provider-compaction-tools memory)
                                        :instructions (provider-compaction-instructions memory))
         (values new did)))
      ((provider-compaction-fallback memory)
       (compact-turns (provider-compaction-fallback memory)
                      (llm-protocol:portable-turns turns)
                      :backend b))
      (t
       (restart-case
           (error 'llm-protocol:llm-unsupported
                  :message (format nil "~a cannot compact and the memory has no :fallback"
                                   (if b (type-of b) "no backend")))
         (use-value (new-turns)
           :report "Use these turns as the compacted history"
           (values new-turns t)))))))
