;;; lispm-office-details.el --- Native identity panels for Office -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Small visual helpers for an agent's inline detail page.  Text remains
;; selectable; only the portrait and engraved rules are images.  These helpers
;; neither fetch roster details nor install observers, windows or timers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'lispm-ui-controls)
(require 'lispm-office-render)

(defun lispm-office-details--text (value)
  "Return VALUE as a single line of inert text."
  (string-trim
   (replace-regexp-in-string
    "[[:space:][:cntrl:]]+" " "
    (substring-no-properties (format "%s" (or value ""))))))

(defun lispm-office-details--measure (text)
  "Return TEXT's visible width, in pixels or terminal cells."
  (if (lispm-ui-tty-p) (string-width text) (lispm-ui-text-width text)))

(defun lispm-office-details--fit (text width)
  "Fit TEXT to positive WIDTH, retaining its faces and full help text."
  (let* ((width (max 1 (floor width)))
         (fitted (if (lispm-ui-tty-p)
                     (truncate-string-to-width text width nil nil "…")
                   (lispm-ui-text-fit text width))))
    (when (> (length fitted) 0)
      (put-text-property 0 (length fitted) 'help-echo
                         (or (get-text-property 0 'help-echo text)
                             (substring-no-properties text)) fitted))
    fitted))

(defun lispm-office-details--center (text width)
  "Insert one centered line of TEXT within WIDTH."
  (let* ((fitted (lispm-office-details--fit text width))
         (padding (max 0 (/ (- width (lispm-office-details--measure fitted)) 2))))
    (insert (if (lispm-ui-tty-p)
                (make-string (floor padding) ?\s)
              (lispm-ui-text-space padding))
            fitted "\n")))

(defun lispm-office-details--state-label (status)
  "Return a concise human label for STATUS."
  (pcase (plist-get status :state)
    ('working "Working")
    ('idle "Idle")
    ('done "Complete")
    ('error "Error")
    ('blocked (pcase (plist-get status :kind)
                ('permission "Waiting for approval")
                ('question "Needs an answer")
                ('auth "Needs authentication")
                (_ "Waiting")))
    (_ "Status unavailable")))

(defun lispm-office-details--state-chip (status)
  "Return a passive, selectable state chip for STATUS."
  (let* ((palette lispm-ui-current-palette)
         (chrome (plist-get palette :chrome))
         (accent (pcase (plist-get status :state)
                   ('working (plist-get palette :focus))
                   ('blocked "#b88432")
                   ('error (plist-get palette :alert-dark))
                   ('done "#4b8663")
                   (_ (plist-get palette :muted))))
         (ground (or (lispm-ui-blend chrome accent 0.17) chrome))
         (ink (lispm-ui-legible ground (plist-get palette :text)
                                 (plist-get palette :light) (plist-get palette :outline))))
    (propertize (concat " " (lispm-office-details--state-label status) " ")
                'face `(:inherit lispm-ui-small :foreground ,ink :background ,ground
                        :box (:line-width 1 :color ,(lispm-ui-grey palette #xA0)))
                'lispm-office-details-status (plist-get status :state))))

(defun lispm-office-details--portrait (node size)
  "Return NODE's existing portrait in an inset frame SIZE pixels square."
  (let* ((palette lispm-ui-current-palette)
         (svg (svg-create size size))
         (inside (- size 8))
         (avatar (plist-get node :avatar)))
    (lispm-ui-svg-fill svg 0 0 size size (plist-get palette :chrome))
    (lispm-ui-svg-edges svg 0 0 size size
                        (list (lispm-ui-grey palette #xFF))
                        (list (lispm-ui-grey palette #x88)))
    (lispm-ui-svg-fill svg 3 3 (- size 6) (- size 6)
                       (plist-get palette :content))
    (lispm-ui-svg-edges svg 2 2 (- size 4) (- size 4)
                        (list (lispm-ui-grey palette #x88))
                        (list (lispm-ui-grey palette #xFF)))
    ;; The renderer owns both identities and the bounded local avatar cache.
    ;; Do not add a path-only image cache that survives an avatar-change event.
    (unless (lispm-office-render--avatar svg avatar 4 4 inside)
      (lispm-office-render--pixel-portrait
       svg (aref lispm-office-render--portraits
                 (lispm-office-render--portrait-index node))
       4 4 (/ inside 16.0)))
    (lispm-ui-svg-image svg)))

(defun lispm-office-details-header (target status node width)
  "Insert TARGET's compact identity header, using STATUS and scene NODE.
WIDTH is the drawable width in graphical pixels or terminal cells.  NODE's
portrait identity is shared with the office scene, including a custom avatar.
The name and current activity are selectable text; long activity is bounded to
two lines with its complete text available as help.  Nothing is interactive."
  (unless lispm-ui-current-palette (lispm-ui-palette-follow-theme))
  (let* ((width (max 1 (floor width)))
         (tty (lispm-ui-tty-p))
         (padding (if tty 2 16))
         (content-width (max 1 (- width padding)))
         (name (lispm-office-details--text
                (or (plist-get target :name) (plist-get node :name) "Agent")))
         (identity (or node (list :key (plist-get target :key))))
         (activity (lispm-office-details--text (plist-get status :msg))))
    (unless (bolp) (insert "\n"))
    (when (and (not tty) (image-type-available-p 'svg) (>= width 40))
      (let ((size (if (>= width 72) 56 40)))
        (insert (lispm-ui-text-space (/ (- width size) 2))
                (propertize " " 'display (lispm-office-details--portrait identity size)
                            'help-echo (concat name " portrait"))
                "\n")))
    (lispm-office-details--center
     (propertize name 'face (if tty 'lispm-ui-title
                              '(:inherit lispm-ui-title :height 1.15)))
     width)
    (lispm-office-details--center (lispm-office-details--state-chip status) width)
    (unless (string-empty-p activity)
      (let* ((text (propertize activity 'face `(:foreground ,(lispm-ui-color :muted))))
             (lines (lispm-ui-text-wrap text
                                       (lambda (line)
                                         (<= (lispm-office-details--measure line) content-width)))))
        (cl-loop for line in lines for index from 0 below 2 do
                 (let ((line (if (and (= index 1) (nthcdr 2 lines))
                                 (concat (string-trim-right line) "…") line)))
                   (put-text-property 0 (length line) 'help-echo activity line)
                   (lispm-office-details--center
                    (lispm-office-details--fit line content-width) width)))))))

(defun lispm-office-details-heading (text width)
  "Insert one compact native engraved section heading TEXT within WIDTH."
  (unless lispm-ui-current-palette (lispm-ui-palette-follow-theme))
  (unless (bolp) (insert "\n"))
  (let* ((width (max 1 (floor width)))
         (padding (if (lispm-ui-tty-p) 5 32))
         (caption (lispm-office-details--fit
                   (propertize (lispm-office-details--text text) 'face 'lispm-ui-title)
                   (max 1 (- width padding)))))
    (if (< width padding)
        (insert (lispm-office-details--fit caption width))
      (insert (lispm-ui-group-edge width caption)))
    (insert "\n")))

(provide 'lispm-office-details)
;;; lispm-office-details.el ends here
