;;; lispm-office-integration-test.el --- Live roster contract tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'lispm-office-inspect)
;; Source dependencies are supplied by LISPM_AGENT.  A package-only
;; checkout may run the isolated tests without the optional integration.
(when (locate-library "lispm-agents-roster")
  (require 'lispm-agents-roster))

(defmacro lispm-office-integration--isolated (&rest body)
  "Run BODY with a real synthetic agent and no external effects.
The runtime objects, roster, inspector and change hooks are real;
model, network, subprocess and permission execution are forbidden."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (featurep 'lispm-agents-roster))
     (let* ((directory (make-temp-file "lispm-office-integration-" t))
            (lispm-directory directory)
            (lispm-agents--archived nil)
            (lispm-agents-defined nil)
            (lispm-agents--session-cache (make-hash-table :test #'equal))
            (lispm-agents-session-lookup-functions nil)
            (lispm-agents-roster-change-functions nil)
            (lispm-agents-roster--timer nil)
            (lispm-agents-roster--keys nil)
            (lispm-agents-roster--fields nil)
            (lispm-agents-roster--events nil)
            (lispm-agents-roster--pending-buffers nil)
            (lispm-agents-roster--all nil)
            (lispm-agents-roster--previous nil)
            (lispm-agents-roster--sequence 0)
            (lispm-collab--requests nil)
            (lispm-office-inspect--buffers nil)
            (source (generate-new-buffer " *Office integration source*"))
            (owner (generate-new-buffer " *Office integration owner*"))
            (key '(lispm "office-integration-session"))
            (agent (lispm-agent--create :name 'office-test :id (cadr key)
                                        :root directory :buffer source :state 'waiting :turn 3
                                        :status "Reviewing a local note"))
            (lispm--agents (list (cons 'office-test agent)))
            (forbidden (lambda (&rest _) (ert-fail "Integration attempted an external effect"))))
       (with-current-buffer source
         (setq-local lispm-session-agent agent)
         (setq-local default-directory (file-name-as-directory directory)))
       (puthash "C1" (list :name "read-file" :status 'ask :turn 3 :input '(:file "note.el"))
                (lispm-agent-pending agent))
       (setf (lispm-agent-entry agent) '(:id "M1" :from "user" :queued "2026-10-29" :text "Inspect note")
             (lispm-agent-inbox agent) '((:id "M2" :from "claude" :reply-to "R1" :text "A follow-up"))
             (lispm-agent-journal agent) '((3 ("edit" :file "note.el"))))
       (unwind-protect
           (cl-letf (((symbol-function 'url-retrieve) forbidden)
                     ((symbol-function 'url-retrieve-synchronously) forbidden)
                     ((symbol-function 'make-network-process) forbidden)
                     ((symbol-function 'make-process) forbidden)
                     ((symbol-function 'start-process) forbidden)
                     ((symbol-function 'lispm--request) forbidden)
                     ((symbol-function 'lispm-resolve) forbidden)
                     ((symbol-function 'lispm-tell) forbidden)
                     ((symbol-function 'lispm-abort) forbidden)
                     ((symbol-function 'lispm-agents-bridge-deliver) forbidden))
             (save-window-excursion ,@body))
         (lispm-office-inspect-close owner)
         (setq lispm-agents-roster-change-functions nil)
         (when (timerp lispm-agents-roster--timer) (cancel-timer lispm-agents-roster--timer))
         (dolist (buffer (list source owner))
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (delete-directory directory t)))))

(ert-deftest lispm-office-integration-roster-details-and-inspector ()
  (lispm-office-integration--isolated
    (let* ((roster (lispm-agents-roster))
           (record (seq-find (lambda (item) (equal key (plist-get item :key))) roster))
           (details (lispm-agents-roster-details key)))
      (should record)
      (should (eq (plist-get record :buffer) source))
      (should (equal (plist-get record :mailbox) '(:handling t :queued 1)))
      (should (eq (plist-get (plist-get record :status) :kind) 'permission))
      (should (= (plist-get (plist-get details :work) :turn) 3))
      (should (equal (plist-get (plist-get details :work) :files) '("note.el")))
      (should (equal (plist-get (car (plist-get (plist-get details :mailbox) :queued)) :from) "claude"))
      (let ((inspector (lispm-office-inspect key 'work owner)))
        (with-current-buffer inspector
          (should (string-match-p "read-file" (buffer-string)))
          (should (string-match-p "note.el" (buffer-string)))
          (lispm-office-inspect--set-tab 'mailbox)
          (should (string-match-p "A follow-up" (buffer-string)))
          (should (string-match-p "Reply to: R1" (buffer-string)))))
      (lispm-office-inspect-close owner)
      (should-not lispm-office-inspect--buffers))))

(ert-deftest lispm-office-integration-real-notification-refreshes-mail ()
  (lispm-office-integration--isolated
    (let* ((inspector (lispm-office-inspect key 'mailbox owner))
           (batches nil)
           (observer (lambda (keys fields event)
                       (push (list keys fields event) batches)
                       (lispm-office-inspect-refresh owner keys))))
      (add-hook 'lispm-agents-roster-change-functions observer)
      (unwind-protect
          (progn
            (setf (lispm-agent-inbox agent)
                  (append (lispm-agent-inbox agent)
                          '((:id "M3" :from "codex" :text "New real hook message"))))
            (lispm-agents-roster-notify agent '(mailbox)
                                       (list :type 'message-queued :id "M3" :to key))
            (lispm-agents-roster--flush)
            (should (= 1 (length batches)))
            (should (member key (caar batches)))
            (should (memq 'mailbox (cadar batches)))
            ;; Batch Emacs may report no visible graphical frame.  The
            ;; same visibility callback that the Office uses catches up.
            (with-current-buffer inspector
              (when lispm-office-inspect--dirty (lispm-office-inspect--draw))
              (should (string-match-p "New real hook message" (buffer-string)))))
        (remove-hook 'lispm-agents-roster-change-functions observer))
      (lispm-office-inspect-close owner)
      (should-not (buffer-live-p inspector))
      (should-not lispm-agents-roster-change-functions)
      (should-not lispm-office-inspect--buffers))))

(provide 'lispm-office-integration-test)
;;; lispm-office-integration-test.el ends here
