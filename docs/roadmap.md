# Roadmap

Where pitwall goes next, and the rules it keeps on the way.

## The rules

1. **One job.** See and steer coding agents in tmux. Worktrees belong to a worktree manager, diffs to a diff viewer, the record of what happened to a timeline. pitwall composes them; it does not grow into them.
2. **Free when nothing moves.** Agents push their state; tmux options are the database; format strings render it. No daemon, no polling, no model. The spinner ticker is the only loop, and it runs only while a lane works.
3. **Agents read it too.** Every view a person gets has a text form an agent can read in one call, with refs it can act on.
4. **Your setup stays yours.** pitwall slips into the theme, the keys and the shell you already have. Colemak and vim navigation are first-class, not an afterthought.
5. **Nothing risky by default.** pitwall never types into an agent's pane. Anything that would ships off and marked as an experiment.

## Next

| Step | Ships | Done when |
| --- | --- | --- |
| **Lanes as worktrees** | `pitwall new <task> [--agent codex]` creates a worktree with [gwm](https://github.com/kbrdn1/gwm), opens a window there and starts the agent; `pitwall done @N` opens the diff in [lumen](https://github.com/jnsahaj/lumen) and removes the worktree after you confirm | A task goes from idea to reviewed diff without typing a path |
| **Restore** | The hook already sees each session's id; pitwall keeps `lane → resume command` and `pitwall restore` reopens the lanes that exited | A reboot costs one command |
| **Needs you, beyond the terminal** | `lane.state` signals to [OpenTimeline](https://github.com/mateonunez/opentimeline) through a system seat: `asking` needs attention, `asking` for ten minutes is urgent. Its bell comes back as a count in the status line | A lane waiting for you shows up where you are, not only in tmux |
| **Quotas** | [CodexBar](https://github.com/steipete/CodexBar)'s CLI usage for Claude and Codex in the status line, cached for a few minutes | You see the limit coming before an agent hits it |
| **A skill for agents** | `skills/pitwall/SKILL.md`, so an orchestrator learns `pitwall ls`, refs and `peek` | An agent reads the fleet and asks before acting |

## Open questions

- Should a lane that has been `asking` for a long time escalate in tmux too, for example with a bell?
- How far should the board go: filter by typing, or stay a list you move through?
- Would a TypeScript CLI earn its keep once `new`, `done` and `restore` arrive, with the hot path staying in `sh`?
