;;; pi-code-rpc.el --- JSONL RPC client for the pi coding agent -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Chris
;; Author: Chris
;; Keywords: ai, tools
;; Package-Requires: ((emacs "30.1"))

;; This file is part of pi-code.el, an Emacs frontend for the pi coding
;; agent (https://pi.dev).  The agent runs as a subprocess in RPC mode
;; (`pi --mode rpc`) and speaks JSON lines over stdin/stdout.  The full
;; protocol is documented in pi's docs/rpc.md; the reference client is
;; pi's src/modes/rpc/rpc-client.ts.

;;; Commentary:

;; Pure protocol layer: process lifecycle, strict JSONL framing (split on
;; \n only, strip trailing \r), command/response correlation by id, and
;; event dispatch.  No UI code here so it can be unit tested in batch mode.
;;
;; Incoming objects (plists):
;; - (:type "response" ...) with a known :id -> pending callback
;; - (:type "extension_ui_request" ...) -> session ui-handler
;; - anything else -> session event-functions
;;
;; JSON false/null decode to nil, arrays decode to lists, objects to plists.

;;; Code:

(require 'json)
(require 'cl-lib)

(cl-defstruct (pi-code-session (:constructor pi-code-session--create))
  "Handle for one `pi --mode rpc' subprocess."
  process rest pending id-counter event-functions ui-handler
  stderr-buffer name cwd ready-p state models debug-buffer)

(defvar pi-code-rpc-debug nil
  "When non-nil, log raw protocol lines to the session debug buffer.")

(defun pi-code-session--new (name cwd stderr-buffer)
  "Build a fresh `pi-code-session' struct."
  (pi-code-session--create
   :process nil :rest "" :pending (make-hash-table :test 'equal)
   :id-counter 0 :event-functions nil :ui-handler #'pi-code--default-ui-handler
   :stderr-buffer stderr-buffer :name name :cwd cwd :ready-p nil
   :state nil :models nil
   :debug-buffer (get-buffer-create (format "*pi-code-proto:%s*" name))))

(defun pi-code-rpc-alive-p (session)
  "Return non-nil if SESSION's process is running."
  (let ((proc (pi-code-session-process session)))
    (and proc (process-live-p proc))))

(defun pi-code-rpc-add-event-function (session fn)
  "Call FN as (FN SESSION EVENT) for every agent event on SESSION."
  (setf (pi-code-session-event-functions session)
        (cons fn (pi-code-session-event-functions session))))

(defun pi-code-rpc-set-ui-handler (session fn)
  "Set FN as (FN SESSION REQUEST) handler for extension UI requests."
  (setf (pi-code-session-ui-handler session) fn))

;;; Sending

(defun pi-code--encode-line (object)
  "Encode OBJECT (plist) as one JSON line string, no trailing newline."
  (json-encode object))

(defun pi-code-rpc-send (session command &optional callback)
  "Send COMMAND plist to SESSION, return the request id string.
COMMAND must not contain :id; one is assigned automatically.
CALLBACK, if given, is called as (CALLBACK SESSION RESPONSE) when the
matching response arrives, or with a failed response if the process dies."
  (unless (pi-code-rpc-alive-p session)
    (error "pi-code: session process is not running"))
  (let ((id (format "req-%d" (cl-incf (pi-code-session-id-counter session)))))
    (when callback
      (puthash id callback (pi-code-session-pending session)))
    (process-send-string
     (pi-code-session-process session)
     (concat (pi-code--encode-line
              (plist-put (copy-sequence command) :id id))
             "\n"))
    id))

(defun pi-code-rpc-ui-respond (session id fields)
  "Write an extension_ui_response with ID and FIELDS plist to SESSION."
  (unless (pi-code-rpc-alive-p session)
    (error "pi-code: session process is not running"))
  (process-send-string
   (pi-code-session-process session)
   (concat (pi-code--encode-line
            (plist-put (plist-put (copy-sequence fields) :id id)
                       :type "extension_ui_response"))
           "\n")))

;;; Receiving

(defun pi-code--debug-log (session direction line)
  (when pi-code-rpc-debug
    (with-current-buffer (pi-code-session-debug-buffer session)
      (goto-char (point-max))
      (insert (format "%s %s\n" direction line)))))

(defun pi-code--rpc-filter (process chunk)
  "Process filter: accumulate CHUNK and dispatch complete lines."
  (let ((session (process-get process 'pi-code-session)))
    (when session
      (pi-code--rpc-ingest session chunk))))

(defun pi-code--rpc-ingest (session chunk)
  "Append CHUNK to SESSION's buffer and handle each complete line.
Lines are split on \\n only; a trailing \\r is stripped."
  (let* ((buf (concat (pi-code-session-rest session) chunk))
         (lines (split-string buf "\n")))
    (setf (pi-code-session-rest session) (car (last lines)))
    (dolist (raw (butlast lines))
      (let ((line (if (string-suffix-p "\r" raw)
                      (substring raw 0 -1)
                    raw)))
        (unless (string-empty-p line)
          (pi-code--debug-log session "<-" line)
          (pi-code--handle-line session line))))))

(defun pi-code--handle-line (session line)
  "Parse LINE as JSON and dispatch it for SESSION."
  (let ((obj (condition-case err
                 (json-parse-string line :object-type 'plist
                                    :array-type 'list
                                    :null-object nil :false-object nil)
               (error
                (pi-code--log session "pi-code: ignoring malformed line: %s (%s)"
                              (truncate-string-to-width line 120) err)
                nil))))
    (when obj
      (let ((type (plist-get obj :type)))
        (cond
         ((and (equal type "response")
               (let ((cb (gethash (plist-get obj :id)
                                  (pi-code-session-pending session))))
                 (when cb
                   (remhash (plist-get obj :id)
                            (pi-code-session-pending session))
                   (condition-case err
                       (funcall cb session obj)
                     (error (pi-code--log session "pi-code: response callback error: %s" err)))
                   t))))
         ((equal type "response")
          (pi-code--log session "pi-code: unmatched response: %s"
                        (truncate-string-to-width line 160)))
         ((equal type "extension_ui_request")
          (condition-case err
              (funcall (pi-code-session-ui-handler session) session obj)
            (error
             (pi-code--log session "pi-code: UI handler error: %s" err)
             (pi-code--default-ui-handler session obj))))
         (t
          (dolist (fn (pi-code-session-event-functions session))
            (condition-case err
                (funcall fn session obj)
              (error (pi-code--log session "pi-code: event function error: %s" err))))))))))

(defun pi-code--log (session format &rest args)
  "Log a message; SESSION may be nil."
  (let ((msg (apply #'format format args)))
    (if (and session (buffer-live-p (pi-code-session-stderr-buffer session)))
        (with-current-buffer (pi-code-session-stderr-buffer session)
          (goto-char (point-max))
          (insert msg "\n"))
      (message "%s" msg))))

(defun pi-code--default-ui-handler (session request)
  "Default UI handler: cancel the dialog so the agent never blocks."
  (pi-code-rpc-ui-respond session (plist-get request :id) '(:cancelled t)))

;;; Lifecycle

(cl-defun pi-code-rpc-start (&key program cwd args name on-ready on-error)
  "Start `pi --mode rpc' in CWD and return a `pi-code-session'.
PROGRAM defaults to \"pi\".  ARGS are extra CLI arguments.
ON-READY is called as (ON-READY SESSION STATE) once the initial
get_state handshake succeeds.  ON-ERROR is called as
\\(ON-ERROR SESSION MESSAGE) if it fails."
  (let* ((program (or program "pi"))
         (prog (if (file-executable-p program)
                   program
                 (executable-find program)))
         (cwd (expand-file-name (or cwd default-directory)))
         (name (or name (format "pi:%s"
                               (file-name-nondirectory
                                (directory-file-name cwd)))))
         (stderr (get-buffer-create (format "*pi-code-stderr:%s*" name)))
         (session (pi-code-session--new name cwd stderr)))
    (unless prog
      (user-error
       (concat "pi-code-rpc: cannot find executable " program
               " in exec-path.\n"
               "Set pi-code-executable to its full path, or add its"
               " directory to exec-path, e.g.\n"
               "  (add-to-list 'exec-path \"/path/to/pi/bin\")")))
    (let ((proc (let ((default-directory (file-name-as-directory cwd)))
                  (make-process
                   :name name :buffer nil
                   :command (append (list prog "--mode" "rpc") args)
                   :connection-type 'pipe :coding 'utf-8 :noquery t
                   :stderr stderr :file-handler nil
                   :filter #'pi-code--rpc-filter
                   :sentinel #'pi-code--rpc-sentinel))))
      (setf (pi-code-session-process session) proc)
      (process-put proc 'pi-code-session session)
      (pi-code-rpc-send
       session '(:type "get_state")
       (lambda (sess resp)
         (if (plist-get resp :success)
             (progn
               (setf (pi-code-session-ready-p sess) t)
               (setf (pi-code-session-state sess) (plist-get resp :data))
               (when on-ready (funcall on-ready sess (plist-get resp :data))))
           (when on-error
             (funcall on-error sess (or (plist-get resp :error)
                                        "get_state handshake failed")))))))
    session))

(defun pi-code-rpc-stop (session)
  "Terminate SESSION's process: SIGTERM, wait up to 1s, then kill."
  (let ((proc (pi-code-session-process session)))
    (when (and proc (process-live-p proc))
      (signal-process proc 'SIGTERM)
      (dotimes (_ 20)
        (when (process-live-p proc)
          (accept-process-output proc 0.05)))
      (when (process-live-p proc)
        (delete-process proc))))
  (setf (pi-code-session-process session) nil
        (pi-code-session-ready-p session) nil)
  (pi-code--fail-pending
   session "process stopped"))

(defun pi-code--fail-pending (session message)
  "Fail every pending callback on SESSION with MESSAGE."
  (maphash (lambda (id cb)
             (remhash id (pi-code-session-pending session))
             (condition-case err
                 (funcall cb session (list :type "response" :id id
                                           :success nil :error message))
               (error (pi-code--log session "pi-code: error callback error: %s" err))))
           (pi-code-session-pending session)))

(defun pi-code--rpc-sentinel (process _event)
  "Handle PROCESS exit: fail pending callbacks and report."
  (let ((session (process-get process 'pi-code-session)))
    (when (and session (eq (pi-code-session-process session) process)
               (memq (process-status process) '(exit signal)))
      (setf (pi-code-session-process session) nil
            (pi-code-session-ready-p session) nil)
      (pi-code--fail-pending session
                             (format "process %s (code %s)"
                                     (process-status process)
                                     (process-exit-status process)))
      (pi-code--log session "pi-code: process %s ended (%s %s)"
                    (pi-code-session-name session)
                    (process-status process)
                    (process-exit-status process)))))

(provide 'pi-code-rpc)
;;; pi-code-rpc.el ends here
