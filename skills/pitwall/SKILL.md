---
name: pitwall
description: Coordinate local tmux lanes with Pitwall when the user asks or the project opts in. Use for triage, handoffs and restore. Ask the user before acting on another lane.
---

# pitwall: the fleet of agents in tmux

pitwall shows each coding agent running in tmux (Claude Code, Codex, Hermes and others) as a **lane**, with a **state**:
`asking` (waits for the user), `done` (finished while the user looked elsewhere), `working`, `idle`, `gone`.
An `asking` lane that has waited past ten minutes is **urgent**.

## Scope the read

Follow the project's local coordination instructions first. Use Pitwall proactively only where the project opts in.
When the owner authorizes one workspace, run
`pitwall ls --workspace NAME --json`, with `--root DIR` for each approved project root when that workspace is shared.
This returns pane IDs for inspection. Use the unscoped commands below only when the owner authorizes the whole fleet.

```sh
pitwall ls --json      # every lane, the ones that need the user first
pitwall peek @2 40     # the last 40 lines of a lane's screen
pitwall stats @2       # model, context used, tokens
pitwall up --list      # the workspace recipes, and how much of each is up
```

`ls --json` gives, per lane: `ref` (`@1`, `@2`…), `state`, `session` (the tmux workspace), `window`, `harness`,
`task` (what the agent is on), `since` (epoch of the last state change), `urgent`, `folder`, and for an `asking`
lane its `question` (`Allow pnpm release --tag v0.2.0?`) and `choices` (`1 Yes · 2 Yes, always · 3 No`).

Unscoped refs are positions in the current order. Confirm the lane and list again before acting.

For a handoff from your own lane, save a short note with the result, evidence and next step via
`pitwall handoff save --here < note.md`, or use the project's scoped wrapper. Share the resulting ID with the user.

## Report like a pit wall

Lead with what waits on the user, urgent first, one line each, with the question and how long it has waited:

> Three lanes wait on you: **malock** asks which changelog format (12m, urgent); **ait.2** asks to run
> `pnpm --filter @ait/linear lint` (4m); **website** finished the Spotify card. Two are working, one is idle.

Then offer the one obvious next step ("Answer ait.2 with 1, yes?"). Do not dump the whole list unless asked.

## Act only after asking, one lane at a time

Every action below changes another agent's session. **Ask the user and wait for a yes** for each one, naming the
lane, the action and, for an answer, which choice it is. Never act on a lane because it "looks safe".

```sh
pitwall answer @2 1          # one numbered answer to a lane that is asking (refused if it is not)
pitwall send @3 "run the tests again"   # a message to a lane's agent
pitwall go @2                # take the user to the lane
pitwall up ait               # bring a workspace back from its recipe (only what is missing)
```

- Read the lane (`peek`) before proposing an answer; quote what it asks.
- An answer like "Yes, and don't ask again" widens what that agent may do later: say so when you propose it.
- Never answer, send to, or close a lane on your own initiative, and never several at once without a yes for
  that whole set.
- Moving, closing, renaming and restarting lanes are for the user in the dashboard (`prefix Space`).
