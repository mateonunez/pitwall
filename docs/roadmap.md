# Roadmap

Where pitwall goes next, and the rules it keeps on the way.

## The rules

1. **One job.** See and steer coding agents in tmux. Worktrees belong to a worktree manager, diffs to a diff viewer, the record of what happened to a timeline. pitwall composes them; it does not grow into them.
2. **Free when nothing moves.** Agents push their state; tmux options are the database; format strings render it. No daemon, no polling, no model. The spinner ticker is the only loop, and it runs only while a lane works.
3. **Agents read it too.** Every view a person gets has a text form an agent can read in one call, with refs it can act on.
4. **Your setup stays yours.** pitwall slips into the theme, the keys and the shell you already have. Colemak and vim navigation are first-class, not an afterthought.
5. **Nothing risky by default.** pitwall never types into an agent's pane. Anything that would ships off and marked as an experiment.

## Shipped

- **Restore.** The hook keeps one record per agent session; after tmux dies, `prefix R` or `pitwall restore` rebuilds sessions, windows and panes and resumes each agent.
- **Lanes as worktrees.** `pitwall new` and `pitwall done`, on [gwm](https://github.com/kbrdn1/gwm) and [lumen](https://github.com/jnsahaj/lumen).
- **Needs you, beyond the terminal.** `lane.state` signals to [OpenTimeline](https://github.com/mateonunez/opentimeline) through a system seat, with the lane's metrics; the credential renews itself.
- **The board as a manager.** Filter (`/`), output search (`//`), workspace scope (`w`), views by state, by workspace or one row per workspace (`g`), sort (`s`), help (`?`), and a selection with tested rules (`v`, `V`, `m`).
- **Workspaces.** tmux sessions as workspaces: `prefix W`, `m` in the board, `pitwall move`, other workspaces that need you in the status line.
- **Urgent after a while, and the bell.** A lane asking for ten minutes turns red and is sent as `urgent`; Needs you's count can sit in the status line.
- **Tabs.** `@pitwall-layout tabs`: workspaces as Chrome-style tab groups on top, the usage limits and the machine (cpu, gpu, memory, disk, network, battery) on the panes' bottom rule.
- **Signals that reach their lane.** Hooks run outside tmux (Codex's shared daemon, some Claude sessions) find their pane by session, directory or Codex thread name; a lane whose subagents still work in the background stays working.
- **Context on every lane.** Model, context and tokens from each agent's transcript; [CodexBar](https://github.com/steipete/CodexBar) usage limits in the status line.

## Next

| Step | Ships | Done when |
| --- | --- | --- |
| **Manage a lane from the board** | `r` rename, `x` close (asks first), `space` full preview with scrollback, `o` diff, `y` copy the resume command, `a` a new lane here, `u` undo the last move; each with its `pitwall` command | Most of a lane's life happens without leaving the board |
| **Group actions, past moving** | Close or rename a selection, with the same rules: counted, named, cleared | Tidying ten lanes takes one selection |
| **Workspaces, fuller** | A working directory and a note per workspace; close from the picker | A workspace is a place, not just a name |
| **Saved lanes in the board** | Closed and restorable lanes in their own section; restore or forget one | Coming back after a crash is a list, not a command |
| **Metrics over time** | A small per-session ledger (turns, tokens, time asking versus working) so `pitwall stats --today` answers where the day went | You see which lanes cost the most and which waited on you the longest |
| **Why a lane asks** | The reason a lane is asking shows on its row and its tab | You answer from the board without opening the lane |
| **A skill for agents** | `skills/pitwall/SKILL.md`, so an orchestrator learns `pitwall ls`, refs and `peek` | An agent reads the fleet and asks before acting |

## Open questions

- OpenTimeline scopes only agent credentials, so the bell reads Needs you with a person's full token. A `read` scope for people's tokens would let it hold far less.

- Should a lane that has been `asking` for a long time escalate in tmux too, for example with a bell?
- How far should the board go: filter by typing, or stay a list you move through?
- Would a TypeScript CLI earn its keep once `new`, `done` and `restore` arrive, with the hot path staying in `sh`?
