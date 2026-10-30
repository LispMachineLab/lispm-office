;;; lispm-office-demo.el --- Isolated preview data for Office -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Commentary:
;; Fixtures are never given to agent operations or written to saved seats.
;;; Code:
(require 'cl-lib)

(defun lispm-office-demo-records (count)
  "Return COUNT stable preview records, between two and 1000."
  (unless (and (integerp count) (<= 2 count 1000))
    (user-error "Choose between 2 and 1000 agents"))
  (cl-loop for i below count
           for kind = (nth (mod i 3) '(lispm claude codex))
           for state = (nth (mod i 7) '(working blocked idle working done blocked error))
           for root = (if (< i 4) (expand-file-name "~/")
                        (format "/projects/%s/" (nth (mod (/ (- i 4) 12) 5)
                                                       '(kernel editor tools research website))))
           collect (list :key (list kind (format "preview-%03d" i))
                         :name (format "%s %d" (nth (mod i 6) '(Ada Grace Alan Claude Codex Probe)) (1+ i))
                         :kind kind :root root :alive t :running (eq state 'working)
                         :parent (when (= (mod i 4) 1)
                                   (list (nth (mod (1- i) 3) '(lispm claude codex))
                                         (format "preview-%03d" (1- i))))
                         :status (list :state state
                                       :kind (when (eq state 'blocked) (if (= (mod i 7) 1) 'permission 'question))
                                       :msg (pcase state ('working "Reading and editing")
                                                   ('blocked "Waiting for your decision")
                                                   ('done "Tests passed") ('error "Connection interrupted")
                                                   (_ "Ready")))
                         :mailbox (list :handling (eq state 'working) :queued (mod i 4))
                         :actions nil)))

(provide 'lispm-office-demo)
;;; lispm-office-demo.el ends here
