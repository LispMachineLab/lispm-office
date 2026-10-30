;;; lispm-office-extension.el --- Store lifecycle entry for Office -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Hosts activate this extension through `require' and deactivate it through
;; `unload-feature'.  The plugin itself remains passive when merely required.
;; Loading this entry again re-enables the plugin without duplicate observers.

;;; Code:

(require 'lispm-office-plugin)

(defun lispm-office-extension-unload-function ()
  "Deactivate Office and unload its code so reinstall can load a new version.
The Store owns installation and activation.  Shared Agent, Kit and UI
features are never unloaded; existing agent sessions continue running."
  (when (fboundp 'lispm-office-plugin-mode) (lispm-office-plugin-mode -1))
  ;; Consumers precede providers.  Force allows this activation feature to
  ;; release its own dependencies before Emacs unloads its final definition.
  (dolist (feature '(lispm-office-plugin lispm-office lispm-office-inspect
                    lispm-office-details lispm-office-demo
                    lispm-office-render lispm-office-layout))
    (when (featurep feature) (unload-feature feature t)))
  nil)

(lispm-office-plugin-mode 1)

(provide 'lispm-office-extension)
;;; lispm-office-extension.el ends here
