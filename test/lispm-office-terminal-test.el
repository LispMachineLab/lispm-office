;;; lispm-office-terminal-test.el --- Text Work navigation -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'lispm-office-test
         (expand-file-name "lispm-office-test.el"
                           (file-name-directory (or load-file-name buffer-file-name))))

(defmacro lispm-office-terminal-test--isolated (&rest body)
  "Run BODY with real Office behavior and terminal cell dimensions."
  (declare (indent 0) (debug t))
  `(lispm-office-test--isolated
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil))
               ((symbol-function 'lispm-ui-tty-p) (lambda (&optional _) t))
               ((symbol-function 'lispm-office--dimensions) (lambda () '(100 . 24))))
       ,@body)))

(ert-deftest lispm-office-terminal-selection-keeps-all-projects-visible ()
  (lispm-office-terminal-test--isolated
    (dolist (record records)
      (setf (plist-get record :status) '(:state blocked :kind permission)))
    (setq waiting-buffers (list source-a source-b))
    (let ((office (lispm-office)))
      (with-current-buffer office
        (should-not (lispm-office--graphic-p))
        (should-not lispm-office--room)
        (lispm-office--select '(codex "b"))
        (dolist (key '((claude "a") (codex "b") (claude "a")))
          (lispm-office-next-waiting)
          (should (equal lispm-office--selected key))
          (should (equal (get-text-property (point) 'lispm-office-key) key))
          (should-not lispm-office--room)
          (should (eq lispm-office--scope 'all))
          (should (string-match-p "alpha  (1 agents)" (buffer-string)))
          (should (string-match-p "beta  (1 agents)" (buffer-string)))
          (should-not lispm-office--timer))))))

(ert-deftest lispm-office-terminal-arrows-follow-text-order-and-stop-at-ends ()
  (lispm-office-terminal-test--isolated
    ;; Interleave roster order across projects, with an extra waits-on line.
    ;; The displayed order is Ada, Cara in alpha, then Bob in beta.
    (let ((cara (copy-tree (car records))))
      (setf (plist-get cara :key) '(claude "c")
            (plist-get cara :name) "Cara"
            (plist-get cara :waits-on) '((codex "b")))
      (setq records (append records (list cara))))
    (let ((office (lispm-office)))
      (with-current-buffer office
        (setq lispm-office--selected nil)
        (lispm-office-down)
        (should (equal lispm-office--selected '(claude "a")))
        (lispm-office-up)
        (should (equal lispm-office--selected '(claude "a")))
        (lispm-office-down)
        (should (equal lispm-office--selected '(claude "c")))
        (should (looking-at "> Cara"))
        (lispm-office-down)
        (should (equal lispm-office--selected '(codex "b")))
        (should (looking-at "> Bob"))
        (lispm-office-down)
        (should (equal lispm-office--selected '(codex "b")))
        (lispm-office-left)
        (should (equal lispm-office--selected '(claude "c")))
        (lispm-office-up)
        (should (equal lispm-office--selected '(claude "a")))
        (lispm-office-right)
        (should (equal lispm-office--selected '(claude "c")))
        (should-not lispm-office--room)))))

(ert-deftest lispm-office-terminal-explicit-room-limits-arrows-but-waiting-can-switch ()
  (lispm-office-terminal-test--isolated
    (setf (plist-get (cadr records) :status) '(:state blocked :kind permission))
    (setq waiting-buffers (list source-b))
    (let ((office (lispm-office)))
      (with-current-buffer office
        (setq lispm-office--room 0)
        (lispm-office--select '(claude "a"))
        (lispm-office-down)
        (should (equal lispm-office--selected '(claude "a")))
        (should (equal lispm-office--room 0))
        (lispm-office-next-waiting)
        (should (equal lispm-office--selected '(codex "b")))
        (should (equal lispm-office--room 1))
        (should (looking-at "> Bob"))
        (should-not (string-match-p "alpha  (1 agents)" (buffer-string)))
        (should (string-match-p "beta  (1 agents)" (buffer-string)))))))

(provide 'lispm-office-terminal-test)
;;; lispm-office-terminal-test.el ends here
