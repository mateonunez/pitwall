# Context

The words pitwall uses, and only those.

- **Lane**: one tmux pane that runs one agent, usually in one worktree. A window can hold several lanes; it shows the most urgent one. A lane is named after its window, plus `.N` when the window has more than one pane.
- **State**: what a lane is doing now. Exactly one of:
  - `working`: the agent is thinking or running a tool, or a subagent it started in the background still is (a background shell does not count).
  - `asking`: the agent waits for you (permission, a question, a choice).
  - `done`: the agent finished a turn while you were in another window. It stays `done` until you visit the lane: the unread mark.
  - `idle`: finished and already seen, or never started.
  - `gone`: the agent exited; the window has a plain shell.
- **Urgent**: an `asking` lane that has waited longer than `@pitwall-urgent-after` (ten minutes). Not a state of its own: a mark that clears when the lane moves on.
- **Workspace**: a tmux session, holding the windows of one project or one kind of work. Moving a lane between workspaces moves its window; its agents keep running.
- **Search**: what you type in the dashboard; every word must appear in a lane, a workspace, an action or a command. Words that start an action's name (`rename`, `diff`, `move`) and words that find a lane suggest that action on that lane. With a leading `/`, the text searched in the lanes' recent output.
- **Selection**: a set of lanes, kept as pane ids so it survives re-sorting. Actions apply to it when it is not empty, else to the lane under the cursor, and say which.
- **Dashboard**: the popup on `prefix Space`: one palette for lanes, workspaces, actions and commands. With the search empty, the lanes waiting for you first, then every lane by workspace.
- **Action**: something you can do with what is under the cursor, listed by `shift-tab`, each on one key; the most used also run with `ctrl` + their key, even mid-search.
- **View**: what the dashboard lists, switched with `tab`: Lanes, or OpenTimeline (the seat's last days of stories, by project).
- **Story**: an OpenTimeline conversation. It belongs with a lane when the lane's tab name appears in its project or title.
- **Ref**: the short handle `@1`, `@2`… that `pitwall ls` prints, valid until the next `ls`. Agents act on refs, not on pane ids.
- **Seat**: the OpenTimeline system identity pitwall reports signals with. It has `read` and `signal` only.
- **Record**: one file per agent session in `~/.local/state/pitwall/lanes/`: its agent, session id, directory, and where it lived (session, window, pane, tmux server). Written by the hook, read by restore.
- **Restorable**: a record whose tmux server is gone. On a live server, a lane without its agent was closed on purpose and stays closed.
- **Hook**: the one `sh` script every harness (Claude Code, Codex, Hermes) calls on every event. It sets state; it never talks to the network.
