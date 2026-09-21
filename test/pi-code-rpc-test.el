;;; pi-code-rpc-test.el --- ERT tests for pi-code-rpc -*- lexical-binding: t; -*-

;;; Code:
(require 'ert)
(require 'pi-code-rpc)

(defun pi-code-test--session ()
  "Make a stub session with no process."
  (let ((s (pi-code-session--new "test" "/tmp"
                                 (get-buffer-create " *pi-code-test-stderr*"))))
    (setf (pi-code-session-process s) nil)
    s))

(ert-deftest pi-code-test-ingest-split-chunks ()
  "Fragmented chunks reassemble into complete lines."
  (let ((s (pi-code-test--session)) (got nil))
    (pi-code-rpc-add-event-function s (lambda (_sess ev) (push ev got)))
    (pi-code--rpc-ingest s "{\"type\":\"a\"}\n{\"type\":")
    (should (equal (mapcar (lambda (e) (plist-get e :type)) (nreverse got))
                   '("a")))
    (pi-code--rpc-ingest s "\"b\"}\n{\"type\":\"c\"")
    (should (equal (mapcar (lambda (e) (plist-get e :type)) (nreverse got))
                   '("a" "b")))
    (should (equal (pi-code-session-rest s) "{\"type\":\"c\""))))

(ert-deftest pi-code-test-ingest-crlf ()
  "Trailing CR is stripped; only LF delimits."
  (let ((s (pi-code-test--session)) (got nil))
    (pi-code-rpc-add-event-function s (lambda (_sess ev) (push ev got)))
    (pi-code--rpc-ingest s "{\"type\":\"x\"}\r\n")
    (should (equal (plist-get (car got) :type) "x"))))

(ert-deftest pi-code-test-response-routing ()
  "Responses with known ids reach their callback and clear pending."
  (let ((s (pi-code-test--session)) (got nil))
    (puthash "req-9" (lambda (_sess resp) (setq got resp))
             (pi-code-session-pending s))
    (pi-code--handle-line
     s "{\"id\":\"req-9\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true}")
    (should (equal (plist-get got :command) "get_state"))
    (should (null (gethash "req-9" (pi-code-session-pending s))))))

(ert-deftest pi-code-test-unmatched-response-ignored ()
  "Unknown response ids do not signal."
  (let ((s (pi-code-test--session)))
    (pi-code--handle-line
     s "{\"id\":\"nope\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}")
    (should t)))

(ert-deftest pi-code-test-malformed-tolerated ()
  "Bad lines are skipped; the stream continues."
  (let ((s (pi-code-test--session)) (got nil))
    (pi-code-rpc-add-event-function s (lambda (_sess ev) (push ev got)))
    (pi-code--rpc-ingest s "{oops\n{\"type\":\"ok\"}\n")
    (should (equal (plist-get (car got) :type) "ok"))))

(ert-deftest pi-code-test-encode-roundtrip ()
  "Unicode, quotes and newlines survive encode/decode."
  (let* ((msg "你好 \"quoted\"\nnewline 😀")
         (line (pi-code--encode-line (list :type "prompt" :message msg)))
         (back (json-parse-string line :object-type 'plist)))
    (should (equal (plist-get back :message) msg))))

(ert-deftest pi-code-test-ui-default-cancels ()
  "Default UI handler answers with cancelled (needs a fake process)."
  (let ((s (pi-code-test--session)) (sent nil))
    (cl-letf (((symbol-function 'pi-code-rpc-alive-p) (lambda (_s) t))
              ((symbol-function 'process-send-string)
               (lambda (_proc str) (setq sent str))))
      (pi-code--default-ui-handler s '(:id "u1" :method "select")))
    (let ((back (json-parse-string sent :object-type 'plist)))
      (should (equal (plist-get back :type) "extension_ui_response"))
      (should (equal (plist-get back :id) "u1"))
      (should (plist-get back :cancelled)))))

(provide 'pi-code-rpc-test)
;;; pi-code-rpc-test.el ends here
