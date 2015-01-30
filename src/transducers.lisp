(in-package :transducers)

(defgeneric coll-reduce (coll f val)
  (declare (optimize speed (space 0))))

(defmethod coll-reduce ((coll null) f val)
  (declare (function f) (optimize speed (safety 0) (debug 0) (space 0)))
  (or val (funcall f)))

(defmethod coll-reduce ((coll sequence) f val)
  (declare (function f) (optimize speed (safety 0) (debug 0) (space 0)))
  (if val
      (cl:reduce f coll :initial-value val)
      (cl:reduce f coll)))

(defun seq-reduce (coll f val)
  (cond (coll (seq-reduce (next coll) f (funcall f val (first coll))))
        (val val)
        (t (funcall f))))

(defmethod coll-reduce (coll f val)
  (declare (function f) (optimize speed (safety 0) (debug 0) (space 0)))
  (when-let (s (seq coll))    
    (seq-reduce s f (if val (funcall f val) (funcall f)))))

(define-compiler-macro reduce (f coll &optional val)
  `(coll-reduce ,coll ,f ,val))

(defun reduce (f coll &optional val)
  (declare (function f) (optimize speed (safety 0) (debug 0) (space 0)))
  (coll-reduce coll f val))

(defun interleave (&optional c1 c2 &rest more)
  (cond (more (let ((ss (map #'seq (list* c1 c2 more))))
                (concat (map #'first ss)
                        (apply #'interleave (map #'next ss)))))
        (c2 (when-let ((s1 (seq c1))
                       (s2 (seq c2)))
              (cons (first s1)
                    (cons (first s2) (interleave (rest s1) (rest s2))))))
        (c1 c1)
        (t nil)))

(defun map (f &optional (coll nil has-collp) &rest more)
  (declare (function f))
  (cond (more (map f (apply #'interleave coll more)))
        (has-collp (when-let (x (first coll))
                     (cons (funcall f x) (map f (rest coll)))))
        (f (lambda (rf)
             (declare (function rf))
             (lambda (&optional (x nil xp) (y nil yp) &rest inputs)
               (declare (optimize speed (debug 0) (safety 0)))
               (cond (inputs (funcall rf x (apply f y inputs)))
                     (yp (funcall rf x (funcall f y)))
                     (xp (funcall rf x))
                     (t (funcall rf))))))
        (t nil)))

(defun comp (&optional f g &rest more)
  (declare ((or function null) f g))
  (cond (more (reduce #'comp more (comp f g)))
        (g (lambda (&rest args)
             (funcall f (apply g args))))
        (f f)
        (t #'identity)))

(define-compiler-macro inc (n)
  `(1+ ,n))

(defun inc (n)
  (1+ n))

(define-compiler-macro dec (n)
  `(1- ,n))

(defun dec (n)
  (1- n))

(defun range (start &optional end step)
  (declare (type (or fixnum null) start end step))
  (cond (step (when (not (= start end))
                (loop
                  for i from start below end by step
                  collect i)))
        (end (range start end 1))
        (start (range 0 start 1))
        (t (range 0 most-positive-fixnum 1))))

(defun take (n &optional coll)
  (declare (fixnum n))
  (when (and (plusp n) coll)
    (cons (first coll) (take (dec n) (rest coll)))))

(defun take-while (pred &optional coll)
  (declare (function pred))
  (when-let (x (and (funcall pred (first coll)) (first coll)))
    (cons x (take-while pred (rest coll)))))

(defun drop (n &optional coll)
  (declare (fixnum n))
  (if (plusp n)
      (when (seq coll)
        (drop (dec n) (rest coll)))
      coll))

(defun drop-while (pred &optional coll)
  (declare (function pred))
  (when-let (x (and (funcall pred (first coll)) (first coll)))
    (cons x (take-while pred (rest coll)))))

(defun repeat (x n)
  (declare (fixnum n))
  (loop
    for i from 1 to n
    collect x))

(defun completing (f &optional (cf #'identity))
  (declare (function f cf))
  (lambda (&optional (x nil xp) (y nil yp))
    (declare (optimize speed (debug 0) (safety 0)))
    (cond (yp (funcall f x y))
          (xp (funcall cf x))
          (t (funcall f)))))

(defun concat (&optional x y &rest more)
  (cond (more (apply #'concat (concat x y) more))
        (y (if (seq x)
               (cons (first x) (concat (rest x) y))
               y))
        (x x)
        (t nil)))

(defun cat (rf)
  (declare (function rf))
  (lambda (&optional (x nil xp) (y nil yp))
    (declare (optimize speed (debug 0) (safety 0)))
    (cond (yp (funcall rf x y))
          (xp (funcall rf x))
          (t (funcall rf)))))

(defun mapcat (f &rest colls)
  (if colls
      (apply #'concat (apply #'map f colls))
      (comp (map f) #'cat)))

(defmacro loop* (bindings &body body)
  (with-gensyms (f)
    `(labels ((,f ,(map #'first bindings) (progn ,@(subst f 'recur body))))
       (,f ,@(map #'second bindings)))))

(defun nthnext (coll n)
  (loop* ((n n)
          (xs (seq coll)))
    (if (and xs (plusp n))
        (recur (dec n) (next xs))
        xs)))

(defun nthrest (coll n)
  (loop* ((n n)
          (xs coll))
    (if (and (plusp n) (seq xs))
        (recur (dec n) (rest xs))
        xs)))

(defmacro reducing (rf &body body)
  (destructuring-bind ((&rest b0) (a1 &rest b1) (a2 &rest b2)) body
    (with-gensyms (result input resultp inputp)
      `(flet (,(when (typep rf '(or symbol list))
                     `(,rf (&rest args) (apply ,rf args))))
         (lambda (&optional (,result nil ,resultp) (,input nil ,inputp))
           (cond (,inputp (let ((,(car a2) ,result)
                                (,(cadr a2) ,input))
                            ,@b2))
                 (,resultp (let ((,(car a1) ,result))
                             ,@b1))
                 (t ,@b0)))))))

(defmacro reducer (&body body)
  `(reducing nil ,@body))

(defun partition-all (n)
  (lambda (rf)
    (let ((vec (make-array 0 :adjustable t)))
      (reducing rf
        (() (rf))
        ((result)
         (if (emptyp vec)
             (rf result)
             (rf (rf result vec))))
        ((result input)
         (push vec input)
         (if (= n (length vec))
             (rf result vec)
             result))))))

(defun filter (pred &optional coll)
  (declare (ignore coll))
  (lambda (rf)
    (reducing rf
      (() (rf))
      ((result) (rf result))
      ((result input)
       (if (funcall pred input)
           (rf result input)
           result)))))

(defun transduce (xf f coll &optional (init (funcall f)))
  (let* ((f (funcall xf f))
         (ret (coll-reduce coll f init)))
    (funcall f ret)))

