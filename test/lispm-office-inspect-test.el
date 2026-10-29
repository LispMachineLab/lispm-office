;;; lispm-office-inspect-test.el --- Inspector and action tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'lispm-office-inspect)

(defmacro lispm-office-inspect-test--with-agent (&rest body)
  "Run BODY with a live agent and mocked public LispM APIs."
  (declare (indent 0) (debug t))
  `(let* ((key '(lispm "session-a"))
          (pending (make-hash-table :test #'equal))
          (agent (list :name 'ada :turn 7 :pending pending))
          (source (generate-new-buffer " *Office test source*"))
          (live source) (approved nil) (denied nil) (sent nil) (stopped nil))
     (with-current-buffer source (setq-local lispm-session-agent agent))
     (puthash "C1" (list :status 'ask :turn 7 :name "read-file" :input '(:path "/tmp/a")) pending)
     (unwind-protect
         (cl-letf (((get 'lispm-agent-pending 'compiler-macro) nil)
                   ((get 'lispm-agent-turn 'compiler-macro) nil)
                   ((get 'lispm-agent-name 'compiler-macro) nil)
                   ((get 'lispm-agent-character 'compiler-macro) nil)
                   ((get 'lispm-agent-model 'compiler-macro) nil)
                   ((symbol-function 'lispm-office-inspect--require) #'ignore)
                   ((symbol-function 'lispm-agents-roster-buffer) (lambda (identity) (and (equal identity key) live)))
                   ((symbol-function 'lispm-agent-turn) (lambda (a) (plist-get a :turn)))
                   ((symbol-function 'lispm-agent-name) (lambda (a) (plist-get a :name)))
                   ((symbol-function 'lispm-agent-pending) (lambda (a) (plist-get a :pending)))
                   ((symbol-function 'lispm-agent-character) (lambda (a) (plist-get a :character)))
                   ((symbol-function 'lispm-agent-model) (lambda (a) (plist-get a :model)))
                   ((symbol-function 'lispm-agents-props) (lambda (_) nil))
                   ((symbol-function 'lispm-agents-buffer-status) (lambda (_) '(:state blocked :kind permission)))
                   ((symbol-function 'lispm-asked) (lambda (call) (or (plist-get call :asking) call)))
                   ((symbol-function 'lispm-waiting-calls)
                    (lambda (a) (let (ids)
                                  (maphash (lambda (id call) (when (eq (plist-get call :status) 'ask) (push id ids)))
                                           (plist-get a :pending))
                                  (sort ids #'string<))))
                   ((symbol-function 'lispm-approve-for) (lambda (a &optional id) (push (list a id) approved)))
                   ((symbol-function 'lispm-approve-all-for) (lambda (a) (push (list a 'all) approved)))
                   ((symbol-function 'lispm-deny-for) (lambda (a reason &optional id) (push (list a id reason) denied)))
                   ((symbol-function 'lispm-abort) (lambda (a) (setq stopped a)))
                   ((symbol-function 'lispm-tell) (lambda (&rest args) (setq sent args))))
           ,@body)
       (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest lispm-office-inspect-approve-exact-call ()
  (lispm-office-inspect-test--with-agent
    (lispm-office-approve key "C1")
    (should (equal approved (list (list agent "C1"))))
    (should-error (lispm-office-approve key "missing") :type 'user-error)))

(ert-deftest lispm-office-inspect-does-not-restart-error-calls ()
  (lispm-office-inspect-test--with-agent
    (setf (plist-get (gethash "C1" pending) :status) 'stopped)
    (should-error (lispm-office-approve key "C1") :type 'user-error)
    (should-not approved)))

(ert-deftest lispm-office-inspect-stale-button-does-not-approve-reused-id ()
  (lispm-office-inspect-test--with-agent
    (let* ((target (lispm-office-inspect--target key))
           (preview (car (lispm-office-inspect--permissions target))))
      (puthash "C1" (copy-tree (gethash "C1" pending)) pending)
      (should-error (lispm-office-inspect--act-preview target 7 preview nil) :type 'user-error)
      (should-not approved))))

(ert-deftest lispm-office-inspect-approve-all-shows-selected-turn ()
  (lispm-office-inspect-test--with-agent
    (let (preview)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (question) (setq preview question) t)))
        (lispm-office-approve-all key))
      (should (string-match-p "ada, turn 7: C1 (read-file)" preview))
      (should (equal approved (list (list agent 'all)))))))

(ert-deftest lispm-office-inspect-approve-all-rejects-later-turn ()
  (lispm-office-inspect-test--with-agent
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) (setf (plist-get agent :turn) 8) t)))
      (should-error (lispm-office-approve-all key) :type 'user-error))
    (should-not approved)))

(ert-deftest lispm-office-inspect-approve-all-rejects-new-permission ()
  (lispm-office-inspect-test--with-agent
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (_) (puthash "C2" (list :status 'ask :turn 7 :name "shell" :input '(:command "new")) pending) t)))
      (should-error (lispm-office-approve-all key) :type 'user-error))
    (should-not approved)))

(ert-deftest lispm-office-inspect-approve-all-rejects-reused-id ()
  (lispm-office-inspect-test--with-agent
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) (puthash "C1" (copy-tree (gethash "C1" pending)) pending) t)))
      (should-error (lispm-office-approve-all key) :type 'user-error))
    (should-not approved)))

(ert-deftest lispm-office-inspect-approve-all-rejects-mutated-input ()
  (lispm-office-inspect-test--with-agent
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (_) (setf (plist-get (gethash "C1" pending) :input) '(:path "/private/new")) t)))
      (should-error (lispm-office-approve-all key) :type 'user-error))
    (should-not approved)))

(ert-deftest lispm-office-inspect-approve-all-rejects-replaced-agent ()
  (lispm-office-inspect-test--with-agent
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (_) (with-current-buffer source (setq-local lispm-session-agent (copy-sequence agent))) t)))
      (should-error (lispm-office-approve-all key) :type 'user-error))
    (should-not approved)))

(ert-deftest lispm-office-inspect-deny-revalidates-after-reason ()
  (lispm-office-inspect-test--with-agent
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (setq live nil) "No")))
      (should-error (lispm-office-deny key "C1") :type 'user-error))
    (should-not denied)))

(ert-deftest lispm-office-inspect-stop-discloses-cleared-queue ()
  (lispm-office-inspect-test--with-agent
    (let (preview)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (text) (setq preview text) t)))
        (lispm-office-abort key))
      (should (string-match-p "clear all its queued inputs" preview))
      (should (eq stopped agent)))))

(ert-deftest lispm-office-inspect-stop-rejects-new-turn ()
  (lispm-office-inspect-test--with-agent
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) (setf (plist-get agent :turn) 8) t)))
      (should-error (lispm-office-abort key) :type 'user-error))
    (should-not stopped)))

(ert-deftest lispm-office-inspect-send-as-user-and-strip-properties ()
  (lispm-office-inspect-test--with-agent
    (lispm-office-send key (propertize "Hello" 'display "Hidden" 'keymap (make-sparse-keymap)))
    (should (equal sent (list agent "Hello" :from "user")))
    (should-not (text-properties-at 0 (cadr sent)))
    (should-error (lispm-office-send key "  \n") :type 'user-error)))

(ert-deftest lispm-office-inspect-terminal-capabilities-and-delivery ()
  (lispm-office-inspect-test--with-agent
    (setq key '(claude "session-a"))
    (with-current-buffer source (setq-local lispm-session-agent nil))
    (should-error (lispm-office-send key "Hi") :type 'user-error)
    (should-error (lispm-office-approve-all key) :type 'user-error)
    (let (delivery)
      (cl-letf (((symbol-function 'lispm-agents-props) (lambda (_) '(:ready ignore)))
                ((symbol-function 'lispm-agents-bridge-deliver) (lambda (&rest args) (setq delivery args))))
        (lispm-office-send key "Hi"))
      (should (equal delivery (list source "Hi" '(:from "user" :text "Hi")))))))

(ert-deftest lispm-office-inspect-mail-is-inert-text ()
  (with-temp-buffer
    (let ((text (propertize "#.(error \"Do not evaluate\")\n<button>" 'display '(eval (error "bad")))))
      (lispm-office-inspect--mail-entry (list :from "user" :text text))
      (should (string-match-p "Do not evaluate" (buffer-string)))
      (should-not (text-property-any (point-min) (point-max) 'display '(eval (error "bad")))))))

(ert-deftest lispm-office-inspect-tabs-read-only-the-selected-details ()
  (lispm-office-inspect-test--with-agent
    (let ((reads nil))
      (cl-letf (((symbol-function 'lispm-agents-roster-details)
                 (lambda (identity)
                   (push identity reads)
                   '(:work (:turn 7 :pending-calls ((:id "C1" :name "read-file" :status ask
                                                       :input-summary "Read /tmp/a"))
                                  :recent-calls ((:id "C0" :name "find-file" :status done))
                                  :files ("/tmp/a"))
                     :mailbox (:handling (:from "user" :text "Current request")
                                         :queued ((:from "claude" :reply-to "R4" :text "Queued note")))))))
        (with-temp-buffer
          (lispm-office-inspect-mode)
          (setq-local lispm-office-inspect--key key)
          (lispm-office-inspect--draw)
          (should (string-match-p "Read /tmp/a" (buffer-string)))
          (should (string-match-p "Files touched this turn" (buffer-string)))
          (should (equal reads (list key)))
          (lispm-office-inspect--set-tab 'mailbox)
          (should (string-match-p "Queued note" (buffer-string)))
          (should (string-match-p "Reply to: R4" (buffer-string)))
          (should (= 2 (length reads)))
          (lispm-office-inspect--set-tab 'character)
          (should (string-match-p "no character identity" (buffer-string)))
          (should (= 2 (length reads))))))))

(ert-deftest lispm-office-inspect-refresh-is-selected-key-only ()
  (let ((owner (generate-new-buffer " *Office owner*"))
        (inspector (generate-new-buffer " *Office inspector*"))
        (draws 0) (lispm-office-inspect--buffers nil))
    (unwind-protect
        (progn
          (setq lispm-office-inspect--buffers (list (cons owner inspector)))
          (with-current-buffer inspector (setq-local lispm-office-inspect--key '(lispm "a")))
          (cl-letf (((symbol-function 'lispm-office-inspect--draw) (lambda () (cl-incf draws)))
                    ((symbol-function 'lispm-office-inspect--visible-p) (lambda () t)))
            (lispm-office-inspect-refresh owner '((lispm "b")))
            (should (= 0 draws))
            (lispm-office-inspect-refresh owner '((lispm "a")))
            (should (= 1 draws))
            (lispm-office-inspect-refresh owner nil)
            (should (= 2 draws))))
      (kill-buffer owner) (kill-buffer inspector))))

(ert-deftest lispm-office-inspect-hidden-refresh-defers-reading ()
  (let ((owner (generate-new-buffer " *Office hidden owner*"))
        (inspector (generate-new-buffer " *Office hidden inspector*"))
        (draws 0) (visible nil) (lispm-office-inspect--buffers nil))
    (unwind-protect
        (progn
          (setq lispm-office-inspect--buffers (list (cons owner inspector)))
          (with-current-buffer inspector (setq-local lispm-office-inspect--key '(lispm "a")))
          (cl-letf (((symbol-function 'lispm-office-inspect--draw)
                     (lambda () (setq lispm-office-inspect--dirty nil) (cl-incf draws)))
                    ((symbol-function 'lispm-office-inspect--visible-p) (lambda () visible)))
            (lispm-office-inspect-refresh owner '((lispm "a")))
            (lispm-office-inspect-refresh owner '((lispm "a")))
            (should (= 0 draws))
            (should (buffer-local-value 'lispm-office-inspect--dirty inspector))
            (lispm-office-inspect-visible-refresh owner)
            (should (= 0 draws))
            (setq visible t)
            (lispm-office-inspect-visible-refresh owner)
            (should (= 1 draws))
            (lispm-office-inspect-visible-refresh owner)
            (should (= 1 draws))))
      (kill-buffer owner) (kill-buffer inspector))))

(ert-deftest lispm-office-inspect-all-preview-contains-full-input ()
  (lispm-office-inspect-test--with-agent
    (let (shown)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (_)
                   (let ((buffer (seq-find (lambda (buffer)
                                             (string-prefix-p "*Office Permission Preview*" (buffer-name buffer)))
                                           (buffer-list))))
                     (setq shown (with-current-buffer buffer (buffer-string))))
                   nil)))
        (lispm-office-approve-all key))
      (should (string-match-p "/tmp/a" shown))
      (should-not approved))))

(ert-deftest lispm-office-inspect-close-does-not-close-another-owner ()
  (let* ((owner-a (generate-new-buffer " *Owner A*"))
         (owner-b (generate-new-buffer " *Owner B*"))
         (inspector-a (generate-new-buffer " *Inspector A*"))
         (inspector-b (generate-new-buffer " *Inspector B*"))
         (lispm-office-inspect--buffers (list (cons owner-a inspector-a) (cons owner-b inspector-b))))
    (unwind-protect
        (progn
          (with-current-buffer inspector-a (lispm-office-inspect-mode))
          (with-current-buffer inspector-b (lispm-office-inspect-mode))
          (lispm-office-inspect-close owner-a)
          (should-not (buffer-live-p inspector-a))
          (should (buffer-live-p inspector-b))
          (should (equal lispm-office-inspect--buffers (list (cons owner-b inspector-b)))))
      (dolist (buffer (list owner-a owner-b inspector-a inspector-b))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'lispm-office-inspect-test)
;;; lispm-office-inspect-test.el ends here
