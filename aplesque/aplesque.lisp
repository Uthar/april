;;;; aplesque.lisp

(in-package #:aplesque)

(defun is-singleton (value)
  (let ((adims (dims value)))
    (and (= 1 (first adims))
	 (= 1 (length adims)))))

(defun scale-array (singleton to-match)
  "Scale up a 1-element array to fill the dimensions of the given array."
  (make-array (dims to-match)
	      :initial-element (aref singleton 0)))

(defun array-promote (array)
  "Promote an array to the next rank. The existing content will occupy 1 unit of the new dimension."
  (make-array (cons 1 (dims array))
	      :initial-contents (list (array-to-list array))))

(defun array-to-list (array)
  "Convert array to list."
  (let* ((dimensions (dims array))
         (depth (1- (length dimensions)))
         (indices (make-list (1+ depth) :initial-element 0)))
    (labels ((recurse (n)
               (loop for j below (nth n dimensions)
		  do (setf (nth n indices) j)
		  collect (if (= n depth)
			      (apply #'aref array indices)
			      (recurse (1+ n))))))
      (recurse 0))))

(defun array-match (alpha omega)
  (let ((singleton-alpha (is-singleton alpha))
	(singleton-omega (is-singleton omega)))
    (if (or singleton-alpha singleton-omega
	    (loop for dimension in (funcall (lambda (a o) (mapcar #'= a o))
					    (dims alpha)
					    (dims omega))
	       always dimension))
	(if singleton-alpha
	    (if singleton-omega
		(list alpha omega)
		(list (scale-array alpha omega)
		      omega))
	    (if singleton-omega
		(list alpha (scale-array omega alpha))
		(list alpha omega))))))

(defun array-depth (array &optional layer)
  "Find the maximum depth of nested arrays within an array."
  (let ((layer (if layer layer 1)))
    (aops:each (lambda (item)
		 (if (arrayp item)
		     (setq layer (array-depth item (1+ layer)))))
	       array)
    layer))

(defun swap! (v i j)
  (let ((tt (aref v i)))
    (setf (aref v i)
	  (aref v j))
    (setf (aref v j) tt)))

(defun reverse! (v lo hi)
  (when (< lo hi)
    (swap! v lo hi)
    (reverse! v (+ lo 1) (- hi 1))))

(defun rotate! (n v)
  (let* ((len (length v))
	 (n (mod n len)))
    (reverse! v 0 (- n 1))
    (reverse! v n (- len 1))
    (reverse! v 0 (- len 1))))

(defun make-rotator (&optional degrees)
  "Create a function to rotate an array by a given number of degrees, or otherwise reverse it."
  (lambda (vector)
    (if degrees (rotate! degrees vector)
	(reverse! vector 0 (1- (length vector))))))

(defun rotate-left (n l)
  (append (nthcdr n l) (butlast l (- (length l) n))))

(defun rotate-right (n l)
  (rotate-left (- (length l) n) l))

(defun multidim-slice (array dimensions &key (inverse nil) (fill-with 0))
  "Take a slice of an array in multiple dimensions."
  (if (= 1 (length dimensions))
      (apply #'aops:stack
	     (append (list 0 (aops:partition array (if inverse (first dimensions)
						       0)
					     (if inverse
						 (first (dims array))
						 (if (< (first (dims array))
							(first dimensions))
						     (first (dims array))
						     (first dimensions)))))
		     (if (and (not inverse)
			      (< (first (dims array))
				 (first dimensions)))
			 (list (make-array (list (- (first dimensions)
						    (first (dims array))))
					   :initial-element fill-with)))))
      (aops:combine (apply #'aops:stack
			   (append (list 0 (aops:each (lambda (a)
							(multidim-slice a (rest dimensions)
									:inverse inverse
									:fill-with fill-with))
						      (subseq (aops:split array 1)
							      (if inverse (first dimensions)
								  0)
							      (if inverse
								  (first (dims array))
								  (if (< (first (dims array))
									 (first dimensions))
								      (first (dims array))
								      (first dimensions))))))
				   (if (and (not inverse)
					    (< (first (dims array))
					       (first dimensions)))
				       (list (make-array (list (- (first dimensions)
								  (first (dims array))))
							 :initial-contents
							 (loop for index from 1 to (- (first dimensions)
										      (first (dims array)))
							    collect (make-array (rest dimensions)
										:initial-element fill-with))))))))))

(defun scan-back (function input &optional output)
  (if (not input)
      output (if (not output)
		 (scan-back function (cddr input)
			    (funcall function (second input)
				     (first input)))
		 (scan-back function (rest input)
			    (funcall function (first input)
				     output)))))

(defun make-back-scanner (function)
  (lambda (sub-array)
    (let ((args (list (aref sub-array 0))))
      (loop for index from 1 to (1- (length sub-array))
	 do (setf args (cons (aref sub-array index)
			     args)
		  (aref sub-array index)
		  (scan-back function args)))
      sub-array)))

(defun apply-marginal (function array axis default-axis)
  (let* ((new-array (copy-array array))
	 (a-rank (rank array))
	 (axis (if axis axis default-axis)))
    (if (> axis (1- a-rank))
	(error "Invalid axis.")
	(progn (if (not (= axis (1- a-rank)))
		   (setq new-array (aops:permute (rotate-left (- a-rank 1 axis)
							      (alexandria:iota a-rank))
						 new-array)))
	       (aops:margin (lambda (sub-array) (funcall function sub-array))
			    new-array (1- a-rank))
	       (if (not (= axis (1- a-rank)))
		   (aops:permute (rotate-right (- a-rank 1 axis)
					       (alexandria:iota a-rank))
				 new-array)
		   new-array)))))

(defun expand-array (degrees array axis default-axis &key (compress-mode nil))
  (let* ((new-array (copy-array array))
	 (a-rank (rank array))
	 (axis (if axis axis default-axis))
	 (singleton-array (loop for dim in (dims array) always (= 1 dim)))
	 (char-array? (or (eql 'character (element-type array))
			  (eql 'base-char (element-type array)))))
    (if (and singleton-array (< 1 a-rank))
    	(setq array (make-array (list 1)
				:element-type (element-type array)
				:displaced-to array)))
    (if (> axis (1- a-rank))
	(error "Invalid axis.")
	(progn (if (not (= axis (1- a-rank)))
		   (setq new-array (aops:permute (rotate-left (- a-rank 1 axis)
							      (alexandria:iota a-rank))
						 new-array)))
	       (let ((array-segments (aops:split new-array 1))
		     (segment-index 0))
		 (let* ((expanded (loop for degree in degrees
				     append (cond ((< 0 degree)
						   (loop for items from 1 to degree
						      collect (aref array-segments segment-index)))
						  ((and (= 0 degree)
							(not compress-mode))
						   (list (if (arrayp (aref array-segments 0))
							     (make-array (dims (aref array-segments 0))
									 :element-type (element-type array)
									 :initial-element (if char-array? #\  0))
							     (if char-array? #\  0))))
						  ((> 0 degree)
						   (loop for items from -1 downto degree
						      collect (if (arrayp (aref array-segments 0))
								  (make-array (dims (aref array-segments 0))
									      :element-type (element-type array)
									      :initial-element
									      (if char-array? #\  0))
								  (if char-array? #\  0)))))
				     do (if (and (not singleton-array)
						 (or compress-mode (< 0 degree)))
					    (incf segment-index 1))))
			(output (funcall (if (< 1 (rank array))
					     #'aops:combine (lambda (x) x))
					 ;; combine the resulting arrays if the original is multidimensional,
					 ;; otherwise just make a vector
					 (make-array (length expanded)
						     :element-type (element-type array)
						     :initial-contents expanded))))
		   (if (not (= axis (1- a-rank)))
		       (aops:permute (rotate-right (- a-rank 1 axis)
						   (alexandria:iota a-rank))
				     output)
		       output)))))))

(defun enlist (vector)
  (if (arrayp vector)
      (setq vector (aops:flatten vector)))
  (if (and (vectorp vector)
	   (loop for element from 0 to (1- (length vector))
	      always (not (arrayp (aref vector element)))))
      vector
      (let ((current-segment nil)
	    (segments nil))
	(dotimes (index (length vector))
	  (let ((element (aref vector index)))
	    (if (arrayp element)
		(if (not (= 0 (array-total-size element)))
		    ;; skip empty vectors
		    (setq segments (cons (enlist element)
					 (if current-segment
					     (cons (make-array (list (length current-segment))
							       :initial-contents (reverse current-segment))
						   segments)
					     segments))
			  current-segment nil))
		(setq current-segment (cons element current-segment)))))
	(if current-segment (setq segments (cons (make-array (list (length current-segment))
							     :initial-contents (reverse current-segment))
						 segments)))
	(apply #'aops:stack (cons 0 (reverse segments))))))

(defun reshape-array-fitting (array adims)
  (let* ((original-length (array-total-size array))
	 (total-length (apply #'* adims))
	 (displaced-array (make-array (list original-length)
				      :element-type (element-type array)
				      :displaced-to array)))
    (aops:reshape (make-array (list total-length)
			      :element-type (element-type array)
			      :initial-contents (loop for index from 0 to (1- total-length)
						   collect (aref displaced-array (mod index original-length))))
		  adims)))

(defun sprfact (n) ; recursive factorial-computing function based on P. Luschny's code
  (let ((p 1) (r 1) (NN 1) (log2n (floor (log n 2)))
	(h 0) (shift 0) (high 1) (len 0))
    (labels ((prod (n)
	       (declare (fixnum n))
	       (let ((m (ash n -1)))
		 (cond ((= m 0) (incf NN 2))
		       ((= n 2) (* (incf NN 2)
				   (incf NN 2)))
		       (t (* (prod (- n m))
			     (prod m)))))))
      (loop while (/= h n) do
	   (incf shift h)
	   (setf h (ash n (- log2n)))
	   (decf log2n)
	   (setf len high)
	   (setf high (if (oddp h)
			  h (1- h)))
	   (setf len (ash (- high len) -1))
	   (cond ((> len 0)
		  (setf p (* p (prod len)))
		  (setf r (* r p)))))
      (ash r shift))))

(defun binomial (k n)
  (labels ((prod-enum (s e)
	     (do ((i s (1+ i)) (r 1 (* i r))) ((> i e) r)))
	   (sprfact (n) (prod-enum 1 n)))
    (/ (prod-enum (- (1+ n) k) n) (sprfact k))))

(defun array-inner-product (operand1 operand2 function1 function2)
  (funcall (lambda (result)
	     ;; disclose the result if the right argument was a vector and there is
	     ;; a superfluous second dimension
	     (if (vectorp operand1)
		 (aref (aops:split result 1) 0)
		 (if (vectorp operand2)
		     (let ((nested-result (aops:split result 1)))
		       (make-array (list (length nested-result))
				   :initial-contents (loop for index from 0 to (1- (length nested-result))
							  collect (aref (aref nested-result index) 0))))
		     result)))
	   (aops:each (lambda (sub-vector)
			(if (vectorp sub-vector)
			    (reduce function2 sub-vector)
			    (funcall function2 sub-vector)))
		      (aops:outer function1
				  ;; enclose the argument if it is a vector
				  (if (vectorp operand1)
				      (vector operand1)
				      (aops:split (aops:permute (alexandria:iota (rank operand1))
								operand1)
						  1))
				  (if (vectorp operand2)
				      (vector operand2)
				      (aops:split (aops:permute (reverse (alexandria:iota (rank operand2)))
								operand2)
						  1))))))

(defun index-of (set to-search)
  (if (not (vectorp set))
      (error "Rank error.")
      (let* ((to-find (remove-duplicates set :from-end t))
	     (maximum (+ 1 (length set)))
	     (results (if (stringp to-search)
			  (make-array (list (length to-search)))
			  (alexandria:copy-array to-search))))
	(dotimes (index (array-total-size results))
	  (setf (row-major-aref results index)
		(let ((found (position (row-major-aref to-search index)
				       to-find)))
		  (if found (1+ found)
		      maximum))))
	results)))

(defun alpha-compare (atomic-vector compare-by)
  (lambda (item1 item2)
    (flet ((assign-char-value (char)
	     (let ((vector-pos (position char atomic-vector)))
	       (if vector-pos vector-pos (length atomic-vector)))))
      (if (numberp item1)
	  (or (characterp item2)
	      (if (= item1 item2)
		  :equal (funcall compare-by item1 item2)))
	  (if (characterp item1)
	      (if (characterp item2)
		  (if (char= item1 item2)
		      :equal (funcall compare-by (assign-char-value item1)
				      (assign-char-value item2)))))))))
  
(defun vector-grade (compare-by vector1 vector2 &optional index)
  (let ((index (if index index 0)))
    (cond ((>= index (length vector1))
	   (not (>= index (length vector2))))
	  ((>= index (length vector2)) nil)
	  (t (let ((compared (funcall compare-by (aref vector1 index)
				      (aref vector2 index))))
	       (if (eq :equal compared)
		   (vector-grade compare-by vector1 vector2 (1+ index))
		   compared))))))

(defun grade (array compare-by count-from)
  (let* ((array (if (= 1 (rank array))
		    array (aops:split array 1)))
	 (vector (make-array (list (length array))))
	 (graded-array (make-array (list (length array))
				   :initial-contents (mapcar (lambda (item) (+ item count-from))
							     (alexandria:iota (length array))))))
    (loop for index from 0 to (1- (length vector))
       do (setf (aref vector index)
		(if (and (arrayp (aref array index))
			 (< 1 (rank (aref array index))))
		    (grade (aref array index)
			   compare-by count-from)
		    (aref array index))))
    (stable-sort graded-array (lambda (1st 2nd)
				(let ((val1 (aref vector (- 1st count-from)))
				      (val2 (aref vector (- 2nd count-from))))
				  (cond ((not (arrayp val1))
					 (if (arrayp val2)
					     (funcall compare-by val1 (aref val2 0))
					     (let ((output (funcall compare-by val1 val2)))
					       (and output (not (eq :equal output))))))
					((not (arrayp val2))
					 (funcall compare-by (aref val1 0)
						  val2))
					(t (vector-grade compare-by val1 val2))))))
    graded-array))

(defun array-grade (compare-by array)
  (aops:each (lambda (item)
	       (let ((coords nil))
		 (run-dim compare-by (lambda (found indices)
				       (if (char= found item)
					   (setq coords indices))))
		 (make-array (list (length coords))
			     :initial-contents (reverse coords))))
	     array))

(defun find-array (target array)
  "Find instances of an array within a larger array."
  (let ((target-head (row-major-aref target 0))
	(target-dims (append (if (< (rank target)
				    (rank array))
				 (loop for index from 0 to (1- (- (rank array)
								  (rank target)))
				    collect 1))
			     (dims target)))
	(output (make-array (dims array) :initial-element 0))
	(match-coords nil)
	(confirmed-matches nil))
    (run-dim array (lambda (element coords)
		     (if (equal element target-head)
			 (setq match-coords (cons coords match-coords)))))
    (loop for match in match-coords
       do (let ((target-index 0)
		(target-matched t)
		(target-displaced (make-array (list (array-total-size target))
					      :displaced-to target)))
	    (run-dim array (lambda (element coords)
			     (declare (ignore coords))
			     (if (and (< target-index (length target-displaced))
				      (not (equal element (aref target-displaced target-index))))
				 (setq target-matched nil))
			     (incf target-index 1))
		     :start-at match :limit target-dims)
	    ;; check the target index in case the elements in the searched array ran out
	    (if (and target-matched (= target-index (length target-displaced)))
		(setq confirmed-matches (cons match confirmed-matches)))))
    (loop for match in confirmed-matches
       do (setf (apply #'aref (cons output match))
		1))
    output))

(defun run-dim (array function &key (dimensions nil) (indices nil) (start-at nil) (limit nil))
  "Iterate across a range of elements in an array, with an optional starting point and limits."
  (let ((dimensions (if dimensions dimensions (dims array))))
    (loop for elix from (if start-at (nth (length indices)
					  start-at)
			    0)
       to (min (if limit
		   (+ (if start-at (nth (length indices)
					start-at)
			  0)
		      -1 (nth (length indices)
			      limit))
		   (1- (nth (length indices)
			    dimensions)))
	       (1- (nth (length indices)
			dimensions)))
       do (if (< (length indices)
		 (1- (length dimensions)))
	      (run-dim array function :indices (append indices (list elix))
		       :dimensions dimensions :start-at start-at :limit limit)
	      (funcall function (apply #'aref (cons array (append indices (list elix))))
		       (append indices (list elix)))))))

(defun mix-arrays (axis arrays &optional max-dims)
  (let ((permute-dims (if (vectorp arrays)
			  (alexandria:iota (1+ (rank (aref arrays 0))))))
	(max-dims (if max-dims max-dims
		      (let ((mdims (make-array (list (array-total-size arrays))
					       :displaced-to (aops:each #'dims arrays))))
			(loop for dx from 0 to (1- (length (aref mdims 0)))
			   collect (apply #'max (array-to-list (aops:each (lambda (n) (nth dx n))
									  mdims))))))))
    (if (vectorp arrays)
	(apply #'aops:stack
	       (cons axis (loop for index from 0 to (1- (length arrays))
			     collect (aops:permute (rotate-right axis permute-dims)
						   (array-promote
						    (if (not (equalp max-dims (dims (aref arrays index))))
							(let ((out-array (make-array max-dims)))
							  (run-dim (aref arrays index)
								   (lambda (item coords)
								     (setf (apply #'aref (cons out-array coords))
									   item)))
							  out-array)
							(aref arrays index)))))))
	(aops:combine (aops:each (lambda (sub-arrays)
				   (mix-arrays axis sub-arrays max-dims))
				 (aops:split arrays 1))))))

(defun invert-matrix (in-matrix)
  (let ((dim (array-dimension in-matrix 0))   ;; dimension of matrix
	(det 1)                               ;; determinant of matrix
	(l nil)                               ;; permutation vector
	(m nil)                               ;; permutation vector
	(temp 0)
	(out-matrix (make-array (dims in-matrix))))

    (if (not (equal dim (array-dimension in-matrix 1)))
	(error "invert-matrix () - matrix not square"))

    ;; (if (not (equal (array-dimensions in-matrix)
    ;;                 (array-dimensions out-matrix)))
    ;;     (error "invert-matrix () - matrices not of the same size"))

    ;; copy in-matrix to out-matrix if they are not the same
    (when (not (equal in-matrix out-matrix))
      (do ((i 0 (1+ i)))
	  ((>= i dim))    
	(do ((j 0 (1+ j)))
	    ((>= j dim)) 
	  (setf (aref out-matrix i j) (aref in-matrix i j)))))

    ;; allocate permutation vectors for l and m, with the 
    ;; same origin as the matrix
    (setf l (make-array `(,dim)))
    (setf m (make-array `(,dim)))

    (do ((k 0 (1+ k))
	 (biga 0)
	 (recip-biga 0))
	((>= k dim))

      (setf (aref l k) k)
      (setf (aref m k) k)
      (setf biga (aref out-matrix k k))

      ;; find the biggest element in the submatrix
      (do ((i k (1+ i)))
	  ((>= i dim))    
	(do ((j k (1+ j)))
	    ((>= j dim)) 
	  (when (> (abs (aref out-matrix i j)) (abs biga))
	    (setf biga (aref out-matrix i j))
	    (setf (aref l k) i)
	    (setf (aref m k) j))))

      ;; interchange rows
      (if (> (aref l k) k)
	  (do ((j 0 (1+ j))
	       (i (aref l k)))
	      ((>= j dim)) 
	    (setf temp (- (aref out-matrix k j)))
	    (setf (aref out-matrix k j) (aref out-matrix i j))
	    (setf (aref out-matrix i j) temp)))

      ;; interchange columns 
      (if (> (aref m k) k)
	  (do ((i 0 (1+ i))
	       (j (aref m k)))
	      ((>= i dim)) 
	    (setf temp (- (aref out-matrix i k)))
	    (setf (aref out-matrix i k) (aref out-matrix i j))
	    (setf (aref out-matrix i j) temp)))

      ;; divide column by minus pivot (value of pivot 
      ;; element is in biga)
      (if (equalp biga 0) 
	  (return-from invert-matrix 0))
      (setf recip-biga (/ 1 biga))
      (do ((i 0 (1+ i)))
	  ((>= i dim)) 
	(if (not (equal i k))
	    (setf (aref out-matrix i k) 
		  (* (aref out-matrix i k) (- recip-biga)))))

      ;; reduce matrix
      (do ((i 0 (1+ i)))
	  ((>= i dim)) 
	(when (not (equal i k))
	  (setf temp (aref out-matrix i k))
	  (do ((j 0 (1+ j)))
	      ((>= j dim)) 
	    (if (not (equal j k))
		(incf (aref out-matrix i j) 
		      (* temp (aref out-matrix k j)))))))

      ;; divide row by pivot
      (do ((j 0 (1+ j)))
	  ((>= j dim)) 
	(if (not (equal j k))
	    (setf (aref out-matrix k j)
		  (* (aref out-matrix k j) recip-biga))))

      (setf det (* det biga)) ;; product of pivots
      (setf (aref out-matrix k k) recip-biga)) ;; k loop

    ;; final row & column interchanges
    (do ((k (1- dim) (1- k)))
	((< k 0))
      (if (> (aref l k) k)
	  (do ((j 0 (1+ j))
	       (i (aref l k)))
	      ((>= j dim))
	    (setf temp (aref out-matrix j k))
	    (setf (aref out-matrix j k) 
		  (- (aref out-matrix j i)))
	    (setf (aref out-matrix j i) temp)))
      (if (> (aref m k) k)
	  (do ((i 0 (1+ i))
	       (j (aref m k)))
	      ((>= i dim))
	    (setf temp (aref out-matrix k i))
	    (setf (aref out-matrix k i) 
		  (- (aref out-matrix j i)))
	    (setf (aref out-matrix j i) temp))))
    det ;; return determinant
    out-matrix))
