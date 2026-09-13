(in-package #:conversation-protocol)

;;; Compress oldest overflow via llm-protocol:generate.
;;; Loaded only with conversation-protocol/summary so core stays free of generate.

(defparameter +summary-prefix+ "[summary]"
  "Prefix of a :system summary turn. Documented choice: summaries are :system
   turns starting with this prefix, not a dedicated user/system role.")

(defclass summary-memory (conversation-memory)
  ((window-size :initarg :window-size :accessor summary-memory-window-size
                :initform 10)
   (max-tokens :initarg :max-tokens :accessor summary-memory-max-tokens
               :initform nil)
   (backend :initarg :backend :accessor summary-memory-backend :initform nil)
   (reserve :initarg :reserve :accessor summary-memory-reserve :initform 0)
   (model :initarg :model :accessor summary-memory-model :initform nil)
   (prompt :initarg :prompt :accessor summary-memory-prompt
           :initform "Summarize the following conversation turns concisely. Reply with the summary only."))
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
                              (reserve 0) model prompt)
  (check-type window-size (or null (integer 0 *)))
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
                 :prompt (or prompt
                             "Summarize the following conversation turns concisely. Reply with the summary only.")))

(defun use-summary-memory (&rest args &key &allow-other-keys)
  (setf *conversation-memory* (apply #'make-summary-memory args)))

(defun %summary-count-backend (memory)
  (or (summary-memory-backend memory)
      llm-protocol:*llm-backend*
      (make-instance 'llm-protocol:llm-backend)))

(defun %summary-generate-backend (memory)
  (or (summary-memory-backend memory)
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

(defun %window-keep (memory turns)
  "Real :system turns plus the last WINDOW-SIZE non-system turns, original order.
   Existing summary turns are excluded so they are re-compressed."
  (let* ((window (or (summary-memory-window-size memory)
                     most-positive-fixnum))
         (non-sys (remove-if-not #'%non-system-p turns)))
    (if (<= (length non-sys) window)
        (remove-if #'summary-turn-p turns)
        (let ((keep-ns (nthcdr (- (length non-sys) window) non-sys)))
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

(defun %make-summary-turn (memory overflow)
  (let* ((backend (%summary-generate-backend memory))
         (prompt (append (list (llm-protocol:system-turn
                                (summary-memory-prompt memory)))
                         overflow))
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
