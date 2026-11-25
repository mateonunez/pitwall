# OpenTimeline for pitwall

The official plugin for [OpenTimeline](https://github.com/mateonunez/opentimeline):

- **Signals.** A lane that starts asking shows up in OpenTimeline's Needs you, and clears when the lane moves on. Only the state, the agent and its metrics are sent, never prompts, task titles or transcripts. A signal that cannot go out waits in `~/.local/state/pitwall/signals.jsonl` and leaves with the next one.
- **A dashboard view.** `tab` shows the last seven days of stories, grouped by project, with what needs you (a `blocker`) first. On the right are the story's latest updates and the lanes it belongs with: `⏎` opens it in the browser, `ctrl-g` takes you to its lane, `ctrl-y` copies its link. When the server does not answer, the view says so and offers to start it, to ask your agent to bring it up, or to download it. It retries on its own.
- **Needs you in the status line.** `⚑ 3`, refreshed when a lane finishes a turn.
- **Hand off a story.** Press `ctrl-q` on a story, or use `→` then `h`. The connected seat reads the latest story and exports its conversation as a private Pitwall handoff, with a source link. Older servers contribute their current Today summaries. Large exports include the latest summaries and stop around 60 KiB. Use the same recipient picker and draft confirmation as for a lane handoff.

```sh
pitwall plugin add opentimeline
pitwall ot connect <seat-token-file> [--url URL]   # status · flush · disconnect
pitwall ot bell <person-token-file>                # Needs you's count; off to stop
```

The seat is a system identity with `read` and `signal` only. Its token renews itself in place when the server opens the renewal window. Needs you belongs to a person, so its count is read with that person's token.

For agents working in an approved space, `pitwall ot stories --space SLUG [query]` lists recent matching stories as JSON. Use a returned event ID with `pitwall ot context --space SLUG EVENT_ID` for a bounded Markdown export. These commands read through the connected seat and check each event's space before presenting or exporting it.

The view opens with the last successful Today response for the current connection and refreshes in the background. The snapshot lives in the private Pitwall cache under `$XDG_CACHE_HOME/pitwall/panels` (default `~/.cache/pitwall/panels`). It stays visible with a `Last seen` label when the server is temporarily unreachable. Disconnecting or losing access clears the snapshot.

| Option | Default | |
| --- | --- | --- |
| `@pitwall-ot-dir` · `@pitwall-ot-start` | `~/opentimeline` · `pnpm dev` | where OpenTimeline lives on this machine, and how the view starts it |
| `@pitwall-ot-web` | the API's address, `4430` for `4431` | the web app, for links to stories |
| `@pitwall-ot-repo` | `https://github.com/mateonunez/opentimeline` | what the view downloads |

pitwall setups that connected OpenTimeline before it became a plugin get this plugin installed once, on their next tmux load.
