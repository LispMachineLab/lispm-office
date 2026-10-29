;;; lispm-office.el --- Visualize current work in LispM Agent  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ryan.K
;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-office
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (lispm "0.11.0") (lispm-kit "0.2.0") (lispm-ui "0.5.0"))
;; Keywords: tools
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Enable `lispm-office-plugin-mode' to toggle this view from agent sessions.
;; M-x lispm-office switches the conversation window to its work view.  The
;; roster owns agent data; Office subscribes while a live view is open.
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
(declare-function lispm-agents-roster-key "lispm-agents-roster" (subject))
(declare-function lispm-agents-buffer-p "lispm-agents" (buffer))
(declare-function lispm-agents-waiting-buffers "lispm-agents" ())
(declare-function lispm-office-demo-records "lispm-office-demo" (count))
(declare-function lispm-desktop-platinum-tabs "lispm-desktop-platinum-controls" (tabs width &optional face))
(declare-function lispm-desktop-platinum-tabs-width "lispm-desktop-platinum-controls" (labels &optional face))
(declare-function lispm-terminal-p "lispm-terminal" (&optional frame))
(defvar lispm-agents-roster-change-functions)
(defvar lispm-directory)
(defvar lispm-office-mode-map)
(defvar lispm-agents-main-window-function)
(defvar lispm-desktop-conversation-buffer)

(defgroup lispm-office nil "Current-work visualization for LispM Agent." :group 'tools)

(defcustom lispm-office-seat-file nil
  "Seat data file, or nil for office-seats.eld under `lispm-directory'."
  :type '(choice (const :tag "LispM directory" nil) file))

(defcustom lispm-office-animate t
  "Whether visible working agents and delivered messages animate."
  :type 'boolean)

(defcustom lispm-office-frame-interval 0.12
  "Seconds between animation frames; no timer runs for an idle office."
  :type 'number)

(defvar lispm-office--buffers nil "Open Office buffers, including previews.")
(defvar-local lispm-office--all-records nil "Full cheap roster, retained for global seat reservations.")
(defvar-local lispm-office--records nil "Records visible in the chosen scope.")
(defvar-local lispm-office--scope 'all "Visible scope: session, project or all.")
(defvar-local lispm-office--project-root nil "Explicit directory selected from a project folder.")
(defvar-local lispm-office--working-only nil "Whether Project scope hides agents without current work.")
(defvar-local lispm-office--state nil "Persistent seats and room allocation.")
(defvar-local lispm-office--plan nil "Geometry derived from the current snapshot.")
(defvar-local lispm-office--display-plan nil "Responsive geometry used by the displayed image.")
(defvar-local lispm-office--display-context nil "Snapshot and room used for the displayed geometry.")
(defvar-local lispm-office--chrome-height 0 "Measured height of controls above the drawing.")
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
(defvar-local lispm-office--floor-start 1 "Start of desk content after the view menu.")
(defvar-local lispm-office--source-buffer nil "Agent buffer whose current work is shown.")
(defvar-local lispm-office--source-key nil "Last identity followed from the source buffer.")
(defvar-local lispm-office--focus-frame nil
  "Focus frame owning this view exclusively, or nil for a shared view.
Views first opened in ordinary frames can belong to inactive workspaces;
they must survive the closing of a Focus frame that later reuses them.")

;; Return contexts contain live buffers and markers.  Keep them in this Emacs
;; session's window configurations, but never serialize them to desktop files.
(add-to-list 'window-persistent-parameters '(lispm-office-source . t))

(defun lispm-office--ensure-ui ()
  "Initialize LispM UI controls when the host has not done so."
  (unless lispm-ui-current-palette (lispm-ui-palette-follow-theme)))

(defun lispm-office--view-switcher ()
  "Return the host's adjacent Conversation / Work tabs.
A directory view has no conversation tab or inferred conversation target."
  (let ((work (derived-mode-p 'lispm-office-mode)))
    (if (and work (not (lispm-office--source-p lispm-office--source-buffer))) ""
      (let ((tabs
             (mapcar
              (lambda (entry)
                (let* ((active (eq (not (null work)) (cdr entry)))
                       (map (make-sparse-keymap)))
                  (define-key map [header-line mouse-1]
                              (lambda (event)
                                (interactive "e")
                                (select-window (posn-window (event-start event)))
                                (unless active (lispm-office-toggle))))
                  (list (car entry) active 'local-map map 'keymap map
                        'mouse-face 'highlight 'pointer 'arrow
                        'help-echo (concat "Switch to " (car entry))
                        'lispm-ui-label (car entry))))
              '(("Conversation") ("Work" . t)))))
        (if (and (fboundp 'lispm-desktop-platinum-tabs)
                 (fboundp 'lispm-desktop-platinum-tabs-width))
            (lispm-desktop-platinum-tabs
             tabs (min (window-body-width nil t)
                       (lispm-desktop-platinum-tabs-width (mapcar #'car tabs))))
          ;; Without Desktop, use Emacs' native tab faces, retaining the same
          ;; event maps and adjacent tabs rather than imitating a push button.
          (mapconcat
           (pcase-lambda (`(,label ,active . ,properties))
             (apply #'propertize (concat " " label " ")
                    'face (if active 'tab-line-tab-current 'tab-line-tab) properties))
           tabs ""))))))

(defun lispm-office--restore-window (window)
  "Restore WINDOW's conversation and its exact saved viewing position."
  (let* ((saved (window-parameter window 'lispm-office-source))
         (source (plist-get saved :buffer))
         (point (plist-get saved :point))
         (start (plist-get saved :start)))
    (when saved
      (set-window-parameter window 'lispm-office-source nil)
      (when (eq (window-buffer window) (plist-get saved :view))
        (set-window-buffer window (if (buffer-live-p source) source
                                    (other-buffer (window-buffer window) t)))
        (when (buffer-live-p source)
          (set-window-point window (or (and (markerp point) (marker-position point))
                                       (plist-get saved :point-position) 1))
          (set-window-start window (or (and (markerp start) (marker-position start))
                                       (plist-get saved :start-position) 1) t)
          (set-window-hscroll window (plist-get saved :hscroll))
          (set-window-vscroll window (plist-get saved :vscroll) t)))
      ;; Tab window configurations retain this plist.  Keep integer fallbacks
      ;; before releasing its markers, so a later restore can recover its view.
      (when (and (markerp point) (marker-position point))
        (setf (plist-get saved :point-position) (marker-position point))
        (set-marker point nil))
      (when (and (markerp start) (marker-position start))
        (setf (plist-get saved :start-position) (marker-position start))
        (set-marker start nil)))))

(defun lispm-office-cleanup-windows (&rest _)
  "Clean up saved Work return contexts after workspace or Focus navigation.
Restore only generated placeholders with an original return context.  When
Focus replaced inline details with a new chat, retain that new conversation."
  (save-selected-window
    (walk-windows
     (lambda (window)
       (let* ((saved (window-parameter window 'lispm-office-source))
              (view (plist-get saved :view))
              (buffer (window-buffer window))
              (name (or (plist-get saved :view-name)
                        (and (bufferp view) (buffer-last-name view)))))
         (when (and saved (buffer-live-p view) (not (eq buffer view))
                    (buffer-local-value 'lispm-office-inspect--inline view)
                    (fboundp 'lispm-terminal-p) (lispm-terminal-p (window-frame window)))
           ;; The native session list can replace Work without using its
           ;; keymap.  Release obsolete return markers without replacing the
           ;; newly displayed chat, then close an otherwise hidden detail page.
           (lispm-office--restore-window window)
           (unless (get-buffer-window view t) (kill-buffer view)))
         (when (and saved (bufferp view) (not (buffer-live-p view)) name
                    (with-current-buffer buffer
                      (and (eq major-mode 'special-mode)
                           (string-prefix-p (format " *Old buffer %s*" name) (buffer-name))
                           (string-prefix-p "This window displayed the buffer " (buffer-string)))))
           ;; Set the saved source before restoring its position; the normal
           ;; return path checks that the window still displays the live view.
           (let ((source (plist-get saved :buffer)))
             (set-window-buffer window (if (buffer-live-p source) source (other-buffer buffer t)))
             (when (buffer-live-p source)
               (set-window-point window (or (plist-get saved :point-position) 1))
               (set-window-start window (or (plist-get saved :start-position) 1) t)
               (set-window-hscroll window (or (plist-get saved :hscroll) 0))
               (set-window-vscroll window (or (plist-get saved :vscroll) 0) t)))
           (lispm-office--restore-window window)
           (unless (get-buffer-window buffer t) (kill-buffer buffer)))))
     'no-minibuf t)))

(defun lispm-office--frame-deleted (frame)
  "Release views owned exclusively by the closing Focus FRAME.
Keep views shown in another frame, and ordinary workspace views even when
their saved layout is inactive and has no currently visible window."
  (save-current-buffer
    (save-selected-window
      (dolist (buffer (copy-sequence lispm-office--buffers))
        (when (and (buffer-live-p buffer)
                   (eq (buffer-local-value 'lispm-office--focus-frame buffer) frame))
          (with-current-buffer buffer
            (setq lispm-office--focus-frame nil))
          (unless (seq-some (lambda (window) (not (eq (window-frame window) frame)))
                            (get-buffer-window-list buffer nil t))
            (kill-buffer buffer)))))))

(defun lispm-office-return ()
  "Return this window to its conversation, preserving the running session."
  (interactive)
  (let ((view (current-buffer)) (window (selected-window)))
    (if (eq (plist-get (window-parameter window 'lispm-office-source) :view) view)
        (save-current-buffer (lispm-office--restore-window window))
      (when (buffer-live-p lispm-office--source-buffer)
        (set-window-buffer window lispm-office--source-buffer)))
    (unless (get-buffer-window view t) (kill-buffer view))
    (when (window-live-p window) (select-window window))))

(defun lispm-office--prepare-navigation (owner)
  "Restore OWNER's current workspace before host navigation saves its windows.
The host may switch tabs or workspaces.  Leaving a Work window or its Inspector
in that saved state would retain a buffer that navigation later closes."
  (when (buffer-live-p owner)
    (let ((windows (get-buffer-window-list owner nil (selected-frame))))
      (save-current-buffer
        (lispm-office-inspect-close owner)
        (dolist (window windows)
          (when (window-live-p window) (lispm-office--restore-window window)))))))

;;;###autoload
(defun lispm-office-toggle ()
  "Switch this Agent window between its conversation and work visualization."
  (interactive)
  (if (derived-mode-p 'lispm-office-mode)
      (lispm-office-return)
    (lispm-office--show (current-buffer))))

(defun lispm-office--source-p (buffer)
  "Whether BUFFER is a native agent view or an agent terminal."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (or (bound-and-true-p lispm-chat-agent)
             (bound-and-true-p lispm-session-agent)
             (and (fboundp 'lispm-agents-buffer-p)
                  (lispm-agents-buffer-p buffer))))))

(defun lispm-office--context-key (buffer)
  "Resolve BUFFER's agent identity without reading session files.
Native chat buffers use their owner because the roster indexes transcripts."
  (when (and (buffer-live-p buffer) (fboundp 'lispm-agents-roster-key))
    (with-current-buffer buffer
      (lispm-agents-roster-key
       (or (bound-and-true-p lispm-chat-agent)
           (bound-and-true-p lispm-session-agent) buffer)))))

(defun lispm-office--session-records (records key)
  "Return KEY's explicit collaboration group from RECORDS.
Start with KEY and its descendants, never its ancestors.  Then follow active
wait links in either direction and shared request ids.  A collaborator found
through those links does not bring its unrelated descendants into the group.
Unknown keys and project membership alone never establish a relationship."
  (let ((index (make-hash-table :test #'equal))
        (children (make-hash-table :test #'equal))
        (links (make-hash-table :test #'equal))
        (requests (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal))
        queue)
    (dolist (record records)
      (when-let* ((id (plist-get record :key)))
        (puthash id record index)
        (when-let* ((parent (plist-get record :parent)))
          (push id (gethash parent children)))
        (dolist (target (append (plist-get record :waits-on)
                               (plist-get record :waited-on-by)))
          (when target
            (push target (gethash id links))
            (push id (gethash target links))))
        (dolist (request (plist-get record :request-ids))
          (when request (push id (gethash request requests))))))
    (when (and key (gethash key index))
      (setq queue (list key))
      (while queue
        (let ((id (pop queue)))
          (unless (gethash id seen)
            (puthash id t seen)
            (setq queue (append (gethash id children) queue)))))
      ;; Connect each request through one endpoint, avoiding a quadratic clique.
      (maphash (lambda (_request ids)
                 (dolist (id (cdr ids))
                   (push id (gethash (car ids) links))
                   (push (car ids) (gethash id links))))
               requests)
      (maphash (lambda (id _value) (push id queue)) seen)
      (while queue
        (dolist (id (gethash (pop queue) links))
          (when (and (gethash id index) (not (gethash id seen)))
            (puthash id t seen)
            (push id queue))))
      (seq-filter (lambda (record) (gethash (plist-get record :key) seen)) records))))

(defun lispm-office--working-p (record)
  "Whether RECORD has ongoing work, needs attention or has queued input.
An explicitly ended conversation is excluded.  Unknown activity alone is
not evidence of work; this predicate never reads transcripts or processes."
  (and (or (not (plist-member record :alive)) (plist-get record :alive))
       (or (memq (plist-get (plist-get record :status) :state) '(working blocked error))
           (let ((queued (plist-get (plist-get record :mailbox) :queued)))
             (and (numberp queued) (> queued 0))))))

(defun lispm-office--scoped-records ()
  "Select visible records from the cached full roster, without querying agents."
  (pcase lispm-office--scope
    ('session (lispm-office--session-records lispm-office--all-records lispm-office--source-key))
    ('project
     (let* ((source (and lispm-office--source-key
                         (seq-find (lambda (record)
                                     (equal (plist-get record :key) lispm-office--source-key))
                                   lispm-office--all-records)))
            (root (lispm-office-layout--root
                   (or lispm-office--project-root
                       (if source (plist-get source :root)
                         (if (buffer-live-p lispm-office--source-buffer)
                             (buffer-local-value 'default-directory lispm-office--source-buffer)
                           default-directory))))))
       (seq-filter (lambda (record)
                     (and (equal root (lispm-office-layout--root (plist-get record :root)))
                          (or (not lispm-office--project-root)
                              (not (plist-member record :alive))
                              (plist-get record :alive))
                          (or (not lispm-office--working-only)
                              (lispm-office--working-p record))))
                   lispm-office--all-records)))
    (_ lispm-office--all-records)))

(defun lispm-office--scoped-plan ()
  "Make display geometry without changing global seat reservations.
A session's collaborators share one display room, including cross-project
requests.  Each node keeps its actual roster fields, including its project."
  (let ((plan (lispm-office-layout-plan lispm-office--state lispm-office--records)))
    (if (and (eq lispm-office--scope 'session) (plist-get plan :nodes))
        (let* ((nodes (plist-get plan :nodes))
               (source (seq-find (lambda (node)
                                   (equal lispm-office--source-key (plist-get node :key))) nodes))
               (room (copy-tree (seq-find (lambda (item)
                                            (equal (plist-get item :id) (plist-get source :room)))
                                          (plist-get plan :rooms)))))
          (cl-loop for node in nodes for slot from 0 do
                   (setf (plist-get node :room) (plist-get room :id)
                         (plist-get node :slot) slot))
          (setf (plist-get room :label) "Session collaboration"
                (plist-get room :nodes) nodes
                (plist-get plan :rooms) (list room))
          plan)
      plan)))

(defun lispm-office--apply-scope (&optional prefer-source)
  "Rebuild visible data and selection; PREFER-SOURCE selects the source desk.
Return non-nil when scope contents or selection changed."
  (let ((old-records lispm-office--records)
        (old-selected lispm-office--selected)
        (old-plan lispm-office--plan)
        (old-room lispm-office--room))
    (setq lispm-office--records (lispm-office--scoped-records)
          lispm-office--plan (lispm-office--scoped-plan))
    ;; An unchanged source-window event does not repaint.  Keep the plan's
    ;; identity so hit tests continue using the geometry of its displayed SVG.
    (when (equal lispm-office--plan old-plan) (setq lispm-office--plan old-plan))
    (let* ((nodes (plist-get lispm-office--plan :nodes))
           (source (seq-find (lambda (node) (equal lispm-office--source-key (plist-get node :key))) nodes)))
      (unless (and (not prefer-source)
                   (seq-find (lambda (node) (equal lispm-office--selected (plist-get node :key))) nodes))
        (setq lispm-office--selected
              (or (plist-get source :key)
                  (and (not (eq lispm-office--scope 'session))
                       (plist-get (car nodes) :key)))))
      (cond
       ((eq lispm-office--scope 'session)
        (setq lispm-office--room (plist-get source :room)))
       ((and lispm-office--project-root (eq lispm-office--scope 'project)
             (= (length (plist-get lispm-office--plan :rooms)) 1))
        (setq lispm-office--room (plist-get (car (plist-get lispm-office--plan :rooms)) :id)))
       ((or prefer-source
            (not (seq-find (lambda (room) (equal lispm-office--room (plist-get room :id)))
                           (plist-get lispm-office--plan :rooms))))
        (setq lispm-office--room nil))))
    (when (or (not (equal old-selected lispm-office--selected))
              (when-let* ((inspector (lispm-office-inspect-buffer (current-buffer)))
                          ((buffer-live-p inspector)))
                (let ((key (buffer-local-value 'lispm-office-inspect--key inspector)))
                  (not (seq-find (lambda (record) (equal key (plist-get record :key)))
                                 lispm-office--records)))))
      (lispm-office-inspect-follow (current-buffer) lispm-office--selected))
    (or (not (equal old-records lispm-office--records))
        (not (eq old-plan lispm-office--plan))
        (not (equal old-selected lispm-office--selected))
        (not (equal old-room lispm-office--room)))))

(defun lispm-office--focus-source (source)
  "Follow SOURCE's identity and recompute scope from the full cached roster.
An unknown session stays empty.  Manual selection survives updates while it
remains in scope; switching session returns to Session scope."
  (if lispm-office--project-root
      (lispm-office--apply-scope)
    (let* ((new-source (not (eq source lispm-office--source-buffer)))
           (key (and (lispm-office--source-p source) (lispm-office--context-key source)))
           (known (and key (seq-find (lambda (record) (equal key (plist-get record :key)))
                                    lispm-office--all-records)))
           (new-session (or (and new-source
                                 (not (and key (equal key lispm-office--source-key))))
                            (and key (consp lispm-office--source-key)
                                 (not (equal key lispm-office--source-key)))))
           (changed (or new-session (not (equal (and known key) lispm-office--source-key)))))
      (when new-session (setq lispm-office--scope 'session))
      (setq lispm-office--source-buffer source lispm-office--source-key (and known key))
      (when changed (setq lispm-office--fit t))
      (let ((scope-changed (lispm-office--apply-scope changed)))
        (or changed scope-changed)))))

(defun lispm-office--window ()
  "Return a window displaying the current Office buffer."
  (if (eq (window-buffer (selected-window)) (current-buffer))
      (selected-window)
    (get-buffer-window (current-buffer) 'visible)))

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
              (plist-get (lispm-office--scene-plan) :nodes)))

(defun lispm-office--scene-plan ()
  "Return the displayed geometry when it belongs to the current snapshot."
  (if (and lispm-office--display-plan
           (eq (car lispm-office--display-context) lispm-office--plan)
           (equal (cadr lispm-office--display-context) lispm-office--room))
      lispm-office--display-plan
    lispm-office--plan))

(defun lispm-office--dimensions ()
  "Return the available drawing width and height."
  (if-let* ((window (lispm-office--window)))
      (cons (max 1 (window-body-width window t))
            (max 1 (- (window-body-height window t) lispm-office--chrome-height)))
    '(1000 . 600)))

(defun lispm-office--fit-scale ()
  "Fit the room to the available width and height without stretching desks."
  (let* ((size (lispm-office--dimensions))
         (responsive (lispm-office-render-fit-room
                      lispm-office--plan lispm-office--room (car size) (cdr size))))
    (setq lispm-office--display-context (list lispm-office--plan lispm-office--room))
    (if responsive
        (setq lispm-office--display-plan (plist-get responsive :plan)
              lispm-office--scale (plist-get responsive :scale))
      (let ((width (max 1 (or (plist-get lispm-office--plan :width) 1)))
            (height (max 1 (or (plist-get lispm-office--plan :height) 1))))
        (setq lispm-office--scale
              (max 0.08 (min 1.5 (/ (float (car size)) width) (/ (float (cdr size)) height)))))
      ;; An overview keeps its rooms' shared geometry, while its background
      ;; still occupies the full available canvas.
      (setq lispm-office--display-plan (copy-sequence lispm-office--plan))
      (setq lispm-office--display-plan
            (plist-put lispm-office--display-plan :width
                       (max (or (plist-get lispm-office--plan :width) 1)
                            (/ (car size) lispm-office--scale))))
      (setq lispm-office--display-plan
            (plist-put lispm-office--display-plan :height
                       (max (or (plist-get lispm-office--plan :height) 1)
                            (/ (cdr size) lispm-office--scale)))))))

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

(defun lispm-office--view-choices ()
  "Return the compact view menu's commands without querying agents."
  (append
   (when (lispm-office--source-p lispm-office--source-buffer)
     '((session . "Session")))
   '((project . "Project") (all . "All projects"))
   (when (eq lispm-office--scope 'project)
     (list (cons 'working-only (if lispm-office--working-only "Show all active agents" "Working only"))))
   (when (> (length (plist-get lispm-office--plan :rooms)) 1)
     '((room . "Choose room…")))
   (list (cons 'text (if lispm-office--text "Pictures" "Text view")))
   '((refresh . "Refresh") (help . "Help"))))

(defun lispm-office--view-command (command)
  "Perform COMMAND chosen from the view menu."
  (pcase command
    ('session (lispm-office-session))
    ('project (lispm-office-project))
    ('all (lispm-office-overview))
    ('working-only (lispm-office-toggle-working-only))
    ('room (lispm-office-choose-room))
    ('text (lispm-office-toggle-text))
    ('refresh (lispm-office-refresh))
    ('help (describe-mode))))

(defun lispm-office--insert-view-menu ()
  "Insert one shared LispM UI pop-up control for view navigation."
  (let* ((owner (current-buffer))
         (label (pcase lispm-office--scope
                  ('session "Session") ('project "Project") (_ "All projects")))
         (start (point)))
    (lispm-ui-insert-popup-button
     label (lispm-office--view-choices)
     (lambda (command)
       (when (buffer-live-p owner)
         (with-current-buffer owner (lispm-office--view-command command))))
     :current lispm-office--scope :help "View")
    (add-text-properties start (point) (list 'lispm-ui-label label))
    (insert "\n")))

(defun lispm-office--insert-centered (text)
  "Insert a short, centered empty-state caption TEXT."
  (let* ((window (lispm-office--window))
         (width (if window (window-body-width window) 80))
         (caption (propertize text 'face 'shadow)))
    (insert (if (display-graphic-p)
                (propertize " " 'display
                            `(space :align-to (- center (,(/ (string-pixel-width caption) 2)))))
              (make-string (max 0 (/ (- width (string-width text)) 2)) ?\s))
            caption "\n")))

(defun lispm-office--draw ()
  "Draw the current page from cached data, without querying an agent."
  (unless lispm-office--drawing
    (if lispm-office-inspect--inline
        (let ((lispm-office--drawing t))
          (setq lispm-office--dirty nil)
          (lispm-office-inspect--draw t))
      (lispm-office--draw-floor))))

(defun lispm-office--draw-floor ()
  "Draw the cached floor, without inspecting or querying an agent."
  (unless lispm-office--drawing
    ;; Global line-number mode runs after major-mode setup.  Disable its
    ;; buffer-local gutter before measuring the edge-to-edge image.
    (when (bound-and-true-p display-line-numbers-mode)
      (display-line-numbers-mode -1))
    (let ((lispm-office--drawing t)
          (inhibit-read-only t)
          (old-point (point))
          (window (lispm-office--window)))
      (lispm-office--prune-flights)
      (setq lispm-office--dirty nil)
      (erase-buffer)
      (lispm-office--insert-view-menu)
      (setq lispm-office--floor-start (point))
      (setq lispm-office--chrome-height
            (if window
                (cdr (window-text-pixel-size window (point-min) (point) nil nil nil t))
              0))
      (let ((scale lispm-office--scale))
        (lispm-office--fit-scale)
        (unless lispm-office--fit (setq lispm-office--scale scale)))
      (setq lispm-office--size (lispm-office--dimensions))
      (cond
       ((null (plist-get lispm-office--plan :nodes))
        (lispm-office--insert-centered
         (cond ((and (eq lispm-office--scope 'session) (null lispm-office--source-key))
                "Session is starting…")
               ((and (eq lispm-office--scope 'project) lispm-office--working-only)
                "No agents working")
               (t "No active agents"))))
       ((lispm-office--graphic-p)
        (let* ((now (float-time))
               (events (mapcar (lambda (event)
                                 (plist-put (copy-sequence event) :progress
                                            (min 1.0 (max 0.0 (- now (plist-get event :started))))))
                               lispm-office--flights))
               (svg (lispm-office-render-svg (lispm-office--scene-plan) lispm-office--selected
                                              lispm-office--scale lispm-office--phase
                                              lispm-office--room events))
               (start (point)))
          (insert-image (lispm-ui-svg-image svg) "Office floor")
          (add-text-properties start (point)
                               (list 'keymap lispm-office-mode-map
                                     'help-echo "Click a desk to inspect it; click a map room to enter."))))
       (t (lispm-office-render-text lispm-office--plan lispm-office--selected lispm-office--room)))
      (goto-char (min old-point (point-max)))
      (when window (set-window-hscroll window 0)))))

(defun lispm-office--animated-p ()
  "Whether visible graphical content currently needs animation."
  (and (not lispm-office-inspect--inline) lispm-office-animate (lispm-office--graphic-p)
       (or (lispm-office-render-visible-events (lispm-office--scene-plan) lispm-office--scale
                                               lispm-office--room lispm-office--flights)
           (and (>= (plist-get (lispm-office-render-projection
                                (lispm-office--scene-plan) lispm-office--scale lispm-office--room) :scale) 0.45)
                (let* ((nodes (lispm-office--visible-nodes))
                       (keys (mapcar (lambda (node) (plist-get node :key)) nodes)))
                  (seq-some
                   (lambda (record)
                     (or (eq (plist-get (plist-get record :status) :state) 'working)
                         (seq-some (lambda (key) (member key keys))
                                   (plist-get record :waits-on))))
                   nodes))))))

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
  "Discard expired or out-of-scope message animations without querying agents."
  (setq lispm-office--flights
        (seq-filter (lambda (event)
                      (and (< (- (float-time) (plist-get event :started)) 1.0)
                           (lispm-office--event-in-scope-p event)))
                    lispm-office--flights)))

(defun lispm-office--event-in-scope-p (event)
  "Whether both known endpoints of EVENT belong to the visible scope."
  (cl-every (lambda (field)
              (let ((record (lispm-office-render--endpoint
                             (plist-get event field) (or lispm-office--all-records lispm-office--records))))
                (and record (memq record lispm-office--records))))
            '(:from :to)))

(defun lispm-office--tick (buffer)
  "Advance BUFFER's visible animation; never read agent data."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (lispm-office--prune-flights)
      (cond
       (lispm-office-inspect--inline nil)
       ((lispm-office--graphic-p)
        (setq lispm-office--phase (mod (1+ lispm-office--phase) 32))
        (lispm-office--draw))
       (t (setq lispm-office--flights nil)))
      (lispm-office--sync-timer))))

(defun lispm-office--ingest (records &optional event)
  "Accept RECORDS and one batch EVENT, preserving seats and selection."
  (let* ((state (lispm-office-layout-reconcile lispm-office--state records))
         (changed (not (equal state lispm-office--state))))
    (setq lispm-office--all-records records lispm-office--state state)
    (if lispm-office--demo (lispm-office--apply-scope)
      (lispm-office--focus-source lispm-office--source-buffer))
    (when (and changed (not lispm-office--demo) lispm-office--seat-path)
      (setq lispm-office--unsaved t)
      (lispm-office--save-seats))
    (dolist (message (plist-get event :events))
      (let ((sequence (plist-get message :sequence)))
        (when (and (numberp sequence) (> sequence lispm-office--sequence))
          (setq lispm-office--sequence sequence)
          (when (and (not lispm-office-inspect--inline)
                     lispm-office-animate (lispm-office--graphic-p)
                     (lispm-office--event-in-scope-p message)
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
        (when (and (not lispm-office-inspect--inline) (lispm-office--window)
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
  ;; Restoring a selected conversation changes the current buffer.  Keep the
  ;; owner current until its observer and registry entries have been removed.
  (save-current-buffer
    (lispm-office-inspect-close (current-buffer)))
  (save-current-buffer
    (let ((owner (current-buffer)))
      (walk-windows
       (lambda (window)
         (when (eq (plist-get (window-parameter window 'lispm-office-source) :view) owner)
           (lispm-office--restore-window window))) 'no-minibuf t)))
  (setq lispm-office--buffers (delq (current-buffer) lispm-office--buffers))
  (unless (seq-some (lambda (buffer)
                     (and (buffer-live-p buffer)
                          (not (buffer-local-value 'lispm-office--demo buffer)))) lispm-office--buffers)
    (remove-hook 'lispm-agents-roster-change-functions #'lispm-office--changed))
  (unless lispm-office--buffers
    (remove-hook 'window-size-change-functions #'lispm-office--windows-changed)
    (remove-hook 'window-state-change-functions #'lispm-office--windows-changed)
    (remove-hook 'delete-frame-functions #'lispm-office--frame-deleted)
    (remove-hook 'lispm-ui-palette-changed-hook #'lispm-office--palette-changed)))

(defun lispm-office--focus-selection ()
  "Put keyboard focus on the scene or the selected agent's text row."
  (unless lispm-office-inspect--inline
    (let ((position lispm-office--floor-start))
      (unless (lispm-office--graphic-p)
        (while (and (< position (point-max))
                    (not (equal lispm-office--selected
                                (get-text-property position 'lispm-office-key))))
          (setq position (next-single-property-change position 'lispm-office-key nil (point-max))))
        (when (= position (point-max)) (setq position lispm-office--floor-start)))
      (goto-char position)
      (when-let* ((window (lispm-office--window)))
        (set-window-point window position)))))

(defun lispm-office--select (key &optional inspect)
  "Select KEY, enter its room if needed, and optionally INSPECT."
  (when-let* ((node (seq-find (lambda (r) (equal key (plist-get r :key)))
                            (plist-get lispm-office--plan :nodes))))
    (setq lispm-office--selected key)
    (when (or (and (lispm-office--graphic-p)
                   (or (< (plist-get (lispm-office-render-projection
                                      (lispm-office--scene-plan) lispm-office--scale lispm-office--room)
                                     :scale) 0.45)
                       (and (null lispm-office--room)
                            (let ((projection (lispm-office-render-projection
                                               (lispm-office--scene-plan) lispm-office--scale))
                                  (size (lispm-office--dimensions)))
                              (or (> (plist-get projection :pixel-width) (car size))
                                  (> (plist-get projection :pixel-height) (cdr size)))))))
              (and lispm-office--room (not (equal lispm-office--room (plist-get node :room)))))
      (setq lispm-office--room (plist-get node :room) lispm-office--fit t))
    (when lispm-office-inspect--inline
      (lispm-office-inspect-follow (current-buffer) key))
    (lispm-office--draw)
    (lispm-office--focus-selection)
    (lispm-office--sync-timer)
    (when inspect (lispm-office-inspect-selected))))

(defun lispm-office--key ()
  "Return the selected live key, refusing preview actions."
  (when lispm-office--demo (user-error "This is a preview; open M-x lispm-office for live agents"))
  (if (and lispm-office--selected
           (seq-find (lambda (record) (equal lispm-office--selected (plist-get record :key)))
                     lispm-office--records))
      lispm-office--selected
    (user-error "No agent selected in this scope")))

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
  "Select the nearest desk in direction DX, DY.
In text, move through agents in their displayed order instead."
  (let* ((graphic (lispm-office--graphic-p))
         (nodes (if graphic
                    (if lispm-office--room (lispm-office--visible-nodes)
                      (plist-get (lispm-office--scene-plan) :nodes))
                  (cl-loop for room in (plist-get lispm-office--plan :rooms)
                           when (or (null lispm-office--room)
                                    (equal lispm-office--room (plist-get room :id)))
                           append (plist-get room :nodes))))
         (selected (seq-find (lambda (n) (equal lispm-office--selected (plist-get n :key))) nodes)))
    (cond
     ((not selected)
      (when nodes (lispm-office--select (plist-get (car nodes) :key))))
     ((not graphic)
      (let* ((index (cl-position selected nodes :test #'eq))
             (next (+ index (if (zerop dy) dx dy))))
        (when (and (>= next 0) (< next (length nodes)))
          (lispm-office--select (plist-get (nth next nodes) :key)))))
     (t
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
        (when best (lispm-office--select (plist-get best :key))))))))
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
                       (lispm-office-render-hit-test (lispm-office--scene-plan) (car xy) (cdr xy)
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
  (setq lispm-office--fit t)
  (lispm-office--draw)
  (when-let* ((window (lispm-office--window)))
    (set-window-start window (point-min))
    (set-window-vscroll window 0 t))
  (lispm-office--sync-timer))
(defun lispm-office--set-scope (scope)
  "Switch to SCOPE using the cached roster, then fit its complete view."
  (setq lispm-office--scope scope lispm-office--room nil lispm-office--fit t)
  (lispm-office--apply-scope t)
  (lispm-office-fit))

(defun lispm-office-session ()
  "Show the current session and its explicit collaborators."
  (interactive)
  (unless (lispm-office--source-p lispm-office--source-buffer)
    (user-error "Open Work from an agent conversation to select a session"))
  (lispm-office--set-scope 'session))

(defun lispm-office-project ()
  "Show all conversations in the source session's project."
  (interactive)
  (lispm-office--set-scope 'project))

(defun lispm-office-toggle-working-only ()
  "Include or hide idle conversations in this project's Work view."
  (interactive)
  (setq lispm-office--working-only (not lispm-office--working-only))
  (lispm-office--set-scope 'project))

(defun lispm-office-overview ()
  "Explicitly show every project and live conversation."
  (interactive)
  (lispm-office--set-scope 'all))
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
    (setq lispm-office--state (lispm-office-layout-compact lispm-office--state lispm-office--all-records))
    (when (and (not lispm-office--demo) lispm-office--seat-path)
      (setq lispm-office--unsaved t)
      (lispm-office--save-seats))
    (setq lispm-office--room nil)
    (lispm-office--ingest lispm-office--all-records)))

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
        :scope lispm-office--scope
        :directory lispm-office--project-root :working-only lispm-office--working-only
        :rooms (length (plist-get lispm-office--plan :rooms))
        :waiting (length (lispm-office--waiting))
        :selected lispm-office--selected :preview lispm-office--demo))

(defun lispm-office-quit ()
  "Return to the conversation and release the closed view's resources."
  (interactive)
  (if lispm-office--demo (quit-window t) (lispm-office-return)))

(define-derived-mode lispm-office-mode special-mode "Agent Work"
  "Visualize current agent work; toggle back to its conversation with C-c O."
  (lispm-office--ensure-ui)
  (setq-local truncate-lines t cursor-type nil display-line-numbers nil)
  (setq-local header-line-format '((:eval (lispm-office--view-switcher))))
  (when (boundp 'lispm-desktop-conversation-buffer)
    (setq-local lispm-desktop-conversation-buffer t))
  (add-hook 'kill-buffer-hook #'lispm-office--close nil t)
  (add-hook 'change-major-mode-hook #'lispm-office--close nil t))

(lispm-kit-define-commands lispm-office-mode
  (lispm-office-left :key ("<left>" "C-b"))
  (lispm-office-right :key ("<right>" "C-f"))
  (lispm-office-up :key ("<up>" "C-p"))
  (lispm-office-down :key ("<down>" "C-n"))
  (lispm-office-mouse :key "<mouse-1>")
  (lispm-office-toggle :key "C-c O")
  :menu "Agent Work"
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
  (lispm-office-session :key "S" :label "Session")
  (lispm-office-project :key "P" :label "Project")
  (lispm-office-overview :key "h" :label "All Projects")
  (lispm-office-choose-room :key "r" :label "Choose Room…")
  (lispm-office-toggle-text :key "t" :label "Text View" :style toggle :selected lispm-office--text)
  (lispm-office-compact :label "Compact Saved Seats…")
  (lispm-office-refresh :key "g" :label "Refresh")
  (lispm-office-quit :key "q" :label "Return to Previous View"))

(lispm-office-inspect--focus-keys lispm-office-mode-map)

(defun lispm-office--observe ()
  "Install observers shared by the open Office buffers."
  (cl-pushnew (current-buffer) lispm-office--buffers)
  (unless lispm-office--demo
    (add-hook 'lispm-agents-roster-change-functions #'lispm-office--changed))
  (add-hook 'window-size-change-functions #'lispm-office--windows-changed)
  (add-hook 'window-state-change-functions #'lispm-office--windows-changed)
  ;; Run before Agent's Focus teardown removes its panes and identity.
  (add-hook 'delete-frame-functions #'lispm-office--frame-deleted -80)
  (add-hook 'lispm-ui-palette-changed-hook #'lispm-office--palette-changed))

(defun lispm-office--show (source &optional overview directory)
  "Switch SOURCE's existing window to its work view.
OVERVIEW shows all rooms.  DIRECTORY pins a project's current work instead.
The source buffer and its input remain intact."
  (unless (require 'lispm-agents-roster nil t)
    (user-error "Update lispm-agent to a version containing the roster API"))
  (let* ((window (if (or (and (not directory) (lispm-office--source-p source))
                         (not (boundp 'lispm-agents-main-window-function)))
                     (selected-window)
                   (funcall lispm-agents-main-window-function)))
         (source (if (eq (window-buffer window) source) source (window-buffer window)))
         (path (or lispm-office-seat-file
                   (expand-file-name "office-seats.eld" lispm-directory)))
         (buffer (get-buffer-create "*LispM Office*")))
    (when (eq source buffer)
      (setq source (or (plist-get (window-parameter window 'lispm-office-source) :buffer)
                       (other-buffer buffer t))))
    (with-current-buffer buffer
      (when lispm-office-inspect--inline (lispm-office-inspect-close buffer))
      (unless (and (derived-mode-p 'lispm-office-mode) lispm-office--seat-path)
        ;; Read before initializing, so reopening after an error cannot replace
        ;; the corrupt file with an empty layout.
        (let ((state (lispm-office-layout-read path)))
          (lispm-office-mode)
          (setq lispm-office--state state lispm-office--seat-path path
                lispm-office--focus-frame
                (and (fboundp 'lispm-terminal-p)
                     (lispm-terminal-p (window-frame window))
                     (window-frame window)))))
      (unless (and (eq lispm-office--focus-frame (window-frame window))
                   (fboundp 'lispm-terminal-p)
                   (lispm-terminal-p (window-frame window)))
        (setq lispm-office--focus-frame nil))
      (setq lispm-office--source-buffer (and (not directory) (lispm-office--source-p source) source)
            lispm-office--project-root directory
            lispm-office--working-only nil
            lispm-office--scope (cond (directory 'project)
                                     ((and (not overview) (lispm-office--source-p source)) 'session)
                                     (t 'all))
            lispm-office--source-key (unless directory :unresolved) lispm-office--selected nil
            lispm-office--room nil lispm-office--fit t)
      (setq default-directory (or directory (buffer-local-value 'default-directory source)))
      (lispm-office--observe))
    (unless (eq (window-buffer window) buffer)
      ;; Each window returns to its own conversation, even when the work view
      ;; is shared across several agent windows.
      (lispm-office--restore-window window)
      (set-window-parameter
       window 'lispm-office-source
       (list :view buffer :view-name (buffer-name buffer) :buffer source
             :point (with-current-buffer source (copy-marker (window-point window)))
             :start (with-current-buffer source (copy-marker (window-start window)))
             :point-position (window-point window) :start-position (window-start window)
             :hscroll (window-hscroll window) :vscroll (window-vscroll window t)))
      (set-window-buffer window buffer))
    (select-window window)
    (with-current-buffer buffer
      (setq-local header-line-format
                  (when lispm-office--source-buffer '((:eval (lispm-office--view-switcher)))))
      (lispm-office-refresh)
      (lispm-office--focus-selection))
    buffer))

;;;###autoload
(defun lispm-office-open-project (directory)
  "Show all active agent sessions in DIRECTORY in the host's main window.
Called interactively, use the current working directory.  This project
view includes idle agents and stays pinned when other conversations receive
focus.  It has no Conversation tab; q restores the previous main-window
buffer and its draft."
  (interactive (list default-directory))
  (unless (and (stringp directory) (not (string-empty-p directory)))
    (user-error "A project directory is required"))
  (lispm-office--show (current-buffer) nil (lispm-office-layout--root directory)))

;;;###autoload
(defun lispm-office (&optional overview)
  "Switch the Agent window from conversation to current work.
With prefix argument OVERVIEW, show all projects.  Outside an agent buffer,
show the overview.  Toggle back with C-c O or the Conversation control."
  (interactive "P")
  (lispm-office--show (current-buffer) overview))

;;;###autoload
(defun lispm-office-demo (&optional count)
  "Preview COUNT simulated agents, default twelve, without side effects."
  (interactive (list (if current-prefix-arg (read-number "Preview agent count: " 40) 12)))
  (require 'lispm-office-demo)
  (let ((buffer (get-buffer-create "*LispM Office Preview*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'lispm-office-mode) (lispm-office-mode))
      (setq lispm-office--demo t lispm-office--fit t lispm-office--room nil lispm-office--scope 'all
            header-line-format nil)
      (lispm-office--observe))
    (pop-to-buffer buffer)
    (lispm-office--ingest (lispm-office-demo-records (or count 12)))
    (lispm-office--focus-selection)
    buffer))

(provide 'lispm-office)
;;; lispm-office.el ends here
