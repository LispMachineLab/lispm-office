;;; lispm-office-plugin.el --- Work view toggle inside LispM Agent -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Enable `lispm-office-plugin-mode', then use C-c O in an agent conversation
;; to switch that window between conversation and work.  Session events attach the
;; command and follow the active agent.  No polling or roster subscription is
;; needed until a live panel opens.  Disabling leaves conversations running.

;;; Code:

(require 'lispm-office)
(require 'easymenu)

(defvar lispm-chat-mode-hook)
(defvar lispm-session-mode-hook)
(defvar lispm-agents-sessions-changed-hook)
(defvar lispm-agents-open-project-functions)
(defvar lispm-office-plugin-mode)
(defvar-local lispm-office-plugin--saved-header nil "Header before plugin activation.")
(defvar-local lispm-office-plugin--header-was-local nil "Whether the original header was local.")
(defvar-local lispm-office-plugin--header nil "Header installed by this plugin.")

(defcustom lispm-office-follow-current-agent t
  "Whether an open work panel follows the selected agent conversation."
  :type 'boolean :group 'lispm-office)

(defvar lispm-office-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c O") #'lispm-office-toggle)
    map)
  "Work visualization commands in agent conversation buffers.")

(define-minor-mode lispm-office-agent-mode
  "Provide the Conversation / Work toggle in this agent conversation."
  :lighter nil :keymap lispm-office-agent-mode-map :group 'lispm-office
  (if lispm-office-agent-mode
      (unless lispm-office-plugin--header
        (lispm-office--ensure-ui)
        (setq lispm-office-plugin--saved-header header-line-format
              lispm-office-plugin--header-was-local (local-variable-p 'header-line-format)
              lispm-office-plugin--header
              (list '(:eval (lispm-office--view-switcher)) header-line-format))
        (setq-local header-line-format lispm-office-plugin--header))
    (when (eq header-line-format lispm-office-plugin--header)
      (if lispm-office-plugin--header-was-local
          (setq-local header-line-format lispm-office-plugin--saved-header)
        (kill-local-variable 'header-line-format)))
    (setq lispm-office-plugin--header nil lispm-office-plugin--saved-header nil)))

(easy-menu-define lispm-office-agent-menu lispm-office-agent-mode-map
  "Agent work visualization."
  '("Agent Work" ["Toggle Current Work" lispm-office-toggle t]))

(defun lispm-office-plugin--attach ()
  "Attach visualization commands to the current agent buffer."
  (when (and lispm-office-plugin-mode (lispm-office--source-p (current-buffer)))
    (lispm-office-agent-mode 1)))

(defun lispm-office-plugin--sessions-changed ()
  "Attach commands after agent sessions are created or discovered."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer (lispm-office-plugin--attach))))

(defun lispm-office-plugin--window-changed (frame-or-window)
  "Follow the selected conversation after FRAME-OR-WINDOW changes.
Global window hooks pass a frame; local invocations can pass a window."
  (when lispm-office-plugin-mode
    (let* ((window (if (windowp frame-or-window) frame-or-window
                     (frame-selected-window frame-or-window)))
           (source (and (window-live-p window) (window-buffer window))))
      (when (and (eq window (selected-window)) (lispm-office--source-p source))
        (with-current-buffer source (lispm-office-plugin--attach))
        (when lispm-office-follow-current-agent
          (dolist (buffer lispm-office--buffers)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (when (and (not lispm-office--demo)
                           (get-buffer-window buffer (window-frame window))
                           (lispm-office--focus-source source))
                  (lispm-office--draw)
                  (lispm-office--sync-timer))))))))))

(defun lispm-office-plugin--disable ()
  "Release plugin hooks, bindings and live panels, preserving conversations."
  (remove-hook 'lispm-chat-mode-hook #'lispm-office-plugin--attach)
  (remove-hook 'lispm-session-mode-hook #'lispm-office-plugin--attach)
  (remove-hook 'lispm-agents-sessions-changed-hook #'lispm-office-plugin--sessions-changed)
  (remove-hook 'lispm-agents-open-project-functions #'lispm-office-open-project)
  (remove-hook 'window-selection-change-functions #'lispm-office-plugin--window-changed)
  (remove-hook 'window-buffer-change-functions #'lispm-office-plugin--window-changed)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when lispm-office-agent-mode (lispm-office-agent-mode -1))))
  (when (fboundp 'lispm-office-shutdown) (lispm-office-shutdown)))

;;;###autoload
(define-minor-mode lispm-office-plugin-mode
  "Integrate the current-work visualization into LispM Agent sessions.
Use the Conversation / Work control or C-c O to switch the current window.
Disabling closes all panels, previews and inspectors; sessions stay intact."
  :global t :group 'lispm-office
  (if (not lispm-office-plugin-mode)
      (lispm-office-plugin--disable)
    (condition-case err
        (progn
          (require 'lispm-office)
          (unless (require 'lispm-agents-work nil t)
            (user-error "LispM Agent 0.15.0 or later is required"))
          (add-hook 'lispm-chat-mode-hook #'lispm-office-plugin--attach)
          (add-hook 'lispm-session-mode-hook #'lispm-office-plugin--attach)
          (add-hook 'lispm-agents-sessions-changed-hook #'lispm-office-plugin--sessions-changed)
          (add-hook 'lispm-agents-open-project-functions #'lispm-office-open-project)
          (add-hook 'window-selection-change-functions #'lispm-office-plugin--window-changed)
          (add-hook 'window-buffer-change-functions #'lispm-office-plugin--window-changed)
          (lispm-office-plugin--sessions-changed))
      (error
       (setq lispm-office-plugin-mode nil)
       (lispm-office-plugin--disable)
       (signal (car err) (cdr err))))))

(defun lispm-office-plugin-unload-function ()
  "Release plugin resources before Emacs unloads its definitions."
  (lispm-office-plugin-mode -1)
  nil)

(provide 'lispm-office-plugin)
;;; lispm-office-plugin.el ends here
