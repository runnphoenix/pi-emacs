;;; pi-code-chat.el --- Chat buffer UI for the pi coding agent -*- lexical-binding: t; -*-

;;; Commentary:

;; One chat buffer per RPC session.  History before
;; `pi-code--history-end' is read-only; the tail is the input area.
;; Agent events from `pi-code-rpc' are rendered incrementally:
;; text/thinking deltas append at the marker, tool progress blocks are
;; replaced in place, and usage/stats refresh the header line.

;;; Code:

(require 'pi-code-rpc)
(require 'subr-x)
(require 'base64)
(require 'image nil t)
;; Chat buffers are real Org documents (native rendering and folding),
;; and Org ships with Emacs, so require it unconditionally.
(require 'org)

;; NOTE: evil-define-key is a macro, so it cannot be called at runtime.
;; evil-define-key* is its function counterpart and is safe here.
(declare-function evil-define-key* "evil-core" t t)

;;; Customization

(defcustom pi-code-show-timestamps nil
  "When non-nil, show a clock time next to each message header."
  :type 'boolean
  :group 'pi-code)

(defcustom pi-code-tool-result-lines 15
  "Tool result lines shown before the rest is folded away.
Set to nil to always show the full result."
  :type '(choice (integer :tag "Lines") (const :tag "Unlimited" nil))
  :group 'pi-code)

(defcustom pi-code-separator-width 80
  "Maximum width of the turn separator rule."
  :type 'integer
  :group 'pi-code)

(defcustom pi-code-fold-thinking t
  "When non-nil, fold thinking blocks; TAB or mouse expands them."
  :type 'boolean
  :group 'pi-code)

(defcustom pi-code-show-model-name t
  "When non-nil, show the model name next to the assistant header."
  :type 'boolean
  :group 'pi-code)

(defcustom pi-code-use-org t
  "When non-nil, fontify assistant text as Org at message end.
The chat buffer is a real Org document; this controls the explicit
fontify/align pass run when a message completes (headlines, tables,
emphasis, src blocks).  Streaming deltas stay plain text either way.
The agent side is configured separately, e.g. in
~/.pi/agent/APPEND_SYSTEM.md."
  :type 'boolean
  :group 'pi-code)

(defcustom pi-code-org-max-chars 100000
   "Messages longer than this skip Org fontification."
  :type 'integer
  :group 'pi-code)

(defcustom pi-code-inline-images t
  "When non-nil, render image tool results inline with `create-image'."
  :type 'boolean
  :group 'pi-code)

(defcustom pi-code-open-file-side-window nil
  "When non-nil, open files clicked in chat in a side window."
  :type 'boolean
  :group 'pi-code)

(defcustom pi-code-refresh-rules-on-resize t
  "When non-nil, resize separator rules to match the window width."
  :type 'boolean
  :group 'pi-code)

(defcustom pi-code-code-wrap-prefix "↪ "
  "Marker shown at the start of wrapped lines inside fenced code blocks.
Set to nil to fall back to plain wrapping."
  :type '(choice (string :tag "Marker") (const :tag "Off" nil))
  :group 'pi-code)

(defcustom pi-code-body-indent "  "
  "Indent prepended to each user/assistant body line.
Matches the tool/thinking block indent so turns read as one level.
An empty string disables body indentation."
  :type 'string
  :group 'pi-code)

;;; Faces

(defface pi-code-user-face
  '((t :inherit font-lock-keyword-face :weight bold :extend t))
  "Face for the user prompt header."
  :group 'pi-code)

(defface pi-code-assistant-face
  '((t :inherit font-lock-function-name-face :weight bold :extend t))
  "Face for the assistant header."
  :group 'pi-code)

(defface pi-code-banner-face
  '((t :inherit font-lock-constant-face :weight bold :extend t))
  "Face for the welcome banner."
  :group 'pi-code)

(defface pi-code-separator-face
  '((t :inherit shadow :extend t))
  "Face for turn separator rules."
  :group 'pi-code)

(defface pi-code-thinking-face
  '((t :inherit shadow :slant italic))
  "Face for streamed thinking/reasoning text."
  :group 'pi-code)

(defface pi-code-thinking-label-face
  '((t :inherit shadow :weight bold))
  "Face for the `thinking' label."
  :group 'pi-code)

(defface pi-code-emphasis-face
  '((t :inherit italic :underline t))
  "Face for Org `/italic/' emphasis in chat buffers.
CJK fonts rarely ship an italic style, so a bare slant is invisible
on Chinese text; the underline keeps the emphasis legible."
  :group 'pi-code)

(defface pi-code-tool-face
  '((t :inherit font-lock-builtin-face :weight bold))
  "Face for tool call lines."
  :group 'pi-code)

(defface pi-code-tool-args-face
  '((t :inherit shadow))
  "Face for pretty-printed tool arguments."
  :group 'pi-code)

(defface pi-code-tool-key-face
  '((t :inherit font-lock-variable-name-face :weight bold))
  "Face for tool argument keys."
  :group 'pi-code)

(defface pi-code-tool-result-face
  '((t :inherit default))
  "Face for tool result bodies.
Kept at normal contrast by default so command output stays readable."
  :group 'pi-code)

(defface pi-code-error-face
  '((t :inherit error :weight bold))
  "Face for errors and aborted notices."
  :group 'pi-code)

(defface pi-code-meta-face
  '((t :inherit shadow))
  "Face for meta lines (stats, notices)."
  :group 'pi-code)

(defface pi-code-header-brand-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for the brand segment of the header line."
  :group 'pi-code)

(defface pi-code-header-model-face
  '((t :inherit bold))
  "Face for the model name in the header line."
  :group 'pi-code)

(defface pi-code-header-busy-face
  '((t :inherit warning :weight bold))
  "Face for the working indicator in the header line."
  :group 'pi-code)

(defface pi-code-prompt-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the input area prompt."
  :group 'pi-code)

(defface pi-code-code-face
  '((t :inherit fixed-pitch :extend t))
  "Face for inline code and fenced code block bodies.
Deliberately does not inherit `highlight', whose default is an
inverse-video or green background.  `pi-code-theme' adds a subtle
background instead."
  :group 'pi-code)

(defface pi-code-diff-add-face
  '((t :inherit diff-added :extend t))
  "Face for added lines in unified diffs."
  :group 'pi-code)

(defface pi-code-diff-del-face
  '((t :inherit diff-removed :extend t))
  "Face for removed lines in unified diffs."
  :group 'pi-code)

(defface pi-code-diff-file-face
  '((t :inherit (font-lock-type-face bold) :extend t))
  "Face for file-level lines in a unified diff (diff --git, ---, +++)."
  :group 'pi-code)

(defface pi-code-file-link-face
  '((t :inherit link))
  "Face for clickable file paths and URLs."
  :group 'pi-code)

;;; Buffer-local state

(defvar-local pi-code--session nil "RPC session for this chat buffer.")
(defvar-local pi-code--session-name nil "Display name of this chat's session.")
(defvar-local pi-code--folds nil "Live fold overlays in this chat buffer.")
(defvar-local pi-code--history-end nil "Marker: end of rendered history.")
(defvar-local pi-code--input-active nil
  "Non-nil while an input prompt follows `pi-code--history-end'.")
(defvar-local pi-code--caret-ov nil
  "Overlay showing the streaming caret, or nil.")
(defvar-local pi-code--last-turn-role nil
  "Role of the most recently rendered turn, for separator decisions.")
(defvar-local pi-code--live-start nil "Marker: start of live-replaced block, or nil.")
(defvar-local pi-code--streaming-p nil "Non-nil while the agent is streaming.")
(defvar-local pi-code--streamed-current nil "Non-nil if current message got deltas.")
(defvar-local pi-code--last-index nil "Last contentIndex seen in message_update.")
(defvar-local pi-code--pending-echo nil "Optimistically rendered user text awaiting echo.")
(defvar-local pi-code--echoed-user nil "User text consumed by message_start echo.")
(defvar-local pi-code--assistant-open nil "Non-nil if * pi header was emitted for current message.")
(defvar-local pi-code--stats nil "Last get_session_stats data plist.")
(defvar-local pi-code--ext-status nil
  "Alist of (STATUS-KEY . TEXT) from extension setStatus requests.")
(defvar-local pi-code--widgets nil
  "Alist of (WIDGET-KEY START-MARKER . END-MARKER) for setWidget blocks.")
(defvar-local pi-code--queue nil
  "Cons (STEERING . FOLLOW-UP) of queued message counts from queue_update.")
(defvar-local pi-code--last-reply nil
  "Plain text of the most recently completed assistant message.")
(defvar-local pi-code--streamed-text nil
  "Accumulated text of the assistant message currently streaming.")
(defvar-local pi-code--msg-start nil
  "Marker: start of the current assistant message text, or nil.")
(defvar-local pi-code--thinking-start nil
  "Marker: start of the thinking body currently streaming, or nil.")
(defvar-local pi-code--thinking-block-start nil
  "Marker: start of the current `#+begin_quote' thinking block, or nil.")
(defvar-local pi-code--spinner-index 0
  "Current spinner frame index for this chat buffer.")

(defvar pi-code--spinner-timer nil
  "Global timer animating spinners in streaming chat buffers.")

(defconst pi-code--spinner-frames ["◐" "◓" "◑" "◒"]
  "Spinner glyphs cycled while the agent is working.")

(defconst pi-code--input-prompt "> "
  "Prefix shown at the start of the input area.")

(defconst pi-code--tool-icons
  '(("bash" . "$")
    ("read" . "≡")
    ("write" . "✎")
    ("edit" . "✎")
    ("grep" . "⌕")
    ("search" . "⌕")
    ("find" . "⌕")
    ("glob" . "⌕"))
  "Mapping of lowercase tool names to prefix glyphs.
Tools not listed here keep the plain ▸ marker.")

(defconst pi-code--url-re "https?://[^[:space:]()\"'<>]+"
  "Regexp matching http(s) URLs.")

(defconst pi-code--file-path-re
  "\\(?:\\`\\|[[:space:]()\\[{}\"',;:]\\)\\(\\(?:\\./\\|~/\\|/\\)[^[:space:]()\\[{}\"',;]+\\)"
  "Regexp matching candidate file paths; group 1 is the path.
Only paths that actually exist are turned into buttons.")

(defconst pi-code--display-cap 30000
  "Max chars of one tool result block shown; beyond this it is cut.")

;;; Mode

(defun pi-code--set-org-cjk-emphasis ()
  "Enable Org emphasis next to CJK text in the current buffer.
Stock Org only allows ASCII prematch/postmatch around emphasis
markers, so `/类地行星/：` or `是*粗体*的` never fontify.  Extend
both sets buffer-locally with `[:nonascii:]' (covering CJK
punctuation and letters, still excluding ASCII letters/digits so
`/usr/bin' and `a=b' keep working) and recompute the buffer-local
`org-emph-re' and `org-verbatim-re' with Org's own
`org-set-emph-re'.  Global state is saved and restored around the
call, so other Org buffers are unaffected."
  (let* ((comps org-emphasis-regexp-components)
         ;; Idempotent: a user who already extended the global sets
         ;; (see ~/.emacs) must not get `[:nonascii:]' appended twice.
         (extended (if (string-match-p "\\[:nonascii:\\]" (nth 0 comps))
                       comps
                     (list (concat (nth 0 comps) "[:nonascii:]")
                           (concat (nth 1 comps) "[:nonascii:]")
                           (nth 2 comps)
                           (nth 3 comps)
                           (nth 4 comps))))
         (save-comps (default-value 'org-emphasis-regexp-components))
         (save-emph org-emph-re)
         (save-verb org-verbatim-re)
         new-emph new-verb)
    ;; `org-set-emph-re' writes the toplevel default and the global
    ;; regexps as a side effect; capture the computed values locally,
    ;; then put everything back before any fontification can run.
    (org-set-emph-re 'org-emphasis-regexp-components extended)
    (setq new-emph org-emph-re
          new-verb org-verbatim-re)
    (set-default-toplevel-value 'org-emphasis-regexp-components
                                save-comps)
    (setq org-emph-re save-emph
          org-verbatim-re save-verb)
    (setq-local org-emphasis-regexp-components extended)
    (setq-local org-emph-re new-emph)
    (setq-local org-verbatim-re new-verb)))

(defvar pi-code-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'pi-code-send-or-abort)
    (define-key map (kbd "C-c C-k") #'pi-code-abort)
    (define-key map (kbd "C-c C-s") #'pi-code-steer)
    (define-key map (kbd "C-c C-o") #'pi-code-open-file-at-point)
    (define-key map (kbd "C-c C-y") #'pi-code-copy-last-reply)
    (define-key map (kbd "M-n") #'pi-code-next-turn)
    (define-key map (kbd "M-p") #'pi-code-previous-turn)
    (define-key map (kbd "TAB") #'pi-code-toggle-fold)
    ;; Keep RET a plain newline: Org would otherwise run `org-return'
    ;; (list continuation, structure edits) in the input area.
    (define-key map (kbd "RET") #'newline)
    map)
  "Keymap for `pi-code-chat-mode'.")

(define-derived-mode pi-code-chat-mode org-mode "pi-code"
  "Major mode for chatting with the pi coding agent.
The whole buffer is a real Org document: assistant Org markup,
links, tables and source blocks render with Org's own font-lock,
and `* You' / `* pi' turn headers fold with TAB.
Automatic refontification is off (`font-lock-support-mode' is nil);
Org regions are fontified explicitly when messages complete, so
thinking blocks and tool output keep their faces."
  :group 'pi-code
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; No JIT: only explicit `font-lock-fontify-region' calls fontify,
  ;; so Org never repaints our chrome by surprise.
  (setq-local font-lock-support-mode nil)
  ;; Emphasis next to CJK text (e.g. `/类地行星/：`) is invisible to
  ;; stock Org: its prematch/postmatch sets lack non-ASCII.  Extend
  ;; them buffer-locally; `org-do-emphasis-faces' reads the components
  ;; (candidate scan) and `org-emph-re'/`org-verbatim-re' (validation)
  ;; dynamically, so buffer-local values just work, globally untouched.
  (pi-code--set-org-cjk-emphasis)
  ;; `/italic/' gets an underline so CJK emphasis stays visible even
  ;; though Noto Sans Mono CJK (and most CJK fonts) have no italic
  ;; glyph.  Based on the global alist so other markers are untouched.
  (setq-local org-emphasis-alist
              (cons '("/" pi-code-emphasis-face)
                    (assq-delete-all "/" (copy-sequence org-emphasis-alist))))
  ;; Keep the chat theme: Org constructs reuse pi-code faces on display.
  ;; (Text properties still hold native Org faces; see README.)
  (setq-local face-remapping-alist
              '((org-code pi-code-code-face)
                (org-verbatim pi-code-code-face)
                (org-block pi-code-code-face)
                (org-link pi-code-file-link-face)
                (org-meta-line pi-code-meta-face)
                (org-block-begin-line pi-code-meta-face)
                (org-block-end-line pi-code-meta-face))))

(defun pi-code--chat-evil-bindings ()
  "Apply chat keys to evil normal/insert states."
  (evil-define-key* '(normal insert) pi-code-chat-mode-map
    (kbd "C-c C-c") #'pi-code-send-or-abort
    (kbd "C-c C-k") #'pi-code-abort
    (kbd "C-c C-s") #'pi-code-steer
    (kbd "C-c C-o") #'pi-code-open-file-at-point
    (kbd "C-c C-y") #'pi-code-copy-last-reply
    (kbd "TAB") #'pi-code-toggle-fold))

(defun pi-code--maybe-bind-evil ()
  "Apply evil bindings now or when evil loads."
  (if (featurep 'evil)
      (pi-code--chat-evil-bindings)
    (with-eval-after-load 'evil #'pi-code--chat-evil-bindings)))

(pi-code--maybe-bind-evil)

;;; Low-level insertion

(defun pi-code--maintain-input-separator ()
  "Keep the input prompt on a line of its own after history insertions.
`pi-code--history-end' is left just before the separator newline so
later insertions stay contiguous.  No-op when there is no input area."
  (when (and pi-code--input-active pi-code--history-end)
    (save-excursion
      (goto-char pi-code--history-end)
      (let ((inhibit-read-only t))
        (cond
         ;; The content already ends in a newline: drop a stale separator.
         ((and (bolp) (looking-at "\n"))
          (delete-region (point) (1+ (point))))
         ;; The prompt would land mid-line: open a fresh line for it.
         ((and (not (bolp)) (not (looking-at "\n")))
          (insert "\n")))))))

(defun pi-code--caret-update ()
  "Show the streaming caret at the current history end."
  (when (and pi-code--streaming-p pi-code--history-end
             (marker-position pi-code--history-end))
    (let ((pos (marker-position pi-code--history-end)))
      (unless (overlayp pi-code--caret-ov)
        (setq pi-code--caret-ov (make-overlay pos pos nil t t)))
      (move-overlay pi-code--caret-ov pos pos)
      (overlay-put pi-code--caret-ov 'after-string
                   (propertize "▌" 'face 'pi-code-header-busy-face)))))

(defun pi-code--caret-hide ()
  "Remove the streaming caret."
  (when (overlayp pi-code--caret-ov)
    (delete-overlay pi-code--caret-ov))
  (setq pi-code--caret-ov nil))

(defun pi-code--insert (text &rest props)
  "Insert TEXT with PROPS at history end, keeping it read-only.
The rear boundary stays writable so the input area can follow.
The history marker does not follow user typing (insertion-type
nil); it is advanced explicitly here.
Return the (START . END) region that was written."
  (let ((inhibit-read-only t)
        region)
    (save-excursion
      (goto-char pi-code--history-end)
      (setq region (cons (point)
                         (+ (point) (length text))))
      (insert (apply #'propertize text
                     'read-only t 'rear-nonsticky t props))
      (set-marker pi-code--history-end (point))
      (pi-code--maintain-input-separator))
    region))

(defun pi-code--fresh-line ()
  "Insert a newline at history end unless already at a fresh line.
Keeps blocks separated by exactly one line break, never a blank."
  (save-excursion
    (goto-char pi-code--history-end)
    (unless (bolp)
      (pi-code--insert "\n"))))

(defun pi-code--finalize-block ()
  "End any live-replaced block."
  (setq pi-code--live-start nil))

(defun pi-code--replace-live (text &rest props)
  "Replace the live block (or start one) with TEXT.
Return the (START . END) region that was written."
  (let ((inhibit-read-only t))
    (unless pi-code--live-start
      (setq pi-code--live-start (copy-marker pi-code--history-end nil)))
    (delete-region pi-code--live-start (marker-position pi-code--history-end))
    (goto-char pi-code--live-start)
    (insert (apply #'propertize text 'read-only t 'rear-nonsticky t props))
    (set-marker pi-code--history-end (point))
    (pi-code--maintain-input-separator)
    (cons pi-code--live-start (point))))

;;; Presentation helpers

(defconst pi-code--tool-result-prefix "  └ "
  "Prefix for the first line of a tool result body.")

(defconst pi-code--thinking-indent "  "
  "Indent shared by the thinking label, body and fold placeholder.")

(defconst pi-code--thinking-label "▹ thinking"
  "Text of the thinking label.")

(defun pi-code--rule-string ()
  "Return a horizontal rule sized to the current window."
  (let ((width (condition-case nil (window-body-width) (error 80))))
    (make-string (max 24 (min pi-code-separator-width (or width 80))) ?─)))

(defun pi-code--refresh-rules ()
  "Resize existing separator rules in this buffer to the window width."
  (when (derived-mode-p 'pi-code-chat-mode)
    (let ((width (max 24 (min pi-code-separator-width
                              (or (window-body-width) 80))))
          (inhibit-read-only t))
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (while (re-search-forward "^─+$" nil t)
            (let ((beg (match-beginning 0))
                  (end (match-end 0)))
              (unless (= (- end beg) width)
                (let ((face (or (get-text-property beg 'face)
                                'pi-code-separator-face)))
                  (delete-region beg end)
                  (goto-char beg)
                  (insert (propertize (make-string width ?─)
                                      'read-only t 'rear-nonsticky t
                                      'face face)))))))))))

(defun pi-code--refresh-all-rules (&rest _)
  "Refresh separator rules in every chat buffer."
  (when pi-code-refresh-rules-on-resize
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (derived-mode-p 'pi-code-chat-mode)
          (condition-case nil (pi-code--refresh-rules) (error nil)))))))

(add-hook 'window-size-change-functions #'pi-code--refresh-all-rules)

(defun pi-code--timestamp ()
  "Return a short clock time string, or nil when timestamps are disabled."
  (when pi-code-show-timestamps
    (format-time-string " [%H:%M]")))

(defun pi-code--indent-lines (text first-prefix continuation-prefix)
  "Prefix the first line of TEXT with FIRST-PREFIX.
Remaining lines get CONTINUATION-PREFIX."
  (let ((lines (split-string (or text "") "\n")))
    (concat first-prefix (or (car lines) "")
            (mapconcat (lambda (line)
                         (concat "\n" continuation-prefix line))
                       (cdr lines) ""))))

(defun pi-code--tool-glyph (name)
  "Return the prefix glyph for tool NAME, defaulting to ▸."
  (or (and (stringp name)
           (cdr (assoc-string (downcase name) pi-code--tool-icons)))
      "▸"))

(defun pi-code--insert-body-text (text)
  "Insert TEXT at history end, indenting each body line.
Every line starts with `pi-code-body-indent'; wrapped display
lines use it as `wrap-prefix'.  A trailing newline gains no
trailing spaces, and empty TEXT inserts nothing."
  (unless (string-empty-p (or text ""))
    (let* ((indent pi-code-body-indent)
           (fresh (save-excursion
                    (goto-char pi-code--history-end)
                    (bolp)))
           (ends-with-nl (string-suffix-p "\n" text))
           (core (if ends-with-nl (substring text 0 -1) text))
           (body (replace-regexp-in-string "\n" (concat "\n" indent)
                                           core t t)))
      (pi-code--insert (concat (when (and fresh (not (string-empty-p core)))
                                 indent)
                               body
                               (when ends-with-nl "\n"))
                       'wrap-prefix indent))))

(defun pi-code--insert-user (text)
  "Insert a user turn: separator rule, header and TEXT.
Back-to-back user messages share one separator."
  (pi-code--fresh-line)
  (unless (eq pi-code--last-turn-role 'user)
    (pi-code--insert (concat (pi-code--rule-string) "\n")
                     'face 'pi-code-separator-face))
  (pi-code--insert "* You" 'face 'pi-code-user-face)
  (when-let ((ts (pi-code--timestamp)))
    (pi-code--insert ts 'face 'pi-code-meta-face))
  (pi-code--insert "\n")
  (pi-code--insert-body-text (concat (string-trim-right text) "\n"))
  (setq pi-code--last-turn-role 'user))

(defun pi-code--insert-assistant-header ()
  "Insert the assistant message header, with the model name when enabled."
  (pi-code--fresh-line)
  (pi-code--insert "* pi" 'face 'pi-code-assistant-face)
  (when pi-code-show-model-name
    (pi-code--insert (concat " · " (pi-code--model-name))
                     'face 'pi-code-meta-face))
  (when-let ((ts (pi-code--timestamp)))
    (pi-code--insert ts 'face 'pi-code-meta-face))
  (pi-code--insert "\n")
  (setq pi-code--last-turn-role 'assistant))

(defun pi-code--insert-thinking-label ()
  "Open a `#+begin_comment' thinking block and insert its label line.
The comment wrapper keeps the thinking out of Org/HTML export while
it stays visible and foldable in the chat buffer."
  (setq pi-code--thinking-block-start
        (copy-marker (marker-position pi-code--history-end) nil))
  (pi-code--insert (concat pi-code--thinking-indent "#+begin_comment\n")
                   'face 'pi-code-meta-face)
  (pi-code--insert (concat pi-code--thinking-indent pi-code--thinking-label "\n")
                   'face 'pi-code-thinking-label-face)
  (setq pi-code--thinking-start
        (copy-marker (marker-position pi-code--history-end) nil)))

(defun pi-code--close-thinking-block ()
  "Close the open thinking block with a `#+end_comment' line."
  (pi-code--fresh-line)
  (pi-code--insert (concat pi-code--thinking-indent "#+end_comment\n")
                   'face 'pi-code-meta-face))

(defun pi-code--thinking-delta (text)
  "Indent literal newlines in thinking TEXT so the body stays indented."
  (replace-regexp-in-string "\n" (concat "\n" pi-code--thinking-indent)
                            (or text "")))

(defun pi-code--insert-thinking (text)
  "Insert a labelled quote-wrapped thinking block, folded by default."
  (pi-code--fresh-line)
  (pi-code--insert-thinking-label)
  (let ((body (string-trim-right (or text ""))))
    (unless (string-empty-p body)
      (pi-code--insert
       (pi-code--indent-lines (concat body "\n")
                              pi-code--thinking-indent
                              pi-code--thinking-indent)
       'face 'pi-code-thinking-face
       'wrap-prefix pi-code--thinking-indent)))
  (pi-code--trim-thinking-tail)
  (let ((lines (max 1 (count-lines (marker-position pi-code--thinking-start)
                                   (marker-position pi-code--history-end)))))
    (pi-code--close-thinking-block)
    (pi-code--fold-thinking-block lines))
  (pi-code--disarm-thinking))

(defun pi-code--fold-thinking-block (lines)
  "Fold the quote-wrapped thinking block, reporting LINES of body.
The whole `#+begin_quote'...`#+end_quote' block is hidden so only
the placeholder shows; LINES counts the body alone, not the label
or the two keyword lines."
  (when (and pi-code-fold-thinking
             (markerp pi-code--thinking-block-start)
             (marker-position pi-code--thinking-block-start))
    (let ((start (marker-position pi-code--thinking-block-start))
          (end (marker-position pi-code--history-end)))
      (when (< start end)
        (pi-code--make-fold start end (max 1 lines)
                            pi-code--thinking-indent "▹ thinking")))))

(defun pi-code--disarm-thinking ()
  "Drop the pending streamed thinking markers without folding."
  (when (markerp pi-code--thinking-start)
    (set-marker pi-code--thinking-start nil))
  (when (markerp pi-code--thinking-block-start)
    (set-marker pi-code--thinking-block-start nil))
  (setq pi-code--thinking-start nil
        pi-code--thinking-block-start nil))

(defun pi-code--trim-thinking-tail ()
  "Drop indentation left at the end of a streamed thinking body.
A delta ending in a newline inserts the next line's indent eagerly;
if the block ends there, that indent would count as a phantom line."
  (when (and pi-code--thinking-start
             (marker-position pi-code--thinking-start))
    (let ((start (marker-position pi-code--thinking-start))
          (end (marker-position pi-code--history-end)))
      (when (< start end)
        (save-excursion
          (goto-char end)
          (skip-chars-backward " \t\n" start)
          (when (< (point) end)
            (let ((inhibit-read-only t)
                  (new (point)))
              (delete-region new end)
              (set-marker pi-code--history-end new))))))))

(defun pi-code--finish-thinking ()
  "Fold the pending streamed thinking body, if any.
A no-op when no thinking block is open, so callers can call this
unconditionally before starting text or a tool call."
  (when pi-code--thinking-start
    (pi-code--trim-thinking-tail)
    (let ((lines (max 1 (count-lines (marker-position pi-code--thinking-start)
                                     (marker-position pi-code--history-end)))))
      (pi-code--close-thinking-block)
      (pi-code--fold-thinking-block lines))
    (pi-code--disarm-thinking)
    (pi-code--fresh-line)))

(defun pi-code--plist-pairs (plist)
  "Return PLIST as a list of (KEY . VALUE) pairs, preserving order."
  (let (pairs)
    (while (consp plist)
      (let ((key (pop plist)))
        (push (cons key (pop plist)) pairs)))
    (nreverse pairs)))

(defun pi-code--arg-key-string (key)
  "Render plist KEY as a plain name without the leading colon."
  (let ((name (cond ((keywordp key) (substring (symbol-name key) 1))
                    ((symbolp key) (symbol-name key))
                    (t (format "%s" key)))))
    name))

(defun pi-code--arg-value-string (value)
  "Render a tool argument VALUE as a short string."
  (cond
   ((null value) "null")
   ((eq value t) "true")
   ((stringp value) value)
   ((numberp value) (number-to-string value))
   ((symbolp value) (symbol-name value))
   (t (pi-code--one-line (json-encode value)))))

(defun pi-code--format-tool-args (args)
  "Return ARGS (a plist) as indented `key: value' lines ending in a newline.
Keys use `pi-code-tool-key-face', values `pi-code-tool-args-face'."
  (let ((pairs (and (listp args) (pi-code--plist-pairs args))))
    (if (null pairs)
        ""
      (let ((s (mapconcat
                (lambda (pair)
                  (pi-code--indent-lines
                   (concat
                    (propertize (pi-code--arg-key-string (car pair))
                                'face 'pi-code-tool-key-face)
                    (propertize
                     (concat ": "
                             (pi-code--arg-value-string (cdr pair)))
                     'face 'pi-code-tool-args-face))
                   (propertize "    " 'face 'pi-code-tool-args-face)
                   (propertize "      " 'face 'pi-code-tool-args-face)))
                pairs "\n")))
        (put-text-property 0 (length s) 'wrap-prefix "      " s)
        (concat s "\n")))))

(defun pi-code--insert-tool-line (name)
  "Insert the tool header line for NAME.
The `└' result prefix closes the block, so each execution reads as
one wrapped unit."
  (pi-code--fresh-line)
  (let* ((glyph (pi-code--tool-glyph name))
         ;; Fixed 4-column icon field so every ▸ lines up, glyph or not.
         (icon (if (equal glyph "▸") "    " (format "  %s " glyph)))
         (head (format "%s▸ %s" icon (or name "?"))))
    (pi-code--insert (concat head "\n") 'face 'pi-code-tool-face)))

(defun pi-code--insert-tool-call (name args)
  "Insert a tool call line for NAME with pretty-printed ARGS.
Known tools get a leading glyph (see `pi-code--tool-icons');
the legacy ▸ marker is always kept."
  (pi-code--insert-tool-line name)
  (let ((region (pi-code--insert (pi-code--format-tool-args args))))
    (when region
      (pi-code--linkify-region (car region) (cdr region)))))

;;; Links and folds

(defvar pi-code--link-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-2] #'pi-code--link-click)
    (define-key map (kbd "RET") #'pi-code-open-link-at-point)
    (define-key map [follow-link] 'mouse-face)
    map)
  "Keymap for clickable links in pi-code chat buffers.")

(defun pi-code--link-open (target)
  "Open TARGET: a URL in the browser, a path in another window.
When `pi-code-open-file-side-window' is non-nil, files open in a
right-hand side window instead."
  (if (string-match-p pi-code--url-re target)
      (browse-url target)
    (if pi-code-open-file-side-window
        (display-buffer (find-file-noselect target)
                        '(display-buffer-in-side-window
                          (side . right)
                          (window-width . 0.45)))
      (find-file-other-window target))))

(defun pi-code-open-link-at-point ()
  "Open the file or URL link at point."
  (interactive)
  (let ((target (get-text-property (point) 'pi-code-link)))
    (when target
      (pi-code--link-open target))))

(defun pi-code--link-click (event)
  "Open the file or URL link clicked with the mouse."
  (interactive "e")
  (let* ((end (event-end event))
         (target (with-current-buffer (window-buffer (posn-window end))
                   (get-text-property (posn-point end) 'pi-code-link))))
    (when target
      (pi-code--link-open target))))

(defun pi-code--apply-link (begin end target)
  "Make buffer text [BEGIN, END) a clickable link to TARGET."
  (add-text-properties
   begin end
   (list 'keymap pi-code--link-map
         'mouse-face 'highlight
         'follow-link t
         'face 'pi-code-file-link-face
         'help-echo "RET / mouse-2: open"
         'pi-code-link target)))

(defun pi-code--linkify-region (start end)
  "Make URLs and existing file paths in [START, END) clickable."
  (when (and start end (< start end))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char start)
        (while (re-search-forward pi-code--url-re end t)
          (pi-code--apply-link (match-beginning 0) (match-end 0)
                               (match-string-no-properties 0)))
        (goto-char start)
        (while (re-search-forward pi-code--file-path-re end t)
          (let ((path (match-string-no-properties 1)))
            (when (and path
                       (condition-case nil
                           (file-exists-p path)
                         (error nil)))
              (pi-code--apply-link (match-beginning 1) (match-end 1)
                                   path))))))))

(defvar pi-code--fold-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-2] #'pi-code--fold-click)
    (define-key map (kbd "RET") #'pi-code--fold-toggle-at-point)
    (define-key map [follow-link] 'mouse-face)
    map)
  "Keymap for clickable fold placeholders in pi-code chat buffers.")

(defun pi-code--fold-toggle-at-point ()
  "Toggle the fold placeholder at point."
  (interactive)
  (let ((ov (and (derived-mode-p 'pi-code-chat-mode)
                 (pi-code--fold-at-point))))
    (when (overlayp ov)
      (pi-code--toggle-fold ov))))

(defun pi-code--fold-click (event)
  "Toggle the fold placeholder clicked with the mouse."
  (interactive "e")
  (let* ((win (posn-window (event-end event)))
         (pos (posn-point (event-end event))))
    (when (and (window-live-p win) (integer-or-marker-p pos))
      (with-current-buffer (window-buffer win)
        (let ((ov (and (derived-mode-p 'pi-code-chat-mode)
                       (pi-code--fold-at-pos pos))))
          (when (overlayp ov)
            (pi-code--toggle-fold ov)))))))

(defun pi-code--fold-placeholder (hidden-count ov)
  "Return a clickable fold placeholder for HIDDEN-COUNT lines on OV.
The placeholder inherits OV's stored indent so it lines up with the
block it replaces; a stored label (e.g. thinking) names the block."
  (propertize (let ((indent (or (overlay-get ov 'pi-code-fold-indent) "    "))
                    (label (overlay-get ov 'pi-code-fold-label)))
                (if label
                    (format "%s⋯ %s · %d %s (TAB)" indent label hidden-count
                            (if (= hidden-count 1) "line" "lines"))
                  (format "%s⋯ %d more lines (TAB)" indent hidden-count)))
              'face 'pi-code-meta-face
              'mouse-face 'highlight
              'follow-link t
              'help-echo "mouse-2: expand (or TAB)"
              'keymap pi-code--fold-map
              'pi-code-fold-ov ov))

;;; Folding

(defun pi-code--live-folds ()
  "Return the currently live fold overlays."
  (setq pi-code--folds
        (cl-remove-if-not (lambda (ov) (and (overlayp ov) (overlay-start ov)))
                          pi-code--folds))
  pi-code--folds)

(defun pi-code--make-fold (start end hidden-count &optional indent label)
  "Hide lines from START to END, showing HIDDEN-COUNT in the placeholder.
INDENT is the prefix used to line the placeholder up with the block;
LABEL names the block kind (e.g. thinking) in the placeholder."
  (let ((ov (make-overlay start end nil t)))
    (overlay-put ov 'pi-code-fold t)
    (overlay-put ov 'pi-code-fold-count hidden-count)
    (overlay-put ov 'pi-code-fold-indent (or indent "    "))
    (overlay-put ov 'pi-code-fold-label label)
    (overlay-put ov 'invisible t)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'isearch-open-invisible #'delete-overlay)
    (overlay-put ov 'after-string (pi-code--fold-placeholder hidden-count ov))
    (push ov pi-code--folds)
    ov))

(defun pi-code--fold-result (region)
  "Fold the tail of tool result REGION, a (START . END) cons, when long.
Uses the result's stored indent so the placeholder aligns."
  (when (and pi-code-tool-result-lines region)
    (let ((start (car region))
          (end (cdr region))
          (indent (or (get-text-property (car region) 'pi-code-indent)
                      "    ")))
      (when (> (count-lines start end) pi-code-tool-result-lines)
        (save-excursion
          (goto-char start)
          (forward-line pi-code-tool-result-lines)
          (let ((fold-start (point)))
            (when (< fold-start end)
              (pi-code--make-fold fold-start end
                                  (count-lines fold-start end)
                                  indent))))))))

(defun pi-code--fold-placeholder-at (pos)
  "Return the fold overlay ending at POS, or nil.
Placeholders display at the overlay end whether folded (showing
the after-string) or expanded, so both toggle from there.  Unlike
the old text-property lookup, this also works from mouse events."
  (cl-find-if (lambda (ov)
                (and (overlayp ov)
                     (overlay-get ov 'pi-code-fold)
                     (overlay-buffer ov)
                     (overlay-end ov)
                     (= (overlay-end ov) pos)))
              (pi-code--live-folds)))

(defun pi-code--fold-at-pos (pos)
  "Return the fold overlay relevant at buffer position POS, or nil.
Matches folds containing POS as well as placeholders displayed
there.  Only the nearest fold counts: unlike the old fallback,
positions past a fold no longer toggle it by proximity."
  (or (cl-find-if (lambda (ov) (overlay-get ov 'pi-code-fold))
                  (overlays-at pos))
      (pi-code--fold-placeholder-at pos)))

(defun pi-code--fold-at-point ()
  "Return the fold overlay relevant at point, or nil."
  (pi-code--fold-at-pos (point)))

(defun pi-code--toggle-fold (ov)
  "Show or hide the contents of fold overlay OV."
  (if (overlay-get ov 'invisible)
      (progn
        (overlay-put ov 'invisible nil)
        (overlay-put ov 'after-string nil))
    (overlay-put ov 'invisible t)
    (overlay-put ov 'after-string
                 (pi-code--fold-placeholder
                  (overlay-get ov 'pi-code-fold-count) ov))))

(defun pi-code-toggle-fold ()
  "Toggle the fold at point, cycle Org headings, else indent as usual.
Answer headlines are demoted to level 2+ at column 0, so `org-cycle'
folds their subtrees natively."
  (interactive)
  (let ((ov (and (derived-mode-p 'pi-code-chat-mode)
                 (pi-code--fold-at-point))))
    (cond
     (ov (pi-code--toggle-fold ov))
     ((and (derived-mode-p 'pi-code-chat-mode)
           (org-at-heading-p))
      (org-cycle))
     ((derived-mode-p 'pi-code-chat-mode)
      (when (and pi-code--history-end
                 (>= (point) (marker-position pi-code--history-end)))
        (indent-for-tab-command)))
     (t (indent-for-tab-command)))))

;;; Navigation and actions

(defun pi-code--file-at-point ()
  "Return the file path or URL at point, or nil."
  (or (get-text-property (point) 'pi-code-link)
      (let ((name (thing-at-point 'filename t)))
        (and name (file-exists-p name) name))))

(defun pi-code-open-file-at-point ()
  "Open the file path or URL at point in another window."
  (interactive)
  (let ((target (pi-code--file-at-point)))
    (if target
        (pi-code--link-open target)
      (message "pi-code: no file at point"))))

(defun pi-code-copy-last-reply ()
  "Copy the most recent assistant reply to the kill ring."
  (interactive)
  (if (and pi-code--last-reply (not (string-empty-p pi-code--last-reply)))
      (progn
        (kill-new pi-code--last-reply)
        (message "pi-code: copied last reply (%d chars)"
                 (length pi-code--last-reply)))
    (message "pi-code: no assistant reply yet")))

(defun pi-code--turn-positions ()
  "Return a sorted list of turn header positions in this buffer."
  (let (positions)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\* \\(You\\|pi\\)" nil t)
        (push (match-beginning 0) positions)))
    (nreverse positions)))

(defun pi-code-next-turn (&optional count)
  "Move point to the COUNT-th next conversation turn header."
  (interactive "p")
  (let* ((rest (cl-remove-if-not (lambda (p) (> p (point)))
                                 (pi-code--turn-positions)))
         (target (nth (1- (or count 1)) rest)))
    (if target
        (goto-char target)
      (message "pi-code: no further turns"))))

(defun pi-code-previous-turn (&optional count)
  "Move point to the COUNT-th previous conversation turn header."
  (interactive "p")
  (let* ((prev (cl-remove-if-not (lambda (p) (< p (point)))
                                 (pi-code--turn-positions)))
         (target (nth (1- (or count 1)) (reverse prev))))
    (if target
        (goto-char target)
      (message "pi-code: no earlier turns"))))

;;; Buffer setup

(defun pi-code--insert-banner ()
  "Insert the welcome banner at point (before the history marker)."
  (let ((inhibit-read-only t)
        (name (or pi-code--session-name "pi")))
    (insert (propertize (format " pi · %s\n" name)
                        'face 'pi-code-banner-face
                        'read-only t 'rear-nonsticky t))
    (insert (propertize
             (concat " Type a request below and press C-c C-c to send.\n"
                     " C-c C-c send/abort  ·  C-c C-s steer  ·  C-c C-k abort"
                     "  ·  C-c C-a menu  ·  C-c C-n new  ·  C-c C-r resume"
                     "  ·  C-c C-q quit\n\n")
             'face 'pi-code-meta-face
             'wrap-prefix "  "
             'read-only t 'rear-nonsticky t))))

(defun pi-code--open-chat (session name)
  "Open a chat buffer for SESSION named NAME and return it."
  (let ((buf (get-buffer-create (format "*pi-code:%s*" name))))
    (with-current-buffer buf
      (pi-code-chat-mode)
      (when-let ((cwd (pi-code-session-cwd session)))
        (setq default-directory
              (file-name-as-directory (expand-file-name cwd))))
      (setq pi-code--session session
            pi-code--session-name name
            pi-code--folds nil
            pi-code--widgets nil
            pi-code--ext-status nil
            pi-code--caret-ov nil
            pi-code--last-turn-role nil)
      (pi-code--insert-banner)
      (setq pi-code--history-end (copy-marker (point-max) nil)
            pi-code--streaming-p nil
            pi-code--streamed-current nil
            pi-code--streamed-text nil
            pi-code--assistant-open nil
            pi-code--msg-start nil
            pi-code--thinking-start nil
            pi-code--queue nil
            pi-code--last-reply nil
            pi-code--spinner-index 0
            pi-code--last-index nil
            pi-code--pending-echo nil
            pi-code--echoed-user nil
            pi-code--stats nil)
      (setq-local frame-title-format (format "%s — pi" name))
      (pi-code--insert-prompt)
      (pi-code-rpc-add-event-function session #'pi-code--on-event)
      (pi-code-rpc-set-ui-handler session #'pi-code--on-ui-request)
      (pi-code--update-header)
      (pi-code--refresh-stats))
    buf))

;;; Header line

(defun pi-code--spinner ()
  "Return the current spinner glyph."
  (aref pi-code--spinner-frames
        (% pi-code--spinner-index (length pi-code--spinner-frames))))

(defun pi-code--any-streaming-p ()
  "Return non-nil if some chat buffer is currently streaming."
  (cl-find-if (lambda (b)
                (with-current-buffer b
                  (and (derived-mode-p 'pi-code-chat-mode)
                       pi-code--streaming-p)))
              (buffer-list)))

(defun pi-code--spinner-tick ()
  "Advance spinners in all streaming chat buffers."
  (let ((streaming nil))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (and (derived-mode-p 'pi-code-chat-mode)
                   pi-code--streaming-p)
          (setq streaming t
                pi-code--spinner-index
                (1+ pi-code--spinner-index))
          (pi-code--update-header))))
    (unless streaming
      (when (timerp pi-code--spinner-timer)
        (cancel-timer pi-code--spinner-timer))
      (setq pi-code--spinner-timer nil))))

(defun pi-code--spinner-ensure ()
  "Start the spinner timer if some chat buffer is streaming."
  (when (timerp pi-code--spinner-timer)
    (cancel-timer pi-code--spinner-timer)
    (setq pi-code--spinner-timer nil))
  (when (pi-code--any-streaming-p)
    (setq pi-code--spinner-timer
          (run-with-timer 0.15 0.15 #'pi-code--spinner-tick))))

(defun pi-code--model-name ()
  (let ((state (and pi-code--session
                    (pi-code-session-state pi-code--session))))
    (or (plist-get (plist-get state :model) :name) "…")))

(defun pi-code--format-tokens (n)
  "Format token count N compactly (60000 -> \"60k\")."
  (cond
   ((not (numberp n)) nil)
   ((>= n 1000000) (format "%.1fM" (/ n 1000000.0)))
   ((>= n 1000) (format "%gk" (/ n 1000.0)))
   (t (number-to-string n))))

(defun pi-code--context-label (pct tokens window)
  "Build the header context segment from PCT, TOKENS and WINDOW."
  (cond
   ((and pct tokens window)
    (format "ctx %s%% (%s/%s)" pct
            (pi-code--format-tokens tokens)
            (pi-code--format-tokens window)))
   (pct (format "ctx %s%%" pct))
   (t "ctx --")))

(defun pi-code--context-face (pct)
  "Return the header face for context usage percent PCT.
Near-full contexts stand out in the header line."
  (cond
   ((not (numberp pct)) 'pi-code-meta-face)
   ((>= pct 95) 'pi-code-error-face)
   ((>= pct 80) 'pi-code-header-busy-face)
   (t 'pi-code-meta-face)))

(defun pi-code--sync-frame-title (buf title)
  "Set the frame title of frames showing BUF to TITLE.
`frame-title-format' is set buffer-locally so redisplay picks it up
whenever the chat buffer is shown; the frame `name' parameter is set
too for good measure."
  (let ((label (format "%s — pi" title)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq-local frame-title-format label)))
    (dolist (frame (frame-list))
      (when (cl-find-if (lambda (win) (eq (window-buffer win) buf))
                        (window-list frame 'no-mini))
        (condition-case nil
            (set-frame-parameter frame 'name label)
          (error nil))))))

(defun pi-code--update-header ()
  "Refresh the header line from session state and stats."
  (let* ((state (and pi-code--session
                     (pi-code-session-state pi-code--session)))
         (ctx (and pi-code--stats (plist-get pi-code--stats :contextUsage)))
         (pct (and ctx (plist-get ctx :percent)))
         (ctx-tokens (and ctx (plist-get ctx :tokens)))
         (ctx-window (and ctx (plist-get ctx :contextWindow)))
         (tok (and pi-code--stats (plist-get pi-code--stats :tokens)))
         (tok-total (and tok (plist-get tok :total)))
         (cost (and pi-code--stats (plist-get pi-code--stats :cost)))
         (thinking (plist-get state :thinkingLevel))
         (project (and pi-code--session
                       (let ((cwd (pi-code-session-cwd pi-code--session)))
                         (and cwd
                              (file-name-nondirectory
                               (directory-file-name cwd)))))))
     (setq header-line-format
           (list
            (propertize " pi " 'face 'pi-code-header-brand-face)
            (when pi-code--session-name
              (propertize (format "· %s " pi-code--session-name)
                          'face 'pi-code-meta-face))
            (propertize (pi-code--model-name) 'face 'pi-code-header-model-face)
            (when (and project
                       (not (equal project pi-code--session-name)))
              (concat "  " (propertize project 'face 'pi-code-meta-face)))
            "   "
            (propertize (if pi-code--streaming-p
                            (concat (pi-code--spinner) " working")
                          "○ idle")
                        'face (if pi-code--streaming-p
                                  'pi-code-header-busy-face
                                'pi-code-meta-face))
            (when thinking
              (concat "   " (propertize (format "think %s" thinking)
                                        'face 'pi-code-meta-face)))
            "   "
            (propertize (pi-code--context-label pct ctx-tokens ctx-window)
                        'face (pi-code--context-face pct))
            (when tok-total
              (concat "   " (propertize
                              (format "tokens %s"
                                      (pi-code--format-tokens tok-total))
                              'face 'pi-code-meta-face)))
            (when cost
              (concat "   " (propertize (format "$%.4f" cost)
                                        'face 'pi-code-meta-face)))
            (when (and pi-code--queue
                       (> (+ (car pi-code--queue) (cdr pi-code--queue)) 0))
              (concat "   "
                      (propertize
                       (format "queued: %d (steer %d, follow-up %d)"
                               (+ (car pi-code--queue) (cdr pi-code--queue))
                               (car pi-code--queue) (cdr pi-code--queue))
                       'face 'pi-code-meta-face)))
            (when pi-code--ext-status
              (concat "   "
                      (propertize
                       (string-join (mapcar #'cdr pi-code--ext-status) " · ")
                       'face 'pi-code-meta-face)))))))

(defun pi-code--refresh-stats ()
  "Ask the agent for session stats and update the header."
  (when (and pi-code--session (pi-code-rpc-alive-p pi-code--session))
    (let ((buf (current-buffer))
          (sess pi-code--session))
      (pi-code-rpc-send
       sess '(:type "get_session_stats")
       (lambda (s2 resp)
         (when (and (plist-get resp :success) (buffer-live-p buf))
           (with-current-buffer buf
             (when (eq s2 pi-code--session)
               (setq pi-code--stats (plist-get resp :data))
               (pi-code--update-header)))))))))

;;; Sending

(defun pi-code--insert-prompt ()
  "Insert the input prompt at the end of the input area.
The prompt is read-only; the `field' property extends to text
typed after it so `pi-code--in-input-p' can find the input area."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (insert (propertize pi-code--input-prompt
                          'face 'pi-code-prompt-face
                          'read-only t
                          'field 'pi-code-input
                          'rear-nonsticky '(read-only face
                                             rear-nonsticky))))
    (setq pi-code--input-active t)))

(defun pi-code--in-input-p ()
  "Return non-nil if point is inside the input area."
  (and pi-code--history-end
       (or (eq (get-char-property (point) 'field) 'pi-code-input)
           (>= (point) (marker-position pi-code--history-end)))))

(defun pi-code--input-text ()
  "Return the trimmed text of the input area, without the prompt.
Tolerates a separator newline between history and the prompt."
  (let ((text (buffer-substring-no-properties
               pi-code--history-end (point-max))))
    (setq text (replace-regexp-in-string "\\`\n+" "" text))
    (when (string-prefix-p pi-code--input-prompt text)
      (setq text (substring text (length pi-code--input-prompt))))
    (string-trim text)))

(defun pi-code--clear-input ()
  (let ((inhibit-read-only t))
    (delete-region pi-code--history-end (point-max))
    (pi-code--insert-prompt)))

(defun pi-code-send-or-abort ()
  "Send the input as a prompt, or abort if the agent is working."
  (interactive)
  (if pi-code--streaming-p
      (pi-code-abort)
    (if (pi-code--in-input-p)
        (pi-code--send-prompt (pi-code--input-text) nil)
      (message "pi-code: move point into the input area to send"))))

(defun pi-code--send-prompt (text streaming-behavior)
  "Send TEXT as a prompt; STREAMING-BEHAVIOR nil, steer or followUp."
  (if (string-empty-p text)
      (message "pi-code: input is empty")
    (unless (and pi-code--session (pi-code-rpc-alive-p pi-code--session))
      (user-error "pi-code: session is not running"))
    (let ((cmd (list :type "prompt" :message text)))
      (when streaming-behavior
        (setq cmd (plist-put cmd :streamingBehavior streaming-behavior)))
      (pi-code--clear-input)
      (pi-code--render-user text)
      (setq pi-code--pending-echo text)
      (let ((buf (current-buffer)))
        (pi-code-rpc-send
         pi-code--session cmd
         (lambda (_sess resp)
            (unless (plist-get resp :success)
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (pi-code--fresh-line)
                  (pi-code--insert
                   (format "[send failed: %s]\n"
                           (or (plist-get resp :error) "unknown"))
                   'face 'pi-code-error-face))))))))))

(defun pi-code-abort ()
  "Abort the current agent run."
  (interactive)
  (when (and pi-code--session (pi-code-rpc-alive-p pi-code--session))
    (pi-code-rpc-send pi-code--session '(:type "abort"))
    (pi-code--caret-hide)
    (pi-code--fresh-line)
    (pi-code--insert "[aborted]\n" 'face 'pi-code-error-face)))

(defun pi-code-steer ()
  "Send the input as a steering message while the agent works."
  (interactive)
  (let ((text (pi-code--input-text)))
    (cond
     ((string-empty-p text) (message "pi-code: input is empty"))
     ((not pi-code--streaming-p) (pi-code--send-prompt text nil))
      (t (unless (and pi-code--session (pi-code-rpc-alive-p pi-code--session))
           (user-error "pi-code: session is not running"))
         (pi-code--clear-input)
         (pi-code-rpc-send pi-code--session (list :type "steer" :message text))
         (pi-code--fresh-line)
         (pi-code--insert (format "[steer queued: %s]\n" text)
                          'face 'pi-code-meta-face)))))

;;; Org

(defun pi-code--in-ranges-p (pos ranges)
  "Return non-nil if POS lies inside any (START . END) in RANGES."
  (cl-some (lambda (r) (and (>= pos (car r)) (< pos (cdr r)))) ranges))

(defun pi-code--org-src-ranges (start end)
  "Return (START . END) ranges of Org src/example blocks in [START, END).
Keywords are case-insensitive, as in Org; an unclosed block runs
to END."
  (let (ranges (case-fold-search t))
    (save-excursion
      (goto-char start)
      (while (re-search-forward "^[ \t]*#\\+begin_\\(src\\|example\\)\\b"
                                end t)
        (let ((beg (match-beginning 0))
              (kind (match-string-no-properties 1)))
          (if (re-search-forward
               (concat "^[ \t]*#\\+end_" (regexp-quote kind) "\\b")
               end t)
              (push (cons beg (match-end 0)) ranges)
            (push (cons beg end) ranges)))))
    ranges))

(defun pi-code--demote-org-headlines (start end)
  "Dedent and demote Org headlines in [START, END), in place.
Turn headers (`* You' / `* pi') own level 1, so answer text must
nest below them; and Org only counts a headline at column 0, while
chat bodies are indented.  Each answer headline is therefore moved
to column 0 and given one extra star (`*' -> `**', `**' -> `***'),
making it a real Org headline that folds and exports correctly.
Demotion is uniform, so relative structure is preserved whatever
levels the agent chose.  Headline-looking lines inside
src/example bodies are code and are left alone."
  (let ((inhibit-read-only t)
        (case-fold-search t)
        (in-src nil))
    (save-excursion
      (goto-char start)
      (while (and (< (point) end) (not (eobp)))
        (cond
         ((looking-at "^[ \t]*#\\+begin_\\(src\\|example\\)\\b")
          (setq in-src t))
         ((looking-at "^[ \t]*#\\+end_\\(src\\|example\\)\\b")
          (setq in-src nil))
         ((and (not in-src) (looking-at "^[ \t]*\\*+ "))
          (let ((bol (line-beginning-position)))
            (skip-chars-forward " \t")
            (delete-region bol (point))
            (goto-char bol)
            (looking-at "\\*+")
            (goto-char (match-end 0))
            (insert "*"))))
        (forward-line 1)))))

(defun pi-code--align-org-tables (start end)
  "Align Org tables in [START, END) in place.
Faces alone leave columns ragged; aligning gives tables their grid
look.  Tables inside src/example bodies are skipped (their `|'
characters are code, not markup)."
  (let ((inhibit-read-only t)
        (ranges (pi-code--org-src-ranges start end))
        (lim (if (markerp end) (marker-position end) end)))
    (save-excursion
      (goto-char start)
      (while (re-search-forward "^[ \t]*|" end t)
        (beginning-of-line)
        ;; Align once per table, at its first row.
        (unless (or (pi-code--in-ranges-p (point) ranges)
                    (save-excursion
                      (forward-line -1)
                      (looking-at-p "^[ \t]*|")))
          (condition-case nil
              (org-table-align)
            (error nil)))
        ;; Step past this table block: re-searching from inside it
        ;; would revisit the same rows forever (`org-table-align'
        ;; does not move point past the table).
        (forward-line 1)
        (while (and (< (point) lim)
                    (looking-at-p "^[ \t]*|"))
          (forward-line 1))))))

(defun pi-code--mark-org-code-blocks (start end)
  "On Org src/example bodies in [START, END), set `wrap-prefix'.
The marker makes it obvious when a long code line is wrapped rather
than actually containing a line break."
  (when pi-code-code-wrap-prefix
    (let ((prefix (propertize pi-code-code-wrap-prefix
                              'face 'pi-code-meta-face))
          (inhibit-read-only t))
      (save-excursion
        (save-restriction
          (narrow-to-region start end)
          (dolist (r (pi-code--org-src-ranges (point-min) (point-max)))
            ;; The range covers the keyword lines; the body is between
            ;; the end of the begin line and the start of the end line.
            (goto-char (car r))
            (forward-line 1)
            (let ((body (point)))
              (goto-char (cdr r))
              ;; A closed block ends mid-line after the keyword; an
              ;; unclosed one runs to the region end as-is.
              (unless (= (point) (point-max))
                (forward-line 0))
              (when (< body (point))
                (put-text-property body (point)
                                   'wrap-prefix prefix)))))))))

(defun pi-code--fontify-org-structure (start end)
  "Face Org headlines and list bullets in [START, END).
Org headlines must start at column 0, but chat bodies are indented,
so org-mode's own font-lock never sees them; face them here
directly, skipping src/example bodies.  List bullets are `-', `+'
and ordered markers: a leading `*' starts a headline, never a
bullet."
  (let ((inhibit-read-only t)
        (ranges (pi-code--org-src-ranges start end)))
    (save-excursion
      (goto-char start)
      (while (re-search-forward "^[ \t]*\\*+ .*$" end t)
        (unless (pi-code--in-ranges-p (match-beginning 0) ranges)
          (put-text-property (match-beginning 0) (match-end 0)
                             'face 'pi-code-assistant-face)))
      (goto-char start)
      (while (re-search-forward "^[ \t]*\\([-+]\\|[0-9]+[.)]\\) " end t)
        (unless (pi-code--in-ranges-p (match-beginning 0) ranges)
          (put-text-property (match-beginning 1) (match-end 1)
                             'face 'bold))))))

(defun pi-code--fontify-org-region (start end)
  "Fontify the assistant text region [START, END) as Org.
The chat buffer is a real Org document with automatic
refontification off, so bodies are fontified here explicitly with
Org's own engine (indented headlines and bullets are faced
directly, since Org only sees column 0).  Answer headlines are
demoted one level first (turn headers own level 1), then tables
are aligned; both are text surgery, so they run before any facing.
Native unfontify clears explicit faces, so the structure pass must
land last.  Never signals.  URLs and file paths become clickable."
  (when (and start end (< start end)
             (<= (- end start) pi-code-org-max-chars)
             pi-code-use-org)
    (let ((inhibit-read-only t))
      (condition-case nil
          (progn
            (pi-code--demote-org-headlines start end)
            (pi-code--align-org-tables start end)
            (font-lock-fontify-region start end)
            (pi-code--fontify-org-structure start end))
        (error nil))
      (condition-case nil
          (pi-code--mark-org-code-blocks start end)
        (error nil))
      (condition-case nil
          (pi-code--linkify-region start end)
        (error nil)))))

(defun pi-code--flush-text-run ()
  "Fontify the pending assistant text run, if any."
  (when (and pi-code--msg-start (marker-position pi-code--msg-start))
    (pi-code--fontify-org-region pi-code--msg-start
                                      pi-code--history-end)
    (set-marker pi-code--msg-start nil))
  (setq pi-code--msg-start nil))

;;; Rendering messages

(defun pi-code--render-user (text)
  "Render TEXT as a user turn."
  (pi-code--insert-user text))

(defun pi-code--message-text (msg)
  "Extract plain text from MSG (user or assistant)."
  (let ((content (plist-get msg :content)))
    (cond
     ((stringp content) content)
     ((listp content)
      (mapconcat
       (lambda (b)
         (cond
          ((stringp b) b)
          ((equal (plist-get b :type) "text") (or (plist-get b :text) ""))
          ((equal (plist-get b :type) "thinking") "")
          (t "")))
       content ""))
     (t ""))))

(defun pi-code--render-message-full (msg)
  "Render a complete MSG (used for history replay)."
  (let ((role (plist-get msg :role)))
    (cond
     ((equal role "user")
      (pi-code--insert-user (pi-code--message-text msg)))
      ((equal role "assistant")
       (pi-code--insert-assistant-header)
       (dolist (b (plist-get msg :content))
         (when (listp b)
           (cond
               ((equal (plist-get b :type) "text")
                 (let ((start (marker-position pi-code--history-end)))
                   (pi-code--insert-body-text (or (plist-get b :text) ""))
                   (pi-code--fontify-org-region
                    start pi-code--history-end)))
                ((equal (plist-get b :type) "thinking")
                 (pi-code--insert-thinking (plist-get b :thinking)))
                ((equal (plist-get b :type) "toolCall")
                 (pi-code--insert-tool-call (plist-get b :name)
                                            (plist-get b :arguments)))
                ((equal (plist-get b :type) "image")
            (pi-code--insert
             (pi-code--image-placeholder (plist-get b :data)
                                         (plist-get b :mimeType))))))))
      ((equal role "toolResult")
       (let ((region (pi-code--insert
                      (pi-code--format-tool-result msg))))
         (when region
           (pi-code--linkify-region (car region) (cdr region))))))))

(defun pi-code--one-line (s)
  "Collapse S to one line, truncated."
  (let ((one (replace-regexp-in-string "[\r\n]+" " " (or s ""))))
    (if (> (length one) 300) (concat (substring one 0 300) "…") one)))

(defun pi-code--diff-p (text)
  "Return non-nil if TEXT looks like a unified diff."
  (and (stringp text)
       (or (string-match-p "\\`diff --git" text)
           (string-match-p "^diff --git" text)
           (string-match-p "^@@ -[0-9]" text))))

(defun pi-code--diff-line-face (line)
  "Return the diff face for a single indented result LINE, or nil."
  (let ((body (replace-regexp-in-string "\\`[ \t]+" "" line)))
    (setq body (replace-regexp-in-string "\\`└[ \t]*" "" body))
    (setq body (replace-regexp-in-string "\\`✔[ \t]*" "" body))
    (setq body (replace-regexp-in-string "\\`✖ \\[error\\] " "" body))
    (cond
     ;; File-level lines make the boundaries of a multi-file diff clear.
     ((string-match-p
       "\\`\\(diff --git\\|index \\|old mode\\|new mode\\|new file mode\\|deleted file mode\\|similarity index\\|rename from\\|rename to\\|copy from\\|copy to\\|Binary files\\|GIT binary patch\\|\\\\ No newline\\|\\+\\+\\+ \\|--- \\)"
       body)
      'pi-code-diff-file-face)
     ((string-match-p "\\`@@[^@]*@@" body) 'pi-code-meta-face)
     ((string-match-p "\\`\\+\\([^+ \t]\\|$\\)" body)
      'pi-code-diff-add-face)
     ((string-match-p "\\`-\\([^- \t]\\|$\\)" body)
      'pi-code-diff-del-face))))

(defun pi-code--diff-fontify (text)
  "Apply diff faces to unified diff lines in TEXT, in place."
  (let ((pos 0)
        (len (length text)))
    (while (< pos len)
      (let* ((nl (string-match "\n" text pos))
             (line-end (or nl len))
             (face (pi-code--diff-line-face
                    (substring text pos line-end))))
        (when face
          (put-text-property pos line-end 'face face text))
        (setq pos (if nl (1+ nl) len)))))
  text)

(defun pi-code--image-placeholder (data mime)
  "Return an inline image placeholder for base64 DATA of type MIME.
When `pi-code-inline-images' is nil or the image cannot be decoded,
fall back to a plain descriptive label."
  (let ((label (format "[image %s]" (or mime "image"))))
    (if (not (and pi-code-inline-images (stringp data) (not (string-empty-p data))))
        (concat (propertize label 'face 'pi-code-meta-face) "\n")
      (let* ((ext (pcase (downcase (or mime ""))
                    ("image/jpeg" "jpg")
                    ("image/gif" "gif")
                    ("image/webp" "webp")
                    (_ "png")))
             (file (condition-case nil
                       (make-temp-file "pi-code-img-" nil (concat "." ext))
                     (error nil)))
             (image (and file
                         (condition-case nil
                             (progn
                               (with-temp-buffer
                                 (set-buffer-multibyte nil)
                                 (insert (base64-decode-string data))
                                 (write-region (point-min) (point-max) file nil 'silent))
                               (create-image file nil nil :ascent 'center))
                           (error nil)))))
        (if image
            (concat (propertize label
                                'display image
                                'face 'pi-code-meta-face
                                'pi-code-image file)
                    "\n")
          (concat (propertize (concat label " (unavailable)")
                              'face 'pi-code-meta-face)
                  "\n"))))))

(defun pi-code--format-tool-result (msg)
  "Format a toolResult MSG for display, capped in size.
The result owns its own face: `pi-code-error-face' on errors,
`pi-code-tool-result-face' otherwise, with unified diff lines
faced individually.  Truncation and full-output hints from
`details' are appended when present."
  (let* ((parts
          (mapcar (lambda (c)
                    (cond ((stringp c) c)
                          ((equal (plist-get c :type) "text")
                           (or (plist-get c :text) ""))
                          ((equal (plist-get c :type) "image")
                           (pi-code--image-placeholder
                            (plist-get c :data) (plist-get c :mimeType)))
                          (t (json-encode c))))
                  (plist-get msg :content)))
         (text (string-join parts ""))
         (err (plist-get msg :isError))
         (is-diff nil)
         (status (if err "✖ [error] " "✔ "))
         (prefix (format "%s%s" pi-code--tool-result-prefix status))
         (cont (make-string (string-width prefix) ?\s)))
    (setq is-diff (pi-code--diff-p text))
    (when (> (length text) pi-code--display-cap)
      (setq text (concat (substring text 0 pi-code--display-cap)
                         "\n\u2026[output truncated for display]")))
    (setq text (propertize
                (pi-code--indent-lines text prefix cont)
                'face (if err 'pi-code-error-face
                        'pi-code-tool-result-face)
                'wrap-prefix cont
                'pi-code-indent cont))
    (when is-diff
      (pi-code--diff-fontify text))
    (let ((pos (string-match "[✔✖]" text)))
      (when pos
        (put-text-property pos (1+ pos) 'face
                           (if err 'pi-code-error-face 'success)
                           text)))
    (let ((details (plist-get msg :details)))
      (when details
        (let ((trunc (plist-get details :truncation))
              (full-path (plist-get details :fullOutputPath))
              (hints nil))
          (when (and trunc (plist-get trunc :truncated))
            (push (format "[truncated: %s of %s lines]"
                          (or (plist-get trunc :outputLines) "?")
                          (or (plist-get trunc :totalLines) "?"))
                  hints))
          (when full-path
            (push (concat "full output: " full-path) hints))
          (when hints
            (setq text (concat text
                               (propertize
                                (concat (mapconcat
                                         (lambda (h) (concat cont "⋯ " h))
                                         (nreverse hints) "\n")
                                        "\n")
                                'face 'pi-code-meta-face)))))))
    (concat text "\n")))

;;; Event dispatch

(defun pi-code--on-event (session event)
  "Render one agent EVENT for SESSION in its chat buffer."
  (let ((buf (pi-code--chat-buffer-for session)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (pi-code--handle-event event)))))

(defun pi-code--chat-buffer-for (session)
  "Find the live chat buffer attached to SESSION."
  (cl-find-if (lambda (b)
                (with-current-buffer b
                  (and (derived-mode-p 'pi-code-chat-mode)
                       (eq pi-code--session session))))
              (buffer-list)))

(defun pi-code--handle-event (event)
  "Render EVENT in the current chat buffer."
  (let ((type (plist-get event :type)))
     (cond
      ((equal type "agent_start")
       (setq pi-code--streaming-p t
             pi-code--streamed-current nil
             pi-code--streamed-text nil
             pi-code--assistant-open nil
             pi-code--msg-start nil
             pi-code--thinking-start nil
             pi-code--queue nil
             pi-code--last-index nil)
       (pi-code--update-header)
       (pi-code--spinner-ensure))
      ((equal type "agent_settled")
       (setq pi-code--streaming-p nil)
       (pi-code--caret-hide)
       (pi-code--finish-thinking)
       (pi-code--flush-text-run)
       (pi-code--finalize-block)
       (pi-code--update-header)
       (pi-code--refresh-stats))
     ((equal type "agent_end") nil) ; content already streamed
     ((equal type "message_start")
      (pi-code--ev-message-start (plist-get event :message)))
     ((equal type "message_update")
      (pi-code--ev-message-update
       (plist-get event :assistantMessageEvent)))
     ((equal type "message_end")
      (pi-code--ev-message-end (plist-get event :message)))
      ((equal type "tool_execution_start")
       (pi-code--insert-tool-call (plist-get event :toolName)
                                  (plist-get event :args))
       (let ((s (propertize (concat pi-code--tool-result-prefix
                                    "◐ running\n")
                            'face 'pi-code-meta-face)))
         (let ((pos (string-match "◐" s)))
           (when pos
             (put-text-property pos (1+ pos) 'face
                                'pi-code-header-busy-face s)))
         (pi-code--replace-live s)))
      ((equal type "tool_execution_update")
       (let ((region
              (pi-code--replace-live
               (pi-code--format-tool-result
                (list :content
                      (plist-get (plist-get event :partialResult) :content)
                      :isError nil)))))
         (when region
           (pi-code--linkify-region (car region) (cdr region)))))
      ((equal type "bash_execution_update")
       (let ((delta (plist-get event :delta)))
         (when (and (stringp delta) (not (string-empty-p delta)))
           (let ((region
                  (pi-code--replace-live
                   (pi-code--format-tool-result
                    (list :content `((:type "text" :text ,delta))
                          :isError nil)))))
             (when region
               (pi-code--linkify-region (car region) (cdr region)))))))
      ((equal type "tool_execution_end")
       (pi-code--fold-result
        (let ((region
               (pi-code--replace-live
                (pi-code--format-tool-result
                 (list :content (plist-get (plist-get event :result) :content)
                       :details (plist-get (plist-get event :result) :details)
                       :isError (plist-get event :isError))))))
          (when region
            (pi-code--linkify-region (car region) (cdr region))
            region)))
       (pi-code--finalize-block))
      ((equal type "compaction_start")
       (pi-code--fresh-line)
       (pi-code--insert "[compacting context…]\n" 'face 'pi-code-meta-face))
      ((equal type "compaction_end")
       (let* ((reason (plist-get event :reason))
              (result (plist-get event :result))
              (summary (and result (plist-get result :summary)))
              (err (or (plist-get event :errorMessage)
                       (and (plist-get event :aborted)
                            "compaction aborted"))))
         (pi-code--fresh-line)
         (cond
          (err
           (pi-code--insert
            (format "[compaction failed: %s]\n"
                    (pi-code--one-line err))
            'face 'pi-code-error-face))
          ((and summary (not (string-empty-p summary)))
           (let* ((before (plist-get result :tokensBefore))
                  (after (plist-get result :estimatedTokensAfter))
                  (delta (when (and (numberp before) (numberp after))
                           (format " %s → %s"
                                   (pi-code--format-tokens before)
                                   (pi-code--format-tokens after)))))
             (pi-code--insert
              (format "[context compacted (%s): %s]%s\n"
                      (or reason "manual")
                      (pi-code--one-line summary)
                      (or delta ""))
              'face 'pi-code-meta-face)))
          (t
           (pi-code--insert "[compaction done]\n"
                            'face 'pi-code-meta-face))))
       (pi-code--refresh-stats))
      ((equal type "auto_retry_start")
       (pi-code--fresh-line)
       (pi-code--insert
        (format "[retry %s/%s in %s: %s]\n"
                (or (plist-get event :attempt) "?")
                (or (plist-get event :maxAttempts) "?")
                (let ((ms (plist-get event :delayMs)))
                  (if (numberp ms) (format "%gs" (/ ms 1000.0)) "?"))
                (or (plist-get event :errorMessage) "transient error"))
        'face 'pi-code-meta-face))
      ((equal type "auto_retry_end")
       (unless (plist-get event :success)
         (pi-code--fresh-line)
         (pi-code--insert
          (format "[retry failed: %s]\n"
                  (or (plist-get event :finalError) "unknown error"))
          'face 'pi-code-error-face)))
      ((equal type "summarization_retry_scheduled")
       (pi-code--fresh-line)
       (pi-code--insert
        (format "[summarizing retry %s/%s in %s: %s]\n"
                (or (plist-get event :attempt) "?")
                (or (plist-get event :maxAttempts) "?")
                (let ((ms (plist-get event :delayMs)))
                  (if (numberp ms) (format "%gs" (/ ms 1000.0)) "?"))
                (or (plist-get event :errorMessage) "transient error"))
        'face 'pi-code-meta-face))
      ((equal type "summarization_retry_attempt_start") nil)
      ((equal type "summarization_retry_finished") nil)
      ((equal type "extension_error")
       (pi-code--fresh-line)
       (pi-code--insert
        (format "[extension error%s: %s]\n"
                (let ((path (plist-get event :extensionPath)))
                  (if path (format " (%s)" path) ""))
                (pi-code--one-line (or (plist-get event :error)
                                       "unknown")))
        'face 'pi-code-error-face))
      ((equal type "queue_update")
       (setq pi-code--queue
             (cons (length (plist-get event :steering))
                   (length (plist-get event :followUp))))
       (pi-code--update-header))
      ((equal type "turn_start") nil)
      ((equal type "turn_end") nil)
      (t nil))))

(defun pi-code--ev-message-start (msg)
  (when msg
    (let ((role (plist-get msg :role)))
      (cond
       ((equal role "user")
        ;; The echo of our optimistic render, or a queued message.
        (let ((text (pi-code--message-text msg)))
          (if (and pi-code--pending-echo (equal text pi-code--pending-echo))
              (setq pi-code--pending-echo nil
                    pi-code--echoed-user text)
            (pi-code--insert-user text))))
       ((equal role "assistant")
        (pi-code--insert-assistant-header)
        (setq pi-code--assistant-open t
              pi-code--streamed-text nil
              pi-code--msg-start
              (copy-marker (marker-position pi-code--history-end)
                           nil))
        (pi-code--disarm-thinking))))))

(defun pi-code--ev-message-update (delta)
  "Render one streaming DELTA event."
  (when delta
    (setq pi-code--streamed-current t)
    (let ((dtype (plist-get delta :type)))
       (cond
        ((equal dtype "text_delta")
         ;; Close any thinking block left open by a missing thinking_end
         ;; (e.g. a cancelled or malformed stream) before answer text
         ;; starts, so it still folds instead of leaking into the reply.
         (pi-code--finish-thinking)
         (let ((delta (or (plist-get delta :delta) "")))
           (unless pi-code--msg-start
             (setq pi-code--msg-start
                   (copy-marker (marker-position pi-code--history-end)
                                nil)))
            (setq pi-code--streamed-text
                  (concat pi-code--streamed-text delta))
            (pi-code--insert-body-text delta)
            (pi-code--caret-update)))
         ((equal dtype "thinking_start")
          (pi-code--flush-text-run)
          (pi-code--fresh-line)
          (pi-code--insert-thinking-label))
         ((equal dtype "thinking_delta")
          (unless pi-code--thinking-start
            (pi-code--fresh-line)
            (pi-code--insert-thinking-label))
         (let ((d (or (plist-get delta :delta) "")))
           ;; Indent the first line too when this delta opens the body.
           (when (and pi-code--thinking-start
                      (= (marker-position pi-code--thinking-start)
                         (marker-position pi-code--history-end)))
             (setq d (concat pi-code--thinking-indent d)))
           (pi-code--insert (pi-code--thinking-delta d)
                            'face 'pi-code-thinking-face
                            'wrap-prefix pi-code--thinking-indent)
           (pi-code--caret-update)))
        ((equal dtype "thinking_end")
         (pi-code--finish-thinking))
        ((equal dtype "toolcall_start")
         (pi-code--finish-thinking)
         (pi-code--flush-text-run)
         (pi-code--insert-tool-line (plist-get delta :toolName)))
        ((equal dtype "toolcall_end")
         (let ((call (plist-get delta :toolCall)))
           (when call
             (let ((region
                    (pi-code--insert
                     (pi-code--format-tool-args
                      (plist-get call :arguments)))))
               (when region
                 (pi-code--linkify-region (car region) (cdr region)))))))
        (t nil)))))

(defun pi-code--ev-message-end (msg)
  "Finalize MSG.  Non-streamed messages render in full here."
  (when msg
    (let ((role (plist-get msg :role)))
      (cond
       ((equal role "user")
        (let ((text (pi-code--message-text msg)))
          (cond
           ((and pi-code--pending-echo (equal text pi-code--pending-echo))
            (setq pi-code--pending-echo nil
                  pi-code--echoed-user text))
           ((and pi-code--echoed-user (equal text pi-code--echoed-user))
            (setq pi-code--echoed-user nil))
           (t (pi-code--insert-user text)))))
       ((equal role "assistant")
        (unless (or pi-code--streamed-current pi-code--assistant-open)
          (pi-code--insert-assistant-header)
          (dolist (b (plist-get msg :content))
            (when (listp b)
           (cond
            ((equal (plist-get b :type) "text")
             (let ((start (marker-position pi-code--history-end)))
               (pi-code--insert-body-text (or (plist-get b :text) ""))
               (pi-code--fontify-org-region
                start pi-code--history-end)))
               ((equal (plist-get b :type) "thinking")
                (pi-code--insert-thinking (plist-get b :thinking)))
               ((equal (plist-get b :type) "toolCall")
                (pi-code--insert-tool-call (plist-get b :name)
                                           (plist-get b :arguments)))
               ((equal (plist-get b :type) "image")
                (pi-code--insert
                 (pi-code--image-placeholder (plist-get b :data)
                                             (plist-get b :mimeType))))))))
        ;; Safety net: an un-ended thinking block stays visible so no
        ;; answer text is ever folded by mistake.
        (pi-code--disarm-thinking)
        (pi-code--flush-text-run)
        (let ((reply (or pi-code--streamed-text
                         (pi-code--message-text msg))))
          (when (and reply (not (string-empty-p reply)))
            (setq pi-code--last-reply reply)))
        (let ((err (plist-get msg :errorMessage)))
          (when err
            (pi-code--insert (format "\n[error: %s]\n"
                                     (pi-code--one-line err))
                             'face 'pi-code-error-face)))
        (setq pi-code--streamed-current nil
              pi-code--streamed-text nil
              pi-code--assistant-open nil
              pi-code--msg-start nil)
        (pi-code--caret-hide))
       ((equal role "toolResult")
        (unless pi-code--streamed-current
          (let ((region (pi-code--insert
                         (pi-code--format-tool-result msg))))
            (when region
              (pi-code--linkify-region (car region) (cdr region))))))))
  (pi-code--fresh-line)))

;;; Extension UI requests

(defun pi-code--on-ui-request (session request)
  "Handle extension UI REQUEST for SESSION.
Runs outside the process filter via a timer so minibuffer
interaction never re-enters the filter."
  (let ((buf (pi-code--chat-buffer-for session)))
    (run-with-timer
     0 nil
     (lambda ()
       (if (pi-code-rpc-alive-p session)
           (pi-code--dispatch-ui-request session request buf)
         (message "pi-code: dropped UI request, session is gone"))))))

(defun pi-code--ui-respond-cancel (session id)
  (when (pi-code-rpc-alive-p session)
    (pi-code-rpc-ui-respond session id '(:cancelled t))))

(defun pi-code--dispatch-ui-request (session request buf)
  "Execute one extension UI REQUEST."
  (let ((id (plist-get request :id))
        (method (plist-get request :method)))
    (cond
     ((equal method "select")
      (let ((choice (condition-case nil
                        (completing-read
                         (concat (or (plist-get request :title) "Choose") ": ")
                         (plist-get request :options) nil t)
                      (quit nil))))
        (if choice
            (pi-code-rpc-ui-respond session id (list :value choice))
          (pi-code--ui-respond-cancel session id))))
     ((equal method "confirm")
      (let ((answer (condition-case nil
                        (y-or-n-p (format "%s %s"
                                          (or (plist-get request :title) "Confirm?")
                                          (or (plist-get request :message) "")))
                      (quit nil))))
        (if (null answer)
            (pi-code--ui-respond-cancel session id)
          (pi-code-rpc-ui-respond session id (list :confirmed answer)))))
     ((equal method "input")
      (let* ((title (or (plist-get request :title) "Input"))
             (ph (plist-get request :placeholder))
             (prompt (if ph (format "%s (%s): " title ph)
                       (format "%s: " title)))
             (value (condition-case nil (read-from-minibuffer prompt)
                        (quit nil))))
        (if (null value)
            (pi-code--ui-respond-cancel session id)
          (pi-code-rpc-ui-respond session id (list :value value)))))
     ((equal method "editor")
      (pi-code--open-editor session id (plist-get request :title)
                            (plist-get request :prefill)))
     ((equal method "notify")
      (message "pi [%s]: %s"
               (or (plist-get request :notifyType) "info")
               (or (plist-get request :message) "")))
     ((equal method "setStatus")
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((key (plist-get request :statusKey))
                (text (plist-get request :statusText)))
            (setq pi-code--ext-status
                  (assoc-delete-all key pi-code--ext-status))
            (when text
              (push (cons key text) pi-code--ext-status))
            (pi-code--update-header)))))
     ((equal method "setWidget")
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (pi-code--set-widget (plist-get request :widgetKey)
                               (plist-get request :widgetLines)))))
      ((equal method "set_editor_text")
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (when (eq session pi-code--session)
             (let ((inhibit-read-only t)
                   (had-prompt
                    (and pi-code--history-end
                         (string-prefix-p
                          pi-code--input-prompt
                          (buffer-substring-no-properties
                           pi-code--history-end (point-max))))))
               (delete-region pi-code--history-end (point-max))
               (goto-char (point-max))
               (when had-prompt
                 (pi-code--insert-prompt))
               (insert (or (plist-get request :text) "")))))))
      ((equal method "setTitle")
       (let ((title (plist-get request :title)))
         (when (and title (buffer-live-p buf))
           (with-current-buffer buf
             (setq pi-code--session-name title)
             (rename-buffer (format "*pi-code:%s*" title) t)
             (pi-code--sync-frame-title buf title)
             (pi-code--update-header)))))
      (t nil))))

(defun pi-code--set-widget (key lines)
  "Show LINES (list of strings) as widget KEY, replacing any old one.
A nil LINES clears the widget."
  (let ((inhibit-read-only t)
        (old (assoc key pi-code--widgets)))
    (when old
      (let ((s (cadr old)) (e (caddr old)))
        (when (and (markerp s) (markerp e)
                   (marker-position s) (marker-position e))
          (delete-region s e)))
      (setq pi-code--widgets (delq old pi-code--widgets)))
    (when lines
      (pi-code--fresh-line)
      (let ((s (copy-marker pi-code--history-end nil)))
        (goto-char pi-code--history-end)
        (insert (propertize (concat (string-join lines "\n") "\n")
                            'read-only t 'rear-nonsticky t
                            'face 'pi-code-meta-face))
        (set-marker pi-code--history-end (point))
        (pi-code--maintain-input-separator)
        (push (list key s (copy-marker (point) nil))
              pi-code--widgets)))))

;;; Editor dialog

(defvar pi-code-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'pi-code-edit-submit)
    (define-key map (kbd "C-c C-k") #'pi-code-edit-cancel)
    map))

(define-derived-mode pi-code-edit-mode text-mode "pi-edit"
  "Edit extension-provided text, then submit it."
  :group 'pi-code)

(defvar-local pi-code-edit--session nil)
(defvar-local pi-code-edit--request-id nil)

(defun pi-code--open-editor (session id title prefill)
  (let ((buf (get-buffer-create (format "*pi-code-edit:%s*" (or title "text")))))
    (with-current-buffer buf
      (pi-code-edit-mode)
      (setq pi-code-edit--session session
            pi-code-edit--request-id id)
      (erase-buffer)
      (when prefill (insert prefill))
      (goto-char (point-min)))
    (pop-to-buffer buf)
    (message "pi-code: %s — C-c C-c to submit, C-c C-k to cancel"
             (or title "edit text"))))

(defun pi-code-edit-submit ()
  "Submit the editor buffer content as the dialog value."
  (interactive)
  (let ((text (buffer-substring-no-properties (point-min) (point-max)))
        (session pi-code-edit--session)
        (id pi-code-edit--request-id))
    (kill-buffer (current-buffer))
    (if (and session id (pi-code-rpc-alive-p session))
        (pi-code-rpc-ui-respond session id (list :value text))
      (message "pi-code: session gone, edit discarded"))))

(defun pi-code-edit-cancel ()
  "Cancel the editor dialog."
  (interactive)
  (let ((session pi-code-edit--session)
        (id pi-code-edit--request-id))
    (kill-buffer (current-buffer))
    (when (and session id)
      (pi-code--ui-respond-cancel session id))))

(provide 'pi-code-chat)
;;; pi-code-chat.el ends here
