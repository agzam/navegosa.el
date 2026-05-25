;;; navegosa-tabs.el --- Org-based browser tab manager -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Org-mode buffer showing all browser tabs grouped by window.
;; Read-only with keybindings for common tab operations.

;;; Code:

(require 'navegosa)
(require 'org)

(defvar-keymap navegosa-tabs-mode-map
  :parent org-mode-map
  :doc "Keymap for `navegosa-tabs-mode'."
  "RET"   #'navegosa-tabs-switch
  "d"     #'navegosa-tabs-close
  "g"     #'navegosa-tabs-refresh
  "q"     #'quit-window
  "o"     #'navegosa-tabs-browse-url)

(define-derived-mode navegosa-tabs-mode org-mode "Tabs"
  "Major mode for browsing and managing browser tabs.
Read-only Org buffer with keybindings for tab operations."
  :interactive nil
  (setq-local org-todo-keywords '((sequence "ACTIVE"))
              org-todo-keyword-faces '(("ACTIVE" . (:foreground "#50fa7b" :weight bold)))
              buffer-read-only t
              truncate-lines t))

(defun navegosa-tabs--sanitize-title (title)
  "Clean TITLE for safe use as an Org heading.
Strips leading stars, brackets, and notification counts."
  (thread-last title
    (replace-regexp-in-string "^\\*+" "")
    (replace-regexp-in-string "\\[\\[\\|\\]\\]" "")
    (replace-regexp-in-string "^([0-9]+)\\s-*" "")
    (string-trim)))

(defun navegosa-tabs--render (tabs)
  "Render TABS into the current buffer as Org headings.
TABS is a list of plists as returned by `navegosa-get-tabs'.
Groups tabs by window index."
  (let ((inhibit-read-only t)
        (grouped (seq-group-by (lambda (tab) (plist-get tab :windowIndex)) tabs)))
    (erase-buffer)
    (dolist (group (seq-sort-by #'car #'< grouped))
      (let ((win-idx (car group))
            (win-tabs (cdr group)))
        (insert (format "* Window %d\n" win-idx))
        (dolist (tab win-tabs)
          (let ((title (navegosa-tabs--sanitize-title (plist-get tab :title)))
                (active (plist-get tab :active)))
            (insert (format "** %s%s\n" (if active "ACTIVE " "") title))
            (insert ":PROPERTIES:\n")
            (insert (format ":URL: %s\n" (plist-get tab :url)))
            (insert (format ":WINDOW-INDEX: %d\n" (plist-get tab :windowIndex)))
            (insert (format ":TAB-INDEX: %d\n" (plist-get tab :tabIndex)))
            (when active (insert ":ACTIVE: t\n"))
            (insert ":END:\n")))))
    (goto-char (point-min))
    (org-fold-show-all)))

(defun navegosa-tabs--tab-at-point ()
  "Return plist for the tab at point, or nil if not on a tab heading."
  (save-excursion
    (org-back-to-heading t)
    (when (= 2 (org-current-level))
      (let ((url (org-entry-get nil "URL"))
            (win (org-entry-get nil "WINDOW-INDEX"))
            (tab (org-entry-get nil "TAB-INDEX")))
        (when (and url win tab)
          (list :url url
                :windowIndex (string-to-number win)
                :tabIndex (string-to-number tab)
                :title (org-get-heading t t t t)))))))

;;;###autoload
(defun navegosa-tabs ()
  "Open the browser tabs buffer."
  (interactive)
  (let ((buf (get-buffer-create "*navegosa-tabs*")))
    (with-current-buffer buf
      (navegosa-tabs-mode)
      (navegosa-tabs--render (navegosa-get-tabs)))
    (pop-to-buffer buf)))

(defun navegosa-tabs-refresh ()
  "Refresh the tabs buffer."
  (interactive)
  (when (derived-mode-p 'navegosa-tabs-mode)
    (let ((pos (point)))
      (navegosa-tabs--render (navegosa-get-tabs))
      (goto-char (min pos (point-max))))))

(defun navegosa-tabs-switch ()
  "Switch to the tab at point in the browser."
  (interactive)
  (if-let* ((tab (navegosa-tabs--tab-at-point)))
      (navegosa--run "activateTab" (navegosa--browser)
                     (plist-get tab :windowIndex)
                     (plist-get tab :tabIndex))
    (user-error "No tab at point")))

(defun navegosa-tabs-close ()
  "Close the tab at point and refresh."
  (interactive)
  (if-let* ((tab (navegosa-tabs--tab-at-point)))
      (when (yes-or-no-p (format "Close \"%s\"?" (plist-get tab :title)))
        (navegosa--run "closeTab" (navegosa--browser)
                       (plist-get tab :windowIndex)
                       (plist-get tab :tabIndex))
        (navegosa-tabs-refresh))
    (user-error "No tab at point")))

(defun navegosa-tabs-browse-url ()
  "Open the URL of the tab at point in eww."
  (interactive)
  (if-let* ((tab (navegosa-tabs--tab-at-point))
            (url (plist-get tab :url)))
      (eww url)
    (user-error "No tab at point")))

(provide 'navegosa-tabs)
;;; navegosa-tabs.el ends here
