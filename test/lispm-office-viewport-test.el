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
    (let* ((scene (lispm-office--scene-plan))
           (projection (lispm-office-render-projection
                        scene lispm-office--scale lispm-office--room))
           (svg (lispm-office-render-svg scene lispm-office--selected
                                         lispm-office--scale 0 lispm-office--room)))
      ;; A focused room may scroll in a short window.  It must not turn
      ;; into a room-count tile with no agents or readable agent names.
      (should (>= (plist-get projection :scale) 0.72))
      (should (equal (dom-attr svg 'data-view) "desk"))
      (should (= (length (dom-by-class svg "office-desk")) 3))
      (dolist (node (plist-get scene :nodes))
        (should (string-match-p (regexp-quote (plist-get node :name)) (dom-texts svg)))
        (let ((position (lispm-office-viewport-test--desk-position
                         node scene lispm-office--scale lispm-office--room)))
          (should (equal (lispm-office-render-hit-test
                          scene (car position) (cdr position)
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
                lispm-office--fit nil inspected nil)
          (let* ((scene (lispm-office--scene-plan))
                 (display-node (seq-find (lambda (item)
                                           (equal (plist-get item :key) (plist-get node :key)))
                                         (plist-get scene :nodes))))
            (setq position (lispm-office-viewport-test--desk-position
                            display-node scene lispm-office--scale initial-room)))
          (lispm-office-mouse (list 'mouse-1 (list window 1 '(0 . 0) 0)))
          (should (eql lispm-office--room room-id))
          (should (>= lispm-office--scale 0.72))
          (let* ((scene (lispm-office--scene-plan))
                 (display-node (seq-find (lambda (item)
                                           (equal (plist-get item :key) (plist-get node :key)))
                                         (plist-get scene :nodes))))
            (setq position (lispm-office-viewport-test--desk-position
                            display-node scene lispm-office--scale room-id)))
          ;; A second click reaches an agent; it must not re-enter the
          ;; same map tile forever after Fit recomputes the same low scale.
          (lispm-office-mouse (list 'mouse-1 (list window 1 '(0 . 0) 0)))
          (should (equal inspected (plist-get node :key))))))))

(ert-deftest lispm-office-viewport-overview-fit-can-still-show-map ()
  (lispm-office-viewport-test--short-window
    (lispm-office--fit-scale)
    (let ((svg (lispm-office-render-svg (lispm-office--scene-plan) nil lispm-office--scale 0)))
      (should (equal (dom-attr svg 'data-view) "map"))
      (should (= (length (dom-by-class svg "office-room")) 1))
      (should-not (dom-by-class svg "office-desk")))))

(ert-deftest lispm-office-viewport-draw-fills-measured-body-and-resize-keeps-hit-geometry ()
  (skip-unless (image-type-available-p 'svg))
  (let ((dimensions (symbol-function 'lispm-office--dimensions))
        (svg-image (symbol-function 'lispm-ui-svg-image))
        (measure (symbol-function 'window-text-pixel-size))
        (pixels-wide 782) (pixels-high 300)
        (floor-svg nil) (measured-chrome nil) (last-position nil)
        (position nil) (inspected nil) (target-key nil))
    (lispm-office-viewport-test--short-window
      (setq lispm-office--room 0 lispm-office--fit t
            lispm-office--buffers (list (current-buffer)))
      (cl-letf (((symbol-function 'lispm-office--dimensions) dimensions)
                ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                ((symbol-function 'window-body-width)
                 (lambda (&optional _window pixelwise) (if pixelwise pixels-wide (/ pixels-wide 8))))
                ((symbol-function 'window-body-height)
                 (lambda (&optional _window pixelwise) (if pixelwise pixels-high (/ pixels-high 16))))
                ((symbol-function 'window-text-pixel-size)
                 (lambda (&rest arguments)
                   (let ((size (apply measure arguments)))
                     (setq measured-chrome (cdr size))
                     size)))
                ((symbol-function 'lispm-ui-svg-image)
                 (lambda (svg) (setq floor-svg svg) (funcall svg-image svg)))
                ((symbol-function 'posn-object-x-y) (lambda (_) position))
                ((symbol-function 'lispm-office-inspect-selected)
                 (lambda (&optional _) (setq inspected lispm-office--selected))))
        (dolist (width '(782 420))
          (setq pixels-wide width)
          (display-line-numbers-mode 1)
          (if floor-svg (lispm-office--windows-changed) (lispm-office--draw))
          (should-not display-line-numbers-mode)
          (should (> measured-chrome 0))
          (should (< (abs (- (dom-attr floor-svg 'width) pixels-wide)) 0.001))
          (should (< (abs (- (+ (dom-attr floor-svg 'height) measured-chrome) pixels-high)) 0.001))
          (should (get-text-property (1- (point-max)) 'display))
          (should-not (eq (char-before (point-max)) ?\n))
          (let* ((scene (lispm-office--scene-plan))
                 (nodes (plist-get (car (plist-get scene :rooms)) :nodes))
                 (third (nth 2 nodes)))
            (if target-key (should (equal (plist-get third :key) target-key))
              (setq target-key (plist-get third :key)))
            (should (> (plist-get third :x) (plist-get (nth 1 nodes) :x)))
            (setq position (lispm-office-viewport-test--desk-position
                            third scene lispm-office--scale 0))
            (when last-position (should-not (equal position last-position)))
            (setq last-position position inspected nil)
            (lispm-office-mouse (list 'mouse-1 (list (selected-window) lispm-office--floor-start '(0 . 0) 0)))
            (should (equal inspected target-key))))))))

(provide 'lispm-office-viewport-test)
;;; lispm-office-viewport-test.el ends here
