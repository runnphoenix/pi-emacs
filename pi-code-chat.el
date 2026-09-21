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

;; NOTE: evil-define-key is a macro, so it cannot be called at runtime.
;; evil-define-key* is its function counterpart and is safe here.
(declare-function evil-define-key* "evil-core" t t)

;;; Faces

(defface pi-code-user-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the user prompt header."
  :group 'pi-code)

(defface pi-code-assistant-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the assistant header."
  :group 'pi-code)

(defface pi-code-thinking-face
  '((t :inherit shadow :slant italic))
  "Face for streamed thinking/reasoning text."
  :group 'pi-code)

(defface pi-code-tool-face
  '((t :inherit font-lock-builtin-face))
  "Face for tool call lines."
  :group 'pi-code)

(defface pi-code-error-face
  '((t :inherit error))
  "Face for errors and aborted notices."
  :group 'pi-code)

(defface pi-code-meta-face
  '((t :inherit shadow))
  "Face for meta lines (stats, notices)."
  :group 'pi-code)

;;; Buffer-local state

(defvar-local pi-code--session nil "RPC session for this chat buffer.")
(defvar-local pi-code--history-end nil "Marker: end of rendered history.")
(defvar-local pi-code--live-start nil "Marker: start of live-replaced block, or nil.")
(defvar-local pi-code--streaming-p nil "Non-nil while the agent is streaming.")
(defvar-local pi-code--streamed-current nil "Non-nil if current message got deltas.")
(defvar-local pi-code--last-index nil "Last contentIndex seen in message_update.")
(defvar-local pi-code--pending-echo nil "Optimistically rendered user text awaiting echo.")
(defvar-local pi-code--echoed-user nil "User text consumed by message_start echo.")
(defvar-local pi-code--assistant-open nil "Non-nil if ## pi header was emitted for current message.")
(defvar-local pi-code--stats nil "Last get_session_stats data plist.")
(defvar-local pi-code--ext-status nil
  "Alist of (STATUS-KEY . TEXT) from extension setStatus requests.")
(defvar-local pi-code--widgets nil
  "Alist of (WIDGET-KEY START-MARKER . END-MARKER) for setWidget blocks.")

(defconst pi-code--display-cap 30000
  "Max chars of one tool result block shown; beyond this it is cut.")

;;; Mode

(defvar pi-code-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'pi-code-send-or-abort)
    (define-key map (kbd "C-c C-k") #'pi-code-abort)
    (define-key map (kbd "C-c C-s") #'pi-code-steer)
    map)
  "Keymap for `pi-code-chat-mode'.")

(define-derived-mode pi-code-chat-mode text-mode "pi-code"
  "Major mode for chatting with the pi coding agent."
  :group 'pi-code
  (setq-local truncate-lines nil))

(defun pi-code--chat-evil-bindings ()
  "Apply chat keys to evil normal/insert states."
  (evil-define-key* '(normal insert) pi-code-chat-mode-map
    (kbd "C-c C-c") #'pi-code-send-or-abort
    (kbd "C-c C-k") #'pi-code-abort
    (kbd "C-c C-s") #'pi-code-steer))

(defun pi-code--maybe-bind-evil ()
  "Apply evil bindings now or when evil loads."
  (if (featurep 'evil)
      (pi-code--chat-evil-bindings)
    (with-eval-after-load 'evil #'pi-code--chat-evil-bindings)))

(pi-code--maybe-bind-evil)

;;; Low-level insertion

(defun pi-code--insert (text &rest props)
  "Insert TEXT with PROPS at history end, keeping it read-only.
The rear boundary stays writable so the input area can follow.
The history marker does not follow user typing (insertion-type
nil); it is advanced explicitly here."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char pi-code--history-end)
      (insert (apply #'propertize text
                     'read-only t 'rear-nonsticky t props))
      (set-marker pi-code--history-end (point)))))

(defun pi-code--finalize-block ()
  "End any live-replaced block."
  (setq pi-code--live-start nil))

(defun pi-code--replace-live (text &rest props)
  "Replace the live block (or start one) with TEXT."
  (let ((inhibit-read-only t))
    (unless pi-code--live-start
      (setq pi-code--live-start (copy-marker pi-code--history-end nil)))
    (delete-region pi-code--live-start (marker-position pi-code--history-end))
    (goto-char pi-code--live-start)
    (insert (apply #'propertize text 'read-only t 'rear-nonsticky t props))
    (set-marker pi-code--history-end (point))))

;;; Buffer setup

(defun pi-code--open-chat (session name)
  "Open a chat buffer for SESSION named NAME and return it."
  (let ((buf (get-buffer-create (format "*pi-code:%s*" name))))
    (with-current-buffer buf
      (pi-code-chat-mode)
      (setq pi-code--session session
            pi-code--history-end (copy-marker (point-max) nil)
            pi-code--streaming-p nil
            pi-code--streamed-current nil
            pi-code--assistant-open nil
            pi-code--last-index nil
            pi-code--pending-echo nil
            pi-code--echoed-user nil
            pi-code--stats nil)
      (pi-code-rpc-add-event-function session #'pi-code--on-event)
      (pi-code-rpc-set-ui-handler session #'pi-code--on-ui-request)
      (pi-code--update-header)
      (pi-code--refresh-stats))
    buf))

;;; Header line

(defun pi-code--model-name ()
  (let ((state (and pi-code--session
                    (pi-code-session-state pi-code--session))))
    (or (plist-get (plist-get state :model) :name) "…")))

(defun pi-code--update-header ()
  "Refresh the header line from session state and stats."
  (let* ((ctx (and pi-code--stats (plist-get pi-code--stats :contextUsage)))
         (pct (and ctx (plist-get ctx :percent)))
         (cost (and pi-code--stats (plist-get pi-code--stats :cost))))
    (setq header-line-format
          (list (format " pi %s | %s | %s"
                        (pi-code--model-name)
                        (if pi-code--streaming-p "● working" "○ idle")
                        (if pct (format "ctx %s%%" pct) "ctx --"))
                (when cost (format " | $%.4f" cost))
                (when pi-code--ext-status
                  (format " | %s"
                          (string-join (mapcar #'cdr pi-code--ext-status)
                                       " | ")))))))

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

(defun pi-code--input-text ()
  "Return the trimmed text of the input area."
  (string-trim
   (buffer-substring-no-properties pi-code--history-end (point-max))))

(defun pi-code--clear-input ()
  (let ((inhibit-read-only t))
    (delete-region pi-code--history-end (point-max))))

(defun pi-code-send-or-abort ()
  "Send the input as a prompt, or abort if the agent is working."
  (interactive)
  (if pi-code--streaming-p
      (pi-code-abort)
    (pi-code--send-prompt (pi-code--input-text) nil)))

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
                 (pi-code--insert
                  (format "\n[send failed: %s]\n"
                          (or (plist-get resp :error) "unknown"))
                  'face 'pi-code-error-face))))))))))

(defun pi-code-abort ()
  "Abort the current agent run."
  (interactive)
  (when (and pi-code--session (pi-code-rpc-alive-p pi-code--session))
    (pi-code-rpc-send pi-code--session '(:type "abort"))
    (pi-code--insert "\n[aborted]\n" 'face 'pi-code-error-face)))

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
        (pi-code--insert (format "\n[steer queued: %s]\n" text)
                         'face 'pi-code-meta-face)))))

;;; Rendering messages

(defun pi-code--render-user (text)
  (pi-code--insert (format "\n## You\n\n%s\n" text)))

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
      (pi-code--insert (format "\n## You\n\n%s\n" (pi-code--message-text msg))))
     ((equal role "assistant")
      (pi-code--insert "\n## pi\n\n" 'face 'pi-code-assistant-face)
      (dolist (b (plist-get msg :content))
        (when (listp b)
          (cond
           ((equal (plist-get b :type) "text")
            (pi-code--insert (or (plist-get b :text) "")))
           ((equal (plist-get b :type) "thinking")
            (pi-code--insert (or (plist-get b :thinking) "")
                             'face 'pi-code-thinking-face))
           ((equal (plist-get b :type) "toolCall")
            (pi-code--insert
             (format "\n▸ %s %s\n"
                     (plist-get b :name)
                     (pi-code--one-line
                      (json-encode (plist-get b :arguments))))
             'face 'pi-code-tool-face))))))
     ((equal role "toolResult")
      (pi-code--insert (pi-code--format-tool-result msg)
                       'face 'pi-code-meta-face)))))

(defun pi-code--one-line (s)
  "Collapse S to one line, truncated."
  (let ((one (replace-regexp-in-string "[\r\n]+" " " (or s ""))))
    (if (> (length one) 300) (concat (substring one 0 300) "…") one)))

(defun pi-code--format-tool-result (msg)
  "Format a toolResult MSG for display, capped in size."
  (let* ((parts
          (mapcar (lambda (c)
                    (cond ((stringp c) c)
                          ((equal (plist-get c :type) "text")
                           (or (plist-get c :text) ""))
                          (t (json-encode c))))
                  (plist-get msg :content)))
         (text (string-join parts "")))
    (when (> (length text) pi-code--display-cap)
      (setq text (concat (substring text 0 pi-code--display-cap)
                         "\n…[output truncated for display]")))
    (format "  └ %s%s\n"
            (if (plist-get msg :isError) "[error] " "")
            text)))

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
            pi-code--assistant-open nil
            pi-code--last-index nil)
      (pi-code--update-header))
     ((equal type "agent_settled")
      (setq pi-code--streaming-p nil)
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
      (pi-code--insert
       (format "\n▸ %s %s\n"
               (plist-get event :toolName)
               (pi-code--one-line
                (json-encode (plist-get event :args))))
       'face 'pi-code-tool-face))
     ((equal type "tool_execution_update")
      (pi-code--replace-live
       (concat (pi-code--format-tool-result
                (list :content
                      (plist-get (plist-get event :partialResult) :content)
                      :isError nil))
               "")))
     ((equal type "tool_execution_end")
      (pi-code--replace-live
       (pi-code--format-tool-result
        (list :content (plist-get (plist-get event :result) :content)
              :isError (plist-get event :isError))))
      (pi-code--finalize-block))
     ((equal type "compaction_start")
      (pi-code--insert "\n[compacting context…]\n" 'face 'pi-code-meta-face))
     ((equal type "compaction_end")
      (pi-code--insert "[compaction done]\n" 'face 'pi-code-meta-face))
     ((equal type "auto_retry_start")
      (pi-code--insert
       (format "\n[retrying (%s)…]\n"
               (or (plist-get event :errorMessage) "transient error"))
       'face 'pi-code-meta-face))
     ((equal type "auto_retry_end")
      (unless (plist-get event :success)
        (pi-code--insert
         (format "\n[retry failed: %s]\n"
                 (or (plist-get event :finalError) "unknown error"))
         'face 'pi-code-error-face)))
     ((equal type "queue_update") nil)
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
            (pi-code--insert (format "\n## You\n\n%s\n" text)))))
       ((equal role "assistant")
        (pi-code--insert "\n## pi\n\n" 'face 'pi-code-assistant-face)
        (setq pi-code--assistant-open t))))))

(defun pi-code--ev-message-update (delta)
  "Render one streaming DELTA event."
  (when delta
    (setq pi-code--streamed-current t)
    (let ((dtype (plist-get delta :type))
          (idx (plist-get delta :contentIndex)))
      ;; New content block: separate visually.
      (when (and idx (not (equal idx pi-code--last-index)))
        (setq pi-code--last-index idx)
        (when (string-prefix-p "thinking" (or dtype ""))
          (pi-code--insert "\n")))
      (cond
       ((equal dtype "text_delta")
        (pi-code--insert (or (plist-get delta :delta) "")))
       ((equal dtype "thinking_delta")
        (pi-code--insert (or (plist-get delta :delta) "")
                         'face 'pi-code-thinking-face))
       ((equal dtype "toolcall_start")
        (pi-code--insert
         (format "\n▸ %s\n" (or (plist-get delta :toolName) "?"))
         'face 'pi-code-tool-face))
       ((equal dtype "toolcall_end")
        (let ((call (plist-get delta :toolCall)))
          (when call
            (pi-code--insert
             (format "  └ %s\n"
                     (pi-code--one-line
                      (json-encode (plist-get call :arguments))))
             'face 'pi-code-meta-face))))
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
           (t (pi-code--insert (format "\n## You\n\n%s\n" text))))))
       ((equal role "assistant")
        (unless (or pi-code--streamed-current pi-code--assistant-open)
          (pi-code--insert "\n## pi\n\n" 'face 'pi-code-assistant-face)
          (dolist (b (plist-get msg :content))
            (when (listp b)
              (cond
               ((equal (plist-get b :type) "text")
                (pi-code--insert (or (plist-get b :text) "")))
               ((equal (plist-get b :type) "thinking")
                (pi-code--insert (or (plist-get b :thinking) "")
                                 'face 'pi-code-thinking-face))
               ((equal (plist-get b :type) "toolCall")
                (pi-code--insert
                 (format "\n▸ %s %s\n"
                         (plist-get b :name)
                         (pi-code--one-line
                          (json-encode (plist-get b :arguments))))
                 'face 'pi-code-tool-face))))))
        (let ((err (plist-get msg :errorMessage)))
          (when err
            (pi-code--insert (format "\n[error: %s]\n"
                                     (pi-code--one-line err))
                             'face 'pi-code-error-face)))
        (setq pi-code--streamed-current nil
              pi-code--assistant-open nil))
       ((equal role "toolResult")
        (unless pi-code--streamed-current
          (pi-code--insert (pi-code--format-tool-result msg)
                           'face 'pi-code-meta-face))))))
  (pi-code--insert "\n"))

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
            (let ((inhibit-read-only t))
              (delete-region pi-code--history-end (point-max))
              (goto-char (point-max))
              (insert (or (plist-get request :text) "")))))))
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
      (let ((s (copy-marker pi-code--history-end nil)))
        (goto-char pi-code--history-end)
        (insert (propertize (concat "\n" (string-join lines "\n") "\n")
                            'read-only t 'rear-nonsticky t
                            'face 'pi-code-meta-face))
        (set-marker pi-code--history-end (point))
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
