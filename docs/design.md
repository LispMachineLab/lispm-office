# LispM Office

Office is a LispM Agent plugin that switches a conversation between Conversation
and Work views in the same window. Work starts with the current conversation and
its explicit collaborators. One desk represents one live conversation. LispM UI
supplies drawing and controls; LispM Agent owns conversations, data and actions.

## Plugin and current work

Load `lispm-office-plugin` and enable `lispm-office-plugin-mode` to add visible
Conversation / Work tabs to Agent chat and terminal headers. Desktop supplies
its native Mac OS 9 pane tabs; without Desktop the same controls use Emacs tab
faces. The tabs are adjacent, and the active tab is in front. The local `C-c O`
binding performs the same toggle. Existing header content is preserved and
restored when the plugin is disabled.

Work replaces the conversation in its existing window. It retains the source
buffer and its draft, point and scroll position; returning to Conversation, or
pressing `q` in Work, restores them. This does not change the agent's canonical
chat or transcript buffer, restart it or end its session.

Opening a folder in the Desktop Agents sidebar enters a pinned Project view in
the host's main window. The triangle alone controls folding. Folder activation
calls the optional `lispm-desktop-agent-list-open-project-functions` hook; Office
registers `lispm-office-open-project` while enabled and removes it on disable.
Desktop falls back to its native directory Agent list without Office; no file
browser is involved. Desktop is not a required dependency. The entrypoint also
works directly with the current working directory, without a conversation or a
Desktop sidebar. This entry has no Conversation tab and never infers a conversation
from the first desk. `q` restores only the original main-pane buffer.

The directory is explicit and never inferred from the previously selected agent.
Folder views initially include all active sessions, including idle and done
agents that remain available, excluding explicitly ended sessions. Working only
optionally narrows this to working, blocked or error states and queued input.
Unknown activity by itself does not count as work. Roster updates
reapply the filter without querying details. Focusing another conversation does
not retarget this pinned view; changing folders preserves the original return
buffer and draft. A folder with no active work stays empty.

Work opened from a conversation starts in Session scope. It includes the current
stable identity and its recursive descendants, then follows active wait links in
either direction and shared request ids. Project membership alone adds no conversations. Parent
pointers are followed only downward from the original session: reaching a peer
through an active request does not bring that peer's unrelated children into the
group. Traversal is cycle-safe and uses only the cached roster.

A shared LispM UI pop-up menu explicitly selects Session, Project or All projects.
The same compact menu contains the optional Working only filter, room selection,
text view, refresh and help. There are no inline counts, waiting strip, selected
agent summary, directory diagnostics or zoom buttons; empty-state captions are
short and centered. The floor fits the available area by default. Project
shows the source session's project; All projects shows the whole live roster.
Session returns to the source and its collaborators. A source without a known
identity has an empty pending Session view until its key arrives, without falling
back to its project or another agent.

While a conversation's Work view remains visible, selecting another Agent in a
second window follows that session by default and returns to Session scope.
Switching between chat and transcript views of the same stable identity preserves the chosen scope and desk.
An open details page follows the selection without changing its Work, Mailbox or
Character tab or stealing focus. Manual desk selections survive updates while
they remain in scope; when a request settles and the selected collaborator leaves
scope, selection and details return to the source. Set
`lispm-office-follow-current-agent` to `nil` to disable following.

Clicking a desk replaces the floor with details in the same Work buffer and
window. It retains Office mode, stores the floor's point and scroll position,
and pauses floor animation. Back restores that view; leaving Work clears the
details state. A centered portrait, name and status head the page, followed by
contextual actions and native Work, Mailbox and Character tabs. Empty sections
are omitted. Open Chat prefers
an existing native chat view; terminal agents open their canonical buffer.
Navigation uses LispM Agent's host display functions and never resumes a retired
conversation. Entry from outside a conversation uses
`lispm-agents-main-window-function` to locate the host's main window.

Leaving Work clears its details and releases its subscriptions. Disabling or
unloading the plugin restores source conversations, headers and local bindings,
and releases its roster observers. Legacy Inspector panes carry ownership markers;
cleanup removes them without restoring an obsolete buffer from window history.
Workspace cleanup removes saved panes belonging to closed legacy Inspectors
and restores the original source of a closed Work view. Return contexts stay in
this Emacs session's window configurations, without being serialized to disk.
Source conversations keep running.

## Identity and layout

The stable identity is `(KIND SESSION-ID)`. The full cheap roster is retained for
global seat reservations; visible records and geometry are derived separately
from the chosen scope. Characters without an open conversation are not included.
Project and All projects group rooms by project root, including Home for the home
directory. An unidentified terminal remains pending without a desk until its identity is
known; Session scope stays empty until its source identity is known.

The persistent seating model uses 450 × 454 rooms, each with four pods of four
desks. New children prefer their parent's pod, then its room. Full projects gain
annexes. Reserved room cells append in a fixed three-column grid; existing seat
identities survive roster reordering and status changes. A changed root moves
only that conversation. Missing agents keep reservations until Compact. Compact
uses the full live roster, so it cannot remove another scope's live desks.

Session scope places its collaborators in one transient display room, even when
their actual project roots differ. It preserves each record's identity and root
and never rewrites saved seats. Fit derives a responsive scene from that room or
the selected project room and the window's measured available width and height.
Compact desk pods reflow within the pane, leaving shared aisles and a coffee area
beside or below them; spare space enlarges those shared areas. Avatars and text
scale uniformly. When a pane is
too small for readable desks, it scrolls instead of collapsing the focused room
into an inaccessible map tile.

Seats are saved as validated, versioned Lisp data under `lispm-directory`.
Reading never evaluates forms. Writes use a private temporary file and atomic
rename; malformed existing files are never replaced. Failed saves remain pending
for a manual refresh or close to retry.

## Data and actions

`lispm-agents-roster` supplies cheap snapshots. Enabling the plugin alone creates
no roster observer. Office subscribes to `lispm-agents-roster-change-functions`
while a live Work view is open. Leaving the last Work view removes that observer.
Preview buffers do not subscribe.
Selection, actions, inspection and animation use only visible records.
The waiting order comes from `lispm-agents-waiting-buffers`, filtered to scope.
Source changes, roster refreshes and settled requests recompute that scope
without fetching work details. Cached message animations are discarded when
either endpoint leaves the visible group.

Only an opened, visible details page calls `lispm-agents-roster-details`, for its
selected key. Hidden pages defer reads; resizing redraws a cached model without
fetching details or replacing its permission-turn snapshot. Work shows pending and recent calls
and files touched this turn; Mailbox shows handling and queued entries with sender,
reply-to and time, plus wait relations. Character reads the selected character’s
identity, soul, model and recent diary entries on demand.

Operations resolve the live identity again. Native conversations expose send,
approve, deny and abort; terminal capabilities determine whether sending is
available, while unsupported operations remain absent. Questions and authentication
requests are handled in the conversation itself. Approve All shows the selected
agent’s pending calls and complete arguments before consent, then revalidates
agent, turn, call identity and input. It never spans several agents. Aborting
explicitly discloses that queued inputs are cleared.

## Rendering and resource use

SVG, hit testing, keyboard movement and animation share the displayed scene and
projection. A single compact view menu occupies one toolbar row; its actual
pixel height is measured before fitting the remaining buffer area. Conversation
tabs live in the header; a directory view omits that header.
Desk view starts at scale 0.72, Floor
at 0.45, and Map below that; image dimensions are capped at 4096 pixels and the
effective scale controls both rendering and interaction. A map selection enters
its room. Text mode uses the same records, stable identity and commands.

Eight room interiors combine wood, parquet, tile, tatami or carpet patterns with
wallpaper, dividing walls, doors and furnishings. A shuffled deck assigns each
room a style retained for the Emacs session, independently of the interface's
accent color. Raised back walls have cornices, wainscot, skirting and floor-contact
shadows. Windows, clocks, framed art, noticeboards and shelves sit on the wall;
floor patterns and furniture begin below it. Rooms include coffee counters and
plants where their layout provides space. Room labels are centered signs within
the wallpaper.

Workers use 16 distinct 16 × 16 pixel sprites with varied hairstyles,
accessories, skin, hair and clothing colors. Each newly seen stable session key
receives an index from a shuffled deck; the first 16 identities receive distinct
portraits. An in-memory identity map keeps that assignment across redraws,
renaming, scope changes, roster refreshes and theme changes. It is separate from
the image cache and is not saved to disk, so restarting Emacs randomizes the
assignments again. At Desk zoom, a configured avatar takes precedence over the
sprite's head.

Roster state selects each worker's pose: working types, idle holds coffee, and
blocked or error raises a hand. An explicit `:waits-on` link to a visible peer
can produce a walking visitor when the layout supplies a safe route. The worker
leaves its chair, follows the aisles and stands beside the peer, keeping both
desks and their labels clear. This is a representation of the existing wait
relationship; shared directories alone do not create visits. The visible worker
retains its source agent's identity for inspection.

The floor never reads transcripts. Cached avatar data avoids filesystem reads
on animation ticks. There is no roster polling or global post-command hook.
A one-shot animation timer runs only for visible working desks, explicit waits
between visible peers, or actual message events with visible endpoints. It waits
at least 120 ms after a frame finishes and yields to pending input, so expensive
frames cannot build up a timer backlog. The 32-phase cycle supports typing and
walking poses without reading new agent data. Steady poses reuse at most six
images per scene; ticks replace the floor image without rebuilding its controls
or layout. Full scene redraws invalidate those images. Flights and visits bypass
the cache because elapsed time moves their positions and hit regions. Idle poses
alone start no timer.
Map, text and hidden views stop animation. Events
are sequence-deduplicated, expire after one second and have a bounded queue.
The palette is initialized through LispM UI's public API. Palette changes
invalidate drawing resources without changing portrait or interior assignments.
Controls use LispM UI's palette; room interiors and sprite colors keep their
individual palettes.

## Dependency and distribution

Live data requires the roster API introduced by the merged
[LispM Agent PR #135](https://github.com/LispMachineLab/lispm-agent/pull/135).
Tests pin a known API commit; no released dependency version is assumed. The
runtime check explains a missing API. An isolated simulated preview is available
for development and does not subscribe to agents or perform actions.

The plugin declares its commands through LispM Kit and is installed alongside
LispM Agent. When Desktop is present, its public conversation-buffer marker keeps
Work in the session column. There is no runtime Desktop dependency or native OS
API.
