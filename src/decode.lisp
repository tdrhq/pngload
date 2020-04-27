(in-package #:pngload)

(defvar *decode-data* nil)
(defvar *flatten* nil)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (alexandria:define-constant +filter-type-none+ 0)
  (alexandria:define-constant +filter-type-sub+ 1)
  (alexandria:define-constant +filter-type-up+ 2)
  (alexandria:define-constant +filter-type-average+ 3)
  (alexandria:define-constant +filter-type-paeth+ 4))

(defmacro %row-major-aref (array index)
  `(row-major-aref ,array (the fixnum ,index)))

(defun get-image-bytes ()
  (with-slots (width height interlace-method) *png*
    (ecase interlace-method
      (:null
       (+ height (* height (get-scanline-bytes width))))
      (:adam7
       (loop :for (width height) :in (calculate-sub-image-dimensions)
             :sum (* height (1+ (get-scanline-bytes width))))))))

(defun get-image-raw-channels ()
  (ecase (color-type *png*)
    ((:truecolour :indexed-colour) 3)
    (:truecolour-alpha 4)
    (:greyscale-alpha 2)
    (:greyscale 1)))

(defun get-image-channels ()
  (let ((channels (get-image-raw-channels)))
    (when (transparency *png*)
      (assert (member (color-type *png*)
                      '(:truecolour :indexed-colour :greyscale)))
      (incf channels))
    channels))

(defun allocate-image-data ()
  (let* ((width (width *png*))
         (height (height *png*))
         (channels (get-image-channels))
         (args (list (if *flatten*
                         (* width height channels)
                         `(,height ,width ,@(when (> channels 1)
                                              (list channels))))
                     :element-type (ecase (bit-depth *png*)
                                     ((1 2 4 8) 'ub8)
                                     (16 'ub16)))))
    (when *use-static-vector* (assert *flatten*))
    #- (or clisp abcl)
    (if *use-static-vector*
        (apply #'static-vectors:make-static-vector args)
        (apply #'make-array args))
    #+ (or clisp abcl)
    (apply #'make-array args)
    ))

;;; Following the PNG sW3 spec, the pixels considered when performing filter
;;; Are described in this diagram:
;;;   +-------+
;;;   | c | b |
;;;   +---+---+
;;;   | a | x |
;;;   +---+---+
;;; Where x is the 'current' pixel
;;;
(defun unfilter-row-sub (y data row-start row-bytes pixel-bytes)
  (declare (type ub8a1d data)
           (type (and fixnum (integer 0)) y row-start)
           (type (and fixnum (integer 1)) row-bytes pixel-bytes)
           (ignore y)
           (optimize speed))
  (loop :for x :from (+ row-start pixel-bytes)
          :below (+ row-start (1- row-bytes))
        :for a fixnum = (- x pixel-bytes)
        :do (setf (aref data x)
                  (ldb (byte 8 0) (+ (aref data x) (aref data a))))))

(defun unfilter-row-up (y data row-start row-bytes pixel-bytes)
  (declare (type ub8a1d data)
           (type (and fixnum (integer 0)) y row-start)
           (type (and fixnum (integer 1)) row-bytes  pixel-bytes)
           (ignore pixel-bytes)
           (optimize speed))
  (when (>= y 1)
    (loop
      :for x :from row-start :below (+ row-start (1- row-bytes))
      :for b = (- x row-bytes)
      :do (setf (aref data x)
                (ldb (byte 8 0) (+ (aref data x) (aref data b)))))))

(defun unfilter-row-average (y data row-start row-bytes pixel-bytes)
  (declare (type ub8a1d data)
           (type (and fixnum (integer 0)) y row-start)
           (type (and fixnum (integer 1)) row-bytes  pixel-bytes)
           (optimize speed))
  (loop :for x fixnum :from row-start :below (+ row-start (1- row-bytes))
        :for a fixnum = (- x pixel-bytes)
        :for b fixnum = (- x row-bytes)
        :do (setf (aref data x)
                  (ldb (byte 8 0)
                       (+ (aref data x)
                          (floor (+ (if (>= a row-start) (aref data a) 0)
                                    (if (>= y 1) (aref data b) 0))
                                 2))))))

(defun unfilter-row-paeth (y data row-start row-bytes pixel-bytes)
  (declare (type ub8a1d data)
           (type (and fixnum (integer 0)) y row-start)
           (type (and fixnum (integer 1)) row-bytes  pixel-bytes)
           (optimize speed))
  (if (zerop y)
      ;; paeth on the first row is equivalent to a sub
      (unfilter-row-sub y data row-start row-bytes pixel-bytes)
      (loop :initially
        ;; Handle the first column specifically so we don't have to worry about
        ;; it later
        (loop :for x :from row-start :below (+ row-start pixel-bytes)
              :do (setf (aref data x)
                        (ldb (byte 8 0)
                             (+ (aref data x) (aref data (- x row-bytes))))))
            :for x fixnum :from (+ row-start pixel-bytes)
              :below (+ row-start (1- row-bytes))
            :for a fixnum = (- x pixel-bytes)
            :for b fixnum = (- x row-bytes)
            :for c fixnum = (- b pixel-bytes)
            :do (setf (aref data x)
                      (ldb (byte 8 0)
                           (+ (aref data x)
                              ;; We know we're not on the first row or column so
                              ;; we can just branch off the values and not their
                              ;; positions
                              (let* ((av (aref data a))
                                     (bv (aref data b))
                                     (cv (aref data c))
                                     (p (- (+ av bv) cv))
                                     (pa (abs (- p av)))
                                     (pb (abs (- p bv)))
                                     (pc (abs (- p cv))))
                                (cond ((and (<= pa pb) (<= pa pc)) av)
                                      ((<= pb pc) bv)
                                      (t cv)))))))))

(defun unfilter (data width height start)
  (declare (ub32 width height)
           (fixnum start)
           (ub8a1d data))
  (loop :with pixel-bytes = (get-pixel-bytes)
        :with scanline-bytes fixnum = (get-scanline-bytes width)
        :with row-bytes = (1+ scanline-bytes)
        :for y fixnum :below height
        :for in-start fixnum :from start :by row-bytes
        :for row-start fixnum :from (1+ start) :by row-bytes
        :do
           (ecase (aref data in-start)
             (#.+filter-type-none+ ; nothing tbd
              nil)
             (#.+filter-type-sub+
              (unfilter-row-sub y data row-start row-bytes pixel-bytes))
             (#.+filter-type-up+
              (unfilter-row-up y data row-start row-bytes pixel-bytes))
             (#.+filter-type-average+
              (unfilter-row-average y data row-start row-bytes pixel-bytes))
             (#.+filter-type-paeth+
              (unfilter-row-paeth y data row-start row-bytes pixel-bytes)))
        :finally
           ;; Now compact row data by removing the filter bytes
           (loop
             :for y :below height
             :for dst-data :from start :by scanline-bytes
             :for row-start fixnum :from (1+ start) :by row-bytes
             :do (replace data
                          data
                          :start1 dst-data
                          :start2 row-start
                          :end2 (+ row-start scanline-bytes)))))

(defmacro maybe-flatten (dims bit-depth)
  (let ((nd-fn-sym (intern (format nil "COPY/~dD/~d" dims bit-depth)))
        (1d-fn-sym (intern (format nil "COPY/1D/~d" bit-depth)))
        (copy-fn-sym (intern (format nil "COPY/~d" bit-depth)))
        (copy-flip-fn-sym (intern (format nil "COPY/~d/FLIP" bit-depth)))
        (nd-type-sym (intern (format nil "UB~dA~dD" bit-depth dims)))
        (1d-type-sym (intern (format nil "UB~dA1D" bit-depth))))
    `(flet ((,nd-fn-sym ()
              (declare (,nd-type-sym data))
              (if *flip-y*
                  (,copy-flip-fn-sym)
                  (,copy-fn-sym)))
            (,1d-fn-sym ()
              (declare (,1d-type-sym data))
              (if *flip-y*
                  (,copy-flip-fn-sym)
                  (,copy-fn-sym))))
       (if *flatten*
           (,1d-fn-sym)
           (,nd-fn-sym)))))

(defmacro copy/8 ()
  `(loop :for d fixnum :below (array-total-size data)
         :for s fixnum :below (array-total-size image-data)
         :do (locally (declare (optimize speed (safety 0)))
               (setf (%row-major-aref data d)
                     (aref image-data s)))))

(defmacro copy/8/flip ()
  `(with-slots (width height bit-depth) *png*
     (let* ((channels (get-image-raw-channels))
            (stride (* channels width))
            (ssize (array-total-size image-data))
            (dsize (array-total-size data)))
       (declare (fixnum ssize dsize)
                (type (unsigned-byte 34) stride))
       (loop :for dy :below height
             :for sy :downfrom (1- height)
             :for d1 = (* dy stride)
             :for s1 = (* sy stride)
             :do (assert (<= 0 (+ d1 stride) dsize))
                 (assert (<= 0 (+ s1 stride) ssize))
                 (locally (declare (optimize speed))
                   (loop :for s fixnum :from s1 :below ssize
                         :for d fixnum :from d1 :below dsize
                         :repeat stride
                         :do (locally (declare (optimize speed (safety 0)))
                               (setf (%row-major-aref data d)
                                     (aref image-data s)))))))))

(defmacro copy/16 ()
  `(progn
     (assert (zerop (mod (array-total-size image-data) 2)))
     (loop :for d :below (array-total-size data)
           :for s :below (array-total-size image-data) :by 2
           :do (locally (declare (optimize speed (safety 0)))
                 (setf (%row-major-aref data d)
                       (dpb (aref image-data s) (byte 8 8)
                            (aref image-data (1+ s))))))))

(defmacro copy/16/flip ()
  `(with-slots (width height bit-depth) *png*
     (let* ((channels (get-image-raw-channels))
            (stride (* channels width))
            (ssize (array-total-size image-data))
            (dsize (array-total-size data)))
       (declare (fixnum ssize dsize)
                (type (unsigned-byte 34) stride))
       (loop :for dy :below height
             :for sy :downfrom (1- height)
             :for d1 = (* dy stride)
             :for s1 = (* sy stride 2)
             :do (assert (<= 0 (+ d1 stride) dsize))
                 (assert (<= 0 (+ s1 stride stride) ssize))
                 (locally (declare (optimize speed))
                   (loop :for s fixnum :from s1 :below ssize :by 2
                         :for d fixnum :from d1 :below dsize
                         :repeat stride
                         :do (locally (declare (optimize speed (safety 0)))
                               (setf (%row-major-aref data d)
                                     (dpb (aref image-data s) (byte 8 8)
                                          (aref image-data (1+ s)))))))))))

(defun copy/pal/8 (image-data)
  (with-slots (data palette transparency) *png*
    (macrolet ((copy ()
                 `(loop :with c = (get-image-channels)
                        :for d :below (array-total-size data) :by c
                        :for s :across image-data
                        :do  (setf (%row-major-aref data (+ d 0))
                                   (aref palette s 0)
                                   (%row-major-aref data (+ d 1))
                                   (aref palette s 1)
                                   (%row-major-aref data (+ d 2))
                                   (aref palette s 2))
                             (when transparency
                               (setf (%row-major-aref data (+ d 3))
                                     (if (array-in-bounds-p transparency s)
                                         (aref transparency s)
                                         255))))))
      (if *flatten*
          (locally (declare (ub8a1d data)) (copy))
          (locally (declare (ub8a3d data)) (copy))))))

(defun copy/pal/sub (image-data)
  (with-slots (width height bit-depth palette transparency data) *png*
    (loop :with scanline-bytes = (get-scanline-bytes width)
          :with pixels-per-byte = (/ 8 bit-depth)
          :with channels = (get-image-channels)
          :with dstride = (* width channels)
          :for y :below height
          :for yb = (* y scanline-bytes)
          :do (flet (((setf %data) (v y x c)
                       (setf (%row-major-aref
                              data (+ (* y dstride) (* x channels) c))
                             v)))
                (loop :for x :below width
                      :do (multiple-value-bind (b p) (floor x pixels-per-byte)
                            (let ((i (ldb (byte bit-depth
                                                (- 8 (* p bit-depth) bit-depth))
                                          (aref image-data (+ yb b)))))
                              (setf (%data y x 0) (aref palette i 0)
                                    (%data y x 1) (aref palette i 1)
                                    (%data y x 2) (aref palette i 2))
                              (when transparency
                                (setf (%data y x 3)
                                      (if (array-in-bounds-p transparency i)
                                          (aref transparency i)
                                          255))))))))))

(defun copy/2d/sub (image-data)
  (with-slots (width bit-depth data) *png*
    (declare (ub8a data))
    (loop :with s = 0
          :with x = 0
          :with bx = 0
          :with p = 0
          :with b = 0
          :with scanline-bytes = (get-scanline-bytes width)
          :with ssize = (array-total-size image-data)
          :for d :below (array-total-size data)
          :while (< (+ s bx) ssize)
          :when (zerop p)
            :do (setf b (aref image-data (+ s bx)))
          :do (setf (%row-major-aref data d)
                    (ldb (byte bit-depth (- 8 p bit-depth)) b))
              (incf p bit-depth)
              (incf x)
              (cond
                ((>= x width)
                 (setf x 0
                       bx 0
                       p 0)
                 (incf s scanline-bytes))
                ((>= p 8)
                 (setf p 0)
                 (incf bx 1))))))

(defmacro trns (opaque)
  `(loop :with c = (get-image-channels)
         :with key = (etypecase transparency
                       (ub16 (make-array 1 :element-type 'ub16
                                           :initial-element transparency))
                       (ub16a1d transparency))
         :for s :from (- (* width height (1- c)) (1- c)) :downto 0 :by (1- c)
         :for d :from (- (array-total-size data) c) :downto 0 :by c
         :do (loop :for i :below (1- c)
                   :for k :across key
                   :for v = (%row-major-aref data (+ s i))
                   :do (setf (%row-major-aref data (+ d i)) v)
                   :count (= v k) :into matches
                   ;; collect (list v k matches) :into foo
                   :finally (setf (%row-major-aref data (+ d (1- c)))
                                  (if (= matches (1- c)) 0 ,opaque)))))

(defun flip (image)
  (let ((w (width *png*))
        (h (height *png*))
        (c (get-image-channels)))
    (let ((stride (* w c))
          (end (array-total-size image)))
      (assert (plusp stride))
      (macrolet ((f (&key (opt t))
                   `(loop :for y1 :below (floor h 2)
                          :for y2 :downfrom (1- h) :above 0
                          :do (loop :for x1 :from (* y1 stride) :below end
                                    :for x2 :from (* y2 stride) :below end
                                    :repeat stride
                                    :do (,@(if opt
                                               '(locally
                                                 (declare
                                                  (optimize speed (safety 0))))
                                               '(progn))
                                         (rotatef (%row-major-aref image x1)
                                                  (%row-major-aref
                                                   image x2)))))))
        (typecase image
          (ub8a3d (f))
          (ub8a2d (f))
          (ub8a1d (f))
          (ub16a3d (f))
          (ub16a2d (f))
          (ub16a1d (f))
          (t (f :opt nil)))))))

(defun maybe-flip (data)
  (when *flip-y*
    (flip data)))

(defun decode ()
  (let ((image-data (data *png*)))
    (declare (ub8a1d image-data))
    (with-slots (width height bit-depth interlace-method color-type
                 transparency data)
        *png*
      (if (eq interlace-method :null)
          (unfilter image-data width height 0)
          (setf image-data (deinterlace-adam7 image-data)))
      (assert (and (typep bit-depth 'ub8)
                   (member bit-depth '(1 2 4 8 16))))
      (setf data (allocate-image-data))
      (let ((data data))
        (ecase color-type
          ((:truecolour :truecolour-alpha :greyscale-alpha)
           (ecase bit-depth
             (8 (maybe-flatten 3 8))
             (16 (maybe-flatten 3 16)))
           (when transparency
             (ecase bit-depth
               (8 (trns #xff))
               (16 (trns #xffff)))))
          (:greyscale
           (if transparency
               (ecase bit-depth
                 (8 (maybe-flatten 3 8) (trns #xff))
                 (16 (maybe-flatten 3 16) (trns #xffff))
                 ((1 2 4)
                  (copy/2d/sub image-data)
                  (trns #xff)
                  (maybe-flip data)))
               (ecase bit-depth
                 (8 (maybe-flatten 2 8))
                 (16 (maybe-flatten 2 16))
                 ((1 2 4) (copy/2d/sub image-data) (maybe-flip data)))))
          (:indexed-colour
           (ecase bit-depth
             (8 (copy/pal/8 image-data))
             ((1 2 4) (copy/pal/sub image-data)))
           (maybe-flip data)))))
    *png*))
