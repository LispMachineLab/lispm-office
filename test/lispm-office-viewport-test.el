;;; lispm-office-viewport-test.el --- Readable short-window views -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'lispm-office)

(defmacro lispm-office-viewport-test--short-window (&rest body)
  "Run BODY with a real three-agent scene in a 200-pixel drawing area."
  (declare (indent 0) (debug t))
  `(let ((lispm-office-animate nil)
         (lispm-office--buffers nil)
         (lispm-office-inspect--buffers nil)
         (lispm-ui-current-palette
          (lispm-ui-derive-palette "#f4f2e9" "#24251f" "#77796d" "#6363ce")))
     (with-temp-buffer
       (lispm-office-mode)
       (setq lispm-office--demo t
             lispm-office--records
             '((:key (lispm "ada") :name "Ada" :kind lispm :root "/tmp/office-viewport"
                :status (:state working :msg "Inspecting work") :mailbox (:queued 0))
               (:key (claude "grace") :name "Grace" :kind claude :root "/tmp/office-viewport"
                :status (:state idle) :mailbox (:queued 0))
               (:key (codex "alan") :name "Alan" :kind codex :root "/tmp/office-viewport"
                :status (:state idle) :mailbox (:queued 1)))
             lispm-office--state (lispm-office-layout-reconcile nil lispm-office--records)
             lispm-office--plan (lispm-office-layout-plan lispm-office--state lispm-office--records)
             lispm-office--selected '(lispm "ada"))
       (save-window-excursion
         (switch-to-buffer (current-buffer))
         (cl-letf (((symbol-function 'lispm-office--dimensions) (lambda () '(360 . 200))))
           ,@body)))))

(defun lispm-office-viewport-test--desk-position (node plan scale room)
  "Return NODE's center in displayed image coordinates for PLAN/SCALE/ROOM."
  (let* ((projection (lispm-office-render-projection plan scale room))
         (actual (plist-get projection :scale)))
    (cons (* actual (- (+ (plist-get node :x) (/ (plist-get node :width) 2))
                       (plist-get projection :x)))
          (* actual (- (+ (plist-get node :y) (/ (plist-get node :height) 2))
                       (plist-get projection :y))))))

(ert-deftest lispm-office-viewport-focused-fit-keeps-named-clickable-desks ()
  (lispm-office-viewport-test--short-window
    (setq lispm-office--room (plist-get (car (plist-get lispm-office--plan :rooms)) :id))
    (lispm-office--fit-scale)
    (let* ((projection (lispm-office-render-projection
                        lispm-office--plan lispm-office--scale lispm-office--room))
           (svg (lispm-office-render-svg lispm-office--plan lispm-office--selected
                                         lispm-office--scale 0 lispm-office--room)))
      ;; A focused room may scroll in a short window.  It must not turn
      ;; into a room-count tile with no agents or readable agent names.
      (should (>= (plist-get projection :scale) 0.72))
      (should (equal (dom-attr svg 'data-view) "desk"))
      (should (= (length (dom-by-class svg "office-desk")) 3))
      (dolist (node (plist-get lispm-office--plan :nodes))
        (should (string-match-p (regexp-quote (plist-get node :name)) (dom-texts svg)))
        (let ((position (lispm-office-viewport-test--desk-position
                         node lispm-office--plan lispm-office--scale lispm-office--room)))
          (should (equal (lispm-office-render-hit-test
                          lispm-office--plan (car position) (cdr position)
                          lispm-office--scale lispm-office--room)
                         (list :key (plist-get node :key)))))))))

(ert-deftest lispm-office-viewport-map-click-enters-desks-in-short-window ()
  (skip-unless (image-type-available-p 'svg))
  (lispm-office-viewport-test--short-window
    (let* ((room (car (plist-get lispm-office--plan :rooms)))
           (room-id (plist-get room :id))
           (node (car (plist-get lispm-office--plan :nodes)))
           (window (selected-window))
           (inspected nil)
           (position nil))
      (lispm-office--fit-scale)
      (should (< lispm-office--scale 0.45))
      (setq position (lispm-office-viewport-test--desk-position
                      node lispm-office--plan lispm-office--scale nil))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                ((symbol-function 'posn-object-x-y) (lambda (_) position))
                ((symbol-function 'lispm-office-inspect-selected)
                 (lambda (&optional _) (setq inspected lispm-office--selected))))
        (dolist (initial-room (list nil room-id))
          ;; Exercise both initial overview navigation and manually
          ;; zooming a focused room out to its room-count tile.
          (setq lispm-office--room initial-room lispm-office--scale 0.25
                lispm-office--fit nil inspected nil
                position (lispm-office-viewport-test--desk-position
                          node lispm-office--plan lispm-office--scale initial-room))
          (lispm-office-mouse (list 'mouse-1 (list window 1 '(0 . 0) 0)))
          (should (eql lispm-office--room room-id))
          (should (>= lispm-office--scale 0.72))
          (setq position (lispm-office-viewport-test--desk-position
                          node lispm-office--plan lispm-office--scale room-id))
          ;; A second click reaches an agent; it must not re-enter the
          ;; same map tile forever after Fit recomputes the same low scale.
          (lispm-office-mouse (list 'mouse-1 (list window 1 '(0 . 0) 0)))
          (should (equal inspected (plist-get node :key))))))))

(ert-deftest lispm-office-viewport-overview-fit-can-still-show-map ()
  (lispm-office-viewport-test--short-window
    (lispm-office--fit-scale)
    (let ((svg (lispm-office-render-svg lispm-office--plan nil lispm-office--scale 0)))
      (should (equal (dom-attr svg 'data-view) "map"))
      (should (= (length (dom-by-class svg "office-room")) 1))
      (should-not (dom-by-class svg "office-desk")))))

(provide 'lispm-office-viewport-test)
;;; lispm-office-viewport-test.el ends here
