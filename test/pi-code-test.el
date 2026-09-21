;;; pi-code-test.el --- ERT tests for pi-code.el -*- lexical-binding: t; -*-

;;; Code:
(require 'ert)
(require 'pi-code)

(ert-deftest pi-code-test-sessions-subdir ()
  "CWD maps to pi's --...-- session directory name."
  (should (equal (pi-code--sessions-subdir-for-cwd "/home/chris/projects/emacs_code")
                 "--home-chris-projects-emacs_code--"))
  (should (equal (pi-code--sessions-subdir-for-cwd "/home/chris/")
                 "--home-chris--")))

(ert-deftest pi-code-test-session-label ()
  (let* ((dir (make-temp-file "pi-code-sess" t))
         (f (expand-file-name
             "2026-09-18T13-38-32-115Z_01a0b4bd-xxx.jsonl" dir)))
    (unwind-protect
        (progn
          (write-region "x" nil f)
          (let ((label (pi-code--session-label f)))
            (should (string-match-p "2026-09-18 13:38" label))
            (should (string-match-p "01a0b4bd" label))))
      (delete-directory dir t))))

(ert-deftest pi-code-test-session-files-newest-first ()
  "Session files sort newest first."
  (let* ((root (make-temp-file "pi-code-sess" t))
         (pi-code-sessions-root root)
         (dir (expand-file-name "--home-chris--" root)))
    (make-directory dir t)
    (let ((a (expand-file-name "2026-01-01T00-00-00-000Z_aaaaaaaa.jsonl" dir))
          (b (expand-file-name "2026-09-18T13-38-32-115Z_bbbbbbbb.jsonl" dir)))
      (write-region "" nil a) (write-region "" nil b)
      (set-file-times a (encode-time 0 0 0 1 1 2026))
      (set-file-times b (encode-time 0 38 13 18 9 2026))
      (should (equal (pi-code--session-files "/home/chris/") (list b a))))
    (delete-directory root t)))

(provide 'pi-code-test)
;;; pi-code-test.el ends here
