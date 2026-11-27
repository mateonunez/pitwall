# Context

The words pitwall uses, and only those.

- **Lane**: one tmux pane that runs one agent, usually in one worktree. A window can hold several lanes; it shows the most urgent one. A lane is named after its window, plus `.N` when the window has more than one pane.
- **State**: what a lane is doing now. Exactly one of:
  - `working`: the agent is thinking or running a tool, or a subagent it started in the background still is (a background shell does not count).
  - `asking`: the agent waits for you (permission, a question, a choice).
  - `done`: the agent finished a turn while you were in another window. It stays `done` until you visit the lane: the unread mark.
  - `idle`: finished and already seen, interrupted, or never started.
  - `gone`: the agent exited; the window has a plain shell.
- **Question**: what an asking lane asks, read off its screen when it starts asking (`Allow pnpm release?`) with its numbered answers; dropped once it moves on.
- **Urgent**: an `asking` lane that has waited longer than `@pitwall-urgent-after` (ten minutes). Not a state of its own: a mark that clears when the lane moves on.
- **Workspace**: a tmux session, holding the windows of one project or one kind of work. Moving a lane between workspaces moves its window; its agents keep running.
- **Search**: what you type in the dashboard; every word must appear in a lane, a workspace, an action, a command or a plugin row included in the main search. Words that start an action's name (`rename`, `diff`, `move`) and words that find a lane suggest that action on that lane. With a leading `/`, the text searched in the lanes' recent output.
- **Selection**: a set of lanes, kept as pane ids so it survives re-sorting. Actions apply to it when it is not empty, else to the lane under the cursor, and say which.
- **Favorite**: a lane you starred. It stays at the top of Lanes across state changes, workspace moves and dashboard openings.
- **Inbox**: questions, unread completions and queued handoffs across all workspaces. Questions and completions appear oldest first within each group.
- **Handoff**: a private Markdown checkpoint holding a note and a lane's workspace metadata, or context imported from a plugin. Its title is searchable in Lanes and stays available across tmux restarts. Queuing links it to a recipient in the Inbox. Staging leaves a file reference in that idle agent's input for the user to submit.
- **Dashboard**: the popup on `prefix Space`: one palette for lanes, workspaces, actions and commands. With the search empty, favorites come first, followed by lanes waiting for you and the remaining lanes in their groups.
- **Action**: something you can do with what is under the cursor, listed by `→`, each on one key; the most used also run with `ctrl` + their key, even mid-search.
- **View**: what the dashboard lists, switched with `tab`: Lanes, one per plugin that brings a view, and Usage.
- **Plugin**: a folder with a `plugin.toml` and one executable, installed by name (official, in `plugins/`), from a folder, or from a git repo. It may listen to lane events (`lane.state`, `lane.urgent`), bring a view, a `pitwall <command>` and a segment (its piece of the status line, `@pitwall_seg_<name>`). See docs/plugins.md.
- **Story**: an OpenTimeline conversation, a row of the OpenTimeline plugin's view. A plugin's row belongs with a lane when the lane's tab name appears in what the row is about (a story: its project or title).
- **Recipe**: a workspace written down for `pitwall up`: its tabs, and what each runs (an agent, a command, a worktree). In a repo's `.pitwall.toml` or `~/.config/pitwall/up/<name>.toml`.
- **Ref**: the short handle `@1`, `@2`… that `pitwall ls` prints, valid until the next `ls`. Agents act on refs, not on pane ids.
- **Ledger**: one line per lane state change, a file a day under `~/.local/state/pitwall/ledger/`; it tells how long each lane worked and waited on you.
- **Seat**: the OpenTimeline system identity the OpenTimeline plugin reports signals with. It has `read` and `signal` only.
- **Record**: one file per agent session in `~/.local/state/pitwall/lanes/`: its agent, session id, directory, and where it lived (session, window, pane, tmux server). Written by the hook, read by restore.
- **Restorable**: a record whose tmux server is gone. On a live server, a lane without its agent was closed on purpose and stays closed.
- **Hook**: the one `sh` script every harness (Claude Code, Codex, Hermes) calls on every event. It sets state; it never talks to the network.
