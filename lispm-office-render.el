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
(require 'xml)
(require 'lispm-ui-draw)
(require 'lispm-office-layout)

(defconst lispm-office-render-max-pixels 4096
  "Largest width or height of an Office image in pixels.")

(defvar lispm-office-render--palette nil
  "Palette dynamically bound for one drawing.")
(defvar lispm-office-render--actor-hits)

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
room.  Compact furniture pods leave shared circulation and coffee space;
spare floor fills the viewport without stretching distances inside pods.
Stable identities, desk sizes and the input PLAN remain unchanged."
  (when-let* ((room (lispm-office-render--room plan room-id)))
    (let* ((packed (lispm-office-layout-fit-room room width height))
           (display-room (plist-get packed :room))
           (nodes (plist-get display-room :nodes))
           (display (copy-tree plan))
           (by-key (make-hash-table :test #'equal)))
      (dolist (node nodes) (puthash (plist-get node :key) node by-key))
      (setf (plist-get display :rooms)
            (mapcar (lambda (item) (if (equal (plist-get item :id) room-id) display-room item))
                    (plist-get display :rooms))
            (plist-get display :nodes)
            (mapcar (lambda (node) (or (gethash (plist-get node :key) by-key) node))
                    (plist-get display :nodes))
            (plist-get display :width)
            (max (or (plist-get display :width) 0)
                 (+ (plist-get room :x) (plist-get display-room :width) 16))
            (plist-get display :height)
            (max (or (plist-get display :height) 0)
                 (+ (plist-get room :y) (plist-get display-room :height) 16)))
      (list :plan display :scale (plist-get packed :scale)))))

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
             (actors (gethash plan lispm-office-render--actor-hits))
             (actor (and (not map-p) (equal (car actors) (list scale room-id))
                         (seq-find (lambda (item) (lispm-office-render--inside-p wx wy item))
                                   (cdr actors))))
             (target
              (or actor (seq-find
               (lambda (item)
                 (and (or (null room)
                          (equal (plist-get room :id)
                                 (plist-get item (if map-p :id :room))))
                      (lispm-office-render--inside-p wx wy item)))
               (plist-get plan (if map-p :rooms :nodes))))))
        (when target
          (if map-p (list :room (plist-get target :id))
            (list :key (plist-get target :key))))))))

(defconst lispm-office-render--room-styles
  [(:id oak :floor "#c5a378" :grain "#ae885f" :wall "#efe3c9" :trim "#786b59" :pattern planks)
   (:id mint :floor "#d7d6bd" :grain "#b9c3a7" :wall "#dfe9d4" :trim "#71816c" :pattern tiles)
   (:id rose :floor "#b58b78" :grain "#947361" :wall "#eddbd5" :trim "#806561" :pattern parquet)
   (:id tatami :floor "#d7c48d" :grain "#b1a16e" :wall "#eee7d4" :trim "#72725a" :pattern tatami)
   (:id library :floor "#a78c70" :grain "#876e56" :wall "#e5d8bc" :trim "#685e4b" :pattern planks)
   (:id apricot :floor "#dfbe94" :grain "#cba47a" :wall "#f0dfc7" :trim "#9b7962" :pattern parquet)
   (:id sage :floor "#a7ad9a" :grain "#939b87" :wall "#e4e6d9" :trim "#667367" :pattern carpet)
   (:id cream :floor "#d9d2bd" :grain "#bdb5a2" :wall "#f2ecdd" :trim "#88806e" :pattern tiles)]
  "Eight pixel office interiors, independent of the interface accent colour.")
(defvar lispm-office-render--room-assignments (make-hash-table :test #'equal)
  "Stable random interior indices for room identities during this Emacs session.")
(defvar lispm-office-render--room-pool nil "Remaining shuffled interior indices.")
(defvar lispm-office-render--visits (make-hash-table :test #'equal)
  "Start times of explicit collaboration visits, indexed by both agent keys.")
(defvar lispm-office-render--actor-hits (make-hash-table :test #'eq :weakness 'key)
  "Visible actor rectangles indexed by their immutable display plan.")

(defun lispm-office-render--room-style (room)
  "Return ROOM's stable, randomly assigned interior."
  (let* ((key (list (plist-get room :root) (plist-get room :id)))
         (index (gethash key lispm-office-render--room-assignments)))
    (unless index
      (unless lispm-office-render--room-pool
        (let ((deck (vconcat (number-sequence 0 (1- (length lispm-office-render--room-styles))))))
          (cl-loop for i downfrom (1- (length deck)) above 0 do
                   (let* ((j (random (1+ i))) (value (aref deck i)))
                     (aset deck i (aref deck j)) (aset deck j value)))
          (setq lispm-office-render--room-pool (append deck nil))))
      (setq index (pop lispm-office-render--room-pool))
      (puthash key index lispm-office-render--room-assignments))
    (aref lispm-office-render--room-styles index)))

(defun lispm-office-render--interior-patterns (svg room style)
  "Define ROOM's pixel floor and wallpaper patterns from STYLE on SVG."
  (let* ((id (format "%s" (plist-get room :id)))
         (floor-id (concat "office-floor-" id))
         (wall-id (concat "office-wall-" id))
         (defs (list 'defs nil))
         (floor (list 'pattern `((id . ,floor-id) (patternUnits . "userSpaceOnUse")
                                (width . 80) (height . 64))))
         (wall (list 'pattern `((id . ,wall-id) (patternUnits . "userSpaceOnUse")
                               (width . 16) (height . 16))))
         (base (plist-get style :floor)) (grain (plist-get style :grain)))
    (svg-rectangle floor 0 0 80 64 :fill base)
    (pcase (plist-get style :pattern)
      ('planks
       (dotimes (row 4)
         (svg-rectangle floor 0 (* row 16) 80 1 :fill grain)
         (svg-rectangle floor (if (zerop (% row 2)) 20 60) (* row 16) 1 16 :fill grain)
         (svg-rectangle floor 4 (+ 7 (* row 16)) 25 1 :fill grain :opacity 0.16)))
      ('tiles
       (dotimes (row 4)
         (dotimes (col 5)
           (svg-rectangle floor (* col 16) (* row 16) 16 1 :fill grain :opacity 0.45)
           (svg-rectangle floor (* col 16) (* row 16) 1 16 :fill grain :opacity 0.45)
           (when (zerop (% (+ row col) 2))
             (svg-rectangle floor (1+ (* col 16)) (1+ (* row 16)) 15 15
                            :fill "#ffffff" :opacity 0.045)))))
      ('parquet
       (dotimes (row 4)
         (dotimes (col 5)
           (let ((x (* col 16)) (y (* row 16)))
             (svg-rectangle floor x y 16 1 :fill grain)
             (svg-rectangle floor x y 1 16 :fill grain)
             (if (zerop (% (+ row col) 2))
                 (svg-rectangle floor (+ x 8) y 1 16 :fill grain)
               (svg-rectangle floor x (+ y 8) 16 1 :fill grain))))))
      ('tatami
       (dotimes (row 8) (svg-rectangle floor 0 (* row 8) 80 1 :fill grain :opacity 0.5))
       (svg-rectangle floor 0 0 3 64 :fill grain)
       (svg-rectangle floor 40 0 3 64 :fill grain)
       (svg-rectangle floor 0 0 80 3 :fill grain))
      (_ (dotimes (row 8)
           (dotimes (col 10)
             (svg-rectangle floor (+ 2 (* col 8)) (+ 2 (* row 8)) 2 2 :fill grain :opacity 0.55)))))
    (svg-rectangle wall 0 0 16 16 :fill (plist-get style :wall))
    (pcase (plist-get style :id)
      ((or 'oak 'library)
       (svg-rectangle wall 0 0 1 16 :fill (plist-get style :trim) :opacity 0.12)
       (svg-rectangle wall 3 0 1 16 :fill "#ffffff" :opacity 0.25))
      ((or 'mint 'cream)
       (svg-rectangle wall 7 5 2 2 :fill (plist-get style :trim) :opacity 0.12)
       (svg-rectangle wall 5 7 6 2 :fill (plist-get style :trim) :opacity 0.12)
       (svg-rectangle wall 7 9 2 2 :fill (plist-get style :trim) :opacity 0.12))
      ((or 'rose 'apricot)
       (svg-rectangle wall 0 0 1 16 :fill (plist-get style :trim) :opacity 0.08)
       (svg-rectangle wall 7 7 2 2 :fill (plist-get style :trim) :opacity 0.15))
      (_ (svg-rectangle wall 0 0 16 1 :fill (plist-get style :trim) :opacity 0.06)))
    (dom-append-child defs floor) (dom-append-child defs wall)
    (dom-append-child svg defs)
    (cons (format "url(#%s)" floor-id) (format "url(#%s)" wall-id))))

(defun lispm-office-render--fixture (svg fixture style)
  "Draw pixel FIXTURE inside the furnishing bounds supplied by the layout."
  (let* ((x (plist-get fixture :x)) (y (plist-get fixture :y))
         (w (plist-get fixture :width)) (h (plist-get fixture :height))
         (trim (plist-get style :trim))
         (group (lispm-office-render--group svg "office-fixture")))
    (dom-set-attribute group 'data-kind (format "%s" (plist-get fixture :kind)))
    (pcase (or (plist-get fixture :kind) (plist-get fixture :type))
      ('plant
       (svg-rectangle group (+ x (* w 0.3)) (+ y (* h 0.62)) (* w 0.45) (* h 0.35) :fill "#a36f52")
       (svg-rectangle group (+ x (* w 0.44)) (+ y (* h 0.25)) (* w 0.13) (* h 0.5) :fill "#61704b")
       (svg-rectangle group x (+ y (* h 0.16)) (* w 0.55) (* h 0.3) :fill "#719060")
       (svg-rectangle group (+ x (* w 0.4)) y (* w 0.6) (* h 0.35) :fill "#87a16b")
       (svg-rectangle group (+ x (* w 0.25)) (+ y (* h 0.36)) (* w 0.6) (* h 0.25) :fill "#5f7d51"))
      ((or 'coffee 'coffee-bar)
       ;; The fixture rectangle reserves a whole break area.  Furniture stays
       ;; human-sized instead of stretching into a room-sized cabinet.
       (let* ((counter-width (min w 92)) (counter-height (min h 28))
              (cx (+ x (/ (- w counter-width) 2))))
         (svg-rectangle group cx (+ y 6) counter-width (- counter-height 6) :fill trim)
         (svg-rectangle group (+ cx 2) (+ y 8) (- counter-width 4) (- counter-height 10) :fill "#bd9b74")
         (svg-rectangle group cx (+ y 4) counter-width 6 :fill "#e4dcc9")
         (svg-rectangle group (+ cx 5) y 16 12 :fill "#5c5551")
         (svg-rectangle group (+ cx 8) (+ y 2) 8 5 :fill "#c4c4aa")
         (svg-rectangle group (+ cx 10) (+ y 9) 6 5 :fill "#f3ead5")
         (svg-rectangle group (+ cx counter-width -13) (+ y 2) 6 7 :fill "#f4e8d2")
         (when (>= h 76)
           (lispm-office-render--fixture
            group (list :kind 'sofa :x (+ cx 6) :y (+ y 52)
                        :width (- counter-width 12) :height 24) style))))
      ((or 'sofa 'lounge)
       (svg-rectangle group x y w h :fill trim)
       (svg-rectangle group (+ x 3) (+ y 3) (- w 6) (- h 6) :fill "#9faaa0")
       (svg-rectangle group (+ x 5) (+ y 8) (- w 10) (- h 13) :fill "#b9c4b7")
       (svg-rectangle group (+ x (/ w 2)) (+ y 8) 2 (- h 13) :fill "#86978c"))
      (_
       (svg-rectangle group x y w h :fill trim)
       (svg-rectangle group (+ x 2) (+ y 2) (- w 4) (- h 4) :fill "#c9b18e")
       (dotimes (shelf 3)
         (let ((sy (+ y 4 (* shelf (/ (- h 8) 3)))))
           (svg-rectangle group (+ x 4) sy (- w 8) 2 :fill trim)
           (dotimes (book (max 0 (floor (/ (- w 10) 6))))
             (svg-rectangle group (+ x 5 (* book 6)) (+ sy 3) 4 6
                            :fill (nth (% (+ shelf book) 4) '("#8b9e88" "#b7836f" "#a5a1b5" "#dac28a"))))))))))

(defun lispm-office-render--wall-object (svg kind x y width height style)
  "Hang a pixel KIND on SVG inside X, Y, WIDTH, HEIGHT of the wall."
  (let ((group (lispm-office-render--group svg "office-wall-object"))
        (trim (plist-get style :trim))
        (paper (plist-get style :wall)))
    (dolist (entry `((data-kind . ,(symbol-name kind)) (data-x . ,x) (data-y . ,y)
                    (data-width . ,width) (data-height . ,height)))
      (dom-set-attribute group (car entry) (cdr entry)))
    (dom-set-attribute group 'transform
                       (format "translate(%s %s) scale(%s %s)" x y (/ width 64.0) (/ height 40.0)))
    (pcase kind
      ('window
       ;; Recessed glass, a landscape beyond it, mullions, and a projecting sill.
       (svg-rectangle group 3 3 60 37 :fill "#51483e" :opacity 0.2)
       (svg-rectangle group 0 0 62 36 :fill trim)
       (svg-rectangle group 2 2 58 32 :fill "#f4ead5")
       (svg-rectangle group 5 5 52 25 :fill "#b3d2d6")
       (svg-rectangle group 5 22 52 8 :fill "#8eaa86")
       (svg-rectangle group 5 19 14 11 :fill "#9db894")
       (svg-rectangle group 45 17 12 13 :fill "#779b80")
       (svg-rectangle group 12 10 14 3 :fill "#edf1df")
       (svg-rectangle group 16 8 6 2 :fill "#edf1df")
       (svg-rectangle group 31 4 3 28 :fill "#f4ead5")
       (svg-rectangle group 4 17 54 2 :fill "#f4ead5")
       (svg-rectangle group 0 0 4 31 :fill "#bd9173")
       (svg-rectangle group 58 0 4 31 :fill "#bd9173")
       (svg-rectangle group 0 34 64 3 :fill "#eee1c6")
       (svg-rectangle group 2 37 60 3 :fill trim))
      ('clock
       ;; A stepped bezel keeps the clock pixel-shaped, without smooth curves.
       (svg-rectangle group 8 3 48 34 :fill trim)
       (svg-rectangle group 4 7 56 26 :fill trim)
       (svg-rectangle group 12 0 40 40 :fill trim)
       (svg-rectangle group 12 6 40 28 :fill "#f3e9ce")
       (svg-rectangle group 8 10 48 20 :fill "#f3e9ce")
       (svg-rectangle group 16 4 32 32 :fill "#f3e9ce")
       (svg-rectangle group 30 7 4 3 :fill trim)
       (svg-rectangle group 30 30 4 3 :fill trim)
       (svg-rectangle group 12 18 4 3 :fill trim)
       (svg-rectangle group 48 18 4 3 :fill trim)
       (svg-rectangle group 30 13 3 10 :fill "#544b42")
       (svg-rectangle group 30 20 13 3 :fill "#544b42"))
      ('shelf
       (svg-rectangle group 2 35 60 4 :fill "#544b42" :opacity 0.2)
       (svg-rectangle group 7 31 4 9 :fill trim)
       (svg-rectangle group 52 31 4 9 :fill trim)
       (dotimes (i 6)
         (svg-rectangle group (+ 4 (* i 5)) (+ 12 (% (* i 3) 7)) 4 (- 19 (% (* i 3) 7))
                        :fill (nth (% i 4) '("#7b937d" "#bd8067" "#9b91a6" "#d2b570"))))
       (svg-rectangle group 44 22 12 9 :fill "#b47c5d")
       (svg-rectangle group 48 11 3 14 :fill "#61774f")
       (svg-rectangle group 39 13 13 5 :fill "#809b67")
       (svg-rectangle group 49 7 12 7 :fill "#6e8c59")
       (svg-rectangle group 0 30 64 4 :fill "#d3b58a")
       (svg-rectangle group 0 34 64 2 :fill trim))
      ('noticeboard
       (svg-rectangle group 3 3 61 37 :fill "#544b42" :opacity 0.2)
       (svg-rectangle group 0 0 61 37 :fill trim)
       (svg-rectangle group 3 3 55 31 :fill "#b69a70")
       (cl-loop for (nx ny nw nh color) in
                '((7 7 17 20 "#f4e8bf") (29 6 22 12 "#dce3cb") (33 22 18 9 "#e9c1a5")) do
                (svg-rectangle group nx ny nw nh :fill color)
                (svg-rectangle group (+ nx 3) (+ ny 6) (- nw 6) 1 :fill "#a69a80")
                (svg-rectangle group (+ nx (/ nw 2)) ny 2 2 :fill "#9c6554")))
      (_
       (svg-rectangle group 3 3 61 37 :fill "#544b42" :opacity 0.2)
       (svg-rectangle group 0 0 61 37 :fill trim)
       (svg-rectangle group 3 3 55 31 :fill paper)
       (svg-rectangle group 6 6 49 25 :fill "#aebfc0")
       (svg-rectangle group 42 9 7 7 :fill "#e9cf8b")
       (svg-rectangle group 6 24 49 7 :fill "#637e70")
       (svg-rectangle group 6 20 19 11 :fill "#789383")
       (svg-rectangle group 11 16 10 5 :fill "#789383")
       (svg-rectangle group 29 22 26 9 :fill "#8fa18a")
       (svg-rectangle group 36 18 12 5 :fill "#8fa18a")))
    group))

(defun lispm-office-render--wall-decor (svg room style)
  "Place bounded wall decorations in ROOM without consuming floor space."
  (let* ((x (plist-get room :x)) (y (plist-get room :y))
         (width (plist-get room :width))
         (kind (pcase (plist-get style :id)
                 ((or 'library 'tatami) 'shelf)
                 ((or 'mint 'sage) 'noticeboard)
                 (_ 'painting)))
         (window-width (min 66 (max 32 (* width 0.23))))
         (picture-width (min 60 (max 28 (* width 0.20)))))
    (lispm-office-render--wall-object svg 'window (+ x 24) (+ y 33) window-width 40 style)
    (lispm-office-render--wall-object svg kind (- (+ x width) picture-width 24) (+ y 36)
                                      picture-width 36 style)
    (when (>= width 250)
      (lispm-office-render--wall-object svg 'clock (- (+ x (/ width 2)) 13) (+ y 42) 26 26 style))))

(defun lispm-office-render--room-drawing (svg room _selected level scale)
  "Draw ROOM with a raised back wall, decorated wall face and cutaway floor."
  (let* ((style (lispm-office-render--room-style room))
         (patterns (lispm-office-render--interior-patterns svg room style))
         (group (lispm-office-render--group svg "office-room"))
         (x (plist-get room :x)) (y (plist-get room :y))
         (w (plist-get room :width)) (h (plist-get room :height))
         (wall-height lispm-office-layout-wall-height)
         (floor-y (+ y wall-height))
         (trim (plist-get style :trim)))
    (dom-set-attribute group 'data-interior (symbol-name (plist-get style :id)))
    (dom-set-attribute group 'shape-rendering "crispEdges")
    ;; The floor begins behind the baseboard, not behind the wall face.
    (svg-rectangle group x y w h :fill trim)
    (svg-rectangle group (+ x 12) floor-y (- w 24) (- h wall-height 10)
                   :fill (car patterns) :class "office-floor-surface")
    (svg-rectangle group (+ x 8) (+ y 8) (- w 16) (- wall-height 8)
                   :fill (cdr patterns) :class "office-back-wall")
    ;; Cornice, lower wall panelling, and three-tone skirting make height visible.
    (svg-rectangle group (+ x 8) (+ y 8) (- w 16) 3 :fill "#fff5df")
    (svg-rectangle group (+ x 8) (+ y 11) (- w 16) 2 :fill trim :opacity 0.2)
    (svg-rectangle group (+ x 8) (- floor-y 14) (- w 16) 10 :fill trim :opacity 0.18)
    (svg-rectangle group (+ x 8) (- floor-y 15) (- w 16) 2 :fill "#fff1d6")
    (svg-rectangle group (+ x 8) (- floor-y 5) (- w 16) 5 :fill trim)
    (svg-rectangle group (+ x 8) (- floor-y 5) (- w 16) 1 :fill "#eadbc0")
    ;; The room is cut away at the front; side walls retain a substantial cap.
    (svg-rectangle group x y w 6 :fill "#e9dfca")
    (svg-rectangle group x y 7 h :fill "#e9dfca")
    (svg-rectangle group (+ x 7) (+ y 6) 5 (- h 6) :fill trim)
    (svg-rectangle group (+ x w -12) (+ y 6) 6 (- h 6) :fill trim)
    (svg-rectangle group (+ x w -6) y 6 h :fill "#625b50")
    (svg-rectangle group x (+ y h -9) w 5 :fill "#e9dfca")
    (svg-rectangle group x (+ y h -4) w 4 :fill "#625b50")
    ;; Contact shadows belong to the floor and don't change actor hit geometry.
    (svg-rectangle group (+ x 12) floor-y (- w 24) 5 :fill "#51483e" :opacity 0.18)
    (svg-rectangle group (+ x 12) (+ floor-y 5) (- w 24) 4 :fill "#51483e" :opacity 0.07)
    (svg-rectangle group (+ x 12) floor-y 5 (- h wall-height 10) :fill "#51483e" :opacity 0.12)
    (when-let* ((door (plist-get room :door-anchor)))
      (if (< (car door) (+ x 20))
          (progn
            (svg-rectangle group x (- (cdr door) 14) 12 28 :fill (plist-get style :floor))
            (svg-rectangle group (+ x 9) (- (cdr door) 14) 3 28 :fill "#e7d6b6")
            (svg-rectangle group x (- (cdr door) 16) 12 3 :fill trim)
            (svg-rectangle group x (+ (cdr door) 14) 12 3 :fill trim))
        (svg-rectangle group (- (car door) 16) (+ y h -9) 32 9 :fill (plist-get style :floor))))
    (unless (eq level 'map)
      (lispm-office-render--wall-decor group room style)
      (dolist (fixture (plist-get room :fixtures))
        (lispm-office-render--fixture group fixture style)))
    ;; The name is an inset sign above the objects, leaving the wall face visible.
    (let* ((font (if (eq level 'map) (min 24 (/ 11 scale)) 10))
           (label (lispm-office-render--label (plist-get room :label)
                                              (max 1 (floor (/ (- w 48) (* font 0.65))))))
           (label-width (+ 16 (* (string-width label) font 0.62)))
           (label-x (- (+ x (/ w 2)) (/ label-width 2))))
      (svg-rectangle group label-x (+ y 13) label-width 17 :fill trim :opacity 0.2)
      (svg-rectangle group (+ label-x 1) (+ y 14) (- label-width 2) 14 :fill (plist-get style :wall))
      (lispm-office-render--text group label (+ x (/ w 2)) (+ y 25) font "#514b42" "middle"))
    (when (eq level 'map)
      (lispm-office-render--text group (format "%d" (length (plist-get room :nodes)))
                                 (+ x (/ w 2)) (+ floor-y (/ (- h wall-height) 2))
                                 (min 90 (/ 24 scale)) trim "middle"))))

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

(defun lispm-office-render--person (svg node level phase pose)
  "Draw NODE's pixel person in POSE on SVG, using LEVEL and PHASE."
  (let* ((group (lispm-office-render--group svg "office-person"))
         (portrait (aref lispm-office-render--portraits (lispm-office-render--portrait-index node)))
         (skin (plist-get portrait :skin)) (shirt (plist-get portrait :shirt))
         (light (lispm-ui-blend shirt "#fff0cf" 0.22))
         (dark (lispm-ui-blend shirt "#302b3b" 0.3))
         (step (if (and (eq pose 'walking) (zerop (% phase 2))) 4 0)))
    (dom-set-attribute group 'data-pose (symbol-name pose))
    (dom-set-attribute group 'shape-rendering "crispEdges")
    (svg-rectangle group 32 34 26 18 :fill dark)
    (svg-rectangle group 30 36 30 12 :fill shirt)
    (svg-rectangle group 34 34 22 4 :fill light)
    (svg-rectangle group 40 30 10 6 :fill skin)
    (svg-rectangle group 26 38 8 10 :fill shirt)
    (svg-rectangle group 56 38 8 10 :fill shirt)
    (svg-rectangle group 26 38 6 2 :fill light)
    (svg-rectangle group 58 38 6 2 :fill light)
    (when (memq pose '(walking talking))
      (svg-rectangle group 34 50 8 (+ 8 step) :fill "#494453")
      (svg-rectangle group 48 50 8 (- 12 step) :fill "#494453")
      (svg-rectangle group 32 (+ 57 step) 10 4 :fill "#302b3b")
      (svg-rectangle group 48 (- 61 step) 10 4 :fill "#302b3b"))
    (unless (and (eq level 'desk)
                 (lispm-office-render--avatar group (plist-get node :avatar) 30 4 30))
      (lispm-office-render--pixel-portrait group portrait 29 2))
    (pcase pose
      ('coffee
       (svg-rectangle group 56 30 8 12 :fill shirt)
       (svg-rectangle group 54 24 6 12 :fill skin)
       (svg-rectangle group 44 24 10 10 :fill "#f8edd8")
       (svg-rectangle group 46 24 6 2 :fill "#805b41")
       (svg-rectangle group 54 26 4 6 :fill "#f8edd8")
       (svg-rectangle group 54 28 2 2 :fill skin)
       (svg-rectangle group 46 19 2 3 :fill "#faf2df")
       (svg-rectangle group 50 16 2 4 :fill "#faf2df"))
      ('help
       (svg-rectangle group 60 22 8 18 :fill shirt)
       (svg-rectangle group 64 12 6 14 :fill skin)
       (svg-rectangle group 62 8 10 8 :fill skin)
       (svg-rectangle group 62 6 2 6 :fill skin)
       (svg-rectangle group 66 4 2 8 :fill skin)
       (svg-rectangle group 70 6 2 6 :fill skin)
       (svg-rectangle group 74 1 10 12 :fill "#f2c869")
       (svg-rectangle group 78 3 2 5 :fill "#694e35")
       (svg-rectangle group 78 10 2 2 :fill "#694e35"))
      ('talking
       (svg-rectangle group 60 30 10 6 :fill skin)
       (svg-rectangle group 65 6 22 16 :fill "#514c43")
       (svg-rectangle group 67 8 18 12 :fill "#fff4d9")
       (svg-rectangle group 66 20 5 5 :fill "#514c43")
       (dolist (x '(70 75 80)) (svg-rectangle group x 13 2 2 :fill "#6b6255")))
      (_
       (svg-rectangle group 24 (+ 47 (if (eq pose 'walking) step 0)) 8 4 :fill skin)
       (svg-rectangle group 58 (- 51 (if (eq pose 'walking) step 0)) 8 4 :fill skin)))
    group))

(defun lispm-office-render--station (svg node phase working)
  "Draw NODE's stationary desk and computer on SVG at PHASE.
WORKING lights the screen and animates the typed code."
  (let* ((paper "#d6bea0") (edge "#8a7460") (frame "#4a484b")
         (group (lispm-office-render--group svg "office-station")))
    (dom-set-attribute group 'data-key (xml-escape-string (prin1-to-string (plist-get node :key))))
    (svg-rectangle group 10 54 70 8 :fill edge)
    (svg-rectangle group 12 54 66 4 :fill paper)
    (svg-rectangle group 12 54 66 2 :fill "#eddbbb")
    (svg-rectangle group 14 62 4 4 :fill edge)
    (svg-rectangle group 72 62 4 4 :fill edge)
    (svg-rectangle group 28 38 34 22 :fill frame)
    (svg-rectangle group 30 40 30 16 :fill (if working "#303d43" "#68736d"))
    (svg-rectangle group 30 40 30 2 :fill "#8d928a")
    (when working
      (svg-rectangle group 32 44 2 2 :fill "#c5e2bf")
      (svg-rectangle group 34 46 2 2 :fill "#c5e2bf")
      (svg-rectangle group 32 48 2 2 :fill "#c5e2bf")
      (svg-rectangle group 40 46 (+ 8 (* 4 (% phase 2))) 2 :fill "#c5e2bf")
      (svg-rectangle group 40 50 (+ 4 (* 2 (% phase 3))) 2 :fill "#91b6c5")
      (svg-rectangle group 52 50 4 2 :fill "#c8b68c"))
    (svg-rectangle group 26 58 38 4 :fill edge)
    (svg-rectangle group 28 58 34 2 :fill "#d2cbbc")
    (svg-rectangle group 40 58 10 2 :fill "#f4e6ce")
    ;; A small document stack makes the desk read as furniture, not a card.
    (svg-rectangle group 66 48 10 6 :fill "#b5a894")
    (svg-rectangle group 66 48 10 2 :fill "#f8ebd3")))

(defun lispm-office-render--worker (svg node level phase &optional away)
  "Draw NODE's workstation and state pose; AWAY leaves the chair empty."
  (let* ((state (lispm-office-render--state node))
         (working (and (eq state 'working) (not away)))
         (pose (cond ((memq state '(blocked error)) 'help)
                     ((eq state 'working) 'typing) (t 'coffee)))
         (portrait (aref lispm-office-render--portraits (lispm-office-render--portrait-index node))))
    (dom-set-attribute svg 'shape-rendering "crispEdges")
    (dom-set-attribute svg 'data-pose (if away "away" (symbol-name pose)))
    (svg-rectangle svg 16 64 58 2 :fill "#514b43" :opacity 0.15)
    (svg-rectangle svg 32 28 26 28 :fill "#716d65")
    (svg-rectangle svg 34 30 22 22 :fill "#a9ada0")
    (unless away (lispm-office-render--person svg node level phase pose))
    (lispm-office-render--station svg node phase working)
    (when working
      (let ((skin (plist-get portrait :skin)) (step (* 2 (% phase 2))))
        (svg-rectangle svg 33 (+ 55 step) 8 4 :fill skin)
        (svg-rectangle svg 51 (- 57 step) 8 4 :fill skin)
        (svg-rectangle svg 31 (- 52 step) 2 2 :fill "#fff0b0")
        (svg-rectangle svg 59 (+ 50 step) 2 2 :fill "#fff0b0")))))

(defun lispm-office-render--path-position (path progress)
  "Interpolate along PATH at PROGRESS, proportionally to segment lengths."
  (let* ((lengths (cl-loop for (a b) on path while b
                           collect (+ (abs (- (car b) (car a))) (abs (- (cdr b) (cdr a))))))
         (remaining (* progress (apply #'+ lengths)))
         (points path) (sizes lengths))
    (while (and (cdr sizes) (> remaining (car sizes)))
      (setq remaining (- remaining (car sizes)) points (cdr points) sizes (cdr sizes)))
    (if (or (null (cdr points)) (zerop (or (car sizes) 0))) (car (last path))
      (let* ((a (car points)) (b (cadr points)) (part (/ remaining (float (car sizes)))))
        (cons (+ (car a) (* part (- (car b) (car a))))
              (+ (cdr a) (* part (- (cdr b) (cdr a)))))))))

(defun lispm-office-render--visitors (plan nodes)
  "Return animated visitor poses from explicit collaboration links in NODES."
  (let ((active (make-hash-table :test #'equal)) (now (float-time)) visitors)
    (dolist (node nodes)
      (when-let* ((target (seq-some (lambda (key) (lispm-office-render--endpoint key nodes))
                                    (plist-get node :waits-on)))
                  (path (lispm-office-layout-walk-path plan (plist-get node :key) (plist-get target :key))))
        (let* ((key (list (plist-get node :key) (plist-get target :key)))
               (start (or (gethash key lispm-office-render--visits) now))
               (progress (min 1.0 (max 0.0 (/ (- now start) 1.4))))
               (position (lispm-office-render--path-position path progress)))
          (puthash key t active)
          (puthash key start lispm-office-render--visits)
          (push (list :key (plist-get node :key) :node node :feet position
                      :pose (if (< progress 1) 'walking 'talking)) visitors))))
    (maphash (lambda (key _value) (unless (gethash key active) (remhash key lispm-office-render--visits)))
             lispm-office-render--visits)
    visitors))

(defun lispm-office-render--desk-label (node)
  "Return a compact name for NODE, preserving native session suffixes."
  (let ((name (or (plist-get node :name) "Agent")))
    (if (string-match "\\`\\([^@]+\\)@.*\\(<[0-9]+>\\)\\'" name)
        (let ((role (match-string 1 name)) (suffix (match-string 2 name)))
          (concat (truncate-string-to-width role (max 1 (- 13 (string-width suffix))) nil nil "…")
                  " " suffix))
      name)))

(defun lispm-office-render--desk (svg node selected level phase _scale &optional away)
  "Draw NODE's desk on SVG, using SELECTED, LEVEL, PHASE and AWAY."
  (let* ((group (lispm-office-render--group svg "office-desk"))
         (x (plist-get node :x)) (y (plist-get node :y))
         (width (plist-get node :width)) (height (plist-get node :height))
         (ink "#433c36")
         (dim "#7c7062")
         (paper "#f4ead9")
         (queued (plist-get (plist-get node :mailbox) :queued)))
    (dom-set-attribute group 'data-state (symbol-name (lispm-office-render--state node)))
    (when (equal selected (plist-get node :key))
      (svg-rectangle group x y width height
                     :fill (lispm-ui-blend paper (lispm-office-render--color :focus) 0.05)
                     :stroke (lispm-office-render--color :focus) :stroke-width 1.2))
    (let ((worker (lispm-office-render--group group "office-worker")))
      (dom-set-attribute worker 'transform (format "translate(%s %s)" x y))
      (lispm-office-render--worker worker node level phase away))
    (when (and (numberp queued) (> queued 0))
      (svg-rectangle group (+ x 69) (+ y 34) 17 12
                     :fill paper :stroke dim :stroke-width 0.8)
      (lispm-office-render--text group (format "%s" queued) (+ x 77.5) (+ y 43) 8 ink "middle" 3))
    (when (eq level 'desk)
      (lispm-office-render--text group (lispm-office-render--desk-label node)
                                 (+ x (/ width 2)) (+ y height -4) 10 ink "middle" 14))))

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
  "Draw actual message EVENTS between NODES on SVG."
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
                            :fill "none" :stroke (lispm-office-render--color :accent))))))))

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
         (visitors (unless (eq level 'map) (lispm-office-render--visitors plan nodes)))
         (lispm-office-render--palette (lispm-office-render--current-palette))
         (svg (svg-create (plist-get projection :pixel-width) (plist-get projection :pixel-height))))
    (dom-set-attribute svg 'viewBox
                       (format "%s %s %s %s" (plist-get projection :x) (plist-get projection :y)
                               (plist-get projection :width) (plist-get projection :height)))
    (dom-set-attribute svg 'preserveAspectRatio "none")
    (dom-set-attribute svg 'data-view (symbol-name level))
    (lispm-ui-svg-fill svg (plist-get projection :x) (plist-get projection :y)
                       (plist-get projection :width) (plist-get projection :height)
                       "#aaa392")
    (dolist (item rooms) (lispm-office-render--room-drawing svg item selected level actual))
    (unless (eq level 'map)
      (dolist (node nodes)
        (lispm-office-render--desk svg node selected level phase actual
                                  (seq-find (lambda (actor) (equal (plist-get actor :key)
                                                                  (plist-get node :key))) visitors)))
      (lispm-office-render--relations svg nodes events)
      (let (hits)
        (dolist (actor visitors)
          (let* ((feet (plist-get actor :feet))
                 (group (lispm-office-render--group svg "office-visitor")))
            (dom-set-attribute group 'data-key (xml-escape-string (prin1-to-string (plist-get actor :key))))
            (dom-set-attribute group 'transform (format "translate(%s %s)" (- (car feet) 45) (- (cdr feet) 64)))
            (svg-rectangle group 31 63 28 3 :fill "#514b43" :opacity 0.18)
            (lispm-office-render--person group (plist-get actor :node) level phase (plist-get actor :pose))
            (push (list :key (plist-get actor :key) :x (- (car feet) 18)
                        :y (- (cdr feet) 62) :width 55 :height 65) hits)))
        (puthash plan (cons (list scale room-id) hits) lispm-office-render--actor-hits)))
    (when (eq level 'map) (remhash plan lispm-office-render--actor-hits))
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
