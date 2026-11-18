(in-package #:conversation-protocol)

;;; Compress oldest overflow via llm-protocol:generate.
;;; Loaded only with conversation-protocol/summary so core stays free of generate.

(defparameter +summary-prefix+ "[summary]"
  "Prefix of a :system summary turn. Documented choice: summaries are :system
   turns starting with this prefix, not a dedicated user/system role.")

(defparameter +compaction-prompt+
  "You are compacting a long agent conversation so the work can continue in a
fresh context. The transcript follows. Write a summary under these markdown
headings, keeping every fact needed to carry on:

## Objective
What the user ultimately wants.
## Requirements
Constraints, preferences and instructions the user gave, verbatim where exact.
## Decisions
What was decided and why; approaches ruled out.
## Work State
What is done, what is in progress, what failed (with exact error text).
## Next Move
The very next step.
## Relevant Files
Paths, symbols and identifiers touched or needed.
## Important Context
Anything else that would be costly to rediscover.

If the transcript opens with an earlier summary, merge it in: keep what is
still true, drop what was superseded. Reply with the summary only."
  "Default SUMMARY-MEMORY prompt: a fixed template, so a compaction keeps the
same facts every time instead of whatever a free-form summary picks.")

(defvar *summary-part-chars* 2000
  "Tool arguments and results longer than this are clipped in the transcript
sent for summarizing.")

(defun %clip (text)
  (let ((text (or text "")))
    (if (<= (length text) *summary-part-chars*)
        text
        (format nil "~a … [+~d chars]" (subseq text 0 *summary-part-chars*)
                (- (length text) *summary-part-chars*)))))

(defun %render-part (part)
  (typecase part
    (llm-protocol:llm-thinking-part nil)
    (llm-protocol:llm-tool-call-part
     (format nil "[tool call ~a ~a]"
             (llm-protocol:llm-tool-call-part-name part)
             (%clip (llm-protocol:llm-tool-call-part-arguments part))))
    (llm-protocol:llm-tool-result-part
     (format nil "[tool result ~a~:[~; (error)~]] ~a"
             (or (llm-protocol:llm-tool-result-part-name part) "")
             (llm-protocol:llm-tool-result-part-error-p part)
             (%clip (llm-protocol:llm-tool-result-part-content part))))
    (t (llm-protocol:part-text part))))

(defun render-transcript (turns)
  "TURNS as plain text, one block per turn, for a summarizing GENERATE.
Plain text cannot break provider rules (a tool call without its result)."
  (with-output-to-string (s)
    (dolist (turn (llm-protocol:coerce-turns turns))
      (let ((texts (remove-if (lambda (x) (or (null x) (zerop (length x))))
                              (mapcar #'%render-part (llm-protocol:llm-turn-parts turn)))))
        (when texts
          (format s "~&~:@(~a~):~%~{~a~^~%~}~%~%"
                  (if (summary-turn-p turn) "earlier summary" (llm-protocol:llm-turn-role turn))
                  texts))))))

(defclass summary-memory (conversation-memory)
  ((window-size :initarg :window-size :accessor summary-memory-window-size
                :initform 10)
   (max-tokens :initarg :max-tokens :accessor summary-memory-max-tokens
               :initform nil)
   (backend :initarg :backend :accessor summary-memory-backend :initform nil)
   (reserve :initarg :reserve :accessor summary-memory-reserve :initform 0)
   (model :initarg :model :accessor summary-memory-model :initform nil)
   (tail-tokens :initarg :tail-tokens :accessor summary-memory-tail-tokens
                :initform 15000
                :documentation "COMPACT-TURNS keeps the newest turns up to this many
tokens verbatim (at least the last one) and summarizes the rest.")
   (prompt :initarg :prompt :accessor summary-memory-prompt
           :initform +compaction-prompt+))
  (:documentation "When turn count or token budget is exceeded, compress the
   oldest span into one :system turn starting with +SUMMARY-PREFIX+.
   Previous summary turns are folded into the next compression."))

(defun summary-turn-p (turn)
  "True when TURN is a :system turn whose text starts with +SUMMARY-PREFIX+."
  (and (llm-protocol:llm-turn-p turn)
       (eq (llm-protocol:llm-turn-role turn) :system)
       (let* ((tx (or (llm-protocol:turn-text turn) ""))
              (n (length +summary-prefix+)))
         (and (>= (length tx) n)
              (string= +summary-prefix+ tx :end2 n)))))

(defun make-summary-memory (&key store (session "default")
                              (window-size 10) max-tokens backend
                              (reserve 0) model prompt (tail-tokens 15000))
  (check-type window-size (or null (integer 0 *)))
  (check-type tail-tokens (integer 0 *))
  (check-type max-tokens (or null (integer 0 *)))
  (check-type reserve (integer 0 *))
  (make-instance 'summary-memory
                 :store (%default-store store)
                 :session (coerce-session session)
                 :window-size window-size
                 :max-tokens max-tokens
                 :backend backend
                 :reserve reserve
                 :model model
                 :tail-tokens tail-tokens
                 :prompt (or prompt +compaction-prompt+)))

(defun use-summary-memory (&rest args &key &allow-other-keys)
  (setf *conversation-memory* (apply #'make-summary-memory args)))

(defun %summary-count-backend (memory &optional fallback)
  (or (summary-memory-backend memory)
      fallback
      llm-protocol:*llm-backend*
      (make-instance 'llm-protocol:llm-backend)))

(defun %summary-generate-backend (memory &optional fallback)
  (or (summary-memory-backend memory)
      fallback
      llm-protocol:*llm-backend*
      (restart-case
          (error 'conversation-missing-backend
                 :role :backend
                 :message "summary-memory needs an llm backend — pass :backend or bind *llm-backend*")
        (use-value (supplied)
          :report "Use a supplied llm backend"
          supplied))))

(defun %non-system-p (turn)
  (not (eq (llm-protocol:llm-turn-role turn) :system)))

(defun %real-system-p (turn)
  (and (eq (llm-protocol:llm-turn-role turn) :system)
       (not (summary-turn-p turn))))

(defun %non-system-count (turns)
  (count-if #'%non-system-p turns))

(defun %over-summary-limit-p (memory turns backend)
  (let ((window (summary-memory-window-size memory))
        (budget (summary-memory-max-tokens memory)))
    (or (and window (> (%non-system-count turns) window))
        (and budget
             (> (%count-tokens backend turns)
                (max 0 (- budget (or (summary-memory-reserve memory) 0))))))))

(defun %tool-safe-start (turns index)
  "INDEX moved back past :tool turns, so a kept tail never opens with a tool
result whose call was summarized away."
  (loop while (and (plusp index)
                   (eq :tool (llm-protocol:llm-turn-role (nth index turns))))
        do (decf index))
  index)

(defun %window-keep (memory turns)
  "Real :system turns plus the last WINDOW-SIZE non-system turns, original order.
   Existing summary turns are excluded so they are re-compressed."
  (let* ((window (or (summary-memory-window-size memory)
                     most-positive-fixnum))
         (non-sys (remove-if-not #'%non-system-p turns)))
    (if (<= (length non-sys) window)
        (remove-if #'summary-turn-p turns)
        (let ((keep-ns (nthcdr (%tool-safe-start non-sys (- (length non-sys) window))
                               non-sys)))
          (loop for tr in turns
                when (or (%real-system-p tr)
                         (member tr keep-ns :test #'eq))
                  collect tr)))))

(defun %drop-oldest-non-system (turns)
  (let ((dropped nil))
    (loop for turn in turns
          if (and (not dropped) (%non-system-p turn))
            do (setf dropped t)
          else
            collect turn)))

(defun %trim-keep-to-tokens (memory keep backend)
  "Drop oldest non-system turns from KEEP until the token budget fits.
   → (values extra-overflow trimmed-keep)"
  (let* ((budget (summary-memory-max-tokens memory))
         (reserve (or (summary-memory-reserve memory) 0))
         (limit (and budget (max 0 (- budget reserve)))))
    (if (null limit)
        (values nil keep)
        (let ((extra '())
              (cur (copy-list keep)))
          (loop while (and (> (%count-tokens backend cur) limit)
                           (find-if #'%non-system-p cur))
                do (let ((next (%drop-oldest-non-system cur))
                         (gone (find-if #'%non-system-p cur)))
                     (when gone
                       (push gone extra))
                     (setf cur next)))
          (values (nreverse extra) cur)))))

(defun %split-summary-span (memory turns backend)
  (let* ((keep (%window-keep memory turns))
         (overflow (remove-if (lambda (tr) (member tr keep :test #'eq)) turns)))
    (multiple-value-bind (extra trimmed)
        (%trim-keep-to-tokens memory keep backend)
      (values (append overflow extra) trimmed))))

(defun %make-summary-turn (memory overflow &optional fallback)
  (let* ((backend (%summary-generate-backend memory fallback))
         (prompt (list (llm-protocol:system-turn (summary-memory-prompt memory))
                       (llm-protocol:user-turn (render-transcript overflow))))
         (response (llm-protocol:generate backend prompt
                                          :model (summary-memory-model memory)))
         (text (string-trim '(#\Space #\Newline #\Return #\Tab)
                            (or (llm-protocol:llm-response-text response) ""))))
    (when (zerop (length text))
      (setf text "(empty)"))
    (llm-protocol:system-turn
     (if (and (>= (length text) (length +summary-prefix+))
              (string= +summary-prefix+ text :end2 (length +summary-prefix+)))
         text
         (format nil "~a ~a" +summary-prefix+ text)))))

(defmethod apply-memory-policy ((memory summary-memory) turns)
  (let* ((turns (llm-protocol:coerce-turns turns))
         (backend (%summary-count-backend memory)))
    (if (not (%over-summary-limit-p memory turns backend))
        turns
        (multiple-value-bind (overflow keep)
            (%split-summary-span memory turns backend)
          (if (null overflow)
              turns
              (cons (%make-summary-turn memory overflow) keep))))))

(defmethod compact-turns ((memory summary-memory) turns &key backend)
  "Summarize all but the newest SUMMARY-MEMORY-TAIL-TOKENS of TURNS (real
:system turns stay). Earlier summaries fold into the new one."
  (let* ((turns (llm-protocol:coerce-turns turns))
         (counter (%summary-count-backend memory backend))
         (system (remove-if-not #'%real-system-p turns))
         (rest (remove-if #'%real-system-p turns))
         (budget (summary-memory-tail-tokens memory))
         (start (length rest))
         (used 0))
    ;; Newest first: take turns while they fit; always keep the last one.
    (loop for i from (1- (length rest)) downto 0
          for cost = (%count-tokens counter (list (nth i rest)))
          while (or (= i (1- (length rest)))
                    (<= (+ used cost) budget))
          do (incf used cost)
             (setf start i))
    (let* ((start (%tool-safe-start rest start))
           (head (subseq rest 0 start))
           (tail (nthcdr start rest)))
      (if (notany #'%non-system-p head)
          (values turns nil)
          (values (append system
                          (list (%make-summary-turn memory head backend))
                          tail)
                  t)))))
