;;; lispm-office-render.el --- A floor of desks, in pictures or text -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Render an already laid-out roster.  This module never asks agents for
;; data, creates timers, or performs actions.  SVG and hit testing share
;; one projection, including room focus, the master-detail docket, and
;; the maximum image size.

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

(defvaralias 'lispm-office-render--palette '*lispm-office-render-palette*)
(defvar *lispm-office-render-palette* nil
  "Palette dynamically bound for one drawing.")

(defvar lispm-office-render--avatars (make-hash-table :test #'equal)
  "Local avatar drawings cached until their roster or palette changes.")

(defvar lispm-office-render--portrait-assignments (make-hash-table :test #'equal)
  "Random portrait indices retained by stable agent key for this Emacs session.")

(defvar lispm-office-render--portrait-pool nil
  "Remaining indices in the current shuffled portrait deck.")

(defvar lispm-office-render--room-assignments (make-hash-table :test #'equal)
  "Stable random interior indices for room identities during this Emacs session.")

(defvar lispm-office-render--room-pool nil
  "Remaining shuffled interior indices.")

(defvar lispm-office-render--visits (make-hash-table :test #'equal)
  "Start times of explicit collaboration visits, indexed by both agent keys.")

(defvar lispm-office-render--actor-hits (make-hash-table :test #'eq :weakness 'key)
  "Visible actor rectangles indexed by their immutable display plan.")

(defvar lispm-office-render--docket-hits (make-hash-table :test #'eq :weakness 'key)
  "Interactive master-detail docket buttons indexed by their display plan.")

(defconst lispm-office-render--portraits
  [(:id side-part :skin "#eab690" :hair "#5c3c30" :shirt "#3b6e91" :pixels ["....OOOOOOOO...." "...OHHhhhhHHO..." "..OHHhhhhhhHHO.." "..OHHHHHHHHHHO.." "..OHHHhSSSHHHO.." "..OHHSSSSSSsHO.." "..OSSSSSSSSssO.." ".OSSSSSSSSSssSO." ".OSSEWSSSSEWsSO." ".OSSESSSSSESsSO." "..OCSSSSSSSSCO.." "..OSSSSssSSssO.." "...OSsssssssO..." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...."])
   (:id teal-bob :skin "#f2c8a4" :hair "#295861" :shirt "#b86452" :pixels ["....OOOOOOOO...." "...OHHhhhhHHO..." "..OHHhhhhhhHHO.." ".OHHHHHHHHHHHHO." ".OHHHHHHHHHHHHO." ".OHHHhSSSShHHHO." ".OHHSSSSSSSsHHO." ".OHSSSSSSSSssHO." ".OHSEWSSSSEWsHO." ".OHSESSSSSESsHO." ".OHCSSSSSSSSCHO." ".OHSSSSssSSssHO." "..OHSsssssssHO.." "..OOOOOOOOOOOO.." ".....OssssO....." "....OAAAAAAO...."])
   (:id curls :skin "#9e654d" :hair "#2c2633" :shirt "#c49442" :pixels ["...OO.OOOO.OO..." "..OHHOHhhHOHHO.." ".OHhHHhHHhHHhHO." ".OHHHhHHHHhHHHO." ".OHhHHHHHHHHhHO." "..OHHHSSSHHHHO.." "..OHSSSSSSSSsO.." ".OSSSSSSSSSssSO." ".OSSEWSSSSEWsSO." ".OSSESSSSSESsSO." "..OCSSSSSSSSCO.." "..OSSSSssSSssO.." "...OSsssssssO..." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...."])
   (:id ponytail :skin "#f3c2a1" :hair "#c79440" :shirt "#6a74ad" :pixels ["....OOOOOOOO...." "...OHHhhhhHHO..." "..OHHhhhhhhHHO.." "..OHHHHHHHHHHO.." "..OHHHHHHHHHHOA." "..OHHHSSSSHHHAaO" "..OHSSSSSSssHHOO" ".OSSSSSSSSSssSHO" ".OSSEWSSSSEWsSHO" ".OSSESSSSSESsSHO" "..OCSSSSSSSSCOHO" "..OSSSSssSSssOHO" "...OSsssssssOOO." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...."])
   (:id auburn-waves :skin "#e9ae89" :hair "#8c4238" :shirt "#43838c" :pixels ["....OOOOOOOO...." "...OHHhhhhHHO..." "..OHHhhhhhhHHO.." ".OHHHHHHHHHHHHO." ".OHHHHHHHHHHHHO." ".OHHHHSSSSHHHHO." ".OHHHSSSSSSsHHO." ".OHHSSSSSSSssHO." ".OHSEWSSSSEWsHO." ".OHSESSSSSESsHO." ".OHCSSSSSSSSCHO." ".OHHSSSssSSsHHO." ".OHHSsssssssHHO." "..OOOOOOOOOOOO.." ".OHH.OssssO.HHO." "..OO.OAAAAO.OO.."])
   (:id silver-cut :skin "#bc805d" :hair "#aeb9ca" :shirt "#966684" :pixels ["....OOOOOOOO...." "...OHhhhhhhHHO.." "..OHHhhhhhhhHO.." "..OHHHHHHHHHHO.." "..OHHHHHHHHHO..." "..OHHHSSSSSsO..." "..OHSSSSSSSssO.." ".OSSSSSSSSSssSO." ".OSSEWSSSSEWsSO." ".OSSESSSSSESsSO." "..OCSSSSSSSSCO.." "..OSSSSssSSssO.." "...OSsssssssO..." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...."])
   (:id blue-cap :skin "#d99c72" :hair "#42393a" :shirt "#4670a8" :pixels ["....OOOOOOOO...." "...OAAAAAAAAO..." "..OAAaaaaaaAAO.." "..OAAaaaaAAAAO.." "..OAAAAWWAAAAO.." ".OAAAAAAAAAAAAO." ".OOOOOOOOOOOOOO." ".OSSSSSSSSSssSO." ".OSSEWSSSSEWsSO." ".OSSESSSSSESsSO." "..OCSSSSSSSSCO.." "..OSSSSssSSssO.." "...OSsssssssO..." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...."])
   (:id round-glasses :skin "#aa7053" :hair "#3d2f35" :shirt "#67885c" :pixels ["....OOOOOOOO...." "...OHHhhhhHHO..." "..OHHhhhhhhHHO.." "..OHHHHHHHHHHO.." "..OHHHhSSSHHHO.." "..OHHSSSSSSsHO.." "..OSSSSSSSSssO.." ".OSSSSSSSSSssSO." ".OOOEEEOOEEEOOO." ".OSOEWEssEWEOSO." "..OOEEEssEEEOO.." "..OSSSSssSSssO.." "...OSsssssssO..." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...."])
   (:id violet-buns :skin "#eebaa0" :hair "#6b4b87" :shirt "#c28088" :pixels ["..OOO.OOOO.OOO.." ".OHhHOhhhhOHhHO." ".OHHOHHHHHHOHHO." "..OOOHHHHHHOOO.." "..OAAHSSSSHHAAO." "..OHHSSSSSSsHHO." "..OHSSSSSSSSssO." ".OSSSSSSSSSssSO." ".OSSEWSSSSEWsSO." ".OSSESSSSSESsSO." "..OCSSSSSSSSCO.." "..OSSSSssSSssO.." "...OSsssssssO..." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...."])
   (:id top-bun :skin "#855541" :hair "#2c2835" :shirt "#bd8248" :pixels [".....OOOOOO....." "....OHHhhHHO...." "....OHHHHHHO...." "...OOAAAAAAOO..." "..OHHHHHHHHHHO.." "..OHHHSSSSHHHO.." "..OHSSSSSSSSsO.." ".OSSSSSSSSSssSO." ".OSSEWSSSSEWsSO." ".OSSESSSSSESsSO." "..OCSSSSSSSSCO.." "..OSSSSssSSssO.." "...OSsssssssO..." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...."])
   (:id ginger-beard :skin "#e8b691" :hair "#a85331" :shirt "#4f7b65" :pixels ["....OOOOOOOO...." "...OHHhhhhHHO..." "..OHHhhhhhhHHO.." "..OHHHHHHHHHHO.." "..OHHHhSSSHHHO.." "..OHHSSSSSSsHO.." "..OSSSSSSSSssO.." ".OSSSSSSSSSssSO." ".OSSEWSSSSEWsSO." ".OSSESSSSSESsSO." "..OHSSSSSSSSHO.." "..OHHhHssHhHHO.." "...OHHhHHhHHO..." "....OOHHHHOO...." ".....OOOOOO....." "....OAAAAAAO...."])
   (:id rose-crop :skin "#bf8261" :hair "#ba6b82" :shirt "#546c99" :pixels ["....OOOOOOOO...." "...OHHhhhhHHO..." "..OHhhhhhhhHHO.." "..OHhhhHHHHHHO.." "..OHHhSSSHHHHO.." "..OHHSSSSSSsHO.." "..OSSSSSSSSssO.." ".OSSSSSSSSSssSO." ".OSSEWSSSSEWsSO." ".OSSESSSSSESsSO." "..OCSSSSSSSSCO.." "..OSSSSssSSssO.." "...OSsssssssO..." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...."])
   (:id cream-wrap :skin "#9b6149" :hair "#49373e" :shirt "#d2ad75" :pixels ["....OOOOOOOO...." "...OAAAAAAAAO..." "..OAAWaaaaaaAO.." ".OAAAWaaaaaaaAO." ".OAAAAWaaaaaaAO." ".OAAASSSSSSAAAO." ".OASSSSSSSSSsAO." ".OASSEWSSSSEWAO." ".OASSESSSSSESAO." "..OACSSSSSSSCAO." "..OASSSssSSsAAO." "...OASsssssAAO.." "...OAAOOOOAAAO.." "....OAAAAAAAO..." ".....OssssO....." "....OAAAAAAO...."])
   (:id headset :skin "#dda783" :hair "#443c52" :shirt "#5b899c" :pixels ["....OOOOOOOO...." "...OAAAAAAAAO..." "..OAHHhhhhHHAO.." ".OAOHHHHHHHHOAO." ".OAOHHhSSSHHOAO." ".OAOHSSSSSSsOAO." ".OAASSSSSSSSAAO." "OOAASEWSSSSEWAAO" "OOAASESSSSSESAAO" ".OAACSSSSSSSCAOO" "..OSSSSssSSsAAO." "...OSsssssAAAO.." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...." "....OaaaaaaO...."])
   (:id green-beanie :skin "#e9bc9a" :hair "#5d4739" :shirt "#688661" :pixels [".....OOOOOO....." "....OAAAAAAO...." "...OAAaaaaAAO..." "..OAaAaAaAaAAO.." "..OAaAaAaAaAAO.." ".OAAAAAAAAAAAAO." ".OAAWaaaaaaaaAO." ".OOOOOOOOOOOOOO." ".OSSEWSSSSEWsSO." ".OSSESSSSSESsSO." "..OCSSSSSSSSCO.." "..OSSSSssSSssO.." "...OSsssssssO..." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...."])
   (:id white-spikes :skin "#c88e69" :hair "#c4cad6" :shirt "#88667d" :pixels ["...OO..OO..OO..." "..OHOOOHOOOHHO.." ".OHhHHhHHhHHhHO." "..OHhhhHHhhhHO.." "..OHHHHHHHHHHO.." "..OHHSSSSSSHHO.." "..OHSSSSSSSSsO.." ".OSSSSSSSSSssSO." ".OSSEWSSSSEWsSO." ".OSSESSSSSESsSO." "..OCSSSSSSSSCO.." "..OSSSSssSSssO.." "...OSsssssssO..." "....OOOOOOOO...." ".....OssssO....." "....OAAAAAAO...."])]
  "Sixteen hand-drawn 16 by 16 pixel portraits.
Dots are transparent; O outlines, H/h hair, S/s skin, E eyes, W glints,
A/a accessories and C cheeks.  Colours belong to the sprite, not its provider.")

(defconst lispm-office-render--room-styles
  [(:id oak :floor "#c6a479" :grain "#ad875d" :wall "#f0e4ca" :trim "#756856" :pattern planks)
   (:id mint :floor "#d6d5bc" :grain "#b6c0a4" :wall "#e0ead5" :trim "#6e7e69" :pattern tiles)
   (:id rose :floor "#b78d7a" :grain "#967462" :wall "#eedcd6" :trim "#7e635f" :pattern parquet)
   (:id tatami :floor "#d8c58e" :grain "#b2a26f" :wall "#efe8d5" :trim "#707058" :pattern tatami)
   (:id library :floor "#a98e72" :grain "#886f57" :wall "#e6d9bd" :trim "#665c49" :pattern planks)
   (:id apricot :floor "#e0bf95" :grain "#cca57b" :wall "#f1e0c8" :trim "#997760" :pattern parquet)
   (:id sage :floor "#a8ae9b" :grain "#929a86" :wall "#e5e7da" :trim "#647165" :pattern carpet)
   (:id cream :floor "#dad3be" :grain "#beb6a3" :wall "#f3edde" :trim "#867e6c" :pattern tiles)]
  "Eight pixel office interiors, independent of the interface accent colour.")

(defun lispm-office-render-clear-cache ()
  "Forget cached avatar images after a character or palette change."
  (clrhash lispm-office-render--avatars))

(defun lispm-office-render--room (plan room-id)
  "Find ROOM-ID in PLAN, or nil for the overview."
  (and room-id (seq-find (lambda (r) (equal room-id (plist-get r :id))) (plist-get plan :rooms))))

(defun lispm-office-render-fit-room (plan room-id width height)
  "Return a responsive copy of PLAN focused on ROOM-ID in WIDTH by HEIGHT."
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
            (max (or (plist-get display :width) 0) (+ (plist-get room :x) (plist-get display-room :width) 16))
            (plist-get display :height)
            (max (or (plist-get display :height) 0) (+ (plist-get room :y) (plist-get display-room :height) 16)))
      (list :plan display :scale (plist-get packed :scale)))))

(defun lispm-office-render-projection (plan scale &optional room-id)
  "Return the projection of PLAN at SCALE, optionally focusing ROOM-ID."
  (unless (and (numberp scale) (> scale 0) (< scale 1.0e6))
    (signal 'wrong-type-argument (list 'positive-finite-number scale)))
  (let* ((room (lispm-office-render--room plan room-id))
         (x (if room (plist-get room :x) 0)) (y (if room (plist-get room :y) 0))
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
  (plist-get *lispm-office-render-palette* name))

(defun lispm-office-render--rects (group specs)
  "Draw rectangle SPECS as (X Y WIDTH HEIGHT FILL &optional OPACITY) on GROUP."
  (dolist (spec specs)
    (if (nth 5 spec)
        (svg-rectangle group (nth 0 spec) (nth 1 spec) (nth 2 spec) (nth 3 spec)
                       :fill (nth 4 spec) :opacity (nth 5 spec))
      (svg-rectangle group (nth 0 spec) (nth 1 spec) (nth 2 spec) (nth 3 spec)
                     :fill (nth 4 spec)))))

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
  (let ((text (replace-regexp-in-string "[[:cntrl:]]" " " (format "%s" (or value "")))))
    (if width (truncate-string-to-width text (max 1 width) nil nil "…") text)))

(defun lispm-office-render--text (svg text x y size color &optional anchor width weight)
  "Write TEXT on SVG at X/Y, SIZE, COLOR and optional ANCHOR, WIDTH and WEIGHT."
  (lispm-ui-svg-label svg (lispm-office-render--label text width) x y color
                      (list :family "monospace" :size size :weight (or weight "normal"))
                      (or anchor "start")))

(defun lispm-office-render--group (svg class)
  "Add a group of CLASS to SVG and return it."
  (let ((group (list 'g (list (cons 'class class))))) (dom-append-child svg group) group))

(defun lispm-office-render--state (node)
  "Return NODE's state, preserving unavailable data as unknown."
  (or (plist-get (plist-get node :status) :state) 'unknown))

(defun lispm-office-render--badge (node)
  "Return the short state badge for NODE."
  (pcase (lispm-office-render--state node)
    ('blocked (pcase (plist-get (plist-get node :status) :kind)
                ('permission "!") ('question "?") ('auth "AUTH") (_ "WAIT")))
    ('error "ERR") ('done "OK") (_ nil)))

(defun lispm-office-render--state-dot-color (state)
  "Return a crisp status LED colour for STATE."
  (pcase state
    ('working "#389b6c") ('blocked "#d98b26") ('error "#c94a4a") ('done "#4b7da8") (_ "#8e8375")))

(defun lispm-office-render--state-text (status)
  "Return a human-readable state phrase for STATUS without provider tokens."
  (pcase (plist-get status :state)
    ('working "Working") ('idle "Idle") ('done "Complete") ('error "Error")
    ('blocked (pcase (plist-get status :kind)
                ('permission "Approval needed") ('question "Needs answer")
                ('auth "Sign-in needed") (_ "Paused")))
    (_ "Active")))

(defun lispm-office-render--inside-p (x y rect)
  "Return non-nil if world point X/Y is inside RECT, excluding far edges."
  (and (>= x (plist-get rect :x)) (>= y (plist-get rect :y))
       (< x (+ (plist-get rect :x) (plist-get rect :width)))
       (< y (+ (plist-get rect :y) (plist-get rect :height)))))

(defun lispm-office-render-hit-test (plan x y scale &optional room-id)
  "Identify pixel X/Y in PLAN at SCALE, optionally focused on ROOM-ID."
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
                         (seq-find (lambda (item) (lispm-office-render--inside-p wx wy item)) (cdr actors))))
             (desk (and (not map-p)
                        (seq-find (lambda (item)
                                    (and (or (null room) (equal (plist-get room :id) (plist-get item :room)))
                                         (lispm-office-render--inside-p wx wy item)))
                                  (plist-get plan :nodes))))
             (buttons (gethash plan lispm-office-render--docket-hits))
             (button (and (not map-p) (not actor) (not desk)
                          (equal (car buttons) (list scale room-id))
                          (seq-find (lambda (item) (lispm-office-render--inside-p wx wy item)) (cdr buttons))))
             (tile (and map-p
                        (seq-find (lambda (item)
                                    (and (or (null room) (equal (plist-get room :id) (plist-get item :id)))
                                         (lispm-office-render--inside-p wx wy item)))
                                  (plist-get plan :rooms)))))
        (cond
         (button (list :action (plist-get button :action) :key (plist-get button :key)))
         ((or actor desk) (list :key (plist-get (or actor desk) :key)))
         (tile (list :room (plist-get tile :id))))))))

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
         (floor-id (concat "office-floor-" id)) (wall-id (concat "office-wall-" id))
         (defs (list 'defs nil))
         (floor (list 'pattern `((id . ,floor-id) (patternUnits . "userSpaceOnUse") (width . 80) (height . 64))))
         (wall (list 'pattern `((id . ,wall-id) (patternUnits . "userSpaceOnUse") (width . 16) (height . 16))))
         (base (plist-get style :floor)) (grain (plist-get style :grain)) (trim (plist-get style :trim)))
    (svg-rectangle floor 0 0 80 64 :fill base)
    (pcase (plist-get style :pattern)
      ('planks (lispm-office-render--rects floor `((0 0 80 1 ,grain) (0 16 80 1 ,grain) (22 0 1 16 ,grain))))
      ('tiles (lispm-office-render--rects floor `((0 0 16 1 ,grain) (0 0 1 16 ,grain) (2 2 12 12 "#ffffff" 0.06))))
      ('parquet (lispm-office-render--rects floor `((0 0 16 1 ,grain) (8 0 1 16 ,grain) (16 8 16 1 ,grain))))
      ('tatami (lispm-office-render--rects floor `((0 0 80 1 ,grain) (0 0 3 64 "#5f6e52") (40 0 3 64 "#5f6e52"))))
      (_ (lispm-office-render--rects floor `((2 2 2 2 ,grain 0.55) (10 10 2 2 ,grain 0.55)))))
    (svg-rectangle wall 0 0 16 16 :fill (plist-get style :wall))
    (pcase (plist-get style :id)
      ((or 'oak 'library) (lispm-office-render--rects wall `((0 0 1 16 ,trim 0.14) (3 0 1 16 "#ffffff" 0.28))))
      ((or 'mint 'cream) (lispm-office-render--rects wall `((7 5 2 2 ,trim 0.13) (5 7 6 2 ,trim 0.13))))
      ((or 'rose 'apricot) (lispm-office-render--rects wall `((0 0 1 16 ,trim 0.09) (7 7 2 2 ,trim 0.16))))
      (_ (svg-rectangle wall 0 0 16 1 :fill trim :opacity 0.08)))
    (dom-append-child defs floor) (dom-append-child defs wall)
    (dom-append-child svg defs)
    (cons base (plist-get style :wall))))

(defun lispm-office-render--fixture (svg fixture style)
  "Draw pixel FIXTURE inside the furnishing bounds supplied by the layout."
  (let* ((x (plist-get fixture :x)) (y (plist-get fixture :y))
         (w (plist-get fixture :width)) (h (plist-get fixture :height))
         (trim (plist-get style :trim))
         (group (lispm-office-render--group svg "office-fixture")))
    (dom-set-attribute group 'data-kind (format "%s" (plist-get fixture :kind)))
    (pcase (or (plist-get fixture :kind) (plist-get fixture :type))
      ('plant
       (lispm-office-render--rects
        group `((,(+ x (* w 0.22)) ,(+ y (* h 0.85)) ,(* w 0.56) ,(* h 0.14) "#4a4238" 0.2)
                (,(+ x (* w 0.25)) ,(+ y (* h 0.58)) ,(* w 0.5) ,(* h 0.36) "#a86848")
                (,(+ x (* w 0.22)) ,(+ y (* h 0.55)) ,(* w 0.56) ,(* h 0.1) "#c27d5b")
                (,(+ x (* w 0.43)) ,(+ y (* h 0.24)) ,(* w 0.14) ,(* h 0.38) "#596b45")
                (,x ,(+ y (* h 0.16)) ,(* w 0.52) ,(* h 0.26) "#678c56")
                (,(+ x (* w 0.42)) ,y ,(* w 0.56) ,(* h 0.32) "#82a668")
                (,(+ x (* w 0.18)) ,(+ y (* h 0.04)) ,(* w 0.46) ,(* h 0.24) "#97b87a")
                (,(+ x (* w 0.22)) ,(+ y (* h 0.34)) ,(* w 0.62) ,(* h 0.22) "#547547"))))
      ((or 'coffee 'coffee-bar)
       (let* ((cw (min w 92)) (ch (min h 28)) (cx (+ x (/ (- w cw) 2))))
         (lispm-office-render--rects
          group `((,cx ,(+ y 6) ,cw ,(- ch 6) ,trim) (,(+ cx 2) ,(+ y 8) ,(- cw 4) ,(- ch 10) "#c29e75")
                  (,cx ,(+ y 4) ,cw 5 "#efe6d4") (,cx ,(+ y 8) ,cw 2 "#cbbfa9")
                  (,(+ cx 5) ,y 18 12 "#494440") (,(+ cx 7) ,(+ y 2) 10 4 "#c8c8b0")
                  (,(+ cx 19) ,(+ y 3) 2 2 "#d95b43") (,(+ cx 9) ,(+ y 8) 6 4 "#f6eedb")
                  (,(+ cx 30) ,(+ y 2) 14 5 "#d7b377") (,(+ cx cw -22) ,(+ y 2) 6 6 "#f4e8d2")
                  (,(+ cx cw -13) ,(+ y 2) 6 6 "#e6d8be")))
         (when (>= h 76)
           (lispm-office-render--fixture
            group (list :kind 'sofa :x (+ cx 6) :y (+ y 52) :width (- cw 12) :height 24) style))))
      ((or 'sofa 'lounge)
       (lispm-office-render--rects
        group `((,x ,(+ y 2) ,w ,(- h 2) "#4a4238" 0.18) (,x ,y ,w ,(- h 2) ,trim)
                (,(+ x 3) ,(+ y 3) ,(- w 6) ,(- h 7) "#8e9e90") (,(+ x 5) ,(+ y 8) ,(- w 10) ,(- h 13) "#b7c4b5")
                (,(+ x 5) ,(+ y 8) ,(- w 10) 3 "#cdd8cb") (,(+ x (/ w 2)) ,(+ y 6) 2 ,(- h 11) "#7c8d81"))))
      (_
       (svg-rectangle group x y w h :fill trim)
       (svg-rectangle group (+ x 2) (+ y 2) (- w 4) (- h 4) :fill "#cbb390")
       (dotimes (shelf 3)
         (let ((sy (+ y 4 (* shelf (/ (- h 8) 3)))))
           (svg-rectangle group (+ x 4) sy (- w 8) 2 :fill trim)
           (dotimes (book (max 0 (floor (/ (- w 10) 6))))
             (svg-rectangle group (+ x 5 (* book 6)) (+ sy 3) 4 6
                            :fill (nth (% (+ shelf book) 4)
                                       '("#7e967b" "#be7f68" "#9a95ae" "#dcc284"))))))))))

(defun lispm-office-render--wall-object (svg kind x y width height style)
  "Hang a pixel KIND on SVG inside X, Y, WIDTH, HEIGHT of the wall."
  (let ((group (lispm-office-render--group svg "office-wall-object"))
        (trim (plist-get style :trim)) (paper (plist-get style :wall)))
    (dolist (entry `((data-kind . ,(symbol-name kind)) (data-x . ,x) (data-y . ,y)
                    (data-width . ,width) (data-height . ,height)))
      (dom-set-attribute group (car entry) (cdr entry)))
    (dom-set-attribute group 'transform
                       (format "translate(%s %s) scale(%s %s)" x y (/ width 64.0) (/ height 40.0)))
    (pcase kind
      ('window
       (lispm-office-render--rects
        group `((3 3 60 37 "#51483e" 0.22) (0 0 62 36 ,trim) (2 2 58 32 "#f5ebd8")
                (5 5 52 25 "#a9cfd6") (5 5 52 7 "#95c2cc") (44 8 6 5 "#fae29c")
                (10 9 14 3 "#f4f7e8") (14 7 7 2 "#f4f7e8") (5 22 52 8 "#86a67e")
                (5 18 16 12 "#9ab892") (42 16 15 14 "#72987b") (30 4 3 28 "#f5ebd8")
                (4 17 54 2 "#f5ebd8") (0 0 5 32 "#c49676") (57 0 5 32 "#c49676")
                (0 34 64 3 "#f0e3c8") (2 37 60 3 ,trim))))
      ('clock
       (lispm-office-render--rects
        group `((8 3 48 34 ,trim) (4 7 56 26 ,trim) (12 0 40 40 ,trim)
                (12 6 40 28 "#f6edd5") (8 10 48 20 "#f6edd5") (16 4 32 32 "#f6edd5")
                (30 6 4 3 ,trim) (30 31 4 3 ,trim) (11 18 4 3 ,trim) (49 18 4 3 ,trim)
                (30 11 3 11 "#4a423a") (30 20 13 3 "#4a423a") (30 19 4 4 "#b85d48"))))
      ('shelf
       (lispm-office-render--rects group `((2 35 60 4 "#544b42" 0.22) (7 31 4 9 ,trim) (52 31 4 9 ,trim)))
       (dotimes (i 7)
         (let ((bh (- 19 (% (* i 3) 7))))
           (svg-rectangle group (+ 4 (* i 5)) (- 30 bh) 4 bh
                          :fill (nth (% i 4) '("#738f76" "#c27d63" "#9389a3" "#d6b86e")))))
       (lispm-office-render--rects
        group `((44 21 12 9 "#b87d5d") (48 10 3 14 "#5c754a") (39 12 13 5 "#7e9c64")
                (49 6 12 7 "#6c8c56") (0 30 64 4 "#d6b88d") (0 34 64 2 ,trim))))
      ('noticeboard
       (lispm-office-render--rects group `((3 3 61 37 "#544b42" 0.22) (0 0 61 37 ,trim) (3 3 55 31 "#b99c72")))
       (cl-loop for (nx ny nw nh color) in
                '((6 6 18 21 "#f7ecc4") (28 6 24 12 "#dde6cc") (31 21 20 10 "#ecc3a7"))
                do (lispm-office-render--rects
                    group `((,nx ,ny ,nw ,nh ,color) (,(+ nx 3) ,(+ ny 5) ,(- nw 6) 1 "#9e9278")
                            (,(+ nx 3) ,(+ ny 8) ,(- nw 8) 1 "#b5a98e") (,(+ nx (/ nw 2)) ,(1+ ny) 2 2 "#b85648")))))
      (_
       (lispm-office-render--rects
        group `((3 3 61 37 "#544b42" 0.22) (0 0 61 37 ,trim) (3 3 55 31 ,paper)
                (6 6 49 25 "#a8bec2") (42 9 7 7 "#eed28a") (6 24 49 7 "#5f7d6e")
                (6 19 20 12 "#769482") (11 15 11 5 "#86a391") (28 21 27 10 "#8ca088")
                (35 17 13 5 "#9cb098")))))
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
    (svg-rectangle group x y w h :fill trim)
    (svg-rectangle group (+ x 12) floor-y (- w 24) (- h wall-height 10)
                   :fill (car patterns) :class "office-floor-surface")
    (svg-rectangle group (+ x 8) (+ y 8) (- w 16) (- wall-height 8)
                   :fill (cdr patterns) :class "office-back-wall")
    (lispm-office-render--rects
     group `((,(+ x 8) ,(+ y 8) ,(- w 16) 3 "#fff5df")
             (,(+ x 8) ,(+ y 11) ,(- w 16) 2 ,trim 0.22)
             (,(+ x 8) ,(- floor-y 16) ,(- w 16) 11 ,trim 0.18)
             (,(+ x 8) ,(- floor-y 17) ,(- w 16) 2 "#fff1d6")
             (,(+ x 8) ,(- floor-y 5) ,(- w 16) 5 ,trim)
             (,(+ x 8) ,(- floor-y 5) ,(- w 16) 1 "#eadbc0")
             (,x ,y ,w 6 "#e9dfca") (,x ,y 7 ,h "#e9dfca")
             (,(+ x 7) ,(+ y 6) 5 ,(- h 6) ,trim)
             (,(+ x w -12) ,(+ y 6) 6 ,(- h 6) ,trim)
             (,(+ x w -6) ,y 6 ,h "#625b50")
             (,x ,(+ y h -9) ,w 5 "#e9dfca") (,x ,(+ y h -4) ,w 4 "#625b50")
             (,(+ x 12) ,floor-y ,(- w 24) 5 "#51483e" 0.2)
             (,(+ x 12) ,(+ floor-y 5) ,(- w 24) 4 "#51483e" 0.08)
             (,(+ x 12) ,floor-y 5 ,(- h wall-height 10) "#51483e" 0.13)))
    (when-let* ((door (plist-get room :door-anchor)))
      (if (< (car door) (+ x 20))
          (lispm-office-render--rects
           group `((,x ,(- (cdr door) 14) 12 28 ,(plist-get style :floor))
                   (,(+ x 9) ,(- (cdr door) 14) 3 28 "#e7d6b6")
                   (,x ,(- (cdr door) 16) 12 3 ,trim)
                   (,x ,(+ (cdr door) 14) 12 3 ,trim)))
        (svg-rectangle group (- (car door) 16) (+ y h -9) 32 9 :fill (plist-get style :floor))))
    (unless (eq level 'map)
      (lispm-office-render--wall-decor group room style)
      (dolist (fixture (plist-get room :fixtures))
        (lispm-office-render--fixture group fixture style)))
    (let* ((font (if (eq level 'map) (min 24 (/ 11 scale)) 10))
           (label (lispm-office-render--label
                   (plist-get room :label) (max 1 (floor (/ (- w 48) (* font 0.65))))))
           (label-width (+ 18 (* (string-width label) font 0.62)))
           (label-x (- (+ x (/ w 2)) (/ label-width 2))))
      (svg-rectangle group label-x (+ y 13) label-width 17 :fill trim :opacity 0.28)
      (svg-rectangle group (+ label-x 1) (+ y 14) (- label-width 2) 15 :fill (plist-get style :wall))
      (svg-rectangle group (+ label-x 2) (+ y 15) (- label-width 4) 1 :fill "#fff9eb")
      (lispm-office-render--text group label (+ x (/ w 2)) (+ y 25) font "#4a433b" "middle" nil "bold"))
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
      ((file-error wrong-type-argument args-out-of-range) nil))))

(defun lispm-office-render--avatar (svg avatar x y &optional size)
  "Draw local AVATAR at X/Y, returning non-nil on success.
SIZE defaults to 18 pixels."
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
  "Return NODE's random portrait index, retaining its stable identity."
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
         (colors (list (cons ?O "#2a2533") (cons ?E "#24202c")
                       (cons ?H hair) (cons ?h (lispm-ui-blend hair "#fff4d8" 0.28))
                       (cons ?S skin) (cons ?s (lispm-ui-blend skin "#6e3b40" 0.24))
                       (cons ?C (lispm-ui-blend skin "#d46a64" 0.36))
                       (cons ?W "#fffaf0") (cons ?A shirt)
                       (cons ?a (lispm-ui-blend shirt "#fff4d8" 0.25)))))
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
         (light (lispm-ui-blend shirt "#fff2d6" 0.25))
         (dark (lispm-ui-blend shirt "#282332" 0.32))
         (cycle (% phase 6))
         (stride (if (eq pose 'walking) (aref [-4 -2 1 4 2 -1] cycle) 0))
         (bob (cond ((eq pose 'walking) (aref [0 -1 -2 0 -1 -2] cycle))
                    ((eq pose 'typing) (aref [0 0 -1 0 0 1] cycle))
                    (t 0)))
         (kind (plist-get (plist-get node :status) :kind))
         (err-p (eq (lispm-office-render--state node) 'error)))
    (dom-set-attribute group 'data-pose (symbol-name pose))
    (dom-set-attribute group 'shape-rendering "crispEdges")
    (lispm-office-render--rects
     group `((31 ,(+ 33 bob) 28 19 ,dark) (29 ,(+ 35 bob) 32 13 ,shirt)
             (33 ,(+ 33 bob) 24 4 ,light) (39 ,(+ 33 bob) 12 2 "#f4ead8")
             (40 ,(+ 29 bob) 10 5 ,skin) (25 ,(+ 37 bob) 8 11 ,shirt)
             (57 ,(+ 37 bob) 8 11 ,shirt) (25 ,(+ 37 bob) 6 2 ,light)
             (59 ,(+ 37 bob) 6 2 ,light)))
    (when (memq pose '(walking talking))
      (lispm-office-render--rects
       group `((34 50 8 ,(+ 9 (max -3 stride)) "#454050")
               (48 50 8 ,(- 9 (max -3 stride)) "#454050")
               (32 ,(+ 58 (max -3 stride)) 10 4 "#2a2533")
               (48 ,(- 58 (max -3 stride)) 10 4 "#2a2533"))))
    (unless (and (eq level 'desk)
                 (lispm-office-render--avatar group (plist-get node :avatar) 30 (+ 3 bob) 30))
      (lispm-office-render--pixel-portrait group portrait 29 (+ 1 bob)))
    (pcase pose
      ('coffee
       (lispm-office-render--rects
        group `((56 30 8 12 ,shirt) (53 25 6 11 ,skin) (43 23 11 11 "#2a2533")
                (44 24 9 9 "#fbf2e0") (45 24 7 2 "#7b5338") (53 26 4 6 "#fbf2e0")
                (46 18 2 3 "#fffaf0" 0.75) (49 15 2 4 "#fffaf0" 0.65) (45 13 2 2 "#fffaf0" 0.45))))
      ('help
       (lispm-office-render--rects
        group `((60 20 8 19 ,shirt) (63 10 6 13 ,skin) (61 7 10 7 ,skin)
                (71 1 16 15 "#2a2533") (72 2 14 13 ,(if err-p "#e05a52" "#f5ca5c"))
                (73 3 12 2 ,(if err-p "#f48b84" "#fae39c")) (69 12 3 3 "#2a2533")))
       (if (eq kind 'question)
           (lispm-office-render--rects
            group '((77 4 5 2 "#3a2b1c") (80 6 2 3 "#3a2b1c") (78 8 2 2 "#3a2b1c") (78 12 2 2 "#3a2b1c")))
         (lispm-office-render--rects
          group `((78 4 2 6 ,(if err-p "#ffffff" "#3a2b1c"))
                  (78 12 2 2 ,(if err-p "#ffffff" "#3a2b1c"))))))
      ('talking
       (lispm-office-render--rects
        group `((60 30 10 6 ,skin) (64 5 24 17 "#3d3730") (66 7 20 13 "#fff7e2") (65 20 5 5 "#3d3730")))
       (dolist (x '(69 75 81)) (svg-rectangle group x 12 3 3 :fill "#635a4e")))
      (_
       (svg-rectangle group 24 (+ 47 (if (eq pose 'walking) stride 0)) 8 4 :fill skin)
       (svg-rectangle group 58 (- 47 (if (eq pose 'walking) stride 0)) 8 4 :fill skin)))
    group))

(defun lispm-office-render--station (svg node phase working)
  "Draw NODE's stationary desk, chair and computer on SVG at PHASE.
WORKING lights the screen, animates 6-phase code lines and emits sparks."
  (let* ((wood "#d8be9c") (edge "#876f59") (dark-wood "#695442")
         (frame "#424046") (bezel "#5b5961")
         (cycle (% phase 6))
         (group (lispm-office-render--group svg "office-station")))
    (dom-set-attribute group 'data-key (xml-escape-string (prin1-to-string (plist-get node :key))))
    (lispm-office-render--rects
     group `((10 53 70 10 ,edge) (12 53 66 6 ,wood) (12 53 66 2 "#f2e1c4")
             (13 59 64 3 ,dark-wood) (13 62 5 5 ,dark-wood) (62 59 14 8 ,edge)
             (63 60 12 6 "#9e846b") (67 62 4 2 "#e8d6bc") (16 55 10 4 "#b5a692")
             (16 55 10 2 "#f7ebd6") (66 47 11 7 "#9e907d") (66 47 11 2 "#faf0dc")
             (68 45 9 2 "#749483") (26 57 38 4 ,edge) (28 57 34 2 "#d9d2c5")
             (38 57 14 2 "#f7ead4") (42 54 6 5 ,frame) (27 36 36 22 "#2c2a30")
             (28 37 34 20 ,frame) (28 37 34 2 ,bezel)
             (30 39 30 15 ,(if working "#1f2b33" "#5a635f"))
             (30 39 30 2 ,(if working "#38505e" "#7c8580"))
             (58 55 2 2 ,(if working "#4cd98c" "#9e988e"))))
    (when working
      (let ((c1 (aref [10 14 18 12 16 20] cycle))
            (c2 (aref [16 10 14 18 12 8] cycle))
            (c3 (aref [8 12 10 16 14 12] cycle))
            (sy (aref [32 30 27 31 28 25] cycle))
            (sx (aref [33 54 44 36 52 41] cycle)))
        (lispm-office-render--rects
         group `((32 42 3 2 "#f0c674") (36 42 ,c1 2 "#b5e8b0")
                 (32 45 2 2 "#81a2be") (35 45 ,c2 2 "#8abeb7")
                 (32 48 4 2 "#b294bb") (37 48 ,c3 2 "#de935f")))
        (when (zerop (% cycle 2))
          (svg-rectangle group (+ 38 c3) 48 3 2 :fill "#fff6d6"))
        (svg-rectangle group sx sy 3 3 :fill "#ffe89e")
        (svg-rectangle group (+ sx 1) (- sy 3) 2 2 :fill "#8ce0b8")))))

(defun lispm-office-render--worker (svg node level phase &optional away)
  "Draw NODE's workstation and state pose; AWAY leaves the chair empty."
  (let* ((state (lispm-office-render--state node))
         (working (and (eq state 'working) (not away)))
         (pose (cond ((memq state '(blocked error)) 'help)
                     ((eq state 'working) 'typing) (t 'coffee)))
         (portrait (aref lispm-office-render--portraits (lispm-office-render--portrait-index node)))
         (cycle (% phase 6)))
    (dom-set-attribute svg 'shape-rendering "crispEdges")
    (dom-set-attribute svg 'data-pose (if away "away" (symbol-name pose)))
    (lispm-office-render--rects
     svg '((14 64 62 3 "#4a433b" 0.18) (31 25 28 30 "#5c5852")
           (33 27 24 24 "#959c90") (35 28 20 4 "#aeb5a8")
           (28 38 4 10 "#5c5852") (58 38 4 10 "#5c5852")))
    (unless away (lispm-office-render--person svg node level phase pose))
    (lispm-office-render--station svg node phase working)
    (when working
      (let ((skin (plist-get portrait :skin))
            (lh (aref [0 2 1 -1 2 0] cycle))
            (rh (aref [2 0 -1 2 0 1] cycle)))
        (lispm-office-render--rects
         svg `((32 ,(+ 54 lh) 8 4 ,skin) (50 ,(+ 54 rh) 8 4 ,skin)
               (,(+ 30 (% cycle 3)) ,(- 51 (abs lh)) 2 2 "#fff0b0")
               (,(- 59 (% cycle 3)) ,(- 51 (abs rh)) 2 2 "#9be8c8")))))))

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

(defun lispm-office-render--desk-label (node &optional lead-p)
  "Return a compact name for NODE, preserving native session suffixes.
LEAD-P marks a parent session that coordinates child sub-sessions."
  (let ((name (or (plist-get node :name) "Agent"))
        (sub-p (plist-get node :parent)))
    (cond
     ((string-match "\\`\\([^@]+\\)@.*\\(<[0-9]+>\\)\\'" name)
      (let ((role (match-string 1 name))
            (suffix (match-string 2 name))
            (prefix (if sub-p "↳ " "")))
        (concat prefix
                (truncate-string-to-width
                 role (max 1 (- 13 (string-width prefix) (string-width suffix))) nil nil "…")
                " " suffix)))
     ((string-match "\\`\\([^@]+\\)@[^<]+\\'" name)
      (let ((role (match-string 1 name)))
        (cond (lead-p (concat "★ " role))
              (sub-p (concat "↳ " role))
              ((> (string-width name) 14) role)
              (t name))))
     (lead-p (concat "★ " name))
     (sub-p (concat "↳ " name))
     (t name))))

(defun lispm-office-render--desk (svg node selected level phase _scale &optional away lead-p)
  "Draw NODE's desk on SVG, using SELECTED, LEVEL, PHASE, AWAY and LEAD-P."
  (let* ((group (lispm-office-render--group svg "office-desk"))
         (x (plist-get node :x)) (y (plist-get node :y))
         (width (plist-get node :width)) (height (plist-get node :height))
         (state (lispm-office-render--state node))
         (selected-p (equal selected (plist-get node :key)))
         (sub-p (and (plist-get node :parent) t))
         (ink "#3d3630") (dim "#7a6e60") (paper "#f6ecdc")
         (accent (lispm-office-render--color :accent))
         (focus (lispm-office-render--color :focus))
         (dot-color (lispm-office-render--state-dot-color state))
         (queued (plist-get (plist-get node :mailbox) :queued)))
    (dom-set-attribute group 'data-state (symbol-name state))
    (when (or lead-p sub-p) (dom-set-attribute group 'data-role (if lead-p "main" "sub")))
    (when selected-p
      (svg-rectangle group (+ x 2) (+ y 2) (- width 4) (- height 2)
                     :fill (lispm-ui-blend paper focus 0.14) :stroke focus :stroke-width 1.6)
      (lispm-office-render--rects
       group `((,(+ x 4) ,(+ y 4) 8 2 ,focus) (,(+ x 4) ,(+ y 4) 2 8 ,focus)
               (,(+ x width -12) ,(+ y 4) 8 2 ,focus) (,(+ x width -6) ,(+ y 4) 2 8 ,focus))))
    (let ((worker (lispm-office-render--group group "office-worker")))
      (dom-set-attribute worker 'transform (format "translate(%s %s)" x y))
      (lispm-office-render--worker worker node level phase away))
    (when lead-p (svg-rectangle group (+ x 12) (+ y 53) 66 2 :fill accent))
    (when (and (eq level 'desk) (or lead-p sub-p))
      (svg-rectangle group (+ x 5) (+ y 4) (if lead-p 27 23) 11
                     :fill (if lead-p accent paper) :stroke (if lead-p accent dim) :stroke-width 0.9)
      (lispm-office-render--text group (if lead-p "MAIN" "SUB") (+ x (if lead-p 18.5 16.5)) (+ y 12) 7
                                 (if lead-p "#ffffff" dim) "middle" 4 "bold"))
    (when (and (numberp queued) (> queued 0))
      (svg-rectangle group (+ x 68) (+ y 33) 18 12 :fill "#fff8e8" :stroke dim :stroke-width 0.9)
      (svg-rectangle group (+ x 69) (+ y 34) 16 2 :fill accent)
      (lispm-office-render--text group (format "%s" queued) (+ x 77) (+ y 43) 8 ink "middle" 3 "bold"))
    (when (eq level 'desk)
      (svg-rectangle group (+ x 6) (+ y height -15) (- width 12) 14 :fill (if selected-p "#fffaf0" paper)
                     :stroke (if selected-p focus "#b5a692") :stroke-width (if selected-p 1.2 0.8))
      (svg-rectangle group (+ x 10) (+ y height -10) 4 4 :fill dot-color)
      (lispm-office-render--text group (lispm-office-render--desk-label node lead-p)
                                 (+ x (/ width 2) 3) (+ y height -5) 9.5 (if lead-p accent ink) "middle" 14
                                 (if (or selected-p lead-p) "bold" "normal")))))

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
  "Draw parent-child delegation links and actual message EVENTS between NODES."
  (let ((accent (lispm-office-render--color :accent)))
    (dolist (node nodes)
      (when-let* ((parent-key (plist-get node :parent))
                  (parent (lispm-office-render--endpoint parent-key nodes))
                  ((eql (plist-get node :room) (plist-get parent :room))))
        (let ((px (+ (plist-get parent :x) 45)) (py (+ (plist-get parent :y) 56))
              (cx (+ (plist-get node :x) 45)) (cy (+ (plist-get node :y) 56))
              (link (lispm-office-render--group svg "office-delegation")))
          (svg-polyline link (list (cons px py) (cons px cy) (cons cx cy))
                        :fill "none" :stroke accent :stroke-width 1.2
                        :stroke-dasharray "3,3" :opacity 0.45))))
    (dolist (event events)
      (when (memq (plist-get event :type) '(message-queued message-taken message-delivered))
        (let ((from (lispm-office-render--endpoint (plist-get event :from) nodes))
              (to (lispm-office-render--endpoint (plist-get event :to) nodes))
              (progress (plist-get event :progress)))
          (when (and from to)
            (let* ((p (if (numberp progress) (max 0 (min 1 progress)) 0.5))
                   (fx (+ 45 (plist-get from :x))) (fy (+ 28 (plist-get from :y)))
                   (tx (+ 45 (plist-get to :x))) (ty (+ 28 (plist-get to :y)))
                   (x (+ (* (- 1 p) fx) (* p tx)))
                   (y (+ (* (- 1 p) fy) (* p ty)))
                   (tp (max 0.0 (- p 0.12)))
                   (trx (+ (* (- 1 tp) fx) (* tp tx)))
                   (try (+ (* (- 1 tp) fy) (* tp ty)))
                   (group (lispm-office-render--group svg "office-envelope")))
              (svg-rectangle group (- trx 2) (- try 2) 4 4 :fill accent :opacity 0.35)
              (svg-rectangle group (- x 8) (- y 4) 18 11 :fill "#3a332c" :opacity 0.22)
              (svg-rectangle group (- x 9) (- y 6) 18 11
                             :fill "#fff9eb" :stroke accent :stroke-width 1.2)
              (svg-polyline group (list (cons (- x 9) (- y 6)) (cons x y)
                                        (cons (+ x 9) (- y 6)))
                            :fill "none" :stroke accent :stroke-width 1.1)
              (svg-rectangle group (- x 2) (- y 2) 4 3 :fill "#d95b43"))))))))

(defun lispm-office-render--docket-bounds (room nodes)
  "Return non-overlapping master-detail docket bounds in ROOM clear of NODES."
  (let* ((rx (plist-get room :x)) (ry (plist-get room :y))
         (rw (plist-get room :width)) (rh (plist-get room :height))
         (bottom (- (+ ry rh) lispm-office-layout-wall-thickness))
         (right (- (+ rx rw) lispm-office-layout-wall-thickness))
         (max-y (if nodes (apply #'max (mapcar (lambda (n) (+ (plist-get n :y) (plist-get n :height))) nodes))
                  (+ ry lispm-office-layout-wall-height)))
         (max-x (if nodes (apply #'max (mapcar (lambda (n) (+ (plist-get n :x) (plist-get n :width))) nodes))
                  rx))
         (avail-y (- bottom max-y))
         (avail-x (- right max-x)))
    (cond
     ((>= avail-y 44)
      (list :x (+ rx 16) :y (- bottom 40) :width (- rw 32) :height 36 :layout 'full))
     ((and (>= avail-x 180) (>= (- bottom (+ ry lispm-office-layout-wall-height 36)) 40))
      (list :x (+ max-x 12) :y (- bottom 40) :width (- avail-x 16) :height 36 :layout 'side))
     ((>= avail-y 16)
      (list :x (+ rx 14) :y (- bottom 16) :width (- rw 28) :height 14 :layout 'compact)))))

(defun lispm-office-render--docket (svg room nodes selected level phase)
  "Draw the selected desk's master-detail docket in ROOM and return button hits."
  (when-let* ((_ (eq level 'desk))
              (node (and selected (seq-find (lambda (n) (equal selected (plist-get n :key))) nodes)))
              (bounds (lispm-office-render--docket-bounds room nodes)))
    (let* ((group (lispm-office-render--group svg "office-docket"))
           (dx (plist-get bounds :x)) (dy (plist-get bounds :y))
           (dw (plist-get bounds :width)) (dh (plist-get bounds :height))
           (compact (eq (plist-get bounds :layout) 'compact))
           (status (plist-get node :status)) (state (lispm-office-render--state node))
           (dot (lispm-office-render--state-dot-color state))
           (accent (lispm-office-render--color :accent)) (focus (lispm-office-render--color :focus))
           (raw-id (and (consp selected) (stringp (cadr selected)) (cadr selected)))
           (short-id (and raw-id (string-match "-\\([0-9a-fA-F]\\{4\\}\\)\\'" raw-id)
                          (concat " #" (match-string 1 raw-id))))
           (name (concat (lispm-office-render--desk-label node) (or short-id "")))
           (state-text (lispm-office-render--state-text status))
           (msg (string-trim (replace-regexp-in-string "[[:space:][:cntrl:]]+" " " (format "%s" (or (plist-get status :msg) "")))))
           (queued (plist-get (plist-get node :mailbox) :queued)) (waits (plist-get node :waits-on))
           (portrait (aref lispm-office-render--portraits (lispm-office-render--portrait-index node)))
           (buttons (append (when (and (eq state 'blocked) (eq (plist-get status :kind) 'permission))
                              '((approve . "Approve")))
                            '((open-chat . "Chat") (send . "Message") (inspect . "Details"))))
           (bx (- (+ dx dw) 6)) hits)
      (dom-set-attribute group 'data-key (xml-escape-string (prin1-to-string selected)))
      (svg-rectangle group (+ dx 2) (+ dy 2) dw dh :fill "#3b342c" :opacity 0.22)
      (svg-rectangle group dx dy dw dh :fill "#f6eddc" :stroke focus :stroke-width 1.3)
      (lispm-office-render--rects group `((,(1+ dx) ,(1+ dy) ,(- dw 2) 1 "#fffaf0") (,dx ,dy 5 ,dh ,dot)))
      (dolist (btn (reverse buttons))
        (let* ((label (cdr btn)) (bw (+ 12 (* (length label) 5.6)))
               (bh (if compact 11 18)) (by (+ dy (/ (- dh bh) 2.0))) (primary (eq (car btn) 'approve)))
          (setq bx (- bx bw 5))
          (when (> bx (+ dx (if compact 90 150)))
            (svg-rectangle group (+ bx 5) by bw bh :fill (if primary accent "#fffaf0")
                           :stroke (if primary accent focus) :stroke-width 0.9)
            (lispm-office-render--text group label (+ bx 5 (/ bw 2.0)) (+ by (if compact 8.5 12.5))
                                       (if compact 7 8) (if primary "#ffffff" "#38312b") "middle" nil "bold")
            (push (list :action (car btn) :key selected :x (+ bx 5) :y by :width bw :height bh) hits))))
      (if compact
          (let ((summary (concat name " · " state-text (if (string-empty-p msg) "" (concat " — " msg)))))
            (lispm-office-render--text group summary (+ dx 10) (+ dy 10) 8 "#38312b"
                                       "start" (max 12 (floor (/ (- bx dx 16) 5.2))) "bold"))
        (svg-rectangle group (+ dx 9) (+ dy 5) 26 26 :fill "#e6d9c3" :stroke "#8c7d6b" :stroke-width 0.8)
        (unless (lispm-office-render--avatar group (plist-get node :avatar) (+ dx 11) (+ dy 7) 22)
          (lispm-office-render--pixel-portrait group portrait (+ dx 14) (+ dy 10) 1))
        (let* ((text-x (+ dx 42)) (avail-cols (max 14 (floor (/ (- bx text-x 8) 5.5))))
               (role (if (plist-get node :parent) "Subagent · " ""))
               (meta (concat role state-text
                             (if (and (numberp queued) (> queued 0)) (format " · Inbox: %d" queued) "")
                             (if waits (format " · Waiting (%d)" (length waits)) "")
                             (if (and (eq state 'working) (zerop (% phase 2))) " ●" "")))
               (activity (cond ((not (string-empty-p msg)) msg)
                               ((eq state 'done) "Task completed — click desk again, Details, or Chat to view transcript")
                               (t "Ready at desk — click desk again, Details, or press RET to inspect"))))
          (lispm-office-render--text group (concat name "  [" meta "]") text-x (+ dy 15) 9 "#352e28" "start" avail-cols "bold")
          (lispm-office-render--text group activity text-x (+ dy 28) 8.2 "#63584c" "start" avail-cols)))
      hits)))

(defun lispm-office-render-svg (plan selected scale phase &optional room-id events)
  "Draw PLAN as an SVG DOM, with SELECTED desk, SCALE and animation PHASE."
  (let* ((projection (lispm-office-render-projection plan scale room-id))
         (actual (plist-get projection :scale)) (level (lispm-office-render--level actual))
         (room (lispm-office-render--room plan room-id))
         (rooms (if room (list room) (plist-get plan :rooms)))
         (nodes (if room (plist-get room :nodes) (plist-get plan :nodes)))
         (visitors (unless (eq level 'map) (lispm-office-render--visitors plan nodes)))
         (*lispm-office-render-palette* (lispm-office-render--current-palette))
         (svg (svg-create (plist-get projection :pixel-width) (plist-get projection :pixel-height))))
    (dom-set-attribute svg 'viewBox (format "%s %s %s %s" (plist-get projection :x) (plist-get projection :y)
                                            (plist-get projection :width) (plist-get projection :height)))
    (dom-set-attribute svg 'preserveAspectRatio "none")
    (dom-set-attribute svg 'data-view (symbol-name level))
    (lispm-ui-svg-fill svg (plist-get projection :x) (plist-get projection :y)
                       (plist-get projection :width) (plist-get projection :height) "#aaa392")
    (dolist (item rooms) (lispm-office-render--room-drawing svg item selected level actual))
    (unless (eq level 'map)
      (let ((parents (make-hash-table :test #'equal)))
        (dolist (node (plist-get plan :nodes))
          (when-let* ((parent (plist-get node :parent))) (puthash parent t parents)))
        (dolist (node nodes)
          (lispm-office-render--desk
           svg node selected level phase actual
           (seq-find (lambda (actor) (equal (plist-get actor :key) (plist-get node :key))) visitors)
           (and (null (plist-get node :parent)) (gethash (plist-get node :key) parents)))))
      (lispm-office-render--relations svg nodes events)
      (let (hits)
        (dolist (actor visitors)
          (let* ((feet (plist-get actor :feet)) (group (lispm-office-render--group svg "office-visitor")))
            (dom-set-attribute group 'data-key (xml-escape-string (prin1-to-string (plist-get actor :key))))
            (dom-set-attribute group 'transform (format "translate(%s %s)" (- (car feet) 45) (- (cdr feet) 64)))
            (svg-rectangle group 31 63 28 3 :fill "#514b43" :opacity 0.18)
            (lispm-office-render--person group (plist-get actor :node) level phase (plist-get actor :pose))
            (push (list :key (plist-get actor :key) :x (- (car feet) 18) :y (- (cdr feet) 62) :width 55 :height 65) hits)))
        (puthash plan (cons (list scale room-id) hits) lispm-office-render--actor-hits))
      (let ((docket-room (or room (and selected (when-let* ((sel (seq-find (lambda (n) (equal selected (plist-get n :key))) nodes)))
                                                  (lispm-office-render--room plan (plist-get sel :room)))))))
        (if docket-room
            (let ((docket-hits (lispm-office-render--docket svg docket-room (plist-get docket-room :nodes) selected level phase)))
              (puthash plan (cons (list scale room-id) docket-hits) lispm-office-render--docket-hits))
          (remhash plan lispm-office-render--docket-hits))))
    (when (eq level 'map)
      (remhash plan lispm-office-render--actor-hits)
      (remhash plan lispm-office-render--docket-hits))
    svg))

(defun lispm-office-render-text (plan selected &optional room-id)
  "Insert PLAN as accessible text with SELECTED marked, optionally ROOM-ID.
Desk lines carry `lispm-office-key'; headings carry `lispm-office-room'.
No actions, data reads or timers are performed here."
  (let* ((room (lispm-office-render--room plan room-id))
         (rooms (if room (list room) (plist-get plan :rooms)))
         (parents (let ((table (make-hash-table :test #'equal)))
                    (dolist (node (plist-get plan :nodes) table)
                      (when-let* ((parent (plist-get node :parent)))
                        (puthash parent t table))))))
    (dolist (item rooms)
      (insert (propertize (format "%s  (%d agents)\n" (lispm-office-render--label (plist-get item :label))
                                  (length (plist-get item :nodes)))
                          'face 'bold 'lispm-office-room (plist-get item :id)))
      (dolist (node (plist-get item :nodes))
        (let* ((key (plist-get node :key))
               (lead-p (and (null (plist-get node :parent)) (gethash key parents)))
               (sub-p (and (plist-get node :parent) t))
               (prefix (cond (lead-p "★ ") (sub-p "↳ ") (t "")))
               (badge (lispm-office-render--badge node))
               (queued (plist-get (plist-get node :mailbox) :queued))
               (state (lispm-office-render--state node))
               (status (plist-get node :status))
               (text (format "%s %-18s [%s%s] inbox:%s%s\n"
                             (if (equal key selected) ">" " ")
                             (lispm-office-render--label (concat prefix (or (plist-get node :name) "")) 18)
                             state (if badge (concat " " badge) "") (if (numberp queued) queued "?")
                             (if (plist-get status :msg)
                                 (concat "  " (lispm-office-render--label (plist-get status :msg) 80)) ""))))
          (insert (propertize text 'lispm-office-key key 'lispm-office-room (plist-get item :id)
                              'mouse-face 'highlight 'help-echo "Inspect this agent"
                              'face (and (equal key selected) 'highlight)))
          (when (plist-get node :waits-on)
            (insert (propertize
                     (format "    Waits on: %s\n"
                             (mapconcat (lambda (target)
                                          (let ((other (lispm-office-render--endpoint target (plist-get plan :nodes))))
                                            (lispm-office-render--label (if other (plist-get other :name) (format "%S" target)))))
                                        (plist-get node :waits-on) ", "))
                     'lispm-office-key key 'lispm-office-room (plist-get item :id))))))
      (insert "\n"))))

(provide 'lispm-office-render)
;;; lispm-office-render.el ends here
