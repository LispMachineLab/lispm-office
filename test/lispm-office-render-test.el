;;; lispm-office-render-test.el --- Tests of the Office drawing -*- lexical-binding: t; -*-

(require 'ert)
(require 'lispm-office-render)

(defun lispm-office-render-test--plan ()
  "Return a small drawing fixture with two rooms and three agents."
  (let* ((a '(:key (lispm "a") :name "Ada" :kind lispm :x 20 :y 55 :width 90 :height 80
              :room 0 :slot 0 :status (:state working) :mailbox (:queued 2)
              :waits-on ((claude "b"))))
         (b '(:key (claude "b") :name "Claude" :kind claude :x 120 :y 55 :width 90 :height 80
              :room 0 :slot 1 :status (:state blocked :kind permission) :mailbox (:queued 0)))
         (c '(:key (codex "c") :name "Codex" :kind codex :x 470 :y 55 :width 90 :height 80
              :room 1 :slot 0 :status (:state idle)))
         (rooms (list (list :id 0 :label "Home" :x 0 :y 0 :width 450 :height 454 :nodes (list a b))
                      (list :id 1 :label "Project" :x 450 :y 0 :width 450 :height 454 :nodes (list c)))))
    (copy-tree (list :width 900 :height 454 :rooms rooms :nodes (list a b c)))))

(ert-deftest lispm-office-render-projection-and-hit-test-agree ()
  (let ((plan (lispm-office-render-test--plan)))
    (dolist (scale '(0.45 0.71 0.72 1.0 2.0))
      (should (equal (lispm-office-render-hit-test plan (* 40 scale) (* 80 scale) scale)
                     '(:key (lispm "a")))))
    (should (equal (lispm-office-render-hit-test plan 40 80 1 1) '(:key (codex "c"))))
    (should-not (lispm-office-render-hit-test plan -1 10 1))
    (should-not (lispm-office-render-hit-test plan 900 10 1))
    (should-not (lispm-office-render-hit-test plan 110 80 1))))

(ert-deftest lispm-office-render-map-hits-a-room-not-a-desk ()
  (let* ((plan (lispm-office-render-test--plan))
         (svg (lispm-office-render-svg plan '(lispm "a") 0.25 0)))
    (should (equal (dom-attr svg 'data-view) "map"))
    (should (equal (lispm-office-render-hit-test plan 125 20 0.25) '(:room 1)))
    (should-not (dom-by-class svg "office-desk"))
    (should (= (length (dom-by-class svg "office-room")) 2))))

(ert-deftest lispm-office-render-focus-and-image-cap-agree ()
  (let* ((plan (lispm-office-render-test--plan))
         (projection (lispm-office-render-projection plan 100 1))
         (scale (plist-get projection :scale))
         (svg (lispm-office-render-svg plan nil 100 0 1)))
    (should (<= (dom-attr svg 'width) lispm-office-render-max-pixels))
    (should (<= (dom-attr svg 'height) lispm-office-render-max-pixels))
    (should (equal (dom-attr svg 'viewBox) "450 0 450 454"))
    (should (= (length (dom-by-class svg "office-desk")) 1))
    (should (equal (lispm-office-render-hit-test plan (* 40 scale) (* 80 scale) 100 1)
                   '(:key (codex "c"))))))

(ert-deftest lispm-office-render-rejects-invalid-scale ()
  (dolist (scale '(0 -1 nil "1"))
    (should-error (lispm-office-render-projection nil scale) :type 'wrong-type-argument)))

(ert-deftest lispm-office-render-distinguishes-blocked-kinds ()
  (should (equal (lispm-office-render--badge '(:status (:state blocked :kind permission))) "!"))
  (should (equal (lispm-office-render--badge '(:status (:state blocked :kind question))) "?"))
  (should (equal (lispm-office-render--badge '(:status (:state blocked :kind auth))) "AUTH"))
  (should-not (lispm-office-render--badge '(:status (:state idle)))))

(ert-deftest lispm-office-render-animates-only-working-pose ()
  (let* ((plan (lispm-office-render-test--plan))
         (a (lispm-office-render-svg plan nil 1 0))
         (b (lispm-office-render-svg plan nil 1 1)))
    (should-not (equal a b))
    (setf (plist-get (car (plist-get plan :nodes)) :status) '(:state idle))
    (should (equal (lispm-office-render-svg plan nil 1 0)
                   (lispm-office-render-svg plan nil 1 1)))))

(ert-deftest lispm-office-render-only-actual-message-events-make-envelopes ()
  (let* ((plan (lispm-office-render-test--plan))
         (ordinary (lispm-office-render-svg plan nil 1 0))
         (message (lispm-office-render-svg
                   plan nil 1 0 nil '((:type message-queued :from "Ada" :to "Claude" :progress 0.3))))
         (unknown (lispm-office-render-svg
                   plan nil 1 0 nil '((:type message-queued :from "Nobody" :to "Claude"))))
         (state (lispm-office-render-svg
                 plan nil 1 0 nil '((:type state-changed :from "Ada" :to "Claude")))))
    (should (= (length (dom-by-class ordinary "office-wait")) 1))
    (should-not (dom-by-class ordinary "office-envelope"))
    (should (= (length (dom-by-class message "office-envelope")) 1))
    (should-not (dom-by-class unknown "office-envelope"))
    (should-not (dom-by-class state "office-envelope"))))

(ert-deftest lispm-office-render-labels-do-not-become-markup ()
  (let ((plan (lispm-office-render-test--plan)))
    (setf (plist-get (car (plist-get plan :nodes)) :name) "<script>&bad")
    (let ((svg (lispm-office-render-svg plan nil 1 0)))
      (should-not (dom-by-tag svg 'script))
      (with-temp-buffer
        (svg-print svg)
        (should (string-match-p "&lt;script&gt;&amp;bad" (buffer-string)))))))

(ert-deftest lispm-office-render-text-preserves-identity-and-unknowns ()
  (with-temp-buffer
    (lispm-office-render-text (lispm-office-render-test--plan) '(codex "c"))
    (goto-char (point-min))
    (search-forward "Codex")
    (should (equal (get-text-property (1- (point)) 'lispm-office-key) '(codex "c")))
    (should (equal (get-text-property (1- (point)) 'lispm-office-room) 1))
    (should (string-match-p (regexp-quote "inbox:?") (buffer-string)))
    (should (string-match-p "Waits on: Claude" (buffer-string)))))

(ert-deftest lispm-office-render-is-pure-for-layout-and-events ()
  (let* ((plan (lispm-office-render-test--plan))
         (before (copy-tree plan))
         (events '((:type message-taken :from (lispm "a") :to (claude "b") :progress 0.5)))
         (events-before (copy-tree events)))
    (lispm-office-render-svg plan '(lispm "a") 1 1 nil events)
    (with-temp-buffer (lispm-office-render-text plan '(lispm "a")))
    (should (equal plan before))
    (should (equal events events-before))))

(ert-deftest lispm-office-render-avatar-animation-does-not-read-files ()
  (let ((lispm-office-render--avatars (make-hash-table :test #'equal))
        (reads 0))
    (cl-letf (((symbol-function 'lispm-office-render--read-avatar)
               (lambda (_path) (setq reads (1+ reads)) (svg-create 18 18))))
      (dotimes (_ 3)
        (lispm-office-render--avatar (svg-create 100 100) "/tmp/character.svg" 0 0))
      (should (= reads 1))
      (lispm-office-render-clear-cache)
      (lispm-office-render--avatar (svg-create 100 100) "/tmp/character.svg" 0 0)
      (should (= reads 2)))))

(provide 'lispm-office-render-test)
;;; lispm-office-render-test.el ends here
