;;; lispm-office-focus-test.el --- Focus frame integration -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'lispm-office)
(require 'lispm-core)
(defvar lispm-agents-show-function #'pop-to-buffer)
;; Exercise the real public Focus predicate and keymap without loading the
;; application entrypoint's optional MCP/network integrations in batch tests.
(unless (featurep 'lispm-terminal)
  (let ((original-require (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'lispm) t
                   (funcall original-require feature filename noerror)))))
      (require 'lispm-terminal))))

(ert-deftest lispm-office-focus-shortcuts-follow-the-current-frame ()
  (let ((lispm-terminal-mode t)
        (lispm-terminal--frame (selected-frame))
        (old-map (current-global-map))
        (global (make-sparse-keymap)))
    (unwind-protect
        (progn
          (define-key global (kbd "C-c C-q") #'ignore)
          (use-global-map global)
          (dolist (mode '(lispm-office-mode lispm-office-inspect-mode))
            (with-temp-buffer
              (funcall mode)
              (dolist (key '("C-c C-s" "C-c C-n" "C-c C-p" "C-c C-j" "C-c C-o" "C-c C-q"))
                (should (commandp (key-binding (kbd key)))))
              (should (eq (key-binding (kbd "C-c C-s")) #'lispm-terminal-sessions))
              ;; In ordinary frames and after Focus exits, preserve the user's
              ;; original binding rather than replacing it with a dead prefix.
              (let ((lispm-terminal--frame nil))
                (should (eq (key-binding (kbd "C-c C-q")) #'ignore)))
              (let ((lispm-terminal-mode nil))
                (should (eq (key-binding (kbd "C-c C-q")) #'ignore))))))
      (use-global-map old-map))))

(defmacro lispm-office-focus-test--view (&rest body)
  "Run BODY with a Work listener, a source chat and a dedicated sessions pane."
  (declare (indent 0) (debug t))
  `(let* ((source (generate-new-buffer " *Focus source*"))
          (chat (generate-new-buffer " *Focus target chat*"))
          (owner (generate-new-buffer " *Focus Office*"))
          (sessions (generate-new-buffer " *Focus sessions*"))
          (agent (lispm-agent--create :name 'focus-test :id "focus-test"
                                      :root temporary-file-directory :state 'idle
                                      :buffer source :view chat))
          (lispm-office--buffers nil)
          (lispm-office-inspect--buffers nil)
          (lispm-agents-roster-change-functions nil)
          (window-size-change-functions nil)
          (window-state-change-functions nil)
          (lispm-ui-palette-changed-hook nil)
          (focus t) (shown nil) (keys nil)
          (lispm-agents-show-function
           (lambda (buffer) (setq shown (list 'host buffer)) (switch-to-buffer buffer))))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (switch-to-buffer source)
           (insert "Unsent source draft")
           (with-current-buffer owner (lispm-office-mode))
           (let* ((listener (selected-window))
                  (side (display-buffer-in-side-window
                         sessions '((side . left) (slot . 0) (window-width . 20) (dedicated . t)))))
             (set-window-parameter listener 'mode-line-format 'none)
             (set-window-parameter listener 'tab-line-format 'none)
             (set-window-parameter listener 'lispm-office-source
                                   (list :view owner :buffer source
                                         :point (copy-marker 1) :start (copy-marker 1)
                                         :hscroll 0 :vscroll 0))
             (set-window-buffer listener owner)
             (select-window listener)
             (cl-letf (((symbol-function 'lispm-terminal-p) (lambda (&optional _) focus))
                       ((symbol-function 'lispm-office-inspect--target)
                        (lambda (&rest _) (list :key '(lispm "focus-test") :buffer source :agent agent)))
                       ((symbol-function 'lispm-terminal-show)
                        (lambda (target &optional stay)
                          (setq shown (list 'focus target))
                          (set-window-buffer listener chat)
                          (unless stay (select-window listener))
                          chat))
                       ((symbol-function 'lispm-terminal-keys-mode)
                        (lambda (&optional _) (push (current-buffer) keys)))
                       ((symbol-function 'lispm-agents-show)
                        (lambda (buffer) (funcall lispm-agents-show-function buffer) buffer)))
               ,@body)))
       (dolist (buffer (list owner source chat sessions))
         (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest lispm-office-focus-open-chat-stays-in-listener-and-preserves-panes ()
  (lispm-office-focus-test--view
    ;; A missing native chat must be created by Focus's public show function,
    ;; without using a Desktop display command along the way.
    (setf (lispm-agent-view agent) nil)
    (cl-letf (((symbol-function 'lispm-agent-display-buffer)
               (lambda (_) (ert-fail "Focus navigation escaped through the ordinary host"))))
      (should (eq (lispm-office-open-chat '(lispm "focus-test")) chat)))
    (should (equal shown (list 'focus agent)))
    (should (eq (selected-window) listener))
    (should (eq (window-buffer listener) chat))
    (should (eq (window-buffer side) sessions))
    (should (window-dedicated-p side))
    (should (eq (window-parameter listener 'mode-line-format) 'none))
    (should (eq (window-parameter listener 'tab-line-format) 'none))
    (should (equal (with-current-buffer source (buffer-string)) "Unsent source draft"))
    (should-not (buffer-live-p owner))))

(ert-deftest lispm-office-focus-open-chat-outside-focus-keeps-host-routing ()
  (lispm-office-focus-test--view
    (setq focus nil)
    (should (eq (lispm-office-open-chat '(lispm "focus-test")) chat))
    (should (equal shown (list 'host chat)))
    (should (eq (window-buffer listener) chat))
    (should (eq (window-buffer side) sessions))))

(ert-deftest lispm-office-focus-external-collaborator-uses-existing-listener ()
  (lispm-office-focus-test--view
    (setq agent nil)
    (should (eq (lispm-office-open-chat '(claude "external")) source))
    (should-not shown)
    (should (equal keys (list source)))
    (should (eq (selected-window) listener))
    (should (eq (window-buffer listener) source))
    (should (eq (window-buffer side) sessions))
    (should-not (buffer-live-p owner))))

(ert-deftest lispm-office-focus-navigation-closes-owned-inspector-before-delegating ()
  (dolist (key '("C-c C-n" "C-c C-p" "C-c C-j" "C-c C-o" "C-c C-q"))
    (dolist (from-inspector '(nil t))
      (lispm-office-focus-test--view
        (let* ((inspector (generate-new-buffer " *Focus Inspector*"))
               (lispm-terminal-map (copy-keymap lispm-terminal-map))
               (current-prefix-arg '(4))
               (calls 0))
          (with-current-buffer inspector
            (lispm-office-inspect-mode)
            (setq lispm-office-inspect--owner owner))
          (push (cons owner inspector) lispm-office-inspect--buffers)
          (let ((pane (display-buffer-in-side-window inspector '((side . right) (slot . 0)))))
            (select-window (if from-inspector pane listener))
            (let ((command (key-binding (kbd key))))
              ;; A binding fetched before the native map changes still uses
              ;; the current command exactly once, including its prefix.
              (define-key lispm-terminal-map (kbd key)
                          (lambda ()
                            (interactive)
                            (cl-incf calls)
                            (should (equal current-prefix-arg '(4)))
                            (should-not (buffer-live-p inspector))
                            (should-not (window-live-p pane))
                            (should (eq (window-buffer listener) source))
                            (should-not (window-parameter listener 'lispm-office-source))
                            (set-window-buffer listener chat)
                            (select-window listener)))
              (call-interactively command)))
          (should (= calls 1))
          (should (eq (window-buffer listener) chat))
          (should (eq (window-buffer side) sessions))
          (should (equal (with-current-buffer source (buffer-string)) "Unsent source draft"))
          (should-not (buffer-live-p owner)))))))

(ert-deftest lispm-office-focus-navigation-cancel-keeps-source-and-unrelated-panes ()
  (lispm-office-focus-test--view
    (let ((lispm-terminal-map (copy-keymap lispm-terminal-map)))
      (define-key lispm-terminal-map (kbd "C-c C-j")
                  (lambda () (interactive) (user-error "Cancelled selection")))
      (should-error (call-interactively (key-binding (kbd "C-c C-j"))) :type 'user-error)
      (should (eq (window-buffer listener) source))
      (should (= (window-point listener) 1))
      (should (eq (window-buffer side) sessions))
      (should (equal (with-current-buffer source (buffer-string)) "Unsent source draft"))
      (should-not (buffer-live-p owner)))))

(ert-deftest lispm-office-focus-sessions-key-retains-visible-work ()
  (lispm-office-focus-test--view
    (let ((lispm-terminal-map (copy-keymap lispm-terminal-map)) (calls 0))
      (define-key lispm-terminal-map (kbd "C-c C-s")
                  (lambda () (interactive) (cl-incf calls) (select-window side)))
      (call-interactively (key-binding (kbd "C-c C-s")))
      (should (= calls 1))
      (should (eq (window-buffer listener) owner))
      (should (buffer-live-p owner))
      (should (eq (selected-window) side)))))

(ert-deftest lispm-office-focus-session-list-navigation-closes-stale-inspector ()
  (dolist (command '(lispm-terminal-talk lispm-terminal-peek))
    (lispm-office-focus-test--view
      (let ((inspector (generate-new-buffer " *Focus Inspector*")))
        (with-current-buffer inspector
          (lispm-office-inspect-mode)
          (setq lispm-office-inspect--owner owner))
        (push (cons owner inspector) lispm-office-inspect--buffers)
        (push owner lispm-office--buffers)
        (let ((pane (display-buffer-in-side-window inspector '((side . right) (slot . 0)))))
          (select-window side)
          (funcall command (list :agent agent))
          (lispm-office-inspect-cleanup-windows)
          (should-not (window-live-p pane))
          (should-not (buffer-live-p inspector))
          (should-not (buffer-live-p owner))
          (should-not (window-parameter listener 'lispm-office-source))
          (should (eq (window-buffer listener) chat))
          (should (eq (window-buffer side) sessions))
          (should (eq (selected-window) (if (eq command 'lispm-terminal-peek) side listener)))
          (should (equal (with-current-buffer source (buffer-string)) "Unsent source draft")))))))

(ert-deftest lispm-office-focus-cleanup-preserves-non-focus-inspector ()
  (lispm-office-focus-test--view
    (let ((inspector (generate-new-buffer " *Normal Inspector*")))
      (unwind-protect
          (progn
            (with-current-buffer inspector
              (lispm-office-inspect-mode)
              (setq lispm-office-inspect--owner owner))
            (push (cons owner inspector) lispm-office-inspect--buffers)
            (let ((pane (display-buffer-in-side-window inspector '((side . right) (slot . 0)))))
              (setq focus nil)
              (set-window-buffer listener chat)
              (lispm-office-inspect-cleanup-windows)
              (should (buffer-live-p owner))
              (should (buffer-live-p inspector))
              (should (window-live-p pane))))
        (when (buffer-live-p inspector) (kill-buffer inspector))))))

(provide 'lispm-office-focus-test)
;;; lispm-office-focus-test.el ends here
