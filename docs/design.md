# LispM Office

One desk represents one live conversation. Office is a standalone Emacs package,
using LispM UI for drawing and controls and LispM Agent for data and actions.

## Identity and layout

The stable identity is `(KIND SESSION-ID)`. Rooms belong to project roots; Home
contains conversations rooted at the home directory. Characters without an open
conversation are not included. A terminal whose session id is not known appears
in the Starting line until its real identity arrives.

Each 450 × 454 room holds four pods of four desks. New children prefer their
parent’s pod, then its room. Full projects gain annexes. Room cells append in a
fixed three-column grid; existing desks stay put even when the roster order or
status changes. A changed root moves only that conversation. Missing agents keep
reserved seats until the explicit Compact command.

Seats are saved as validated, versioned Lisp data under `lispm-directory`.
Reading never evaluates forms. Writes use a private temporary file and atomic
rename; malformed existing files are never replaced. Failed saves remain pending
for a manual refresh or close to retry.

## Data and actions

`lispm-agents-roster` supplies cheap snapshots. The app subscribes to
`lispm-agents-roster-change-functions` while a live Office buffer exists. Closing
the last live Office removes that observer. Preview buffers do not subscribe.
The waiting order comes from `lispm-agents-waiting-buffers`.

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

SVG and hit testing share one projection. Desk view starts at scale 0.72, Floor
at 0.45, and Map below that; image dimensions are capped at 4096 pixels and the
effective scale controls both rendering and interaction. A map selection enters
its room. Text mode uses the same records, stable identity and commands.

The floor never reads transcripts. Cached avatar data avoids filesystem reads
on animation ticks. There is no roster polling or global post-command hook.
One 250 ms animation timer runs only for visible working desks or actual message
events with visible endpoints. Map, text, hidden and idle views stop it. Events
are sequence-deduplicated, expire after one second and have a bounded queue.
Palette changes invalidate drawing resources. All colours come from LispM UI.

## Dependency and distribution

Live data currently requires the roster API introduced by
[LispM Agent PR #135](https://github.com/LispMachineLab/lispm-agent/pull/135).
Tests pin a known API commit until the dependency is released. The app’s runtime
check explains a missing API and offers the isolated preview command.

The package declares its commands through LispM Kit. A future App Store catalog
entry should pin the reviewed application commit after its roster dependency is
available; catalog metadata and any desktop-specific skin belong to their owning
repositories. This package has no desktop dependency and no native OS API.
