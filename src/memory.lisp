(in-package #:conversation-protocol)

;;; In-tree store + buffer / window / token-window.
;;; LLM summary-memory lives in conversation-protocol/summary (uses generate).
;;; SQL persist is conversation-backend-sql.

(defclass in-memory-conversation-store (conversation-store)
  ((sessions :initform (make-hash-table :test 'equal)
             :accessor in-memory-store-sessions)))

(defun make-in-memory-conversation-store ()
  (make-instance 'in-memory-conversation-store))

(defmethod load-session ((store in-memory-conversation-store) session)
  (copy-list (gethash (coerce-session session) (in-memory-store-sessions store))))

(defmethod save-session ((store in-memory-conversation-store) session turns)
  (setf (gethash (coerce-session session) (in-memory-store-sessions store))
        (copy-list (llm-protocol:coerce-turns turns)))
  store)

(defmethod delete-session ((store in-memory-conversation-store) session)
  (let* ((sid (coerce-session session))
         (table (in-memory-store-sessions store)))
    (if (nth-value 1 (gethash sid table))
        (remhash sid table)
        (restart-case
            (error 'conversation-session-not-found
                   :session sid
                   :message (format nil "unknown session ~s" sid))
          (continue ()
            :report "Skip missing session"
            nil)
          (use-value (value)
            :report "Return a supplied value"
            (return-from delete-session value))))
    store))

(defmethod initialize-instance :after ((memory conversation-memory) &key)
  (unless (memory-store memory)
    (setf (memory-store memory) (make-in-memory-conversation-store)))
  (setf (memory-session memory) (coerce-session (memory-session memory))))

(defclass buffer-memory (conversation-memory) ())

(defclass window-memory (conversation-memory)
  ((window-size :initarg :window-size :accessor window-memory-size :initform 10)))

(defun %default-store (store)
  (or store (make-in-memory-conversation-store)))

(defun make-buffer-memory (&key store (session "default"))
  (make-instance 'buffer-memory
                 :store (%default-store store)
                 :session (coerce-session session)))

(defun make-window-memory (&key store (session "default") (window-size 10))
  (check-type window-size (integer 0 *))
  (make-instance 'window-memory
                 :store (%default-store store)
                 :session (coerce-session session)
                 :window-size window-size))

(defmethod apply-memory-policy ((memory window-memory) turns)
  (window-turns turns (window-memory-size memory)))

(defun use-buffer-memory (&rest args &key &allow-other-keys)
  (setf *conversation-memory* (apply #'make-buffer-memory args)))

(defun use-window-memory (&rest args &key &allow-other-keys)
  (setf *conversation-memory* (apply #'make-window-memory args)))

(defclass token-window-memory (conversation-memory)
  ((max-tokens :initarg :max-tokens :accessor token-window-memory-max-tokens
               :initform nil)
   (backend :initarg :backend :accessor token-window-memory-backend :initform nil)
   (reserve :initarg :reserve :accessor token-window-memory-reserve :initform 0)
   (model :initarg :model :accessor token-window-memory-model :initform nil))
  (:documentation "Window by COUNT-TOKENS / FIT-TURNS, not turn count.
   MAX-TOKENS is the FIT-TURNS budget. BACKEND is optional (heuristic
   COUNT-TOKENS ignores it). System turns are kept."))

(defun %token-count-backend (memory)
  "BACKEND for COUNT-TOKENS / FIT-TURNS. NIL → *LLM-BACKEND* or a dummy
   LLM-BACKEND so the null method does not demand a live generator."
  (or (token-window-memory-backend memory)
      llm-protocol:*llm-backend*
      (make-instance 'llm-protocol:llm-backend)))

(defun make-token-window-memory (&key store (session "default")
                                    max-tokens backend (reserve 0) model)
  (check-type max-tokens (or null (integer 0 *)))
  (check-type reserve (integer 0 *))
  (make-instance 'token-window-memory
                 :store (%default-store store)
                 :session (coerce-session session)
                 :max-tokens max-tokens
                 :backend backend
                 :reserve reserve
                 :model model))

(defun %llm-fn (name)
  (let ((s (find-symbol name :llm-protocol)))
    (and s (fboundp s) s)))

(defun %heuristic-token-count (thing)
  "CEILING of character length / 4 — same default as llm-protocol 0.3 COUNT-TOKENS."
  (cond
    ((null thing) 0)
    ((stringp thing) (ceiling (length thing) 4))
    ((llm-protocol:llm-turn-p thing)
     (%heuristic-token-count (llm-protocol:turn-text thing)))
    ((or (listp thing) (vectorp thing))
     (loop for x in (if (vectorp thing) (coerce thing 'list) thing)
           sum (%heuristic-token-count x)))
    (t (%heuristic-token-count (princ-to-string thing)))))

(defun %count-tokens (backend thing)
  "Prefer llm-protocol:COUNT-TOKENS (0.3+). Else the /4 heuristic so 0.2.1 OCI works."
  (let ((fn (%llm-fn "COUNT-TOKENS")))
    (if fn
        (funcall fn backend thing)
        (%heuristic-token-count thing))))

(defun %fit-turns (turns backend &key max-tokens reserve)
  "Prefer llm-protocol:FIT-TURNS. Else keep :system + drop oldest non-system."
  (let ((fit (%llm-fn "FIT-TURNS"))
        (make-policy (%llm-fn "MAKE-TOKEN-FIT-POLICY")))
    (if (and fit make-policy)
        (funcall fit turns backend
                 :policy (funcall make-policy :max-tokens max-tokens
                                  :reserve (or reserve 0)))
        (let* ((turns (llm-protocol:coerce-turns turns))
               (budget (and max-tokens (max 0 (- max-tokens (or reserve 0))))))
          (if (null budget)
              turns
              (let ((kept (copy-list turns)))
                (loop while (and (> (%count-tokens backend kept) budget)
                                 (find-if (lambda (tr)
                                            (not (eq (llm-protocol:llm-turn-role tr)
                                                     :system)))
                                          kept))
                      do (let ((gone nil))
                           (setf kept
                                 (loop for tr in kept
                                       if (and (null gone)
                                               (not (eq (llm-protocol:llm-turn-role tr)
                                                        :system)))
                                         do (setf gone t)
                                       else collect tr))))
                kept))))))

(defmethod apply-memory-policy ((memory token-window-memory) turns)
  (%fit-turns turns (%token-count-backend memory)
              :max-tokens (token-window-memory-max-tokens memory)
              :reserve (token-window-memory-reserve memory)))

(defun use-token-window-memory (&rest args &key &allow-other-keys)
  (setf *conversation-memory* (apply #'make-token-window-memory args)))
