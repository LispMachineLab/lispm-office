;;; lispm-office-layout-test.el --- Seating invariants -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-or-later

(require 'ert)
(require 'lispm-office-layout)

(defun lispm-office-layout-test--record (id &optional root parent)
  "Make a roster record with ID, ROOT and optional PARENT."
  (list :key (list 'claude id) :name id :root (or root "/projects/alpha")
        :parent (and parent (list 'claude parent)) :status '(:state idle)))

(defun lispm-office-layout-test--records (count &optional root)
  "Make COUNT records belonging to ROOT."
  (cl-loop for i below count collect
           (lispm-office-layout-test--record (format "agent-%04d" i) root)))

(defun lispm-office-layout-test--seat (state id)
  "Return the reserved seat in STATE for Claude agent ID."
  (cdr (assoc (list 'claude id) (plist-get state :seats))))

(defmacro lispm-office-layout-test--file (&rest body)
  "Run BODY with a temporary FILE and DIRECTORY."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "lispm-office-layout-" t))
          (file (expand-file-name "seats.eld" directory)))
     (unwind-protect (progn ,@body)
       (delete-directory directory t))))

(ert-deftest lispm-office-layout-empty-and-unknown ()
  (let* ((records '((:key nil :name "Connecting")))
         (state (lispm-office-layout-reconcile nil records))
         (plan (lispm-office-layout-plan state records)))
    (should (equal state '(:version 1 :rooms nil :seats nil)))
    (should-not (plist-get plan :nodes))
    (should (= (plist-get plan :width) 32))))

(ert-deftest lispm-office-layout-order-is-not-position ()
  (let* ((records (lispm-office-layout-test--records 24))
         (state (lispm-office-layout-reconcile nil records)))
    (should (equal state (lispm-office-layout-reconcile nil (reverse records))))
    (should (equal state (lispm-office-layout-reconcile state (reverse records))))))

(ert-deftest lispm-office-layout-growth-does-not-move-desks ()
  (let* ((records (lispm-office-layout-test--records 12))
         (state (lispm-office-layout-reconcile nil records))
         (expanded (lispm-office-layout-reconcile state (lispm-office-layout-test--records 240))))
    (dolist (entry (plist-get state :seats))
      (should (equal (cdr entry) (cdr (assoc (car entry) (plist-get expanded :seats)))))))
  (let* ((records (lispm-office-layout-test--records 240))
         (state (lispm-office-layout-reconcile nil records))
         (plan (lispm-office-layout-plan state records)))
    (should (= (length (plist-get plan :nodes)) 240))
    (should (= (length (plist-get plan :rooms)) 15))
    (dolist (room (plist-get plan :rooms))
      (should (= (length (plist-get room :nodes)) 16))
      (dolist (node (plist-get room :nodes))
        (should (<= (plist-get room :x) (plist-get node :x)))
        (should (<= (+ (plist-get node :x) (plist-get node :width))
                    (+ (plist-get room :x) (plist-get room :width))))
        (should (<= (+ (plist-get node :y) (plist-get node :height))
                    (+ (plist-get room :y) (plist-get room :height))))))))

(ert-deftest lispm-office-layout-absent-desks-reserved-until-compact ()
  (let* ((records (lispm-office-layout-test--records 17))
         (state (lispm-office-layout-reconcile nil records))
         (last (last records))
         (shrunk (lispm-office-layout-reconcile state last))
         (plan (lispm-office-layout-plan shrunk last))
         (compact (lispm-office-layout-compact shrunk last)))
    (should (equal state shrunk))
    (should (= (length (plist-get plan :rooms)) 1))
    (should (= (plist-get (car (plist-get plan :rooms)) :id) 1))
    (should (= (length (plist-get compact :seats)) 1))
    (should (= (plist-get (car (plist-get compact :rooms)) :id) 0))
    (should (equal state (lispm-office-layout-reconcile shrunk records)))))

(ert-deftest lispm-office-layout-parent-before-child-and-siblings ()
  (let* ((parent (lispm-office-layout-test--record "z-parent"))
         (records (list (lispm-office-layout-test--record "a-child" nil "z-parent")
                        (lispm-office-layout-test--record "b-child" nil "z-parent") parent))
         (state (lispm-office-layout-reconcile nil records))
         (seat (lispm-office-layout-test--seat state "z-parent")))
    (dolist (id '("a-child" "b-child"))
      (let ((child (lispm-office-layout-test--seat state id)))
        (should (= (plist-get child :room) (plist-get seat :room)))
        (should (= (/ (plist-get child :slot) 4) (/ (plist-get seat :slot) 4)))))))

(ert-deftest lispm-office-layout-child-prefers-parents-pod ()
  (let* ((records (lispm-office-layout-test--records 9))
         (state (lispm-office-layout-reconcile nil records))
         (child (lispm-office-layout-test--record "child" nil "agent-0008"))
         (new (lispm-office-layout-reconcile state (cons child records))))
    (should (= (plist-get (lispm-office-layout-test--seat new "child") :slot) 9))))

(ert-deftest lispm-office-layout-parent-cycle-and-long-chain ()
  (let* ((records (list (lispm-office-layout-test--record "a" nil "b")
                        (lispm-office-layout-test--record "b" nil "c")
                        (lispm-office-layout-test--record "c" nil "a")))
         (state (lispm-office-layout-reconcile nil records)))
    (should (= (length (plist-get state :seats)) 3))
    (should (equal state (lispm-office-layout-reconcile nil (reverse records)))))
  (let* ((records (cl-loop for i below 240 collect
                          (lispm-office-layout-test--record
                           (format "%04d" i) nil (and (< i 239) (format "%04d" (1+ i))))))
         (state (lispm-office-layout-reconcile nil records)))
    (should (= (length (plist-get state :seats)) 240))))

(ert-deftest lispm-office-layout-project-relocation-is-local ()
  (let* ((records (list (lispm-office-layout-test--record "a")
                        (lispm-office-layout-test--record "b")))
         (state (lispm-office-layout-reconcile nil records))
         (moved (lispm-office-layout-reconcile
                 state (list (lispm-office-layout-test--record "a" "/projects/beta")
                             (cadr records)))))
    (should (equal (lispm-office-layout-test--seat state "b")
                   (lispm-office-layout-test--seat moved "b")))
    (should-not (equal (lispm-office-layout-test--seat state "a")
                       (lispm-office-layout-test--seat moved "a")))
    (should (= (length (plist-get moved :seats)) 2))
    (should (equal (plist-get (cadr (plist-get moved :rooms)) :root) "/projects/beta/"))))

(ert-deftest lispm-office-layout-root-normalization-and-home ()
  (let* ((records (list (lispm-office-layout-test--record "a" "/projects/foo/../alpha")
                        (lispm-office-layout-test--record "b" "/projects/alpha/")
                        '(:key (lispm "home") :root nil)))
         (state (lispm-office-layout-reconcile nil records)))
    (should (= (length (plist-get state :rooms)) 2))
    (should (seq-find (lambda (room) (equal "Home" (plist-get room :label)))
                      (plist-get state :rooms)))))

(ert-deftest lispm-office-layout-does-not-mutate-inputs ()
  (let* ((records (lispm-office-layout-test--records 6))
         (state (lispm-office-layout-reconcile nil records))
         (before-records (copy-tree records))
         (before-state (copy-tree state)))
    (lispm-office-layout-reconcile state (cons (lispm-office-layout-test--record "new" "/other") records))
    (lispm-office-layout-plan state records)
    (should (equal before-records records))
    (should (equal before-state state))))

(ert-deftest lispm-office-layout-duplicate-record-and-invalid-key ()
  (let ((record (lispm-office-layout-test--record "a")))
    (should-error (lispm-office-layout-reconcile nil (list record record))))
  (dolist (key '("bad" (nil "a") (claude "") (claude 1) (:claude "a") (claude "a" "extra")))
    (should-error (lispm-office-layout-reconcile nil (list (list :key key))))))

(ert-deftest lispm-office-layout-restart-preserves-seats ()
  (lispm-office-layout-test--file
    (let* ((records (lispm-office-layout-test--records 32))
           (state (lispm-office-layout-reconcile nil records)))
      (should-not (lispm-office-layout-read file))
      (lispm-office-layout-write state file)
      (should (equal state (lispm-office-layout-read file)))
      (should (equal state (lispm-office-layout-reconcile (lispm-office-layout-read file) records)))
      (should (= (logand (file-modes file) #o077) 0)))))

(ert-deftest lispm-office-layout-corrupt-file-is-never-replaced ()
  (lispm-office-layout-test--file
    (dolist (data '("(" "(:version 99 :rooms nil :seats nil)" "#1=(#1#)"
                    "#.(error \"must not run\")"
                    "(:version 1 :rooms nil :seats nil) ("
                    "(:version 1 :rooms nil :seats nil) nil"))
      (with-temp-file file (insert data))
      (should-error (lispm-office-layout-read file))
      (should-error (lispm-office-layout-write '(:version 1 :rooms nil :seats nil) file))
      (should (equal data (with-temp-buffer (insert-file-contents file) (buffer-string)))))))

(ert-deftest lispm-office-layout-rejects-seat-collisions-and-dangling-rooms ()
  (lispm-office-layout-test--file
    (let* ((state (lispm-office-layout-reconcile nil (lispm-office-layout-test--records 2)))
           (bad (copy-tree state)))
      (setcdr (cadr (plist-get bad :seats)) (copy-tree (cdar (plist-get bad :seats))))
      (should-error (lispm-office-layout-write bad file))
      (setq bad (copy-tree state))
      (setf (plist-get (cdar (plist-get bad :seats)) :room) 99)
      (should-error (lispm-office-layout-write bad file))
      (should-not (file-exists-p file)))))

(ert-deftest lispm-office-layout-atomic-write-preserves-old-file-on-failure ()
  (lispm-office-layout-test--file
    (let ((old (lispm-office-layout-reconcile nil (lispm-office-layout-test--records 1)))
          (new (lispm-office-layout-reconcile nil (lispm-office-layout-test--records 2))))
      (lispm-office-layout-write old file)
      (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "Rename failed"))))
        (should-error (lispm-office-layout-write new file)))
      (should (equal old (lispm-office-layout-read file)))
      (should (equal '("seats.eld") (directory-files directory nil "^[^.]")))
      (should-not (directory-files directory nil "^\\.office-seats-")))))

(provide 'lispm-office-layout-test)
;;; lispm-office-layout-test.el ends here
