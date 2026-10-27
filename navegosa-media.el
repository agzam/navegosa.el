;;; navegosa-media.el --- Control media playback in browser tabs -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Control video playback (YouTube, Vimeo, etc.) in a browser tab from
;; Emacs: play/pause, seek, speed, volume, subtitles, next/prev.
;;
;; Two transports share this one command set.  On macOS, Apple-Events
;; JS runs in an isolated world where the page's own JS (e.g.
;; YouTube's player API) is unreachable, so everything goes through
;; the DOM: the <video> element plus player buttons.  On Linux the
;; commands ride the browser's MPRIS D-Bus interface instead
;; (navegosa-mpris.el), a narrower surface where some commands
;; degrade with an honest error.
;;
;; Each command is one JXA call that lists the media tabs, checks which
;; of them play, picks the target by tab id and runs the command.  An
;; unloaded (Memory Saver) tab never answers the check, so every call is
;; deadline-guarded and a silent tab is left out for a while.

;;; Code:

(require 'navegosa)

(declare-function navegosa-mpris-dispatch "navegosa-mpris")
(declare-function navegosa-mpris-select-player "navegosa-mpris")
(defvar navegosa-mpris--service)

(defun navegosa-media--use-mpris-p ()
  "Non-nil when media commands ride MPRIS instead of JXA."
  (and (eq system-type 'gnu/linux)
       (featurep 'dbusbind)
       (require 'navegosa-mpris nil t)
       t))

;;;; Customization

(defgroup navegosa-media nil
  "Control media playback in browser tabs."
  :group 'navegosa
  :prefix "navegosa-media-")

(defcustom navegosa-media-url-patterns
  '("youtube\\.com/watch" "youtu\\.be/" "vimeo\\.com" "twitch\\.tv")
  "JavaScript regexes matching URLs of tabs that may contain media.
Only matching tabs are ever probed: JS execution into a discarded
tab hangs forever, and playing tabs always match by URL."
  :type '(repeat string))

(defcustom navegosa-media-seek-step 5
  "Seconds to seek per step."
  :type 'natnum)

(defcustom navegosa-media-speed-step 1.1
  "Multiplicative playback-rate step."
  :type 'number)

(defcustom navegosa-media-volume-step 0.1
  "Volume step on the 0.0-1.0 scale."
  :type 'number)

(defcustom navegosa-media-timeout 3.0
  "Seconds before a media JXA call is killed.
Guards against probing a tab that cannot respond; a healthy
round-trip is ~150ms."
  :type 'number)

(defcustom navegosa-media-check-timeout 0.75
  "Seconds a tab may take to tell whether it plays.
A tab silent for longer counts as unloaded and stays out of the check
for a minute; a healthy check takes a few milliseconds."
  :type 'number)

;;;; State

(defvar navegosa-media--tab nil
  "The tab the last command acted on: plist with :id, :url and :title.")

(defvar navegosa-media--pick nil
  "Id of the tab picked with `navegosa-media-select-tab'.
A pick wins over playing tabs until `navegosa-media-clear-pick'.")

(defvar navegosa-media--skip nil
  "Alist of (TAB-ID . TIME): tabs that missed the playing check.")

;;;; Guarded runner

(defun navegosa-media--call-async (fn args callback &optional on-line)
  "Call Navegosa.FN with ARGS list via JXA; CALLBACK receives (RESULT ERR).
ON-LINE, when non-nil, receives each line as the script prints it;
the result is the last line.  The osascript process is killed after
`navegosa-media-timeout' seconds, in which case ERR describes the
timeout.  Returns the process object."
  (navegosa--ensure-macos)
  (let* ((buf (generate-new-buffer " *navegosa-media*" t))
         (partial "")
         (timer nil)
         (proc
          (make-process
           :name "navegosa-media"
           :buffer buf
           :command '("osascript" "-l" "JavaScript")
           :connection-type 'pipe
           :noquery t
           :filter
           (lambda (_p chunk)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (goto-char (point-max))
                 (insert chunk)))
             (when on-line
               (let ((lines (split-string (concat partial chunk) "\n")))
                 (setq partial (car (last lines)))
                 (mapc on-line (butlast lines)))))
           :sentinel
           (lambda (p _event)
             (unless (process-live-p p)
               (when timer (cancel-timer timer))
               (let* ((output (when (buffer-live-p buf)
                                (with-current-buffer buf
                                  (string-trim (buffer-string)))))
                      (killed (eq (process-status p) 'signal))
                      (code (process-exit-status p))
                      (result (if (zerop code)
                                  (car (last (split-string (or output "") "\n" t)))
                                output)))
                 (when (buffer-live-p buf) (kill-buffer buf))
                 (if killed
                     (funcall callback nil
                              (format "timed out after %.1fs (discarded tab?)"
                                      navegosa-media-timeout))
                   (condition-case e
                       (funcall callback
                                (navegosa--parse-result (or result "") code)
                                nil)
                     (error (funcall callback nil (error-message-string e)))))))))))
    (setq timer (run-at-time navegosa-media-timeout nil
                             (lambda ()
                               (when (process-live-p proc)
                                 (kill-process proc)))))
    (process-send-string proc (navegosa--build-script fn args))
    (process-send-eof proc)
    proc))

(defun navegosa-media--call-sync (fn &rest args)
  "Call Navegosa.FN with ARGS via JXA, blocking; return the result.
Same deadline guard as `navegosa-media--call-async'; signals
`user-error' on failure or timeout."
  (let ((done nil) (result nil) (err nil))
    (navegosa-media--call-async
     fn args
     (lambda (r e) (setq done t result r err e)))
    (let ((deadline (+ (float-time) navegosa-media-timeout 1.0)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (cond
     (err (user-error "navegosa-media: %s" err))
     ((not done) (user-error "navegosa-media: no response from JXA"))
     (t result))))

;;;; Target choice

(defun navegosa-media--url-pattern ()
  "Join `navegosa-media-url-patterns' into one JS regex string."
  (mapconcat #'identity navegosa-media-url-patterns "|"))

(defun navegosa-media--skip-ids ()
  "Comma-joined ids of tabs that missed the playing check in the last minute."
  (setq navegosa-media--skip
        (seq-filter (lambda (entry) (< (- (float-time) (cdr entry)) 60))
                    navegosa-media--skip))
  (mapconcat #'car navegosa-media--skip ","))

(defun navegosa-media--run (cmd arg callback &optional retried)
  "Run media CMD with ARG in one `mediaRun' call; CALLBACK gets (RESULT ERR).
The script names each tab before checking it.  A tab silent past
`navegosa-media-check-timeout' is skipped for a minute, and the call
runs once more without it unless RETRIED."
  (let (proc watchdog stalled)
    (setq proc
          (navegosa-media--call-async
           "mediaRun"
           (list (navegosa--browser) (navegosa-media--url-pattern)
                 navegosa-media--pick (plist-get navegosa-media--tab :id)
                 (navegosa-media--skip-ids) cmd arg)
           (lambda (result err)
             (when watchdog (cancel-timer watchdog))
             (unless stalled (funcall callback result err)))
           (lambda (line)
             (when watchdog (cancel-timer watchdog) (setq watchdog nil))
             (when (string-prefix-p "probe " line)
               (let ((id (substring line 6)))
                 (setq watchdog
                       (run-at-time
                        navegosa-media-check-timeout nil
                        (lambda ()
                          (setq stalled t)
                          (setf (alist-get id navegosa-media--skip nil nil #'equal)
                                (float-time))
                          (when (process-live-p proc) (kill-process proc))
                          (if retried
                              (funcall callback nil (format "tab %s does not answer" id))
                            (navegosa-media--run cmd arg callback t))))))))))
    proc))

(defun navegosa-media--run-sync (cmd arg)
  "Run media CMD with ARG, wait, and return the result plist.
Signals `user-error' on failure or timeout."
  (let ((done nil) (result nil) (err nil))
    (navegosa-media--run cmd arg (lambda (r e) (setq done t result r err e)))
    (let ((deadline (+ (float-time) (* 2 navegosa-media-timeout) 1.0)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (cond
     (err (user-error "navegosa-media: %s" err))
     ((not done) (user-error "navegosa-media: no response from JXA"))
     (t result))))

(defun navegosa-media--candidate-label (tab)
  "Completion label for TAB; a playing tab starts with ♫."
  (format "%s%s | %s"
          (if (plist-get tab :playing) "♫ " "")
          (plist-get tab :title) (plist-get tab :url)))

(defun navegosa-media--prompt-tab (tabs)
  "Offer TABS in the minibuffer and return the chosen one."
  (let ((alist (mapcar (lambda (tab) (cons (navegosa-media--candidate-label tab) tab))
                       tabs)))
    (cdr (assoc (completing-read "Media tab: " (mapcar #'car alist) nil t)
                alist))))

(defun navegosa-media--remember (state)
  "Make the tab STATE came from the last controlled one."
  (when-let* ((id (plist-get state :id)))
    (setq navegosa-media--tab
          (list :id id :url (plist-get state :url) :title (plist-get state :title)))))

(defun navegosa-media--settle-target ()
  "Settle the target tab now, prompting when nothing decides; return it.
The browser side takes the picked, a playing, the last, the shown or
the only tab.  The prompt runs here, in a command, because a process
sentinel cannot safely read the minibuffer."
  (let ((result (navegosa-media--run-sync "pick" nil)))
    (navegosa-media--remember
     (or (plist-get result :target)
         (navegosa-media--prompt-tab (plist-get result :tabs))))
    navegosa-media--tab))

;;;; State formatting

(defun navegosa-media--format-time (secs)
  "Format SECS as M:SS or H:MM:SS; \"live\" when nil.
A live stream's Infinity duration serializes to JSON null."
  (if (null secs)
      "live"
    (let* ((s (floor secs))
           (h (/ s 3600))
           (m (/ (% s 3600) 60))
           (sec (% s 60)))
      (if (< 0 h)
          (format "%d:%02d:%02d" h m sec)
        (format "%d:%02d" m sec)))))

(defun navegosa-media--format-state (state)
  "One-line echo string for STATE: position, rate, volume, flags, title."
  (let ((rate (plist-get state :rate))
        (volume (plist-get state :volume))
        (title (plist-get state :title))
        (warning (plist-get state :warning)))
    (string-join
     (delq nil
           (list
            (format "%s/%s"
                    (navegosa-media--format-time (plist-get state :time))
                    (navegosa-media--format-time (plist-get state :duration)))
            (when (and rate (/= rate 1)) (format "%.3gx" rate))
            (when volume (format "vol:%d%%" (round (* 100 volume))))
            (when (plist-get state :muted) "[muted]")
            (when (plist-get state :paused) "[paused]")
            (when warning (format "(%s)" warning))
            (when title
              (truncate-string-to-width
               (replace-regexp-in-string " - YouTube\\'" "" title)
               50 nil nil "..."))))
     " ")))

(defun navegosa-media--echo (state)
  "Echo STATE in the echo area."
  (message "%s" (navegosa-media--format-state state)))

;;;; Command dispatch

(defun navegosa-media--dispatch (cmd arg &optional handler)
  "Send media CMD with ARG to the target tab; HANDLER gets the state.
HANDLER defaults to `navegosa-media--echo'.  The target is the picked
tab, else a playing one, else the last one controlled; before the
first command it is settled here.  On Linux the command goes to the
MPRIS lane instead, synchronously (in-process D-Bus)."
  (let ((handler (or handler #'navegosa-media--echo)))
    (if (navegosa-media--use-mpris-p)
        (navegosa-mpris-dispatch cmd arg handler)
      (unless (or navegosa-media--pick navegosa-media--tab)
        (navegosa-media--settle-target))
      (navegosa-media--run
       cmd arg
       (lambda (result err)
         (cond
          (err (message "navegosa-media: %s" err))
          ((plist-get result :tabs)
           ;; the last tab is gone and nothing else decides
           (setq navegosa-media--tab nil)
           (message "navegosa-media: no tab plays and the last one is gone; run it again to pick one"))
          (t (navegosa-media--remember result)
             (funcall handler result))))))))

;;;; Commands

;;;###autoload
(defun navegosa-media-select-tab ()
  "Pick the media tab to control and show it in its browser window.
Playing tabs are marked with ♫.  The pick wins over playing tabs
until `navegosa-media-clear-pick'.  The browser app is not activated,
so Emacs keeps keyboard focus.  On the MPRIS lane this picks a player."
  (interactive)
  (if (navegosa-media--use-mpris-p)
      (navegosa-mpris-select-player)
    (let ((tab (navegosa-media--prompt-tab
                (plist-get (navegosa-media--run-sync "list" nil) :tabs))))
      (setq navegosa-media--pick (plist-get tab :id))
      (navegosa-media--remember tab)
      (navegosa--run "showTabById" (navegosa--browser) (plist-get tab :id))
      (message "navegosa-media: controlling %s" (plist-get tab :title)))))

(defun navegosa-media-clear-pick ()
  "Forget the tab picked with `navegosa-media-select-tab'.
Commands go to a playing tab again."
  (setq navegosa-media--pick nil))

;;;###autoload
(defun navegosa-media-status ()
  "Echo playback state of the controlled media tab."
  (interactive)
  (navegosa-media--dispatch "status" nil))

;;;###autoload
(defun navegosa-media-play-pause ()
  "Toggle play/pause in the target tab; other playing tabs pause first.
So it either silences every tab or plays the target alone."
  (interactive)
  (navegosa-media--dispatch "playPause" nil))

;;;###autoload
(defun navegosa-media-pause (&optional handler)
  "Pause the target tab.
HANDLER, when given, receives the paused tab's state plist with
:url, :time and :rate, so playback can continue elsewhere."
  (interactive)
  (navegosa-media--dispatch "pause" nil handler))

;;;###autoload
(defun navegosa-media-seek-forward (&optional arg)
  "Seek forward `navegosa-media-seek-step' seconds, ARG times."
  (interactive "p")
  (navegosa-media--dispatch "seekBy" (* (or arg 1) navegosa-media-seek-step)))

;;;###autoload
(defun navegosa-media-seek-backward (&optional arg)
  "Seek backward `navegosa-media-seek-step' seconds, ARG times."
  (interactive "p")
  (navegosa-media--dispatch "seekBy" (* (or arg 1) (- navegosa-media-seek-step))))

;;;###autoload
(defun navegosa-media-seek-to (seconds)
  "Seek to absolute position SECONDS."
  (interactive "nSeek to (seconds): ")
  (navegosa-media--dispatch "seekTo" seconds))

;;;###autoload
(defun navegosa-media-speed-up ()
  "Increase playback rate by `navegosa-media-speed-step'."
  (interactive)
  (navegosa-media--dispatch "rateMul" navegosa-media-speed-step))

;;;###autoload
(defun navegosa-media-speed-down ()
  "Decrease playback rate by `navegosa-media-speed-step'."
  (interactive)
  (navegosa-media--dispatch "rateMul" (/ 1.0 navegosa-media-speed-step)))

;;;###autoload
(defun navegosa-media-speed-reset ()
  "Reset playback rate to 1x."
  (interactive)
  (navegosa-media--dispatch "rateSet" 1))

;;;###autoload
(defun navegosa-media-volume-up ()
  "Raise volume by `navegosa-media-volume-step'; unmutes."
  (interactive)
  (navegosa-media--dispatch "volumeBy" navegosa-media-volume-step))

;;;###autoload
(defun navegosa-media-volume-down ()
  "Lower volume by `navegosa-media-volume-step'."
  (interactive)
  (navegosa-media--dispatch "volumeBy" (- navegosa-media-volume-step)))

;;;###autoload
(defun navegosa-media-mute-toggle ()
  "Toggle mute in the controlled media tab."
  (interactive)
  (navegosa-media--dispatch "muteToggle" nil))

;;;###autoload
(defun navegosa-media-subs-toggle ()
  "Toggle subtitles.
Clicks YouTube's captions button when present, otherwise cycles the
video element's text tracks."
  (interactive)
  (navegosa-media--dispatch "subsToggle" nil))

;;;###autoload
(defun navegosa-media-next ()
  "Play next video (YouTube playlist/autoplay next button)."
  (interactive)
  (navegosa-media--dispatch "next" nil))

;;;###autoload
(defun navegosa-media-prev ()
  "Play previous video (YouTube previous button)."
  (interactive)
  (navegosa-media--dispatch "prev" nil))

;;;###autoload
(defun navegosa-media-theater-toggle ()
  "Toggle YouTube theater (cinema) mode.
The layout change applies when the tab is visible; on a hidden tab
the click registers and takes effect once the tab is shown."
  (interactive)
  (navegosa-media--dispatch "theaterToggle" nil))

;;;###autoload
(defun navegosa-media-fullscreen-toggle ()
  "Toggle the player's own fullscreen in the controlled media tab.
The Fullscreen API demands a user gesture that JS from Apple
Events never carries; a key posted to the browser process supplies
one without activating the browser, which needs Accessibility
permission for osascript.  Entering fullscreen activates the
browser anyway, twice, so a `navegosa--reclaim-focus' watcher runs
alongside and hands keyboard focus back to Emacs each time."
  (interactive)
  (when (navegosa-media--use-mpris-p)
    (user-error
     "navegosa-mpris: fullscreen unsupported on this backend (MPRIS has no window surface)"))
  (let ((tab (navegosa-media--settle-target)))
    (navegosa--reclaim-focus)
    (navegosa-media--call-async
     "mediaFullscreenToggle"
     (list (navegosa--browser) (plist-get tab :id))
     (lambda (state err)
       (if err
           (message "navegosa-media: %s" err)
         (message "Fullscreen: %s"
                  (if (plist-get state :fullscreen) "on" "off")))))))

(defun navegosa-media--timestamped-url (url secs)
  "Return URL with a t=SECS timestamp.
YouTube URLs get a t= query parameter (replacing any existing one);
anything else gets a #t= media fragment.  Existing fragments are
dropped."
  (let ((base (car (split-string url "#")))
        (ts (floor secs)))
    (if (string-match-p "youtube\\.com/watch\\|youtu\\.be/" base)
        (let* ((clean (replace-regexp-in-string "&t=[0-9]+s?" "" base))
               (clean (replace-regexp-in-string "\\?t=[0-9]+s?&" "?" clean))
               (clean (replace-regexp-in-string "\\?t=[0-9]+s?\\'" "" clean)))
          (format "%s%st=%ds" clean (if (string-search "?" clean) "&" "?") ts))
      (format "%s#t=%ds" base ts))))

;;;###autoload
(defun navegosa-media-copy-url ()
  "Copy the media tab URL with a timestamp at the current position."
  (interactive)
  (navegosa-media--dispatch
   "status" nil
   (lambda (state)
     (unless (plist-get state :url)
       (user-error
        "navegosa-media: player exposes no URL (Chromium MPRIS omits xesam:url)"))
     (let ((url (navegosa-media--timestamped-url
                 (plist-get state :url)
                 (or (plist-get state :time) 0))))
       (kill-new url)
       (message "Copied: %s" url)))))

;;;###autoload
(defun navegosa-media-open-tab ()
  "Show the controlled media tab in its browser window.
The browser app is not activated, so Emacs keeps keyboard focus;
the tab becomes visible wherever its window is on screen, which is
what a never-shown YouTube tab needs before it loads media."
  (interactive)
  (unless navegosa-media--tab
    (user-error "navegosa-media: no media tab controlled yet"))
  (navegosa--run "showTabById" (navegosa--browser)
                 (plist-get navegosa-media--tab :id)))

;;;###autoload
(defun navegosa-media-open-url (url)
  "Open URL as the browser window's front tab and control it.
Playing tabs pause first, so the new video does not play over them.
The tab is switched in-window without activating the browser app,
so Emacs keeps focus; media starts once the browser window is
visible on screen (the player defers loading in hidden tabs).

On the MPRIS lane the URL goes through `browse-url' - MPRIS cannot
open tabs - and the player cache resets so the next command
attaches to the newly playing media."
  (interactive "sMedia URL: ")
  (if (navegosa-media--use-mpris-p)
      (progn
        (browse-url url)
        (setq navegosa-mpris--service nil)
        (message "navegosa-media: opened in browser; control attaches once it plays"))
    (navegosa-media--run "pauseAll" nil #'ignore)
    (let ((tab (navegosa-media--call-sync "openMediaTab"
                                          (navegosa--browser) url)))
      (setq navegosa-media--pick (plist-get tab :id))
      (navegosa-media--remember tab)
      (message "navegosa-media: opened %s" (plist-get tab :url))
      tab)))

(defun navegosa-media--play-at (time rate tries)
  "Play the picked tab from TIME seconds at RATE.
A tab that is still loading has no video yet, so a failed try runs
again half a second later, TRIES times in all."
  (navegosa-media--run
   "playAt" (vector time rate)
   (lambda (result err)
     (cond
      ((and err (< 1 tries))
       (run-at-time 0.5 nil #'navegosa-media--play-at time rate (1- tries)))
      (err (message "navegosa-media: %s" err))
      (t (navegosa-media--remember result)
         (navegosa-media--echo result))))))

;;;###autoload
(defun navegosa-media-play-url-at (url time &optional rate)
  "Play URL in the browser from TIME seconds at RATE.
A media tab showing the same video plays it, else URL opens in a new
tab; other playing tabs pause.  On the MPRIS lane URL opens through
`browse-url' at TIME, and RATE is not applied."
  (if (navegosa-media--use-mpris-p)
      (navegosa-media-open-url (navegosa-media--timestamped-url url time))
    (if-let* ((tab (navegosa-media--call-sync "findMediaTab" (navegosa--browser)
                                              (navegosa-media--url-pattern) url)))
        (progn
          (setq navegosa-media--pick (plist-get tab :id))
          (navegosa-media--remember tab)
          (navegosa--run "showTabById" (navegosa--browser) (plist-get tab :id)))
      (navegosa-media-open-url (navegosa-media--timestamped-url url time)))
    (navegosa-media--play-at time (or rate 1) 20)))

(provide 'navegosa-media)
;;; navegosa-media.el ends here
