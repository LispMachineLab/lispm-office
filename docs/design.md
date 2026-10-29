# LispM Office

Office is a LispM Agent plugin that switches a conversation between Conversation
and Work views in the same window. Work starts with the current conversation and
its explicit collaborators. One desk represents one live conversation. LispM UI
supplies drawing and controls; LispM Agent owns conversations, data and actions.

## Plugin and current work

Load `lispm-office-plugin` and enable `lispm-office-plugin-mode` to add a visible
Conversation / Work toggle to Agent chat and terminal headers. The controls use
LispM UI's bevel buttons and mark the active view as pressed. The local `C-c O`
binding performs the same toggle. Existing header content is preserved and
restored when the plugin is disabled.

Work replaces the conversation in its existing window. It retains the source
buffer and its draft, point and scroll position; returning to Conversation, or
pressing `q` in Work, restores them. This does not change the agent's canonical
chat or transcript buffer, restart it or end its session.

Work starts in Session scope. It includes the current stable identity and its
recursive descendants, then follows active wait links in either direction and
shared request ids. Project membership alone adds no conversations. Parent
pointers are followed only downward from the original session: reaching a peer
through an active request does not bring that peer's unrelated children into the
group. Traversal is cycle-safe and uses only the cached roster.

The Session, Project and All projects controls explicitly select scope. Project
shows the source session's project; All projects shows the whole live roster.
Session returns to the source and its collaborators. A source without a known
identity has an empty pending Session view until its key arrives, without falling
back to its project or another agent.

While Work remains visible, selecting another Agent in a second window follows
that session by default and returns to Session scope. Switching between chat and
transcript views of the same stable identity preserves the chosen scope and desk.
An existing Inspector follows the selection without changing its Work, Mailbox or
Character tab or stealing focus. Manual desk selections survive updates while
they remain in scope; when a request settles and the selected collaborator leaves
scope, selection and Inspector return to the source. Set
`lispm-office-follow-current-agent` to `nil` to disable following.

The optional Inspector opens in a side window owned by Work. Open Chat prefers
an existing native chat view; terminal agents open their canonical buffer.
Navigation uses LispM Agent's host display functions and never resumes a retired
conversation. Entry from outside a conversation uses
`lispm-agents-main-window-function` to locate the host's main window.

Leaving Work closes its Inspector and releases its subscriptions. Disabling or
unloading the plugin restores source conversations, headers and local bindings,
and removes its observers. It never stops or closes source conversations.

## Identity and layout

The stable identity is `(KIND SESSION-ID)`. The full cheap roster is retained for
global seat reservations; visible records and geometry are derived separately
from the chosen scope. Characters without an open conversation are not included.
Project and All projects group rooms by project root, including Home for the home
directory. An unidentified terminal can appear in those explicit overviews'
Starting line; Session scope remains empty until its source identity is known.

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
Desks reflow to fill the pane; avatars and text scale uniformly. When a pane is
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
Counts, waiting strip, selection, actions and animation use only visible records.
The waiting order comes from `lispm-agents-waiting-buffers`, filtered to scope.
Source changes, roster refreshes and settled requests recompute that scope
without fetching work details. Cached message animations are discarded when
either endpoint leaves the visible group.

Only an opened, visible Inspector calls `lispm-agents-roster-details`, for its
selected key. Hidden inspectors defer reads. Work shows pending and recent calls
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
projection. Scope controls and drawing controls occupy separate toolbar rows;
their actual pixel height is measured before fitting the remaining buffer area.
Desk view starts at scale 0.72, Floor
at 0.45, and Map below that; image dimensions are capped at 4096 pixels and the
effective scale controls both rendering and interaction. A map selection enters
its room. Text mode uses the same records, stable identity and commands.

Workers use 16 distinct 16 × 16 pixel sprites with varied hairstyles,
accessories, skin, hair and clothing colors. Each newly seen stable session key
receives an index from a shuffled deck; the first 16 identities receive distinct
portraits. An in-memory identity map keeps that assignment across redraws,
renaming, scope changes, roster refreshes and theme changes. It is separate from
the image cache and is not saved to disk, so restarting Emacs randomizes the
assignments again. At Desk zoom, a configured avatar takes precedence over the
sprite's head.

The floor never reads transcripts. Cached avatar data avoids filesystem reads
on animation ticks. There is no roster polling or global post-command hook.
One 250 ms animation timer runs only for visible working desks or actual message
events with visible endpoints. Map, text, hidden and idle views stop it. Events
are sequence-deduplicated, expire after one second and have a bounded queue.
The palette is initialized through LispM UI's public API. Palette changes
invalidate drawing resources without changing portrait assignments. The room and
controls use LispM UI's palette; sprite colors distinguish individual workers.

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
