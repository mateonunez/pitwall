# Working on pitwall

Read [README.md](README.md) for the product and [CONTEXT.md](CONTEXT.md) for its words: lane, state, dashboard, ref, hook. Code, documentation and commits use English.

## Own the whole change

- `bin/pitwall-hook` is the hot path: it runs on every tool call of every agent. Keep it POSIX `sh`, at most two tmux calls when the state did not change, no network, no new processes beyond tmux. Its only file is the restore record, written when a session starts and once per turn, never per tool call. It must never fail an agent: every error path exits 0.
- A lane is a pane, not a window: state lives in pane options (`set -p`), and a window shows its most urgent pane.
- Rendering is tmux formats reading pane and window options. Do not add a `#()` job, a daemon or polling to show state. `bin/pitwall-tick` is the one exception, and it runs only while a lane works.
- `pitwall.tmux` runs on every config reload. Every change it makes is idempotent and composes with the user's theme: inject into existing formats, never replace them.
- The dashboard types first, like a palette: `ctrl-n` `ctrl-e` move (Colemak), `⏎` does the obvious thing, `ctrl` + a letter runs an action even mid-search, `shift-tab` (or `→`) lists the actions, each on one key, with `n` `e` to move there. `esc` steps back one layer at a time. Only with the search empty do bare keys act at once (`1` `2` `3`, `space`); `tab` switches views. No action takes `ctrl-a` `ctrl-b` (tmux prefixes), `ctrl-l` (often bound in tmux's root table) or the keys the terminal reserves (`ctrl-h` `ctrl-i` `ctrl-j` `ctrl-m`). The OpenTimeline view shows stories only while the server answers; otherwise it names the problem and offers the way out (start, ask an agent, download, connect).
- The dashboard's selection rules are part of its contract: marks are pane ids, never rows; selected lanes the filter hides are counted wherever an action is offered; the footer names the target; `esc` peels the selection, then the filter and scope, then closes; a group action clears the selection. A change that touches selection keeps or extends the board tests that check these.
- The dashboard stays smooth by never blocking on tmux while you type: the periodic reload runs in the background (`fetch &`, picked up by `load_poll`), the list is rebuilt only when what it shows changed, keys already typed are read before the next frame, and drawing forks nothing (functions set variables such as `$hlo` and `$fl` instead of `$(…)`). Keep it that way: one `$(…)` per row is a visible stutter with a dozen lanes.
- Dashboard tests drive the real dashboard in its own tmux server (keys in with `send-keys`, screen out with `capture-pane`). Assert what a person would see, such as the filter line disappearing, not only row counts.
- Bash traps the dashboard has met: a cooked tty applies a backspace typed while the screen draws to the keys still queued, so the dashboard keeps the tty out of line mode (`stty -icanon -echo`) for its whole run; `read -n` turns signals and literal-next back on, so the dashboard undefines `intr`, `susp`, `lnext`, `discard` (and `dsusp`, `status` on macOS) instead of clearing `isig` and `iexten`; `shopt -s nocasematch` also changes `case`, so enable it only around the match that needs it; and `x='' f` assigns `x` only for that call of `f`, so end assignments with `;`.
- `bin/pitwall-dash` targets the macOS bash 3.2 as well as bash 5. Write `${VAR}` before any non-ASCII character, and never put multibyte text in a padded `printf` column.
- Lists that come back from tmux are tab-separated, and a field that may be empty gets a placeholder in the format itself (`#{?x,#{x},-}`): `read` merges consecutive tabs, and tmux before 3.5 prints control characters escaped.
- Add a check to `test/run.sh` for nontrivial logic. It runs on a throwaway tmux server (`tmux -L pitwall-test-$$`).

## Trust boundaries

pitwall reads window options and pane titles and captures panes only for the dashboard's preview. The only network calls are `bin/pitwall-signal`'s, in the background, when the user connected OpenTimeline: it sends states and metrics, never prompts, task titles or transcripts, and the dashboard reads `/v1/today` back with the same seat. Keys reach an agent's pane only when the user presses them in the dashboard: `1` `2` `3` to a lane that is `asking` (never one that works), a message they typed (`s`), `esc` (`i`); a restart (`R`) asks first. Back from the actions, the cursor returns to the lane it was on, so an answer never lands on another lane. `pitwall restore` types a resume command only into a pane it just created or a plain shell. `pitwall done` removes a worktree only after an explicit `y`. `pitwall install` changes harness settings only with `--write`, keeps a backup beside each file and adds nothing that is already there.

## Commits and releases

Commits are Conventional Commits, subject only. While pitwall is 0.x, `feat` and `fix` both bump the patch (as in OpenTimeline); a breaking change bumps the minor. Never edit `version.txt`, `CHANGELOG.md` or `.release-please-manifest.json` by hand: release-please owns them through its release PR.

## Commands

`test/run.sh` runs the checks. `bin/pitwall demo` starts a server you can attach to (`tmux -L pitwall-demo attach -t lab`). `bin/pitwall doctor` checks a real setup.
