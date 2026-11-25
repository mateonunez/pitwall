# Roadmap

Where pitwall goes next, and the rules it keeps on the way.

## The rules

1. **One job.** See and steer coding agents in tmux. Worktrees belong to a worktree manager, diffs to a diff viewer, the record of what happened to a timeline. pitwall composes them; it does not grow into them.
2. **Free when nothing moves.** Agents push their state; tmux options are the database; format strings render it. No daemon, no polling, no model. The spinner ticker is the only loop, and it runs only while a lane works.
3. **Agents read it too.** Every view a person gets has a text form an agent can read in one call, with refs it can act on.
4. **Your setup stays yours.** pitwall slips into the theme, the keys and the shell you already have. Colemak and vim navigation are first-class, not an afterthought.
5. **Nothing risky by default.** pitwall never types into an agent's pane. Anything that would ships off and marked as an experiment.

## Shipped

- **Restore.** The hook keeps one record per agent session. After tmux dies, `prefix R` opens recoverable lanes in the dashboard and resumes the one you choose. `pitwall restore` brings them all back.
- **Inbox.** Review questions and unread completions across workspaces, answer questions, and mark individual completions as read from the dashboard.
- **Lanes as worktrees.** `pitwall new` and `pitwall done`, on [gwm](https://github.com/kbrdn1/gwm) and [lumen](https://github.com/jnsahaj/lumen).
- **Needs you, beyond the terminal.** `lane.state` signals to [OpenTimeline](https://github.com/mateonunez/opentimeline) through a system seat, with the lane's metrics; the credential renews itself.
- **The dashboard** (`prefix Space`): one palette for lanes, workspaces, actions and commands, replacing the board, the workspace picker and the menu. Move, move and go, rename tabs and workspaces, select, new lane or gwm worktree, diff in lumen, close.
- **The dashboard, second round.** Answer an asking lane with `1` `2` `3`; each lane's task under it; branch, changes and a context bar in the preview; read the whole output, write to the agent, the worktree's or the branch's diff, nvim, lazygit, the PR, interrupt, restart, copy the resume command, undo a move, the most used on `ctrl` keys that work mid-search. An OpenTimeline view (`tab`): stories by project, linked to their lanes, and a way out when the server is down.
- **Questions and selections.** An asking lane's question on its row and in its toast; close, interrupt, restart, write to or rename a whole selection (`select idle` picks them).
- **Workspace recipes.** `pitwall up` brings a workspace back from a small TOML file (tabs, agents resumed, servers, nvim, gwm worktrees), only what is missing; `--save` writes one from an open workspace; `up` in the dashboard.
- **A skill for agents.** `skills/pitwall/SKILL.md`, linked by `pitwall install`: an orchestrator reads `ls --json` (questions included) and `peek`, reports like a pit wall, and acts with `answer` / `send` only after a yes.
- **Usage.** A third dashboard view: limits with bars, resets and the week's pace; today per lane (working, waited on you, tokens) from a local ledger the hook keeps; cpu and memory sparklines. `pitwall stats --today`.
- **Lanes in Neovim.** The repo is a Neovim plugin: `:Pitwall` picks a lane (Telescope, its screen as preview; go, open its folder, answer), `:PitwallCd`, and a statusline count.
- **Recipes that keep up.** A recipe written by `--save` follows its workspace (tabs opened, closed, renamed, new agent sessions) until edited by hand.
- **The board as a manager** (now inside the dashboard). Filter (`/`), output search (`//`), workspace scope (`w`), views by state, by workspace or one row per workspace (`g`), sort (`s`), help (`?`), and a selection with tested rules (`v`, `V`, `m`).
- **Workspaces.** tmux sessions as workspaces, managed from the dashboard, `pitwall move`, other workspaces that need you in the status line.
- **Urgent after a while, and the bell.** A lane asking for ten minutes turns red and is sent as `urgent`; Needs you's count can sit in the status line.
- **Tabs.** `@pitwall-layout tabs`: workspaces as Chrome-style tab groups on top, the usage limits and the machine (cpu, gpu, memory, disk, network, battery) on the panes' bottom rule.
- **Signals that reach their lane.** Hooks run outside tmux (Codex's shared daemon, some Claude sessions) find their pane by session, directory or Codex thread name; a lane whose subagents still work in the background stays working.
- **Context on every lane.** Model, context and tokens from each agent's transcript; [CodexBar](https://github.com/steipete/CodexBar) usage limits in the status line.

- **Plugins.** `pitwall plugin add` takes an official plugin by name, a local folder or any git repo (shown, then installed after a yes). A plugin is one executable and a manifest: lane events, a dashboard view, a `pitwall` command, a piece of the status line ([docs/plugins.md](plugins.md)). OpenTimeline moved out of core to become the first, unchanged for its users.

## Next

| Step | Ships | Done when |
| --- | --- | --- |
| **Spotify, the second plugin** | What plays, from a repo of its own: proves a plugin from outside the tree | `pitwall plugin add mateonunez/pitwall-spotify` and it plays |
| **Workspaces, fuller** | A working directory and a note per workspace; close from the picker | A workspace is a place, not just a name |

## Open questions

- OpenTimeline scopes only agent credentials, so the bell reads Needs you with a person's full token. A `read` scope for people's tokens would let it hold far less.

- Should a lane that has been `asking` for a long time escalate in tmux too, for example with a bell?
- Would a TypeScript CLI earn its keep once `new`, `done` and `restore` arrive, with the hot path staying in `sh`?
