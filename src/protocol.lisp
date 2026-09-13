(in-package #:conversation-protocol)

;;; CLOS conversation memory. Turns stay llm-turn. Not RAG. Not llm-protocol GFs.

(defclass conversation-store () ())

(defclass conversation-memory ()
  ((store :initarg :store :accessor memory-store :initform nil)
   (session :initarg :session :accessor memory-session :initform "default")))

(defvar *conversation-store* nil)
(defvar *conversation-memory* nil)

(defun coerce-session (session)
  "Normalize SESSION to a string key. NIL → \"default\"."
  (cond
    ((null session) "default")
    ((stringp session) session)
    ((symbolp session) (string session))
    (t (princ-to-string session))))

(defun %ensure (value role message)
  (or value
      (restart-case
          (error 'conversation-missing-backend :role role :message message)
        (use-value (supplied)
          :report (lambda (s) (format s "Use a supplied ~a" role))
          :interactive (lambda ()
                         (format *query-io* "~a: " role)
                         (force-output *query-io*)
                         (list (read *query-io*)))
          supplied))))

(defun %ensure-store (&optional (store *conversation-store*))
  (%ensure store :store
           "*conversation-store* is nil — call MAKE-IN-MEMORY-CONVERSATION-STORE"))

(defun %ensure-memory (&optional (memory *conversation-memory*))
  (%ensure memory :memory
           "*conversation-memory* is nil — call MAKE-BUFFER-MEMORY, MAKE-WINDOW-MEMORY, MAKE-TOKEN-WINDOW-MEMORY, or MAKE-SUMMARY-MEMORY"))

(defun window-turns (turns window-size)
  "Keep every :system turn plus the last WINDOW-SIZE non-system turns, original order.
   Window is turn count, not tokens."
  (check-type window-size (integer 0 *))
  (let ((non-sys (remove-if (lambda (tr)
                              (eq (llm-protocol:llm-turn-role tr) :system))
                            turns)))
    (if (<= (length non-sys) window-size)
        (copy-list turns)
        (let ((keep (nthcdr (- (length non-sys) window-size) non-sys)))
          (loop for tr in turns
                when (or (eq (llm-protocol:llm-turn-role tr) :system)
                         (member tr keep :test #'eq))
                  collect tr)))))

(defgeneric load-session (store session)
  (:documentation "Return stored llm-turn list for SESSION. Missing → empty list."))

(defgeneric save-session (store session turns)
  (:documentation "Replace stored turns for SESSION. TURNS are coerced via llm:coerce-turns."))

(defgeneric delete-session (store session)
  (:documentation "Drop SESSION. Missing signals CONVERSATION-SESSION-NOT-FOUND (CONTINUE skips)."))

(defgeneric recall (memory incoming &key session)
  (:documentation "Turns to send to generate: applied history + INCOMING.
   Does not persist INCOMING."))

(defgeneric remember (memory turns &key session replace)
  (:documentation "Persist TURNS for SESSION. Default appends. :REPLACE T snapshots.
   TURNS should be the delta (incoming + new assistant/tool) unless :REPLACE T."))

(defgeneric clear-memory (memory &key session)
  (:documentation "Drop SESSION (default MEMORY-SESSION). Missing session is ignored."))

(defgeneric apply-memory-policy (memory turns)
  (:documentation "Trim or otherwise rewrite TURNS before save. Buffer = identity."))

(defmethod load-session ((store conversation-store) session)
  (declare (ignore session))
  (error 'conversation-missing-backend
         :role :store
         :message (format nil "~a does not implement load-session" (class-of store))))

(defmethod load-session ((store null) session)
  (load-session (%ensure-store) session))

(defmethod save-session ((store conversation-store) session turns)
  (declare (ignore session turns))
  (error 'conversation-missing-backend
         :role :store
         :message (format nil "~a does not implement save-session" (class-of store))))

(defmethod save-session ((store null) session turns)
  (save-session (%ensure-store) session turns))

(defmethod delete-session ((store conversation-store) session)
  (declare (ignore session))
  (error 'conversation-missing-backend
         :role :store
         :message (format nil "~a does not implement delete-session" (class-of store))))

(defmethod delete-session ((store null) session)
  (delete-session (%ensure-store) session))

(defmethod recall ((memory conversation-memory) incoming &key session)
  (let* ((store (%ensure-store (memory-store memory)))
         (sid (coerce-session (or session (memory-session memory)))))
    (append (load-session store sid)
            (llm-protocol:coerce-turns incoming))))

(defmethod recall ((memory null) incoming &key session)
  (recall (%ensure-memory) incoming :session session))

(defmethod apply-memory-policy ((memory conversation-memory) turns)
  (declare (ignore memory))
  turns)

(defmethod remember ((memory conversation-memory) turns &key session replace)
  (let* ((store (%ensure-store (memory-store memory)))
         (sid (coerce-session (or session (memory-session memory))))
         (new (llm-protocol:coerce-turns turns))
         (all (if replace new (append (load-session store sid) new))))
    (save-session store sid (apply-memory-policy memory all))
    memory))

(defmethod remember ((memory null) turns &key session replace)
  (remember (%ensure-memory) turns :session session :replace replace))

(defmethod clear-memory ((memory conversation-memory) &key session)
  (let ((store (%ensure-store (memory-store memory)))
        (sid (coerce-session (or session (memory-session memory)))))
    (restart-case
        (handler-bind ((conversation-session-not-found
                        (lambda (c)
                          (let ((r (find-restart 'continue c)))
                            (when r (invoke-restart r))))))
          (delete-session store sid))
      (continue ()
        :report "Ignore missing session"
        nil))
    memory))

(defmethod clear-memory ((memory null) &key session)
  (clear-memory (%ensure-memory) :session session))
