# harner.nvim

[![tests](https://github.com/duskpoet/harner.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/duskpoet/harner.nvim/actions/workflows/test.yml)

Chat with [Claude Code](https://docs.claude.com/en/docs/claude-code) from a
Neovim split, with Claude working *inside your editor* instead of next to it.

https://github.com/user-attachments/assets/127306c0-f5e7-402c-ac4b-859eef6e422b

harner runs the `claude` CLI headless (`claude -p`) and gives it an MCP
server that talks to the Neovim you are sitting in. Claude can then:

- **see what you see**: the current buffer, cursor, visual selection, open
  buffers and LSP diagnostics, so "explain this" or "fix the error here"
  needs no copy-pasting;
- **show you things**: jump your window to a file and highlight the lines it
  is talking about, or open long output (diffs, tables, generated code) in a
  scratch window;
- **edit your buffers**: changes land in the buffer unsaved, so you review
  them with your usual tools and undo with `u`;
- **ask you**: questions with choices, and a confirm float before it runs an
  Ex command or a shell command.

There is no terminal emulator in between: the transcript is a markdown
buffer (boxed tables, shaded code, `gf` on `file.lua:12` references and
URLs), prompts are typed in a small popup, and every chat keeps its own
Claude session with your `CLAUDE.md`, skills and MCP connectors.

If you want the interactive Claude Code TUI inside Neovim instead, use
[coder/claudecode.nvim](https://github.com/coder/claudecode.nvim); the two
work side by side.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Usage](#usage)
- [What Claude can do in the editor](#what-claude-can-do-in-the-editor)
- [Confirms and auto mode](#confirms-and-auto-mode)
- [Security](#security)
- [Configuration](#configuration)
- [Extra MCP servers](#extra-mcp-servers)
- [Highlight groups](#highlight-groups)
- [Terminal integration](#terminal-integration)
- [Troubleshooting](#troubleshooting)
- [How it works](#how-it-works)
- [Development](#development)

## Requirements

- Neovim 0.10 or newer
- the [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) on
  `PATH` as `claude` (or set `claude_cmd`), logged in: run `claude` once in
  a terminal first. Requests are billed to that account like any other
  Claude Code use
- optional: the treesitter `markdown` and `markdown_inline` parsers for
  transcript colours and concealed markup,
  [which-key.nvim](https://github.com/folke/which-key.nvim) for the
  `<leader>h` group label

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "duskpoet/harner.nvim",
  event = "VeryLazy",
  opts = {},
}
```

`opts` is passed to `require("harner").setup()`; without `opts` (or
`config`) lazy.nvim never calls `setup()` and no commands or keys exist. To
load on first use instead, list the commands and keys in the spec:

```lua
{
  "duskpoet/harner.nvim",
  cmd = { "Harner", "HarnerAsk", "HarnerNew", "HarnerChats", "HarnerCancel", "HarnerAuto", "HarnerMinimize", "HarnerDecisions" },
  keys = { "<leader>hh", { "<leader>hh", mode = "x" }, "<leader>ht", "<leader>hn", "<leader>hl", "<leader>hx", "<leader>ha", "<leader>hm" },
  opts = {},
}
```

With any other plugin manager, add the repository and call
`require("harner").setup({})` yourself.

Inside Neovim the same documentation is available as `:help harner`.

## Quick start

1. Open a file and press `<leader>hh`. Type a question in the popup, e.g.
   `what does this file do?`, and press `<CR>`.
2. The chat split opens on the right and the answer streams in. Lines like
   `→ nvim:get_current_buffer` show which tools Claude used.
3. Select some lines in visual mode, press `<leader>hh` and ask
   `simplify this`. Claude reads the selection, edits the buffer and moves
   your window to the change. Review it, then `:w` to keep it or `u` to
   undo.
4. Keep asking with `<leader>hh` (same conversation), or press `<leader>hn`
   for a fresh one.

## Usage

| key / command            | action                                                             |
| ------------------------ | ------------------------------------------------------------------ |
| `<leader>hh`             | input popup for the current chat; in visual mode it attaches a reference to the selection |
| `<leader>ht` / `:Harner` | toggle the chat split                                              |
| `<leader>hn` / `:HarnerNew` | new chat (fresh Claude session; the old chat is kept)           |
| `<leader>hl` / `:HarnerChats` | pick one of this nvim's chats to show, or a saved one from an earlier session in this directory |
| `<leader>hx` / `:HarnerCancel` | cancel the running request (the current chat's, else the only running one) |
| `<leader>ha` / `:HarnerAuto` | toggle auto mode (fewer confirms) for the current chat         |
| `<leader>hm` / `:HarnerMinimize` | minimize / restore the open confirm float (`m` inside it), to read what it covers before answering |
| `:HarnerAsk [text]`      | send text directly, or open the popup when called bare; `:'<,'>HarnerAsk` attaches the range |
| `:HarnerDecisions`       | summary of what was confirmed, declined or run unasked             |

The keys are configurable (`keys`, any entry `false` disables it).

**The popup.** `<CR>` sends, `<S-CR>` or `<C-CR>` inserts a newline, `<Esc>`
closes and keeps the text as a draft for the next open. Sending while Claude
is still answering queues the message; it goes out when the current reply
ends (the winbar shows `N queued`).

**Skills.** Start a message with `/` (in the popup or the chat input) and a
menu lists your skills and slash commands with their descriptions: user and
project `.claude/skills` / `.claude/commands`, installed plugins
(`plugin:name`), and after the first reply everything Claude itself reports
for the project (built-ins included). `<Tab>` fills in the highlighted entry
and then moves down, `<S-Tab>` moves up, `<CR>` accepts.
`prompt.complete = false` turns it off.

**The chat split.** Everything below the last `────` line is your next
message: `<CR>` in normal mode or `<C-s>` in insert mode sends it, `<C-c>`
cancels a run. `gf` on a URL or a `path/file.lua:12-20` reference opens it.
The winbar shows the state (`thinking…`, `running Grep`, `idle`), the cost
of the last reply, how full the context window is (`ctx 42k/200k 21%`) and
the `AUTO` badge.

**Selections.** A selection is passed by reference, not pasted: the prompt
ends with a `Selection: <path> lines N-M` line and Claude reads the lines
itself with `get_selection`.

**Several chats.** Chats live until nvim exits. Closing the split,
`:bdelete` or `:bwipeout` on a chat buffer only hides it; `<leader>hl`
brings it back with the same transcript and Claude session. Several chats
can run at once; each one's tools act on the window it was asked from.

## What Claude can do in the editor

- read: `get_current_buffer`, `get_cursor`, `get_selection`, `list_buffers`,
  `get_diagnostics`
- display: `show_text` (scratch window with a filetype, `q` closes it),
  `open_file` (jump to a file and highlight a line range), `show_page` (a
  markdown or HTML file, a picture or an http(s) URL, rendered: an overlay
  in agterm, the system viewer elsewhere)
- change: `edit_file` (str_replace-style edit applied to the buffer, unsaved
  and undoable), `write_file` and `save_file` (disk writes, unasked except outside the
  working directory, `.git/`, `.claude/` and files that run code when loaded;
  `save_file` takes several files under at most one confirm)
- interact: `ask_user` (question with optional choices), `run_command` (an Ex
  command, confirmed unless it starts with an entry of `run_command.allow`)
- shell (opt-in, `bash = { enabled = true }`): `bash` runs a command with
  `bash -c` in the working directory and returns stdout, stderr and the exit
  code. Each command is confirmed unless it starts with an entry of
  `bash.allow` and contains no shell operators (`;`, `&`, `|`, redirects,
  `$`, backticks, ...), so `git status; rm -rf ~` never slips through an
  allowed `git status`. The operator check does not limit what the allowed
  program does with its own arguments, so keep entries to specific read-only
  subcommands (`git status`, `git log`, `gh pr view`). A bare program name
  allows everything it can do (`git -c alias.x='!rm -rf ~' x` passes a
  `git` entry), as does any entry that writes through options (`git diff
  --output=FILE`) or runs project scripts (`npm`, `make`, `cargo`). No stdin
  or TTY; commands are killed (whole process
  group) on timeout, `<leader>hx` or the end of the reply. This is what
  shell-dependent skills such as a PR review need. With the tool off, Claude
  is told to say up front when a task needs a shell instead of stopping
  partway through.

Next to these, Claude has its built-in read-only tools (`Read`, `Grep`,
`Glob`, `WebFetch`) and nothing else: no built-in shell and no direct file
write.

## Confirms and auto mode

Commands and the disk writes that ask are confirmed in a small float that
shows the full command or file list: `y` approves, `a` approves and stops asking for the rest
of the chat (that exact command, or all writes), `n` / `<Esc>` skips. Edited
files are shown in your working window; if it holds unsaved changes of your
own, harner splits once and reuses that window for every later file. If
Claude wants to edit a file you have unsaved changes in, it asks first: `s`
saves your changes and then edits, `d` drops them (reloads from disk), `n`
skips the edit.

### Auto mode

Auto mode is on by default (the winbar shows `AUTO`); `<leader>ha` toggles it
for the current chat, and a new chat starts at `auto.enabled`. Your allow-lists and `a` grants
still apply first. Beyond them:

- with `write_file.confirm = true`, writes (`write_file`, `save_file`) inside
  the working directory run without asking (with the default `false` they
  never ask anyway);
- writes outside the working directory or under `.git/` / `.claude/` go to
  the classifier below (it also sees the content, or the diff for
  `save_file`). Files that run code or grant permissions always ask, auto
  mode or not: `.nvim.lua`, `.nvimrc`, `.exrc`, `.lazy.lua`, `.envrc`,
  a `.git` file, `hooks/` and `config` under `.git/` (submodules and
  worktrees included),
  everything under a `.claude/` dir (project or `~`: settings, hooks and
  their scripts, plugins) except memory notes in `projects/<x>/memory/`, and
  `~/.claude.json`. Directories you list in `write_file.allow` (e.g. a
  skill's data dir, `~/.claude/skills/pr-review/reviews`) count as project
  files, so writes there don't ask, except `SKILL.md`, `CLAUDE.md`,
  `settings*.json`, `.mcp.json`, `hooks.json`, the files above that run code,
  and anything under `.git/`;
- a built-in list of read-only shell commands runs without asking (`git
  status|log|diff|show|blame`, read-only `git branch`, `ls`, `pwd`, `rg`, and
  `cat|head|tail|wc` on paths inside the working directory), plus your
  `auto.allow` entries. Chains (`&&`, `||`, `;`, `|`) pass when every part
  does; quotes are respected and `2>&1` / `2>/dev/null` are allowed, any
  other operator, redirect, `$` or backtick rules the command out;
- every other `bash` and `run_command` call goes to a classifier
  (`claude -p --model haiku`, no tools) that sees the command, Claude's
  description and your latest message. It either lets the call run or opens
  the normal confirm with its reason under the command. It never refuses on
  its own; an error or a timeout (`auto.timeout`, 15 s) asks you.
  `auto.policy` (a string or a list) adds your own rules to its prompt for
  side effects you are fine with, e.g. `"Launching the Cursor CLI (agent -p
  --mode ask) to review a diff or PR is allowed."`; the rest of the command
  is still judged by the defaults;
- `edit_file`'s save/drop question over your own unsaved changes always asks.

Calls that ran unasked are marked in the transcript, e.g.
`→ nvim:bash · $ git log -5 · auto (rule)` or `· auto (classifier)`.

Every decision (rule, classifier, or your answer to a confirm) is appended
to `decisions.path` (default `stdpath("state")/harner/decisions.jsonl`).
`:HarnerDecisions` summarises it by tool and command, so you can see what
still asks and add `auto.allow`, `auto.policy` or `write_file.allow`
entries for it.

## Security

Headless Claude silently denies anything not pre-approved. harner restricts
the built-in tools to `Read`, `Grep`, `Glob`, `WebFetch` and `ToolSearch` and
approves the `nvim` MCP server, so there is no built-in shell and no direct file write;
all changes go through the tools above (shell commands only through the
confirmed `bash` tool, when you enable it).

Things to know before you rely on that:

- Claude can read any file your user can (`Read` is not limited to the
  working directory) and fetch URLs.
- By default, writes inside the working directory are not confirmed
  (`write_file.confirm = false`); set it to `true` and turn auto mode off
  if you want to approve each one.
- Auto mode is a convenience, not a sandbox: its classifier is a model and
  can be wrong. Set `auto = { enabled = false }` to confirm every command.
- `claude -p` has no trust prompt for the project. harner denies the MCP
  servers of project `.mcp.json` files, but a project's
  `.claude/settings.json` is still read: its `permissions.allow` can
  pre-approve tools and its `hooks` run commands. **Only chat in
  repositories you trust**, as you would with `claude` itself.

## Configuration

Defaults:

```lua
require("harner").setup({
  claude_cmd = "claude",
  model = nil,            -- passed as --model when set
  width = 0.4,            -- chat split: fraction of columns, or columns if >= 1
  builtin_tools = { "Read", "Grep", "Glob", "WebFetch", "ToolSearch" },
  allowed_tools = { "mcp__nvim" },
  extra_args = {},        -- appended to the claude argv (no --settings: harner passes its own)
  mcp_servers = {},       -- extra MCP servers, see below
  connectors = {},        -- claude.ai connectors to approve, see below
  show_text = {
    mode = "split",       -- "split" | "vsplit" | "float"
    float_width = 100,
  },
  show_page = {
    size = 90,            -- agterm overlay: percent of the session
  },
  title = {
    enabled = false,      -- mirror the chat state into the terminal title ('titlestring')
    prefix = "",          -- string or function, e.g. the ssh/dtach session the editor runs in
    format = nil,         -- function(state, chat) -> string, replaces the whole title (prefix ignored)
  },
  terminal = {
    backend = "auto",     -- "auto" | "agterm" | false: show harner's state in the hosting terminal, see below
    info = true,          -- agterm: activity line under the session row
    agtermctl = "agtermctl", -- name on PATH or absolute path
    notify = {            -- desktop notifications through a terminal escape, see below
      enabled = false,
      when = "unfocused", -- or "always"
      events = { "blocked", "done", "error" }, -- waiting for you / run ended / run failed
      protocol = "auto",  -- "auto" | "osc9" | "osc99" | "osc777" | "bell"
    },
  },
  render = {
    enabled = true,       -- decorate the transcript: box tables, shaded code, URL / file:line links (`gf` follows)
    conceal = true,       -- 'conceallevel' 2: hide `**`, backticks, fences, link targets off the cursor line
    tables = true,        -- re-pad finished tables so columns line up
    wrap_tables = true,   -- wrap long cells onto extra rows when a table is wider than the chat window
  },
  run_command = {
    confirm = true,       -- ask before each command not covered by `allow`
    allow = { "edit", "Telescope", "DiffviewOpen", "Git blame", "Git log", "Git diff" },
  },
  write_file = {
    confirm = false,      -- true: ask before every write_file / save_file (auto mode off);
                          -- outside cwd, .git/, .claude/, .nvim.lua & co. always ask
    allow = {},           -- dirs written like project files (not SKILL.md, settings, .git/)
  },
  bash = {
    enabled = false,      -- opt-in shell tool
    confirm = true,       -- ask before each command not covered by `allow`
    allow = {},           -- read-only subcommands only, e.g. { "git status", "gh pr view" }
                          -- (never a bare "git" / "npm": its arguments can run anything)
    shell = "bash",       -- run as `<shell> -c <command>`
    timeout = 120,        -- seconds when Claude gives none (max 540)
    max_output = 30000,   -- bytes returned to Claude, middle cut beyond that
  },
  auto = {                -- auto mode, see above
    enabled = true,       -- default for new chats (<leader>ha toggles per chat)
    allow = {},           -- extra bash prefixes that run without asking
    model = "haiku",      -- classifier model
    timeout = 15,         -- classifier seconds before falling back to asking
    policy = nil,         -- your rules for the classifier (string or list)
  },
  persist = {             -- chats saved per project (cwd), restored via :HarnerChats
    enabled = true,
    path = nil,           -- default stdpath("state")/harner/chats.json
    max = 20,             -- chats kept per project, oldest dropped
  },
  decisions = {           -- decision log, :HarnerDecisions
    enabled = true,
    path = nil,           -- default stdpath("state")/harner/decisions.jsonl
  },
  keys = {                -- set an entry to false to skip it
    group = "<leader>h",  -- which-key group label
    ask = "<leader>hh",
    toggle = "<leader>ht",
    new = "<leader>hn",
    cancel = "<leader>hx",
    auto = "<leader>ha",
    list = "<leader>hl",
    minimize = "<leader>hm",
  },
  prompt = {
    width = 0.6,
    min_height = 1,
    max_height = 10,
    border = "rounded",
    open_chat = true,     -- open the chat split (unfocused) when sending from the popup
    complete = true,      -- menu of /skills when the input starts with `/`
  },
})
```

## Extra MCP servers

Claude loads every MCP server it knows about: claude.ai connectors, servers
added with `claude mcp add`, plugin servers. harner approves only `nvim` and
the ones you list; Claude still sees the others (deferred through `ToolSearch`,
so their schemas don't fill the context), but every call to them is denied and
the system note tells it not to try. To trim what loads, disconnect servers in
claude itself. The exception is project `.mcp.json` files (in the working
directory or any parent): `claude -p` would start them without a trust
prompt, so harner denies them; if one can't be read, that chat runs with
`--strict-mcp-config` and loads none of the above. A project's
`.claude/settings.json` is still read unasked, though: its `permissions.allow`
can pre-approve any loaded server's tools (your connectors included) and its
`hooks` run commands. Only chat in repositories you trust.

Servers that only harner should use go in `mcp_servers` (Claude's
`mcpServers` format). They are merged next to harner's own `nvim` server (that
name is reserved), every tool they offer is pre-approved (`mcp__<name>`), and
the system note tells Claude they exist. claude.ai connectors go in
`connectors`, by the name `claude mcp list` shows without the `claude.ai `
prefix, e.g. `connectors = { "Grafana Cloud", "Linear" }`, which approves
`mcp__claude_ai_Grafana_Cloud__*` and `mcp__claude_ai_Linear__*`.

```lua
require("harner").setup({
  mcp_servers = {
    -- OAuth: log in once from interactive `claude` (/mcp) with a server of the
    -- same name and URL; `claude -p` reuses the stored token
    linear = { type = "http", url = "https://mcp.linear.app/mcp" },
    -- or an API key
    github = {
      type = "http",
      url = "https://api.githubcopilot.com/mcp/",
      headers = { Authorization = "Bearer " .. (os.getenv("GITHUB_TOKEN") or "") },
    },
  },
})
```

OAuth tokens are stored per server name and URL, so the name in `mcp_servers`
must match the one you logged in with (`claude mcp list` shows it). The
generated config file can contain API keys: it is written `0600` and deleted
when the run ends.

## Highlight groups

All groups are defined with `default = true`, so a colorscheme or your own
`nvim_set_hl` wins.

| group | default link | used for |
| ----- | ------------ | -------- |
| `HarnerWinBar`, `HarnerWinBarNC` | `StatusLine`, `StatusLineNC` | chat winbar |
| `HarnerConfirmBorder`, `HarnerConfirmTitle`, `HarnerConfirmKey` | `DiagnosticInfo` | confirm float border, title, keys in the footer |
| `HarnerConfirmFooter` | `Comment` | confirm float footer text |
| `HarnerConfirmNormal` | `NormalFloat` | confirm float body |

The transcript uses `HarnerCodeBlock`, `HarnerCodeLang`, `HarnerToolNote`,
`HarnerSeparator`, `HarnerError`, `HarnerTableBorder`, `HarnerTableHead`,
`HarnerUrl` and `HarnerFileRef`. If your `NormalFloat` matches `Normal`,
give `HarnerConfirmNormal` a distinct background so confirms stand out.

## Terminal integration

harner works the same in every terminal. Three things are optional extras:

- **Title** (any terminal): `title = { enabled = true }` mirrors the chat
  state into the terminal title.
- **Notifications** (any terminal, opt-in with
  `terminal = { notify = { enabled = true } }`): while the terminal is
  unfocused, harner writes a notification escape when a confirm or
  `ask_user` float starts waiting for you, when a run ends and when one
  fails (`terminal.notify.events`). A cancel is not announced, nor is a run
  that only makes room for the next queued message. The escape is picked
  from the environment:

  | terminal                              | escape  |
  | ------------------------------------- | ------- |
  | kitty                                 | OSC 99  |
  | Ghostty, iTerm2, WezTerm, agterm      | OSC 9   |
  | foot                                  | OSC 777 |
  | anything else (Alacritty, Terminal.app, Windows Terminal, …) | BEL |

  It is plain terminal output, so it also works through ssh and dtach.
  Over ssh the terminal's own variables are usually gone: if the guess is
  wrong there, set `protocol` yourself. Inside tmux the escape is wrapped
  for passthrough, which needs `set -g allow-passthrough on`, and
  "unfocused" needs `set -g focus-events on`. Without focus events from
  the terminal harner assumes it is focused and stays quiet;
  `when = "always"` notifies regardless. With `protocol = "auto"` nothing
  is sent while the agterm backend below shows the state already.
- **agterm**: detected by itself
  (`terminal.backend = "auto"`) when nvim runs in an agterm pane and
  `agtermctl` is on `PATH`. The session's status glyph then follows harner:

  | harner                               | agterm status             |
  | ------------------------------------ | ------------------------- |
  | a chat is running                    | `active`                  |
  | a confirm or `ask_user` float waits  | `blocked`                 |
  | the last run ended                   | `completed` (until visited) |
  | the last run failed                  | `completed`, triangle glyph |
  | cancelled, or nvim exits mid-run     | `idle`                    |

  The row also gets an activity line (`harner #1 running Grep`), which
  expires by itself if nvim dies. Several chats count as one session:
  `blocked` wins over `active`, which wins over `completed`.

  If you installed agterm's Claude status hooks, they stay as they are for
  interactive `claude`. For harner's own `claude -p` they are silenced
  (it runs with an empty `AGTERM_SESSION_ID`), since the two would fight
  over the same glyph. `terminal = { backend = false }` turns the
  integration off and leaves the hooks in charge.

  `show_page` uses the same backend: markdown, HTML, pictures, URLs and
  text files open in an overlay floating over the session
  (`show_page.size` percent of it; HTML runs no scripts).

Without agterm `show_page` hands markdown, HTML, pictures (png, jpg, gif,
webp) and http(s) URLs to `vim.ui.open`, so they open in your system viewer
or browser on the machine nvim runs on, and shows any other text file in the
editor like `open_file`. A URL asks first (your browser carries your
logins; `a` stops asking for the chat), and an opener that fails, such as
`xdg-open` over ssh, is reported as an error. Nothing else ever reaches `vim.ui.open`: it would
run a script or an app instead of showing it.

## Troubleshooting

- **No `:Harner` command or keys.** `setup()` was not called: the lazy.nvim
  spec needs `opts = {}`.
- **"`claude` not found on PATH" in the chat.** The CLI is not on the `PATH` Neovim
  sees; set `claude_cmd` to its full path.
- **Authentication errors.** Run `claude` in a terminal and log in; harner
  uses the same credentials.
- **Claude says a task needs a shell.** Enable the opt-in tool with
  `bash = { enabled = true }`.
- **A connector's tools are denied.** Only servers listed in `mcp_servers`
  or `connectors` are approved, see [Extra MCP servers](#extra-mcp-servers).
- **Tables or markup look raw.** Install the `markdown` and
  `markdown_inline` treesitter parsers, or check `render` in the config.

## How it works

```
chat.lua ──send──▶ runner.lua ──vim.system──▶ claude -p --output-format stream-json
   ▲                                              │ --mcp-config <tmp.json>
   │ text deltas / tool notes                     ▼
   │                                      nvim -l bridge.lua   (MCP stdio server)
   │                                              │ RPC into the running nvim
   └──────── tools.lua (runs in your nvim) ◀──────┘
```

The MCP server is `bridge.lua`, started by the CLI with the same `nvim`
binary in `-l` mode. It forwards every tool call over RPC to the nvim that
owns the chat, where `tools.lua` runs it. Tools that wait on you or a process
(`ask_user`, `run_command`, `bash`, `write_file`, `save_file`) answer
asynchronously so the editor stays responsive.

## Development

Offline tests, run from the repo root; each ends with `ALL OK`:

```sh
nvim --headless -u NONE -l tests/bridge_test.lua   # MCP round trip, every tool
nvim --headless -u NONE -l tests/chats_test.lua    # several chats, wiped buffers, routing
nvim --headless -u NONE -l tests/prompt_test.lua   # popup and keymaps
nvim --headless -u NONE -l tests/render_test.lua   # tables, code shading, refs, gf
nvim --headless -u NONE -l tests/title_test.lua    # terminal title
nvim --headless -u NONE -l tests/confirm_test.lua  # confirm float, grants, window reuse
nvim --headless -u NONE -l tests/bash_test.lua     # opt-in shell tool, allow-list, timeout, cancel
nvim --headless -u NONE -l tests/auto_test.lua     # auto mode rules and classifier
nvim --headless -u NONE -l tests/runner_test.lua   # stream parsing against a fake claude
nvim --headless -u NONE -l tests/term_test.lua     # terminal status against a fake agtermctl
nvim --headless -u NONE -l tests/notify_test.lua   # notification escapes per terminal, focus gate
nvim --headless -u NONE -l tests/page_test.lua     # show_page: overlay per kind, fallbacks, refusals
nvim --headless -u NONE -l tests/skills_test.lua   # /skill completion: scan, init names, menu
```

A failing test exits non-zero; CI (`.github/workflows/test.yml`) runs them on
Neovim 0.10, stable and nightly. `tests/chat_test.lua` runs the full loop
against the real CLI (about two minutes, costs money). Design notes and gotchas are in `CLAUDE.md`.

## License

[MIT](LICENSE)
