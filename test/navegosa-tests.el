;;; navegosa-tests.el --- Tests for navegosa.el -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for navegosa.  JXA calls are mocked since tests run in batch mode.
;;
;;; Code:

(require 'buttercup)
(require 'navegosa)
(require 'navegosa-tabs)
(require 'cl-lib)

;;; Serialization

(describe "navegosa--to-js"
  (it "serializes strings with proper escaping"
    (expect (navegosa--to-js "hello") :to-equal "\"hello\"")
    (expect (navegosa--to-js "say \"hi\"") :to-equal "\"say \\\"hi\\\"\"")
    (expect (navegosa--to-js "line1\nline2") :to-equal "\"line1\\nline2\""))

  (it "serializes numbers"
    (expect (navegosa--to-js 42) :to-equal "42")
    (expect (navegosa--to-js 3.14) :to-equal "3.14"))

  (it "serializes booleans and nil"
    (expect (navegosa--to-js t) :to-equal "true")
    (expect (navegosa--to-js nil) :to-equal "null"))

  (it "rejects unsupported types"
    (expect (navegosa--to-js '(1 2 3)) :to-throw 'error)))

;;; Script loading

(describe "navegosa--load-scripts"
  (it "loads the JS file and caches it"
    (let ((navegosa--scripts-cache nil))
      (spy-on 'navegosa--scripts-file
              :and-return-value
              (expand-file-name "navegosa-scripts.js"
                                (file-name-directory
                                 (or load-file-name default-directory))))
      (let ((scripts (navegosa--load-scripts)))
        (expect scripts :to-be-truthy)
        (expect (string-match-p "Navegosa" scripts) :to-be-truthy)
        ;; Second call returns cached value
        (expect (navegosa--load-scripts) :to-equal scripts)))))

;;; JXA runner (mocked)

(describe "navegosa--run"
  :var (navegosa--scripts-cache)

  (before-each
    (setq navegosa--scripts-cache "const Navegosa = {};")
    (spy-on 'navegosa--ensure-macos))

  (it "parses JSON object results into plists"
    (spy-on 'call-process-region
            :and-call-fake
            (lambda (&rest _)
              (erase-buffer)
              (insert "{\"url\":\"https://example.com\",\"title\":\"Test\"}")
              0))
    (let* ((result (navegosa--run "getActiveTabInfo" "Safari"))
           (url (plist-get result :url))
           (title (plist-get result :title)))
      (expect url :to-equal "https://example.com")
      (expect title :to-equal "Test")))

  (it "parses JSON array results into lists"
    (spy-on 'call-process-region
            :and-call-fake
            (lambda (&rest _)
              (erase-buffer)
              (insert "[{\"title\":\"Tab 1\"},{\"title\":\"Tab 2\"}]")
              0))
    (let* ((result (navegosa--run "getTabs" "Safari"))
           (first-title (plist-get (car result) :title)))
      (expect (length result) :to-equal 2)
      (expect first-title :to-equal "Tab 1")))

  (it "signals error on JXA failure"
    (spy-on 'call-process-region
            :and-call-fake
            (lambda (&rest _)
              (erase-buffer)
              (insert "Error: something went wrong")
              1))
    (expect (navegosa--run "getTabs" "Safari") :to-throw 'user-error))

  (it "signals error on application-level error response"
    (spy-on 'call-process-region
            :and-call-fake
            (lambda (&rest _)
              (erase-buffer)
              (insert "{\"error\":\"Window index out of range\"}")
              0))
    (expect (navegosa--run "activateTab" "Safari" 99 1) :to-throw 'user-error))

  (it "returns nil on empty output"
    (spy-on 'call-process-region
            :and-call-fake
            (lambda (&rest _)
              (erase-buffer)
              0))
    (expect (navegosa--run "getActiveTabInfo" "Safari") :to-be nil)))

;;; Tabs buffer rendering

(describe "navegosa-tabs--sanitize-title"
  (it "strips leading stars"
    (expect (navegosa-tabs--sanitize-title "** Important") :to-equal "Important"))

  (it "strips org link brackets"
    (expect (navegosa-tabs--sanitize-title "Some [[link]]") :to-equal "Some link"))

  (it "strips notification counts"
    (expect (navegosa-tabs--sanitize-title "(3) GitHub") :to-equal "GitHub"))

  (it "handles combined cases"
    (expect (navegosa-tabs--sanitize-title "*Hello [[world]]") :to-equal "Hello world")
    (expect (navegosa-tabs--sanitize-title "*(42) [[test]]") :to-equal "test")))

(describe "navegosa-tabs--render"
  (it "renders tabs grouped by window into Org headings"
    (let ((tabs '((:windowIndex 1 :tabIndex 1 :url "https://a.com" :title "Tab A" :active t)
                  (:windowIndex 1 :tabIndex 2 :url "https://b.com" :title "Tab B" :active nil)
                  (:windowIndex 2 :tabIndex 1 :url "https://c.com" :title "Tab C" :active nil))))
      (with-temp-buffer
        (navegosa-tabs-mode)
        (navegosa-tabs--render tabs)
        (goto-char (point-min))
        ;; Two windows
        (expect (how-many "^\\* Window" (point-min) (point-max)) :to-equal 2)
        ;; Three tabs total
        (expect (how-many "^\\*\\*" (point-min) (point-max)) :to-equal 3)
        ;; Active tab marked
        (expect (buffer-string) :to-match "ACTIVE Tab A")
        ;; Properties present
        (expect (buffer-string) :to-match ":URL: https://a.com")
        (expect (buffer-string) :to-match ":WINDOW-INDEX: 1")
        (expect (buffer-string) :to-match ":TAB-INDEX: 2"))))

  (it "handles empty tab list"
    (with-temp-buffer
      (navegosa-tabs-mode)
      (navegosa-tabs--render '())
      (expect (string-trim (buffer-string)) :to-equal ""))))

(describe "navegosa-tabs--tab-at-point"
  (it "extracts tab data from properties at point"
    (let ((tabs '((:windowIndex 1 :tabIndex 1 :url "https://a.com" :title "Tab A" :active nil)
                  (:windowIndex 1 :tabIndex 2 :url "https://b.com" :title "Tab B" :active nil))))
      (with-temp-buffer
        (navegosa-tabs-mode)
        (navegosa-tabs--render tabs)
        (goto-char (point-min))
        ;; Move to the second tab heading
        (re-search-forward "Tab B")
        (let* ((tab (navegosa-tabs--tab-at-point))
               (url (plist-get tab :url))
               (win-idx (plist-get tab :windowIndex))
               (tab-idx (plist-get tab :tabIndex)))
          (expect url :to-equal "https://b.com")
          (expect win-idx :to-equal 1)
          (expect tab-idx :to-equal 2)))))

  (it "returns nil on window heading"
    (let ((tabs '((:windowIndex 1 :tabIndex 1 :url "https://a.com" :title "Tab A" :active nil))))
      (with-temp-buffer
        (navegosa-tabs-mode)
        (navegosa-tabs--render tabs)
        (goto-char (point-min))
        (expect (navegosa-tabs--tab-at-point) :to-be nil)))))

;;; Interactive commands (mocked)

(describe "navegosa-copy-tab-link"
  (it "copies URL to kill ring and returns it"
    (spy-on 'navegosa--run
            :and-return-value '(:url "https://example.com" :title "Example" :windowIndex 1 :tabIndex 1))
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (let ((result (navegosa-copy-tab-link)))
      (expect result :to-equal "https://example.com")
      (expect (car kill-ring) :to-equal "https://example.com")))

  (it "signals error when no active tab"
    (spy-on 'navegosa--run :and-return-value nil)
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (expect (navegosa-copy-tab-link) :to-throw 'user-error)))

(describe "navegosa-insert-link"
  (it "inserts org-mode link"
    (spy-on 'navegosa--run
            :and-return-value '(:url "https://example.com" :title "Example Page" :windowIndex 1 :tabIndex 1))
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (with-temp-buffer
      (org-mode)
      (navegosa-insert-link)
      (expect (buffer-string) :to-match "\\[\\[https://example.com\\]\\[Example Page\\]\\]")))

  (it "inserts markdown link"
    (spy-on 'navegosa--run
            :and-return-value '(:url "https://example.com" :title "Example Page" :windowIndex 1 :tabIndex 1))
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (with-temp-buffer
      (let ((major-mode 'markdown-mode))
        (navegosa-insert-link)
        (expect (buffer-string) :to-equal "[Example Page](https://example.com)"))))

  (it "inserts plain URL in fundamental mode"
    (spy-on 'navegosa--run
            :and-return-value '(:url "https://example.com" :title "Example Page" :windowIndex 1 :tabIndex 1))
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (with-temp-buffer
      (navegosa-insert-link)
      (expect (buffer-string) :to-equal "https://example.com")))

  (it "strips notification count from title"
    (spy-on 'navegosa--run
            :and-return-value '(:url "https://github.com" :title "(5) GitHub" :windowIndex 1 :tabIndex 1))
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (with-temp-buffer
      (org-mode)
      (navegosa-insert-link)
      (expect (buffer-string) :to-match "\\[GitHub\\]\\]"))))

(describe "navegosa-grab-text"
  (it "returns text string when called non-interactively"
    (spy-on 'navegosa--run
            :and-return-value '(:url "https://example.com" :title "Example" :content "Hello world"))
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (expect (navegosa-grab-text) :to-equal "Hello world"))

  (it "signals error when no content"
    (spy-on 'navegosa--run :and-return-value nil)
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (expect (navegosa-grab-text) :to-throw 'user-error)))

(describe "navegosa-tabs-switch"
  (it "calls activateTab with correct indices"
    (let ((called-args nil))
      (spy-on 'navegosa--run
              :and-call-fake (lambda (fn &rest args)
                               (setq called-args (cons fn args))
                               '(:ok t)))
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (let ((tabs '((:windowIndex 2 :tabIndex 3 :url "https://a.com" :title "Tab A" :active nil))))
        (with-temp-buffer
          (navegosa-tabs-mode)
          (navegosa-tabs--render tabs)
          (goto-char (point-min))
          (re-search-forward "Tab A")
          (navegosa-tabs-switch)
          (expect called-args :to-equal '("activateTab" "Safari" 2 3))))))

  (it "signals error when not on a tab heading"
    (let ((tabs '((:windowIndex 1 :tabIndex 1 :url "https://a.com" :title "Tab A" :active nil))))
      (with-temp-buffer
        (navegosa-tabs-mode)
        (navegosa-tabs--render tabs)
        (goto-char (point-min)) ;; on Window heading
        (expect (navegosa-tabs-switch) :to-throw 'user-error)))))

(describe "navegosa-tabs-close"
  (it "calls closeTab and refreshes on confirmation"
    (let ((close-called nil))
      (spy-on 'navegosa--run
              :and-call-fake (lambda (fn &rest args)
                               (when (equal fn "closeTab")
                                 (setq close-called (cons fn args)))
                               '(:ok t)))
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (spy-on 'navegosa-get-tabs
              :and-return-value '((:windowIndex 1 :tabIndex 1 :url "https://a.com" :title "Tab A" :active nil)))
      (spy-on 'yes-or-no-p :and-return-value t)
      (with-temp-buffer
        (navegosa-tabs-mode)
        (navegosa-tabs--render
         '((:windowIndex 1 :tabIndex 1 :url "https://a.com" :title "Tab A" :active nil)))
        (goto-char (point-min))
        (re-search-forward "Tab A")
        (navegosa-tabs-close)
        (expect close-called :to-equal '("closeTab" "Safari" 1 1))
        (expect 'yes-or-no-p :to-have-been-called))))

  (it "does nothing when user declines"
    (spy-on 'navegosa--run)
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (spy-on 'yes-or-no-p :and-return-value nil)
    (with-temp-buffer
      (navegosa-tabs-mode)
      (navegosa-tabs--render
       '((:windowIndex 1 :tabIndex 1 :url "https://a.com" :title "Tab A" :active nil)))
      (goto-char (point-min))
      (re-search-forward "Tab A")
      (navegosa-tabs-close)
      (expect 'navegosa--run :not :to-have-been-called))))

(describe "navegosa-tabs-browse-url"
  (it "opens URL in eww"
    (spy-on 'eww)
    (let ((tabs '((:windowIndex 1 :tabIndex 1 :url "https://a.com" :title "Tab A" :active nil))))
      (with-temp-buffer
        (navegosa-tabs-mode)
        (navegosa-tabs--render tabs)
        (goto-char (point-min))
        (re-search-forward "Tab A")
        (navegosa-tabs-browse-url)
        (expect 'eww :to-have-been-called-with "https://a.com"))))

  (it "signals error when not on a tab"
    (let ((tabs '((:windowIndex 1 :tabIndex 1 :url "https://a.com" :title "Tab A" :active nil))))
      (with-temp-buffer
        (navegosa-tabs-mode)
        (navegosa-tabs--render tabs)
        (goto-char (point-min))
        (expect (navegosa-tabs-browse-url) :to-throw 'user-error)))))

;;; Jump to link

(describe "navegosa--jump-make-candidates"
  (it "formats candidates with hint, text, and URL"
    (let* ((links '((:hint "A" :text "Example" :href "https://example.com" :index 0)
                    (:hint "B" :text "Other" :href "https://other.com" :index 1)))
           (candidates (navegosa--jump-make-candidates links))
           (first-display (car (nth 0 candidates)))
           (second-display (car (nth 1 candidates))))
      (expect (length candidates) :to-equal 2)
      (expect first-display :to-match "\\[A\\] Example")
      (expect first-display :to-match "https://example.com")
      (expect second-display :to-match "\\[B\\] Other")))

  (it "shows placeholder for empty link text"
    (let* ((links '((:hint "A" :text "" :href "https://example.com" :index 0)))
           (candidates (navegosa--jump-make-candidates links))
           (display (caar candidates)))
      (expect display :to-match "(no text)")))

  (it "preserves link plist in cdr"
    (let* ((links '((:hint "A" :text "Test" :href "https://test.com" :index 5)))
           (candidates (navegosa--jump-make-candidates links))
           (link (cdar candidates))
           (idx (plist-get link :index)))
      (expect idx :to-equal 5))))

(describe "navegosa-jump-to-link"
  :var (navegosa--scripts-cache)

  (before-each
    (setq navegosa--scripts-cache "const Navegosa = {};"))

  (it "calls getLinksAndInjectHints with viewport scope"
    (let ((navegosa-jump-links-scope 'viewport)
          (all-calls nil))
      (spy-on 'navegosa--run
              :and-call-fake (lambda (fn &rest args)
                               (push (cons fn args) all-calls)
                               '((:hint "A" :text "Link" :href "https://a.com" :index 0))))
      (spy-on 'navegosa--run-async)
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (spy-on 'completing-read :and-return-value "[A] Link  https://a.com")
      (navegosa-jump-to-link)
      (let* ((first-call (car (last all-calls)))
             (fn (car first-call))
             (scope-arg (nth 2 first-call)))
        (expect fn :to-equal "getLinksAndInjectHints")
        (expect scope-arg :to-equal t))))

  (it "calls getLinksAndInjectHints with all scope"
    (let ((navegosa-jump-links-scope 'all)
          (all-calls nil))
      (spy-on 'navegosa--run
              :and-call-fake (lambda (fn &rest args)
                               (push (cons fn args) all-calls)
                               '((:hint "A" :text "Link" :href "https://a.com" :index 0))))
      (spy-on 'navegosa--run-async)
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (spy-on 'completing-read :and-return-value "[A] Link  https://a.com")
      (navegosa-jump-to-link)
      (let* ((first-call (car (last all-calls)))
             (scope-arg (nth 2 first-call)))
        (expect scope-arg :to-be nil))))

  (it "clicks link in same-tab mode"
    (let ((navegosa-jump-links-scope 'viewport)
          (navegosa-jump-links-action 'same-tab)
          (click-args nil))
      (spy-on 'navegosa--run
              :and-call-fake (lambda (fn &rest args)
                               (when (equal fn "clickLink")
                                 (setq click-args (cons fn args)))
                               '((:hint "A" :text "Link" :href "https://a.com" :index 3))))
      (spy-on 'navegosa--run-async)
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (spy-on 'completing-read :and-return-value "[A] Link  https://a.com")
      (navegosa-jump-to-link)
      (expect (car click-args) :to-equal "clickLink")
      (expect (nth 2 click-args) :to-equal 3)))

  (it "opens in new tab when configured"
    (let ((navegosa-jump-links-scope 'viewport)
          (navegosa-jump-links-action 'new-tab)
          (open-args nil))
      (spy-on 'navegosa--run
              :and-call-fake (lambda (fn &rest args)
                               (when (equal fn "openLinkNewTab")
                                 (setq open-args (cons fn args)))
                               '((:hint "A" :text "Link" :href "https://a.com" :index 0))))
      (spy-on 'navegosa--run-async)
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (spy-on 'completing-read :and-return-value "[A] Link  https://a.com")
      (navegosa-jump-to-link)
      (expect (car open-args) :to-equal "openLinkNewTab")
      (expect (nth 2 open-args) :to-equal "https://a.com")))

  (it "signals error when no links found"
    (spy-on 'navegosa--run :and-return-value nil)
    (spy-on 'navegosa--run-async)
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (expect (navegosa-jump-to-link) :to-throw 'user-error))

  (it "cleans up hints even on quit"
    (spy-on 'navegosa--run
            :and-return-value '((:hint "A" :text "Link" :href "https://a.com" :index 0)))
    (spy-on 'navegosa--run-async)
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (spy-on 'completing-read :and-call-fake (lambda (&rest _) (signal 'quit nil)))
    (condition-case nil (navegosa-jump-to-link) (quit nil))
    (expect 'navegosa--run-async :to-have-been-called-with
            "clearLinkHints" "Safari")))

(describe "navegosa--run-async"
  (it "creates an async process"
    (let ((navegosa--scripts-cache "const Navegosa = {};")
          (proc-args nil))
      (spy-on 'navegosa--ensure-macos)
      (spy-on 'make-process
              :and-call-fake (lambda (&rest args)
                               (setq proc-args args)
                               nil))
      (spy-on 'process-send-string)
      (spy-on 'process-send-eof)
      (navegosa--run-async "clearLinkHints" "Safari")
      (let ((cmd (plist-get proc-args :command)))
        (expect cmd :to-equal '("osascript" "-l" "JavaScript")))
      (expect 'process-send-string :to-have-been-called)
      (expect 'process-send-eof :to-have-been-called))))

;;; Browser detection

(describe "navegosa--browser"
  (it "returns defcustom value when set"
    (let ((navegosa-browser "Brave Browser")
          (navegosa--browser-cache nil))
      (expect (navegosa--browser) :to-equal "Brave Browser")))

  (it "returns cached value when defcustom is nil"
    (let ((navegosa-browser nil)
          (navegosa--browser-cache "Arc"))
      (expect (navegosa--browser) :to-equal "Arc")))

  (it "clears cache on reset"
    (let ((navegosa--scripts-cache "cached")
          (navegosa--browser-cache "cached"))
      (navegosa-reset)
      (expect navegosa--scripts-cache :to-be nil)
      (expect navegosa--browser-cache :to-be nil))))

;;; navegosa-tests.el ends here
