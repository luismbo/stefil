;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2006 by the authors.
;;;
;;; See LICENCE for details.

(in-package :stefil)

#+nil(defclass-star:defclass* test (testable)
  ((package nil)
   (lambda-list nil)
   (compile-before-run t :type boolean)
   (declarations nil)
   (documentation nil)
   (body nil)))

(defclass test (testable)
  ((package :initform nil :accessor package-of :initarg :package)
   (lambda-list :initform nil :accessor lambda-list-of :initarg :lambda-list)
   (compile-before-run :initform t :accessor compile-before-run-p :initarg :compile-before-run :type boolean)
   (declarations :initform nil :accessor declarations-of :initarg :declarations)
   (documentation :initform nil :accessor documentation-of :initarg :documentation)
   (body :initform nil :accessor body-of :initarg :body)))

(defun ensure-test (name &rest args &key &allow-other-keys)
  (let ((test (find-test name :otherwise nil)))
    (if test
        (apply #'reinitialize-instance test args)
        (apply #'make-instance 'test :name name args))))

(defgeneric get-test-lambda (test global-context)
  (:method ((test test) (context global-context))
    (multiple-value-bind (test-lambda found-p)
        (gethash test (test-lambdas-of context))
      (unless found-p
        (setf test-lambda (let* ((*package* (package-of test))
                                 (*readtable* (copy-readtable)))
                            (compile nil `(lambda ,(lambda-list-of test)
                                            ,@(body-of test)))))
        (setf (gethash test (test-lambdas-of context)) test-lambda))
      test-lambda)))

(defun call-with-test-handlers (function)
  ;; NOTE: the order of the bindings in this handler-bind is important
  (handler-bind
      ((assertion-failed
        (lambda (c)
          (declare (ignore c))
          (unless (debug-on-assertion-failure-p *global-context*)
            (continue))))
       (serious-condition
        (lambda (c)
          (record-unexpected-error c)
          (return-from call-with-test-handlers))))
    (funcall function)))

(defun run-test-body-in-handlers (test function)
  (declare (type test test)
           (type function function))
  (register-test-being-run test)
  (labels ((prune-failure-descriptions ()
             ;; drop failures recorded by the previous run of this test
             (loop repeat (number-of-added-failure-descriptions-of *context*)
                do (vector-pop (failure-descriptions-of *global-context*)))
             (setf (number-of-added-failure-descriptions-of *context*) 0))
           (run-test-body ()
             (call-with-test-handlers
              (lambda ()
                (restart-case
                    (let* ((*package* (package-of test))
                           (*readtable* (copy-readtable))
                           (start-time (get-internal-run-time)))
                      (multiple-value-prog1
                          (funcall function)
                        (setf (internal-realtime-spent-with-test-of *context*)
                              (- (get-internal-run-time) start-time))))
                  (continue ()
                    :report (lambda (stream)
                              (format stream "~@<Skip the rest of the test ~S and continue by returning (values)~@:>" (name-of test)))
                    (values))
                  (retest ()
                    :report (lambda (stream)
                              (format stream "~@<Rerun the test ~S~@:>" (name-of test)))
                    ;; TODO: this will only prune the failures that were recorded in the current context.
                    ;; in case of nesting it will leave alone the failures recorded in deeper levels.
                    (prune-failure-descriptions)
                    (return-from run-test-body (run-test-body))))))))
    (run-test-body)))

(defvar *run-test-function* #'run-test-body-in-handlers)

(defun run-test-body (test function arguments toplevel-p timeout)
  (declare (type test test))
  (when timeout
    (error "TODO: timeouts are not implemented yet in Stefil."))
  (let* ((result-values '()))
    (flet ((body ()
             (with-new-context (:test test :test-arguments arguments)
               (when toplevel-p
                 (setf (toplevel-context-of *global-context*) (current-context)))
               (setf result-values (multiple-value-list (funcall *run-test-function* test function))))))
      (if toplevel-p
          (with-toplevel-restarts
            (body))
          (body))
      (if toplevel-p
          (progn
            (when (print-test-run-progress-p *global-context*)
              (terpri *debug-io*))
            (if result-values
                (values-list (append result-values (list *global-context*)))
                *global-context*))
          (values-list result-values)))))

(defmacro deftest (&whole whole name args &body body)
  (multiple-value-bind (remaining-forms declarations documentation)
      (parse-body body :documentation t :whole whole)
      (destructuring-bind (name &rest test-args &key ignore-home-package (compile-before-run *compile-tests-before-run*)
                                (in nil in-provided?) timeout &allow-other-keys)
          (ensure-list name)
        (remove-from-plistf test-args :in :ignore-home-package)
        (unless (or ignore-home-package
                    (not (symbol-package name))
                    (eq (symbol-package name) *package*))
          (warn 'test-style-warning :test name
                :format-control "Defining test on symbol ~S whose home package is not *package* which is ~A"
                :format-arguments (list name *package*)))
        (with-unique-names (test test-lambda global-context toplevel-p body)
          `(progn
             (eval-when (:load-toplevel :execute)
               (ensure-test ',name
                          :package ,*package*
                          :lambda-list ',args
                          :declarations ',declarations
                          :documentation ',documentation
                          :body ',remaining-forms
                          ,@(when in-provided?
                              `(:in (find-test ',in)))
                          ,@test-args))
             (defun ,name ,args
               ,@(when documentation (list documentation))
               ,@declarations
               ,@(when *compile-tests-with-debug-level*
                   `((declare (optimize (debug ,*compile-tests-with-debug-level*)))))
               (let* ((,test (find-test ',name))
                      (,toplevel-p (not (has-global-context)))
                      (,global-context (unless ,toplevel-p
                                         (current-global-context))))
                 ;; for convenience we define a function in a LABELS with the test name, so the debugger shows it in the backtrace
                 (labels (,@(unless compile-before-run
                                    `((,name ()
                                             ,@remaining-forms)))
                          (,body ()
                            ,(if compile-before-run
                                 `(let* ((,test-lambda (get-test-lambda ,test ,global-context)))
                                    (run-test-body ,test
                                                   (lambda ()
                                                     ;; TODO install a labels entry with the test name? to avoid compile at each recursion...
                                                     ,(lambda-list-to-funcall-expression test-lambda args))
                                                   ,(lambda-list-to-value-list-expression args)
                                                   ,toplevel-p
                                                   ,timeout))
                                 `(run-test-body ,test
                                                 #',name
                                                 ,(lambda-list-to-value-list-expression args)
                                                 ,toplevel-p
                                                 ,timeout))))
                   (declare (dynamic-extent ,@(unless compile-before-run `(#',name))
                                            #',body))
                   (if ,toplevel-p
                       (with-new-global-context* ()
                         (setf ,global-context (current-global-context))
                         (push ,global-context *test-result-history*)
                         (setf *last-test-result* ,global-context)
                         (,body))
                       (,body))))))))))
