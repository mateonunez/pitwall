# Context

The words pitwall uses, and only those.

- **Lane**: one tmux pane that runs one agent, usually in one worktree. A window can hold several lanes; it shows the most urgent one. A lane is named after its window, plus `.N` when the window has more than one pane.
- **State**: what a lane is doing now. Exactly one of:
  - `working`: the agent is thinking or running a tool.
  - `asking`: the agent waits for you (permission, a question, a choice).
  - `done`: the agent finished a turn while you were in another window. It stays `done` until you visit the lane: the unread mark.
  - `idle`: finished and already seen, or never started.
  - `gone`: the agent exited; the window has a plain shell.
- **Board**: the popup listing every lane, `asking` first, then `done`, then `working`, then the rest.
- **Ref**: the short handle `@1`, `@2`… that `pitwall ls` prints, valid until the next `ls`. Agents act on refs, not on pane ids.
- **Seat**: the OpenTimeline system identity pitwall reports signals with. It has `read` and `signal` only.
- **Hook**: the one `sh` script both harnesses call on every event. It sets state; it never talks to the network.
