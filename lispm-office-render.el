;;; lispm-office-render.el --- A floor of desks, in pictures or text -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Render an already laid-out roster.  This module never asks agents for
;; data, creates timers, or performs actions.  SVG and hit testing share
;; one projection, including room focus and the maximum image size.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'dom)
(require 'svg)
(require 'lispm-ui-draw)

(defconst lispm-office-render-max-pixels 4096
  "Largest width or height of an Office image in pixels.")

(defvar lispm-office-render--palette nil
  "Palette dynamically bound for one drawing.")

(defvar lispm-office-render--avatars (make-hash-table :test #'equal)
  "Local avatar drawings cached until their roster or palette changes.")

(defvar lispm-office-render--portrait-assignments (make-hash-table :test #'equal)
  "Random portrait indices retained by stable agent key for this Emacs session.")

(defvar lispm-office-render--portrait-pool nil
  "Remaining indices in the current shuffled portrait deck.")

(defconst lispm-office-render--portraits
  [
   (:id side-part :skin "#e9b58e" :hair "#624338" :shirt "#487a9b"
    :pixels [".....OOOOOO....."
             "....OHHhhHHO...."
             "...OHHhhhhHHO..."
             "...OHHHHHHHHHO.."
             "...OHHHHHHHHO..."
             "...OHHHSSHsHO..."
             "...OHSSSSSssO..."
             "..OSSSSSSSssSO.."
             "..OSSESSSSEsSO.."
             "..OSSESSSSEsSO.."
             "...OCSSSSSsCO..."
             "...OSSSssSssO..."
             "...OSssssssSO..."
             ".....OOOOOO....."
             "......ssss......"
             "......SSSS......"])
   (:id teal-bob :skin "#f1c7a3" :hair "#315b63" :shirt "#b56b59"
    :pixels [".....OOOOOO....."
             "....OHhhhHHO...."
             "...OHhhHHHHHO..."
             "..OHHHHHHHHHHO.."
             "..OHHHHHHHHHHO.."
             "..OHHHHSSHHHHO.."
             "..OHHSSSSSsHHO.."
             "..OHSSSSSSssHO.."
             "..OHSESSSSEsHO.."
             "..OHSESSSSEsHO.."
             "..OHCSSSSSsCHO.."
             "..OHSSSssSssHO.."
             "..OHSssssssSHO.."
             "..OOOOOOOOOOOO.."
             "......ssss......"
             "......SSSS......"])
   (:id curls :skin "#9a624b" :hair "#302b38" :shirt "#c29547"
    :pixels ["....OO.OO.OO...."
             "...OHHOHHOHHO..."
             "..OHhHHhHHhHHO.."
             "..OHHHhHHhHHHO.."
             ".OHhHHHHHHHhHHO."
             "..OHHHHHHHHHHO.."
             "..OHHSHHSHHHHO.."
             "..OHSSSSSSssHO.."
             "..OSSESSSSEsSO.."
             "..OSSESSSSEsSO.."
             "...OCSSSSSsCO..."
             "...OSSSssSssO..."
             "...OSssssssSO..."
             ".....OOOOOO....."
             "......ssss......"
             "......SSSS......"])
   (:id ponytail :skin "#f2c1a0" :hair "#c49242" :shirt "#7079ae"
    :pixels [".....OOOOOO....."
             "....OHhhhhHO...."
             "...OHHhhhhHHO..."
             "...OHHHHHHHHHO.."
             "...OHHHHHHHHHO.."
             "...OHHHSSHHHHAA."
             "...OHSSSSSssHHO."
             "..OSSSSSSSssSHO."
             "..OSSESSSSEsSHO."
             "..OSSESSSSEsSHO."
             "...OCSSSSSsCOHO."
             "...OSSSssSssOHO."
             "...OSssssssSOOO."
             ".....OOOOOO....."
             "......ssss......"
             "......SSSS......"])
   (:id auburn-waves :skin "#e8ad88" :hair "#8b453b" :shirt "#4b8790"
    :pixels [".....OOOOOO....."
             "....OHhhhHHO...."
             "...OHhhHHHHHO..."
             "..OHHHHHHHHHHO.."
             "..OHHHHHHHHHHO.."
             "..OHHHHHSHHHHO.."
             "..OHHHSSSSsHHO.."
             "..OHHSSSSSssHO.."
             ".OHHSESSSSEsHHO."
             "..OHSESSSSEsHO.."
             ".OHHCSSSSSsCHHO."
             "..OHSSSssSssHO.."
             ".OHHSssssssSHHO."
             "..OOOOOOOOOOOO.."
             ".OHH..ssss..HHO."
             "..OO..SSSS..OO.."])
   (:id silver-cut :skin "#b97e5b" :hair "#aab5c6" :shirt "#9a6b87"
    :pixels ["....OOOOOOO....."
             "....HhhhhHHO...."
             "...OHHhhhhHHO..."
             "...OHHHHHHHHHO.."
             "...OHHHHHHHHO..."
             "...OHHHSSSssO..."
             "...OHSSSSSshO..."
             "..OSSSSSSSshOO.."
             "..OSSESSSSEsSO.."
             "..OSSESSSSEsSO.."
             "...OCSSSSSsCO..."
             "...OSSSssSssO..."
             "...OSssssssSO..."
             ".....OOOOOO....."
             "......ssss......"
             "......SSSS......"])
   (:id blue-cap :skin "#d79a70" :hair "#443b3c" :shirt "#4c75ac"
    :pixels [".....OOOOOO....."
             "....OAAAAAAO...."
             "...OAaaaAAAAO..."
             "...OAaaAAAAAOO.."
             "...OAAAAAWAAO..."
             "..OAAAAAAAAAAAO."
             "..OOOOOOOOOOOOO."
             "..OSSSSSSSssSO.."
             "..OSSESSSSEsSO.."
             "..OSSESSSSEsSO.."
             "...OCSSSSSsCO..."
             "...OSSSssSssO..."
             "...OSssssssSO..."
             ".....OOOOOO....."
             "......ssss......"
             "......SSSS......"])
   (:id round-glasses :skin "#a86e51" :hair "#403137" :shirt "#6d8b62"
    :pixels [".....OOOOOO....."
             "....OHHhhHHO...."
             "...OHHhhhhHHO..."
             "...OHHHHHHHHHO.."
             "...OHHHHHHHHO..."
             "...OHHHSSHsHO..."
             "...OHSSSSSssO..."
             "..OSSSSSSSssSO.."
             "..OOEEEOOEEEOO.."
             "..OSEWEssEWESO.."
             "...OEEEssEEEO..."
             "...OSSSssSssO..."
             "...OSssssssSO..."
             ".....OOOOOO....."
             "......ssss......"
             "......SSSS......"])
   (:id violet-buns :skin "#edb998" :hair "#6e4f89" :shirt "#c0838a"
    :pixels [".....OOOOOO....."
             "OOOOOHhhhHHOOOOO"
             "OhHOHhhHHHHHOhHO"
             "OHHOHHHHHHHHOHHO"
             "OOOOHHHHHHHHOOOO"
             "..AAHHHSSHHHAA.."
             "..OHHSSSSSsHHO.."
             "..OHSSSSSSssHO.."
             "..OHSESSSSEsHO.."
             "..OHSESSSSEsHO.."
             "..OHCSSSSSsCHO.."
             "....SSSssSss...."
             "....SssssssS...."
             "....OOOOOOOO...."
             "......ssss......"
             "......SSSS......"])
   (:id top-bun :skin "#83533f" :hair "#2e2a37" :shirt "#b9804a"
    :pixels [".....OOOOOO....."
             "....OOHhhHOO...."
             "...OHOHHHHOHO..."
             "...OHAAAAAAHHO.."
             "...OHHHHHHHHO..."
             "...HHHHSSHsHH..."
             "...OHSSSSSsHO..."
             "..OSSSSSSSssSO.."
             "..OSSESSSSEsSO.."
             "..OSSESSSSEsSO.."
             "...OCSSSSSsCO..."
             "...OSSSssSssO..."
             "...OSssssssSO..."
             ".....OOOOOO....."
             "......ssss......"
             "......SSSS......"])
   (:id ginger-beard :skin "#e7b48f" :hair "#a65433" :shirt "#537d68"
    :pixels [".....OOOOOO....."
             "....OHHhhHHO...."
             "...OHHhhhhHHO..."
             "...OHHHHHHHHHO.."
             "...OHHHHHHHHO..."
             "...OHHHSSHsHO..."
             "...OHSSSSSssO..."
             "..OSSSSSSSssSO.."
             "..OSSESSSSEsSO.."
             "..OSSESSSSEsSO.."
             "...OHSSSSSSHO..."
             "...OHhHssHhHO..."
             "...OOHhHHhHOO..."
             ".....OHHHHO....."
             "......OOOO......"
             "......SSSS......"])
   (:id rose-crop :skin "#bd805f" :hair "#b76c83" :shirt "#586f9b"
    :pixels [".....OOOOOO....."
             "....OHHhhHHO...."
             "...HHhhhhhHHO..."
             "...HhhhHHHHHHO.."
             "...HHhHHHHHHO..."
             "...HHHHSSHssO..."
             "...OHSSSSSssO..."
             "..OSSSSSSSssSO.."
             "..OSSESSSSEsSO.."
             "..OSSESSSSEsSO.."
             "...OCSSSSSsCO..."
             "...OSSSssSssO..."
             "...OSssssssSO..."
             ".....OOOOOO....."
             "......ssss......"
             "......SSSS......"])
   (:id cream-wrap :skin "#995f47" :hair "#4b3940" :shirt "#d1ac76"
    :pixels [".....OOOOOO....."
             "....OAAAAAAO...."
             "...OAWAAAAAAO..."
             "..OAAAWAAAAAAO.."
             "..OAAAAWAAAAAO.."
             "..OAAAAAWAAAAO.."
             "..OAAASSSSAAAO.."
             "..OASSSSSSssAO.."
             "..OASESSSSEsAO.."
             "..OASESSSSEsAO.."
             "..OACSSSSSsCAO.."
             "..OASSSssSssAO.."
             "..OASssssssSAO.."
             "...AAAOOOOAAA..."
             "....AAAAAAAA...."
             "...OAAAAAAAAO..."])
   (:id headset :skin "#dca581" :hair "#463e54" :shirt "#608da0"
    :pixels [".....OOOOOO....."
             "....AAAAAAAA...."
             "...AHHhhhhHHA..."
             "..AOHHHHHHHHHA.."
             "..AOHHHHHHHHOA.."
             "..AOHHHSSHsHOA.."
             "..AOHSSSSSssOA.."
             ".OAASSSSSSssSAAO"
             ".OAASESSSSEsSAAO"
             ".OAASESSSSEsSAAO"
             ".OAACSSSSSsCOAAO"
             "...OSSSssSssAA.."
             "...OSsssssAAA..."
             ".....OOOOOO....."
             "......ssss......"
             "......SSSS......"])
   (:id green-beanie :skin "#e8bb99" :hair "#5f493b" :shirt "#6b8864"
    :pixels ["......OOOO......"
             ".....OAAAAO....."
             "....OAAAAAAO...."
             "...OAaAaAaAAO..."
             "...OAaAaAaAAO..."
             "..OAAAAAAAAAAO.."
             "..OAAWAAAAAAAO.."
             "..OOOOOOOOOOOO.."
             "..OSSESSSSEsSO.."
             "..OSSESSSSEsSO.."
             "...OCSSSSSsCO..."
             "...OSSSssSssO..."
             "...OSssssssSO..."
             ".....OOOOOO....."
             "......ssss......"
             "......SSSS......"])
   (:id white-spikes :skin "#c68c67" :hair "#c1c7d3" :shirt "#8a697f"
    :pixels ["....O..O.O......"
             "...OHOOHOHOO...."
             "..OHhHHhHhHHO..."
             "...OHhhhHHHhHO.."
             "..OHHHHHHHHHO..."
             "...OHHSHHSHHO..."
             "...OHSSSSSssO..."
             "..OSSSSSSSssSO.."
             "..OSSESSSSEsSO.."
             "..OSSESSSSEsSO.."
             "...OCSSSSSsCO..."
             "...OSSSssSssO..."
             "...OSssssssSO..."
             ".....OOOOOO....."
             "......ssss......"
             "......SSSS......"])
   ]
  "Sixteen hand-drawn 16 by 16 pixel portraits.
Dots are transparent; O outlines, H/h hair, S/s skin, E eyes, W glints,
A/a accessories and C cheeks.  Colours belong to the sprite, not its provider.")

(defun lispm-office-render-clear-cache ()
  "Forget cached avatar images after a character or palette change."
  (clrhash lispm-office-render--avatars))

(defun lispm-office-render--room (plan room-id)
  "Find ROOM-ID in PLAN, or nil for the overview."
  (and room-id
       (seq-find (lambda (room) (equal room-id (plist-get room :id)))
                 (plist-get plan :rooms))))

(defun lispm-office-render-fit-room (plan room-id width height)
  "Return a responsive copy of PLAN focused on ROOM-ID in WIDTH by HEIGHT.
The result is (:plan DISPLAY-PLAN :scale SCALE), or nil for a missing
room.  WIDTH and HEIGHT are positive drawable pixel dimensions.  Live
desks retain their sizes and stable slot order; only their display
coordinates change.  Other rooms and the caller's persistent geometry
remain intact.  Scale stays between 0.72 and 1.5, with vertical scrolling
when the pane cannot hold readable desks.  A pane narrower than one desk
at minimum scale necessarily also overflows horizontally."
  (when-let* ((room (lispm-office-render--room plan room-id)))
    (dolist (dimension (list width height))
      (unless (and (numberp dimension) (> dimension 0) (< dimension 1.0e6))
        (signal 'wrong-type-argument (list 'positive-finite-number dimension))))
    (let* ((nodes (cl-stable-sort (copy-tree (plist-get room :nodes))
                                  (lambda (left right)
                                    (< (or (plist-get left :slot) 0)
                                       (or (plist-get right :slot) 0)))))
           (count (max 1 (length nodes)))
           (desk-width (apply #'max 90 (mapcar (lambda (node) (plist-get node :width)) nodes)))
           (desk-height (apply #'max 80 (mapcar (lambda (node) (plist-get node :height)) nodes)))
           (pixels-wide (max (float width) (* 0.72 desk-width)))
           (padding (min 16.0 (max 0.0 (/ (- (/ pixels-wide 0.72) desk-width) 2))))
           (gap 12.0) (top 44.0) (bottom 16.0)
           (columns 1) (rows count) (best-scale 0.0)
           (packed-width 0.0) (packed-height 0.0))
      ;; Only consider grids whose width fits at the minimum readable scale.
      ;; A short pane adds rows below the viewport instead of hiding desks.
      (dotimes (index count)
        (let* ((cols (1+ index))
               (lines (ceiling count cols))
               (w (+ (* 2 padding) (* cols desk-width) (* (1- cols) gap)))
               (h (+ top bottom (* lines desk-height) (* (1- lines) gap)))
               (fit (min (/ pixels-wide w) (/ (float height) h))))
          (when (and (<= (* w 0.72) (+ pixels-wide 0.001)) (> fit best-scale))
            (setq columns cols rows lines best-scale fit packed-width w packed-height h))))
      (let* ((scale (max 0.72 (min 1.5 best-scale)))
             (world-width (max packed-width (/ pixels-wide scale)))
             (world-height (max packed-height (/ (float height) scale)))
             (cell-width (/ (- world-width (* 2 padding) (* (1- columns) gap)) columns))
             (cell-height (/ (- world-height top bottom (* (1- rows) gap)) rows))
             (display (copy-tree plan))
             (display-room (lispm-office-render--room display room-id))
             (by-key (make-hash-table :test #'equal)))
        (cl-loop for node in nodes for index from 0 do
                 (setf (plist-get node :x)
                       (+ (plist-get room :x) padding
                          (* (% index columns) (+ cell-width gap))
                          (/ (- cell-width (plist-get node :width)) 2))
                       (plist-get node :y)
                       (+ (plist-get room :y) top
                          (* (/ index columns) (+ cell-height gap))
                          (/ (- cell-height (plist-get node :height)) 2)))
                 (puthash (plist-get node :key) node by-key))
        (setf (plist-get display-room :width) world-width
              (plist-get display-room :height) world-height
              (plist-get display-room :nodes) nodes
              (plist-get display-room :responsive) t
              (plist-get display :rooms)
              (mapcar (lambda (item) (if (equal (plist-get item :id) room-id) display-room item))
                      (plist-get display :rooms))
              (plist-get display :nodes)
              (mapcar (lambda (node) (or (gethash (plist-get node :key) by-key) node))
                      (plist-get display :nodes))
              (plist-get display :width)
              (max (or (plist-get display :width) 0) (+ (plist-get room :x) world-width 16))
              (plist-get display :height)
              (max (or (plist-get display :height) 0) (+ (plist-get room :y) world-height 16)))
        (list :plan display :scale scale)))))

(defun lispm-office-render-projection (plan scale &optional room-id)
  "Return the projection of PLAN at SCALE, optionally focusing ROOM-ID.
The result has :x, :y, :width, :height in world units; :scale is the
effective uniform scale, and :pixel-width/:pixel-height the image size.
An unknown ROOM-ID falls back to the overview.  SCALE must be positive.
No image side exceeds `lispm-office-render-max-pixels'."
  (unless (and (numberp scale) (> scale 0) (< scale 1.0e6))
    (signal 'wrong-type-argument (list 'positive-finite-number scale)))
  (let* ((room (lispm-office-render--room plan room-id))
         (x (if room (plist-get room :x) 0))
         (y (if room (plist-get room :y) 0))
         (width (max 1 (or (plist-get (or room plan) :width) 450)))
         (height (max 1 (or (plist-get (or room plan) :height) 454)))
         (actual (min (float scale)
                      (/ (float lispm-office-render-max-pixels) width)
                      (/ (float lispm-office-render-max-pixels) height))))
    (list :x x :y y :width width :height height :scale actual
          :pixel-width (* width actual) :pixel-height (* height actual))))

(defun lispm-office-render--level (scale)
  "Return the semantic view level at SCALE."
  (cond ((>= scale 0.72) 'desk) ((>= scale 0.45) 'floor) (t 'map)))

(defun lispm-office-render--color (name)
  "Return the colour NAME in the drawing palette."
  (plist-get lispm-office-render--palette name))

(defun lispm-office-render--theme-color (attribute fallback)
  "Read a usable default-face ATTRIBUTE, else FALLBACK."
  (let ((value (face-attribute 'default attribute nil t)))
    (if (and (stringp value) (color-defined-p value)) value fallback)))

(defun lispm-office-render--current-palette ()
  "Return the current UI palette, or derive one from the current theme."
  (or lispm-ui-current-palette
      (lispm-ui-derive-palette
       (lispm-office-render--theme-color :background "white")
       (lispm-office-render--theme-color :foreground "black")
       (lispm-office-render--theme-color :foreground "black")
       (let ((accent (face-background 'highlight nil t)))
         (if (and (stringp accent) (color-defined-p accent)) accent "gray")))))

(defun lispm-office-render--label (value &optional width)
  "Make VALUE a single safe label, optionally truncating at WIDTH columns."
  (let ((text (replace-regexp-in-string
               "[[:cntrl:]]" " " (format "%s" (or value "")))))
    (if width (truncate-string-to-width text (max 1 width) nil nil "…") text)))

(defun lispm-office-render--text (svg text x y size color &optional anchor width)
  "Write TEXT on SVG at X/Y, SIZE, COLOR and optional ANCHOR and WIDTH."
  (lispm-ui-svg-label svg (lispm-office-render--label text width) x y color
                      (list :family "monospace" :size size :weight "normal")
                      (or anchor "start")))

(defun lispm-office-render--group (svg class)
  "Add a group of CLASS to SVG and return it."
  (let ((group (list 'g (list (cons 'class class)))))
    (dom-append-child svg group)
    group))

(defun lispm-office-render--state (node)
  "Return NODE's state, preserving unavailable data as unknown."
  (or (plist-get (plist-get node :status) :state) 'unknown))

(defun lispm-office-render--badge (node)
  "Return the short state badge for NODE."
  (pcase (lispm-office-render--state node)
    ('blocked (pcase (plist-get (plist-get node :status) :kind)
                ('permission "!") ('question "?") ('auth "AUTH") (_ "WAIT")))
    ('error "ERR") ('done "OK") (_ nil)))

(defun lispm-office-render--state-color (node)
  "Return a theme-derived colour for NODE's state."
  (lispm-office-render--color
   (pcase (lispm-office-render--state node)
     ('error :alert-dark) ((or 'working 'blocked) :accent)
     ('done :text) (_ :dim))))

(defun lispm-office-render--inside-p (x y rect)
  "Return non-nil if world point X/Y is inside RECT, excluding far edges."
  (and (>= x (plist-get rect :x)) (>= y (plist-get rect :y))
       (< x (+ (plist-get rect :x) (plist-get rect :width)))
       (< y (+ (plist-get rect :y) (plist-get rect :height)))))

(defun lispm-office-render-hit-test (plan x y scale &optional room-id)
  "Identify pixel X/Y in PLAN at SCALE, optionally focused on ROOM-ID.
Return (:key KEY) for a desk, (:room ID) for a map tile, or nil.
Coordinates are relative to the displayed image's top left."
  (let* ((projection (lispm-office-render-projection plan scale room-id))
         (actual (plist-get projection :scale))
         (room (lispm-office-render--room plan room-id)))
    (when (and (numberp x) (numberp y) (>= x 0) (>= y 0)
               (< x (plist-get projection :pixel-width))
               (< y (plist-get projection :pixel-height)))
      (let* ((wx (+ (plist-get projection :x) (/ x actual)))
             (wy (+ (plist-get projection :y) (/ y actual)))
             (map-p (eq (lispm-office-render--level actual) 'map))
             (target
              (seq-find
               (lambda (item)
                 (and (or (null room)
                          (equal (plist-get room :id)
                                 (plist-get item (if map-p :id :room))))
                      (lispm-office-render--inside-p wx wy item)))
               (plist-get plan (if map-p :rooms :nodes)))))
        (when target
          (if map-p (list :room (plist-get target :id))
            (list :key (plist-get target :key))))))))

(defun lispm-office-render--room-drawing (svg room selected level scale)
  "Draw ROOM on SVG, using SELECTED, LEVEL and SCALE."
  (let* ((group (lispm-office-render--group svg "office-room"))
         (x (plist-get room :x)) (y (plist-get room :y))
         (w (plist-get room :width)) (h (plist-get room :height))
         (nodes (plist-get room :nodes))
         (selected-p (seq-some (lambda (node) (equal selected (plist-get node :key))) nodes))
         (blocked (seq-count (lambda (node)
                               (memq (lispm-office-render--state node) '(blocked error))) nodes))
         (ink (lispm-office-render--color :text))
         (dim (lispm-office-render--color :dim)))
    (lispm-ui-svg-fill group (+ x 5) (+ y 5) (- w 10) (- h 10)
                       (lispm-office-render--color :content))
    (lispm-ui-svg-edges group (+ x 5) (+ y 5) (- w 10) (- h 10)
                        (list (lispm-office-render--color :light))
                        (list (lispm-office-render--color :shade)))
    (if (eq level 'map)
        (let* ((responsive (plist-get room :responsive))
               (font (min 42 (/ 12 scale) (if responsive (/ h 8) 42))))
          (lispm-ui-svg-fill group (+ x 15) (+ y 15) (- w 30)
                             (if responsive (* h 0.25) 80)
                             (lispm-office-render--color :header))
          (lispm-office-render--text group (plist-get room :label)
                                     (+ x 30) (+ y (if responsive (* h 0.22) 70)) font ink nil
                                     (floor (/ (- w 60) (* font 0.62))))
          (lispm-office-render--text group (format "%d" (length nodes))
                                     (+ x (/ w 2)) (+ y (if responsive (* h 0.52) 220))
                                     (min 100 (/ 26 scale) (if responsive (* h 0.2) 100)) ink "middle")
          (lispm-office-render--text group "agents" (+ x (/ w 2)) (+ y (if responsive (* h 0.72) 285))
                                     font dim "middle")
          (when (> blocked 0)
            (lispm-office-render--text group (format "%d waiting" blocked)
                                       (+ x (/ w 2)) (+ y (if responsive (* h 0.9) 360)) font
                                       (lispm-office-render--color :accent) "middle")))
      (lispm-ui-svg-fill group (+ x 10) (+ y 10) (- w 20) 28
                         (lispm-office-render--color :header))
      (lispm-office-render--text group (plist-get room :label) (+ x 20) (+ y 29)
                                 13 ink nil (max 1 (floor (/ (- w 60) 8))))
      (lispm-office-render--text group (format "%d" (length nodes)) (+ x w -20) (+ y 29)
                                 12 dim "end")
      ;; Responsive rooms contain only the occupied grid.  The canonical
      ;; four-pod mats would paint empty seats beyond a short room's floor.
      (unless (plist-get room :responsive)
        (dotimes (pod 4)
          (let ((px (+ x 15 (* (% pod 2) 210)))
                (py (+ y 48 (* (/ pod 2) 193))))
            (lispm-ui-svg-fill group px py 200 180
                               (lispm-ui-blend (lispm-office-render--color :content)
                                              (lispm-office-render--color :accent) 0.06))))))
    (when selected-p
      (svg-rectangle group (+ x 7) (+ y 7) (- w 14) (- h 14)
                     :fill "none" :stroke (lispm-office-render--color :focus)
                     :stroke-width (max 2 (/ 2 scale))))))

(defun lispm-office-render--read-avatar (avatar)
  "Read local AVATAR as a small SVG, or return nil when unsupported."
  (when (and (not (file-remote-p avatar)) (file-regular-p avatar)
             (file-readable-p avatar)
             (< (file-attribute-size (file-attributes avatar)) (* 2 1024 1024)))
    (condition-case nil
        (let ((svg (svg-create 18 18))
              (extension (downcase (or (file-name-extension avatar) ""))))
          (cond
           ((equal extension "svg")
            (when-let* ((dom (lispm-ui-svg-dom avatar)))
              (lispm-ui-svg-embed svg dom 0 0 18 18)
              svg))
           ((member extension '("png" "jpg" "jpeg" "gif"))
            (svg-embed svg avatar
                       (if (member extension '("jpg" "jpeg")) "image/jpeg"
                         (concat "image/" extension))
                       nil :x 0 :y 0 :width 18 :height 18)
            svg)))
      (error nil))))

(defun lispm-office-render--avatar (svg avatar x y &optional size)
  "Draw local AVATAR at X/Y, returning non-nil on success.
SIZE defaults to 18 pixels.
The first draw caches local image data; animation frames never read the
file again.  Remote paths are ignored without opening a connection."
  (when (stringp avatar)
    (let ((cached (gethash avatar lispm-office-render--avatars 'unread)))
      (when (eq cached 'unread)
        (when (> (hash-table-count lispm-office-render--avatars) 128)
          (clrhash lispm-office-render--avatars))
        (setq cached (lispm-office-render--read-avatar avatar))
        (puthash avatar cached lispm-office-render--avatars))
      (when cached
        (lispm-ui-svg-embed svg cached x y (or size 18) (or size 18))
        t))))

(defun lispm-office-render--portrait-index (node)
  "Return NODE's random portrait index, retaining its stable identity.
A shuffled deck gives the first sixteen new identities different portraits.
Redrawing, renaming, filtering and clearing image caches never reshuffle an
existing identity.  The assignments last for the current Emacs session."
  (let* ((key (plist-get node :key))
         (known (gethash key lispm-office-render--portrait-assignments)))
    (or known
        (progn
          (unless lispm-office-render--portrait-pool
            (let* ((count (length lispm-office-render--portraits))
                   (deck (vconcat (number-sequence 0 (1- count)))))
              (cl-loop for i downfrom (1- count) above 0 do
                       (let* ((j (random (1+ i))) (value (aref deck i)))
                         (aset deck i (aref deck j))
                         (aset deck j value)))
              (setq lispm-office-render--portrait-pool (append deck nil))))
          (let ((index (pop lispm-office-render--portrait-pool)))
            (puthash (copy-tree key) index lispm-office-render--portrait-assignments)
            index)))))

(defun lispm-office-render--pixel-portrait (svg portrait x y &optional pixel-size)
  "Draw PORTRAIT on SVG at X/Y in a crisp pixel grid.
PIXEL-SIZE defaults to two world units.  Adjacent same-colour pixels share
one rectangle; there are no interpolated curves or antialiased outlines."
  (let* ((group (lispm-office-render--group svg "office-pixel-portrait"))
         (size (or pixel-size 2))
         (skin (plist-get portrait :skin))
         (hair (plist-get portrait :hair))
         (shirt (plist-get portrait :shirt))
         (colors (list (cons ?O "#302b3b") (cons ?E "#302b3b")
                       (cons ?H hair) (cons ?h (lispm-ui-blend hair "#fff0cf" 0.23))
                       (cons ?S skin) (cons ?s (lispm-ui-blend skin "#703c42" 0.23))
                       (cons ?C (lispm-ui-blend skin "#c56c66" 0.32))
                       (cons ?W "#fff0d6") (cons ?A shirt)
                       (cons ?a (lispm-ui-blend shirt "#fff0cf" 0.2)))))
    (dom-set-attribute group 'data-portrait (symbol-name (plist-get portrait :id)))
    (dom-set-attribute group 'shape-rendering "crispEdges")
    (cl-loop for row across (plist-get portrait :pixels) for py from 0 do
             (let ((px 0))
               (while (< px (length row))
                 (let* ((pixel (aref row px)) (end (1+ px))
                        (color (cdr (assq pixel colors))))
                   (while (and (< end (length row)) (= pixel (aref row end)))
                     (setq end (1+ end)))
                   (when color
                     (svg-rectangle group (+ x (* px size)) (+ y (* py size))
                                    (* (- end px) size) size :fill color))
                   (setq px end)))))
    group))

(defun lispm-office-render--worker (svg node level phase)
  "Draw NODE's pixel workstation on SVG at LEVEL and PHASE."
  (let* ((working (eq (lispm-office-render--state node) 'working))
         (portrait (aref lispm-office-render--portraits
                         (lispm-office-render--portrait-index node)))
         (skin (plist-get portrait :skin))
         (shirt (plist-get portrait :shirt))
         (shirt-light (lispm-ui-blend shirt "#fff0cf" 0.22))
         (shirt-dark (lispm-ui-blend shirt "#302b3b" 0.3))
         (ink (lispm-office-render--color :text))
         (paper (lispm-office-render--color :content))
         (edge (lispm-ui-blend paper ink 0.38))
         (screen "#303947")
         (hand-step (if (and working (= (% phase 2) 1)) 2 0)))
    (dom-set-attribute svg 'shape-rendering "crispEdges")
    ;; Every part uses the same two-unit grid: chair, shirt, face and hands.
    (svg-rectangle svg 16 64 58 2 :fill ink :opacity 0.1)
    (svg-rectangle svg 32 28 26 28 :fill edge)
    (svg-rectangle svg 30 32 30 20 :fill edge)
    (svg-rectangle svg 32 30 26 22 :fill (lispm-office-render--color :chrome))
    (svg-rectangle svg 32 34 26 20 :fill shirt-dark)
    (svg-rectangle svg 30 36 30 14 :fill shirt)
    (svg-rectangle svg 26 38 8 10 :fill shirt)
    (svg-rectangle svg 56 38 8 10 :fill shirt)
    (svg-rectangle svg 26 38 6 2 :fill shirt-light)
    (svg-rectangle svg 58 38 6 2 :fill shirt-light)
    (svg-rectangle svg 34 34 22 4 :fill shirt-light)
    (svg-rectangle svg 40 32 10 4 :fill skin)
    (unless (and (eq level 'desk)
                 (lispm-office-render--avatar svg (plist-get node :avatar) 30 4 30))
      (lispm-office-render--pixel-portrait svg portrait 29 2))
    ;; A stepped desk with a two-pixel bevel keeps the host UI's palette.
    (svg-rectangle svg 10 54 70 8 :fill edge)
    (svg-rectangle svg 12 54 66 4 :fill (lispm-office-render--color :chrome))
    (svg-rectangle svg 12 54 66 2 :fill (lispm-office-render--color :light))
    (svg-rectangle svg 14 62 4 4 :fill edge)
    (svg-rectangle svg 72 62 4 4 :fill edge)
    (svg-rectangle svg 24 (+ 48 hand-step) 8 4 :fill skin)
    (svg-rectangle svg 58 (- 50 hand-step) 8 4 :fill skin)
    ;; Laptop, typing strokes and cup are pixels too, not smooth vector art.
    (svg-rectangle svg 28 38 34 22 :fill "#302b3b")
    (svg-rectangle svg 30 40 30 16 :fill screen)
    (svg-rectangle svg 30 40 30 2 :fill "#465264")
    (svg-rectangle svg 32 44 2 2 :fill (if working "#c5e2bf" "#8995a6"))
    (svg-rectangle svg 34 46 2 2 :fill (if working "#c5e2bf" "#8995a6"))
    (svg-rectangle svg 32 48 2 2 :fill (if working "#c5e2bf" "#8995a6"))
    (if working
        (progn
          (svg-rectangle svg 40 46 (+ 8 (* 4 (% phase 2))) 2 :fill "#c5e2bf")
          (svg-rectangle svg 40 50 6 2 :fill "#91b6c5")
          (svg-rectangle svg 48 50 6 2 :fill "#7e8fa9"))
      (svg-rectangle svg 40 48 4 2 :fill "#8995a6"))
    (svg-rectangle svg 26 58 38 4 :fill edge)
    (svg-rectangle svg 28 58 34 2 :fill (lispm-office-render--color :chrome))
    (svg-rectangle svg 40 58 10 2 :fill (lispm-office-render--color :light))
    (svg-rectangle svg 14 46 6 8 :fill edge)
    (svg-rectangle svg 16 48 4 4 :fill paper)
    (svg-rectangle svg 20 48 2 4 :fill edge)))

(defun lispm-office-render--desk-label (node)
  "Return a compact name for NODE, preserving native session suffixes."
  (let ((name (or (plist-get node :name) "Agent")))
    (if (string-match "\\`\\([^@]+\\)@.*\\(<[0-9]+>\\)\\'" name)
        (let ((role (match-string 1 name)) (suffix (match-string 2 name)))
          (concat (truncate-string-to-width role (max 1 (- 13 (string-width suffix))) nil nil "…")
                  " " suffix))
      name)))

(defun lispm-office-render--desk (svg node selected level phase scale)
  "Draw NODE's desk on SVG, using SELECTED, LEVEL, PHASE and SCALE."
  (let* ((group (lispm-office-render--group svg "office-desk"))
         (x (plist-get node :x)) (y (plist-get node :y))
         (width (plist-get node :width)) (height (plist-get node :height))
         (ink (lispm-office-render--color :text))
         (dim (lispm-office-render--color :dim))
         (paper (lispm-office-render--color :content))
         (accent (lispm-office-render--state-color node))
         (queued (plist-get (plist-get node :mailbox) :queued))
         (badge (lispm-office-render--badge node)))
    (dom-set-attribute group 'data-state (symbol-name (lispm-office-render--state node)))
    (when (equal selected (plist-get node :key))
      (svg-rectangle group x y width height
                     :fill (lispm-ui-blend paper (lispm-office-render--color :focus) 0.05)
                     :stroke (lispm-office-render--color :focus) :stroke-width 1.2))
    (let ((worker (lispm-office-render--group group "office-worker")))
      (dom-set-attribute worker 'transform (format "translate(%s %s)" x y))
      (lispm-office-render--worker worker node level phase))
    (when (and (numberp queued) (> queued 0))
      (svg-rectangle group (+ x 69) (+ y 34) 17 12
                     :fill paper :stroke dim :stroke-width 0.8)
      (lispm-office-render--text group (format "%s" queued) (+ x 77.5) (+ y 43) 8 ink "middle" 3))
    (when (and badge (or (eq level 'desk) (memq (lispm-office-render--state node) '(blocked error))))
      (let* ((font (if (eq level 'floor) (/ 9 scale) 9))
             (bw (max 16 (+ 8 (* (length badge) font 0.6)))))
        (svg-rectangle group (+ x width (- bw) -3) (+ y 2) bw (+ font 5)
                       :fill paper :stroke accent :stroke-width 0.8)
        (lispm-office-render--text group badge (+ x width (/ (- bw) 2) -3) (+ y 4 font)
                                   font accent "middle")))
    (when (eq level 'desk)
      (lispm-office-render--text group (lispm-office-render--desk-label node)
                                 (+ x (/ width 2)) (+ y height -4) 10 ink "middle" 14)
      (lispm-office-render--text group
                                 (if (plist-get node :app-character) "APP"
                                   (upcase (format "%s" (or (plist-get node :kind) "?"))))
                                 (+ x 4) (+ y 9) 6.5 dim nil 6))))

(defun lispm-office-render--endpoint (endpoint nodes)
  "Find ENDPOINT by stable key or unambiguous name in NODES."
  (when endpoint
    (if (consp endpoint)
        (seq-find (lambda (node) (equal endpoint (plist-get node :key))) nodes)
      (let ((matches (seq-filter
                      (lambda (node) (equal (format "%s" endpoint) (plist-get node :name))) nodes)))
        (and (= (length matches) 1) (car matches))))))

(defun lispm-office-render-visible-events (plan scale room-id events)
  "Return EVENTS whose endpoints are visible in PLAN at SCALE and ROOM-ID."
  (let* ((projection (lispm-office-render-projection plan scale room-id))
         (room (lispm-office-render--room plan room-id))
         (nodes (if room (plist-get room :nodes) (plist-get plan :nodes))))
    (unless (eq (lispm-office-render--level (plist-get projection :scale)) 'map)
      (seq-filter
       (lambda (event)
         (and (memq (plist-get event :type) '(message-queued message-taken message-delivered))
              (lispm-office-render--endpoint (plist-get event :from) nodes)
              (lispm-office-render--endpoint (plist-get event :to) nodes)))
       events))))

(defun lispm-office-render--relations (svg nodes events)
  "Draw wait edges and actual message EVENTS between NODES on SVG."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (node nodes) (puthash (plist-get node :key) node index))
    (dolist (node nodes)
      (dolist (key (plist-get node :waits-on))
        (when-let* ((target (gethash key index)))
          (svg-line svg (+ (plist-get node :x) 43) (+ (plist-get node :y) 48)
                    (+ (plist-get target :x) 43) (+ (plist-get target :y) 48)
                    :class "office-wait" :stroke (lispm-office-render--color :dim)
                    :stroke-width 1 :stroke-dasharray "4 5" :opacity 0.55))))
    (dolist (event events)
      (when (memq (plist-get event :type) '(message-queued message-taken message-delivered))
        (let ((from (lispm-office-render--endpoint (plist-get event :from) nodes))
              (to (lispm-office-render--endpoint (plist-get event :to) nodes))
              (progress (plist-get event :progress)))
          (when (and from to)
            (let* ((p (if (numberp progress) (max 0 (min 1 progress)) 0.5))
                   (x (+ 43 (* (- 1 p) (plist-get from :x)) (* p (plist-get to :x))))
                   (y (+ 28 (* (- 1 p) (plist-get from :y)) (* p (plist-get to :y))))
                   (group (lispm-office-render--group svg "office-envelope")))
              (svg-rectangle group (- x 8) (- y 5) 16 10
                             :fill (lispm-office-render--color :content)
                             :stroke (lispm-office-render--color :accent) :stroke-width 1)
              (svg-polyline group (list (cons (- x 8) (- y 5)) (cons x y)
                                        (cons (+ x 8) (- y 5)))
                            :fill "none" :stroke (lispm-office-render--color :accent)))))))))

(defun lispm-office-render-svg (plan selected scale phase &optional room-id events)
  "Draw PLAN as an SVG DOM, with SELECTED desk, SCALE and animation PHASE.
Focus on ROOM-ID when supplied.  EVENTS are actual roster message events;
an optional :progress from 0 to 1 locates each envelope along its path.
Desk, floor and map views use thresholds 0.72 and 0.45.  The current
LispM UI palette supplies interface colours; pixel portraits retain their
colours."
  (let* ((projection (lispm-office-render-projection plan scale room-id))
         (actual (plist-get projection :scale))
         (level (lispm-office-render--level actual))
         (room (lispm-office-render--room plan room-id))
         (rooms (if room (list room) (plist-get plan :rooms)))
         (nodes (if room (plist-get room :nodes) (plist-get plan :nodes)))
         (lispm-office-render--palette (lispm-office-render--current-palette))
         (svg (svg-create (plist-get projection :pixel-width) (plist-get projection :pixel-height))))
    (dom-set-attribute svg 'viewBox
                       (format "%s %s %s %s" (plist-get projection :x) (plist-get projection :y)
                               (plist-get projection :width) (plist-get projection :height)))
    (dom-set-attribute svg 'preserveAspectRatio "none")
    (dom-set-attribute svg 'data-view (symbol-name level))
    (lispm-ui-svg-fill svg (plist-get projection :x) (plist-get projection :y)
                       (plist-get projection :width) (plist-get projection :height)
                       (lispm-office-render--color :desktop))
    (dolist (item rooms) (lispm-office-render--room-drawing svg item selected level actual))
    (unless (eq level 'map)
      (dolist (node nodes) (lispm-office-render--desk svg node selected level phase actual))
      (lispm-office-render--relations svg nodes events))
    svg))

(defun lispm-office-render-text (plan selected &optional room-id)
  "Insert PLAN as accessible text with SELECTED marked, optionally ROOM-ID.
Desk lines carry `lispm-office-key'; headings carry `lispm-office-room'.
No actions, data reads or timers are performed here."
  (let* ((room (lispm-office-render--room plan room-id))
         (rooms (if room (list room) (plist-get plan :rooms))))
    (dolist (item rooms)
      (insert (propertize
               (format "%s  (%d agents)\n" (lispm-office-render--label (plist-get item :label))
                       (length (plist-get item :nodes)))
               'face 'bold 'lispm-office-room (plist-get item :id)))
      (dolist (node (plist-get item :nodes))
        (let* ((key (plist-get node :key))
               (badge (lispm-office-render--badge node))
               (queued (plist-get (plist-get node :mailbox) :queued))
               (state (lispm-office-render--state node))
               (status (plist-get node :status))
               (text (format "%s %-18s [%s%s] inbox:%s%s\n"
                             (if (equal key selected) ">" " ")
                             (lispm-office-render--label (plist-get node :name) 18)
                             state (if badge (concat " " badge) "")
                             (if (numberp queued) queued "?")
                             (if (plist-get status :msg)
                                 (concat "  " (lispm-office-render--label (plist-get status :msg) 80)) ""))))
          (insert (propertize text 'lispm-office-key key 'lispm-office-room (plist-get item :id)
                              'mouse-face 'highlight 'help-echo "Inspect this agent"
                              'face (and (equal key selected) 'highlight)))
          (when (plist-get node :waits-on)
            (insert (propertize
                     (format "    Waits on: %s\n"
                             (mapconcat
                              (lambda (target)
                                (let ((other (lispm-office-render--endpoint target (plist-get plan :nodes))))
                                  (lispm-office-render--label
                                   (if other (plist-get other :name) (format "%S" target)))))
                              (plist-get node :waits-on) ", "))
                     'lispm-office-key key 'lispm-office-room (plist-get item :id))))))
      (insert "\n"))))

(provide 'lispm-office-render)
;;; lispm-office-render.el ends here
