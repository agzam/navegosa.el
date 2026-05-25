;;; navegosa.el --- Control web browsers from Emacs via JXA -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Created: May 25, 2026
;; Version: 0.2.0
;; Keywords: tools convenience
;; Homepage: https://github.com/agzam/navegosa.el
;; Package-Requires: ((emacs "29.1"))
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Control web browsers directly from Emacs on macOS using JXA
;; (JavaScript for Automation).  Supports any browser with a Standard
;; Suite scripting dictionary: Safari, Chrome, Brave, Arc, etc.
;;
;; All JXA logic lives in a single JS file (navegosa-scripts.js),
;; loaded once and piped to osascript via stdin on each call.

;;; Code:

(require 'json)
(require 'seq)
(require 'cl-lib)

;;;; Customization

(defgroup navegosa nil
  "Control web browsers from Emacs via JXA."
  :group 'tools
  :prefix "navegosa-")

(defcustom navegosa-browser nil
  "Browser application name.
When nil, auto-detected from macOS default browser settings."
  :type '(choice (const :tag "Auto-detect" nil)
                 (string :tag "Browser name")))

(defcustom navegosa-jump-links-scope 'viewport
  "Scope for `navegosa-jump-to-link'.
When `viewport', collect only links visible in the current viewport.
When `all', collect every link on the page."
  :type '(choice (const :tag "Viewport only" viewport)
                 (const :tag "All links" all)))

(defcustom navegosa-jump-links-action 'same-tab
  "Default action when selecting a link in `navegosa-jump-to-link'.
When `same-tab', click the link element in the current tab.
When `new-tab', open the URL in a new browser tab."
  :type '(choice (const :tag "Same tab" same-tab)
                 (const :tag "New tab" new-tab)))

;;;; Internal state

(defvar navegosa--scripts-cache nil
  "Cached content of navegosa-scripts.js.")

(defvar navegosa--browser-cache nil
  "Cached auto-detected browser name.")

(defvar navegosa--jump-highlight-timer nil
  "Debounce timer for link highlighting during `navegosa-jump-to-link'.")

;;;; Core infrastructure

(defun navegosa--ensure-macos ()
  "Signal error unless running on macOS."
  (unless (eq system-type 'darwin)
    (user-error "navegosa requires macOS")))

(defun navegosa--scripts-file ()
  "Locate navegosa-scripts.js relative to package directory."
  (expand-file-name
   "navegosa-scripts.js"
   (file-name-directory
    (or load-file-name
        (locate-library "navegosa")
        (error "Cannot find navegosa package directory")))))

(defun navegosa--load-scripts ()
  "Load and cache the JS scripts file."
  (or navegosa--scripts-cache
      (setq navegosa--scripts-cache
            (with-temp-buffer
              (insert-file-contents (navegosa--scripts-file))
              (buffer-string)))))

(defun navegosa--to-js (value)
  "Serialize elisp VALUE to a JavaScript literal."
  (cond
   ((stringp value) (json-encode-string value))
   ((numberp value) (number-to-string value))
   ((eq value t) "true")
   ((null value) "null")
   (t (error "Cannot serialize %S to JavaScript" value))))

(defun navegosa--run (fn &rest args)
  "Call Navegosa.FN with ARGS via JXA, return parsed result.
Loads the JS scripts file, appends a JSON.stringify dispatch call,
pipes the whole thing to osascript via stdin, and parses the JSON output."
  (navegosa--ensure-macos)
  (let* ((scripts (navegosa--load-scripts))
         (js-args (mapconcat #'navegosa--to-js args ", "))
         (call (format "\nJSON.stringify(Navegosa.%s(%s))" fn js-args))
         (full-script (concat scripts call)))
    (with-temp-buffer
      (insert full-script)
      (let ((exit-code
             (call-process-region
              (point-min) (point-max) "osascript"
              t t nil "-l" "JavaScript")))
        (let ((output (string-trim (buffer-string))))
          (if (not (zerop exit-code))
              (user-error "navegosa: JXA error (exit %d): %s" exit-code output)
            (when (< 0 (length output))
              (let ((result (json-parse-string
                             output
                             :object-type 'plist
                             :array-type 'list
                             :null-object nil
                             :false-object nil)))
                (when (and (consp result) (plist-member result :error))
                  (user-error "navegosa: %s" (plist-get result :error)))
                result))))))))

(defun navegosa--run-async (fn &rest args)
  "Call Navegosa.FN with ARGS via JXA asynchronously.
Fire-and-forget: does not block Emacs, discards output."
  (navegosa--ensure-macos)
  (let* ((scripts (navegosa--load-scripts))
         (js-args (mapconcat #'navegosa--to-js args ", "))
         (call (format "\nJSON.stringify(Navegosa.%s(%s))" fn js-args))
         (full-script (concat scripts call))
         (proc (make-process
                :name "navegosa-async"
                :command '("osascript" "-l" "JavaScript")
                :connection-type 'pipe
                :noquery t
                :sentinel #'ignore)))
    (process-send-string proc full-script)
    (process-send-eof proc)))

;;;; Browser detection

(defun navegosa--detect-browser ()
  "Detect default browser from macOS LaunchServices.
Falls back to Safari when no custom handler is set."
  (let ((plist-path
         (expand-file-name
          "~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist")))
    (if (not (file-exists-p plist-path))
        "Safari"
      (let* ((json-str (shell-command-to-string
                        (format "plutil -convert json -o - '%s'" plist-path)))
             (data (json-parse-string json-str :object-type 'plist :array-type 'list))
             (handlers (plist-get data :LSHandlers))
             (https-handler
              (seq-find (lambda (h)
                          (equal "https" (plist-get h :LSHandlerURLScheme)))
                        handlers))
             (bundle-id (when https-handler
                          (plist-get https-handler :LSHandlerRoleAll))))
        (if (not bundle-id)
            "Safari"
          (string-trim
           (shell-command-to-string
            (format
             "osascript -e 'tell application \"Finder\" to get name of application file id \"%s\"'"
             bundle-id))))))))

(defun navegosa--browser ()
  "Return browser name from defcustom, cache, or auto-detection."
  (or navegosa-browser
      navegosa--browser-cache
      (setq navegosa--browser-cache (navegosa--detect-browser))))

;;;###autoload
(defun navegosa-reset ()
  "Clear all navegosa caches (scripts, browser name)."
  (interactive)
  (setq navegosa--scripts-cache nil
        navegosa--browser-cache nil)
  (message "navegosa: caches cleared"))

;;;; Commands

;;;###autoload
(defun navegosa-get-tabs ()
  "Return all browser tabs as a list of plists.
Each plist has keys :windowIndex, :tabIndex, :url, :title, :active."
  (navegosa--run "getTabs" (navegosa--browser)))

;;;###autoload
(defun navegosa-switch-tab ()
  "Switch to a browser tab selected via `completing-read'."
  (interactive)
  (let* ((tabs (navegosa-get-tabs))
         (tab-alist
          (mapcar (lambda (tab)
                    (cons (format "%s | %s"
                                  (plist-get tab :title)
                                  (plist-get tab :url))
                          tab))
                  tabs))
         (selected (completing-read "Tab: " (mapcar #'car tab-alist) nil t))
         (tab (cdr (assoc selected tab-alist))))
    (when tab
      (navegosa--run "activateTab" (navegosa--browser)
                     (plist-get tab :windowIndex)
                     (plist-get tab :tabIndex)))))

;;;###autoload
(defun navegosa-close-tab ()
  "Close a browser tab selected via `completing-read'."
  (interactive)
  (let* ((tabs (navegosa-get-tabs))
         (tab-alist
          (mapcar (lambda (tab)
                    (cons (format "%s | %s"
                                  (plist-get tab :title)
                                  (plist-get tab :url))
                          tab))
                  tabs))
         (selected (completing-read "Close tab: " (mapcar #'car tab-alist) nil t))
         (tab (cdr (assoc selected tab-alist))))
    (when tab
      (navegosa--run "closeTab" (navegosa--browser)
                     (plist-get tab :windowIndex)
                     (plist-get tab :tabIndex))
      (message "Closed: %s" (plist-get tab :title)))))

;;;###autoload
(defun navegosa-copy-tab-link ()
  "Copy the URL of the active browser tab to the kill ring."
  (interactive)
  (if-let* ((tab (navegosa--run "getActiveTabInfo" (navegosa--browser)))
            (url (plist-get tab :url)))
      (progn
        (kill-new url)
        (message "Copied: %s" url)
        url)
    (user-error "No active tab found")))

;;;###autoload
(defun navegosa-insert-link ()
  "Insert a link to the active browser tab, formatted for current major mode.
In `org-mode': [[url][title]], in `markdown-mode': [title](url),
otherwise just the URL.  If region is active, uses it as the link text."
  (interactive)
  (if-let* ((tab (navegosa--run "getActiveTabInfo" (navegosa--browser)))
            (url (plist-get tab :url)))
      (let ((title (if (use-region-p)
                       (prog1 (buffer-substring (region-beginning) (region-end))
                         (delete-region (region-beginning) (region-end)))
                     ;; Strip leading notification counts like "(3) "
                     (replace-regexp-in-string
                      "^([0-9]+)\\s-*" ""
                      (plist-get tab :title)))))
        (insert
         (cond
          ((derived-mode-p 'org-mode)
           (format "[[%s][%s]]" url title))
          ((derived-mode-p 'markdown-mode)
           (format "[%s](%s)" title url))
          (t url))))
    (user-error "No active tab found")))

;;;###autoload
(defun navegosa-grab-text ()
  "Get the plain text content of the active browser tab.
When called interactively, displays in a buffer.
Requires JS execution permission in Safari."
  (interactive)
  (if-let* ((result (navegosa--run "getActiveTabText" (navegosa--browser)))
            (text (plist-get result :content)))
      (if (called-interactively-p 'interactive)
          (let ((buf (get-buffer-create
                      (format "*navegosa: %s*" (plist-get result :title)))))
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert text))
              (goto-char (point-min))
              (special-mode))
            (pop-to-buffer buf))
        text)
    (user-error "No content retrieved")))

;;;###autoload
(defun navegosa-tab-to-eww ()
  "Render active browser tab content in eww.
Requires JS execution permission in Safari."
  (interactive)
  (if-let* ((result (navegosa--run "getActiveTabContent" (navegosa--browser)))
            (html (plist-get result :content))
            (title (plist-get result :title)))
      (let ((tmp (make-temp-file "navegosa-" nil ".html")))
        (unwind-protect
            (progn
              (with-temp-file tmp (insert html))
              (eww-open-file tmp)
              (rename-buffer (format "*eww: %s*" title) t))
          (when (file-exists-p tmp)
            (delete-file tmp))))
    (user-error "No content retrieved")))

;;;; Jump to link

(defun navegosa--jump-make-candidates (links)
  "Build alist of (display-string . link-plist) from LINKS."
  (mapcar (lambda (link)
            (let ((hint (plist-get link :hint))
                  (text (plist-get link :text))
                  (href (plist-get link :href)))
              (cons (format "[%s] %s  %s" hint
                            (if (string-empty-p text) "(no text)" text)
                            href)
                    link)))
          links))

(defun navegosa--jump-highlight-link (index)
  "Highlight link at INDEX in the browser, debounced."
  (when navegosa--jump-highlight-timer
    (cancel-timer navegosa--jump-highlight-timer))
  (setq navegosa--jump-highlight-timer
        (run-with-timer
         0.05 nil
         (lambda ()
           (navegosa--run-async "highlightLink"
                                (navegosa--browser) index)))))

;;;###autoload
(defun navegosa-jump-to-link ()
  "Jump to a link on the active browser tab.
Collects links (scope controlled by `navegosa-jump-links-scope'),
injects hint overlays into the browser, and presents candidates
via `consult--read' (with live highlight) or `completing-read'.

Selected link is opened per `navegosa-jump-links-action'."
  (interactive)
  (let* ((viewport-p (eq navegosa-jump-links-scope 'viewport))
         (links (navegosa--run "getLinksAndInjectHints"
                               (navegosa--browser)
                               viewport-p)))
    (unless links
      (user-error "No links found on page"))
    (unwind-protect
        (let* ((candidates (navegosa--jump-make-candidates links))
               (display (mapcar #'car candidates))
               (selected
                (if (fboundp 'consult--read)
                    (consult--read
                     display
                     :prompt "Link: "
                     :sort nil
                     :state
                     (lambda (action cand)
                       (when (and (eq action 'preview) cand)
                         (when-let* ((link (cdr (assoc cand candidates))))
                           (navegosa--jump-highlight-link
                            (plist-get link :index))))))
                  (completing-read "Link: " display nil t)))
               (link (cdr (assoc selected candidates))))
          (when link
            (pcase navegosa-jump-links-action
              ('same-tab
               (navegosa--run "clickLink"
                              (navegosa--browser)
                              (plist-get link :index)))
              ('new-tab
               (navegosa--run "openLinkNewTab"
                              (navegosa--browser)
                              (plist-get link :href))))))
      (navegosa--run-async "clearLinkHints" (navegosa--browser))
      (when navegosa--jump-highlight-timer
        (cancel-timer navegosa--jump-highlight-timer)
        (setq navegosa--jump-highlight-timer nil)))))

(provide 'navegosa)
;;; navegosa.el ends here
