;;; pi-code-evil-test.el --- evil integration regression test -*- lexical-binding: t; -*-

;; Run with evil on the load path, e.g.:
;;   emacs --batch -L ~/.emacs.d/elpa/evil-20251108.138 \
;;     -L ~/.emacs.d/elpa/goto-chg-20240407.1110 \
;;     -L . -l test/pi-code-evil-test.el -f ert-run-tests-batch-and-exit

;;; Code:
(require 'ert)
(require 'evil)
(require 'pi-code)

(ert-deftest pi-code-evil-test-loads-with-evil ()
  "Requiring pi-code with evil loaded must not signal."
  (should (featurep 'pi-code)))

(ert-deftest pi-code-evil-test-bindings ()
  "Chat keys resolve in evil insert/normal auxiliary maps."
  (with-temp-buffer
    (pi-code-chat-mode)
    (dolist (state '(insert normal))
      (let ((aux (evil-get-auxiliary-keymap pi-code-chat-mode-map state)))
        (should aux)
        (should (eq (lookup-key aux (kbd "C-c C-c"))
                    #'pi-code-send-or-abort))
        (should (eq (lookup-key aux (kbd "C-c C-m"))
                    #'pi-code-switch-model))))))

(provide 'pi-code-evil-test)
;;; pi-code-evil-test.el ends here
