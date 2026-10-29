;;; lispm-office-test.el --- Office lifecycle and integration tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'lispm-office)

;; The mocked roster feature normally supplies these special variables.
(defvar lispm-agents-roster-change-functions nil)
(defvar lispm-directory nil)

(defmacro lispm-office-test--isolated (&rest body)
  "Run BODY with isolated windows, files and mocked public roster APIs.
The Office implementation, renderer, inspector, timers and layout remain
real.  Bind records, source-a, source-b, roster-reads and detail-reads for
the assertions in BODY."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "lispm-office-lifecycle-" t))
          (before-buffers (buffer-list))
          (lispm-directory directory)
          (lispm-office-seat-file (expand-file-name "seats.eld" directory))
          (lispm-office--buffers nil)
          (lispm-office-inspect--buffers nil)
          (lispm-agents-roster-change-functions nil)
          (window-size-change-functions nil)
          (window-state-change-functions nil)
          (lispm-ui-palette-changed-hook nil)
          (lispm-office-frame-interval 60)
          (roster-require (symbol-function 'require))
          (source-a (generate-new-buffer " *Office source A*"))
          (source-b (generate-new-buffer " *Office source B*"))
          (roster-reads 0) (detail-reads nil)
          (waiting-buffers nil)
          (records
           (list (list :key '(claude "a") :name "Ada" :kind 'claude :buffer source-a
                       :root (expand-file-name "alpha/" directory) :alive t
                       :status '(:state idle :msg "Ready") :mailbox '(:queued 0) :actions '(open-chat))
                 (list :key '(codex "b") :name "Bob" :kind 'codex :buffer source-b
                       :root (expand-file-name "beta/" directory) :alive t
                       :status '(:state idle :msg "Ready") :mailbox '(:queued 0) :actions '(open-chat)))))
     (with-current-buffer source-a (setq-local lispm-session-agent nil))
     (with-current-buffer source-b (setq-local lispm-session-agent nil))
     (unwind-protect
         (save-window-excursion
           (when (or (get-buffer "*LispM Office*") (get-buffer "*LispM Office Preview*"))
             (ert-skip "Close existing Office buffers before running lifecycle tests"))
           (cl-letf (((symbol-function 'require)
                      (lambda (feature &optional filename noerror)
                        (if (eq feature 'lispm-agents-roster) t
                          (funcall roster-require feature filename noerror))))
                     ((symbol-function 'lispm-agents-roster)
                      (lambda () (setq roster-reads (1+ roster-reads)) records))
                     ((symbol-function 'lispm-agents-waiting-buffers)
                      (lambda () waiting-buffers))
                     ((symbol-function 'lispm-agents-roster-buffer)
                      (lambda (key)
                        (plist-get (seq-find (lambda (record) (equal key (plist-get record :key))) records)
                                   :buffer)))
                     ((symbol-function 'lispm-agents-props) (lambda (_) nil))
                     ((symbol-function 'lispm-agents-buffer-status)
                      (lambda (buffer)
                        (plist-get (seq-find (lambda (record) (eq buffer (plist-get record :buffer))) records)
                                   :status)))
                     ((symbol-function 'lispm-agents-roster-details)
                      (lambda (key)
                        (push (copy-tree key) detail-reads)
                        '(:work (:turn 1 :pending-calls nil :recent-calls nil :files nil)
                          :mailbox (:handling nil :queued nil)))))
             ,@body))
       (dolist (buffer (seq-difference (buffer-list) before-buffers))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory directory t))))

(defmacro lispm-office-test--graphical (&rest body)
  "Run BODY with a graphical display capability in a batch Emacs.
The actual SVG image implementation is used."
  (declare (indent 0) (debug t))
  `(progn
     (unless (image-type-available-p 'svg) (ert-skip "This Emacs has no SVG support"))
     (let ((lispm-ui-current-palette
            (lispm-ui-derive-palette "#f4f2e9" "#24251f" "#77796d" "#6363ce")))
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
         ,@body))))

(ert-deftest lispm-office-demo-does-not-subscribe-or-save ()
  (lispm-office-test--isolated
    (let ((buffer (lispm-office-demo 12)))
      (should (= roster-reads 0))
      (should-not detail-reads)
      (should-not lispm-agents-roster-change-functions)
      (should-not (file-exists-p lispm-office-seat-file))
      (with-current-buffer buffer
        (should (plist-get (lispm-office-status) :preview))
        (should (= (plist-get (lispm-office-status) :agents) 12))
        (should-error (lispm-office-chat) :type 'user-error)
        (should-error (lispm-office-approve-all-selected) :type 'user-error)
        (should-not lispm-office--timer))
      (lispm-office-demo 40)
      (should (= roster-reads 0))
      (should-not (file-exists-p lispm-office-seat-file)))))

(ert-deftest lispm-office-unavailable-api-explains-dependency ()
  (lispm-office-test--isolated
    (let ((original-require (symbol-function 'require)))
      (cl-letf (((symbol-function 'require)
                 (lambda (feature &optional filename noerror)
                   (if (eq feature 'lispm-agents-roster) nil
                     (funcall original-require feature filename noerror)))))
        (let ((error (should-error (lispm-office) :type 'user-error)))
          (should (string-match-p "roster API" (error-message-string error)))
          (should (string-match-p "Update lispm-agent" (error-message-string error))))))
    (should-not lispm-office--buffers)
    (should-not (file-exists-p lispm-office-seat-file))))

(ert-deftest lispm-office-roster-events-never-fetch-unopened-details ()
  (lispm-office-test--isolated
    (let ((office (lispm-office)))
      (should (= roster-reads 1))
      (should-not detail-reads)
      (setf (plist-get (car records) :status) '(:state working :msg "Editing"))
      (run-hook-with-args 'lispm-agents-roster-change-functions '((claude "a")) '(status) nil)
      (should (= roster-reads 2))
      (should-not detail-reads)
      (with-current-buffer office
        (should (string-match-p "Editing" (buffer-string)))
        (should (= (plist-get (lispm-office-status) :agents) 2)))
      (lispm-office-inspect '(claude "a") 'work office)
      (should (equal detail-reads '((claude "a"))))
      (run-hook-with-args 'lispm-agents-roster-change-functions '((codex "b")) '(work) nil)
      (should (= (length detail-reads) 1))
      (run-hook-with-args 'lispm-agents-roster-change-functions '((claude "a")) '(work) nil)
      (should (= (length detail-reads) 2)))))

(ert-deftest lispm-office-hidden-events-do-not-repaint-and-reveal-refreshes ()
  (lispm-office-test--isolated
    (let* ((office (lispm-office))
           (window (get-buffer-window office))
           (tick (with-current-buffer office (buffer-chars-modified-tick)))
           (other (generate-new-buffer " *Office unrelated*")))
      (set-window-buffer window other)
      (setf (plist-get (car records) :status) '(:state working :msg "Hidden update"))
      (run-hook-with-args 'lispm-agents-roster-change-functions '((claude "a")) '(status) nil)
      (with-current-buffer office
        (should (= tick (buffer-chars-modified-tick)))
        (should lispm-office--dirty)
        (should-not lispm-office--timer))
      (set-window-buffer window office)
      (lispm-office--windows-changed)
      (with-current-buffer office
        (should-not lispm-office--dirty)
        (should (> (buffer-chars-modified-tick) tick))
        (should (string-match-p "Hidden update" (buffer-string)))))))

(ert-deftest lispm-office-hidden-tick-cancels-timer-without-data-or-paint ()
  (lispm-office-test--isolated
    (let* ((office (lispm-office))
           (window (get-buffer-window office))
           (other (generate-new-buffer " *Office hidden*"))
           (tick (with-current-buffer office (buffer-chars-modified-tick)))
           (reads roster-reads)
           timer)
      (with-current-buffer office
        (setq timer (run-at-time 60 60 #'ignore)
              lispm-office--timer timer
              lispm-office--flights (list (list :type 'message-queued :sequence 1 :started (float-time)))))
      (set-window-buffer window other)
      (lispm-office--tick office)
      (with-current-buffer office
        (should-not lispm-office--timer)
        (should-not lispm-office--flights)
        (should (= tick (buffer-chars-modified-tick))))
      (should-not (memq timer timer-list))
      (should (= roster-reads reads))
      (should-not detail-reads))))

(ert-deftest lispm-office-map-and-offscreen-work-do-not-animate ()
  (lispm-office-test--isolated
    (setf (plist-get (car records) :status) '(:state working))
    (let ((office (lispm-office)))
      (with-current-buffer office
        (setq lispm-office--fit nil lispm-office--scale 0.25)
        (lispm-office-test--graphical
          (should-not (lispm-office--animated-p))
          (lispm-office--sync-timer)
          (should-not lispm-office--timer)
          (setq lispm-office--scale 1.0)
          (should (lispm-office--animated-p))
          (lispm-office--sync-timer)
          (should (memq lispm-office--timer timer-list))
          (setq lispm-office--room
                (plist-get (seq-find (lambda (node) (equal (plist-get node :key) '(codex "b")))
                                    (plist-get lispm-office--plan :nodes)) :room))
          (should-not (lispm-office--animated-p))
          (lispm-office--sync-timer)
          (should-not lispm-office--timer))))))

(ert-deftest lispm-office-actual-viewport-scale-controls-animation ()
  (lispm-office-test--isolated
    (setf (plist-get (car records) :status) '(:state working))
    (let ((office (lispm-office)))
      (with-current-buffer office
        (setq lispm-office--fit nil lispm-office--scale 1.0)
        ;; An old reservation can make the global world larger than any image.
        (setq lispm-office--plan (plist-put (copy-tree lispm-office--plan) :height 20000))
        (lispm-office-test--graphical
          (should (< (plist-get (lispm-office-render-projection lispm-office--plan 1.0) :scale) 0.45))
          (should-not (lispm-office--animated-p)))))))

(ert-deftest lispm-office-effective-map-selection-enters-the-room ()
  (lispm-office-test--isolated
    (let ((office (lispm-office)))
      (with-current-buffer office
        (setq lispm-office--fit nil lispm-office--scale 1.0)
        (setq lispm-office--plan (plist-put (copy-tree lispm-office--plan) :height 20000))
        (let ((room (plist-get (seq-find (lambda (node) (equal (plist-get node :key) '(codex "b")))
                                        (plist-get lispm-office--plan :nodes)) :room)))
          (lispm-office--select '(codex "b"))
          (should (equal lispm-office--room room)))))))

(ert-deftest lispm-office-unseen-mail-does-not-start-animation ()
  (lispm-office-test--isolated
    (let ((office (lispm-office)))
      (with-current-buffer office
        (setq lispm-office--fit nil lispm-office--scale 1.0
              lispm-office--room
              (plist-get (seq-find (lambda (node) (equal (plist-get node :key) '(codex "b")))
                                  (plist-get lispm-office--plan :nodes)) :room))
        (lispm-office-test--graphical
          (lispm-office--ingest records '(:events ((:sequence 1 :type message-queued :from "Ada" :to "Ada"))))
          (should-not (lispm-office--animated-p))
          (should-not lispm-office--timer)
          (setq lispm-office--room nil lispm-office--scale 0.2)
          (lispm-office--ingest records '(:events ((:sequence 2 :type message-queued :from "Ada" :to "Bob"))))
          (should-not (lispm-office--animated-p))
          (should-not lispm-office--timer))))))

(ert-deftest lispm-office-closing-via-q-releases-observers-and-inspector ()
  (lispm-office-test--isolated
    (let* ((office (lispm-office))
           (inspector (lispm-office-inspect '(claude "a") 'work office)))
      (should (memq #'lispm-office--changed lispm-agents-roster-change-functions))
      (pop-to-buffer office)
      (call-interactively (key-binding (kbd "q")))
      (should-not (buffer-live-p office))
      (should-not (buffer-live-p inspector))
      (should-not lispm-office--buffers)
      (should-not lispm-office-inspect--buffers)
      (should-not (memq #'lispm-office--changed lispm-agents-roster-change-functions))
      (should-not (memq #'lispm-office--windows-changed window-size-change-functions))
      (should-not (memq #'lispm-office--windows-changed window-state-change-functions))
      (should-not (memq #'lispm-office--palette-changed lispm-ui-palette-changed-hook)))))

(ert-deftest lispm-office-preview-close-keeps-live-observer ()
  (lispm-office-test--isolated
    (let ((office (lispm-office))
          (preview (lispm-office-demo 12)))
      (kill-buffer preview)
      (should (equal lispm-office--buffers (list office)))
      (should (memq #'lispm-office--changed lispm-agents-roster-change-functions))
      (kill-buffer office)
      (should-not lispm-agents-roster-change-functions))))

(ert-deftest lispm-office-selection-and-seats-survive-roster-reordering ()
  (lispm-office-test--isolated
    (let ((office (lispm-office)))
      (with-current-buffer office
        (lispm-office--select '(codex "b"))
        (let ((seats (copy-tree (plist-get lispm-office--state :seats))))
          (setq records (reverse records))
          (lispm-office-refresh)
          (should (equal lispm-office--selected '(codex "b")))
          (should (equal (plist-get lispm-office--state :seats) seats)))
        (setq records (seq-remove (lambda (record) (equal (plist-get record :key) '(codex "b"))) records))
        (lispm-office-refresh)
        (should (equal lispm-office--selected '(claude "a")))))))

(ert-deftest lispm-office-waiting-follows-sidebar-and-cycles ()
  (lispm-office-test--isolated
    (setf (plist-get (car records) :status) '(:state blocked :kind permission)
          (plist-get (cadr records) :status) '(:state error))
    (setq waiting-buffers (list source-b source-a))
    (let ((office (lispm-office)))
      (with-current-buffer office
        (should (equal (mapcar (lambda (record) (plist-get record :buffer)) (lispm-office--waiting))
                       waiting-buffers))
        (setq lispm-office--selected nil)
        (lispm-office-next-waiting)
        (should (equal lispm-office--selected '(codex "b")))
        (lispm-office-next-waiting)
        (should (equal lispm-office--selected '(claude "a")))
        (lispm-office-next-waiting)
        (should (equal lispm-office--selected '(codex "b")))))))

(ert-deftest lispm-office-message-events-animate-once-and-do-not-invent-mail ()
  (lispm-office-test--isolated
    (let ((office (lispm-office))
          (now (float-time))
          (clock (symbol-function 'float-time))
          (event '(:events ((:sequence 1 :type message-queued :from "Ada" :to "Bob")
                            (:sequence 2 :type state-changed :from "Ada" :to "Bob")
                            (:sequence 3 :type message-delivered :from "Bob" :to "Ada")))))
      (with-current-buffer office
        (setq lispm-office--fit nil lispm-office--scale 1.0)
        (lispm-office-test--graphical
          ;; Rendering may take longer than a flight's lifetime under host load.
          ;; Advance the event clock explicitly while preserving time conversion.
          (cl-letf (((symbol-function 'float-time)
                     (lambda (&optional time) (if time (funcall clock time) now))))
            (lispm-office--ingest records event)
            (should (= (length lispm-office--flights) 2))
            (should (equal (sort (mapcar (lambda (flight) (plist-get flight :sequence)) lispm-office--flights) #'<)
                           '(1 3)))
            (lispm-office--ingest records event)
            (should (= (length lispm-office--flights) 2))
            (let ((reads roster-reads))
              (lispm-office--tick office)
              (should (= reads roster-reads))
              (should-not detail-reads))
            (setq now (+ now 2))
            (lispm-office--tick office)
            (should-not lispm-office--flights)
            (should-not lispm-office--timer)))))))

(ert-deftest lispm-office-corrupt-seats-retry-does-not-overwrite ()
  (lispm-office-test--isolated
    (let ((bad "(:version 99 :rooms nil :seats nil)\n"))
      (with-temp-file lispm-office-seat-file (insert bad))
      (dotimes (_ 2)
        (should-error (lispm-office))
        (should (= roster-reads 0))
        (should-not lispm-agents-roster-change-functions)
        (should-not lispm-office--buffers)
        (should (equal (with-temp-buffer (insert-file-contents lispm-office-seat-file) (buffer-string)) bad)))
      (with-temp-file lispm-office-seat-file (prin1 '(:version 1 :rooms nil :seats nil) (current-buffer)))
      (should (buffer-live-p (lispm-office)))
      (should (= roster-reads 1))
      (should (= (length (plist-get (lispm-office-layout-read lispm-office-seat-file) :seats)) 2)))))

(ert-deftest lispm-office-manual-refresh-retries-transient-seat-save ()
  (lispm-office-test--isolated
    (let* ((office (lispm-office))
           (original-write (symbol-function 'lispm-office-layout-write))
           (attempts 0)
           (source-c (generate-new-buffer " *Office source C*")))
      (with-current-buffer source-c (setq-local lispm-session-agent nil))
      (setq records
            (append records
                    (list (list :key '(claude "c") :name "Cora" :kind 'claude :buffer source-c
                                :root (expand-file-name "alpha/" directory) :alive t
                                :status '(:state idle) :mailbox '(:queued 0)))))
      (cl-letf (((symbol-function 'lispm-office-layout-write)
                 (lambda (state file)
                   (setq attempts (1+ attempts))
                   (if (= attempts 1) (signal 'file-error '("Temporary filesystem failure"))
                     (funcall original-write state file)))))
        (run-hook-with-args 'lispm-agents-roster-change-functions '((claude "c")) '(agents) nil)
        (should (= attempts 1))
        (should (= (length (plist-get (lispm-office-layout-read lispm-office-seat-file) :seats)) 2))
        (with-current-buffer office
          (should lispm-office--unsaved)
          (let ((state (copy-tree lispm-office--state))
                (snapshot (copy-tree records)))
            (call-interactively (key-binding (kbd "g")))
            (should (equal records snapshot))
            (should (equal lispm-office--state state)))
          (should-not lispm-office--unsaved))
        (should (= attempts 2))
        (should (= (length (plist-get (lispm-office-layout-read lispm-office-seat-file) :seats)) 3))))))

(ert-deftest lispm-office-text-selection-moves-point-past-view-menu ()
  (lispm-office-test--isolated
    (setf (plist-get (car records) :status) '(:state blocked :kind question)
          (plist-get (cadr records) :status) '(:state blocked :kind permission))
    (setq waiting-buffers (list source-a source-b))
    (let ((office (lispm-office)))
      (with-current-buffer office
        (setq lispm-office--text t lispm-office--fit nil lispm-office--scale 1.0)
        (goto-char (point-min))
        ;; A copied identity exercises equality rather than object identity.
        (lispm-office--select (copy-tree '(codex "b")))
        (should (>= (point) lispm-office--floor-start))
        (should (equal (get-text-property (point) 'lispm-office-key) '(codex "b")))
        (should (string-match-p "> Bob" (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
        (should (= (window-point (get-buffer-window office)) (point))))
      (with-current-buffer office
        (should-not (text-property-not-all (point-min) lispm-office--floor-start
                                          'lispm-office-key nil))
        (should-not (string-match-p "Waiting:"
                                    (buffer-substring-no-properties
                                     (point-min) lispm-office--floor-start)))
        (lispm-office-next-waiting)
        (should (>= (point) lispm-office--floor-start))
        (should (equal (get-text-property (point) 'lispm-office-key) '(claude "a")))))))

(provide 'lispm-office-test)
;;; lispm-office-test.el ends here
