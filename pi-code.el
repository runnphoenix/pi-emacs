;;; pi-code.el --- Emacs frontend for the pi coding agent -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Chris
;; Author: Chris
;; Keywords: ai, tools
;; URL: https://pi.dev
;; Package-Requires: ((emacs "30.1"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; pi-code.el embeds the pi coding agent (https://pi.dev) in Emacs.
;; The agent runs as a subprocess in RPC mode (`pi --mode rpc'); Emacs
;; acts as the UI: chat buffer, streaming transcript, session management.
;;
;; Entry points: `M-x pi-code' (new session), `M-x pi-code-resume'.
;;
;; Layout:
;;   pi-code.el      this file: customization, sessions, entry points
;;   pi-code-rpc.el  process + JSONL protocol layer
;;   pi-code-chat.el chat buffer UI

;;; Code:

(require 'cl-lib)
(require 'pi-code-rpc)
(require 'pi-code-chat)

(declare-function evil-define-key* "evil-core" t t)

(defgroup pi-code nil
  "Emacs frontend for the pi coding agent."
  :group 'tools
  :prefix "pi-code-")

(defcustom pi-code-executable "pi"
  "Path to the pi CLI executable."
  :type 'string
  :group 'pi-code)

(defcustom pi-code-program-args nil
  "Extra CLI arguments passed to every `pi --mode rpc' process.
Example: (\"--provider\" \"anthropic\" \"--model\" \"provider/id\")."
  :type '(repeat string)
  :group 'pi-code)

(defcustom pi-code-sessions-root
  (expand-file-name "~/.pi/agent/sessions")
  "Root directory where pi stores session files."
  :type 'directory
  :group 'pi-code)

(defun pi-code--sessions-subdir-for-cwd (cwd)
  "Return pi's session subdirectory name for CWD.
Mirrors pi's rule (session-manager.ts): strip leading slash, replace
/ and : with -, wrap in --...--."
  (let ((p (directory-file-name (expand-file-name cwd))))
    (concat "--"
            (replace-regexp-in-string
             "[/:]" "-"
             (replace-regexp-in-string "\\`[/\\]" "" p))
            "--")))

;;; Chat session lookup

(defun pi-code--chat-session ()
  "Return the RPC session of the current chat buffer, or signal."
  (unless (derived-mode-p 'pi-code-chat-mode)
    (user-error "pi-code: not in a pi chat buffer"))
  (unless (and pi-code--session (pi-code-rpc-alive-p pi-code--session))
    (user-error "pi-code: session is not running"))
  pi-code--session)

(defun pi-code--live-chat-for-cwd (cwd)
  "Find a live chat buffer whose session runs in CWD."
  (let ((dir (expand-file-name cwd)))
    (cl-find-if (lambda (b)
                  (with-current-buffer b
                    (and (derived-mode-p 'pi-code-chat-mode)
                         pi-code--session
                         (pi-code-rpc-alive-p pi-code--session)
                         (equal (pi-code-session-cwd pi-code--session)
                                dir))))
                (buffer-list))))

;;; Starting

(defun pi-code--start-new (cwd extra-args)
  "Start a pi session in CWD with EXTRA-ARGS and open its chat."
  (let ((name (file-name-nondirectory (directory-file-name cwd))))
    (message "pi-code: starting pi in %s…" cwd)
    (pi-code-rpc-start
     :program pi-code-executable :cwd cwd
     :args (append pi-code-program-args extra-args)
     :name name
     :on-ready (lambda (sess _state)
                 (let ((buf (pi-code--open-chat sess name)))
                   (pop-to-buffer buf)))
     :on-error (lambda (_sess msg)
                 (message "pi-code: failed to start: %s" msg)))))

;;;###autoload
(defun pi-code ()
  "Open a pi chat for the current project, starting one if needed."
  (interactive)
  (let ((cwd (expand-file-name default-directory)))
    (if-let ((buf (pi-code--live-chat-for-cwd cwd)))
        (pop-to-buffer buf)
      (pi-code--start-new cwd nil))))

(defun pi-code-quit ()
  "Stop the current chat's session and kill its buffer."
  (interactive)
  (let ((session (and (derived-mode-p 'pi-code-chat-mode) pi-code--session)))
    (when session (pi-code-rpc-stop session))
    (kill-buffer (current-buffer))))

(defun pi-code-new-session ()
  "Start a fresh session in the current chat's process."
  (interactive)
  (let ((session (pi-code--chat-session))
        (buf (current-buffer)))
    (pi-code-rpc-send
     session '(:type "new_session")
     (lambda (_sess resp)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (if (and (plist-get resp :success)
                    (not (plist-get (plist-get resp :data) :cancelled)))
               (progn
                 (let ((inhibit-read-only t))
                   (erase-buffer))
                  (setq pi-code--folds nil
                        pi-code--widgets nil
                        pi-code--ext-status nil
                        pi-code--stats nil
                        pi-code--pending-echo nil
                        pi-code--echoed-user nil
                        pi-code--streamed-current nil
                        pi-code--streamed-text nil
                        pi-code--assistant-open nil
                        pi-code--msg-start nil
                        pi-code--thinking-start nil
                        pi-code--queue nil
                        pi-code--last-reply nil
                        pi-code--spinner-index 0
                        pi-code--last-index nil
                        pi-code--streaming-p nil)
                  (pi-code--insert-banner)
                  (set-marker pi-code--history-end (point-max))
                  (pi-code--insert-prompt)
                 (pi-code--update-header)
                 (pi-code--refresh-stats)
                 (message "pi-code: new session"))
             (message "pi-code: new session failed: %s"
                      (or (plist-get resp :error) "cancelled")))))))))

;;; Resume

(defun pi-code--session-files (cwd)
  "List pi session files for CWD, newest first."
  (let ((dir (expand-file-name (pi-code--sessions-subdir-for-cwd cwd)
                               pi-code-sessions-root)))
    (when (file-directory-p dir)
      (sort (directory-files dir t "\\.jsonl\\'")
            (lambda (a b)
              (time-less-p (file-attribute-modification-time
                            (file-attributes b))
                           (file-attribute-modification-time
                            (file-attributes a))))))))

(defun pi-code--session-label (path)
  "Human-readable label for session file PATH."
  (let* ((base (file-name-base path))
         (stamp (if (string-match
                     "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)T\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)"
                     base)
                      (format "%s-%s-%s %s:%s"
                              (match-string 1 base) (match-string 2 base)
                              (match-string 3 base) (match-string 4 base)
                              (match-string 5 base))
                    base))
         (id (if (string-match "_\\([0-9a-f]\\{8\\}\\)" base)
                 (match-string 1 base) "?"))
         (size (file-attribute-size (file-attributes path))))
    (format "%s  %s  (%dk)" stamp id (/ (+ size 1023) 1024))))

;;;###autoload
(defun pi-code-resume ()
  "Pick a saved session for the current project and reopen it."
  (interactive)
  (let* ((cwd (expand-file-name default-directory))
         (files (pi-code--session-files cwd)))
    (unless files
      (user-error "pi-code: no saved sessions for %s" cwd))
    (let* ((table (mapcar (lambda (f) (cons (pi-code--session-label f) f))
                          files))
           (choice (completing-read "Resume pi session: " table nil t))
           (path (cdr (assoc choice table))))
      (when (derived-mode-p 'pi-code-chat-mode)
        (pi-code-quit))
      (pi-code--start-new cwd (list "--session" path)))))

;;; Model & thinking

(defun pi-code--with-session-async (command-title command fn)
  "Send COMMAND, then run FN as (FN SESSION DATA) via a timer.
Avoids minibuffer interaction inside the process filter."
  (let ((session (pi-code--chat-session))
        (buf (current-buffer)))
    (pi-code-rpc-send
     session command
     (lambda (sess resp)
       (if (not (plist-get resp :success))
           (message "pi-code: %s failed: %s" command-title
                    (or (plist-get resp :error) "unknown"))
         (let ((data (plist-get resp :data)))
           (run-with-timer
            0 nil
            (lambda ()
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (when (eq sess pi-code--session)
                    (funcall fn sess data))))))))))))

(defun pi-code-switch-model ()
  "Pick a model from the configured list and switch to it."
  (interactive)
  (pi-code--with-session-async
   "get_available_models" '(:type "get_available_models")
   (lambda (sess data)
     (let* ((models (plist-get data :models))
            (table (mapcar (lambda (m)
                             (cons (format "%s/%s  %s"
                                           (plist-get m :provider)
                                           (plist-get m :id)
                                           (or (plist-get m :name) ""))
                                   m))
                           models))
            (choice (completing-read "pi model: " table nil t))
            (m (cdr (assoc choice table))))
       (pi-code-rpc-send
        sess (list :type "set_model"
                   :provider (plist-get m :provider)
                   :modelId (plist-get m :id))
        (lambda (s2 resp)
          (when (buffer-live-p (current-buffer))
            (with-current-buffer (current-buffer)
              (when (eq s2 pi-code--session)
                (if (plist-get resp :success)
                    (progn
                      (setf (pi-code-session-state s2)
                            (plist-put (pi-code-session-state s2)
                                       :model (plist-get resp :data)))
                      (pi-code--update-header)
                      (message "pi-code: model → %s"
                               (plist-get (plist-get resp :data) :name)))
                  (message "pi-code: set_model failed: %s"
                           (or (plist-get resp :error) "unknown"))))))))))))

(defun pi-code-cycle-model ()
  "Switch to the next configured model."
  (interactive)
  (let ((session (pi-code--chat-session))
        (buf (current-buffer)))
    (pi-code-rpc-send
     session '(:type "cycle_model")
     (lambda (sess resp)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (when (eq sess pi-code--session)
             (let ((data (plist-get resp :data)))
               (if (and (plist-get resp :success) data)
                   (progn
                     (setf (pi-code-session-state sess)
                           (plist-put (pi-code-session-state sess)
                                      :model (plist-get data :model)))
                     (pi-code--update-header)
                     (message "pi-code: model → %s"
                              (plist-get (plist-get data :model) :name)))
                 (message "pi-code: nothing to cycle to"))))))))))

(defun pi-code-set-thinking ()
  "Pick a thinking level for the current model."
  (interactive)
  (pi-code--with-session-async
   "get_available_thinking_levels" '(:type "get_available_thinking_levels")
   (lambda (sess data)
     (let ((level (completing-read
                   "pi thinking level: "
                   (plist-get data :levels) nil t)))
       (pi-code-rpc-send
        sess (list :type "set_thinking_level" :level level)
        (lambda (_s2 resp)
          (message "pi-code: thinking → %s%s" level
                   (if (plist-get resp :success) ""
                     (format " (failed: %s)"
                             (or (plist-get resp :error) "unknown"))))))))))

(defun pi-code-compact (&optional instructions)
  "Manually compact the conversation context.
With a prefix argument, prompt for custom INSTRUCTIONS."
  (interactive
   (list (when current-prefix-arg
           (read-string "Compaction instructions: "))))
  (let ((session (pi-code--chat-session))
        (command (list :type "compact")))
    (when (and instructions (not (string-empty-p instructions)))
      (setq command (plist-put command :customInstructions instructions)))
    (pi-code-rpc-send
     session command
     (lambda (_sess resp)
       (message "pi-code: %s"
                (if (plist-get resp :success)
                    "context compacted"
                  (format "compaction failed: %s"
                          (or (plist-get resp :error) "unknown"))))))))

;;; Menu

(require 'transient nil t)

(defconst pi-code--transient-new-p
  (and (featurep 'transient) (fboundp 'transient--set-layout))
  "Non-nil when transient is new enough for the `pi-code-menu' layout.")

(if pi-code--transient-new-p
    ;; Evaluated at load time (not compile time) so this file also
    ;; compiles and loads where transient is missing or too old.
    (eval '(transient-define-prefix pi-code-menu ()
             "Transient menu for common pi-code actions."
             [["Model"
               ("m" "switch model" pi-code-switch-model)
               ("c" "cycle model" pi-code-cycle-model)
               ("t" "thinking level" pi-code-set-thinking)]
              ["Context"
               ("k" "compact context" pi-code-compact)
               ("y" "copy last reply" pi-code-copy-last-reply)]]
             [["Session"
               ("n" "new session" pi-code-new-session)
               ("r" "resume session" pi-code-resume)
               ("q" "quit session" pi-code-quit)]]))
  (defun pi-code-menu ()
    "Dispatch common pi-code actions.
Fallback used when transient is unavailable or too old."
    (interactive)
    (let* ((actions '(("switch model" . pi-code-switch-model)
                      ("cycle model" . pi-code-cycle-model)
                      ("thinking level" . pi-code-set-thinking)
                      ("compact context" . pi-code-compact)
                      ("copy last reply" . pi-code-copy-last-reply)
                      ("new session" . pi-code-new-session)
                      ("resume session" . pi-code-resume)
                      ("quit session" . pi-code-quit)))
           (choice (completing-read "pi-code: " actions nil t)))
      (when choice
        (call-interactively (cdr (assoc choice actions)))))))

;;; Key bindings

(define-key pi-code-chat-mode-map (kbd "C-c C-m") #'pi-code-switch-model)
(define-key pi-code-chat-mode-map (kbd "C-c C-t") #'pi-code-set-thinking)
(define-key pi-code-chat-mode-map (kbd "C-c C-a") 'pi-code-menu)
(define-key pi-code-chat-mode-map (kbd "C-c C-n") #'pi-code-new-session)
(define-key pi-code-chat-mode-map (kbd "C-c C-r") #'pi-code-resume)
(define-key pi-code-chat-mode-map (kbd "C-c C-q") #'pi-code-quit)

(defun pi-code--extra-evil-bindings ()
  "Apply session/model keys to evil normal/insert states."
  (evil-define-key* '(normal insert) pi-code-chat-mode-map
    (kbd "C-c C-m") #'pi-code-switch-model
    (kbd "C-c C-t") #'pi-code-set-thinking
    (kbd "C-c C-a") 'pi-code-menu
    (kbd "C-c C-n") #'pi-code-new-session
    (kbd "C-c C-r") #'pi-code-resume
    (kbd "C-c C-q") #'pi-code-quit
    (kbd "C-c C-o") #'pi-code-open-file-at-point
    (kbd "C-c C-y") #'pi-code-copy-last-reply))

(if (featurep 'evil)
    (pi-code--extra-evil-bindings)
  (with-eval-after-load 'evil #'pi-code--extra-evil-bindings))

(provide 'pi-code)
;;; pi-code.el ends here
