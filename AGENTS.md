# Working on pitwall

Read [README.md](README.md) for the product and [CONTEXT.md](CONTEXT.md) for its words: lane, state, board, ref, hook. Code, documentation and commits use English.

## Own the whole change

- `bin/pitwall-hook` is the hot path: it runs on every tool call of every agent. Keep it POSIX `sh`, at most two tmux calls when the state did not change, no network, no new processes beyond tmux. Its only file is the restore record, written when a session starts and once per turn, never per tool call. It must never fail an agent: every error path exits 0.
- A lane is a pane, not a window: state lives in pane options (`set -p`), and a window shows its most urgent pane.
- Rendering is tmux formats reading pane and window options. Do not add a `#()` job, a daemon or polling to show state. `bin/pitwall-tick` is the one exception, and it runs only while a lane works.
- `pitwall.tmux` runs on every config reload. Every change it makes is idempotent and composes with the user's theme: inject into existing formats, never replace them.
- The board is Colemak first: `n` `e` move, `i` jumps in, `h` closes, `d` `D` first and last, arrows as a fallback. `choose-tree` cannot do this; keep the board our own.
- `bin/pitwall-board` targets the macOS bash 3.2 as well as bash 5. Write `${VAR}` before any non-ASCII character, and never put multibyte text in a padded `printf` column.
- Lists that come back from tmux are tab-separated, and a field that may be empty gets a placeholder in the format itself (`#{?x,#{x},-}`): `read` merges consecutive tabs, and tmux before 3.5 prints control characters escaped.
- Add a check to `test/run.sh` for nontrivial logic. It runs on a throwaway tmux server (`tmux -L pitwall-test-$$`).

## Trust boundaries

pitwall reads window options and pane titles and captures panes only for the board's preview. The only network call is `bin/pitwall-signal`, in the background, when the user connected OpenTimeline; it sends states and metrics, never prompts, task titles or transcripts. It never sends keys to an agent's pane. `pitwall restore` types a resume command only into a pane it just created or a plain shell. `pitwall done` removes a worktree only after an explicit `y`. `pitwall install` changes harness settings only with `--write`, keeps a backup beside each file and adds nothing that is already there.

## Commits and releases

Commits are Conventional Commits, subject only. While pitwall is 0.x, `feat` and `fix` both bump the patch (as in OpenTimeline); a breaking change bumps the minor. Never edit `version.txt`, `CHANGELOG.md` or `.release-please-manifest.json` by hand: release-please owns them through its release PR.

## Commands

`test/run.sh` runs the checks. `bin/pitwall demo` starts a server you can attach to (`tmux -L pitwall-demo attach -t lab`). `bin/pitwall doctor` checks a real setup.
