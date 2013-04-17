;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2006 by the authors.
;;;
;;; See LICENCE for details.

(in-package :stefil-test)

(defsuite* (test :in root-suite :documentation "Stefil self tests"))

(defsuite (stefil-temp-suite :in test :documentation "Current test suite while the Stefil self-tests are being run"))

;; hide deftest with a local version that rebinds and sets *suite* when executing the body
(defmacro deftest (name args &body body)
  `(stefil:deftest ,name ,args
    (let ((*suite* (find-test 'stefil-temp-suite)))
      ,@body)))

(deftest lifecycle ()
  (let* ((original-test-count (count-tests *suite*))
         (original-current-suite *suite*)
         (suite-name (gensym "TEMP-SUITE"))
         (test-name (gensym "TEMP-TEST"))
         (transient-test-name (gensym "TRANSIENT-TEST"))
         (transient-suite-name (gensym "TRANSIENT-SUITE")))
    (unwind-protect
         (progn
           (eval `(deftest ,test-name ()))
           (is (= (count-tests *suite*) (1+ original-test-count)))
           (let ((test (find-test test-name)))
             ;; it should keep the original test object identity
             (eval `(deftest ,test-name ()))
             (is (eq test (find-test test-name)))))
      (delete-test test-name :otherwise nil))
    (is (not (find-test test-name :otherwise nil)))
    (is (= (count-tests *suite*) original-test-count))
    (unwind-protect
         (let* ((temp-suite (eval `(defsuite (,suite-name :in ,*suite*))))
                (transient-suite (eval `(defsuite (,transient-suite-name :in ,*suite*)))))
           (is (= (count-tests *suite*) (+ 2 original-test-count)))
           (is (eq (parent-of temp-suite) *suite*))
           (is (eq (find-test (name-of temp-suite)) temp-suite))
           (eval `(in-suite ,(name-of temp-suite)))
           (is (eq *suite* (find-test suite-name)))
           (eval `(deftest ,transient-test-name ()))
           (let ((transient-test (find-test transient-test-name)))
             (is (eq *suite* (parent-of transient-test)))
             ;; redefine in another suite
             (eval `(deftest (,transient-test-name :in ,transient-suite-name) ()))
             (is (eq transient-suite (parent-of transient-test)))))
      (setf (find-test suite-name) nil)
      (setf (find-test transient-suite-name) nil))
    (signals error (find-test transient-test-name))
    (signals error (find-test suite-name))
    (is (= (count-tests *suite*) original-test-count))
    (is (eq original-current-suite *suite*))))

(defparameter *global-counter-for-lexical-test* 0)

(let ((counter 0))
  (setf *global-counter-for-lexical-test* 0)
  (deftest (counter-in-lexical-environment :compile-before-run nil) ()
    (incf counter)
    (incf *global-counter-for-lexical-test*)
    (is (= counter *global-counter-for-lexical-test*))))

(defmacro false-macro ()
  nil)

(defmacro true-macro ()
  t)

(deftest (assertions :compile-before-run t :in test) (&key (test-name (gensym "TEMP-TEST")))
  (unwind-protect
       (eval `(deftest ,test-name ()
                (is (= 42 42))
                (is (= 1 42))                                ; fails
                (is (not (= 42 42)))                         ; fails
                (is (true-macro))
                (is (not (false-macro)))
                (with-expected-failures
                  (ignore-errors
                    (finishes (error "expected failure"))))  ; fails
                (finishes 42)
                (ignore-errors                               ; fails
                  (finishes (error "foo")))
                (signals serious-condition (error "foo"))
                (signals serious-condition 'not)             ; fails
                (not-signals warning (warn "foo"))           ; fails
                (not-signals warning 'not)))
    (progn
      ;; this uglyness here is due to testing the test framework which is inherently
      ;; not nestable, so we need to backup and restore some state
      (let* ((context *global-context*)
             (old-assertion-count (assertion-count-of context))
             (old-failure-description-count (length (failure-descriptions-of context)))
             (old-debug-on-unexpected-error (debug-on-unexpected-error-p context))
             (old-debug-on-assertion-failure (debug-on-assertion-failure-p context))
             (old-print-test-run-progress-p (print-test-run-progress-p context)))
        (unwind-protect
             (progn
               (setf (debug-on-unexpected-error-p context) nil)
               (setf (debug-on-assertion-failure-p context) nil)
               (setf (print-test-run-progress-p context) nil)
               (funcall test-name))
          (setf (debug-on-unexpected-error-p context) old-debug-on-unexpected-error)
          (setf (debug-on-assertion-failure-p context) old-debug-on-assertion-failure)
          (setf (print-test-run-progress-p context) old-print-test-run-progress-p))
        (is (= (assertion-count-of context)
               (+ old-assertion-count 13))) ; also includes the current assertion
        (is (= (length (failure-descriptions-of context))
               (+ old-failure-description-count 6)))
        (is (= 1 (count-if 'stefil::expected-p (failure-descriptions-of context))))
        (dotimes (i (- (length (failure-descriptions-of context))
                       old-failure-description-count))
          ;; drop failures registered by the test-test
          (vector-pop (failure-descriptions-of context))))
      (delete-test test-name :otherwise nil)))
  (values))

(defsuite* (lambda-lists :in test))

(deftest lambda-list-processing ()
  (is (equal (lambda-list-to-value-list-expression '(p1 p2 &optional o1 (o2 "o2") &key k1 (k2 "k2") &allow-other-keys))
             '(list (cons 'p1 p1) (cons 'p2 p2) (cons 'o1 o1) (cons 'o2 o2) (cons 'k1 k1)
               (cons 'k2 k2))))
  (is (equal (lambda-list-to-funcall-expression 'foo '(p1 p2 &optional o1 (o2 "o2") &key k1 (k2 "k2") &allow-other-keys))
             '(FUNCALL FOO P1 P2 O1 O2 :K1 K1 :K2 K2)))
  (is (equal (lambda-list-to-funcall-expression 'foo '(&optional &key &allow-other-keys))
             '(FUNCALL FOO)))
  (is (equal (lambda-list-to-funcall-expression 'foo '(&optional &rest args &key &allow-other-keys))
             '(APPLY FOO args)))
  (is (equal (lambda-list-to-funcall-expression 'foo '(p1 p2 &optional o1 (o2 "o2") &rest args &key k1 (k2 "k2") &allow-other-keys))
             '(APPLY FOO P1 P2 O1 O2 :K1 K1 :K2 K2 ARGS)))
  (is (equal (lambda-list-to-variable-name-list '(&whole whole p1 p2 &optional o1 (o2 "o2") &body body)
                                                :macro t :include-specials t)
             '(WHOLE P1 P2 O1 O2 BODY)))
  (is (equal (multiple-value-list
              (lambda-list-to-variable-name-list '(&whole whole &environment env p1 p2 &optional o1 (o2 "o2") &body body)
                                                 :macro t :include-specials nil))
             '((P1 P2 O1 O2)
               BODY
               WHOLE
               ENV)))
  (dolist (entry '((p1 &whole)
                   (&allow-other-keys)
                   (&key k1 &optional o1)
                   (&aux x1 &key k1)))
    (signals illegal-lambda-list
      (lambda-list-to-variable-name-list entry)))
  (dolist (entry '((p1 &whole)
                   (&allow-other-keys)
                   (&key k1 &optional o1)
                   (&aux x1 &key k1)
                   (a &rest rest &body body)
                   (&aux a &body body)))
    (signals illegal-lambda-list
      (lambda-list-to-variable-name-list entry :macro t))))
