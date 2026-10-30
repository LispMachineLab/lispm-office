;;; lispm-office-inspect.el --- Work and mail at an Office desk -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; One inspector belongs to one Office buffer.  Details are read only
;; for the selected conversation; actions resolve its stable key again.
;; A permission preview is tied to the agent, turn, call and arguments
;; that were shown, including while a minibuffer is reading an answer.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'pp)
(require 'lispm-kit-commands)
(require 'lispm-ui-controls)
(require 'lispm-office-details)

(declare-function lispm-agents-roster-buffer "lispm-agents-roster" (key))
(declare-function lispm-agents-roster-details "lispm-inspect" (key))
(declare-function lispm-agents-buffer-status "lispm-agents" (buffer))
(declare-function lispm-agents-props "lispm-agents" (agent))
(declare-function lispm-agents-show "lispm-agents" (buffer))
(declare-function lispm-agent-turn "lispm-core" (agent))
(declare-function lispm-agent-name "lispm-core" (agent))
(declare-function lispm-agent-pending "lispm-core" (agent))
(declare-function lispm-agent-character "lispm-core" (agent))
(declare-function lispm-agent-model "lispm-core" (agent))
(declare-function lispm-agent-view "lispm-core" (agent))
(declare-function lispm-agent-buffer "lispm-core" (agent))
(declare-function lispm-agents "lispm-core" ())
(declare-function lispm-switch "lispm" (agent))
(declare-function lispm-agent-display-buffer "lispm" (agent))
(declare-function lispm-office--prepare-navigation "lispm-office" (owner))
(declare-function lispm-office-cleanup-windows "lispm-office" (&rest _))
(declare-function lispm-office--focus-selection "lispm-office" ())
(declare-function lispm-office--draw "lispm-office" ())
(declare-function lispm-office--sync-timer "lispm-office" ())
(declare-function lispm-terminal-p "lispm-terminal" (&optional frame))
(declare-function lispm-terminal-show "lispm-terminal" (agent &optional stay))
(declare-function lispm-terminal-keys-mode "lispm-terminal" (&optional arg))
(defvar lispm-terminal-map)
(declare-function lispm-desktop-platinum-tabs "lispm-desktop-platinum-controls" (tabs width &optional face))
(declare-function lispm-waiting-calls "lispm-runtime" (agent))
(declare-function lispm-asked "lispm-runtime" (call))
(declare-function lispm-approve-for "lispm-runtime" (agent &optional id))
(declare-function lispm-approve-all-for "lispm-runtime" (agent))
(declare-function lispm-deny-for "lispm-runtime" (agent reason &optional id))
(declare-function lispm-abort "lispm-runtime" (&optional agent))
(declare-function lispm-tell "lispm-runtime" (agent text &rest arguments))
(declare-function lispm-agents-bridge-deliver "lispm-agents-bridge" (terminal text &optional metadata))
(declare-function lispm-get-character "lispm-core" (character &optional noerror))
(declare-function lispm-character-title "lispm-core" (character))
(declare-function lispm-character-soul "lispm-core" (character))
(declare-function lispm-character-skill "lispm-core" (character))
(declare-function lispm-character-avatar "lispm-core" (character))
(declare-function lispm-character-model "lispm-core" (character))
(declare-function lispm-character-self "lispm-characters" (character))
(declare-function lispm-character-days "lispm-characters" (character &optional count))

(defvar lispm-office-inspect--buffers nil
  "Alist of Office owners to their inspector buffers.")
(defvar lispm-agents-show-function)
(defvar-local lispm-office-inspect--owner nil
  "The Office buffer owning this inspector.")
(defvar-local lispm-office-inspect--key nil
  "Stable key of the conversation being inspected.")
(defvar-local lispm-office-inspect--tab 'work
  "The current inspector tab: work, mailbox or character.")
(defvar-local lispm-office-inspect--dirty nil
  "Non-nil when an unseen inspector needs fresh details when shown.")
(defvar-local lispm-office-inspect--width nil
  "Width used by this inspector's last rendering.")
(defvar-local lispm-office-inspect--inline nil
  "Non-nil while this Work buffer displays its agent details page.")
(defvar-local lispm-office-inspect--model nil
  "Selected agent data cached for resize and palette redraws.")
(defvar-local lispm-office-inspect--floor-state nil
  "Floor display state to restore when leaving the details page.")
(defvar lispm-office-inspect--cached-permissions nil)
(defvar lispm-office--plan)
(defvar lispm-office-inspect-inline-mode)

(defun lispm-office-inspect-buffer (owner)
  "Return OWNER's active inline page or its legacy Inspector buffer."
  (if (and (buffer-live-p owner)
           (buffer-local-value 'lispm-office-inspect--inline owner))
      owner
    (cdr (assq owner lispm-office-inspect--buffers))))
(defvar lispm-office-inspect--button-end nil)
(defvar lispm-office-inspect--button-width 0)
(defvar lispm-office-inspect--cleaning-windows nil
  "Non-nil while transient Inspector windows are being removed.")
(defvar tab-bar-tab-post-select-functions)

(defun lispm-office-inspect--placeholder-p (buffer)
  "Whether BUFFER is Emacs's notice for a killed Office Inspector.
Restrict legacy cleanup to the generated name and notice in a special
buffer; other missing files, conversations and user buffers are untouched."
  (and (buffer-live-p buffer)
       (string-match-p
        "\\` \\*Old buffer \\*LispM Office Inspector\\*\\(?:<[0-9]+>\\)?\\*\\(?:<[0-9]+>\\)?\\'"
        (buffer-name buffer))
       (with-current-buffer buffer
         (and (not buffer-file-name) (derived-mode-p 'special-mode)
              (string-match-p
               "\\`This window displayed the buffer .*\\*LispM Office Inspector\\*"
               (buffer-substring-no-properties
                (point-min) (min (point-max) (+ (point-min) 256))))))))

(defun lispm-office-inspect--remove-window (window &optional owner)
  "Remove the Inspector WINDOW, preserving a last ordinary window.
OWNER is a live Office to display if WINDOW cannot be deleted.  Never
consult `quit-restore', which may refer to an obsolete placeholder."
  (set-window-parameter window 'lispm-office-inspector nil)
  (set-window-parameter window 'quit-restore nil)
  (set-window-parameter window 'quit-restore-prev nil)
  (if (and (window-parameter window 'window-side) (window-parent window))
      (delete-window window)
    (let ((replacement (if (buffer-live-p owner) owner
                         (other-buffer (window-buffer window) t))))
      (set-window-dedicated-p window nil)
      (set-window-buffer window replacement))))

(defun lispm-office-inspect--close-windows (buffer)
  "Remove windows still displaying BUFFER, not panes repurposed by users."
  (let ((owner (buffer-local-value 'lispm-office-inspect--owner buffer)))
    (save-current-buffer
      (dolist (window (get-buffer-window-list buffer nil t))
        (lispm-office-inspect--remove-window window owner)))))

(defun lispm-office-inspect--close-hidden-focus-owners ()
  "Close Inspector panes left by native Focus session-list navigation."
  (when (fboundp 'lispm-terminal-p)
    (save-selected-window
      (save-current-buffer
        (dolist (entry (copy-sequence lispm-office-inspect--buffers))
          (let ((owner (car entry)) (inspector (cdr entry)))
            (when (and (buffer-live-p owner) (buffer-live-p inspector)
                       (with-current-buffer owner (derived-mode-p 'lispm-office-mode))
                       (seq-some (lambda (window)
                                   (let ((frame (window-frame window)))
                                     (and (lispm-terminal-p frame)
                                          (not (get-buffer-window owner frame)))))
                                 (get-buffer-window-list inspector nil t)))
              (lispm-office-inspect-close owner)
              (unless (get-buffer-window owner t)
                ;; Core close clears old return parameters; it only restores
                ;; the source in windows that still actually show Work.
                (kill-buffer owner)))))))))

(defun lispm-office-inspect-cleanup-windows (&rest _)
  "Remove obsolete Inspector notices after a window or tab restoration.
This is safe as a window-state or tab-selection callback.  Writable
ownership markers survive saved layouts; narrowly recognized notices
also repair layouts saved before ownership markers were introduced."
  (unless lispm-office-inspect--cleaning-windows
    (let ((lispm-office-inspect--cleaning-windows t) placeholders)
      (save-current-buffer
        (save-selected-window
          (dolist (frame (frame-list))
            (dolist (window (window-list frame 'nomini))
              (let* ((buffer (window-buffer window))
                     (owned (window-parameter window 'lispm-office-inspector)))
                (cond
                 ((and (or owned (window-parameter window 'window-side))
                       (lispm-office-inspect--placeholder-p buffer))
                  (push buffer placeholders)
                  (lispm-office-inspect--remove-window window))
                 ((and owned
                       (not (with-current-buffer buffer
                              (derived-mode-p 'lispm-office-inspect-mode))))
                  ;; A user may deliberately reuse the pane for another buffer.
                  (set-window-parameter window 'lispm-office-inspector nil))))))))
      (dolist (buffer (delete-dups placeholders))
        (when (and (buffer-live-p buffer) (not (get-buffer-window buffer t)))
          (kill-buffer buffer)))
      (lispm-office-inspect--close-hidden-focus-owners)
      (when (fboundp 'lispm-office-cleanup-windows)
        (lispm-office-cleanup-windows)))))

(defun lispm-office-inspect--require ()
  "Ensure the live roster API is installed."
  (unless (and (require 'lispm-agents-roster nil t)
               (fboundp 'lispm-agents-roster-buffer)
               (fboundp 'lispm-agents-roster-details))
    (user-error "Office needs LispM Agent's roster API (PR #135)")))

(defun lispm-office-inspect--target (key &optional action)
  "Resolve live KEY and check ACTION; return a target plist.
No remembered buffer or agent object authorizes an action."
  (lispm-office-inspect--require)
  (unless (and (listp key) (= (length key) 2)
               (symbolp (car key)) (stringp (cadr key)))
    (user-error "This conversation has no stable session identity yet"))
  (let* ((buffer (lispm-agents-roster-buffer key))
         (agent (and (buffer-live-p buffer)
                     (buffer-local-value 'lispm-session-agent buffer)))
         (props (and (not agent) (lispm-agents-props (car key))))
         (actions (if agent '(open-chat send approve approve-all deny abort)
                    (append '(open-chat)
                            (when (or (plist-get props :ready)
                                      (plist-get props :deliver)) '(send))))))
    (unless (buffer-live-p buffer)
      (user-error "This conversation has ended or was archived"))
    (when (and action (not (memq action actions)))
      (user-error "%s does not support %s here; open its chat" (car key) action))
    (list :key (copy-sequence key) :buffer buffer :agent agent :actions actions
          :name (if agent (symbol-name (lispm-agent-name agent)) (buffer-name buffer)))))

(defun lispm-office-inspect--same-target (target action)
  "Re-resolve TARGET for ACTION, rejecting a replaced session object."
  (let ((fresh (lispm-office-inspect--target (plist-get target :key) action)))
    (unless (and (eq (plist-get target :buffer) (plist-get fresh :buffer))
                 (eq (plist-get target :agent) (plist-get fresh :agent)))
      (user-error "The conversation changed; inspect it again"))
    fresh))

(defun lispm-office-inspect--display-chat (buffer alist)
  "Display BUFFER in an ordinary window, keeping Inspector side panes.
Prefer the window of ALIST's `lispm-office-owner', then one already
showing BUFFER.  This is a `display-buffer' action function."
  (let* ((windows (window-list nil 'nomini))
         (ordinary (seq-remove (lambda (window) (window-parameter window 'window-side))
                               windows))
         (owner (alist-get 'lispm-office-owner alist))
         (window (or (seq-find (lambda (window)
                                (and (eq (window-buffer window) owner)
                                     (not (window-dedicated-p window)))) ordinary)
                     (seq-find (lambda (window) (eq (window-buffer window) buffer)) ordinary)
                     (seq-find (lambda (window) (not (window-dedicated-p window))) ordinary))))
    (when window
      (set-window-buffer window buffer)
      window)))

(defun lispm-office-inspect--focus-p ()
  "Whether the selected frame is the optional Agent Focus interface."
  (and (fboundp 'lispm-terminal-p) (lispm-terminal-p)))

(defun lispm-office-inspect--focus-command (sequence)
  "Leave owned Work panes before running native Focus key SEQUENCE."
  (unless (lispm-office-inspect--focus-p) (user-error "Focus Mode is no longer active"))
  (let ((command (and (boundp 'lispm-terminal-map) (lookup-key lispm-terminal-map sequence)))
        (owner (or lispm-office-inspect--owner (current-buffer))))
    (unless (commandp command) (user-error "This Focus command is no longer available"))
    (when (and (buffer-live-p owner)
               (with-current-buffer owner (derived-mode-p 'lispm-office-mode)))
      (lispm-office--prepare-navigation owner))
    (unwind-protect
        (call-interactively command)
      (when (and (buffer-live-p owner)
                 (with-current-buffer owner (derived-mode-p 'lispm-office-mode))
                 (not (get-buffer-window owner t)))
        (save-selected-window
          (save-current-buffer (kill-buffer owner)))))))

(defun lispm-office-inspect--focus-keys (map)
  "Add the Agent's Focus shortcuts to MAP only within its Focus frame.
Filters resolve the public terminal map on use, so no terminal dependency,
mode hooks or ordinary-window bindings are introduced."
  (dolist (key '("C-c C-s" "C-c C-n" "C-c C-p" "C-c C-j" "C-c C-o" "C-c C-q"))
    (let* ((sequence (kbd key))
           (navigate (not (equal key "C-c C-s")))
           (wrapper (lambda () (interactive) (lispm-office-inspect--focus-command sequence))))
      (define-key map sequence
                  (list 'menu-item "Focus Mode" nil :filter
                        (lambda (_)
                          (when (and (lispm-office-inspect--focus-p)
                                     (boundp 'lispm-terminal-map))
                            (let ((command (lookup-key lispm-terminal-map sequence)))
                              (when (commandp command)
                                (if navigate wrapper command)))))))))
  map)

(defun lispm-office-open-chat (key)
  "Return from Office to the live conversation with stable KEY.
A native agent's existing chat takes precedence over its hidden
transcript.  A missing chat may be opened only while the same live
session is still registered.  The Agent host controls where it opens."
  (let* ((target (lispm-office-inspect--target key 'open-chat))
         (buffer (plist-get target :buffer))
         (agent (plist-get target :agent))
         (view (and agent (lispm-agent-view agent)))
         (owner (or lispm-office-inspect--owner (current-buffer)))
         (focus (lispm-office-inspect--focus-p))
         (display-buffer-overriding-action
          (if (eq lispm-agents-show-function #'pop-to-buffer)
              `((lispm-office-inspect--display-chat display-buffer-pop-up-window)
                (lispm-office-owner . ,owner))
            display-buffer-overriding-action))
         (chat
          (cond ((and focus agent (fboundp 'lispm-terminal-show)) nil)
                ((buffer-live-p view) view)
                ((and agent (or (fboundp 'lispm-agent-display-buffer)
                                (fboundp 'lispm-switch)))
                 (unless (and (eq buffer (lispm-agent-buffer agent))
                              (memq agent (lispm-agents)))
                   (user-error "This conversation has ended; it cannot be reopened here"))
                 (if (fboundp 'lispm-agent-display-buffer)
                     (lispm-agent-display-buffer agent)
                   (lispm-switch agent)))
                (t buffer))))
    (when (and (or focus (not (eq lispm-agents-show-function #'pop-to-buffer)))
               (buffer-live-p owner)
               (with-current-buffer owner (derived-mode-p 'lispm-office-mode)))
      (lispm-office--prepare-navigation owner))
    (prog1 (cond
            ((and focus agent (fboundp 'lispm-terminal-show))
             (lispm-terminal-show agent))
            (focus
             ;; External terminal collaborators have no native Agent object.
             ;; Keep their existing canonical buffer in this frame's listener.
             (let ((window (lispm-office-inspect--display-chat
                            chat `((lispm-office-owner . ,owner)))))
               (unless window (user-error "The Focus listener is no longer available"))
               (when (fboundp 'lispm-terminal-keys-mode)
                 (with-current-buffer chat (lispm-terminal-keys-mode 1)))
               (select-window window)
               chat))
            (t (lispm-agents-show chat)))
      (when (and (buffer-live-p owner)
                 (with-current-buffer owner (derived-mode-p 'lispm-office-mode))
                 (not (get-buffer-window owner t)))
        ;; The core's close hook clears saved window state and closes the
        ;; owned Inspector.  Its window changes must not undo host navigation.
        (save-selected-window
          (save-current-buffer (kill-buffer owner)))))))

(defun lispm-office-send (key text)
  "Send TEXT as the user's next message to the live conversation KEY."
  (unless (and (stringp text) (not (string-empty-p (string-trim text))))
    (user-error "Write a message first"))
  (let* ((target (lispm-office-inspect--target key 'send))
         (agent (plist-get target :agent))
         (plain (substring-no-properties text)))
    (if agent (lispm-tell agent plain :from "user")
      (lispm-agents-bridge-deliver (plist-get target :buffer) plain
                                  (list :from "user" :text plain)))))

(defun lispm-office-inspect--call-signature (call)
  "Return an immutable description of CALL's requested action."
  (let ((asked (lispm-asked call)) (print-length nil) (print-level nil))
    (prin1-to-string (list (plist-get asked :name) (plist-get asked :input)))))

(defun lispm-office-inspect--permissions (target)
  "Snapshot current-turn permissions of TARGET in transcript order.
Each entry retains ID, call identity, asking identity and arguments."
  (let* ((agent (plist-get target :agent))
         (turn (lispm-agent-turn agent)))
    (cl-loop for id in (lispm-waiting-calls agent)
             for call = (gethash id (lispm-agent-pending agent))
             when (and (eq (plist-get call :status) 'ask)
                       (or (null (plist-get call :turn))
                           (eql (plist-get call :turn) turn)))
             collect (list id call (plist-get call :asking)
                           (lispm-office-inspect--call-signature call)))))

(defun lispm-office-inspect--validate-permissions (target turn calls &optional exact)
  "Check that TARGET's TURN still contains the permissions CALLS.
When EXACT, reject any addition or removal of current permissions."
  (lispm-office-inspect--same-target target (if exact 'approve-all 'approve))
  (let ((agent (plist-get target :agent)))
    (unless (and (eql turn (lispm-agent-turn agent))
                 (or (not exact)
                     (equal (mapcar #'car calls)
                            (mapcar #'car (lispm-office-inspect--permissions target))))
                 (cl-every
                  (pcase-lambda (`(,id ,call ,asking ,signature))
                    (and (eq call (gethash id (lispm-agent-pending agent)))
                         (eq (plist-get call :status) 'ask)
                         (eq asking (plist-get call :asking))
                         (equal signature (lispm-office-inspect--call-signature call))))
                  calls))
      (user-error "The pending permissions changed; review them again"))))

(defun lispm-office-inspect--choose-permission (target id)
  "Choose a permission of TARGET, or find exact ID, retaining its snapshot."
  (let ((calls (lispm-office-inspect--permissions target)))
    (unless calls (user-error "No permission call awaits approval"))
    (or (if id (assoc id calls)
          (if (null (cdr calls)) (car calls)
            (let* ((choices
                    (mapcar (lambda (entry)
                              (cons (format "%s: %s" (car entry)
                                            (plist-get (lispm-asked (cadr entry)) :name))
                                    entry)) calls))
                   (answer (completing-read "Permission: " choices nil t)))
              (cdr (assoc answer choices)))))
        (user-error "That permission is no longer pending"))))

(defun lispm-office-approve (key &optional call-id)
  "Approve one pending permission CALL-ID of conversation KEY."
  (let* ((target (lispm-office-inspect--target key 'approve))
         (agent (plist-get target :agent))
         (turn (lispm-agent-turn agent))
         (call (lispm-office-inspect--choose-permission target call-id)))
    (lispm-office-inspect--validate-permissions target turn (list call))
    (lispm-approve-for agent (car call))))

(defun lispm-office-deny (key &optional call-id)
  "Ask for a reason and deny pending permission CALL-ID of KEY."
  (let* ((target (lispm-office-inspect--target key 'deny))
         (agent (plist-get target :agent))
         (turn (lispm-agent-turn agent))
         (call (lispm-office-inspect--choose-permission target call-id))
         (reason (read-string "Reason (optional): ")))
    (lispm-office-inspect--validate-permissions target turn (list call))
    (lispm-deny-for agent reason (car call))))

(defun lispm-office-approve-all (key)
  "Preview and approve only KEY's current pending permissions.
A changed turn, replaced call or newly pending permission cancels this
preview.  The runtime also bounds synchronous continuations to this turn."
  (let* ((target (lispm-office-inspect--target key 'approve-all))
         (agent (plist-get target :agent))
         (turn (lispm-agent-turn agent))
         (calls (lispm-office-inspect--permissions target)))
    (unless calls (user-error "No permission call awaits approval"))
    (when (lispm-office-inspect--confirm-all target turn calls)
      (lispm-office-inspect--validate-permissions target turn calls t)
      (lispm-approve-all-for agent))))

(defun lispm-office-inspect--confirm-all (target turn calls)
  "Show complete arguments of TARGET's TURN CALLS before asking consent."
  (let ((preview (generate-new-buffer "*Office Permission Preview*")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer preview
            (insert (format "Pending permissions for %s — turn %s\n\n"
                            (plist-get target :name) turn))
            (dolist (entry calls)
              (let ((asked (lispm-asked (cadr entry))))
                (insert (format "%s  %s\n" (car entry) (plist-get asked :name)))
                (let ((print-length nil) (print-level nil) (print-circle t))
                  (insert (pp-to-string (plist-get asked :input)) "\n"))))
            (special-mode)
            (goto-char (point-min)))
          (display-buffer preview)
          (yes-or-no-p
           (format "Approve these %d calls for %s, turn %s: %s? "
                   (length calls) (plist-get target :name) turn
                   (mapconcat (lambda (entry)
                                (format "%s (%s)" (car entry)
                                        (plist-get (lispm-asked (cadr entry)) :name)))
                              calls ", "))))
      (when (buffer-live-p preview) (kill-buffer preview)))))

(defun lispm-office-abort (key)
  "Stop KEY's current turn, after explaining that queued inputs are cleared."
  (let* ((target (lispm-office-inspect--target key 'abort))
         (agent (plist-get target :agent))
         (turn (lispm-agent-turn agent)))
    (when (yes-or-no-p
           (format "Stop %s's current turn and clear all its queued inputs? "
                   (plist-get target :name)))
      (lispm-office-inspect--same-target target 'abort)
      (unless (eql turn (lispm-agent-turn agent))
        (user-error "A different turn has started; inspect it again"))
      (lispm-abort agent))))

(defun lispm-office-inspect--text (value)
  "Render VALUE as inert text without inherited display or key properties."
  (substring-no-properties (if (stringp value) value (format "%s" value))))

(defun lispm-office-inspect--line (label value)
  "Insert LABEL and VALUE as plain text when VALUE is known."
  (when value
    (insert (propertize (concat label ": ") 'face 'bold)
            (lispm-office-inspect--text value) "\n")))

(defun lispm-office-inspect--heading (text)
  "Insert a section heading TEXT."
  (if lispm-office-inspect--inline
      (progn (insert "\n")
             (lispm-office-details-heading text (lispm-office-inspect--available-width)))
    (insert "\n" (propertize text 'face 'bold) "\n")))

(defun lispm-office-inspect--available-width ()
  "Return this inspector's width in pixels, or terminal columns."
  (let* ((window (or (get-buffer-window (current-buffer) 'visible) (selected-window)))
         (tty (lispm-ui-tty-p)))
    ;; A terminal control must leave the last column free for Emacs's
    ;; continuation marker, including when the host uses partial-width panes.
    (max 1 (- (window-body-width window (not tty)) (if tty 1 0)
              (if lispm-office-inspect--inline (if tty 4 32) 0)))))

(defun lispm-office-inspect--tabs ()
  "Insert native tabs sized to the actual Inspector pane."
  (let* ((inspector (current-buffer))
         (width (lispm-office-inspect--available-width))
         (tabs
          (mapcar
           (lambda (entry)
             (list (cdr entry) (eq (car entry) lispm-office-inspect--tab)
                   'button (make-symbol "inspector-tab") 'category 'default-button
                   'keymap button-map 'follow-link t 'mouse-face 'highlight
                   'help-echo (cdr entry) 'lispm-ui-label (cdr entry)
                   'action (lambda (_)
                             (when (buffer-live-p inspector)
                               (with-current-buffer inspector
                                 (lispm-office-inspect--set-tab (car entry)))))))
           '((work . "Work") (mailbox . "Mailbox") (character . "Character")))))
    (if (and (fboundp 'lispm-desktop-platinum-tabs)
             (or (lispm-ui-tty-p) (>= width 164)))
        (insert (lispm-desktop-platinum-tabs tabs width))
      (let ((used 0))
        (dolist (tab tabs)
          (let* ((label (propertize (concat " " (car tab) " ")
                                    'face (if (cadr tab) 'tab-line-tab-current 'tab-line-tab)))
                 (size (if (lispm-ui-tty-p) (string-width label) (string-pixel-width label))))
            (when (and (> used 0) (> (+ used size) width))
              (insert "\n") (setq used 0))
            (insert (apply #'propertize label (cddr tab)))
            (cl-incf used size)))))
    (insert "\n")))

(defun lispm-office-inspect--title (text)
  "Insert a centered, inert agent title TEXT."
  (let* ((caption (propertize (lispm-office-inspect--text text) 'face 'bold))
         (width (lispm-office-inspect--available-width)))
    (insert (if (lispm-ui-tty-p)
                (make-string (max 0 (/ (- width (string-width caption)) 2)) ?\s)
              (propertize " " 'display
                          `(space :align-to (- center (,(/ (string-pixel-width caption) 2))))))
            caption "\n")))

(defun lispm-office-inspect--button (label function &rest arguments)
  "Insert a button LABEL that calls FUNCTION with ARGUMENTS, wrapping rows."
  (unless (equal lispm-office-inspect--button-end (point))
    (setq lispm-office-inspect--button-width 0))
  (let* ((tty (lispm-ui-tty-p))
         (width (if tty (+ (string-width label) 4)
                  (+ (lispm-ui-push-button-width label) 4)))
         (gap (if tty 1 (string-pixel-width " "))))
    (when (and (> lispm-office-inspect--button-width 0)
               (> (+ lispm-office-inspect--button-width width gap)
                  (lispm-office-inspect--available-width)))
      (insert "\n")
      (setq lispm-office-inspect--button-width 0))
    (cl-incf lispm-office-inspect--button-width (+ width gap)))
  (let ((inspector (current-buffer)))
    (lispm-ui-insert-push-button
     label (lambda ()
             (apply function arguments)
             (when (and (buffer-live-p inspector)
                        (with-current-buffer inspector
                          (or lispm-office-inspect--inline
                              (derived-mode-p 'lispm-office-inspect-mode))))
               (with-current-buffer inspector (lispm-office-inspect--draw))))))
  (insert " ")
  (setq lispm-office-inspect--button-end (point)))

(defun lispm-office-inspect--set-tab (tab)
  "Select TAB in this inspector."
  (setq lispm-office-inspect--tab tab)
  (lispm-office-inspect--draw))

(defun lispm-office-inspect--act-preview (target turn call deny)
  "Act on the permission CALL shown for TARGET's TURN.
When DENY, ask for a reason.  A stale inspector button must not approve
a new call that happens to reuse the old call's id."
  (lispm-office-inspect--validate-permissions target turn (list call))
  (funcall (if deny #'lispm-office-deny #'lispm-office-approve)
           (plist-get target :key) (car call)))

(defun lispm-office-inspect--calls (heading calls target)
  "Insert HEADING, CALLS and any available permission controls for TARGET."
  (lispm-office-inspect--heading heading)
  (if (null calls) (insert "None.\n")
    (dolist (call calls)
      (let ((id (plist-get call :id)))
        (if lispm-office-inspect--inline
            (insert (propertize (lispm-office-inspect--text (or (plist-get call :name) "Tool call"))
                                'face 'bold 'help-echo (lispm-office-inspect--text (or id "")))
                    "   " (propertize (capitalize (lispm-office-inspect--text (or (plist-get call :status) "unknown")))
                                      'face 'shadow) "\n")
          (insert (lispm-office-inspect--text (or id "?")) "  "
                  (lispm-office-inspect--text (or (plist-get call :name) "Unknown call"))
                  "  [" (lispm-office-inspect--text (or (plist-get call :status) "unknown")) "]\n"))
        (when (plist-get call :input-summary)
          (insert (lispm-office-inspect--text (plist-get call :input-summary)) "\n"))
        (when (and (eq (plist-get call :status) 'ask)
                   (memq 'approve (plist-get target :actions)))
          (when-let* ((preview (assoc id (if lispm-office-inspect--inline
                                            lispm-office-inspect--cached-permissions
                                          (lispm-office-inspect--permissions target)))))
            (let ((turn (if lispm-office-inspect--inline
                            (plist-get lispm-office-inspect--model :turn)
                          (lispm-agent-turn (plist-get target :agent)))))
              (lispm-office-inspect--button "Approve" #'lispm-office-inspect--act-preview
                                            target turn preview nil)
              (lispm-office-inspect--button "Deny" #'lispm-office-inspect--act-preview
                                            target turn preview t)
              (insert "\n"))))
        (insert "\n")))))

(defun lispm-office-inspect--work (details target)
  "Insert work DETAILS for TARGET."
  (let ((work (plist-get details :work)))
    (if (null work)
        (insert "\nStructured work details are not available for this agent.\n")
      (lispm-office-inspect--line "Turn" (plist-get work :turn))
      (lispm-office-inspect--calls "Pending calls" (plist-get work :pending-calls) target)
      (lispm-office-inspect--calls "Recent calls this turn" (plist-get work :recent-calls) target)
      (lispm-office-inspect--heading "Files touched this turn")
      (if (plist-get work :files)
          (dolist (file (plist-get work :files))
            (insert (lispm-office-inspect--text file) "\n"))
        (insert "None recorded.\n")))))

(defun lispm-office-inspect--mail-entry (entry)
  "Insert one inert mailbox ENTRY with its known metadata."
  (if lispm-office-inspect--inline
      (insert (propertize (lispm-office-inspect--text (or (plist-get entry :from) "Message"))
                          'face 'bold 'help-echo (lispm-office-inspect--text (or (plist-get entry :id) ""))) "\n")
    (dolist (field '((:from . "From") (:reply-to . "Reply to")
                     (:queued . "Queued") (:request-id . "Request") (:id . "Message")))
      (lispm-office-inspect--line (cdr field) (plist-get entry (car field)))))
  (insert (lispm-office-inspect--text (or (plist-get entry :text) "Text unavailable")) "\n\n"))

(defun lispm-office-inspect--relation (label keys)
  "Insert LABEL followed by buttons for live relation KEYS."
  (when keys
    (lispm-office-inspect--heading label)
    (dolist (key keys)
      (let ((owner lispm-office-inspect--owner))
        (lispm-office-inspect--button
         (format "%s / %s" (car key) (cadr key))
         #'lispm-office-inspect key 'work owner)))
    (insert "\n")))

(defun lispm-office-inspect--mailbox (details)
  "Insert mailbox and delegation DETAILS."
  (let ((mailbox (plist-get details :mailbox)))
    (if (null mailbox)
        (insert "\nStructured mailbox details are not available for this agent.\n")
      (lispm-office-inspect--heading "Handling")
      (if (plist-get mailbox :handling)
          (lispm-office-inspect--mail-entry (plist-get mailbox :handling))
        (insert "None.\n"))
      (lispm-office-inspect--heading "Queued")
      (if (plist-get mailbox :queued)
          (mapc #'lispm-office-inspect--mail-entry (plist-get mailbox :queued))
        (insert "None.\n"))))
  (lispm-office-inspect--relation "Waits on" (plist-get details :waits-on))
  (lispm-office-inspect--relation "Waited on by" (plist-get details :waited-on-by))
  (lispm-office-inspect--line "Requests" (plist-get details :request-ids)))

(defun lispm-office-inspect--character (target)
  "Read and insert the character identity of TARGET on demand."
  (let* ((agent (plist-get target :agent))
         (name (and agent (lispm-agent-character agent)))
         (character (and name (require 'lispm-characters nil t)
                         (lispm-get-character name t))))
    (if (not character)
        (insert "\nThis conversation has no character identity.\n")
      (lispm-office-inspect--line "Character" (or (lispm-character-title character) name))
      (lispm-office-inspect--line "Avatar" (lispm-character-avatar character))
      (lispm-office-inspect--line "Model" (or (lispm-agent-model agent)
                                             (lispm-character-model character) "Default"))
      (lispm-office-inspect--line "Skill" (lispm-character-skill character))
      (lispm-office-inspect--heading "Soul")
      (insert (lispm-office-inspect--text (or (lispm-character-soul character)
                                            "The app's skill describes its purpose.")) "\n")
      (when-let* ((self (lispm-character-self name)))
        (lispm-office-inspect--heading "In its own words")
        (insert (lispm-office-inspect--text self) "\n"))
      (lispm-office-inspect--heading "Lately")
      (let ((days (lispm-character-days name 5)))
        (if (null days) (insert "No diary entries yet.\n")
          (dolist (day days)
            (lispm-office-inspect--line (or (plist-get day :day) "Day") (plist-get day :title))
            (insert (lispm-office-inspect--text (or (plist-get day :text) "")) "\n\n")))))))

(defun lispm-office-inspect--draw-legacy ()
  "Refresh this inspector, preserving point and the selected tab."
  (unless lispm-ui-current-palette
    (lispm-ui-palette-follow-theme))
  (let ((inhibit-read-only t) (position (point))
        (lispm-office-inspect--button-end nil)
        (lispm-office-inspect--button-width 0))
    (setq lispm-office-inspect--width (lispm-office-inspect--available-width))
    (erase-buffer)
    (condition-case error
        (let* ((target (progn
                         (unless lispm-office-inspect--key
                           (user-error "Waiting for current session identity"))
                         (lispm-office-inspect--target lispm-office-inspect--key)))
               (status (lispm-agents-buffer-status (plist-get target :buffer))))
          (lispm-office-inspect--title (plist-get target :name))
          (lispm-office-inspect--line "State" (plist-get status :state))
          (lispm-office-inspect--line "Now" (plist-get status :msg))
          (lispm-office-inspect--tabs)
          (insert "\n")
          (lispm-office-inspect--button "Open Chat" #'lispm-office-open-chat lispm-office-inspect--key)
          (when (memq 'send (plist-get target :actions))
            (lispm-office-inspect--button "Compose" #'lispm-office-inspect-compose))
          (when (and (memq 'approve-all (plist-get target :actions))
                     (lispm-office-inspect--permissions target))
            (lispm-office-inspect--button "Approve All…" #'lispm-office-approve-all lispm-office-inspect--key))
          (when (memq 'abort (plist-get target :actions))
            (lispm-office-inspect--button "Stop…" #'lispm-office-abort lispm-office-inspect--key))
          (insert "\n")
          (pcase lispm-office-inspect--tab
            ('character (lispm-office-inspect--character target))
            (_ (let ((details (lispm-agents-roster-details lispm-office-inspect--key)))
                 (unless details (user-error "This conversation has ended"))
                 (if (eq lispm-office-inspect--tab 'mailbox)
                     (lispm-office-inspect--mailbox details)
                   (lispm-office-inspect--work details target))))))
      (error (insert "\n" (error-message-string error) "\n")))
    (setq lispm-office-inspect--dirty nil)
    (goto-char (min position (point-max)))))

(defun lispm-office-inspect--read-model ()
  "Read only the selected agent and active tab into the page cache."
  (setq lispm-office-inspect--model
        (condition-case err
            (let* ((target (lispm-office-inspect--target lispm-office-inspect--key))
                   (status (lispm-agents-buffer-status (plist-get target :buffer)))
                   (node (and (boundp 'lispm-office--plan)
                              (seq-find (lambda (item) (equal (plist-get item :key) lispm-office-inspect--key))
                                        (plist-get lispm-office--plan :nodes)))))
              (list :target target :status status
                    :turn (when (plist-get target :agent) (lispm-agent-turn (plist-get target :agent)))
                    :node (or node (list :key lispm-office-inspect--key
                                         :kind (car lispm-office-inspect--key)
                                         :name (plist-get target :name) :status status))
                    :permissions (when (memq 'approve (plist-get target :actions))
                                   (lispm-office-inspect--permissions target))
                    :details (unless (eq lispm-office-inspect--tab 'character)
                               (or (lispm-agents-roster-details lispm-office-inspect--key)
                                   (user-error "This conversation has ended")))
                    :character (when (eq lispm-office-inspect--tab 'character)
                                 (with-temp-buffer
                                   (lispm-office-inspect--character target)
                                   (buffer-string)))))
          (error (list :error (error-message-string err))))))

(defun lispm-office-inspect--empty (text)
  "Insert a quiet, readable empty state TEXT."
  (insert (propertize (lispm-office-inspect--text text) 'face 'shadow) "\n"))

(defun lispm-office-inspect--inline-work (details target)
  "Render the selected turn's activity without repetitive empty sections."
  (let* ((work (plist-get details :work))
         (pending (plist-get work :pending-calls))
         (recent (plist-get work :recent-calls))
         (files (plist-get work :files)))
    (lispm-office-inspect--heading "Current work")
    (if (not work)
        (lispm-office-inspect--empty "Open the conversation to see this agent's activity.")
      (insert (propertize (format "Turn %s" (or (plist-get work :turn) "—")) 'face 'bold)
              (format "   ·   %d pending   ·   %d files\n" (length pending) (length files)))
      (when pending (lispm-office-inspect--calls "Pending actions" pending target))
      (when recent (lispm-office-inspect--calls "Recent activity" recent target))
      (when files
        (lispm-office-inspect--heading "Files")
        (dolist (file files) (insert (lispm-office-inspect--text file) "\n")))
      (unless (or pending recent files)
        (insert "\n")
        (lispm-office-inspect--empty "No tool activity recorded in this turn.")))))

(defun lispm-office-inspect--inline-mailbox (details)
  "Render messages and collaboration links as sections of the page."
  (let* ((mailbox (plist-get details :mailbox))
         (handling (plist-get mailbox :handling))
         (queued (plist-get mailbox :queued)))
    (lispm-office-inspect--heading "Messages")
    (cond ((not mailbox) (lispm-office-inspect--empty "Mailbox details are unavailable for this agent."))
          ((not (or handling queued)) (lispm-office-inspect--empty "No messages waiting."))
          (t (when handling (lispm-office-inspect--mail-entry handling))
             (mapc #'lispm-office-inspect--mail-entry queued))))
  (lispm-office-inspect--relation "Waiting for" (plist-get details :waits-on))
  (lispm-office-inspect--relation "Helping" (plist-get details :waited-on-by)))

(defun lispm-office-inspect--draw (&optional cache-only)
  "Draw the current detail view; CACHE-ONLY never queries agent data."
  (if (not lispm-office-inspect--inline)
      (lispm-office-inspect--draw-legacy)
    (unless lispm-ui-current-palette (lispm-ui-palette-follow-theme))
    (unless cache-only (lispm-office-inspect--read-model))
    (let* ((inhibit-read-only t) (position (point))
           (model lispm-office-inspect--model)
           (target (plist-get model :target))
           (status (plist-get model :status))
           (lispm-office-inspect--cached-permissions (plist-get model :permissions))
           (lispm-office-inspect--button-end nil)
           (lispm-office-inspect--button-width 0))
      (setq lispm-office-inspect--width (lispm-office-inspect--available-width))
      (erase-buffer)
      (insert "\n")
      (lispm-office-inspect--button "‹ Back to Office" #'lispm-office-inspect-quit)
      (insert "\n\n")
      (if (plist-get model :error)
          (progn (lispm-office-inspect--heading "Conversation unavailable")
                 (lispm-office-inspect--empty (plist-get model :error)))
        (lispm-office-details-header target status (plist-get model :node) lispm-office-inspect--width)
        (insert "\n")
        (lispm-office-inspect--button "Open Chat" #'lispm-office-open-chat lispm-office-inspect--key)
        (when (memq 'send (plist-get target :actions))
          (lispm-office-inspect--button "Compose…" #'lispm-office-inspect-compose))
        (when (and (memq 'approve-all (plist-get target :actions)) lispm-office-inspect--cached-permissions)
          (lispm-office-inspect--button "Review Approvals…" #'lispm-office-approve-all lispm-office-inspect--key))
        (when (and (memq 'abort (plist-get target :actions))
                   (memq (plist-get status :state) '(working blocked thinking running)))
          (lispm-office-inspect--button "Stop…" #'lispm-office-abort lispm-office-inspect--key))
        (insert "\n\n")
        (lispm-office-inspect--tabs)
        (pcase lispm-office-inspect--tab
          ('character (lispm-office-inspect--heading "Identity")
                      (insert (or (plist-get model :character) "No character identity.") "\n"))
          ('mailbox (lispm-office-inspect--inline-mailbox (plist-get model :details)))
          (_ (lispm-office-inspect--inline-work (plist-get model :details) target))))
      (add-text-properties (point-min) (point-max) '(line-prefix "  " wrap-prefix "  "))
      (unless cache-only (setq lispm-office-inspect--dirty nil))
      (goto-char (min position (point-max))))))

(defun lispm-office-inspect-compose ()
  "Compose a message to this inspector's conversation."
  (interactive)
  (let* ((key (copy-sequence lispm-office-inspect--key))
         (target (lispm-office-inspect--target key 'send))
         (text (read-string (format "Message to %s: " (plist-get target :name)))))
    (lispm-office-inspect--same-target target 'send)
    (lispm-office-send key text)
    (lispm-office-inspect--draw)))

(defun lispm-office-inspect-open-chat ()
  "Open the conversation currently shown in this Inspector."
  (interactive)
  (unless lispm-office-inspect--key (user-error "No conversation selected"))
  (lispm-office-open-chat lispm-office-inspect--key))

(defun lispm-office-inspect-work ()
  "Show the current work of this conversation."
  (interactive) (lispm-office-inspect--set-tab 'work))
(defun lispm-office-inspect-mailbox ()
  "Show the mailbox of this conversation."
  (interactive) (lispm-office-inspect--set-tab 'mailbox))
(defun lispm-office-inspect-character ()
  "Show this conversation's character."
  (interactive) (lispm-office-inspect--set-tab 'character))
(defun lispm-office-inspect-revert ()
  "Read this conversation's current details again."
  (interactive) (lispm-office-inspect--draw))

(defun lispm-office-inspect--leave-inline (&optional return-to-floor)
  "Clear this page without killing its Work buffer.
RETURN-TO-FLOOR redraws and restores the saved floor viewport.  Navigation
and buffer teardown omit it so they cannot overwrite the host's next view."
  (when lispm-office-inspect--inline
    (let ((state lispm-office-inspect--floor-state)
          (window (get-buffer-window (current-buffer) t)))
      (setq lispm-office-inspect--inline nil
            lispm-office-inspect--owner nil
            lispm-office-inspect--key nil
            lispm-office-inspect--model nil
            lispm-office-inspect--width nil
            lispm-office-inspect--floor-state nil
            lispm-office-inspect--dirty nil)
      (lispm-office-inspect-inline-mode -1)
      (setq-local truncate-lines (plist-get state :truncate)
                  truncate-partial-width-windows (plist-get state :partial)
                  word-wrap (plist-get state :wrap))
      (when return-to-floor
        (lispm-office--draw)
        (goto-char (min (point-max) (max (point-min) (or (plist-get state :point) (point-min)))))
        (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
          (set-window-point window (point))
          (set-window-start window (min (point-max) (max (point-min) (or (plist-get state :start) (point-min)))) t)
          (set-window-hscroll window (or (plist-get state :hscroll) 0))
          (set-window-vscroll window (or (plist-get state :vscroll) 0) t))
        (lispm-office--sync-timer)))))

(defun lispm-office-inspect-quit ()
  "Return to the floor, or close a legacy Inspector pane."
  (interactive)
  (if lispm-office-inspect--inline
      (lispm-office-inspect--leave-inline t)
    (let ((owner lispm-office-inspect--owner))
      (lispm-office-inspect--close-buffer (current-buffer))
      (when (and (buffer-live-p owner)
                 (eq (window-buffer (selected-window)) owner)
                 (with-current-buffer owner (derived-mode-p 'lispm-office-mode)))
        (with-current-buffer owner (lispm-office--focus-selection))))))

(defun lispm-office-inspect--forget ()
  "Remove this inspector's panes and registry entry when it is killed."
  (lispm-office-inspect--close-windows (current-buffer))
  (setq lispm-office-inspect--buffers
        (cl-delete (current-buffer) lispm-office-inspect--buffers :key #'cdr :test #'eq)))

(define-derived-mode lispm-office-inspect-mode special-mode "Office Inspector"
  "Inspect one Office conversation's work, mailbox and character."
  (setq-local truncate-lines nil
              truncate-partial-width-windows nil
              word-wrap t)
  (add-hook 'kill-buffer-hook #'lispm-office-inspect--forget nil t))

(lispm-kit-define-commands lispm-office-inspect-mode
  :menu "Inspector"
  (lispm-office-inspect-work :key "w" :label "Work")
  (lispm-office-inspect-mailbox :key "m" :label "Mailbox")
  (lispm-office-inspect-character :key "c" :label "Character")
  (lispm-office-inspect-open-chat :key "o" :label "Open Chat")
  (lispm-office-inspect-compose :key "s" :label "Compose…")
  (lispm-office-inspect-revert :key "g" :label "Refresh")
  (lispm-office-inspect-quit :key "q" :label "Close"))

(lispm-office-inspect--focus-keys lispm-office-inspect-mode-map)
(define-key lispm-office-inspect-mode-map (kbd "TAB") #'forward-button)
(define-key lispm-office-inspect-mode-map (kbd "<tab>") #'forward-button)
(define-key lispm-office-inspect-mode-map (kbd "<backtab>") #'backward-button)

(defun lispm-office-inspect--key-action (function)
  "Run FUNCTION against the displayed identity, then refresh its page."
  (unless lispm-office-inspect--key (user-error "No conversation selected"))
  (let ((buffer (current-buffer)))
    (funcall function (copy-sequence lispm-office-inspect--key))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when lispm-office-inspect--inline (lispm-office-inspect--draw))))))

(defun lispm-office-inspect-approve ()
  "Review a permission for the displayed conversation."
  (interactive) (lispm-office-inspect--key-action #'lispm-office-approve))
(defun lispm-office-inspect-approve-all ()
  "Review all current permissions for the displayed conversation."
  (interactive) (lispm-office-inspect--key-action #'lispm-office-approve-all))
(defun lispm-office-inspect-deny ()
  "Deny a permission for the displayed conversation."
  (interactive) (lispm-office-inspect--key-action #'lispm-office-deny))
(defun lispm-office-inspect-abort ()
  "Confirm stopping the displayed conversation's current turn."
  (interactive) (lispm-office-inspect--key-action #'lispm-office-abort))

(define-minor-mode lispm-office-inspect-inline-mode
  "Navigate agent details inside the current Work buffer."
  :lighter nil :keymap (let ((map (make-sparse-keymap)))
                        (set-keymap-parent map lispm-office-inspect-mode-map)
                        (dolist (entry '(("<up>" . previous-line) ("<down>" . next-line)
                                         ("<left>" . backward-char) ("<right>" . forward-char)
                                         ("C-b" . backward-char) ("C-f" . forward-char)
                                         ("C-n" . next-line) ("C-p" . previous-line)
                                         ("n" . next-line) ("<mouse-1>" . mouse-set-point)
                                         ("RET" . push-button) ("SPC" . scroll-up-command)))
                          (define-key map (kbd (car entry)) (cdr entry)))
                        ;; Detail actions address the shown conversation, which
                        ;; can differ from the floor selection after following
                        ;; a collaboration link.  Floor-only commands cannot
                        ;; mutate the hidden scene through keys or menus.
                        (dolist (entry '((lispm-office-approve-selected . lispm-office-inspect-approve)
                                         (lispm-office-approve-all-selected . lispm-office-inspect-approve-all)
                                         (lispm-office-deny-selected . lispm-office-inspect-deny)
                                         (lispm-office-abort-selected . lispm-office-inspect-abort)
                                         (lispm-office-chat . lispm-office-inspect-open-chat)
                                         (lispm-office-message . lispm-office-inspect-compose)
                                         (lispm-office-inspect-selected . lispm-office-inspect-revert)
                                         (lispm-office-work . lispm-office-inspect-work)
                                         (lispm-office-mailbox . lispm-office-inspect-mailbox)
                                         (lispm-office-character . lispm-office-inspect-character)
                                         (lispm-office-refresh . lispm-office-inspect-revert)
                                         (lispm-office-quit . lispm-office-inspect-quit)
                                         (lispm-office-left . backward-char)
                                         (lispm-office-right . forward-char)
                                         (lispm-office-up . previous-line)
                                         (lispm-office-down . next-line)
                                         (lispm-office-mouse . mouse-set-point)))
                          (define-key map (vector 'remap (car entry)) (cdr entry)))
                        (dolist (command '(lispm-office-next-waiting lispm-office-zoom-in
                                           lispm-office-zoom-out lispm-office-fit lispm-office-session
                                           lispm-office-project lispm-office-overview lispm-office-choose-room
                                           lispm-office-toggle-text lispm-office-compact))
                          (define-key map (vector 'remap command) #'undefined))
                        map))

(defun lispm-office-inspect (key &optional tab owner)
  "Show KEY's details in OWNER's Work page without creating another pane.
For callers outside Work, retain the legacy standalone Inspector API."
  (lispm-office-inspect--target key)
  (when (and tab (not (memq tab '(work mailbox character)))) (user-error "Unknown inspector tab"))
  (let ((owner (or owner (current-buffer))))
    (if (not (with-current-buffer owner (derived-mode-p 'lispm-office-mode)))
        (lispm-office-inspect--legacy key tab owner)
      (when-let* ((old (cdr (assq owner lispm-office-inspect--buffers))))
        (lispm-office-inspect--close-buffer old))
      (with-current-buffer owner
        (unless lispm-office-inspect--inline
          (let ((window (get-buffer-window owner t)))
            (setq lispm-office-inspect--floor-state
                  (list :point (point) :start (and window (window-start window))
                        :hscroll (and window (window-hscroll window))
                        :vscroll (and window (window-vscroll window t))
                        :truncate truncate-lines :partial truncate-partial-width-windows :wrap word-wrap)))
          (setq lispm-office-inspect--tab 'work))
        (setq lispm-office-inspect--inline t
              lispm-office-inspect--owner owner
              lispm-office-inspect--key (copy-sequence key))
        (setq-local truncate-lines nil truncate-partial-width-windows nil word-wrap t)
        (when tab (setq lispm-office-inspect--tab tab))
        (lispm-office-inspect-inline-mode 1)
        (lispm-office--sync-timer)
        (lispm-office-inspect--draw)
        (goto-char (point-min))
        (when-let* ((window (get-buffer-window owner t)))
          (set-window-point window (point-min))
          (set-window-start window (point-min))
          (set-window-hscroll window 0)
          (set-window-vscroll window 0 t)))
      (when-let* ((window (get-buffer-window owner t))) (select-window window))
      owner)))

(defun lispm-office-inspect--legacy (key &optional tab owner)
  "Inspect stable KEY in TAB, in a buffer belonging to OWNER.
TAB is work, mailbox or character.  OWNER defaults to the current
buffer.  An existing inspector for this owner keeps its selected tab."
  (lispm-office-inspect--target key)
  (let* ((owner (or owner (current-buffer)))
         (existing (cdr (assq owner lispm-office-inspect--buffers)))
         (buffer (if (buffer-live-p existing) existing
                   (generate-new-buffer "*LispM Office Inspector*"))))
    (unless (buffer-live-p existing)
      (push (cons owner buffer) lispm-office-inspect--buffers)
      (with-current-buffer buffer (lispm-office-inspect-mode)))
    (with-current-buffer buffer
      (setq lispm-office-inspect--owner owner
            lispm-office-inspect--key (copy-sequence key))
      (when tab
        (unless (memq tab '(work mailbox character)) (user-error "Unknown inspector tab"))
        (setq lispm-office-inspect--tab tab)))
    (let* ((owner-window
            (seq-find (lambda (window) (window-parameter window 'window-side))
                      (get-buffer-window-list owner nil (selected-frame))))
           (window
            (display-buffer-in-side-window
             buffer (if owner-window
                        `((side . ,(window-parameter owner-window 'window-side))
                          (slot . ,(1+ (or (window-parameter owner-window 'window-slot) 0)))
                          (window-width . ,(window-total-width owner-window)))
                      '((side . right) (slot . 0))))))
      (set-window-parameter window 'lispm-office-inspector (buffer-name buffer))
      (select-window window)
      (with-current-buffer buffer (lispm-office-inspect--draw)))
    buffer))

(defun lispm-office-inspect-follow (owner key)
  "Retarget OWNER's existing inspector to KEY without taking focus.
Nil KEY shows a pending session identity without reading agent details.
Preserve its tab, and defer details until visible.  This does not
create or display an inspector."
  (when-let* ((buffer (lispm-office-inspect-buffer owner))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (unless (equal key lispm-office-inspect--key)
        (when key (lispm-office-inspect--target key))
        (setq lispm-office-inspect--key (copy-sequence key)
              lispm-office-inspect--dirty t)
        (when (lispm-office-inspect--visible-p)
          (lispm-office-inspect--draw))))))

(defun lispm-office-inspect-refresh (owner keys)
  "Refresh OWNER's inspector only if its selected identity is in KEYS.
Nil KEYS means all identities may have changed.  No roster is scanned."
  (let ((buffer (lispm-office-inspect-buffer owner)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (or (null keys) (member lispm-office-inspect--key keys))
          (setq lispm-office-inspect--dirty t)
          (when (lispm-office-inspect--visible-p)
            (lispm-office-inspect--draw)))))))

(defun lispm-office-inspect--visible-p ()
  "Whether the current inspector is shown in a visible frame."
  (seq-some (lambda (window) (eq (frame-visible-p (window-frame window)) t))
            (get-buffer-window-list (current-buffer) nil t)))

(defun lispm-office-inspect-visible-refresh (owner)
  "Refresh OWNER's dirty inspector after it becomes visible again.
The Office calls this from its window visibility callback."
  (when-let* ((buffer (lispm-office-inspect-buffer owner))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (when (and (lispm-office-inspect--visible-p)
                 (or lispm-office-inspect--dirty
                     (and lispm-office-inspect--width
                          (/= lispm-office-inspect--width
                              (lispm-office-inspect--available-width)))))
        (if (and lispm-office-inspect--inline (not lispm-office-inspect--dirty))
            (lispm-office-inspect--draw t)
          (lispm-office-inspect--draw))))))

(defun lispm-office-inspect-close (owner)
  "Clear OWNER's inline state and close only its legacy Inspector."
  (when (buffer-live-p owner)
    (with-current-buffer owner (lispm-office-inspect--leave-inline)))
  (when-let* ((buffer (cdr (assq owner lispm-office-inspect--buffers))))
    (lispm-office-inspect--close-buffer buffer)))

(defun lispm-office-inspect--close-buffer (buffer)
  "Close BUFFER and its windows without changing source conversations."
  (when (buffer-live-p buffer)
    (let ((was-current (eq (current-buffer) buffer)))
      (lispm-office-inspect--close-windows buffer)
      (kill-buffer buffer)
      (when was-current
        (set-buffer (window-buffer (selected-window)))))))

(defun lispm-office-inspect-unload-function ()
  "Release Inspector windows and restoration hooks before unloading."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when lispm-office-inspect--inline (lispm-office-inspect--leave-inline t))))
  (dolist (entry (copy-sequence lispm-office-inspect--buffers))
    (lispm-office-inspect--close-buffer (cdr entry)))
  (remove-hook 'window-state-change-functions #'lispm-office-inspect-cleanup-windows)
  (remove-hook 'tab-bar-tab-post-select-functions #'lispm-office-inspect-cleanup-windows)
  (setq window-persistent-parameters
        (assq-delete-all 'lispm-office-inspector window-persistent-parameters))
  nil)

(add-to-list 'window-persistent-parameters '(lispm-office-inspector . writable))
(add-hook 'window-state-change-functions #'lispm-office-inspect-cleanup-windows)
(add-hook 'tab-bar-tab-post-select-functions #'lispm-office-inspect-cleanup-windows)

(provide 'lispm-office-inspect)
;;; lispm-office-inspect.el ends here
