(in-package :transducers)

(define-constant empty-node (cons nil (make-array 32)))

(defclass persistent-vector (sb-mop:funcallable-standard-object sequence)
  ((count :type fixnum :initform 0 :initarg :count :accessor :count)
   (shift :type fixnum :initform 5 :initarg :shift :accessor :shift)
   (root :type cons :initform empty-node :initarg :root :accessor :root)
   (tail :type simple-vector
         :initform (make-array 32) :initarg :tail :accessor :tail))
  (:metaclass sb-mop:funcallable-standard-class))

(defmethod initialize-instance :after ((this persistent-vector) &rest initargs)
  (declare (optimize speed (safety 0) (debug 0)) (ignore initargs))
  (sb-mop:set-funcallable-instance-function
   this (lambda (index)
          (declare (fixnum index) (optimize speed (safety 0) (debug 0)))
          (aref (the simple-vector (array-for this index))
                (bit-and index #x01f)))))

(defvar empty-vector (make-instance 'persistent-vector))

(declaim (inline tailoff))
(defun tailoff (vec)
  (declare ((or persistent-vector transient-vector) vec))
  (let ((cnt (:count vec)))
    (declare (fixnum cnt))
    (the fixnum (if (< cnt 32)
                    0
                    (bit-shift-left (bit-shift-right (dec cnt) 5) 5)))))

(defun array-for (vec i)
  (declare ((or persistent-vector transient-vector) vec) (fixnum i))
  (assert (and (>= i 0) (< i (:count vec))) () "Index out of bounds")
  (if (>= i (tailoff vec))
      (:tail vec)
      (let ((node (:root vec)))
        (loop
          for level from (:shift vec) above 0 by 5
          do (->> (bit-and (bit-shift-right i level) #x01f)
                  (aref (cdr node))
                  (setf node)))
        (cdr node))))

(defmethod sequence:length ((o persistent-vector))
  (declare (optimize speed (debug 0) (safety 0))
           (persistent-vector o))
  (:count o))

(defmethod sequence:elt ((o persistent-vector) index)
  (declare (optimize speed (debug 0) (safety 0))
           (persistent-vector o)
           (fixnum index))
  (aref (the simple-vector (array-for o index)) (bit-and index #x01f)))

(defmethod (setf sequence:elt) (new-value (o persistent-vector) index)
  (declare (optimize speed (debug 0) (safety 0))
           (persistent-vector o)
           (fixnum index))
  (error "Cannot mutate persistent data structures"))

(defmethod sequence:adjust-sequence ((o persistent-vector) length
                                     &key initial-element initial-contents)
  (declare (optimize speed (debug 0) (safety 0))
           (persistent-vector o)
           (fixnum length))
  (cond (initial-contents (into [] initial-contents))
        (initial-element (into [] (repeat initial-element length)))
        (t (into [] o (take length)))))

(defmethod sequence:make-sequence-like ((o persistent-vector) length
                                        &key initial-element initial-contents)
  (declare (optimize speed (debug 0) (safety 0))
           (persistent-vector o)
           (fixnum length))
  (declare (ignore o length initial-element initial-contents)))

(defmethod sequence:make-sequence-iterator ((o persistent-vector)
                                            &key from-end (start 0)
                                              (end (:count o)))
  (declare (optimize speed (debug 0) (safety 0))
           (persistent-vector o)
           (fixnum start end))
  (make-fast-iterator o from-end start end))

(declaim (inline push-new-tail))
(defun make-tail (coll level parent tailnode)
  (let* ((subidx (bit-and (bit-shift-right (dec (:count coll)) level) #x01f))
         (ret (cons (car parent)
                    (make-array 32 :initial-contents (cdr parent))))
         (node-to-insert (if (= level 5)
                             tailnode
                             (let ((child (aref (cdr ret) subidx)))
                               (if child
                                   (make-tail coll (- level 5) child tailnode)
                                   (new-path (car (:root coll)) (- level 5)
                                             tailnode))))))
    (setf (aref (cdr ret) subidx) node-to-insert)
    ret))

(declaim (inline vec-conj))
(defun vec-conj (coll val)
  (declare (persistent-vector coll))
  (let* ((i (:count coll))
         (index (- i (tailoff coll))))
    (if (< index 32)
        (let ((newtail (make-array 32 :initial-contents (:tail coll))))
          (setf (aref newtail index) val)
          (make-instance 'persistent-vector
                         :count (inc i)
                         :shift (:shift coll)
                         :root (:root coll)
                         :tail newtail))
        (let* ((tailnode (cons (car (:root coll)) (:tail coll)))
               (newshift (:shift coll))
               (newroot (if (> (bit-shift-right i 5)
                               (bit-shift-left 1 newshift))
                            (let ((arr (make-array 32)))
                              (setf (aref arr 0) (:root coll))
                              (setf (aref arr 1) (new-path (car (:root coll))
                                                           newshift
                                                           tailnode))
                              (setf newshift (+ newshift 5))
                              (cons (car (:root coll)) arr))
                            (make-tail coll newshift (:root coll) tailnode))))
          (make-instance 'persistent-vector
                         :count (inc i)
                         :shift newshift
                         :root newroot
                         :tail (let ((newtail (make-array 32)))
                                 (setf (aref newtail 0) val)
                                 newtail))))))

(define-compiler-macro conj (coll val)
  `(typecase ,coll
     (persistent-vector (vec-conj ,coll ,val))
     (t (-conj ,coll ,val))))

(defun conj (coll val)
  (typecase coll
    (persistent-vector (vec-conj coll val))
    (t (-conj coll val))))

(defun pop-tail (coll level node)
  (declare (ignore coll level node)))

(defun pop (coll)
  (let ((cnt (:count coll)))
    (cond ((zerop cnt) (error "Can't pop empty vector"))
          
          ((= cnt 1) empty-vector)

          ((> (- cnt (tailoff coll)) 1)
           (make-instance 'persistent-vector
                          :count (dec cnt)
                          :shift (:shift coll)
                          :root (:root coll)
                          :tail (make-array 32 :initial-contents (:tail coll))))

          (t (let* ((newtail (array-for coll (- cnt 2)))
                    (newroot (pop-tail coll (:shift coll) (:root coll)))
                    (newshift (:shift coll)))
               (when (null newroot)
                 (setf newroot empty-node))
               (when (and (> (:shift coll) 5) (null (aref (cdr newroot) 1)))
                 (setf newroot (aref (cdr newroot) 0))
                 (setf newshift (- newshift 5)))
               (make-instance 'persistent-vector
                              :count (dec cnt)
                              :shift newshift
                              :root newroot
                              :tail newtail))))))

(defclass transient-vector (sb-mop:funcallable-standard-object sequence)
  ((count :type fixnum :initform 0 :initarg :count :accessor :count)
   (shift :type fixnum :initform 5 :initarg :shift :accessor :shift)
   (root :type cons :initform empty-node :initarg :root :accessor :root)
   (tail :type simple-vector
         :initform (make-array 32) :initarg :tail :accessor :tail))
  (:metaclass sb-mop:funcallable-standard-class))

(defmethod initialize-instance :after ((this transient-vector) &rest initargs)
  (declare (optimize speed (safety 0) (debug 0)) (ignore initargs))
  (sb-mop:set-funcallable-instance-function
   this (lambda (index)
          (declare (fixnum index) (optimize speed (safety 0) (debug 0)))
          (aref (the simple-vector (array-for this index))
                (bit-and index #x01f)))))

(defmethod sequence:length ((o transient-vector))
  (ensure-editable o)
  (:count o))

(defmethod sequence:elt ((o transient-vector) index)
  (declare (fixnum index))
  (ensure-editable o)
  (aref (array-for o index) (bit-and index #x01f)))

(defun ensure-editable (vec &optional (node nil nodep))
  (if nodep
      (if (eq (car node) (car (:root vec)))
          node
          (cons (car (:root vec)) (make-array 32 :initial-contents (cdr node))))
      (when (null (car (:root vec)))
        (error "Transient used after persistent! call"))))

(defun assoc-in! (level node i val)
  (if (zerop level)
      (progn
        (setf (aref (cdr node) (bit-and i #x01f)) val)
        node)
      (let ((subidx (bit-and (bit-shift-right i level) #x01f)))
        (assoc-in! (- level 5) (aref (cdr node) subidx) i val))))

(defun push-tail (vec level parent tailnode)
  (setf parent (ensure-editable vec parent))
  (let* ((subidx (-> (bit-shift-right (dec (:count vec)) level)
                     (bit-and #x01f)))
         (ret parent)
         (node-to-insert (if (= level 5)
                             tailnode
                             (if-let (child (aref (cdr parent) subidx))
                               (push-tail vec (- level 5) child tailnode)
                               (new-path (car (:root vec)) (- level 5)
                                         tailnode)))))
    (setf (aref (cdr ret) subidx) node-to-insert)
    ret))

(defun new-path (edit level node)
  (if (zerop level)
      node
      (let ((ret (cons edit (make-array 32))))
        (setf (aref (cdr ret) 0) (new-path edit (- level 5) node))
        ret)))

(declaim (inline vec-conj!))
(defun vec-conj! (tcoll val)
  (declare (transient-vector tcoll) (optimize speed (debug 0) (safety 0)))
  (ensure-editable tcoll)
  (let ((i (:count tcoll)))
    (declare (fixnum i))
    (if (< (- i (tailoff tcoll)) 32)
        (progn
          (setf (aref (the simple-vector (:tail tcoll)) (bit-and i #x01f)) val)
          (setf (:count tcoll) (the fixnum (inc i))))
        (let ((newroot nil)
              (tailnode (cons (car (:root tcoll))
                              (the simple-vector (:tail tcoll))))
              (tail (the simple-vector (setf (:tail tcoll) (make-array 32))))
              (newshift (:shift tcoll)))
          (declare (fixnum newshift))
          (setf (aref tail 0) val)
          (if (> (bit-shift-right i 5)
                 (the fixnum (bit-shift-left 1 newshift)))
              (progn
                (setf newroot (cons (car (:root tcoll)) (make-array 32)))
                (setf (aref (the simple-vector (cdr newroot)) 0) (:root tcoll))
                (setf (aref (the simple-vector (cdr newroot)) 1)
                      (new-path (car (:root tcoll))
                                (:shift tcoll)
                                tailnode))
                (setf newshift (+ newshift 5)))
              (setf newroot (push-tail tcoll (:shift tcoll) (:root tcoll)
                                       tailnode)))
          (setf (:root tcoll) newroot)
          (setf (:shift tcoll) newshift)
          (setf (:count tcoll) (the fixnum (inc i)))))
    (the transient-vector tcoll)))

(declaim (inline conj!))
(defun conj! (tcoll val)
  (typecase tcoll
    (transient-vector (vec-conj! tcoll val))
    (t (-conj! tcoll val))))

(defmethod (setf sequence:elt) (new-value (o transient-vector) index)
  (cond ((and (>= index 0) (< index (:count o)))
         (if (>= index (tailoff o))
             (progn
               (aref (:tail o) (bit-and index #x01f))
               o)
             (progn
               (setf (:root o) (assoc-in! (:shift o) (:root o) index new-value))
               o)))
        ((= index (:count o))
         (conj! o new-value))))

(defmethod sequence:adjust-sequence ((o transient-vector) length
                                     &key initial-element initial-contents)
  (declare (optimize speed (debug 0) (safety 0))
           (transient-vector o)
           (fixnum length))
  (let ((tcoll (transient empty-vector)))
    (cond (initial-contents (dolist (x initial-contents)
                              (vec-conj! tcoll x)))
          (initial-element (dotimes (i length)
                             (vec-conj! tcoll initial-element)))
          (t (dotimes (i length)
               (vec-conj! tcoll (elt o i)))))))

(defmethod sequence:make-sequence-like ((o transient-vector) length
                                        &key initial-element initial-contents)
  (declare (optimize speed (debug 0) (safety 0)))
  (sequence:adjust-sequence o length
                            :initial-element initial-element
                            :initial-contents initial-contents))

(defmethod sequence:emptyp ((o transient-vector))
  (declare (optimize speed (debug 0) (safety 0)))
  (zerop (the fixnum (:count o))))

(declaim (inline fast-step))
(defun fast-step (sequence iterator from-end)
  (declare (optimize speed (safety 0) (debug 0))
           (ignore sequence)
           (fixnum iterator))
  (the fixnum (if from-end (1- iterator) (1+ iterator))))

(declaim (inline fast-endp))
(defun fast-endp (sequence iterator limit from-end)
  (declare (optimize speed (safety 0) (debug 0))
           (ignore sequence from-end)
           (fixnum iterator limit))
  (= iterator limit))

(declaim (inline fast-elt))
(defun fast-elt (sequence iterator)
  (declare (optimize speed (safety 0) (debug 0))
           (fixnum iterator))
  (aref (the simple-vector (array-for sequence iterator))
        (bit-and iterator #x01f)))

(declaim (inline fast-index))
(defun fast-index (sequence iterator)
  (declare (optimize speed (safety 0) (debug 0))
           (ignore sequence)
           (fixnum iterator))
  iterator)

(declaim (inline make-fast-iterator))
(defun make-fast-iterator (o from-end start end)
  (declare (optimize speed (debug 0) (safety 0))
           (fixnum start end)
           (ignore o))
  (values (the fixnum (if from-end (dec end) start))
          (the fixnum (if from-end (dec start) end))
          from-end
          #'fast-step
          #'fast-endp
          #'fast-elt
          #'(setf sequence:elt)
          #'fast-index
          #'fast-index))

(defmethod sequence:make-sequence-iterator ((o transient-vector)
                                            &key from-end (start 0) end)
  (declare (optimize speed (debug 0) (safety 0)))
  (make-fast-iterator o from-end start (or end (:count o))))

(defun pop-tail! (tcoll level node)
  (declare (optimize speed (debug 0) (safety 0))
           (transient-vector tcoll)
           (cons node)
           ((unsigned-byte 62) level))
  (setf node (ensure-editable tcoll node))
  (let ((subidx (-> (- (the fixnum (:count tcoll)) 2)
                    (bit-shift-right level)
                    (bit-and #x01f))))
    (cond ((> level 5) (let ((newchild (->> (aref (the simple-vector (cdr node))
                                                  subidx)
                                            (pop-tail! tcoll (- level 5)))))
                         (if (and (null newchild) (zerop subidx))
                             nil
                             (progn
                               (setf (aref (the simple-vector (cdr node))
                                           subidx) newchild)
                               node))))
          ((= subidx 0) nil)
          (t (setf (aref (the simple-vector (cdr node)) subidx) nil)
             node))))

(defun editable-array-for (vec i)
  (declare (optimize speed (debug 0) (safety 0))
           (transient-vector vec)
           (fixnum i))
  (assert (and (>= i 0) (< i (the fixnum (:count vec)))) ()
          "Index out of bounds")
  (if (>= i (tailoff vec))
      (the simple-vector (:tail vec))
      (let ((node (:root vec))
            (shift (:shift vec)))
        (loop
          for level from (the fixnum shift) above 0 by 5
          do (->> #x01f
                  (bit-and (bit-shift-right i (the (unsigned-byte 62) level)))
                  (aref (the simple-vector (cdr node)))
                  (ensure-editable vec)
                  (setf node)))
        (the simple-vector (cdr node)))))

(defun pop! (tcoll)
  (declare (optimize speed (debug 0) (safety 0)))
  (ensure-editable tcoll)
  (let ((cnt (:count tcoll)))
    (declare (fixnum cnt))
    (cond ((zerop cnt) (error "Can't pop empty vector"))
          
          ((= cnt 1) (setf (:count tcoll) 0) tcoll)

          ((plusp (bit-and (dec cnt) #x01f))
           (setf (:count tcoll) (the fixnum (dec cnt))) tcoll)

          (t (let* ((newtail (editable-array-for tcoll (the fixnum (- cnt 2))))
                    (newroot (pop-tail! tcoll (:shift tcoll) (:root tcoll)))
                    (newshift (:shift tcoll)))
               (declare (fixnum newshift))
               (when (null newroot)
                 (setf newroot (cons (car (:root tcoll)) (make-array 32))))
               (when (and (> newshift 5)
                          (null (aref (the simple-vector (cdr newroot)) 1)))
                 (->> (aref (the simple-vector (cdr newroot)) 0)
                      (ensure-editable tcoll)
                      (setf newroot))                 
                 (setf newshift (- newshift 5)))
               (setf (:root tcoll) newroot)
               (setf (:shift tcoll) newshift)
               (setf (:count tcoll) (the fixnum (dec cnt)))
               (setf (:tail tcoll) newtail)
               tcoll)))))

(defun editable-root (node)
  (cons *current-thread* (make-array 32 :initial-contents (cdr node))))

(defun editable-tail (tail)
  (make-array 32 :initial-contents tail))

(declaim (inline transient))
(defun transient (coll)
  (declare (optimize speed (debug 0) (safety 0)))
  (typecase coll
    (persistent-vector (make-instance 'transient-vector
                                      :count (:count coll)
                                      :shift (:shift coll)
                                      :root (editable-root (:root coll))
                                      :tail (editable-tail (:tail coll))))
    (t coll)))

(declaim (inline persistent!))
(defun persistent! (tcoll)
  (declare (optimize speed (debug 0) (safety 0)))
  (typecase tcoll
    (transient-vector (progn
                        (ensure-editable tcoll)
                        (cas (car (:root tcoll)) (car (:root tcoll)) nil)
                        (make-instance 'persistent-vector
                                       :count (:count tcoll)
                                       :shift (:shift tcoll)
                                       :root (:root tcoll)
                                       :tail (:tail tcoll))))
    (t tcoll)))

(defun print-vector (vec stream)
  (princ "[" stream)
  (dotimes (i (dec (length vec)))
    (prin1 (elt vec i) stream)
    (princ #\space stream))
  (when (plusp (length vec))
    (prin1 (elt vec (dec (length vec))) stream))
  (princ "]" stream))

(defmethod print-object ((object persistent-vector) stream)
  (let ((*print-readably* t))
    (print-vector object stream)))

(define-compiler-macro vector (&rest objects)
  (->> (transient empty-vector)
       (reduce #'conj! objects :initial-value)
       (persistent!)
       (make-load-form)))

(defun vector (&rest objects)
  (declare (optimize speed (debug 0) (safety 0)))
  (->> (transient empty-vector)
       (reduce #'conj! objects :initial-value)
       (persistent!)))

(eval-when (:compile-toplevel)
  (set-macro-character #\] (get-macro-character #\)))
  (defun read-vector (stream ch)
    (declare (ignore ch))
    (let* ((list (read-delimited-list #\] stream t)))
      (if (emptyp list)
          `empty-vector
          (apply #'vector list))))
  (defmethod make-load-form ((object persistent-vector) &optional env)
    (declare (ignore env) (optimize speed (debug 0) (safety 0)))
    `(make-instance 'persistent-vector
                    :count ,(:count object)
                    :shift ,(:shift object)
                    :root (cons ,(car (:root object)) ,(cdr (:root object)))
                    :tail ,(:tail object)))
  (set-macro-character #\[ #'read-vector))
