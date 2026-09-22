;;; pi-code-render-test.el --- ERT tests for pi-code rendering -*- lexical-binding: t; -*-

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'pi-code-chat)

(defun pi-code-render-test--buffer ()
  "Make a temp chat buffer with full state initialized."
  (let ((buf (generate-new-buffer " *pi-code-render-test*")))
    (with-current-buffer buf
      (pi-code-chat-mode)
      (setq pi-code--session nil
            pi-code--session-name "test"
            pi-code--history-end (copy-marker (point-max) nil)
            pi-code--streaming-p nil
            pi-code--streamed-current nil
            pi-code--streamed-text nil
            pi-code--assistant-open nil
            pi-code--msg-start nil
            pi-code--queue nil
            pi-code--last-reply nil
            pi-code--spinner-index 0
            pi-code--last-index nil
            pi-code--pending-echo nil
            pi-code--echoed-user nil
            pi-code--folds nil
            pi-code--widgets nil
            pi-code--ext-status nil
            pi-code--stats nil))
    buf))

(defun pi-code-render-test--events (buf events)
  "Feed EVENTS to BUF's handler, return the buffer text."
  (with-current-buffer buf
    (dolist (ev events)
      (pi-code--handle-event ev)))
  (with-current-buffer buf (buffer-string)))

(defun pi-code-render-test--face-at (buf text)
  "Return the face at the first occurrence of TEXT in BUF."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (when (search-forward text nil t)
        (get-text-property (1- (point)) 'face)))))

(defun pi-code-render-test--prop-at (buf text prop)
  "Return text property PROP at the first occurrence of TEXT in BUF."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (when (search-forward text nil t)
        (get-text-property (1- (point)) prop)))))

;;; Tool args and results

(ert-deftest pi-code-render-test-tool-args-multiline ()
  "Args render as indented `key: value' lines."
  (let ((s (pi-code--format-tool-args '(:command "ls" :cwd "/tmp"))))
    (should (string-match-p "^    command: ls$" s))
    (should (string-match-p "^    cwd: /tmp$" s))))

(ert-deftest pi-code-render-test-tool-args-nested ()
  "Nested plist values stay readable instead of raw JSON lines."
  (let ((s (pi-code--format-tool-args '(:nested (:x "y")))))
    (should (string-match-p "nested: {" s))
    (should (string-match-p "\"x\"" s))))

(ert-deftest pi-code-render-test-result-continuation-indent ()
  "Result follow-up lines align under the first line's content."
  (let ((s (pi-code--format-tool-result '(:content ("l1\nl2") :isError nil))))
    ;; First-line prefix is "  └ ✔ " (6 columns); continuation matches.
    (should (string-match-p "\n      l2" s))
    (should (equal (get-text-property 0 'pi-code-indent s) "      "))))

;;; Folding

(ert-deftest pi-code-render-test-fold-default-hidden ()
  "Long results fold away their tail with a line count."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (let* ((text (mapconcat (lambda (n) (format "line %d" n))
                              (number-sequence 1 20) "\n"))
             (region (pi-code--insert (concat text "\n"))))
        (pi-code--fold-result region)
        (let ((ovs (pi-code--live-folds)))
          (should (= (length ovs) 1))
          (should (overlay-get (car ovs) 'invisible))
          (should (string-match-p
                   "5 more lines"
                   (or (overlay-get (car ovs) 'after-string) ""))))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-fold-toggle ()
  "Toggling a fold shows and hides its contents."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (let* ((text (mapconcat (lambda (n) (format "line %d" n))
                              (number-sequence 1 20) "\n"))
             (region (pi-code--insert (concat text "\n"))))
        (pi-code--fold-result region)
        (let ((ov (car (pi-code--live-folds))))
          (pi-code--toggle-fold ov)
          (should-not (overlay-get ov 'invisible))
          (should-not (overlay-get ov 'after-string))
          (pi-code--toggle-fold ov)
          (should (overlay-get ov 'invisible))
          (should (overlay-get ov 'after-string)))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-tool-result-fold-indent ()
  "Folded tool results keep the placeholder aligned under the prefix."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (let* ((text (mapconcat (lambda (n) (format "line %d" n))
                              (number-sequence 1 20) "\n"))
             (region (pi-code--insert
                      (pi-code--format-tool-result
                       (list :content (list text) :isError nil)))))
        (pi-code--fold-result region)
        (let* ((ov (car (pi-code--live-folds)))
               (placeholder (or (overlay-get ov 'after-string) "")))
          (should (string-prefix-p "      ⋯" placeholder)))))
    (kill-buffer buf)))

;;; Header and queue

(ert-deftest pi-code-render-test-context-face ()
  "Context usage escalates meta -> busy -> error."
  (should (eq (pi-code--context-face 30) 'pi-code-meta-face))
  (should (eq (pi-code--context-face 85) 'pi-code-header-busy-face))
  (should (eq (pi-code--context-face 97) 'pi-code-error-face))
  (should (eq (pi-code--context-face nil) 'pi-code-meta-face)))

(ert-deftest pi-code-render-test-header-dedup-project ()
  "The header does not repeat the project when it equals the session."
  (let* ((stderr (generate-new-buffer " *pi-code-render-stderr*"))
         (session (pi-code-session--new "tmp" "/tmp" stderr))
         (buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (setq pi-code--session session
            pi-code--session-name "tmp")
      (pi-code--update-header)
      (should-not (string-match-p "tmp *tmp"
                                  (format "%s" header-line-format))))
    (kill-buffer buf)
    (kill-buffer stderr)
    (when (get-buffer "*pi-code-proto:tmp*")
      (kill-buffer "*pi-code-proto:tmp*"))))

(ert-deftest pi-code-render-test-header-segments ()
  "Header shows working state, queue counts and extension status."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (setq pi-code--streaming-p t
            pi-code--queue '(2 . 1)
            pi-code--ext-status '(("k" . "busy")))
      (pi-code--update-header)
      (let ((h (format "%s" header-line-format)))
        (should (string-match-p "working" h))
        (should (string-match-p "queued: 3 (steer 2, follow-up 1)" h))
        (should (string-match-p "busy" h))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-queue-update ()
  "queue_update stores counts and refreshes the header."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--handle-event '(:type "queue_update"
                               :steering ("a" "b") :followUp nil))
      (should (equal pi-code--queue '(2 . 0)))
      (should (string-match-p "queued: 2"
                              (format "%s" header-line-format))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-set-title ()
  "setTitle updates the session name and the buffer name."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--dispatch-ui-request
       nil '(:id "1" :method "setTitle" :title "Demo") buf)
      (should (equal pi-code--session-name "Demo"))
      (should (string-match-p "Demo" (buffer-name buf))))
    (kill-buffer buf)))

;;; Tool glyphs and status markers

(ert-deftest pi-code-render-test-tool-glyph ()
  "Known tools map to glyphs; unknown tools keep plain ▸."
  (should (equal (pi-code--tool-glyph "bash") "$"))
  (should (equal (pi-code--tool-glyph "BASH") "$"))
  (should (equal (pi-code--tool-glyph "read") "≡"))
  (should (equal (pi-code--tool-glyph "frobnicate") "▸")))

(ert-deftest pi-code-render-test-tool-glyph-line ()
  "Tool lines keep the ▸ marker next to the glyph."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "tool_execution_start"
                             :toolCallId "c1" :toolName "bash"
                             :args (:command "ls"))))))
    (should (string-match-p "\\$ ▸ bash" text))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-tool-glyph-column ()
  "Known and unknown tools place ▸ in the same column."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert-tool-line "bash")
      (pi-code--insert-tool-line "frobnicate")
      (let* ((lines (split-string (buffer-string) "\n"))
             (k-line (nth 0 lines))
             (u-line (nth 1 lines)))
        (should (string-match-p "bash" k-line))
        (should (string-match-p "frobnicate" u-line))
        (should (equal (string-match "▸" k-line)
                       (string-match "▸" u-line)))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-thinking-indent ()
  "Thinking label and body share the same indent."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert-thinking "line1\nline2\n")
      (let ((text (buffer-string)))
        (should (string-match-p "^  ▹ thinking$" text))
        (should (string-match-p "^  line1$" text))
        (should (string-match-p "^  line2$" text))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-tool-status-markers ()
  "Running shows ◐, completion replaces it with ✔."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--handle-event '(:type "tool_execution_start"
                               :toolCallId "c1" :toolName "bash"
                               :args (:command "ls")))
      (should (string-match-p "◐ running" (buffer-string)))
      (pi-code--handle-event '(:type "tool_execution_update"
                               :toolCallId "c1" :toolName "bash"
                               :partialResult (:content ((:type "text" :text "par")))))
      (should-not (string-match-p "◐ running" (buffer-string)))
      (pi-code--handle-event '(:type "tool_execution_end"
                               :toolCallId "c1" :toolName "bash"
                               :result (:content ((:type "text" :text "done")))
                               :isError nil))
      (should-not (string-match-p "◐ running" (buffer-string)))
      (should-not (string-match-p "par" (buffer-string)))
      (should (string-match-p "✔" (buffer-string)))
      (should (string-match-p "done" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-tool-error-marker ()
  "Failed tools show ✖ with the [error] tag."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "tool_execution_end"
                             :toolCallId "c1" :toolName "bash"
                             :result (:content ((:type "text" :text "nope")))
                             :isError t)))))
    (should (string-match-p "✖" text))
    (should (string-match-p "\\[error\\]" text))
    (kill-buffer buf)))

;;; Diff rendering

(ert-deftest pi-code-render-test-diff-faces ()
  "Unified diff lines get add/del faces; +++ / --- headers do not."
  (let* ((buf (pi-code-render-test--buffer))
         (_text (pi-code-render-test--events
                 buf (list '(:type "tool_execution_end"
                              :toolCallId "c1" :toolName "edit"
                              :result (:content ((:type "text" :text "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new")))
                              :isError nil)))))
    (should (eq (pi-code-render-test--face-at buf "old")
                'pi-code-diff-del-face))
    (should (eq (pi-code-render-test--face-at buf "new")
                'pi-code-diff-add-face))
    (should (eq (pi-code-render-test--face-at buf "diff --git")
                'pi-code-diff-file-face))
    (should (eq (pi-code-render-test--face-at buf "--- a/f")
                'pi-code-diff-file-face))
    (should-not (memq (pi-code-render-test--face-at buf "--- a/f")
                      '(pi-code-diff-add-face pi-code-diff-del-face)))
    (kill-buffer buf)))

;;; Links

(ert-deftest pi-code-render-test-linkify ()
  "URLs and existing paths become clickable."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--handle-event
       '(:type "tool_execution_end"
          :toolCallId "c1" :toolName "bash"
          :result (:content ((:type "text"
                             :text "see https://example.com/x and /tmp for details")))
          :isError nil))
      (should (pi-code-render-test--prop-at buf "example.com" 'pi-code-link))
      (should (equal (pi-code-render-test--prop-at buf "/tmp" 'pi-code-link)
                     "/tmp")))
    (kill-buffer buf)))

;;; Retries, compaction, bash updates, truncation

(ert-deftest pi-code-render-test-retry-format ()
  "auto_retry_start renders as [retry N/M in Ns]."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "auto_retry_start"
                             :attempt 2 :maxAttempts 3 :delayMs 2000
                             :errorMessage "boom")))))
    (should (string-match-p "\\[retry 2/3 in 2s: boom\\]" text))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-summarization-retry ()
  "summarization retries render instead of being ignored."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "summarization_retry_scheduled"
                             :attempt 1 :maxAttempts 5 :delayMs 500
                             :errorMessage "e")))))
    (should (string-match-p "summarizing retry 1/5" text))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-extension-error ()
  "extension_error lands as a visible notice."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "extension_error"
                             :extensionPath "/x/y" :error "kaput")))))
    (should (string-match-p "extension error (/x/y): kaput" text))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-compaction-summary ()
  "compaction_end shows the reason and summary."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "compaction_end" :reason "threshold"
                             :result (:summary "summarized")
                             :aborted nil :willRetry nil)))))
    (should (string-match-p "context compacted (threshold): summarized" text))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-bash-update ()
  "bash_execution_update renders into the running tool block."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "bash_execution_update"
                             :id "b1" :delta "hello-bash")))))
    (should (string-match-p "hello-bash" text))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-truncation-hints ()
  "details.truncation and fullOutputPath surface as hints."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "tool_execution_end"
                             :toolCallId "c1" :toolName "bash"
                             :result (:content ((:type "text" :text "out"))
                                      :details (:truncation (:truncated t :totalLines 100 :outputLines 15)
                                                :fullOutputPath "/tmp/full.txt"))
                             :isError nil)))))
    (should (string-match-p "truncated: 15 of 100 lines" text))
    (should (string-match-p "full output: /tmp/full.txt" text))
    (kill-buffer buf)))

;;; Input area

(ert-deftest pi-code-render-test-input-prompt ()
  "The prompt marks the input area; input text excludes it."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert "history\n")
      (pi-code--insert-prompt)
      (goto-char (point-max))
      (should (pi-code--in-input-p))
      (insert "typed")
      (should (equal (pi-code--input-text) "typed"))
      (should (eq (get-text-property pi-code--history-end 'field)
                  'pi-code-input))
      (goto-char (1- (marker-position pi-code--history-end)))
      (should-not (pi-code--in-input-p)))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-input-prompt-own-line ()
  "Streaming text never shares a line with the input prompt."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert "* You\nhi\n")
      (pi-code--insert-prompt)
      (pi-code--handle-event '(:type "agent_start"))
      (pi-code--handle-event
       '(:type "message_start" :message (:role "assistant" :content nil)))
      (pi-code--handle-event
       '(:type "message_update"
         :assistantMessageEvent (:type "text_delta" :delta "partial")))
      ;; Prompt sits on its own line, not glued to the streamed text.
      (should (string-match-p "partial\n> " (buffer-string)))
      (should-not (string-match-p "partial> " (buffer-string)))
      (should (equal (pi-code--input-text) ""))
      (pi-code--handle-event
       '(:type "message_update"
         :assistantMessageEvent (:type "text_delta" :delta " answer")))
      (should (string-match-p "partial answer\n> " (buffer-string)))
      (should (equal (pi-code--input-text) "")))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-streaming-caret ()
  "A caret overlay tracks the streaming text and disappears when done."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert-prompt)
      (pi-code--handle-event '(:type "agent_start"))
      (pi-code--handle-event
       '(:type "message_start" :message (:role "assistant" :content nil)))
      (pi-code--handle-event
       '(:type "message_update"
         :assistantMessageEvent (:type "text_delta" :delta "hi")))
      (should (cl-some (lambda (o) (string-match-p "▌" (or (overlay-get o 'after-string) "")))
                       (overlays-in (point-min) (point-max))))
      (pi-code--handle-event
       '(:type "message_end"
         :message (:role "assistant" :content ((:type "text" :text "hi")))))
      (should-not (cl-some (lambda (o) (overlay-get o 'after-string))
                           (overlays-in (point-min) (point-max)))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-consecutive-user-single-rule ()
  "Two user messages in a row share one separator rule."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert-user "first")
      (pi-code--insert-user "second")
      (let ((rules 0)
            (rule (pi-code--rule-string)))
        (save-excursion
          (goto-char (point-min))
          (while (search-forward rule nil t) (setq rules (1+ rules))))
        (should (= rules 1)))
      (should (string-match-p "\\* You\n  first" (buffer-string)))
      (should (string-match-p "\\* You\n  second" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-rule-refresh ()
  "Existing separator rules are resized to the window width."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert-user "hi")
      (cl-letf (((symbol-function 'window-body-width) (lambda (&optional _) 40)))
        (pi-code--refresh-rules))
      (save-excursion
        (goto-char (point-min))
        (should (looking-at "─+$"))
        (should (= (- (match-end 0) (match-beginning 0)) 40))))
    (kill-buffer buf)))

;;; Turn navigation and copy

(ert-deftest pi-code-render-test-turn-navigation ()
  "M-n / M-p move between turn headers."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--render-user "q1")
      (pi-code--handle-event '(:type "message_end"
                               :message (:role "assistant"
                                          :content ((:type "text" :text "a1")))))
      (goto-char (point-min))
      (pi-code-next-turn)
      (should (looking-at "\\* You"))
      (pi-code-next-turn)
      (should (looking-at "\\* pi"))
      (pi-code-previous-turn)
      (should (looking-at "\\* You")))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-copy-last-reply ()
  "Copying the last reply puts it on the kill ring."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (setq pi-code--last-reply "reply-text")
      (pi-code-copy-last-reply)
      (should (equal (current-kill 0) "reply-text")))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-streamed-text-around-tool ()
  "Streamed text on both sides of a tool block is fontified."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (dolist (ev (list '(:type "message_start"
                           :message (:role "assistant" :content nil))
                        '(:type "message_update"
                           :assistantMessageEvent
                           (:type "text_delta" :delta "before ~alpha~ "))
                        '(:type "message_update"
                           :assistantMessageEvent
                           (:type "toolcall_start" :toolName "bash"))
                        '(:type "message_update"
                           :assistantMessageEvent
                           (:type "toolcall_end"
                            :toolCall (:name "bash"
                                       :arguments (:command "ls"))))
                        '(:type "message_update"
                           :assistantMessageEvent
                           (:type "text_delta" :delta "after ~beta~"))
                        '(:type "message_end"
                           :message (:role "assistant" :content nil))))
        (pi-code--handle-event ev))
      (should (equal (pi-code-render-test--face-at buf "alpha")
                     '(org-code)))
      (should (equal (pi-code-render-test--face-at buf "beta")
                     '(org-code)))
      (should (equal pi-code--last-reply "before ~alpha~ after ~beta~")))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-open-chat-prompt ()
  "open-chat inserts a banner and an input prompt."
  (let* ((stderr (generate-new-buffer " *pi-code-render-stderr*"))
         (session (pi-code-session--new "t" "/tmp" stderr))
         (buf (pi-code--open-chat session "tname")))
    (with-current-buffer buf
      (should (string-match-p "pi · tname" (buffer-string)))
      (goto-char (point-max))
      (should (pi-code--in-input-p))
      (should (string-prefix-p
               "> " (buffer-substring-no-properties
                     pi-code--history-end (point-max)))))
    (kill-buffer buf)
    (kill-buffer stderr)
    (when (get-buffer "*pi-code-proto:t*")
      (kill-buffer "*pi-code-proto:t*"))))

;;; Compact layout

(ert-deftest pi-code-render-test-no-blank-after-header ()
  "Headers are directly followed by the body."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "message_end"
                             :message (:role "user" :content "hello"))
                          '(:type "message_end"
                             :message (:role "assistant"
                                        :content ((:type "text"
                                                  :text "hi"))))))))
    (should (string-match-p "\\* You\n  hello" text))
    (should (string-match-p "\\* pi · …\n  hi" text))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-no-triple-newlines ()
  "A full turn with tools leaves no bank of blank lines."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "agent_start")
                          '(:type "message_start"
                             :message (:role "assistant" :content nil))
                          '(:type "message_update"
                             :assistantMessageEvent
                             (:type "text_delta" :delta "answer"))
                          '(:type "tool_execution_start"
                             :toolCallId "c1" :toolName "bash"
                             :args (:command "ls"))
                          '(:type "tool_execution_end"
                             :toolCallId "c1" :toolName "bash"
                             :result (:content ((:type "text" :text "out")))
                             :isError nil)
                          '(:type "message_end"
                             :message (:role "assistant" :content nil))
                          '(:type "agent_settled")))))
    (should-not (string-match-p "\n\n\n" text))
    (kill-buffer buf)))

;;; Thinking auto-fold

(ert-deftest pi-code-render-test-thinking-streamed-folds ()
  "Streamed thinking folds at thinking_end with a line count."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (dolist (ev (list '(:type "message_start"
                           :message (:role "assistant" :content nil))
                        '(:type "message_update"
                           :assistantMessageEvent (:type "thinking_start"))
                        '(:type "message_update"
                           :assistantMessageEvent
                           (:type "thinking_delta" :delta "line1\n"))
                        '(:type "message_update"
                           :assistantMessageEvent
                           (:type "thinking_delta" :delta "line2\n"))
                        '(:type "message_update"
                           :assistantMessageEvent
                           (:type "thinking_delta" :delta "line3\n"))
                        '(:type "message_update"
                           :assistantMessageEvent (:type "thinking_end"))
                        '(:type "message_end"
                           :message (:role "assistant" :content nil))))
        (pi-code--handle-event ev))
      (should (string-match-p "▹ thinking" (buffer-string)))
      (let ((ovs (pi-code--live-folds)))
        (should (= (length ovs) 1))
        (should (overlay-get (car ovs) 'invisible))
        (should (string-match-p
                 "▹ thinking · 3 lines"
                 (or (overlay-get (car ovs) 'after-string) "")))
        (pi-code--toggle-fold (car ovs))
        (should-not (overlay-get (car ovs) 'invisible))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-thinking-full-render-folds ()
  "Non-streamed thinking blocks fold too."
  (let* ((buf (pi-code-render-test--buffer))
         (_text (pi-code-render-test--events
                 buf (list '(:type "message_end"
                              :message (:role "assistant"
                                         :content ((:type "thinking"
                                                   :thinking "t1\nt2\n"))))))))
    (with-current-buffer buf
      (let ((ovs (pi-code--live-folds)))
        (should (= (length ovs) 1))
        (should (overlay-get (car ovs) 'invisible))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-thinking-fold-disabled ()
  "With pi-code-fold-thinking nil, thinking stays visible."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (let ((pi-code-fold-thinking nil))
        (pi-code--insert-thinking "visible\nthinking\n")
        (should-not (pi-code--live-folds))
        (should (string-match-p "visible" (buffer-string)))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-thinking-folds-on-cancel ()
  "A thinking block still folds when the agent settles without
sending thinking_end (e.g. the run was cancelled mid-thought)."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (dolist (ev (list '(:type "agent_start")
                        '(:type "message_start" :message (:role "assistant"))
                        '(:type "message_update"
                          :assistantMessageEvent (:type "thinking_start"))
                        '(:type "message_update"
                          :assistantMessageEvent
                          (:type "thinking_delta" :delta "line1\n"))
                        '(:type "message_update"
                          :assistantMessageEvent
                          (:type "thinking_delta" :delta "line2"))
                        '(:type "agent_settled")))
        (pi-code--handle-event ev))
      (let ((ovs (pi-code--live-folds)))
        (should (= (length ovs) 1))
        (should (overlay-get (car ovs) 'invisible)))
      (should-not pi-code--thinking-start))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-thinking-folds-before-text ()
  "A thinking block still folds when text starts without a
thinking_end in between (malformed or resumed stream)."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (dolist (ev (list '(:type "agent_start")
                        '(:type "message_start" :message (:role "assistant"))
                        '(:type "message_update"
                          :assistantMessageEvent (:type "thinking_start"))
                        '(:type "message_update"
                          :assistantMessageEvent
                          (:type "thinking_delta" :delta "line1\n"))
                        '(:type "message_update"
                          :assistantMessageEvent
                          (:type "text_delta" :delta "answer"))
                        '(:type "message_end"
                          :message (:role "assistant" :content nil))))
        (pi-code--handle-event ev))
      (let ((ovs (pi-code--live-folds)))
        (should (= (length ovs) 1)))
      (should (string-match-p "answer" (buffer-string))))
    (kill-buffer buf)))

;;; Header details, compaction delta, menu, images

(ert-deftest pi-code-render-test-format-tokens ()
  "Token counts render compactly."
  (should (equal (pi-code--format-tokens 60000) "60k"))
  (should (equal (pi-code--format-tokens 200000) "200k"))
  (should (equal (pi-code--format-tokens 10500) "10.5k"))
  (should (equal (pi-code--format-tokens 500) "500"))
  (should (null (pi-code--format-tokens nil))))

(ert-deftest pi-code-render-test-header-session-and-context ()
  "Header shows the session name, context tokens and token total."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (setq pi-code--session-name "my-session"
            pi-code--stats
            '(:tokens (:total 105000)
              :contextUsage (:tokens 60000 :contextWindow 200000
                             :percent 30)
              :cost 0.45))
      (pi-code--update-header)
      (let ((h (format "%s" header-line-format)))
        (should (string-match-p "my-session" h))
        (should (string-match-p "ctx 30% (60k/200k)" h))
        (should (string-match-p "tokens 105k" h))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-compaction-token-delta ()
  "compaction_end reports the before/after token estimate."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "compaction_end" :reason "threshold"
                             :result (:summary "summarized"
                                      :tokensBefore 150000
                                      :estimatedTokensAfter 32000)
                             :aborted nil :willRetry nil)))))
    (should (string-match-p "context compacted (threshold): summarized" text))
    (should (string-match-p "150k → 32k" text))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-set-title-frame ()
  "setTitle updates the buffer-local frame title."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--dispatch-ui-request
       nil '(:id "1" :method "setTitle" :title "Demo") buf)
      (should (equal (buffer-local-value 'frame-title-format buf)
                     "Demo — pi")))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-native-buffer ()
  "Chat buffers are real Org documents, not outline-minor-mode."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (should (derived-mode-p 'pi-code-chat-mode 'org-mode))
      (should-not (bound-and-true-p outline-minor-mode))
      (should (null font-lock-support-mode))
      (should (assq 'org-code face-remapping-alist))
      (should (assq 'org-link face-remapping-alist))
      (pi-code--insert-user "hello")
      (goto-char (point-min))
      (search-forward "* You")
      (beginning-of-line)
      (should (org-at-heading-p))
      (should (eq (get-text-property (point) 'face)
                  'pi-code-user-face)))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-image-fallback ()
  "Image content never leaks base64 when inline images are off."
  (let ((pi-code-inline-images nil))
    (should (string-match-p
             "\\[image image/png\\]"
             (pi-code--image-placeholder "AAAA" "image/png")))
    (let ((s (pi-code--format-tool-result
              '(:content ((:type "image" :data "AAAA"
                                 :mimeType "image/png"))
                :isError nil))))
      (should (string-match-p "\\[image image/png\\]" s))
      (should-not (string-match-p "AAAA" s)))))

;;; Tool block wrapping and colors

(ert-deftest pi-code-render-test-tool-line-glyph ()
  "Tool header lines carry just the glyph and name, no rule filler."
  (let* ((buf (pi-code-render-test--buffer))
         (text (pi-code-render-test--events
                buf (list '(:type "tool_execution_start"
                             :toolCallId "c1" :toolName "bash"
                             :args (:command "ls"))))))
    (should (string-match-p "\\$ ▸ bash$" text))
    (should-not (string-match-p "bash ─" text))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-tool-arg-faces ()
  "Tool arg keys and values use distinct faces."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--handle-event '(:type "tool_execution_start"
                               :toolCallId "c1" :toolName "bash"
                               :args (:command "ls")))
      (should (eq (pi-code-render-test--face-at buf "command")
                  'pi-code-tool-key-face))
      (should (eq (pi-code-render-test--face-at buf ": ls")
                  'pi-code-tool-args-face)))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-tool-status-faces ()
  "Running shows a busy ◐, results a green ✔ or red ✖."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--handle-event '(:type "tool_execution_start"
                               :toolCallId "c1" :toolName "bash"
                               :args (:command "ls")))
      (should (eq (pi-code-render-test--face-at buf "◐")
                  'pi-code-header-busy-face))
      (pi-code--handle-event '(:type "tool_execution_end"
                               :toolCallId "c1" :toolName "bash"
                               :result (:content ((:type "text" :text "done")))
                               :isError nil))
      (should (eq (pi-code-render-test--face-at buf "✔") 'success))
      (pi-code--handle-event '(:type "tool_execution_end"
                               :toolCallId "c2" :toolName "bash"
                               :result (:content ((:type "text" :text "bad")))
                               :isError t))
      (should (eq (pi-code-render-test--face-at buf "✖")
                  'pi-code-error-face)))
    (kill-buffer buf)))

;;; Body indent (P2 #9)

(ert-deftest pi-code-render-test-body-indent-user ()
  "User body lines are indented without trailing whitespace."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--render-user "a\nb")
      (should (string-match-p "\\* You\n  a\n  b\n" (buffer-string)))
      (should-not (string-match-p " +\n" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-body-indent-streamed ()
  "Split deltas share one indent; internal newlines indent too."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (dolist (ev (list '(:type "message_start"
                           :message (:role "assistant" :content nil))
                        '(:type "message_update"
                           :assistantMessageEvent
                           (:type "text_delta" :delta "Hel"))
                        '(:type "message_update"
                           :assistantMessageEvent
                           (:type "text_delta" :delta "lo"))
                        '(:type "message_update"
                           :assistantMessageEvent
                           (:type "text_delta" :delta "\nnext"))
                        '(:type "message_end"
                           :message (:role "assistant" :content nil))))
        (pi-code--handle-event ev))
      (should (string-match-p "  Hello\n  next\n" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-body-indent-empty-delta ()
  "Empty deltas insert nothing, not even indentation."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (let ((before (buffer-string)))
        (pi-code--handle-event '(:type "message_update"
                                 :assistantMessageEvent
                                 (:type "text_delta" :delta "")))
        (should (equal (buffer-string) before))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-body-indent-custom ()
  "A custom `pi-code-body-indent' (or empty) is honored."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (let ((pi-code-body-indent "    "))
        (pi-code--render-user "hi")
        (should (string-match-p "\\* You\n    hi\n" (buffer-string)))))
    (kill-buffer buf))
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (let ((pi-code-body-indent ""))
        (pi-code--render-user "hi")
        (should (string-match-p "\\* You\nhi\n" (buffer-string)))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-body-indent-org ()
  "Indented headlines and src blocks still highlight."
  (let* ((buf (pi-code-render-test--buffer))
         (_text (pi-code-render-test--events
                 buf (list '(:type "message_end"
                              :message (:role "assistant"
                                         :content ((:type "text" :text "* T\n#+begin_src el\n(+ 1 2)\n#+end_src"))))))))
    (should (eq (pi-code-render-test--face-at buf "T")
                'pi-code-assistant-face))
    (should (equal (pi-code-render-test--face-at buf "+ 1 2")
                   '(org-block)))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-thinking-comment-block ()
  "Thinking is wrapped in a comment block so export omits it."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert-thinking "reasoning line\n")
      (let ((text (buffer-string)))
        (should (string-match-p "^  #\\+begin_comment$" text))
        (should (string-match-p "^  #\\+end_comment$" text))
        (should (string-match-p "^  reasoning line$" text))))
    (kill-buffer buf))
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--handle-event '(:type "agent_start"))
      (pi-code--handle-event '(:type "message_start" :message (:role "assistant")))
      (pi-code--handle-event '(:type "message_update"
                               :assistantMessageEvent (:type "thinking_start")))
      (pi-code--handle-event '(:type "message_update"
                               :assistantMessageEvent
                               (:type "thinking_delta" :delta "streamed thought\n")))
      (pi-code--handle-event '(:type "message_update"
                               :assistantMessageEvent (:type "thinking_end")))
      (let ((text (buffer-string)))
        (should (string-match-p "^  #\\+begin_comment$" text))
        (should (string-match-p "^  #\\+end_comment$" text))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-thinking-label-plain ()
  "The thinking label has no trailing rule filler."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert-thinking-label)
      (should (string-match-p "^  ▹ thinking$" (buffer-string)))
      (should-not (string-match-p "▹ thinking ─" (buffer-string))))
    (kill-buffer buf)))

(defun pi-code-render-test--org-faces (text)
  "Render TEXT as one assistant message, return the buffer."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--handle-event
       (list :type "message_end"
             :message (list :role "assistant"
                            :content (list (list :type "text"
                                                 :text text))))))
    buf))

(ert-deftest pi-code-render-test-org-emphasis ()
  "Org *bold*, /italic/ and ~code~ get native Org faces."
  (let ((buf (pi-code-render-test--org-faces
              "*bold* and /italic/ and ~code~")))
    (should (equal (pi-code-render-test--face-at buf "bold") '(bold)))
    (should (memq 'pi-code-emphasis-face
                  (pi-code-render-test--face-at buf "italic")))
    (should (equal (pi-code-render-test--face-at buf "code") '(org-code)))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-src-block ()
  "Org src bodies keep native block faces; keyword lines stay plain."
  (let ((buf (pi-code-render-test--org-faces
              "#+begin_src fundamental\nhello\n#+end_src")))
    (should (equal (pi-code-render-test--face-at buf "hello")
                   '(org-block)))
    (should (eq (pi-code-render-test--face-at buf "begin_src")
                'org-block-begin-line))
    (should (pi-code-render-test--prop-at buf "hello" 'wrap-prefix))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-link ()
  "Org [[url][label]] labels get the native link face."
  (let ((buf (pi-code-render-test--org-faces
              "See [[https://example.com][the site]].")))
    (should (eq (pi-code-render-test--face-at buf "site") 'org-link))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-table ()
  "Org tables get the native table face."
  (let ((buf (pi-code-render-test--org-faces
              "| a | b |\n|---+---|\n| 1 | 2 |")))
    (should (eq (pi-code-render-test--face-at buf "| a |") 'org-table))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-table-align ()
  "Org tables are aligned in place, keeping faces."
  (let ((buf (pi-code-render-test--org-faces
              "| a | bb |\n|---+---|\n| c | d |")))
    (with-current-buffer buf
      (let ((rows (split-string (buffer-string) "\n" t)))
        (setq rows (cl-remove-if-not
                    (lambda (l) (string-match-p "^ *|" l)) rows))
        (should (= (length rows) 3))
        (should (= (length (nth 0 rows)) (length (nth 1 rows))))
        (should (= (length (nth 1 rows)) (length (nth 2 rows))))))
    (should (eq (pi-code-render-test--face-at buf "| a |") 'org-table))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-cjk-emphasis ()
  "Emphasis next to CJK text fontifies; ASCII lookalikes don't."
  (let ((buf (pi-code-render-test--org-faces
              "是*粗体*的 /类地行星/：水、金")))
    (should (equal (pi-code-render-test--face-at buf "粗体") '(bold)))
    (should (memq 'pi-code-emphasis-face
                  (pi-code-render-test--face-at buf "类地行星")))
    (kill-buffer buf))
  (let ((buf (pi-code-render-test--org-faces
              "go /tmp/nonexistent-xyz ok a=b done")))
    (should-not (pi-code-render-test--face-at buf "nonexistent-xyz"))
    (should-not (pi-code-render-test--face-at buf "a=b"))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-cjk-local-only ()
  "CJK emphasis setup never leaks into global Org state."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (should (local-variable-p 'org-emph-re))
      (should (local-variable-p 'org-emphasis-regexp-components))
      (should (equal (default-value 'org-emphasis-regexp-components)
                     '("-[:space:]('\"{" "-[:space:].,:!?;'\")}\\[" "[:space:]" "." 1))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-headline-star-plain ()
  "The headline star itself is not bolded as a bullet."
  (let ((buf (pi-code-render-test--org-faces "* Head one\n")))
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "* Head")
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'pi-code-assistant-face)))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-headline ()
  "Indented Org headlines face like assistant headers."
  (let ((buf (pi-code-render-test--org-faces "* Head one\n** Head two\n")))
    (should (eq (pi-code-render-test--face-at buf "Head one")
                'pi-code-assistant-face))
    (should (eq (pi-code-render-test--face-at buf "Head two")
                'pi-code-assistant-face))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-structure-skips-src ()
  "Headline-looking lines inside src blocks keep the block face."
  (let ((buf (pi-code-render-test--org-faces
              "#+begin_src fundamental\n* not a headline\n#+end_src")))
    (should (equal (pi-code-render-test--face-at buf "not a headline")
                   '(org-block)))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-headline-demoted ()
  "Answer headlines are dedented to column 0 and demoted one level."
  (let ((buf (pi-code-render-test--org-faces
              "* Head one\n** Head two\n*** Head three\n")))
    (with-current-buffer buf
      (should (string-match-p "^\\*\\* Head one" (buffer-string)))
      (should (string-match-p "^\\*\\*\\* Head two" (buffer-string)))
      (should (string-match-p "^\\*\\*\\*\\* Head three" (buffer-string)))
      (should-not (string-match-p "^[ \t]+\\*" (buffer-string))))
    (should (eq (pi-code-render-test--face-at buf "Head one")
                'pi-code-assistant-face))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-headline-demote-skips-src ()
  "Stars inside src blocks are code, not headlines, and are not demoted."
  (let ((buf (pi-code-render-test--org-faces
              "#+begin_src org\n* raw star\n#+end_src")))
    (with-current-buffer buf
      (should (string-match-p "\\* raw star" (buffer-string)))
      (should-not (string-match-p "\\*\\* raw star" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-answer-headline-native-fold ()
  "Answer headlines are real level-2 Org headlines and fold via org-cycle."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert-user "q")
      (pi-code--handle-event
       (list :type "message_end"
             :message (list :role "assistant"
                            :content (list (list :type "text"
                                                 :text (concat "* 主题\n\n"
                                                               "section body\n\n"
                                                               "* 第二节\n\ntail"))))))
      (goto-char (point-min))
      (search-forward "主题")
      (beginning-of-line)
      (should (org-at-heading-p))
      (should (= (org-current-level) 2))
      (pi-code-toggle-fold)
      (should (invisible-p (save-excursion
                             (goto-char (point-min))
                             (search-forward "section body")
                             (line-beginning-position))))
      (pi-code-toggle-fold)
      (should-not (invisible-p (save-excursion
                                 (goto-char (point-min))
                                 (search-forward "section body")
                                 (line-beginning-position)))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-org-emphasis-cjk-comma ()
  "Italic before a CJK comma parses; marker-adjacent punctuation is fine."
  (let ((buf (pi-code-render-test--org-faces
              "1. 卫星数为 /近似值/，随观测进展会变动")))
    (should (memq 'pi-code-emphasis-face
                  (pi-code-render-test--face-at buf "近似值")))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-tab-cycles-turn ()
  "TAB on a turn header folds and unfolds the turn via Org."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert-user "hello")
      (goto-char (point-min))
      (search-forward "* You")
      (beginning-of-line)
      (should (org-at-heading-p))
      (pi-code-toggle-fold)
      (should (invisible-p (line-beginning-position 2)))
      (pi-code-toggle-fold)
      (should-not (invisible-p (line-beginning-position 2))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-tab-toggles-placeholder ()
  "TAB on a fold placeholder expands and refolds it."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert-thinking "line1\nline2\n")
      (let ((ov (car (pi-code--live-folds))))
        (should (overlay-get ov 'invisible))
        (goto-char (overlay-end ov))
        (pi-code-toggle-fold)
        (should-not (overlay-get ov 'invisible))
        (pi-code-toggle-fold)
        (should (overlay-get ov 'invisible))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-ret-toggles-placeholder ()
  "RET on a fold placeholder expands it."
  (let ((buf (pi-code-render-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert-thinking "line1\nline2\n")
      (let ((ov (car (pi-code--live-folds))))
        (goto-char (overlay-end ov))
        (pi-code--fold-toggle-at-point)
        (should-not (overlay-get ov 'invisible))))
    (kill-buffer buf)))

(ert-deftest pi-code-render-test-ret-is-newline ()
  "RET stays a plain newline, not `org-return'."
  (should (eq (lookup-key pi-code-chat-mode-map (kbd "RET")) 'newline)))

(provide 'pi-code-render-test)
;;; pi-code-render-test.el ends here
