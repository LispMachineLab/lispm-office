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

(defun lispm-office-render-clear-cache ()
  "Forget cached avatar images after a character or palette change."
  (clrhash lispm-office-render--avatars))

(defun lispm-office-render--room (plan room-id)
  "Find ROOM-ID in PLAN, or nil for the overview."
  (and room-id
       (seq-find (lambda (room) (equal room-id (plist-get room :id)))
                 (plist-get plan :rooms))))

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
        (let ((font (min 42 (/ 12 scale))))
          (lispm-ui-svg-fill group (+ x 15) (+ y 15) (- w 30) 80
                             (lispm-office-render--color :header))
          (lispm-office-render--text group (plist-get room :label)
                                     (+ x 30) (+ y 70) font ink nil
                                     (floor (/ (- w 60) (* font 0.62))))
          (lispm-office-render--text group (format "%d" (length nodes))
                                     (+ x (/ w 2)) (+ y 220) (min 100 (/ 26 scale)) ink "middle")
          (lispm-office-render--text group "agents" (+ x (/ w 2)) (+ y 285)
                                     font dim "middle")
          (when (> blocked 0)
            (lispm-office-render--text group (format "%d waiting" blocked)
                                       (+ x (/ w 2)) (+ y 360) font
                                       (lispm-office-render--color :accent) "middle")))
      (lispm-ui-svg-fill group (+ x 10) (+ y 10) (- w 20) 28
                         (lispm-office-render--color :header))
      (lispm-office-render--text group (plist-get room :label) (+ x 20) (+ y 29)
                                 13 ink nil 42)
      (lispm-office-render--text group (format "%d" (length nodes)) (+ x w -20) (+ y 29)
                                 12 dim "end")
      ;; Four quiet floor mats frame the pods without changing seat geometry.
      (dotimes (pod 4)
        (let ((px (+ x 15 (* (% pod 2) 210)))
              (py (+ y 48 (* (/ pod 2) 193))))
          (lispm-ui-svg-fill group px py 200 180
                             (lispm-ui-blend (lispm-office-render--color :content)
                                            (lispm-office-render--color :accent) 0.06)))))
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

(defun lispm-office-render--avatar (svg avatar x y)
  "Draw local AVATAR at X/Y, returning non-nil on success.
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
        (lispm-ui-svg-embed svg cached x y 18 18)
        t))))

(defun lispm-office-render--desk (svg node selected level phase scale)
  "Draw NODE's desk on SVG, using SELECTED, LEVEL, PHASE and SCALE."
  (let* ((group (lispm-office-render--group svg "office-desk"))
         (x (plist-get node :x)) (y (plist-get node :y))
         (width (plist-get node :width)) (height (plist-get node :height))
         (working (eq (lispm-office-render--state node) 'working))
         (blocked (eq (lispm-office-render--state node) 'blocked))
         (ink (lispm-office-render--color :text))
         (dim (lispm-office-render--color :dim))
         (accent (lispm-office-render--state-color node))
         (queued (plist-get (plist-get node :mailbox) :queued))
         (badge (lispm-office-render--badge node)))
    (dom-set-attribute group 'data-state (symbol-name (lispm-office-render--state node)))
    (when (equal selected (plist-get node :key))
      (svg-rectangle group x y width height :fill "none"
                     :stroke (lispm-office-render--color :focus)
                     :stroke-width 2 :stroke-dasharray "3 2"))
    ;; Monitor, desk, keyboard and chair remain pixel aligned.
    (lispm-ui-svg-fill group (+ x 10) (+ y 33) 63 9 (lispm-office-render--color :chrome))
    (lispm-ui-svg-fill group (+ x 12) (+ y 42) 5 8 (lispm-office-render--color :shade))
    (lispm-ui-svg-fill group (+ x 66) (+ y 42) 5 8 (lispm-office-render--color :shade))
    (lispm-ui-svg-fill group (+ x 22) (+ y 13) 35 24 (lispm-office-render--color :frame))
    (lispm-ui-svg-fill group (+ x 25) (+ y 16) 29 17
                       (if working (lispm-office-render--color :accent)
                         (lispm-office-render--color :content)))
    (when working
      (dotimes (line 3)
        (lispm-ui-svg-fill group (+ x 28) (+ y 20 (* line 4))
                           (+ 8 (* 4 (% (+ phase line) 3))) 1
                           (lispm-office-render--color :highlight-text))))
    (lispm-ui-svg-fill group (+ x 32) (+ y 37) 23 3 (lispm-office-render--color :dim))
    (lispm-ui-svg-fill group (+ x 32) (+ y 57) 22 7 (lispm-office-render--color :shade))
    ;; A character is a little worker, with their own avatar as the face.
    (lispm-ui-svg-fill group (+ x 37) (+ y 43) 13 13 accent)
    (unless (and (eq level 'desk)
                 (lispm-office-render--avatar group (plist-get node :avatar) (+ x 35) (+ y 26)))
      (lispm-ui-svg-fill group (+ x 37) (+ y 28) 13 13 (lispm-office-render--color :light))
      (lispm-ui-svg-fill group (+ x 37) (+ y 27) 13 4 dim)
      (lispm-ui-svg-fill group (+ x 39) (+ y 34) 2 2 ink)
      (lispm-ui-svg-fill group (+ x 46) (+ y 34) 2 2 ink))
    (lispm-ui-svg-fill group (+ x 32) (+ y (if (and working (= (% phase 2) 1)) 42 46))
                       6 4 accent)
    (lispm-ui-svg-fill group (+ x 50) (+ y (if blocked 31 46)) 5 (if blocked 17 4) accent)
    (when (and (numberp queued) (> queued 0))
      (lispm-ui-svg-fill group (+ x 64) (+ y 25) 15 8 (lispm-office-render--color :light))
      (lispm-ui-svg-outline group (+ x 64) (+ y 25) 15 8 dim)
      (lispm-office-render--text group (format "%s" queued) (+ x 71) (+ y 22) 9 ink "middle" 4))
    (when (and badge (or (eq level 'desk) (memq (lispm-office-render--state node) '(blocked error))))
      (let* ((font (if (eq level 'floor) (/ 9 scale) 11))
             (bw (max 18 (+ 8 (* (length badge) font 0.6)))))
        (lispm-ui-svg-fill group (+ x 53) (+ y 3) bw (+ font 5)
                           (lispm-office-render--color :content))
        (lispm-office-render--text group badge (+ x 57) (+ y 5 font) font accent)))
    (when (eq level 'desk)
      (lispm-office-render--text group (plist-get node :name) (+ x (/ width 2)) (+ y height -4)
                                 10 ink "middle" 14)
      (lispm-office-render--text group
                                 (if (plist-get node :app-character) "APP"
                                   (upcase (format "%s" (or (plist-get node :kind) "?"))))
                                 (+ x 4) (+ y 10) 7 dim nil 5))))

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
LispM UI palette supplies every colour."
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
