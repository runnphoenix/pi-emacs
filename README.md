# pi-code.el

Emacs frontend for the [pi coding agent](https://pi.dev), in the spirit of
Claude Code's IDE integration and opencode's client mode.

The agent runs as a subprocess in RPC mode (`pi --mode rpc`, JSON lines
over stdin/stdout). Emacs is purely the UI: chat buffer, streaming
transcript, session management. All agent logic (tools, models,
compaction, sessions, extensions) stays inside the pi process.

Protocol reference: pi's `packages/coding-agent/docs/rpc.md`;
reference client: `packages/coding-agent/src/modes/rpc/rpc-client.ts`.

## Install

Requires the `pi` CLI on PATH and Emacs 30+.

```elisp
(add-to-list 'load-path "~/projects/emacs_code/pi-emacs")
(require 'pi-code)
```

Byte-compile for speed:

```sh
emacs --batch -L . --eval \
  '(progn (byte-compile-file "pi-code-rpc.el") \
          (byte-compile-file "pi-code-chat.el") \
          (byte-compile-file "pi-code.el"))'
```

## Usage

- `M-x pi-code` — open (or start) the chat for the current project
- `M-x pi-code-resume` — reopen a saved session for the current project

Chat buffer keys:

| Key | Action |
|---|---|
| `C-c C-c` | send input, or abort while working |
| `C-c C-s` | steer (queue a message mid-run) |
| `C-c C-k` | abort |
| `C-c C-m` | switch model |
| `C-c C-t` | set thinking level |
| `C-c C-n` | new session (same process) |
| `C-c C-r` | resume a saved session |
| `C-c C-q` | stop session, kill buffer |

Extension dialogs (`select`/`confirm`/`input`/`editor`) map to
`completing-read` / `y-or-n-p` / minibuffer / a pop-up edit buffer.

## Layout

- `pi-code-rpc.el` — process lifecycle, strict JSONL framing, id-correlated
  commands, event dispatch. No UI; covered by ERT.
- `pi-code-chat.el` — chat buffer, streaming renderer, input handling,
  extension dialogs.
- `pi-code.el` — customization, entry points, session resume, model menu.
- `test/` — ERT suites. Run with:

```sh
emacs --batch -L . -l test/pi-code-test.el \
  -l test/pi-code-chat-test.el -l test/pi-code-rpc-test.el \
  -f ert-run-tests-batch-and-exit
```

## Troubleshooting

### `M-x pi-code` fails with `No such file or directory, pi`

Emacs inherits `PATH` from whatever launched it, which often differs from
an interactive shell (e.g. a desktop launcher never sources `.bashrc`).
Add pi's bin directory to **both** `exec-path` (how Emacs finds programs)
and the `PATH` environment variable:

```elisp
(let ((bin (expand-file-name "~/.local/share/pi-node/current/bin")))
  (when (file-directory-p bin)
    (add-to-list 'exec-path bin)
    (setenv "PATH" (concat bin path-separator (getenv "PATH")))))
```

### pi exits immediately with `SyntaxError ... node:fs ... globSync`

The `pi` launcher's shebang is `#!/usr/bin/env node`, so the **child
process** resolves `node` through the `PATH` environment variable — not
through Emacs's `exec-path`. If an older system Node (< 22) shadows the
Node bundled with pi-node, pi crashes on startup. The `setenv` above
ensures the bundled Node 22 is found first. The agent's stderr (including
this error) is available in the `*pi-code-stderr:<name>*` buffer.

## Customization

- `pi-code-executable` — path to the pi CLI (default `"pi"`)
- `pi-code-program-args` — extra CLI args, e.g.
  `("--provider" "anthropic")`
- `pi-code-sessions-root` — session storage (default
  `~/.pi/agent/sessions`)

## Not yet implemented

Image attachments, `@file`/region references, edit diff overlays,
compact menu, session fork/tree browser, transient menu, file-change
auto-revert.
