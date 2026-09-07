(in-package #:conversation-protocol)

;;; In-tree store + buffer / window. SQL persist and LLM summary-memory are later backends.

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
