;;; lispm-office-layout.el --- Stable rooms and seats for LispM Office -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Layout is plain data, independent of the renderer and agent runtime.
;; A room never moves and an absent agent keeps its seat.  Only Compact
;; discards reservations.  Saved files contain data, never executable code.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst lispm-office-layout--room-width 450)
(defconst lispm-office-layout--room-height 454)
(defconst lispm-office-layout--file-limit (* 4 1024 1024)
  "Maximum number of bytes read from a saved seating file.")

(defun lispm-office-layout--key-p (key)
  "Return non-nil if KEY is a persistent (KIND SESSION-ID) identity."
  (and (proper-list-p key) (= (length key) 2)
       (symbolp (car key)) (car key) (not (keywordp (car key)))
       (stringp (cadr key)) (not (string-empty-p (cadr key)))))

(defun lispm-office-layout--root (root)
  "Normalize ROOT without consulting the filesystem.
A missing root denotes Home.  Remote paths are kept remote and no
connection is opened merely to lay out their rooms."
  (unless (or (null root) (and (stringp root) (not (string-empty-p root))))
    (error "Invalid Office project root: %S" root))
  (file-name-as-directory (expand-file-name (or root "~"))))

(defun lispm-office-layout--plist-p (value keys)
  "Return non-nil when VALUE has exactly the properties in KEYS."
  (and (proper-list-p value) (= (length value) (* 2 (length keys)))
       (let ((seen nil) (tail value))
         (while (and tail (memq (car tail) keys) (not (memq (car tail) seen)))
           (push (car tail) seen)
           (setq tail (cddr tail)))
         (null tail))))

(defun lispm-office-layout--validate (state)
  "Return STATE if it is a valid seating database, or signal an error."
  (unless (and (lispm-office-layout--plist-p state '(:version :rooms :seats))
               (eql (plist-get state :version) 1)
               (proper-list-p (plist-get state :rooms))
               (proper-list-p (plist-get state :seats)))
    (error "Invalid Office seating database or unsupported version"))
  (let ((rooms (make-hash-table :test #'eql))
        (keys (make-hash-table :test #'equal))
        (occupied (make-hash-table :test #'equal))
        (index 0))
    (dolist (room (plist-get state :rooms))
      (unless (and (lispm-office-layout--plist-p
                    room '(:id :root :label :x :y :width :height))
                   (eql (plist-get room :id) index)
                   (stringp (plist-get room :root))
                   (equal (plist-get room :root)
                          (lispm-office-layout--root (plist-get room :root)))
                   (stringp (plist-get room :label))
                   (eql (plist-get room :x) (+ 16 (* (% index 3) 474)))
                   (eql (plist-get room :y) (+ 16 (* (/ index 3) 478)))
                   (eql (plist-get room :width) lispm-office-layout--room-width)
                   (eql (plist-get room :height) lispm-office-layout--room-height))
        (error "Invalid Office room %S" index))
      (puthash index room rooms)
      (setq index (1+ index)))
    (dolist (entry (plist-get state :seats))
      (unless (and (consp entry) (lispm-office-layout--key-p (car entry))
                   (not (gethash (car entry) keys))
                   (lispm-office-layout--plist-p (cdr entry) '(:room :slot))
                   (integerp (plist-get (cdr entry) :room))
                   (gethash (plist-get (cdr entry) :room) rooms)
                   (integerp (plist-get (cdr entry) :slot))
                   (<= 0 (plist-get (cdr entry) :slot))
                   (< (plist-get (cdr entry) :slot) 16))
        (error "Invalid or duplicate Office seat identity: %S" (car-safe entry)))
      (let ((position (list (plist-get (cdr entry) :room)
                            (plist-get (cdr entry) :slot))))
        (when (gethash position occupied)
          (error "Several Office agents occupy seat %S" position))
        (puthash position t occupied))
      (puthash (car entry) t keys)))
  state)

(defun lispm-office-layout--records (records)
  "Index RECORDS by stable key, rejecting ambiguous identities.
Fresh terminals without a key are omitted.  No input record is changed."
  (unless (proper-list-p records) (error "Invalid Office roster"))
  (let ((index (make-hash-table :test #'equal)))
    (dolist (record records)
      (unless (and (proper-list-p record) (zerop (% (length record) 2)))
        (error "Invalid Office roster record"))
      (when-let* ((key (plist-get record :key)))
        (unless (lispm-office-layout--key-p key)
          (error "Invalid Office agent identity: %S" key))
        (when (gethash key index) (error "Duplicate Office agent identity: %S" key))
        (lispm-office-layout--root (plist-get record :root))
        (puthash key record index)))
    index))

(defun lispm-office-layout--room (root id annex)
  "Make room ID for ROOT; ANNEX is its zero-based number at that root."
  (let ((name (if (equal root (lispm-office-layout--root nil)) "Home"
                (let ((leaf (file-name-nondirectory (directory-file-name root))))
                  (if (string-empty-p leaf) root leaf)))))
    (list :id id :root root :label (if (zerop annex) name (format "%s (%d)" name (1+ annex)))
          :x (+ 16 (* (% id 3) 474)) :y (+ 16 (* (/ id 3) 478))
          :width lispm-office-layout--room-width :height lispm-office-layout--room-height)))

(defun lispm-office-layout-reconcile (state records)
  "Return STATE with stable seats allocated for RECORDS.
This does not mutate STATE or RECORDS.  Missing records retain their
reservations.  A changed project root relocates that agent only.
New children prefer their parent's pod, then its room and project.
Existing seats win over later changes to parentage.  Parent cycles
are broken deterministically without recursion."
  (let* ((state (copy-tree (lispm-office-layout--validate
                            (or state '(:version 1 :rooms nil :seats nil)))))
         (records-by-key (lispm-office-layout--records records))
         (rooms (plist-get state :rooms))
         (room-index (make-hash-table :test #'eql))
         (root-index (make-hash-table :test #'equal))
         (seats (make-hash-table :test #'equal))
         (occupied (make-hash-table :test #'eql))
         (visiting (make-hash-table :test #'equal))
         (new-seats nil)
         (next-room (length rooms))
         (ordered nil))
    (dolist (room rooms)
      (puthash (plist-get room :id) room room-index)
      (puthash (plist-get room :id) (make-vector 16 nil) occupied)
      (push room (gethash (plist-get room :root) root-index)))
    (maphash (lambda (root values) (puthash root (nreverse values) root-index)) root-index)
    (dolist (entry (plist-get state :seats))
      (let* ((key (car entry)) (seat (cdr entry))
             (record (gethash key records-by-key))
             (room (gethash (plist-get seat :room) room-index)))
        (unless (and record
                     (not (equal (plist-get room :root)
                                 (lispm-office-layout--root (plist-get record :root)))))
          (puthash key seat seats)
          (aset (gethash (plist-get seat :room) occupied) (plist-get seat :slot) t)
          (push entry new-seats))))
    (maphash (lambda (key _record) (push key ordered)) records-by-key)
    (setq ordered (sort ordered (lambda (a b) (string< (prin1-to-string a) (prin1-to-string b)))))
    (cl-labels
        ((parent-key
          (record)
          (let* ((key (plist-get record :parent))
                 (parent (and (lispm-office-layout--key-p key) (gethash key records-by-key))))
            (and parent
                 (equal (lispm-office-layout--root (plist-get parent :root))
                        (lispm-office-layout--root (plist-get record :root)))
                 key)))
         (free-slot
          (room &optional pod)
          (let ((used (gethash (plist-get room :id) occupied)))
            (seq-find (lambda (slot) (not (aref used slot)))
                      (if pod (number-sequence (* pod 4) (+ (* pod 4) 3))
                        (number-sequence 0 15)))))
         (allocate
          (key)
          (let* ((record (gethash key records-by-key))
                 (root (lispm-office-layout--root (plist-get record :root)))
                 (parent-seat (gethash (plist-get record :parent) seats))
                 (parent-room (and parent-seat (gethash (plist-get parent-seat :room) room-index)))
                 (room nil) (slot nil))
            (when (and parent-room (equal root (plist-get parent-room :root)))
              (setq slot (or (free-slot parent-room (/ (plist-get parent-seat :slot) 4))
                             (free-slot parent-room)))
              (when slot (setq room parent-room)))
            (unless room
              (dolist (candidate (gethash root root-index))
                (unless room
                  (when-let* ((available (free-slot candidate)))
                    (setq room candidate slot available)))))
            (unless room
              (setq room (lispm-office-layout--room root next-room (length (gethash root root-index)))
                    slot 0 next-room (1+ next-room))
              (puthash (plist-get room :id) room room-index)
              (puthash (plist-get room :id) (make-vector 16 nil) occupied)
              (puthash root (append (gethash root root-index) (list room)) root-index)
              (setq rooms (append rooms (list room))))
            (let ((seat (list :room (plist-get room :id) :slot slot)))
              (puthash key seat seats)
              (aset (gethash (plist-get room :id) occupied) slot t)
              (push (cons (copy-tree key) seat) new-seats)))))
      (dolist (key ordered)
        (unless (gethash key seats)
          (let ((current key) (stack nil))
            (while (and current (not (gethash current seats)) (not (gethash current visiting)))
              (puthash current t visiting)
              (push current stack)
              (setq current (parent-key (gethash current records-by-key))))
            (dolist (pending stack)
              (allocate pending)
              (remhash pending visiting))))))
    (list :version 1 :rooms rooms :seats (nreverse new-seats))))

(defun lispm-office-layout-compact (_state records)
  "Repack RECORDS, discarding all old room and seat reservations.
Unlike ordinary reconciliation, this deliberately moves existing desks."
  (lispm-office-layout-reconcile nil records))

(defun lispm-office-layout-plan (state records)
  "Return visible rooms and desk bounds for STATE and RECORDS.
The result has :rooms, :nodes, :width and :height.  Each node copies
its roster record and adds :room, :slot, :x, :y, :width and :height.
Rooms with no live record are omitted, while their reserved positions
remain in STATE.  Input data is never mutated."
  (lispm-office-layout--validate state)
  (let ((records-by-key (lispm-office-layout--records records))
        (room-index (make-hash-table :test #'eql))
        (nodes-by-room (make-hash-table :test #'eql))
        (nodes nil) (visible nil) (width 32) (height 32))
    (dolist (room (plist-get state :rooms))
      (puthash (plist-get room :id) room room-index))
    (dolist (entry (plist-get state :seats))
      (when-let* ((record (gethash (car entry) records-by-key)))
        (let* ((seat (cdr entry)) (slot (plist-get seat :slot))
               (room (gethash (plist-get seat :room) room-index))
               (pod (/ slot 4)) (local (% slot 4))
               (node (copy-tree record)))
          (setq node (plist-put node :room (plist-get room :id)))
          (setq node (plist-put node :slot slot))
          (setq node (plist-put node :x (+ (plist-get room :x) 24 (* (% pod 2) 204) (* (% local 2) 94))))
          (setq node (plist-put node :y (+ (plist-get room :y) 62 (* (/ pod 2) 186) (* (/ local 2) 88))))
          (setq node (plist-put node :width 90))
          (setq node (plist-put node :height 80))
          (push node nodes)
          (push node (gethash (plist-get room :id) nodes-by-room)))))
    (dolist (room (plist-get state :rooms))
      (when-let* ((members (gethash (plist-get room :id) nodes-by-room)))
        (let ((copy (copy-tree room)))
          (setq copy (plist-put copy :nodes (nreverse members)))
          (push copy visible)
          (setq width (max width (+ (plist-get room :x) (plist-get room :width) 16))
                height (max height (+ (plist-get room :y) (plist-get room :height) 16))))))
    (list :rooms (nreverse visible) :nodes (nreverse nodes) :width width :height height)))

(defun lispm-office-layout-read (file)
  "Read validated seating data from FILE, or return nil if absent.
Malformed or unsupported data signals an error; callers must not
replace that file with an empty layout.  No Lisp forms are evaluated."
  (when (file-exists-p file)
    (condition-case err
        (progn
          (when (> (file-attribute-size (file-attributes file)) lispm-office-layout--file-limit)
            (error "Office seating file exceeds the size limit"))
          (with-temp-buffer
            (insert-file-contents file)
            (let* ((read-circle nil)
                   (state (read (current-buffer))))
              (skip-chars-forward " \t\r\n")
              (while (eq (char-after) ?\;)
                (forward-line 1)
                (skip-chars-forward " \t\r\n"))
              (unless (eobp) (error "Trailing data in Office seating file"))
              (lispm-office-layout--validate state))))
      (error (error "Cannot read Office seats from %s: %s" file (error-message-string err))))))

(defun lispm-office-layout-write (state file)
  "Atomically write validated STATE to FILE, preserving any corrupt file.
If FILE already exists, validate it before replacing it.  The temporary
file is private and is removed even if writing or renaming fails."
  (lispm-office-layout--validate state)
  (lispm-office-layout-read file)
  (let* ((file (expand-file-name file))
         (directory (file-name-directory file))
         (temporary nil))
    (make-directory directory t)
    (unwind-protect
        (progn
          (setq temporary (make-temp-file (expand-file-name ".office-seats-" directory)))
          (let ((coding-system-for-write 'utf-8-unix)
                (print-length nil) (print-level nil) (print-circle nil))
            (with-temp-file temporary
              (insert ";; LispM Office seats.  Data only; versioned and validated.\n")
              (prin1 state (current-buffer))
              (insert "\n")
              (when (> (string-bytes (buffer-string)) lispm-office-layout--file-limit)
                (error "Office seating data exceeds the size limit"))))
          (rename-file temporary file t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary)) (delete-file temporary))))
  state)

(provide 'lispm-office-layout)
;;; lispm-office-layout.el ends here
