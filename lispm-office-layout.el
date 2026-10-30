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
(defconst lispm-office-layout-wall-height 88
  "World-coordinate height reserved for the room's back wall.")
(defconst lispm-office-layout-wall-thickness 12
  "World-coordinate thickness of the side and front walls.")
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

(defun lispm-office-layout--overlap-p (a b)
  "Whether rectangles A and B have overlapping interiors."
  (and (< (plist-get a :x) (+ (plist-get b :x) (plist-get b :width)))
       (< (plist-get b :x) (+ (plist-get a :x) (plist-get a :width)))
       (< (plist-get a :y) (+ (plist-get b :y) (plist-get b :height)))
       (< (plist-get b :y) (+ (plist-get a :y) (plist-get a :height)))))

(defun lispm-office-layout--decorate-room (room &optional service)
  "Add furniture and circulation geometry to a copied ROOM.
SERVICE, when supplied, is a bounded coffee-area rectangle.  All
anchors are (X . Y) world coordinates; walk anchors locate feet."
  (let* ((x (plist-get room :x)) (y (plist-get room :y))
         (width (plist-get room :width)) (height (plist-get room :height))
         (floor-y (+ y lispm-office-layout-wall-height))
         (floor-bottom (- (+ y height) lispm-office-layout-wall-thickness))
         (nodes (plist-get room :nodes))
         (spine (if nodes (max (+ x lispm-office-layout-wall-thickness 6) (- (apply #'min (mapcar (lambda (node) (plist-get node :x)) nodes)) 20))
                  (+ x 20)))
         (groups (make-hash-table :test #'eql))
         (walk-gap (if (plist-get room :responsive) 12 4))
         (coffee (or service (list :kind 'coffee :x (+ x width -112) :y (+ floor-y 4)
                                   :width 88 :height 18)))
         (aisles nil) (pods nil))
    (dolist (node nodes)
      ;; Retain the shared node object held by the plan and its room.
      (dolist (property '(:desk-anchor :walk-anchor :idle-anchor))
        (unless (plist-member node property) (nconc node (list property nil))))
      (let* ((nx (plist-get node :x)) (ny (plist-get node :y))
             (walk (cons (+ nx (/ (plist-get node :width) 2.0))
                         (+ ny (plist-get node :height) walk-gap))))
        (setf (plist-get node :desk-anchor) (cons nx ny)
              (plist-get node :walk-anchor) walk
              (plist-get node :idle-anchor)
              (cons (+ (plist-get coffee :x) 12
                       (* (or (plist-get node :display-seat) (% (or (plist-get node :slot) 0) 4)) 16))
                    (+ (plist-get coffee :y) (plist-get coffee :height) -4)))
        (push node (gethash (or (plist-get node :display-pod) (/ (or (plist-get node :slot) 0) 4)) groups))
        (let ((line (seq-find (lambda (aisle) (= (plist-get aisle :y) (- (cdr walk) 4))) aisles)))
          (if line
              (setf (plist-get line :width) (max (plist-get line :width) (- (car walk) spine)))
            (push (list :x spine :y (- (cdr walk) 4) :width (- (car walk) spine)
                        :height (max 1 (min 8 (- floor-bottom (- (cdr walk) 4))))) aisles)))))
    (maphash
     (lambda (id members)
       (let ((left (apply #'min (mapcar (lambda (node) (plist-get node :x)) members)))
             (top (apply #'min (mapcar (lambda (node) (plist-get node :y)) members)))
             (right (apply #'max (mapcar (lambda (node) (+ (plist-get node :x) (plist-get node :width))) members)))
             (bottom (apply #'max (mapcar (lambda (node) (+ (plist-get node :y) (plist-get node :height))) members))))
         (push (list :id id :x (- left 4) :y (- top 4) :width (+ 8 (- right left))
                     :height (+ 8 (- bottom top)) :keys (mapcar (lambda (node) (plist-get node :key)) members)) pods)))
     groups)
    (setf (plist-get room :pods) (sort pods (lambda (a b) (< (plist-get a :id) (plist-get b :id))))
          (plist-get room :circulation-x) spine
          (plist-get room :door-anchor) (cons (+ x lispm-office-layout-wall-thickness) (+ y height -20))
          (plist-get room :aisles)
          (cons (list :x (- spine 6) :y (+ floor-y 4) :width 12
                      :height (max 1 (- floor-bottom floor-y 4))) aisles)
          (plist-get room :fixtures) (list coffee))
    (dolist (plant (list (list :kind 'plant :x (+ x width -42) :y (+ floor-y 4) :width 18 :height 16)
                        (list :kind 'plant :x (+ x width -42) :y (+ y height -46) :width 18 :height 22)))
      (when (and (>= (plist-get plant :x) (+ x lispm-office-layout-wall-thickness))
                 (>= (plist-get plant :y) floor-y)
                 (not (seq-some (lambda (obstacle) (lispm-office-layout--overlap-p plant obstacle))
                                (append nodes (plist-get room :fixtures) (plist-get room :aisles)))))
        (setf (plist-get room :fixtures) (append (plist-get room :fixtures) (list plant)))))
    room))

(defun lispm-office-layout-fit-room (room width height)
  "Pack a copy of ROOM into WIDTH by HEIGHT pixels without stretching desks.
Return (:room ROOM :scale SCALE).  Compact desk pods share circulation
lanes and a coffee area beside or below them.  The floor fills the pane;
short panes scroll at the minimum readable scale of 0.72.  Visible
agents form chunks of four in saved slot order, without retaining empty
historical reservations in the display.  Saved slots are never changed."
  (dolist (dimension (list width height))
    (unless (and (numberp dimension) (> dimension 0) (< dimension 1.0e6))
      (signal 'wrong-type-argument (list 'positive-finite-number dimension))))
  (let* ((room (copy-tree room))
         (nodes (cl-stable-sort (plist-get room :nodes)
                               (lambda (a b) (< (or (plist-get a :slot) 0) (or (plist-get b :slot) 0)))))
         (groups nil) (largest 1)
         (dw (apply #'max 90 (mapcar (lambda (node) (plist-get node :width)) nodes)))
         (dh (apply #'max 80 (mapcar (lambda (node) (plist-get node :height)) nodes)))
         (pixels-wide (max (float width) (* 0.72 (+ dw 64))))
         (best nil) (score -1.0))
    (cl-loop for node in nodes for index from 0 do
             (dolist (property '(:display-pod :display-seat))
               (unless (plist-member node property) (nconc node (list property nil))))
             (setf (plist-get node :display-pod) (/ index 4)
                   (plist-get node :display-seat) (% index 4))
             (let* ((pod (/ index 4)) (group (assq pod groups)))
               (if group (setcdr group (append (cdr group) (list node)))
                 (setq groups (append groups (list (list pod node)))))))
    (unless groups (setq groups '((0))))
    (setq largest (apply #'max 1 (mapcar (lambda (group) (length (cdr group))) groups)))
    ;; Enumerate only compact furniture arrangements.  Spare floor enlarges
    ;; the circulation/decor area, never the distance between paired desks.
    ;; A single pod may flatten in a short pane.  Multiple pods keep paired
    ;; desks so wide rows cannot consume every safe collaboration standing spot.
    (dotimes (seats (if (= (length groups) 1) largest (min largest 2)))
      (dotimes (columns (length groups))
        (dolist (service '(right bottom))
          (let* ((seat-cols (1+ seats)) (pod-cols (1+ columns))
                 (pod-rows (ceiling (length groups) pod-cols))
                 (pw (+ (* seat-cols dw) (* (1- seat-cols) 8)))
                 (ph (+ (* (ceiling largest seat-cols) dh) (* (1- (ceiling largest seat-cols)) 40)))
                 (workw (+ (* pod-cols pw) (* (1- pod-cols) 40)))
                 (workh (+ (* pod-rows ph) (* (1- pod-rows) 40)))
                 (minw (+ 64 workw (if (eq service 'right) 124 0)))
                 (minh (+ lispm-office-layout-wall-height 56 workh (if (eq service 'bottom) 92 0)))
                 (fit (min (/ pixels-wide minw) (/ (float height) minh)))
                 ;; At equal scale prefer paired desks and a side service area.
                 (quality (+ (min 1.5 fit) (if (= seat-cols 2) 0.006 0)
                             (if (eq service 'right) 0.003 0))))
            (when (and (<= (* minw 0.72) (+ pixels-wide 0.001)) (> quality score))
              (setq score quality best (list seat-cols pod-cols pw ph workw workh minw minh service fit)))))))
    (pcase-let* ((`(,seat-cols ,pod-cols ,pw ,ph ,workw ,workh ,minw ,minh ,service ,fit) best)
                 (scale (max 0.72 (min 1.5 fit)))
                 (worldw (max minw (/ pixels-wide scale)))
                 (worldh (max minh (/ (float height) scale)))
                 (x (plist-get room :x)) (y (plist-get room :y))
                 (left (+ x 40 (/ (- worldw 64 workw (if (eq service 'right) 124 0)) 2)))
                 (top (+ y lispm-office-layout-wall-height 24
                         (/ (- worldh lispm-office-layout-wall-height 56 workh
                               (if (eq service 'bottom) 92 0)) 2)))
                 (coffee (if (eq service 'right)
                             (list :kind 'coffee :x (+ x worldw -124)
                                   :y (+ y lispm-office-layout-wall-height 24)
                                   :width 100 :height (min 100 (- worldh lispm-office-layout-wall-height 56)))
                           (list :kind 'coffee :x (+ x 40) :y (+ y worldh -100)
                                 :width (min 120 (- worldw 64)) :height 68))))
      (cl-loop for group in groups for index from 0 do
               (cl-loop for node in (cdr group) for seat from 0 do
                        (setf (plist-get node :x) (+ left (* (% index pod-cols) (+ pw 40)) (* (% seat seat-cols) (+ dw 8)))
                              (plist-get node :y) (+ top (* (/ index pod-cols) (+ ph 40)) (* (/ seat seat-cols) (+ dh 40))))))
      (setf (plist-get room :width) worldw (plist-get room :height) worldh
            (plist-get room :nodes) nodes (plist-get room :responsive) t)
      (list :room (lispm-office-layout--decorate-room room coffee) :scale scale))))

(defun lispm-office-layout--visit-points (room peer)
  "Return safe standing feetpoints beside PEER in ROOM, nearest first.
The visitor's full 55 by 65 footprint must leave desks, furniture and
the room border clear.  A tightly packed room may have no such point."
  (let* ((nodes (plist-get room :nodes))
         (obstacles (append nodes (plist-get room :fixtures)))
         (px (plist-get peer :x)) (py (plist-get peer :y))
         (right (+ px (plist-get peer :width)))
         (bottom (+ py (plist-get peer :height)))
         (walk (plist-get peer :walk-anchor))
         (left-edge (+ (plist-get room :x) lispm-office-layout-wall-thickness))
         (top-edge (+ (plist-get room :y) lispm-office-layout-wall-height))
         (right-edge (- (+ (plist-get room :x) (plist-get room :width)) lispm-office-layout-wall-thickness))
         (bottom-edge (- (+ (plist-get room :y) (plist-get room :height)) lispm-office-layout-wall-thickness))
         (xs (list (- px 41) (+ right 22))) points)
    (dolist (node nodes)
      (push (- (plist-get node :x) 41) xs)
      (push (+ (plist-get node :x) (plist-get node :width) 22) xs))
    (dolist (x (delete-dups xs))
      (dolist (y (list (cdr walk) (+ py 62) (+ bottom 66)))
        (let ((body (list :x (- x 18) :y (- y 62) :width 55 :height 65)))
          (when (and (or (<= (+ x 37) (- px 4)) (>= (- x 18) (+ right 4)))
                     (>= (- x 18) left-edge) (<= (+ x 37) right-edge)
                     (>= (- y 62) top-edge) (<= (+ y 3) bottom-edge)
                     (not (seq-some (lambda (obstacle) (lispm-office-layout--overlap-p body obstacle)) obstacles)))
            (push (cons x y) points)))))
    (sort points (lambda (a b)
                   (< (+ (expt (- (car a) (car walk)) 2) (expt (- (cdr a) (cdr walk)) 2))
                      (+ (expt (- (car b) (car walk)) 2) (expt (- (cdr b) (cdr walk)) 2)))))))

(defun lispm-office-layout--clear-walk-p (path nodes)
  "Whether orthogonal PATH avoids the desk rectangles in NODES."
  (not
   (cl-loop for (p q) on path while q thereis
            (seq-some
             (lambda (node)
               (let ((left (plist-get node :x)) (top (plist-get node :y))
                     (right (+ (plist-get node :x) (plist-get node :width)))
                     (bottom (+ (plist-get node :y) (plist-get node :height))))
                 (if (= (car p) (car q))
                     (and (< left (car p) right) (< (min (cdr p) (cdr q)) bottom)
                          (> (max (cdr p) (cdr q)) top))
                   (and (< top (cdr p) bottom) (< (min (car p) (car q)) right)
                        (> (max (car p) (car q)) left))))) nodes))))

(defun lispm-office-layout-walk-path (plan from-key to-key)
  "Return orthogonal feet waypoints between FROM-KEY and TO-KEY in PLAN.
Routes use room aisles and stop beside the peer without covering its
desk or name.  Missing endpoints, no safe standing space, or a route
that would cross a desk return nil.  No layout or agent data changes."
  (let* ((nodes (plist-get plan :nodes))
         (from (seq-find (lambda (node) (equal from-key (plist-get node :key))) nodes))
         (to (seq-find (lambda (node) (equal to-key (plist-get node :key))) nodes))
         (rooms (plist-get plan :rooms))
         (a (seq-find (lambda (room) (eql (plist-get from :room) (plist-get room :id))) rooms))
         (b (seq-find (lambda (room) (eql (plist-get to :room) (plist-get room :id))) rooms))
         (start (plist-get from :walk-anchor)) (approach (plist-get to :walk-anchor)))
    (when (and from to a b start approach (not (equal from-key to-key)))
      (let* ((ax (plist-get a :circulation-x)) (bx (plist-get b :circulation-x))
             (ad (plist-get a :door-anchor)) (bd (plist-get b :door-anchor))
             (outside (+ 12 (apply #'max (mapcar (lambda (room) (+ (plist-get room :y) (plist-get room :height))) rooms))))
             (base (if (eq a b) (list start (cons ax (cdr start)) (cons ax (cdr approach)))
                     (list start (cons ax (cdr start)) (cons ax (cdr ad)) ad
                           (cons (- (plist-get a :x) 12) (cdr ad))
                           (cons (- (plist-get a :x) 12) outside)
                           (cons (- (plist-get b :x) 12) outside)
                           (cons (- (plist-get b :x) 12) (cdr bd)) bd
                           (cons bx (cdr bd)) (cons bx (cdr approach))))))
        (seq-some
         (lambda (end)
           (let (clean)
             (dolist (point (append base (list (cons (car end) (cdr approach)) end)))
               (unless (equal point (car clean)) (push point clean)))
             (setq clean (nreverse clean))
             (when (lispm-office-layout--clear-walk-p clean nodes) clean)))
         (lispm-office-layout--visit-points b to))))))

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
        (display-nodes (make-hash-table :test #'equal))
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
          (setq node (plist-put node :y (+ (plist-get room :y) lispm-office-layout-wall-height 24
                                           (* (/ pod 2) 164) (* (/ local 2) 82))))
          (setq node (plist-put node :width 90))
          (setq node (plist-put node :height 80))
          (push node nodes)
          (push node (gethash (plist-get room :id) nodes-by-room)))))
    (dolist (room (plist-get state :rooms))
      (when-let* ((members (gethash (plist-get room :id) nodes-by-room)))
        (let ((copy (copy-tree room)))
          (setq copy (plist-put copy :nodes (nreverse members)))
          (setq copy (lispm-office-layout--decorate-room copy))
          ;; Sparse overview rooms use the same furnished composition as the
          ;; focused view when it fits their established floor.  Dense rooms
          ;; retain their existing seat geometry; saved reservations never move.
          (when (<= (length members) 8)
            (let ((fit (lispm-office-layout-fit-room copy (* 1.5 (plist-get room :width))
                                                      (* 1.5 (plist-get room :height)))))
              (when (= (plist-get fit :scale) 1.5)
                (setq copy (plist-get fit :room)))))
          (dolist (node (plist-get copy :nodes))
            (puthash (plist-get node :key) node display-nodes))
          (push copy visible)
          (setq width (max width (+ (plist-get room :x) (plist-get room :width) 16))
                height (max height (+ (plist-get room :y) (plist-get room :height) 16))))))
    (list :rooms (nreverse visible)
          :nodes (mapcar (lambda (node) (gethash (plist-get node :key) display-nodes)) (nreverse nodes))
          :width width :height height)))

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
