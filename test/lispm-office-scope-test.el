;;; lispm-office-scope-test.el --- Current-session scope boundaries -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'lispm-office)

(defun lispm-office-scope-test--record (id &rest props)
  "Make an idle roster record for ID with PROPS."
  (append (list :key (list 'lispm id) :name id :kind 'lispm :root "/tmp/office-scope/"
                :status '(:state idle) :mailbox '(:queued 0)) props))

(defun lispm-office-scope-test--keys (records)
  "Return RECORDS' sorted session ids."
  (sort (mapcar (lambda (record) (cadr (plist-get record :key))) records) #'string<))

(ert-deftest lispm-office-scope-explicit-family-and-requests-cross-projects ()
  (let* ((a (lispm-office-scope-test--record "a" :parent '(lispm "parent")))
         (child (lispm-office-scope-test--record "child" :parent '(lispm "a")
                                                :waits-on '((claude "peer"))))
         (grandchild (lispm-office-scope-test--record "grandchild" :parent '(lispm "child")
                                                     :request-ids '("R1")))
         (peer (list :key '(claude "peer") :name "peer" :root "/tmp/elsewhere/"))
         (records (list a child grandchild peer
                        (lispm-office-scope-test--record "parent")
                        (lispm-office-scope-test--record "sibling" :parent '(lispm "parent"))
                        (lispm-office-scope-test--record "unrelated")
                        (lispm-office-scope-test--record "peer-child" :parent '(claude "peer"))
                        (lispm-office-scope-test--record "request-peer" :request-ids '("R1")))))
    ;; Child projects and provider kinds do not constrain actual collaboration.
    (setf (plist-get child :root) "/tmp/child-project/")
    (let ((before (copy-tree records)))
      (should (equal (lispm-office-scope-test--keys
                      (lispm-office--session-records records '(lispm "a")))
                     '("a" "child" "grandchild" "peer" "request-peer")))
      (should (equal records before)))))

(ert-deftest lispm-office-scope-waits-are-bidirectional-without-promoting-siblings ()
  (let ((records
         (list (lispm-office-scope-test--record "a" :parent '(lispm "parent"))
               (lispm-office-scope-test--record "parent" :waits-on '((lispm "a")))
               (lispm-office-scope-test--record "sibling" :parent '(lispm "parent"))
               (lispm-office-scope-test--record "upstream" :waited-on-by '((lispm "a")))
               (lispm-office-scope-test--record "next" :waits-on '((lispm "upstream"))))))
    (should (equal (lispm-office-scope-test--keys
                    (lispm-office--session-records records '(lispm "a")))
                   '("a" "next" "parent" "upstream")))))

(ert-deftest lispm-office-scope-cycles-and-missing-identities-terminate ()
  (let ((records
         (list (lispm-office-scope-test--record "a" :parent '(lispm "b") :waits-on '((lispm "b")))
               (lispm-office-scope-test--record "b" :parent '(lispm "a") :waits-on '((lispm "a") (lispm "absent")))
               (list :key nil :name "Starting" :parent '(lispm "a") :root "/tmp/office-scope/")
               (lispm-office-scope-test--record "unrelated"))))
    (should (equal (lispm-office-scope-test--keys
                    (lispm-office--session-records records '(lispm "a"))) '("a" "b")))
    (should-not (lispm-office--session-records records nil))
    (should-not (lispm-office--session-records records '(lispm "absent")))))

(defmacro lispm-office-scope-test--view (&rest body)
  "Run BODY in an isolated scoped view with three cached agents.
SOURCE is A, OTHER is unrelated B in A's project, and C is in another project.
No model, detail, file or network reads are needed to filter the roster."
  (declare (indent 0) (debug t))
  `(let* ((source (generate-new-buffer " *scope source*"))
          (other (generate-new-buffer " *scope other*"))
          (source-key '(lispm "a"))
          (other-key '(lispm "b"))
          (records (list (lispm-office-scope-test--record "a" :buffer source)
                         (lispm-office-scope-test--record "b" :buffer other)
                         (lispm-office-scope-test--record "c")))
          (lispm-office--buffers nil)
          (lispm-office-inspect--buffers nil)
          (lispm-office-animate nil)
          (roster-reads 0))
     (setf (plist-get (nth 2 records) :root) "/tmp/other-scope/"
           (plist-get (nth 1 records) :status) '(:state blocked :kind permission)
           (plist-get (nth 2 records) :status) '(:state working))
     (unwind-protect
         (with-temp-buffer
           (lispm-office-mode)
           (setq lispm-office--scope 'session lispm-office--source-buffer source
                 lispm-office--source-key :unresolved)
           (cl-letf (((symbol-function 'lispm-office--source-p)
                      (lambda (buffer) (memq buffer (list source other))))
                     ((symbol-function 'lispm-office--context-key)
                      (lambda (buffer) (if (eq buffer source) source-key other-key)))
                     ((symbol-function 'lispm-agents-roster)
                      (lambda () (cl-incf roster-reads) records))
                     ((symbol-function 'lispm-agents-waiting-buffers) (lambda () (list other)))
                     ((symbol-function 'lispm-agents-roster-details)
                      (lambda (&rest _) (ert-fail "Scope queried agent details"))))
             (lispm-office--ingest records)
             ,@body))
       (kill-buffer source)
       (kill-buffer other))))

(ert-deftest lispm-office-scope-default-count-waiting-actions-and-animation ()
  (lispm-office-scope-test--view
    (should (equal (lispm-office-scope-test--keys lispm-office--records) '("a")))
    (should (= (length lispm-office--all-records) 3))
    (should (= (length (plist-get lispm-office--state :seats)) 3))
    (should (= (plist-get (lispm-office-status) :agents) 1))
    (should-not (lispm-office--waiting))
    (lispm-office--draw)
    (should (equal (get-text-property (point-min) 'lispm-ui-label) "Session"))
    (setq lispm-office--selected '(lispm "b"))
    (should-error (lispm-office--key) :type 'user-error)
    (setq lispm-office--selected '(lispm "a"))
    (cl-letf (((symbol-function 'lispm-office--graphic-p) (lambda () t)))
      (let ((lispm-office-animate t))
        (should-not (lispm-office--animated-p))))
    (should (= roster-reads 0))))

(ert-deftest lispm-office-scope-cross-project-collaborator-is-in-the-displayed-room ()
  (lispm-office-scope-test--view
    (let ((seats (copy-tree lispm-office--state)))
      (setf (plist-get (car records) :waits-on) '((lispm "c")))
      (lispm-office-refresh)
      (should (equal (lispm-office-scope-test--keys lispm-office--records) '("a" "c")))
      (should (= (length (lispm-office--visible-nodes)) 2))
      (should (= (length (plist-get lispm-office--plan :rooms)) 1))
      (should (equal (plist-get (seq-find (lambda (node) (equal (plist-get node :key) '(lispm "c")))
                                         (plist-get lispm-office--plan :nodes)) :root)
                     "/tmp/other-scope/"))
      (should (equal seats lispm-office--state))
      (should (= roster-reads 1)))))

(ert-deftest lispm-office-scope-unknown-identity-stays-empty-and-can-resolve ()
  (lispm-office-scope-test--view
    (setq source-key nil)
    (lispm-office--focus-source source)
    (should-not lispm-office--records)
    (should-not lispm-office--selected)
    (lispm-office--draw)
    (should (string-match-p "Session is starting…" (buffer-string)))
    (setq source-key '(lispm "not-in-roster"))
    (lispm-office-refresh)
    (should-not lispm-office--records)
    (setq source-key '(lispm "a"))
    (lispm-office-refresh)
    (should (equal (lispm-office-scope-test--keys lispm-office--records) '("a")))))

(ert-deftest lispm-office-scope-explicit-overviews-return-and-source-switch ()
  (lispm-office-scope-test--view
    (let ((seats (copy-tree lispm-office--state)))
      (lispm-office-project)
      (should (eq lispm-office--scope 'project))
      (should (equal (lispm-office-scope-test--keys lispm-office--records) '("a" "b")))
      (lispm-office-overview)
      (should (equal (lispm-office-scope-test--keys lispm-office--records) '("a" "b" "c")))
      (lispm-office-session)
      (should (equal (lispm-office-scope-test--keys lispm-office--records) '("a")))
      (lispm-office-overview)
      (lispm-office--focus-source other)
      (should (eq lispm-office--scope 'session))
      (should (equal lispm-office--selected other-key))
      (should (equal (lispm-office-scope-test--keys lispm-office--records) '("b")))
      (should (equal seats lispm-office--state))
      (should (= roster-reads 0)))))

(ert-deftest lispm-office-scope-settled-request-retargets-inspector-and-removes-flights ()
  (lispm-office-scope-test--view
    (setf (plist-get (car records) :waits-on) '((lispm "c")))
    (lispm-office--ingest records)
    (setq lispm-office--selected '(lispm "c")
          lispm-office--flights (list (list :type 'message-queued :from '(lispm "a")
                                            :to '(lispm "c") :started (float-time))))
    (let ((inspector (generate-new-buffer " *scope inspector*")))
      (unwind-protect
          (progn
            (with-current-buffer inspector
              (setq-local lispm-office-inspect--key '(lispm "c")))
            (push (cons (current-buffer) inspector) lispm-office-inspect--buffers)
            (setf (plist-get (car records) :waits-on) nil)
            (cl-letf (((symbol-function 'lispm-office-inspect--target) (lambda (key &optional _) (list :key key))))
              (lispm-office-refresh))
            (should (equal lispm-office--selected '(lispm "a")))
            (should (equal (buffer-local-value 'lispm-office-inspect--key inspector) '(lispm "a")))
            (should-not lispm-office--flights))
        (setq lispm-office-inspect--buffers nil)
        (kill-buffer inspector)))))

(ert-deftest lispm-office-scope-same-context-preserves-displayed-geometry ()
  (lispm-office-scope-test--view
    (lispm-office--fit-scale)
    (let ((plan lispm-office--plan) (display (lispm-office--scene-plan)))
      (should-not (lispm-office--focus-source source))
      (should (eq plan lispm-office--plan))
      (should (eq display (lispm-office--scene-plan))))))

(ert-deftest lispm-office-scope-same-session-chat-alias-keeps-explicit-overview ()
  (lispm-office-scope-test--view
    (lispm-office-project)
    (setq lispm-office--selected other-key)
    ;; OTHER now stands for the transcript corresponding to SOURCE's chat.
    (setq other-key source-key)
    (should-not (lispm-office--focus-source other))
    (should (eq lispm-office--scope 'project))
    (should (equal lispm-office--selected '(lispm "b")))
    (should (= (length lispm-office--records) 2))))

(ert-deftest lispm-office-scope-new-session-in-same-terminal-returns-to-session ()
  (lispm-office-scope-test--view
    (lispm-office-overview)
    (setq source-key '(lispm "c"))
    (lispm-office--focus-source source)
    (should (eq lispm-office--scope 'session))
    (should (equal (lispm-office-scope-test--keys lispm-office--records) '("c")))))

(ert-deftest lispm-office-scope-compaction-keeps-hidden-live-conversations ()
  (lispm-office-scope-test--view
    (let ((ghost (lispm-office-scope-test--record "old")))
      (setq lispm-office--state (lispm-office-layout-reconcile lispm-office--state (cons ghost records)))
      (should (= (length (plist-get lispm-office--state :seats)) 4))
      (cl-letf (((symbol-function 'lispm-ui-confirm) (lambda (&rest _) t)))
        (lispm-office-compact))
      (should (= (length (plist-get lispm-office--state :seats)) 3))
      (should (equal (lispm-office-scope-test--keys lispm-office--records) '("a")))
      (dolist (key '((lispm "a") (lispm "b") (lispm "c")))
        (should (assoc key (plist-get lispm-office--state :seats)))))))

(provide 'lispm-office-scope-test)
;;; lispm-office-scope-test.el ends here
