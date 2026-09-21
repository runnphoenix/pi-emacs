;;; pi-code-chat-test.el --- ERT tests for pi-code-chat -*- lexical-binding: t; -*-

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'pi-code-chat)

(defun pi-code-chat-test--buffer ()
  "Make a temp chat buffer with markers initialized."
  (let ((buf (generate-new-buffer " *pi-code-chat-test*")))
    (with-current-buffer buf
      (pi-code-chat-mode)
      (setq pi-code--session nil
            pi-code--history-end (copy-marker (point-max) nil)
            pi-code--streaming-p nil
            pi-code--streamed-current nil
            pi-code--assistant-open nil
            pi-code--last-index nil
            pi-code--pending-echo nil
            pi-code--echoed-user nil
            pi-code--stats nil))
    buf))

(defun pi-code-chat-test--count (regexp string)
  (with-temp-buffer
    (insert string)
    (how-many regexp (point-min) (point-max))))

(defun pi-code-chat-test--events (buf events)
  (with-current-buffer buf
    (dolist (ev events)
      (pi-code--handle-event ev)))
  (with-current-buffer buf (buffer-string)))

(ert-deftest pi-code-chat-test-user-echo-dedup ()
  "Optimistic user render is not duplicated by start+end echoes."
  (let ((buf (pi-code-chat-test--buffer)))
    (with-current-buffer buf
      (pi-code--render-user "hello")
      (setq pi-code--pending-echo "hello")
      (pi-code--handle-event '(:type "message_start"
                               :message (:role "user" :content "hello")))
      (pi-code--handle-event '(:type "message_end"
                               :message (:role "user" :content "hello"))))
    (with-current-buffer buf
      (should (= (pi-code-chat-test--count "## You" (buffer-string)) 1))
      (should (null pi-code--pending-echo)))
    (kill-buffer buf)))

(ert-deftest pi-code-chat-test-assistant-error ()
  "Error stop produces one header plus a visible error line."
  (let* ((buf (pi-code-chat-test--buffer))
         (text (pi-code-chat-test--events
                buf (list '(:type "agent_start")
                          '(:type "message_start"
                             :message (:role "assistant" :content nil))
                          '(:type "message_end"
                             :message (:role "assistant" :content nil
                                        :stopReason "error"
                                        :errorMessage "404 boom"))
                          '(:type "agent_settled")))))
    (should (= (pi-code-chat-test--count "## pi" text) 1))
    (should (string-match-p "\\[error: 404 boom\\]" text))
    (kill-buffer buf)))

(ert-deftest pi-code-chat-test-streaming-text ()
  "Text deltas append; message_end does not duplicate."
  (let* ((buf (pi-code-chat-test--buffer))
         (text (pi-code-chat-test--events
                buf (list '(:type "agent_start")
                          '(:type "message_start"
                             :message (:role "assistant" :content nil))
                          '(:type "message_update"
                             :assistantMessageEvent (:type "text_start" :contentIndex 0))
                          '(:type "message_update"
                             :assistantMessageEvent (:type "text_delta" :contentIndex 0 :delta "Hel"))
                          '(:type "message_update"
                             :assistantMessageEvent (:type "text_delta" :contentIndex 0 :delta "lo"))
                          '(:type "message_end"
                             :message (:role "assistant"
                                        :content ((:type "text" :text "Hello"))))
                          '(:type "agent_settled")))))
    (should (string-match-p "## pi" text))
    (should (string-match-p "Hello" text))
    (should (= (pi-code-chat-test--count "Hello" text) 1))
    (kill-buffer buf)))

(ert-deftest pi-code-chat-test-nonstreamed-full-render ()
  "A message_end with no deltas renders the full content."
  (let* ((buf (pi-code-chat-test--buffer))
         (text (pi-code-chat-test--events
                buf (list '(:type "message_end"
                             :message (:role "assistant"
                                        :content ((:type "text" :text "full answer")
                                                  (:type "toolCall" :id "c1"
                                                   :name "bash"
                                                   :arguments (:command "ls")))))))))
    (should (string-match-p "full answer" text))
    (should (string-match-p "▸ bash" text))
    (kill-buffer buf)))

(ert-deftest pi-code-chat-test-tool-live-replace ()
  "Partial tool output is replaced by the final result."
  (let* ((buf (pi-code-chat-test--buffer))
         (text (pi-code-chat-test--events
                buf (list '(:type "tool_execution_start"
                             :toolCallId "c1" :toolName "bash"
                             :args (:command "ls"))
                          '(:type "tool_execution_update"
                             :toolCallId "c1" :toolName "bash"
                             :args (:command "ls")
                             :partialResult (:content ((:type "text" :text "par"))))
                          '(:type "tool_execution_end"
                             :toolCallId "c1" :toolName "bash"
                             :result (:content ((:type "text" :text "partial-full")))
                             :isError nil)))))
    (should (string-match-p "partial-full" text))
    (should (= (pi-code-chat-test--count "└" text) 1))
    (kill-buffer buf)))

(ert-deftest pi-code-chat-test-history-readonly ()
  "Rendered history is read-only; input tail is writable."
  (let ((buf (pi-code-chat-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert "history")
      (insert "input")
      (should (get-text-property (1- (marker-position pi-code--history-end))
                                 'read-only))
      (should-not (get-text-property (point-max) 'read-only)))
    (kill-buffer buf)))

(ert-deftest pi-code-chat-test-input-after-history ()
  "Typing right after history must not signal text-read-only."
  (let ((buf (pi-code-chat-test--buffer)))
    (with-current-buffer buf
      (pi-code--insert "history\n")
      (goto-char (point-max))
      (insert "typed")
      (should (equal (buffer-substring-no-properties
                      pi-code--history-end (point-max))
                     "typed")))
    (kill-buffer buf)))

(ert-deftest pi-code-chat-test-one-line ()
  (should (equal (pi-code--one-line "a\nb\nc") "a b c"))
  (should (string-suffix-p "…" (pi-code--one-line (make-string 500 ?x)))))

(ert-deftest pi-code-chat-test-ui-status ()
  "setStatus stores and clears entries; header reflects them."
  (let ((buf (pi-code-chat-test--buffer)))
    (with-current-buffer buf
      (pi-code--dispatch-ui-request
       nil '(:id "1" :method "setStatus" :statusKey "k" :statusText "busy") buf)
      (should (equal (cdr (assoc "k" pi-code--ext-status)) "busy"))
      (should (string-match-p "busy" (format "%s" header-line-format)))
      (pi-code--dispatch-ui-request
       nil '(:id "2" :method "setStatus" :statusKey "k") buf)
      (should (null (assoc "k" pi-code--ext-status))))
    (kill-buffer buf)))

(ert-deftest pi-code-chat-test-ui-widget ()
  "setWidget inserts a block; clearing removes it."
  (let ((buf (pi-code-chat-test--buffer)))
    (with-current-buffer buf
      (pi-code--dispatch-ui-request
       nil '(:id "1" :method "setWidget" :widgetKey "w"
             :widgetLines ("L1" "L2")) buf)
      (should (string-match-p "L1\nL2" (buffer-string)))
      (pi-code--dispatch-ui-request
       nil '(:id "2" :method "setWidget" :widgetKey "w") buf)
      (should-not (string-match-p "L1" (buffer-string))))
    (kill-buffer buf)))

(ert-deftest pi-code-chat-test-ui-set-editor-text ()
  "set_editor_text replaces the input area only."
  (let ((buf (pi-code-chat-test--buffer)))
    (with-current-buffer buf
      (setq pi-code--session nil)
      (cl-letf (((symbol-function 'pi-code-rpc-alive-p) (lambda (_s) t)))
        (pi-code--insert "history\n")
        (goto-char (point-max))
        (insert "old input")
        (pi-code--dispatch-ui-request
         nil '(:id "1" :method "set_editor_text" :text "new input") buf)
        (should (equal (buffer-substring-no-properties
                        pi-code--history-end (point-max))
                       "new input"))
        (should (string-match-p "history" (buffer-string)))))
    (kill-buffer buf)))

(ert-deftest pi-code-chat-test-ui-editor-opens ()
  "editor request opens a prefilled edit buffer."
  (cl-letf (((symbol-function 'pop-to-buffer) #'switch-to-buffer))
    (pi-code--open-editor nil "rid" "T" "line1\nline2")
    (let ((buf (get-buffer "*pi-code-edit:T*")))
      (should buf)
      (with-current-buffer buf
        (should (equal (buffer-string) "line1\nline2"))
        (should (equal pi-code-edit--request-id "rid")))
      (kill-buffer buf))))

(provide 'pi-code-chat-test)
;;; pi-code-chat-test.el ends here
