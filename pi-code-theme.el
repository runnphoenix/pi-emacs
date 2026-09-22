;;; pi-code-theme.el --- Optional colour theme for pi-code -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Chris
;; Author: Chris
;; Keywords: ai, faces, theme
;; Package-Requires: ((emacs "30.1"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; An optional, self-contained theme for the pi-code chat buffer.
;;
;; All pi-code faces are defined in `pi-code-chat' and already inherit
;; standard faces, so they follow the active theme.  This theme only
;; overrides the few faces where a subtle background helps: inline code
;; and fenced code blocks, and unified-diff add/remove lines.  Keeping
;; it minimal avoids the base deffaces and the theme drifting apart.
;;
;;   M-x load-theme RET pi-code

;;; Code:

(deftheme pi-code
  "A modest theme adding code/diff backgrounds to pi-code chat buffers.")

(let ((dark (eq (frame-parameter nil 'background-mode) 'dark)))
  (custom-theme-set-faces
   'pi-code
   `(pi-code-code-face
     ((t (:inherit fixed-pitch :extend t
                   :background ,(if dark "#1f2430" "#f2f2f2")))))
   `(pi-code-diff-add-face
     ((t (:inherit diff-added :extend t
                   :background ,(if dark "#173b1a" "#ddffdd")))))
   `(pi-code-diff-del-face
     ((t (:inherit diff-removed :extend t
                   :background ,(if dark "#3b1717" "#ffdddd")))))))

(provide-theme 'pi-code)

(provide 'pi-code-theme)
;;; pi-code-theme.el ends here
