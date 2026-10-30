;;; lispm-office-inline-integration-test.el --- Same-page detail lifecycle -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'lispm-office-test
         (expand-file-name "lispm-office-test.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'lispm-office-inspect-test
         (expand-file-name "lispm-office-inspect-test.el"
                           (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest lispm-office-inline-entry-and-back-preserve-scene-and-window ()
  (lispm-office-test--isolated
    (let* ((office (lispm-office))
           (window (selected-window))
           (windows (window-list nil 'nomini))
           (buffers (buffer-list)))
      (with-current-buffer office
        (lispm-office--select '(claude "a"))
        (set-window-start window lispm-office--floor-start t)
        (set-window-hscroll window 2)
        (let ((floor (list lispm-office--selected lispm-office--scope lispm-office--room))
              (position (point)) (start (window-start window))
              (timer (run-at-time 60 60 #'ignore)))
          (setq lispm-office--timer timer)
          (should (eq (lispm-office-inspect-selected) office))
          (should-not lispm-office--timer)
          (should-not (memq timer timer-list))
          (should lispm-office-inspect--inline)
          (should (derived-mode-p 'lispm-office-mode))
          (should (eq (lispm-office-inspect-buffer office) office))
          (should-not (assq office lispm-office-inspect--buffers))
          (should (equal (window-list nil 'nomini) windows))
          (should (equal (buffer-list) buffers))
          (call-interactively (key-binding (kbd "m")))
          (should (eq lispm-office-inspect--tab 'mailbox))
          (call-interactively (key-binding (kbd "q")))
          (should-not lispm-office-inspect--inline)
          (should (eq (window-buffer window) office))
          (should (equal floor (list lispm-office--selected lispm-office--scope lispm-office--room)))
          (should (= (point) position))
          (should (= (window-start window) start))
          (should (= (window-hscroll window) 2))
          (should (eq (key-binding (kbd "RET")) #'lispm-office-inspect-selected)))))))

(ert-deftest lispm-office-inline-callbacks-use-cache-and-pause-floor-animation ()
  (lispm-office-test--isolated
    (let ((office (lispm-office)))
      (with-current-buffer office
        (lispm-office--select '(claude "a") t)
        (let ((reads (length detail-reads))
              (phase lispm-office--phase)
              (timer (run-at-time 60 60 #'ignore)))
          (setq lispm-office--timer timer)
          (cl-letf (((symbol-function 'lispm-office--draw-floor)
                     (lambda () (ert-fail "Details were replaced by the floor")))
                    ((symbol-function 'lispm-office--graphic-p) (lambda () t)))
            (lispm-office--draw)
            (lispm-office--palette-changed)
            (lispm-office--windows-changed)
            (lispm-office--tick office)
            (should (= lispm-office--phase phase))
            (should-not lispm-office--timer)
            (should-not (memq timer timer-list))
            (should (= reads (length detail-reads)))
            (setf (plist-get (cadr records) :status) '(:state working :msg "Unrelated change"))
            (lispm-office--changed '((codex "b")) '(status) nil)
            (should (= reads (length detail-reads)))
            (lispm-office--changed '((claude "a")) '(work) nil)
            (should (= (1+ reads) (length detail-reads)))
            (should lispm-office-inspect--inline)))))))

(ert-deftest lispm-office-inline-selection-follows-live-scope-without-new-pane ()
  (lispm-office-test--isolated
    (let ((office (lispm-office)))
      (with-current-buffer office
        (lispm-office--select '(claude "a") t)
        (setq records (cdr records))
        (lispm-office--changed '((claude "a")) '(alive) nil)
        (should lispm-office-inspect--inline)
        (should (equal lispm-office--selected '(codex "b")))
        (should (equal lispm-office-inspect--key '(codex "b")))
        (should (eq (window-buffer (selected-window)) office))
        (should-not lispm-office-inspect--buffers)))))

(ert-deftest lispm-office-inline-cached-paint-does-not-consume-hidden-refresh ()
  (lispm-office-test--isolated
    (let* ((office (lispm-office)) (window (selected-window)))
      (with-current-buffer office
        (lispm-office--select '(claude "a") t)
        (let ((reads (length detail-reads)))
          (set-window-buffer window source-b)
          (lispm-office--changed '((claude "a")) '(work) nil)
          (should lispm-office-inspect--dirty)
          (should (= reads (length detail-reads)))
          (lispm-office--draw)
          (should lispm-office-inspect--dirty)
          (should (= reads (length detail-reads)))
          (set-window-buffer window office)
          (lispm-office--windows-changed)
          (should-not lispm-office-inspect--dirty)
          (should (= (1+ reads) (length detail-reads))))))))

(ert-deftest lispm-office-inline-resize-only-reflows-cached-details ()
  (lispm-office-test--isolated
    (let ((office (lispm-office)))
      (with-current-buffer office
        (lispm-office--select '(claude "a") t)
        (let ((reads (length detail-reads))
              (width lispm-office-inspect--width))
          (cl-letf (((symbol-function 'lispm-office-inspect--available-width)
                     (lambda () (+ width 10))))
            (lispm-office--windows-changed)
            (should (= lispm-office-inspect--width (+ width 10)))
            (should (= reads (length detail-reads)))
            (should lispm-office-inspect--inline)))))))

(ert-deftest lispm-office-inline-toggle-restores-source-draft-and-releases-observers ()
  (lispm-office-test--isolated
    (switch-to-buffer source-a)
    (insert "Unsent conversation draft")
    (goto-char 8)
    (let ((office (lispm-office)))
      (with-current-buffer office
        (lispm-office--select '(claude "a") t)
        (call-interactively (key-binding (kbd "C-c O")))))
    (should (eq (window-buffer (selected-window)) source-a))
    (should (= (point) 8))
    (should (equal (buffer-string) "Unsent conversation draft"))
    (should-not lispm-office--buffers)
    (should-not lispm-office-inspect--buffers)
    (should-not lispm-agents-roster-change-functions)))

(ert-deftest lispm-office-inline-reopening-work-clears-old-details ()
  (lispm-office-test--isolated
    (let ((office (lispm-office)))
      (with-current-buffer office
        (lispm-office--select '(claude "a") t)
        (should lispm-office-inspect--inline)
        (lispm-office-open-project (plist-get (cadr records) :root))
        (should-not lispm-office-inspect--inline)
        (should (eq lispm-office--scope 'project))
        (should (equal lispm-office--selected '(codex "b")))
        (should-not (lispm-office-inspect-buffer office))))))

(ert-deftest lispm-office-inline-cached-permission-keeps-its-original-turn ()
  (lispm-office-inspect-test--with-work-office
    (with-current-buffer owner (lispm-office-mode))
    (cl-letf (((symbol-function 'lispm-agents-roster-details)
               (lambda (_)
                 '(:work (:turn 7 :pending-calls
                          ((:id "C1" :name "read-file" :status ask :input-summary "Read /tmp/a")))))))
      (with-current-buffer (lispm-office-inspect key 'work owner)
        (should (= (plist-get lispm-office-inspect--model :turn) 7))
        ;; Even reuse of the exact mutable call object with identical id and
        ;; arguments must not let a cached old-turn button approve a new turn.
        (setf (plist-get agent :turn) 8
              (plist-get (gethash "C1" pending) :turn) 8)
        (lispm-office-inspect--draw t)
        (let ((button (next-button (point-min))))
          (while (and button (not (equal (button-get button 'lispm-ui-label) "Review…")))
            (setq button (next-button (button-end button))))
          (should button)
          (should-error (button-activate button) :type 'user-error)
          (should-not approved))))))

(ert-deftest lispm-office-inline-actions-use-shown-collaborator-not-floor-selection ()
  (lispm-office-test--isolated
    (let ((office (lispm-office)) actions)
      (with-current-buffer office
        (lispm-office--select '(claude "a") t)
        ;; Collaboration links open another identity without moving the saved
        ;; floor selection.  Every inherited action must still address B.
        (lispm-office-inspect '(codex "b") 'work office)
        (cl-letf (((symbol-function 'lispm-office-approve)
                   (lambda (key &rest _) (push (list 'approve key) actions)))
                  ((symbol-function 'lispm-office-approve-all)
                   (lambda (key &rest _) (push (list 'approve-all key) actions)))
                  ((symbol-function 'lispm-office-deny)
                   (lambda (key &rest _) (push (list 'deny key) actions)))
                  ((symbol-function 'lispm-office-abort)
                   (lambda (key &rest _) (push (list 'abort key) actions))))
          (dolist (key '("a" "A" "d" "x"))
            (call-interactively (key-binding (kbd key))))
          (should (equal (nreverse actions)
                         '((approve (codex "b")) (approve-all (codex "b"))
                           (deny (codex "b")) (abort (codex "b")))))
          (should (equal lispm-office--selected '(claude "a")))
          (should (equal lispm-office-inspect--key '(codex "b")))
          (setq lispm-office-inspect--key nil)
          (dolist (key '("a" "A" "d" "x"))
            (should-error (call-interactively (key-binding (kbd key))) :type 'user-error)))))))

(ert-deftest lispm-office-inline-navigation-does-not-run-hidden-floor-commands ()
  (lispm-office-test--isolated
    (let ((office (lispm-office)))
      (with-current-buffer office
        (lispm-office--select '(claude "a") t)
        (lispm-office-inspect '(codex "b") 'work office)
        (goto-char (point-min))
        (search-forward "Turn 1")
        (let ((position (point)) (reads (length detail-reads)))
          (call-interactively (key-binding (kbd "C-b")))
          (should (= (point) (1- position)))
          (call-interactively (key-binding (kbd "C-f")))
          (should (= (point) position))
          (should (= reads (length detail-reads)))
          (should (equal lispm-office--selected '(claude "a")))
          (should (equal lispm-office-inspect--key '(codex "b"))))
        (should (eq (key-binding [mouse-1]) #'mouse-set-point))
        (should (eq (key-binding (kbd "n")) #'next-line))
        (let ((floor-commands '(lispm-office-next-waiting lispm-office-zoom-in
                                lispm-office-zoom-out lispm-office-fit lispm-office-session
                                lispm-office-project lispm-office-overview lispm-office-choose-room
                                lispm-office-toggle-text lispm-office-compact)))
          ;; Standard special-mode maps may retain digit/negative-argument
          ;; prefixes; none may fall through to a hidden floor command.
          (dolist (key '("+" "=" "-" "0" "S" "P" "h" "r" "t"))
            (should-not (memq (key-binding (kbd key)) floor-commands)))
          (dolist (command floor-commands)
            (should (eq (command-remapping command) #'undefined))))
        ;; Button-local mouse maps still take precedence over text movement.
        (goto-char (button-start (next-button (point-min))))
        (should (eq (key-binding [mouse-1]) #'ignore))
        (should (eq (key-binding (kbd "RET")) #'lispm-ui-push))
        (call-interactively (key-binding (kbd "RET")))
        (should-not lispm-office-inspect--inline)
        (should (eq (key-binding (kbd "C-f")) #'lispm-office-right))))))

(ert-deftest lispm-office-inline-wrapping-is-local-to-the-detail-buffer ()
  (let ((truncate-partial-width-windows 50))
    (lispm-office-test--isolated
      (let ((unrelated (generate-new-buffer " *Inline unrelated editor*"))
            (office (lispm-office)))
        (with-current-buffer office
          (lispm-office--select '(claude "a") t)
          (should (local-variable-p 'truncate-partial-width-windows))
          (should-not truncate-partial-width-windows)
          (should (= (default-value 'truncate-partial-width-windows) 50))
          (should (= (buffer-local-value 'truncate-partial-width-windows unrelated) 50))
          (lispm-office-inspect-quit)
          (should (= truncate-partial-width-windows 50))
          (should (= (default-value 'truncate-partial-width-windows) 50))
          (should (= (buffer-local-value 'truncate-partial-width-windows unrelated) 50)))))))

(provide 'lispm-office-inline-integration-test)
;;; lispm-office-inline-integration-test.el ends here
