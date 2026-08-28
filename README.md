# muxim

[![ci](https://github.com/Jonathan-Rowles/muxim/actions/workflows/ci.yml/badge.svg)](https://github.com/Jonathan-Rowles/muxim/actions/workflows/ci.yml)

Every project runs as a Neovim server; your visible Neovim is a client attached to one. Detach and nothing dies: buffers, undo history, warm language servers and running jobs are all there when you reattach. A tmux-style prefix drives tabs as windows and splits as panes.

This lived in my Neovim config for a few months, changed with Claude as I worked, and seemed worth sharing. It stands on 0.12's `:connect` and `:detach`; 0.13 targets native session listing, and when core ships a piece of this, muxim adopts it and deletes its own.

![muxim demo](assets/demo.gif)

## Why not just tmux

- **Panes share one language server.** A pane is a Neovim window, not a separate editor process.
- **Killing cannot eat unsaved work.** Kill runs `qall` and refuses if anything is modified; force-kill lists the buffers first. tmux SIGHUPs.
- **Agent state is reported, not guessed.** `working`, `blocked`, `done` come from the agent's own hooks; a blocked agent anywhere in the fleet is one keypress away.

## Install

Neovim 0.12+, Linux or macOS.

```lua
-- lazy.nvim
{ 'Jonathan-Rowles/muxim' }
```

No `setup()` call needed; the one option most people change is `prefix = '<C-a>'`.

## Use

Run `nvim` in a project directory; that project is now a session. `<prefix>d` detaches, `<prefix>s` gets you back from anywhere. A session that has never detached is an ordinary foreground process and ends with its window; sessions spawned from the picker are detached from the start.

| Keys | Action | Native equivalent |
| --- | --- | --- |
| `<prefix>c` | new window (tab with a terminal) | `:tabnew` + `:terminal` |
| `<prefix>n` / `p` / `l` | next / previous / last window | `:tabnext` / `:tabprevious` / `:tabnext #` |
| `<prefix>1`..`9` | select window N | `:tabnext N` |
| `<prefix>,` | rename window | muxim |
| `<prefix>&` | kill window | `:tabclose`, guarded |
| `<prefix>o` / `;` / arrows | move between panes | `:wincmd w` / `p` / `h j k l` |
| `<prefix>x` | kill pane | `:close`, guarded |
| `<prefix>z` | zoom pane | `wincmd _` / `\|`, layout restored |
| `<prefix><M-arrows>` | resize pane | `:resize` / `:vertical resize` |
| `<prefix>[` | copy mode (terminal-normal mode) | `<C-\><C-n>` |
| `<prefix>t` | toggle this tab's terminal | muxim |
| `<prefix>w` | choose window, across every session | muxim |
| `<prefix>s` | choose session, live or not | muxim |
| `<prefix>d` | detach | `:detach` |
| `<prefix>R` | set tab root from the focused terminal | `:tcd` |
| `<prefix>a` | agent drawer | muxim |
| `<prefix>A` | go to a blocked agent | muxim |
| `<prefix>C` | new window running an agent | muxim |
| `<prefix>?` | cheatsheet | muxim |
| `<prefix><prefix>` | send the prefix through | |

Every binding is a real keymap, visible to `:map` and which-key. No split binding: `<C-w>s` already exists. Movement is bound because Neovim ships no terminal-mode mappings at all. Customize with `keys = { g = { fn, 'desc' }, x = false }`. Typing `nvim file` inside a muxim terminal opens it in the session instead of nesting an editor.

## Options

```lua
require('muxim').setup({
  prefix = '<C-b>',
  keys = {},                      -- extra/overriding bindings, or false for none
  tabline = {},                   -- tabline options, or false to keep yours
  picker = nil,                   -- 'telescope' | 'select' | custom table; auto-detects
  projects = {},                  -- dirs the session picker offers even when nothing is running
  nested = false,                 -- allow setup() inside another session's :terminal
  on_last_close = nil,            -- closing the last pane; default offers Quit / Detach / Cancel
  remain_on_exit = false,         -- keep windows of exited terminals open
  adopt_foreign_terminals = false, -- manage :terminal buffers the plugin did not open
  keep_busy_terminals = true,      -- reaping spares terminals with a running foreground job
  follow_terminal_cwd = false,    -- tab root follows the terminal's cwd automatically
  enter_insert = false,           -- entering a managed terminal enters terminal mode
  on_terminal_hide = nil,         -- where toggle() sends you when the window has no alternate
  agents = {},                    -- agent watching; see :h muxim-agents, or false for none
})
```

## Agents

State comes only from the agent's own hooks; existence comes from the process table. An agent that has not reported shows as `running`, and muxim never guesses from terminal output. `<prefix>C` opens an agent already wired to report. For agents you type at a shell prompt, one line in your shell rc, after anything that sets `PATH`:

```sh
[ -n "$MUXIM_SHELL_INIT" ] && . "$MUXIM_SHELL_INIT"
```

The same line keeps muxim's `nvim` wrapper winning `PATH` when your rc rebuilds it. That is only the fast path: without it a nested `nvim` still hands its files over and exits, after a full startup. The generated file is POSIX sh (bash and zsh); on fish, skip the line and wire typed agents with `:MuximAgentSetup` instead.

Anything with lifecycle hooks can report: `"$MUXIM_HOOK" <state> <detail> <name>`.

## Tricks

Per-pane state from my config: shells write pid-keyed files, `require('muxim.terminal').pid()` reads the focused pane's. My tabline shows the focused terminal's AWS profile; a `TabEnter` hook points each tab's vim-dadbod at whatever database its own terminal logged into.

## More

`:h muxim` covers the rest: commands, events, tabline sections, tab roots, the picker API, FAQ. `:MuximInfo` is the one command to paste into an issue.
