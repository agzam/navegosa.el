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
(require 'navegosa-media)
(require 'navegosa-mpris)
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

;;; Script file location

(describe "navegosa--scripts-file"
  (it "finds the script in the same directory as the source"
    (let* ((tmp-dir (file-truename (make-temp-file "navegosa-test-" t))))
      (unwind-protect
          (progn
            (write-region "" nil (expand-file-name "navegosa.el" tmp-dir))
            (write-region "// js" nil (expand-file-name "navegosa-scripts.js" tmp-dir))
            (let ((load-file-name (expand-file-name "navegosa.el" tmp-dir)))
              (expect (navegosa--scripts-file)
                      :to-equal (expand-file-name "navegosa-scripts.js" tmp-dir))))
        (delete-directory tmp-dir t))))

  (it "follows symlinks to find the script in the source repo"
    (let* ((source-dir (file-truename (make-temp-file "navegosa-src-" t)))
           (build-dir (file-truename (make-temp-file "navegosa-build-" t))))
      (unwind-protect
          (progn
            ;; Source repo has both .el and .js
            (write-region "" nil (expand-file-name "navegosa.el" source-dir))
            (write-region "// js" nil (expand-file-name "navegosa-scripts.js" source-dir))
            ;; Build dir has only a symlink to the .el
            (make-symbolic-link
             (expand-file-name "navegosa.el" source-dir)
             (expand-file-name "navegosa.el" build-dir))
            (let ((load-file-name (expand-file-name "navegosa.el" build-dir)))
              (expect (navegosa--scripts-file)
                      :to-equal (expand-file-name "navegosa-scripts.js" source-dir))))
        (delete-directory source-dir t)
        (delete-directory build-dir t))))

  (it "resolves via .el symlink when locate-library returns .elc"
    ;; Simulates straight.el: build dir has a local .elc and a symlinked .el,
    ;; but the .js file only exists in the source repo.
    (let* ((source-dir (file-truename (make-temp-file "navegosa-src-" t)))
           (build-dir (file-truename (make-temp-file "navegosa-build-" t))))
      (unwind-protect
          (progn
            (write-region "" nil (expand-file-name "navegosa.el" source-dir))
            (write-region "// js" nil (expand-file-name "navegosa-scripts.js" source-dir))
            ;; Build dir: symlinked .el + local .elc (byte-compiled in place)
            (make-symbolic-link
             (expand-file-name "navegosa.el" source-dir)
             (expand-file-name "navegosa.el" build-dir))
            (write-region "" nil (expand-file-name "navegosa.elc" build-dir))
            ;; locate-library returns the .elc - the actual failure scenario
            (let ((load-file-name nil))
              (spy-on 'locate-library
                      :and-return-value (expand-file-name "navegosa.elc" build-dir))
              (expect (navegosa--scripts-file)
                      :to-equal (expand-file-name "navegosa-scripts.js" source-dir))))
        (delete-directory source-dir t)
        (delete-directory build-dir t))))

  (it "errors when script file cannot be found"
    (let ((tmp-dir (make-temp-file "navegosa-test-" t)))
      (unwind-protect
          (let ((load-file-name (expand-file-name "navegosa.el" tmp-dir)))
            (expect (navegosa--scripts-file) :to-throw 'error))
        (delete-directory tmp-dir t)))))

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

;;; Script building

(describe "navegosa--build-script"
  (it "appends a JSON.stringify dispatch call to the JS body"
    (let ((navegosa--scripts-cache "const Navegosa = {};"))
      (expect (navegosa--build-script "mediaCommand" '("Safari" 1 2 "seekBy" -5))
              :to-equal
              "const Navegosa = {};\nJSON.stringify(Navegosa.mediaCommand(\"Safari\", 1, 2, \"seekBy\", -5))"))))

;;; Media: formatting

(describe "navegosa-media--url-pattern"
  (it "joins patterns with |"
    (let ((navegosa-media-url-patterns '("youtube\\.com/watch" "vimeo\\.com")))
      (expect (navegosa-media--url-pattern)
              :to-equal "youtube\\.com/watch|vimeo\\.com"))))

(describe "navegosa-media--format-time"
  (it "formats minutes and seconds"
    (expect (navegosa-media--format-time 65) :to-equal "1:05")
    (expect (navegosa-media--format-time 0) :to-equal "0:00"))

  (it "formats hours"
    (expect (navegosa-media--format-time 3725) :to-equal "1:02:05"))

  (it "returns live for nil (Infinity duration serializes to null)"
    (expect (navegosa-media--format-time nil) :to-equal "live")))

(describe "navegosa-media--format-state"
  (it "shows position, rate, volume and stripped title"
    (let ((s (navegosa-media--format-state
              '(:time 754.3 :duration 3367 :rate 1.5 :paused nil
                :volume 0.8 :muted nil :title "Some Video - YouTube"))))
      (expect s :to-match "12:34/56:07")
      (expect s :to-match "1.5x")
      (expect s :to-match "vol:80%")
      (expect s :to-match "Some Video")
      (expect s :not :to-match "YouTube")
      (expect s :not :to-match "paused")))

  (it "omits rate at 1x"
    (expect (navegosa-media--format-state '(:time 1 :duration 2 :rate 1 :volume 0.5))
            :not :to-match "x"))

  (it "marks paused and muted"
    (let ((s (navegosa-media--format-state
              '(:time 0 :duration 10 :rate 1 :paused t :muted t :volume 0))))
      (expect s :to-match "\\[paused\\]")
      (expect s :to-match "\\[muted\\]")))

  (it "includes command warnings"
    (expect (navegosa-media--format-state '(:time 0 :duration 10 :warning "no subtitles"))
            :to-match "(no subtitles)")))

(describe "navegosa-media--timestamped-url"
  (it "appends t= to a bare watch URL"
    (expect (navegosa-media--timestamped-url "https://www.youtube.com/watch?v=abc" 754.9)
            :to-equal "https://www.youtube.com/watch?v=abc&t=754s"))

  (it "replaces an existing t= parameter"
    (expect (navegosa-media--timestamped-url "https://www.youtube.com/watch?v=abc&t=30s" 60)
            :to-equal "https://www.youtube.com/watch?v=abc&t=60s"))

  (it "replaces t= when it is the first parameter"
    (expect (navegosa-media--timestamped-url "https://www.youtube.com/watch?t=30s&v=abc" 60)
            :to-equal "https://www.youtube.com/watch?v=abc&t=60s"))

  (it "handles youtu.be short links"
    (expect (navegosa-media--timestamped-url "https://youtu.be/abc" 90)
            :to-equal "https://youtu.be/abc?t=90s")
    (expect (navegosa-media--timestamped-url "https://youtu.be/abc?t=5s" 90)
            :to-equal "https://youtu.be/abc?t=90s"))

  (it "uses a media fragment for non-YouTube URLs"
    (expect (navegosa-media--timestamped-url "https://vimeo.com/123" 90)
            :to-equal "https://vimeo.com/123#t=90s"))

  (it "drops an existing fragment"
    (expect (navegosa-media--timestamped-url "https://vimeo.com/123#t=5s" 90)
            :to-equal "https://vimeo.com/123#t=90s")))

;;; Media: tab discovery

(describe "navegosa-media--locate"
  (before-each (setq navegosa-media--tab nil))
  (after-each (setq navegosa-media--tab nil))

  (it "errors when no candidates"
    (spy-on 'navegosa--run :and-return-value nil)
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (expect (navegosa-media--locate) :to-throw 'user-error))

  (it "caches a single candidate without prompting"
    (spy-on 'navegosa--run
            :and-return-value
            '((:windowIndex 1 :tabIndex 3 :url "https://www.youtube.com/watch?v=x"
               :title "Vid" :active nil)))
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (spy-on 'completing-read)
    (let ((tab (navegosa-media--locate)))
      (expect (plist-get tab :tabIndex) :to-equal 3)
      (expect navegosa-media--tab :to-equal tab)
      (expect 'completing-read :not :to-have-been-called)))

  (it "prompts among several candidates"
    (spy-on 'navegosa--run
            :and-return-value
            '((:windowIndex 1 :tabIndex 1 :url "https://youtu.be/a" :title "A" :active nil)
              (:windowIndex 2 :tabIndex 5 :url "https://youtu.be/b" :title "B" :active nil)))
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (spy-on 'completing-read :and-return-value "B | https://youtu.be/b")
    (let ((tab (navegosa-media--locate)))
      (expect (plist-get tab :tabIndex) :to-equal 5)))

  (it "auto-picks the first candidate when told to"
    (spy-on 'navegosa--run
            :and-return-value
            '((:windowIndex 1 :tabIndex 1 :url "https://youtu.be/a" :title "A" :active nil)
              (:windowIndex 2 :tabIndex 5 :url "https://youtu.be/b" :title "B" :active nil)))
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (spy-on 'completing-read)
    (let ((tab (navegosa-media--locate 'auto)))
      (expect (plist-get tab :tabIndex) :to-equal 1)
      (expect 'completing-read :not :to-have-been-called)))

  (it "prompt mode offers even a single candidate in the minibuffer"
    (spy-on 'navegosa--run
            :and-return-value
            '((:windowIndex 1 :tabIndex 3 :url "https://youtu.be/a" :title "A" :active nil)))
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (spy-on 'completing-read :and-return-value "A | https://youtu.be/a")
    (let ((tab (navegosa-media--locate 'prompt)))
      (expect 'completing-read :to-have-been-called)
      (expect (plist-get tab :tabIndex) :to-equal 3)))

  (it "passes the joined url pattern to getMediaTabs"
    (let ((navegosa-media-url-patterns '("a" "b"))
          (call nil))
      (spy-on 'navegosa--run
              :and-call-fake
              (lambda (fn &rest args)
                (setq call (cons fn args))
                '((:windowIndex 1 :tabIndex 1 :url "u" :title "t" :active nil))))
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (navegosa-media--locate)
      (expect call :to-equal '("getMediaTabs" "Safari" "a|b")))))

(describe "navegosa-media--ensure-tab"
  (it "uses the cache without re-locating"
    (let ((navegosa-media--tab '(:windowIndex 1 :tabIndex 2)))
      (spy-on 'navegosa--run)
      (expect (navegosa-media--ensure-tab) :to-equal '(:windowIndex 1 :tabIndex 2))
      (expect 'navegosa--run :not :to-have-been-called))))

;;; Media: command dispatch

(describe "navegosa-media--dispatch"
  (before-each
    (spy-on 'navegosa-media--use-mpris-p :and-return-value nil)
    (setq navegosa-media--tab
          '(:windowIndex 1 :tabIndex 2
            :url "https://www.youtube.com/watch?v=x" :title "Vid")))
  (after-each (setq navegosa-media--tab nil))

  (it "sends mediaCommand with cmd and arg and echoes the returned state"
    (let ((sent nil))
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (spy-on 'navegosa-media--call-async
              :and-call-fake
              (lambda (fn args callback)
                (setq sent (list fn args))
                (funcall callback
                         '(:time 10 :duration 100 :rate 1 :paused nil
                           :volume 1 :muted nil :title "Vid")
                         nil)))
      (spy-on 'message)
      (navegosa-media--dispatch "seekBy" -5)
      (expect sent :to-equal '("mediaCommand" ("Safari" 1 2 "seekBy" -5)))
      (expect 'message :to-have-been-called)))

  (it "sends mediaStatus for the status command"
    (let ((sent nil))
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (spy-on 'navegosa-media--call-async
              :and-call-fake
              (lambda (fn args callback)
                (setq sent (list fn args))
                (funcall callback '(:time 1) nil)))
      (spy-on 'message)
      (navegosa-media--dispatch "status" nil)
      (expect sent :to-equal '("mediaStatus" ("Safari" 1 2)))))

  (it "invalidates cache, re-locates and retries exactly once on failure"
    (let ((calls 0))
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (spy-on 'navegosa-media--call-async
              :and-call-fake
              (lambda (_fn _args callback)
                (setq calls (1+ calls))
                (funcall callback nil "boom")))
      (spy-on 'navegosa-media--locate
              :and-call-fake
              (lambda (&optional _auto)
                (setq navegosa-media--tab '(:windowIndex 9 :tabIndex 9))))
      (spy-on 'message)
      (navegosa-media--dispatch "playPause" nil)
      (expect calls :to-equal 2)
      (expect 'navegosa-media--locate :to-have-been-called-with 'auto)
      (expect 'message :to-have-been-called-with "navegosa-media: %s" "boom")))

  (it "reports when re-locating finds nothing"
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (spy-on 'navegosa-media--call-async
            :and-call-fake (lambda (_fn _args callback) (funcall callback nil "boom")))
    (spy-on 'navegosa-media--locate
            :and-call-fake
            (lambda (&optional _auto) (user-error "navegosa-media: no media tabs open")))
    (spy-on 'message)
    (navegosa-media--dispatch "playPause" nil)
    (expect 'message :to-have-been-called-with
            "%s" "navegosa-media: no media tabs open")))

(describe "navegosa-media commands"
  (before-each (spy-on 'navegosa-media--dispatch))

  (it "seek commands scale by step and prefix arg"
    (let ((navegosa-media-seek-step 5))
      (navegosa-media-seek-forward)
      (expect 'navegosa-media--dispatch :to-have-been-called-with "seekBy" 5)
      (navegosa-media-seek-backward 3)
      (expect 'navegosa-media--dispatch :to-have-been-called-with "seekBy" -15)))

  (it "speed commands multiply by step"
    (let ((navegosa-media-speed-step 2.0))
      (navegosa-media-speed-up)
      (expect 'navegosa-media--dispatch :to-have-been-called-with "rateMul" 2.0)
      (navegosa-media-speed-down)
      (expect 'navegosa-media--dispatch :to-have-been-called-with "rateMul" 0.5)
      (navegosa-media-speed-reset)
      (expect 'navegosa-media--dispatch :to-have-been-called-with "rateSet" 1)))

  (it "volume commands step by volume-step"
    (let ((navegosa-media-volume-step 0.2))
      (navegosa-media-volume-up)
      (expect 'navegosa-media--dispatch :to-have-been-called-with "volumeBy" 0.2)
      (navegosa-media-volume-down)
      (expect 'navegosa-media--dispatch :to-have-been-called-with "volumeBy" -0.2)))

  (it "toggles and status dispatch their commands"
    (navegosa-media-play-pause)
    (expect 'navegosa-media--dispatch :to-have-been-called-with "playPause" nil)
    (navegosa-media-mute-toggle)
    (expect 'navegosa-media--dispatch :to-have-been-called-with "muteToggle" nil)
    (navegosa-media-subs-toggle)
    (expect 'navegosa-media--dispatch :to-have-been-called-with "subsToggle" nil)
    (navegosa-media-next)
    (expect 'navegosa-media--dispatch :to-have-been-called-with "next" nil)
    (navegosa-media-prev)
    (expect 'navegosa-media--dispatch :to-have-been-called-with "prev" nil)
    (navegosa-media-status)
    (expect 'navegosa-media--dispatch :to-have-been-called-with "status" nil)
    (navegosa-media-seek-to 42)
    (expect 'navegosa-media--dispatch :to-have-been-called-with "seekTo" 42)
    (navegosa-media-theater-toggle)
    (expect 'navegosa-media--dispatch :to-have-been-called-with "theaterToggle" nil)))

(describe "navegosa-media-fullscreen-toggle"
  (before-each
    (spy-on 'navegosa-media--use-mpris-p :and-return-value nil)
    (setq navegosa-media--tab '(:windowIndex 2 :tabIndex 7)))
  (after-each (setq navegosa-media--tab nil))

  (it "toggles fullscreen on the media tab's window"
    (let ((sent nil))
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (spy-on 'navegosa-media--call-async
              :and-call-fake
              (lambda (fn args callback)
                (setq sent (list fn args))
                (funcall callback '(:ok t :fullscreen t) nil)))
      (spy-on 'message)
      (navegosa-media-fullscreen-toggle)
      (expect sent :to-equal '("windowFullscreenToggle" ("Safari" 2)))
      (expect 'message :to-have-been-called-with "Fullscreen: %s" "on")))

  (it "surfaces the accessibility-permission error"
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (spy-on 'navegosa-media--call-async
            :and-call-fake
            (lambda (_fn _args callback)
              (funcall callback nil "needs Accessibility permission")))
    (spy-on 'message)
    (navegosa-media-fullscreen-toggle)
    (expect 'message :to-have-been-called-with
            "navegosa-media: %s" "needs Accessibility permission")))

(describe "navegosa-media-copy-url"
  (it "kills a timestamped URL built from returned state"
    (spy-on 'navegosa-media--dispatch
            :and-call-fake
            (lambda (_cmd _arg &optional handler _no-retry)
              (funcall handler '(:time 90.7 :url "https://www.youtube.com/watch?v=x"
                                 :title "Vid"))))
    (spy-on 'message)
    (navegosa-media-copy-url)
    (expect (car kill-ring) :to-equal "https://www.youtube.com/watch?v=x&t=90s"))

  (it "degrades honestly when the backend exposes no URL"
    ;; Chromium MPRIS metadata carries no xesam:url.
    (spy-on 'navegosa-media--dispatch
            :and-call-fake
            (lambda (_cmd _arg &optional handler _no-retry)
              (funcall handler '(:time 90.7 :title "Vid"))))
    (expect (navegosa-media-copy-url) :to-throw 'user-error)))

(describe "navegosa-media-open-tab"
  (it "activates the cached tab"
    (let ((navegosa-media--tab '(:windowIndex 2 :tabIndex 7)))
      (spy-on 'navegosa--run)
      (spy-on 'navegosa--browser :and-return-value "Safari")
      (navegosa-media-open-tab)
      (expect 'navegosa--run :to-have-been-called-with "activateTab" "Safari" 2 7))))

(describe "navegosa-media-select-tab"
  (before-each (spy-on 'navegosa-media--use-mpris-p :and-return-value nil))
  (after-each (setq navegosa-media--tab nil))

  (it "prompts and brings the picked tab up in the browser"
    (spy-on 'navegosa-media--locate
            :and-call-fake
            (lambda (&optional _mode)
              (setq navegosa-media--tab '(:windowIndex 1 :tabIndex 5 :title "Vid"))))
    (spy-on 'navegosa--run)
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (navegosa-media-select-tab)
    (expect 'navegosa-media--locate :to-have-been-called-with 'prompt)
    (expect 'navegosa--run :to-have-been-called-with "activateTab" "Safari" 1 5)))

(describe "navegosa-media-open-url"
  (before-each (spy-on 'navegosa-media--use-mpris-p :and-return-value nil))
  (after-each (setq navegosa-media--tab nil))

  (it "opens the url via openMediaTab and controls the new tab"
    (spy-on 'navegosa-media--call-sync
            :and-return-value '(:windowIndex 1 :tabIndex 9
                                :url "https://youtu.be/x" :title ""))
    (spy-on 'navegosa--browser :and-return-value "Safari")
    (navegosa-media-open-url "https://youtu.be/x")
    (expect 'navegosa-media--call-sync :to-have-been-called-with
            "openMediaTab" "Safari" "https://youtu.be/x")
    (expect (plist-get navegosa-media--tab :tabIndex) :to-equal 9)))

;;; MPRIS lane (Linux transport, D-Bus fully mocked)

(defmacro navegosa-tests--with-mpris-bus (props &rest body)
  "Run BODY with the D-Bus mocked from PROPS.
PROPS is an alist of (SERVICE . PROP-ALIST); `dbus-list-names'
returns the services, `dbus-get-property' serves PROP-ALIST, and
method calls are recorded into the anaphoric variable `calls'."
  (declare (indent 1))
  `(let ((bus ,props) (calls nil))
     (ignore bus calls)
     (spy-on 'dbus-list-names
             :and-call-fake (lambda (_type) (mapcar #'car bus)))
     (spy-on 'dbus-get-property
             :and-call-fake
             (lambda (_type service _path _iface prop)
               (cdr (assoc prop (cdr (assoc service bus))))))
     (spy-on 'dbus-call-method
             :and-call-fake
             (lambda (_type service _path _iface method &rest args)
               (push (cons service (cons method args)) calls)))
     ,@body))

(describe "navegosa-mpris--services"
  (after-each (setq navegosa-mpris--service nil))

  (it "filters to active players, browsers first, Playing over Paused"
    (navegosa-tests--with-mpris-bus
        '(("org.mpris.MediaPlayer2.spotify"
           . (("PlaybackStatus" . "Playing")))
          ("org.mpris.MediaPlayer2.brave.instance1"
           . (("PlaybackStatus" . "Stopped")))
          ("org.mpris.MediaPlayer2.chromium.instance2"
           . (("PlaybackStatus" . "Paused")))
          ("org.freedesktop.Notifications"
           . (("PlaybackStatus" . "Playing"))))
      ;; the lingering Stopped name and the non-MPRIS name drop out;
      ;; a paused browser still beats a playing non-browser
      (expect (navegosa-mpris--services)
              :to-equal '("org.mpris.MediaPlayer2.chromium.instance2"
                          "org.mpris.MediaPlayer2.spotify")))))

(describe "navegosa-mpris--locate"
  (after-each (setq navegosa-mpris--service nil))

  (it "errors when no player has controllable media"
    (navegosa-tests--with-mpris-bus
        '(("org.mpris.MediaPlayer2.brave.instance1"
           . (("PlaybackStatus" . "Stopped"))))
      (expect (navegosa-mpris--locate) :to-throw 'user-error)))

  (it "auto mode takes the best candidate without prompting"
    (navegosa-tests--with-mpris-bus
        '(("org.mpris.MediaPlayer2.spotify"
           . (("PlaybackStatus" . "Playing")))
          ("org.mpris.MediaPlayer2.brave.instance1"
           . (("PlaybackStatus" . "Playing"))))
      (spy-on 'completing-read)
      (expect (navegosa-mpris--locate 'auto)
              :to-equal "org.mpris.MediaPlayer2.brave.instance1")
      (expect navegosa-mpris--service
              :to-equal "org.mpris.MediaPlayer2.brave.instance1")
      (expect 'completing-read :not :to-have-been-called)))

  (it "prompt mode offers even a single candidate in the minibuffer"
    (navegosa-tests--with-mpris-bus
        '(("org.mpris.MediaPlayer2.brave.instance1"
           . (("PlaybackStatus" . "Playing")
              ("Identity" . "Brave")
              ("Metadata" . (("xesam:title" ("Vid")))))))
      (spy-on 'completing-read :and-call-fake
              (lambda (_prompt collection &rest _)
                (car collection)))
      (expect (navegosa-mpris--locate 'prompt)
              :to-equal "org.mpris.MediaPlayer2.brave.instance1")
      (expect 'completing-read :to-have-been-called))))

(describe "navegosa-mpris--state"
  (it "maps microseconds and flags into the JXA-shaped plist"
    (navegosa-tests--with-mpris-bus
        '(("svc" . (("PlaybackStatus" . "Paused")
                    ("Position" . 4864509)
                    ("Rate" . 1.0)
                    ("Metadata" . (("mpris:length" (1282301000))
                                   ("mpris:trackid" ("/t/1"))
                                   ("xesam:title" ("Vid")))))))
      (let ((state (navegosa-mpris--state "svc")))
        (expect (plist-get state :time) :to-be-close-to 4.86 1)
        (expect (plist-get state :duration) :to-be-close-to 1282.3 0)
        (expect (plist-get state :paused) :to-be t)
        (expect (plist-get state :title) :to-equal "Vid")
        (expect (plist-get state :url) :to-be nil)
        ;; browser MPRIS reports a fake static volume - never show one
        (expect (plist-member state :volume) :to-be nil))))

  (it "reports no duration when the length is unknown"
    (navegosa-tests--with-mpris-bus
        '(("svc" . (("PlaybackStatus" . "Playing")
                    ("Position" . 0)
                    ("Metadata" . (("mpris:length" (0)))))))
      (expect (plist-get (navegosa-mpris--state "svc") :duration) :to-be nil)))

  (it "coerces Chromium's paused Rate 0 artifact to 1x"
    (navegosa-tests--with-mpris-bus
        '(("svc" . (("PlaybackStatus" . "Paused")
                    ("Position" . 0)
                    ("Rate" . 0.0)
                    ("Metadata" . nil))))
      (expect (plist-get (navegosa-mpris--state "svc") :rate) :to-equal 1.0))))

(describe "navegosa-mpris--set-position"
  :var (base)
  (before-each
    (setq base '(("svc" . (("Metadata" . (("mpris:length" (100000000))
                                          ("mpris:trackid" ("/t/1")))))))))

  (it "seeks through SetPosition with the track id"
    (navegosa-tests--with-mpris-bus base
      (expect (navegosa-mpris--set-position "svc" 42.0) :to-equal 42.0)
      (expect calls :to-equal
              '(("svc" "SetPosition" :object-path "/t/1" :int64 42000000)))))

  (it "clamps into the track bounds"
    (navegosa-tests--with-mpris-bus base
      (expect (navegosa-mpris--set-position "svc" -5) :to-equal 0.0)
      (expect (navegosa-mpris--set-position "svc" 500) :to-equal 100.0)))

  (it "skips the upper clamp when the length is unknown"
    (navegosa-tests--with-mpris-bus
        '(("svc" . (("Metadata" . (("mpris:length" (0))
                                   ("mpris:trackid" ("/t/1")))))))
      (expect (navegosa-mpris--set-position "svc" 500) :to-equal 500.0)))

  (it "errors without a track id"
    (navegosa-tests--with-mpris-bus '(("svc" . (("Metadata" . nil))))
      (expect (navegosa-mpris--set-position "svc" 10) :to-throw 'user-error))))

(describe "navegosa-mpris-dispatch"
  :var (playing)
  (before-each
    (spy-on 'navegosa-mpris--ensure-service :and-return-value "svc")
    (setq playing (copy-tree
                   '(("svc" . (("PlaybackStatus" . "Playing")
                               ("Position" . 10000000)
                               ("Rate" . 1.0)
                               ("CanGoNext" . nil)
                               ("Metadata" . (("mpris:length" (100000000))
                                              ("mpris:trackid" ("/t/1"))
                                              ("xesam:title" ("Vid"))))))))))

  (it "seekBy seeks from the current position and echoes the target"
    (navegosa-tests--with-mpris-bus playing
      (let (echoed)
        (navegosa-mpris-dispatch "seekBy" 30 (lambda (s) (setq echoed s)))
        (expect calls :to-equal
                '(("svc" "SetPosition" :object-path "/t/1" :int64 40000000)))
        (expect (plist-get echoed :time) :to-equal 40.0))))

  (it "playPause flips the echoed paused flag ahead of the browser"
    (navegosa-tests--with-mpris-bus playing
      (let (echoed)
        (navegosa-mpris-dispatch "playPause" nil (lambda (s) (setq echoed s)))
        (expect (car calls) :to-equal '("svc" "PlayPause"))
        (expect (plist-get echoed :paused) :to-be t))))

  (it "next honors CanGoNext"
    (navegosa-tests--with-mpris-bus playing
      (expect (navegosa-mpris-dispatch "next" nil #'ignore)
              :to-throw 'user-error)
      (setf (cdr (assoc "CanGoNext" (cdr (assoc "svc" bus)))) t)
      (navegosa-mpris-dispatch "next" nil #'ignore)
      (expect (car calls) :to-equal '("svc" "Next"))))

  (it "commands the browsers cannot honor signal honest errors"
    (navegosa-tests--with-mpris-bus playing
      (dolist (cmd '("rateMul" "rateSet" "volumeBy" "muteToggle"
                     "subsToggle" "theaterToggle"))
        (expect (navegosa-mpris-dispatch cmd 1 #'ignore)
                :to-throw 'user-error))
      (expect calls :to-be nil)))

  (it "invalidates the cache and retries exactly once on a D-Bus error"
    (let ((attempts nil))
      (setq navegosa-mpris--service "gone")
      (spy-on 'navegosa-mpris--ensure-service :and-return-value "gone")
      (spy-on 'navegosa-mpris--state
              :and-call-fake
              (lambda (service)
                (push service attempts)
                (signal 'dbus-error '("name vanished"))))
      (expect (navegosa-mpris-dispatch "status" nil #'ignore)
              :to-throw 'user-error)
      (expect attempts :to-equal '("gone" "gone"))
      (expect navegosa-mpris--service :to-be nil)
      ;; the retry went through a fresh ensure-service
      (expect (spy-calls-count 'navegosa-mpris--ensure-service) :to-equal 2))))

(describe "navegosa-media--dispatch (mpris routing)"
  (it "hands the command to the MPRIS lane with the echo handler"
    (spy-on 'navegosa-media--use-mpris-p :and-return-value t)
    (spy-on 'navegosa-mpris-dispatch)
    (navegosa-media--dispatch "playPause" nil)
    (expect 'navegosa-mpris-dispatch :to-have-been-called-with
            "playPause" nil #'navegosa-media--echo))

  (it "never picks MPRIS on darwin"
    (let ((system-type 'darwin))
      (expect (navegosa-media--use-mpris-p) :to-be nil))))

(describe "navegosa-media commands (mpris lane)"
  (before-each (spy-on 'navegosa-media--use-mpris-p :and-return-value t))

  (it "select-tab picks among players instead of tabs"
    (spy-on 'navegosa-mpris-select-player)
    (spy-on 'navegosa-media--locate)
    (navegosa-media-select-tab)
    (expect 'navegosa-mpris-select-player :to-have-been-called)
    (expect 'navegosa-media--locate :not :to-have-been-called))

  (it "open-url falls back to browse-url and resets the player cache"
    (spy-on 'browse-url)
    (spy-on 'message)
    (setq navegosa-mpris--service "stale")
    (navegosa-media-open-url "https://youtu.be/x")
    (expect 'browse-url :to-have-been-called-with "https://youtu.be/x")
    (expect navegosa-mpris--service :to-be nil))

  (it "fullscreen reports the missing window surface"
    (expect (navegosa-media-fullscreen-toggle) :to-throw 'user-error)))

;;; Media: guarded runner (real subprocesses, osascript swapped out)

(describe "navegosa-media--call-sync"
  :var (navegosa--scripts-cache)

  (before-each
    (setq navegosa--scripts-cache "const Navegosa = {};")
    (spy-on 'navegosa--ensure-macos))

  (it "kills the process and errors after the timeout"
    ;; sleep simulates the discarded-tab hang the guard exists for:
    ;; tab.execute never returns.
    (let ((orig (symbol-function 'make-process))
          (navegosa-media-timeout 0.3))
      (spy-on 'make-process
              :and-call-fake
              (lambda (&rest kw)
                (apply orig (plist-put kw :command '("sleep" "30")))))
      (expect (navegosa-media--call-sync "mediaStatus" "Safari" 1 1)
              :to-throw 'user-error)))

  (it "returns the parsed result when the process responds"
    (let ((orig (symbol-function 'make-process)))
      (spy-on 'make-process
              :and-call-fake
              (lambda (&rest kw)
                (apply orig
                       (plist-put kw :command
                                  '("sh" "-c" "cat >/dev/null; printf '{\"time\":5,\"paused\":true}'")))))
      (let ((result (navegosa-media--call-sync "mediaStatus" "Safari" 1 1)))
        (expect (plist-get result :time) :to-equal 5)
        (expect (plist-get result :paused) :to-equal t)))))

;;; navegosa-tests.el ends here
