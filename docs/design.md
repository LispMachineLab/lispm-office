# LispM Office

Office is a LispM Agent plugin that switches a conversation between Conversation
and Work views in the same window. One desk represents one live conversation.
LispM UI supplies drawing
and controls; LispM Agent owns the conversations, data and actions.

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

Work initially selects the current Agent's stable key and room. While it remains
visible, selecting another Agent in a second window follows that conversation by
default. An existing Inspector follows the key without changing its Work, Mailbox
or Character tab or stealing focus. Manual desk selections survive updates from
the same source. Set `lispm-office-follow-current-agent` to `nil` to disable
following. A source without a known identity shows a waiting state until the
roster supplies its key; it does not automatically select an unrelated agent.

The optional Inspector opens in a side window owned by Work. Open Chat prefers
an existing native chat view; terminal agents open their canonical buffer.
Navigation uses LispM Agent's host display functions and never resumes a retired
conversation. Entry from outside a conversation uses
`lispm-agents-main-window-function` to locate the host's main window.

Leaving Work closes its Inspector and releases its subscriptions. Disabling or
unloading the plugin restores source conversations, headers and local bindings,
and removes its observers. It never stops or closes source conversations.

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

`lispm-agents-roster` supplies cheap snapshots. Enabling the plugin alone creates
no roster observer. Office subscribes to `lispm-agents-roster-change-functions`
while a live Work view is open. Leaving the last Work view removes that observer.
Preview buffers do not subscribe.
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
The palette is initialized through LispM UI's public API. Palette changes
invalidate drawing resources. All colours and controls come from LispM UI.

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
