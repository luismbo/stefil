;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2009 by the authors.
;;;
;;; See LICENCE for details.

(load-system :asdf)

(in-package :asdf)

(defsystem :stefil-test
    :licence "BSD / Public domain"
    :depends-on (:stefil)
    :components ((:file "package")
                 (:file "basic" :depends-on ("package"))
                 (:file "fixtures" :depends-on ("package" "basic"))))
