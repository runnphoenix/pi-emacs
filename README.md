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
          (byte-compile-file "pi-code-theme.el") \
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
| `C-c C-a` | transient command menu |
| `C-c C-n` | new session (same process) |
| `C-c C-r` | resume a saved session |
| `C-c C-q` | stop session, kill buffer |
| `C-c C-o` | open file/URL at point |
| `C-c C-y` | copy last assistant reply |
| `M-n` / `M-p` | jump to next/previous turn |
| `TAB` | expand/collapse tool output at point |

Extension dialogs (`select`/`confirm`/`input`/`editor`) map to
`completing-read` / `y-or-n-p` / minibuffer / a pop-up edit buffer.

## Layout

- `pi-code-rpc.el` — process lifecycle, strict JSONL framing, id-correlated
  commands, event dispatch. No UI; covered by ERT.
- `pi-code-chat.el` — chat buffer, streaming renderer, input handling,
  extension dialogs.
- `pi-code.el` — customization, entry points, session resume, model menu.
- `pi-code-theme.el` — optional colour theme (`M-x load-theme RET pi-code`).
- `test/` — ERT suites. Run with:

```sh
emacs --batch -L . -L test -l ert \
  -l test/pi-code-test.el -l test/pi-code-chat-test.el \
  -l test/pi-code-rpc-test.el -l test/pi-code-render-test.el \
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
- `pi-code-show-timestamps` — clock time next to message headers
- `pi-code-show-model-name` — model name next to the assistant header
- `pi-code-tool-result-lines` — tool result lines before folding (default 15)
- `pi-code-separator-width` — max width of the turn separator rule
- `pi-code-use-org` — Org fontification at message end (default `t`);
  the master on/off switch for pi-code's own highlight passes
- `pi-code-org-max-chars` — messages longer than this skip Org
  fontification (default 100000)
- `pi-code-fold-thinking` — fold assistant thinking blocks by default
  (default `t`); `TAB` or mouse expands them
- `pi-code-inline-images` — render image results with `create-image`
  (default `t`; falls back to a text label)
- `pi-code-open-file-side-window` — open clicked files in a right side
  window instead of another window (default `nil`)
- `pi-code-code-wrap-prefix` — marker shown at the start of wrapped
  lines inside `#+begin_src`/`#+begin_example` bodies (default `"↪ "`;
  nil to disable)
- `pi-code-body-indent` — indent prepended to each user/assistant body
  line (default `"  "`; empty string disables)
- `pi-code-refresh-rules-on-resize` — resize turn separator rules to
  match the window on resize (default `t`)

## Theme

`pi-code-theme` is an optional, self-contained theme.  All chat faces
already inherit standard faces and follow the active theme; this theme
only adds a subtle background to inline/fenced code and to unified-diff
add/remove lines, so code and diffs stand out without overriding the rest:

```elisp
(add-to-list 'custom-theme-load-path
             "~/projects/emacs_code/pi-emacs")
(load-theme 'pi-code t)
```

Assistant thinking folds automatically into a `⋯ ▹ thinking · N lines
(TAB)` placeholder; long tool outputs fold the same way (`⋯ N more
lines`).  `TAB` on a `* You` / `* pi` header folds the whole turn
with Org cycling; `TAB` on a placeholder expands it.

The input prompt always stays on its own line below the streaming
answer, which shows a `▌` caret while it is being written.

## Org mode output

Every chat buffer is a real Org document (`pi-code-chat-mode` derives
from `org-mode`): turn headers are `* You` / `* pi` headings, and
assistant Org markup — emphasis, links, tables, source blocks —
renders with Org's own font-lock.  Answer headings are dedented to
column 0 and demoted one level (`*` becomes `**`, `**` becomes
`***`) so they nest under the turn headers, which own level 1 — a
real Org headline is only recognised at column 0, so this is what
makes answer headings fold (native `org-cycle`) and export to HTML
with the right nesting.  Thinking is wrapped in a
`#+begin_comment`…`#+end_comment` block, so it stays out of Org/HTML
export instead of blending into the answer.  `TAB` cycles
turn/subtree folds; `M-n` / `M-p` jump between turns.  `RET` stays a
plain newline (not `org-return`).
Because most CJK fonts ship no italic style, `/italic/` also gets an
underline (`pi-code-emphasis-face`) so emphasis stays visible on
Chinese text.  pi-code is Org-only: it no longer renders Markdown, and
there is no format switch or auto-detection.

To make the agent reply in Org, create `~/.pi/agent/APPEND_SYSTEM.md`
(global; pi discovers it automatically) with an instruction such as
"format all replies in Emacs Org mode markup, never Markdown" — see
`UI-PLAN.md` §14 for a full example.  Project-local
`<project>/.pi/APPEND_SYSTEM.md` works too (needs the project
trusted).  Restart the pi process afterwards (`pi-code-quit`, then
`M-x pi-code`); `new_session` does not re-read the system prompt.

Rendering notes: automatic refontification is off, so Org never
repaints thinking blocks or tool output by surprise — Org regions are
fontified explicitly when messages complete.  On display,
`org-code`/`org-block` reuse the code face, `org-link` the link face,
and `org-block` keyword lines the meta face (see
`face-remapping-alist` in `pi-code-chat-mode`); text properties still
hold native Org faces.  Emphasis next to Chinese text (`/类地行星/：`,
`是*粗体*的`) works via buffer-local Org emphasis sets — global Org
state is untouched.  Note: emphasis adjacent to CJK punctuation
(`~code~，`) needs the boundary sets extended with `[:nonascii:]`
globally, and Org's *export* parser
(`org-element--parse-generic-emphasis`) has hard-coded ASCII
boundaries, so exporting such `.org` files also needs an override —
see the example in `~/.emacs` / `UI-PLAN.md` §22.  Tables are
auto-aligned in place (`#+begin_src` bodies excluded).  `#+begin_src`/`#+begin_example` bodies get the
`↪` wrap marker, and indented headlines/bullets are faced directly
(Org headlines must start at column 0, which chat indentation
prevents, so pi-code faces them itself).

## Not yet implemented

Session fork/tree browser, edit diff overlays, `@file`/region references,
file-change auto-revert.
