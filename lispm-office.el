;;; lispm-office.el --- A living office of agents  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ryan.K
;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-office
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (lispm "0.11.0") (lispm-kit "0.2.0") (lispm-ui "0.5.0"))
;; Keywords: tools
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; M-x lispm-office shows live conversations at persistent desks.  The
;; roster owns agent data; Office subscribes only while a window exists.
;; M-x lispm-office-demo previews the same layout without running agents.
;; Rendering never reads transcripts.  Only an opened inspector asks
;; for details, and only visible working desks or mail animate.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'lispm-kit-commands)
(require 'lispm-ui-controls)
(require 'lispm-ui-ask)
(require 'lispm-office-layout)
(require 'lispm-office-render)
(require 'lispm-office-inspect)

(declare-function lispm-agents-roster "lispm-agents-roster" ())
(declare-function lispm-agents-waiting-buffers "lispm-agents" ())
(declare-function lispm-office-demo-records "lispm-office-demo" (count))
(defvar lispm-agents-roster-change-functions)
(defvar lispm-directory)
(defvar lispm-office-mode-map)

(defgroup lispm-office nil "A living office of agents." :group 'tools)

(defcustom lispm-office-seat-file nil
  "Seat data file, or nil for office-seats.eld under `lispm-directory'."
  :type '(choice (const :tag "LispM directory" nil) file))

(defcustom lispm-office-animate t
  "Whether visible working agents and delivered messages animate."
  :type 'boolean)

(defcustom lispm-office-frame-interval 0.25
  "Seconds between animation frames; no timer runs for an idle office."
  :type 'number)

(defvar lispm-office--buffers nil "Open Office buffers, including previews.")
(defvar-local lispm-office--records nil "Last cheap live snapshot.")
(defvar-local lispm-office--state nil "Persistent seats and room allocation.")
(defvar-local lispm-office--plan nil "Geometry derived from the current snapshot.")
(defvar-local lispm-office--selected nil "Selected stable agent key.")
(defvar-local lispm-office--room nil "Focused room id, or nil for the whole office.")
(defvar-local lispm-office--scale 1.0 "Requested drawing scale.")
(defvar-local lispm-office--fit t "Whether resize fits the current view.")
(defvar-local lispm-office--text nil "Whether to use text on graphical displays too.")
(defvar-local lispm-office--timer nil "Visible animation timer, or nil.")
(defvar-local lispm-office--phase 0 "Working pose, toggled by animation.")
(defvar-local lispm-office--flights nil "Actual message events with expiry times.")
(defvar-local lispm-office--sequence 0 "Last message sequence shown.")
(defvar-local lispm-office--demo nil "Non-nil in an isolated preview.")
(defvar-local lispm-office--size nil "Last visible window size.")
(defvar-local lispm-office--drawing nil "Non-nil while drawing this buffer.")
(defvar-local lispm-office--seat-path nil "Seat file selected when Office opened.")
(defvar-local lispm-office--dirty nil "Whether hidden content needs drawing when shown.")
(defvar-local lispm-office--unsaved nil "Whether seat changes still need writing.")
(defvar-local lispm-office--floor-start 1 "Start of desk content after the waiting strip.")

(defun lispm-office--window ()
  "Return a window displaying the current Office buffer."
  (get-buffer-window (current-buffer) 'visible))

(defun lispm-office--graphic-p ()
  "Whether the visible Office window supports SVG images."
  (and (not lispm-office--text)
       (when-let* ((window (lispm-office--window)))
         (and (display-graphic-p (window-frame window))
              (image-type-available-p 'svg)))))

(defun lispm-office--visible-nodes ()
  "Return agents in the current room or whole-office view."
  (seq-filter (lambda (node)
                (or (null lispm-office--room)
                    (equal lispm-office--room (plist-get node :room))))
              (plist-get lispm-office--plan :nodes)))

(defun lispm-office--dimensions ()
  "Return the available drawing width and height."
  (if-let* ((window (lispm-office--window)))
      (cons (max 240 (- (window-body-width window t) 24))
            (max 180 (- (window-body-height window t) 130)))
    '(1000 . 600)))

(defun lispm-office--fit-scale ()
  "Fit the active room or office to its visible window."
  (let* ((room (seq-find (lambda (room)
                           (equal (plist-get room :id) lispm-office--room))
                         (plist-get lispm-office--plan :rooms)))
         (width (max 1 (or (plist-get room :width)
                           (plist-get lispm-office--plan :width) 1)))
         (height (max 1 (or (plist-get room :height)
                            (plist-get lispm-office--plan :height) 1)))
         (size (lispm-office--dimensions)))
    (setq lispm-office--scale
          (min 1.5 (/ (float (car size)) width) (/ (float (cdr size)) height)))))

(defun lispm-office--waiting ()
  "Return waiting records in the agent sidebar's existing order."
  (let ((waiting (seq-filter
                  (lambda (record)
                    (memq (plist-get (plist-get record :status) :state) '(blocked error)))
                  lispm-office--records)))
    (if (or lispm-office--demo (not (fboundp 'lispm-agents-waiting-buffers)))
        (append (seq-filter (lambda (r) (eq (plist-get (plist-get r :status) :state) 'blocked)) waiting)
                (seq-filter (lambda (r) (eq (plist-get (plist-get r :status) :state) 'error)) waiting))
      (let ((by-buffer (make-hash-table :test #'eq)))
        (dolist (record waiting) (puthash (plist-get record :buffer) record by-buffer))
        (delq nil (mapcar (lambda (buffer) (gethash buffer by-buffer))
                         (lispm-agents-waiting-buffers)))))))

(defun lispm-office--button (label function)
  "Insert a LABEL button invoking FUNCTION in the Office buffer."
  (let ((owner (current-buffer)))
    (lispm-ui-insert-push-button
     label (lambda () (when (buffer-live-p owner)
                        (with-current-buffer owner (funcall function)))))))

(defun lispm-office--draw ()
  "Draw cached data, without inspecting or querying an agent."
  (unless lispm-office--drawing
    (let ((lispm-office--drawing t)
          (inhibit-read-only t)
          (old-point (point))
          (window (lispm-office--window)))
      (when lispm-office--fit (lispm-office--fit-scale))
      (lispm-office--prune-flights)
      (setq lispm-office--size (lispm-office--dimensions) lispm-office--dirty nil)
      (erase-buffer)
      (insert (propertize (if lispm-office--demo "Office — Preview" "Office") 'face 'bold))
      (insert (format "   %d conversations · %d rooms\n"
                      (length lispm-office--records)
                      (length (plist-get lispm-office--plan :rooms))))
      (lispm-office--button "Fit" #'lispm-office-fit)
      (insert " ") (lispm-office--button "All rooms" #'lispm-office-overview)
      (insert " ") (lispm-office--button "Room…" #'lispm-office-choose-room)
      (insert " ") (lispm-office--button "−" #'lispm-office-zoom-out)
      (insert " ") (lispm-office--button "+" #'lispm-office-zoom-in)
      (insert " ") (lispm-office--button (if lispm-office--text "Pictures" "Text") #'lispm-office-toggle-text)
      (insert "\nWaiting: ")
      (if-let* ((waiting (lispm-office--waiting)))
          (progn
            (dolist (record (seq-take waiting 6))
              (let ((key (plist-get record :key)))
                (when key
                  (insert-text-button
                   (truncate-string-to-width
                    (replace-regexp-in-string "[[:cntrl:]]" " "
                                              (substring-no-properties (or (plist-get record :name) "Agent")))
                    18 nil nil "…")
                   'follow-link t 'lispm-office-key key
                   'action (lambda (_) (lispm-office--select key t)))
                  (insert "  "))))
            (when (> (length waiting) 6)
              (insert (format "+%d more (n to cycle)" (- (length waiting) 6)))))
        (insert "No agents need attention."))
      (insert "\n")
      (when-let* ((selected (seq-find (lambda (r) (equal lispm-office--selected (plist-get r :key)))
                                    lispm-office--records)))
        (insert (truncate-string-to-width
                 (replace-regexp-in-string
                  "[[:cntrl:]]" " "
                  (format "Selected: %s · %s · %s" (plist-get selected :name)
                          (or (plist-get (plist-get selected :status) :state) 'unknown)
                          (or (plist-get (plist-get selected :status) :msg) "")))
                 (if window (window-body-width window) 100) nil nil "…") "\n"))
      (insert "\n")
      (setq lispm-office--floor-start (point))
      (cond
       ((null (plist-get lispm-office--plan :nodes))
        (insert "No live conversations with a known session id yet.\n"
                "Start a LispM, Claude Code or Codex conversation, then return here.\n"))
       ((lispm-office--graphic-p)
        (let* ((now (float-time))
               (events (mapcar (lambda (event)
                                 (plist-put (copy-sequence event) :progress
                                            (min 1.0 (max 0.0 (- now (plist-get event :started))))))
                               lispm-office--flights))
               (svg (lispm-office-render-svg lispm-office--plan lispm-office--selected
                                              lispm-office--scale lispm-office--phase
                                              lispm-office--room events))
               (start (point)))
          (insert-image (lispm-ui-svg-image svg) "Office floor")
          (add-text-properties start (point)
                               (list 'keymap lispm-office-mode-map
                                     'help-echo "Click a desk to inspect it; click a map room to enter."))
          (insert "\n")))
       (t (lispm-office-render-text lispm-office--plan lispm-office--selected lispm-office--room)))
      (when-let* ((unknown (seq-filter (lambda (r) (null (plist-get r :key))) lispm-office--records)))
        (insert "\nStarting: " (mapconcat (lambda (r) (substring-no-properties (or (plist-get r :name) "Agent"))) unknown ", ")
                " (waiting for session ids)\n"))
      (insert "\nArrows: desk   n: waiting   RET: inspect   w/m/c: tabs\n"
              "o: chat   s: message   a/A: approve/all   d: deny\n"
              "+/−: zoom   0: fit   h: overview   g: refresh   q: close\n")
      (when lispm-office--demo (insert "Preview data only. Agent actions are disabled.  C-u D changes the count.\n"))
      (goto-char (min old-point (point-max)))
      (when window (set-window-hscroll window 0)))))

(defun lispm-office--animated-p ()
  "Whether visible graphical content currently needs animation."
  (and lispm-office-animate (lispm-office--graphic-p)
       (or (lispm-office-render-visible-events lispm-office--plan lispm-office--scale
                                               lispm-office--room lispm-office--flights)
           (and (>= (plist-get (lispm-office-render-projection
                                lispm-office--plan lispm-office--scale lispm-office--room) :scale) 0.45)
                (seq-some (lambda (record)
                            (eq (plist-get (plist-get record :status) :state) 'working))
                          (lispm-office--visible-nodes))))))

(defun lispm-office--sync-timer ()
  "Start or cancel the animation timer according to visible work."
  (lispm-office--prune-flights)
  (if (lispm-office--animated-p)
      (unless lispm-office--timer
        (setq lispm-office--timer
              (run-at-time (max 0.1 lispm-office-frame-interval)
                           (max 0.1 lispm-office-frame-interval)
                           #'lispm-office--tick (current-buffer))))
    (when lispm-office--timer (cancel-timer lispm-office--timer))
    (setq lispm-office--timer nil)))

(defun lispm-office--prune-flights ()
  "Discard expired message animations without scheduling work."
  (setq lispm-office--flights
        (seq-filter (lambda (event) (< (- (float-time) (plist-get event :started)) 1.0))
                    lispm-office--flights)))

(defun lispm-office--tick (buffer)
  "Advance BUFFER's visible animation; never read agent data."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (lispm-office--prune-flights)
      (if (lispm-office--graphic-p)
          (progn (setq lispm-office--phase (- 1 lispm-office--phase))
                 (lispm-office--draw))
        (setq lispm-office--flights nil))
      (lispm-office--sync-timer))))

(defun lispm-office--ingest (records &optional event)
  "Accept RECORDS and one batch EVENT, preserving seats and selection."
  (let* ((state (lispm-office-layout-reconcile lispm-office--state records))
         (changed (not (equal state lispm-office--state))))
    (setq lispm-office--records records lispm-office--state state
          lispm-office--plan (lispm-office-layout-plan state records))
    (unless (seq-find (lambda (r) (equal lispm-office--selected (plist-get r :key)))
                      (plist-get lispm-office--plan :nodes))
      (setq lispm-office--selected (plist-get (car (plist-get lispm-office--plan :nodes)) :key)))
    (when (and lispm-office--room
               (not (seq-find (lambda (r) (equal lispm-office--room (plist-get r :id)))
                              (plist-get lispm-office--plan :rooms))))
      (setq lispm-office--room nil))
    (when (and changed (not lispm-office--demo) lispm-office--seat-path)
      (setq lispm-office--unsaved t)
      (lispm-office--save-seats))
    (dolist (message (plist-get event :events))
      (let ((sequence (plist-get message :sequence)))
        (when (and (numberp sequence) (> sequence lispm-office--sequence))
          (setq lispm-office--sequence sequence)
          (when (and lispm-office-animate (lispm-office--graphic-p)
                     (memq (plist-get message :type) '(message-queued message-taken message-delivered)))
            (push (plist-put (copy-sequence message) :started (float-time)) lispm-office--flights)))))
    ;; A burst cannot leave an unbounded visual history.
    (when (> (length lispm-office--flights) 32) (setcdr (nthcdr 31 lispm-office--flights) nil))
    (if (lispm-office--window) (lispm-office--draw) (setq lispm-office--dirty t))
    (lispm-office--sync-timer)))

(defun lispm-office--save-seats ()
  "Write pending seat changes, retaining them for retry on failure."
  (when (and lispm-office--unsaved lispm-office--seat-path (not lispm-office--demo))
    (condition-case err
        (progn (lispm-office-layout-write lispm-office--state lispm-office--seat-path)
               (setq lispm-office--unsaved nil))
      (error (message "Office could not save seats (g retries): %s" (error-message-string err))))))

(defun lispm-office--changed (keys fields event)
  "Update open live Offices after KEYS change, carrying EVENT."
  (when (or (memq 'avatar fields) (memq 'character fields))
    (lispm-office-render-clear-cache))
  (let ((buffers (seq-filter (lambda (buffer)
                               (and (buffer-live-p buffer)
                                    (not (buffer-local-value 'lispm-office--demo buffer))))
                             lispm-office--buffers)))
    (when buffers
      (let ((records (lispm-agents-roster)))
        (dolist (buffer buffers)
          (with-current-buffer buffer
            (lispm-office--ingest records event)
            (lispm-office-inspect-refresh buffer keys)))))))

(defun lispm-office--windows-changed (&rest _)
  "Adjust fit and animation after visibility or window dimensions change."
  (dolist (buffer lispm-office--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (lispm-office-inspect-visible-refresh buffer)
        (when (and (lispm-office--window)
                   (or lispm-office--dirty
                       (not (equal lispm-office--size (lispm-office--dimensions)))))
          (lispm-office--draw))
        (lispm-office--sync-timer)))))

(defun lispm-office--palette-changed ()
  "Redraw each Office with the new UI palette."
  (lispm-office-render-clear-cache)
  (dolist (buffer lispm-office--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (if (lispm-office--window) (lispm-office--draw) (setq lispm-office--dirty t))))))

(defun lispm-office--close ()
  "Remove this Office's observer, inspector and timer."
  (lispm-office--save-seats)
  (when lispm-office--timer (cancel-timer lispm-office--timer))
  (setq lispm-office--timer nil)
  (lispm-office-inspect-close (current-buffer))
  (setq lispm-office--buffers (delq (current-buffer) lispm-office--buffers))
  (unless (seq-some (lambda (buffer)
                     (and (buffer-live-p buffer)
                          (not (buffer-local-value 'lispm-office--demo buffer)))) lispm-office--buffers)
    (remove-hook 'lispm-agents-roster-change-functions #'lispm-office--changed))
  (unless lispm-office--buffers
    (remove-hook 'window-size-change-functions #'lispm-office--windows-changed)
    (remove-hook 'window-state-change-functions #'lispm-office--windows-changed)
    (remove-hook 'lispm-ui-palette-changed-hook #'lispm-office--palette-changed)))

(defun lispm-office--select (key &optional inspect)
  "Select KEY, enter its room if needed, and optionally INSPECT."
  (when-let* ((node (seq-find (lambda (r) (equal key (plist-get r :key)))
                            (plist-get lispm-office--plan :nodes))))
    (setq lispm-office--selected key)
    (when (or (< (plist-get (lispm-office-render-projection
                            lispm-office--plan lispm-office--scale lispm-office--room) :scale) 0.45)
              (and (null lispm-office--room) (lispm-office--graphic-p)
                   (let ((projection (lispm-office-render-projection lispm-office--plan lispm-office--scale))
                         (size (lispm-office--dimensions)))
                     (or (> (plist-get projection :pixel-width) (car size))
                         (> (plist-get projection :pixel-height) (cdr size)))))
              (and lispm-office--room (not (equal lispm-office--room (plist-get node :room)))))
      (setq lispm-office--room (plist-get node :room) lispm-office--fit t))
    (lispm-office--draw)
    (unless (lispm-office--graphic-p)
      (let ((position (text-property-any lispm-office--floor-start (point-max) 'lispm-office-key key)))
        ;; Text properties may contain an equal copy of a stable key.
        (unless position
          (setq position lispm-office--floor-start)
          (while (and (< position (point-max))
                      (not (equal key (get-text-property position 'lispm-office-key))))
            (setq position (next-single-property-change position 'lispm-office-key nil (point-max)))))
        (when (and position (< position (point-max)))
          (goto-char position)
          (when-let* ((window (lispm-office--window)))
            (set-window-point window position)))))
    (lispm-office--sync-timer)
    (when inspect (lispm-office-inspect-selected))))

(defun lispm-office--key ()
  "Return the selected live key, refusing preview actions."
  (when lispm-office--demo (user-error "This is a preview; open M-x lispm-office for live agents"))
  (or lispm-office--selected (user-error "No agent selected")))

(defun lispm-office-inspect-selected (&optional tab)
  "Inspect the selected agent on TAB."
  (interactive)
  (lispm-office-inspect (lispm-office--key) tab (current-buffer)))

(defun lispm-office-work () "Show the selected agent's current work." (interactive) (lispm-office-inspect-selected 'work))
(defun lispm-office-mailbox () "Show the selected agent's mailbox." (interactive) (lispm-office-inspect-selected 'mailbox))
(defun lispm-office-character () "Show the selected agent's character." (interactive) (lispm-office-inspect-selected 'character))
(defun lispm-office-chat () "Open the selected agent's conversation." (interactive) (lispm-office-open-chat (lispm-office--key)))
(defun lispm-office-message ()
  "Compose a message to the selected agent."
  (interactive)
  (let* ((key (lispm-office--key)) (text (read-string "Message to agent: ")))
    (unless (string-blank-p text) (lispm-office-send key text))))
(defun lispm-office-approve-selected () "Review and approve a pending call." (interactive) (lispm-office-approve (lispm-office--key)))
(defun lispm-office-approve-all-selected () "Preview and approve this agent's pending calls." (interactive) (lispm-office-approve-all (lispm-office--key)))
(defun lispm-office-deny-selected () "Deny a pending call with a reason." (interactive) (lispm-office-deny (lispm-office--key)))
(defun lispm-office-abort-selected () "Confirm stopping this agent and clearing its queue." (interactive) (lispm-office-abort (lispm-office--key)))

(defun lispm-office--move (dx dy)
  "Select the nearest desk in direction DX, DY."
  (let* ((nodes (plist-get lispm-office--plan :nodes))
         (selected (seq-find (lambda (n) (equal lispm-office--selected (plist-get n :key))) nodes)))
    (if (not selected)
        (when nodes (lispm-office--select (plist-get (car nodes) :key)))
      (let (best best-distance)
        (dolist (node nodes)
          (let* ((x (- (plist-get node :x) (plist-get selected :x)))
                 (y (- (plist-get node :y) (plist-get selected :y)))
                 (forward (+ (* dx x) (* dy y)))
                 (side (abs (+ (* dy x) (* dx y)))))
            (when (> forward 0)
              (let ((distance (+ forward (* 3 side))))
                (when (or (null best-distance) (< distance best-distance))
                  (setq best node best-distance distance))))))
        (when best (lispm-office--select (plist-get best :key)))))))
(defun lispm-office-left () "Select a desk to the left." (interactive) (lispm-office--move -1 0))
(defun lispm-office-right () "Select a desk to the right." (interactive) (lispm-office--move 1 0))
(defun lispm-office-up () "Select a desk above." (interactive) (lispm-office--move 0 -1))
(defun lispm-office-down () "Select a desk below." (interactive) (lispm-office--move 0 1))

(defun lispm-office-next-waiting ()
  "Select the next agent waiting for the user."
  (interactive)
  (let* ((keys (delq nil (mapcar (lambda (r) (plist-get r :key)) (lispm-office--waiting))))
         (tail (member lispm-office--selected keys)))
    (if keys (lispm-office--select (or (cadr tail) (car keys)))
      (message "No agents need attention"))))

(defun lispm-office-mouse (event)
  "Select a desk or enter a map room at mouse EVENT."
  (interactive "e")
  (let* ((pos (event-start event)) (window (posn-window pos)))
    (when (windowp window)
      (select-window window)
      (let* ((point (posn-point pos))
             (key (and (integerp point) (get-text-property point 'lispm-office-key)))
             (xy (posn-object-x-y pos))
             (hit (and xy (lispm-office--graphic-p)
                       (lispm-office-render-hit-test lispm-office--plan (car xy) (cdr xy)
                                                     lispm-office--scale lispm-office--room))))
        (cond
         (key (lispm-office--select key t))
         ((plist-get hit :key) (lispm-office--select (plist-get hit :key) t))
         ((plist-member hit :room)
          (setq lispm-office--room (plist-get hit :room) lispm-office--fit t)
          (lispm-office--draw) (lispm-office--sync-timer)))))))

(defun lispm-office-fit ()
  "Fit the current room or overview."
  (interactive)
  (setq lispm-office--fit t) (lispm-office--draw) (lispm-office--sync-timer))
(defun lispm-office-overview ()
  "Show every occupied room."
  (interactive)
  (setq lispm-office--room nil) (lispm-office-fit))
(defun lispm-office--zoom (factor)
  "Change the drawing scale by FACTOR."
  (setq lispm-office--fit nil lispm-office--scale (max 0.08 (min 2.5 (* lispm-office--scale factor))))
  (lispm-office--draw) (lispm-office--sync-timer))
(defun lispm-office-zoom-in () "Look closer at the office." (interactive) (lispm-office--zoom 1.25))
(defun lispm-office-zoom-out () "Look at more of the office." (interactive) (lispm-office--zoom 0.8))
(defun lispm-office-toggle-text ()
  "Switch between the graphical and text office."
  (interactive)
  (setq lispm-office--text (not lispm-office--text))
  (lispm-office--draw) (lispm-office--sync-timer))
(defun lispm-office-choose-room ()
  "Choose a project room from the keyboard."
  (interactive)
  (let* ((choices (mapcar (lambda (room) (cons (format "%s [%s]" (plist-get room :label) (plist-get room :id))
                                               (plist-get room :id)))
                         (plist-get lispm-office--plan :rooms)))
         (choice (and choices (completing-read "Room: " choices nil t))))
    (when choice (setq lispm-office--room (cdr (assoc choice choices))) (lispm-office-fit))))

(defun lispm-office-compact ()
  "Confirm removing empty seats and repacking the occupied office."
  (interactive)
  (when (lispm-ui-confirm "Compact the office? Saved empty seats will be removed and agents may move.")
    (setq lispm-office--state (lispm-office-layout-compact lispm-office--state lispm-office--records))
    (when (and (not lispm-office--demo) lispm-office--seat-path)
      (setq lispm-office--unsaved t)
      (lispm-office--save-seats))
    (setq lispm-office--room nil)
    (lispm-office--ingest lispm-office--records)))

(defun lispm-office-refresh ()
  "Read one fresh roster snapshot and update the selected inspector."
  (interactive)
  (if lispm-office--demo (lispm-office--draw)
    (lispm-office--ingest (lispm-agents-roster))
    (lispm-office--save-seats)
    (lispm-office-inspect-refresh (current-buffer) nil)))

(defun lispm-office-status ()
  "Return public view status without reading transcripts or files."
  (list :agents (length lispm-office--records)
        :rooms (length (plist-get lispm-office--plan :rooms))
        :waiting (length (lispm-office--waiting))
        :selected lispm-office--selected :preview lispm-office--demo))

(defun lispm-office-quit ()
  "Close this Office and release its observers and inspector."
  (interactive)
  (quit-window t))

(define-derived-mode lispm-office-mode special-mode "Office"
  "A live office.  Select desks with arrows and inspect with RET."
  (setq-local truncate-lines t cursor-type nil)
  (add-hook 'kill-buffer-hook #'lispm-office--close nil t)
  (add-hook 'change-major-mode-hook #'lispm-office--close nil t))

(lispm-kit-define-commands lispm-office-mode
  (lispm-office-left :key ("<left>" "C-b"))
  (lispm-office-right :key ("<right>" "C-f"))
  (lispm-office-up :key ("<up>" "C-p"))
  (lispm-office-down :key ("<down>" "C-n"))
  (lispm-office-mouse :key "<mouse-1>")
  :menu "Office"
  (lispm-office-inspect-selected :key "RET" :label "Inspect Agent")
  (lispm-office-work :key "w" :label "Work")
  (lispm-office-mailbox :key "m" :label "Mailbox")
  (lispm-office-character :key "c" :label "Character")
  (lispm-office-chat :key "o" :label "Open Chat")
  (lispm-office-message :key "s" :label "Send Message…")
  (lispm-office-next-waiting :key ("n" "TAB") :label "Next Waiting Agent")
  "---"
  (lispm-office-approve-selected :key "a" :label "Approve Call…")
  (lispm-office-approve-all-selected :key "A" :label "Approve All…")
  (lispm-office-deny-selected :key "d" :label "Deny Call…")
  (lispm-office-abort-selected :key "x" :label "Abort Agent…")
  "---"
  (lispm-office-zoom-in :key ("+" "=") :label "Zoom In")
  (lispm-office-zoom-out :key "-" :label "Zoom Out")
  (lispm-office-fit :key "0" :label "Fit")
  (lispm-office-overview :key "h" :label "All Rooms")
  (lispm-office-choose-room :key "r" :label "Choose Room…")
  (lispm-office-toggle-text :key "t" :label "Text View" :style toggle :selected lispm-office--text)
  (lispm-office-compact :label "Compact Saved Seats…")
  (lispm-office-refresh :key "g" :label "Refresh")
  (lispm-office-demo :key "D" :label "Preview…")
  (lispm-office-quit :key "q" :label "Close Office"))

(defun lispm-office--observe ()
  "Install observers shared by the open Office buffers."
  (cl-pushnew (current-buffer) lispm-office--buffers)
  (unless lispm-office--demo
    (add-hook 'lispm-agents-roster-change-functions #'lispm-office--changed))
  (add-hook 'window-size-change-functions #'lispm-office--windows-changed)
  (add-hook 'window-state-change-functions #'lispm-office--windows-changed)
  (add-hook 'lispm-ui-palette-changed-hook #'lispm-office--palette-changed))

;;;###autoload
(defun lispm-office ()
  "Open a live, event-driven office of LispM conversations."
  (interactive)
  (unless (require 'lispm-agents-roster nil t)
    (user-error "Office needs the agent roster API (lispm-agent PR #135); M-x lispm-office-demo previews it"))
  (let* ((path (or lispm-office-seat-file
                   (expand-file-name "office-seats.eld" lispm-directory)))
         (buffer (get-buffer-create "*LispM Office*")))
    (with-current-buffer buffer
      (unless (and (derived-mode-p 'lispm-office-mode) lispm-office--seat-path)
        ;; Read before initializing, so reopening after an error cannot replace
        ;; the corrupt file with an empty layout.
        (let ((state (lispm-office-layout-read path)))
          (lispm-office-mode)
          (setq lispm-office--state state lispm-office--seat-path path)))
      (lispm-office--observe))
    (pop-to-buffer buffer)
    (lispm-office-refresh)
    buffer))

;;;###autoload
(defun lispm-office-demo (&optional count)
  "Preview COUNT simulated agents, default twelve, without side effects."
  (interactive (list (if current-prefix-arg (read-number "Preview agent count: " 40) 12)))
  (require 'lispm-office-demo)
  (let ((buffer (get-buffer-create "*LispM Office Preview*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'lispm-office-mode) (lispm-office-mode))
      (setq lispm-office--demo t lispm-office--fit t lispm-office--room nil)
      (lispm-office--observe))
    (pop-to-buffer buffer)
    (lispm-office--ingest (lispm-office-demo-records (or count 12)))
    buffer))

(provide 'lispm-office)
;;; lispm-office.el ends here
