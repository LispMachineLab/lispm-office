;;; lispm-office-detail-page-test.el --- Inline property-sheet behavior -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:
;; Exercise real inline pages and controls with isolated live-agent fixtures.
;; No external services, installed packages or user conversations are touched.

;;; Code:

(require 'lispm-office-inline-integration-test
         (expand-file-name "lispm-office-inline-integration-test.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'lispm-agents-work)

(defun lispm-office-detail-page-test--labels ()
  "Return the current page's visible button labels in reading order."
  (let ((button (next-button (point-min))) labels)
    (while button
      (when-let* ((label (button-get button 'lispm-ui-label))) (push label labels))
      (setq button (next-button (button-end button))))
    (nreverse labels)))

(ert-deftest lispm-office-detail-page-identity-matches-scene-and-is-compact ()
  "External identity uses the roster label, with no empty Identity tab."
  (lispm-office-test--isolated
    (cl-letf (((symbol-function 'lispm-ui-tty-p) (lambda (&optional _) t))
              ((symbol-function 'lispm-agents-buffer-label) (lambda (_) "Friendly session")))
      (should (equal (plist-get (lispm-office-inspect--target '(claude "a")) :name)
                     "Friendly session"))
      (with-current-buffer (lispm-office)
        (lispm-office--select '(claude "a") t)
        (let ((labels (lispm-office-detail-page-test--labels)))
          (should (equal (seq-take labels 4)
                         '("‹ Back to Office" "Open Conversation" "Activity" "Messages")))
          (should-not (member "Identity" labels))
          (should-not (member "Stop…" labels)))
        (should (string-match-p "Ada" (buffer-string)))
        (should-not (string-match-p "Office source A" (buffer-string)))
        (should-error (lispm-office-inspect-character) :type 'user-error)
        (should (eq lispm-office-inspect--tab 'work))))))

(ert-deftest lispm-office-detail-page-header-retains-full-activity-as-help ()
  "Long activity stays available without pushing the body below a tall header."
  (with-temp-buffer
    (let ((activity (make-string 150 ?a)))
      (cl-letf (((symbol-function 'lispm-ui-tty-p) (lambda (&optional _) t)))
        (lispm-office-details-header '(:name "Internal")
                                    (list :state 'working :msg activity)
                                    '(:name "Visible name") 40)
        (should (= (count-lines (point-min) (point-max)) 3))
        (should (string-match-p "Visible name" (buffer-string)))
        (should-not (string-match-p "Internal" (buffer-string)))
        (should (cl-loop for position from (point-min) below (point-max)
                         thereis (equal (get-text-property position 'help-echo) activity)))))))

(ert-deftest lispm-office-detail-page-mail-separates-current-and-queued ()
  "A user can distinguish work being handled from future messages and replies."
  (lispm-office-test--isolated
    (cl-letf (((symbol-function 'lispm-ui-tty-p) (lambda (&optional _) t))
              ((symbol-function 'lispm-agents-roster-details)
               (lambda (_)
                 '(:work (:turn 1)
                   :mailbox (:handling (:from "User" :state running :text "Current request")
                             :queued ((:from "Bob" :state queued :reply-to "Request 4"
                                       :text "Next reply")))))))
      (with-current-buffer (lispm-office)
        (lispm-office--select '(claude "a") t)
        (lispm-office-inspect-mailbox)
        (let ((text (buffer-string)))
          (should (string-match-p "Being handled" text))
          (should (string-match-p "Queued · 1" text))
          (should (< (string-match "Current request" text) (string-match "Queued · 1" text)))
          (should (< (string-match "Queued · 1" text) (string-match "Next reply" text)))
          (should (string-match-p "Reply to: Request 4" text)))))))

(ert-deftest lispm-office-detail-page-navigation-resets-but-refresh-preserves-viewport ()
  "Navigation starts at the heading; refreshing the same page keeps its viewport."
  (lispm-office-test--isolated
    (cl-letf (((symbol-function 'lispm-agents-roster-details)
               (lambda (_)
                 (list :work (list :turn 1 :files
                                   (cl-loop for n below 80 collect (format "source/file-%d.el" n)))
                       :mailbox '(:handling nil :queued nil)))))
      (with-current-buffer (lispm-office)
        (lispm-office--select '(claude "a") t)
        (goto-char (point-min))
        (forward-line 40)
        (set-window-start (selected-window) (point) t)
        (let ((position (point)) (start (window-start)))
          (lispm-office-inspect--draw)
          (should (= (point) position))
          (should (= (window-start) start)))
        (lispm-office-inspect-mailbox)
        (should (= (point) (point-min)))
        (should (= (window-start) (point-min)))))))

(ert-deftest lispm-office-detail-page-approval-stays-inline-and-requires-confirmation ()
  "Single and batch requests require a deliberate confirmation in the same page."
  (dolist (all '(nil t))
    (lispm-office-inspect-test--with-work-office
      (with-current-buffer owner (lispm-office-mode))
      (cl-letf (((symbol-function 'lispm-agents-roster-details) (lambda (_) '(:work (:turn 7)))))
        (with-current-buffer (lispm-office-inspect key 'work owner)
          (let ((windows (window-list nil 'nomini)) (buffers (buffer-list)))
            (if all (lispm-office-approve-all key) (lispm-office-approve key "C1"))
            (should lispm-office-inspect--review)
            (should-not approved)
            (should (string-match-p "/tmp/a" (buffer-string)))
            (should (equal (window-list nil 'nomini) windows))
            (should (equal (buffer-list) buffers))
            (should (eq (window-buffer office-window) owner))
            (lispm-office-inspect-review-cancel)
            (should-not lispm-office-inspect--review)
            (should-not approved)
            (if all (lispm-office-approve-all key) (lispm-office-approve key "C1"))
            (lispm-office-inspect-review-confirm)
            (should-not lispm-office-inspect--review)
            (should (equal approved (list (list agent (if all 'all "C1")))))
            (should (equal (window-list nil 'nomini) windows))
            (should (equal (buffer-list) buffers))))))))

(ert-deftest lispm-office-detail-page-review-keeps-snapshot-and-rejects-runtime-changes ()
  "Changed turns, arguments, call identities or pending sets cannot gain approval."
  (dolist (change '(turn input replacement additional))
    (lispm-office-inspect-test--with-work-office
      (with-current-buffer owner (lispm-office-mode))
      (cl-letf (((symbol-function 'lispm-agents-roster-details) (lambda (_) '(:work (:turn 7)))))
        (with-current-buffer (lispm-office-inspect key 'work owner)
          (lispm-office-approve-all key)
          (pcase change
            ('turn (setf (plist-get agent :turn) 8))
            ('input (setf (plist-get (gethash "C1" pending) :input) '(:path "/private/new")))
            ('replacement (puthash "C1" (copy-tree (gethash "C1" pending)) pending))
            ('additional (puthash "C2" (list :status 'ask :turn 7 :name "write-file"
                                            :input '(:path "/private/new")) pending)))
          (lispm-office-inspect--draw)
          (should (string-match-p "/tmp/a" (buffer-string)))
          (should-not (string-match-p "/private/new" (buffer-string)))
          (should-not (member "Approve Action" (lispm-office-detail-page-test--labels)))
          (should-error (lispm-office-inspect-review-confirm) :type 'user-error)
          (should-not approved)
          (lispm-office-inspect-review-cancel)
          (should-not lispm-office-inspect--review))))))

(provide 'lispm-office-detail-page-test)
;;; lispm-office-detail-page-test.el ends here
