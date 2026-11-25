# Plugins

A plugin adds to pitwall without touching it. It can bring a dashboard view, a `pitwall <command>`, a piece of the status line, and a reaction to lane events. [OpenTimeline](../plugins/opentimeline) is the first one, and it is official: it ships in this repo.

```sh
pitwall plugin add opentimeline          # an official plugin, by name
pitwall plugin add ~/code/my-plugin      # a folder on this machine, linked: edit it and pitwall follows
pitwall plugin add someone/pitwall-thing # a GitHub repo (owner/repo[@ref]), or any git URL
pitwall plugin                           # what is installed, from where, and what each brings
pitwall plugin update [name]             # a repo's new commits, shown first
pitwall plugin rm <name>
```

A repo's code runs on your machine and on your lane events. So `add` and `update` show what it is first: its name, the commit, and what it hooks into. They install only after a yes, or with `--yes`. A local folder is yours already, and an official plugin ships with pitwall.

## The shape

A plugin is a folder with a `plugin.toml` and one executable:

```toml
name = "spotify"                 # lowercase letters, digits, dashes
description = "What plays, in the status line and the dashboard"
version = "0.1.0"
pitwall = ">=0.2.1"              # the oldest pitwall it runs on
run = "bin/spotify"              # the executable, inside the folder
events = "lane.state"            # what it listens to (optional)
view = "Spotify"                 # a dashboard view, named (optional)
command = "music"                # pitwall music … (optional; never one of pitwall's own)
segment = "♫"                    # a piece of the status line (optional)
segment_color = "muted"          # asking · done · gone (bold, they ask for you) · muted
segment_where = "rule"           # status (the top, the default) · rule (the panes' bottom rule, in the tabs layout)
```

pitwall calls the executable with a verb:

| Call | When | What it does |
| --- | --- | --- |
| `run hook lane.state <pane> <old> <new>` | a lane changes state (`-` when it had none) | anything; in the background, so a slow plugin never holds an agent up |
| `run hook lane.urgent <pane> <minutes>` | a lane has asked for `@pitwall-urgent-after` | the same |
| `run view` | the dashboard is open: at once, then every minute, or as `every` asks | prints the view's records, below |
| `run view <key>` | a row opens a detail page | prints the records for that page |
| `run act <action> <row> [answer]` | an action whose verb is `run` or `prompt` | acts, then prints what follows |
| `run cmd <args…>` | `pitwall <command> <args…>` | is the command |

Every call gets `PITWALL`, the path of the `pitwall` CLI, so the plugin can call `pitwall ls --json`, `pitwall peek`, and the rest. The segment is the tmux option `@pitwall_seg_<name>` (dashes become underscores). The plugin sets it whenever it likes. The status line shows the glyph and the value while the option holds something other than `0`. The value may carry tmux styles (`#[fg=#6b7280]`). Text from elsewhere, like a song title, must double its `#` (`##`), or tmux reads it as a format.

## A view

A view is lines of tab-separated records, read in the background. Nothing in it runs while the dashboard draws. Each view receives `PITWALL_VIEW_CACHE`, a private temporary file path it may use to reuse data between reads. The dashboard removes it when the popup closes.

A cold view or detail page may publish a saved snapshot or incoming pages through `PITWALL_VIEW_PREVIEW`. Write a standalone set of view records beside the path and atomically rename it in place. Each publication replaces the preceding preview, so include all pages loaded so far. Final stdout replaces the preview, preserving the query and the selected row ID. Use stable row IDs across pages and refreshes. An empty or unset preview path means a view is already visible or the caller only reads stdout.

Plugins own any cache that survives the popup. Keep it private and scoped to the current account, connection and detail key. Label saved records `Last seen` while refreshing or after a transient failure. Clear saved records when the user disconnects or access is revoked. Within the dashboard, Page Up and Page Down move by a screen of currently matching rows.

| Record | Fields | Meaning |
| --- | --- | --- |
| `every` | seconds, optional foreground seconds | when to read the view again (default 60). The foreground interval also applies to the root while a detail is open |
| `badge` | text | beside the view's name in the dashboard's top line |
| `right` | text | the top right, while the view is open |
| `hint` | text | in the search box |
| `unit` | singular, plural | what a row is: `story stories` |
| `head` | title, flags | a section. Flags: `count` appends how many rows it shows, `timeline` joins its rows with `│`, `spotlight` includes the section’s rows in searches from Lanes |
| `row` | id, glyph, text, meta, find, about, at | an item. `find` is what the search matches. `about` links it to a lane whose tab name it contains. `at` is an epoch, so the lane's preview can say how recent it is |
| `act` | row, action, key, label, description, verb, args… | an action on a row; `-` for the view's own commands. The first one is `⏎` |
| `side` | row, prefix, text, optional position ms, duration ms, sample epoch, playing (0 or 1) | a line of the row's preview. On the pinned row, the optional fields replace the fallback text with a progress bar and update that row's timer. Supply one such line per view |
| `pin` | row, shortcuts | keep this row's preview above the selection throughout the tab and its detail pages. Use `-` for the view itself. Emit once before its `side` records. Optional space-separated bindings such as `k:⏎` map Ctrl-K to that row's existing action key while browsing. Only `run` actions take pinned shortcuts. |
| `stale` | | freezes the progress bar at its last confirmed sample |
| `resume` | opaque login key | opts the root into restoring its tab, detail, search and selected row on the same tmux server. Use a stable, hashed key for the current login and API. Emit it on both live records and snapshots that are valid for that login |

A view that prints commands and no rows is a view whose source is down or not set up. There, each command's key runs it, and the search box dims.

An action's verb says what the dashboard does with it:

| Verb | Args | Does |
| --- | --- | --- |
| `open` | URL | opens it |
| `copy` | text | into the tmux buffer and the clipboard |
| `tab` | name, folder, command | a tab in this workspace runs it; the view is read again a few seconds later |
| `lane` | name, folder, command | the same, and you go there |
| `page` | key | opens one detail page from a root view or a Lanes search. The plugin receives the key as a single argument. Esc clears the page search, then returns to the originating row and search. |
| `refresh` | | reads the view again |
| `prompt` | label | asks, then calls `act` with the answer |
| `run` | optional shortcut, such as `ctrl-q` | calls `act` in the background and keeps the search and row selection. On a row, the shortcut also runs the action while browsing. Use `ctrl-` followed by one of `d k o q r s t v w x y` |

`act` answers with lines such as `notice <text>`, `refresh`, `open <url>` and `copy <text>`. The dashboard runs one plugin action at a time. Use `refresh<TAB>root` when only the main plugin view needs refreshing. A plain `refresh` also refreshes the originating detail page while it is still open.

An explicit `run` action can return one `handoff<TAB><base64>` record, with UTF-8 Markdown up to 64 KiB before encoding. Start with a Markdown heading for the saved handoff's label. Pitwall stores the result privately and offers its recipient picker. The user reviews the context, confirms the destination, and submits the staged draft in that lane. OpenTimeline uses this to import a story using its connected seat.

Text in `badge`, `row` glyph and meta, and `side` can carry colours: `{amber}` `{red}` `{green}` `{blue}` `{text}` `{muted}` `{dim}` `{bold}`, and `{/}` to reset.

## Why it is shaped this way

- **One executable and text, not code loaded into pitwall.** A plugin can be written in any language, it cannot break the dashboard or an agent's hook, and the contract outlives a rewrite of pitwall itself.
- **Extracted, not imagined.** Every piece of the contract is there because a plugin uses it: OpenTimeline needed the lane events, a view, actions, a command and a piece of the status line. A hook nobody uses is not added. When a plugin needs something more, the generic contract grows; pitwall never learns a plugin's name.
- **Free when nothing moves.** pitwall reads one index, written when plugins change and when tmux loads it. It never scans plugins on an event. Hooks and views run in the background.
- **Borrowed:**
  - from [fastify](https://fastify.dev/docs/latest/Reference/Plugins/): a plugin owns its namespace (`@pitwall_seg_<name>`, its own files) and states the pitwall it needs;
  - from [Hermes](https://github.com/NousResearch/hermes-agent): a manifest that says what a plugin provides, and code from elsewhere pinned to the commit you said yes to;
  - from [opencode](https://opencode.ai/docs/plugins/) and pi: named events.
