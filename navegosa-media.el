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
;; Apple-Events JS runs in an isolated world where the page's own JS
;; (e.g. YouTube's player API) is unreachable, so everything goes
;; through the DOM: the <video> element plus player buttons.
;;
;; Tabs are discovered by URL prefilter only and every JXA call is
;; deadline-guarded, because executing JS into a discarded (Memory
;; Saver) tab hangs osascript indefinitely.

;;; Code:

(require 'navegosa)

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

;;;; State

(defvar navegosa-media--tab nil
  "Cached media tab plist (:windowIndex :tabIndex :url :title).")

;;;; Guarded runner

(defun navegosa-media--call-async (fn args callback)
  "Call Navegosa.FN with ARGS list via JXA; CALLBACK receives (RESULT ERR).
The osascript process is killed after `navegosa-media-timeout'
seconds, in which case ERR describes the timeout.  Returns the
process object."
  (navegosa--ensure-macos)
  (let* ((buf (generate-new-buffer " *navegosa-media*" t))
         (timer nil)
         (proc
          (make-process
           :name "navegosa-media"
           :buffer buf
           :command '("osascript" "-l" "JavaScript")
           :connection-type 'pipe
           :noquery t
           :sentinel
           (lambda (p _event)
             (unless (process-live-p p)
               (when timer (cancel-timer timer))
               (let ((output (when (buffer-live-p buf)
                               (with-current-buffer buf
                                 (string-trim (buffer-string)))))
                     (killed (eq (process-status p) 'signal))
                     (code (process-exit-status p)))
                 (when (buffer-live-p buf) (kill-buffer buf))
                 (if killed
                     (funcall callback nil
                              (format "timed out after %.1fs (discarded tab?)"
                                      navegosa-media-timeout))
                   (condition-case e
                       (funcall callback
                                (navegosa--parse-result (or output "") code)
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

;;;; Tab discovery

(defun navegosa-media--url-pattern ()
  "Join `navegosa-media-url-patterns' into one JS regex string."
  (mapconcat #'identity navegosa-media-url-patterns "|"))

(defun navegosa-media--candidates ()
  "Return media-tab candidates, URL-prefiltered, never JS-probed."
  (navegosa--run "getMediaTabs" (navegosa--browser)
                 (navegosa-media--url-pattern)))

(defun navegosa-media--candidate-label (tab)
  "Completion label for TAB."
  (format "%s | %s" (plist-get tab :title) (plist-get tab :url)))

(defun navegosa-media--locate (&optional mode)
  "Locate a media tab, cache and return it.
MODE nil prompts via `completing-read' only when there are several
candidates; `auto' never prompts and takes the first (the retry
path runs from a process sentinel, where prompting would be
hostile); `prompt' always prompts, a single candidate shows as the
one choice.  Signals `user-error' when nothing matches
`navegosa-media-url-patterns'."
  (let ((cands (navegosa-media--candidates)))
    (setq navegosa-media--tab
          (cond
           ((null cands)
            (user-error "navegosa-media: no media tabs open"))
           ((or (eq mode 'auto)
                (and (null (cdr cands)) (not (eq mode 'prompt))))
            (car cands))
           (t
            (let* ((alist (mapcar (lambda (tab)
                                    (cons (navegosa-media--candidate-label tab)
                                          tab))
                                  cands))
                   (choice (completing-read "Media tab: " (mapcar #'car alist)
                                            nil t)))
              (cdr (assoc choice alist))))))))

(defun navegosa-media--ensure-tab ()
  "Return the cached media tab, locating one first when needed."
  (or navegosa-media--tab (navegosa-media--locate)))

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

(defun navegosa-media--dispatch (cmd arg &optional handler no-retry)
  "Send media CMD with ARG to the cached tab, locating one when needed.
HANDLER receives the returned state plist (default:
`navegosa-media--echo').  On failure the tab cache is invalidated
and the command retried once against a freshly located tab, unless
NO-RETRY is non-nil."
  (let ((tab (navegosa-media--ensure-tab))
        (handler (or handler #'navegosa-media--echo)))
    (navegosa-media--call-async
     (if (equal cmd "status") "mediaStatus" "mediaCommand")
     (append (list (navegosa--browser)
                   (plist-get tab :windowIndex)
                   (plist-get tab :tabIndex))
             (unless (equal cmd "status") (list cmd arg)))
     (lambda (state err)
       (cond
        ((null err) (funcall handler state))
        (no-retry (message "navegosa-media: %s" err))
        (t
         (setq navegosa-media--tab nil)
         (condition-case relocate-err
             (progn
               (navegosa-media--locate 'auto)
               (navegosa-media--dispatch cmd arg handler 'no-retry))
           (error (message "%s" (error-message-string relocate-err))))))))))

;;;; Commands

;;;###autoload
(defun navegosa-media-select-tab ()
  "Pick the media tab to control and bring it up in the browser.
Always prompts, a single candidate showing as the one choice."
  (interactive)
  (let ((tab (navegosa-media--locate 'prompt)))
    (navegosa--run "activateTab" (navegosa--browser)
                   (plist-get tab :windowIndex)
                   (plist-get tab :tabIndex))
    (message "navegosa-media: controlling %s" (plist-get tab :title))))

;;;###autoload
(defun navegosa-media-status ()
  "Echo playback state of the controlled media tab."
  (interactive)
  (navegosa-media--dispatch "status" nil))

;;;###autoload
(defun navegosa-media-play-pause ()
  "Toggle play/pause in the controlled media tab."
  (interactive)
  (navegosa-media--dispatch "playPause" nil))

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
  "Toggle macOS fullscreen on the window holding the media tab.
The player's own fullscreen is unreachable (synthetic clicks carry
no user activation), so this drives the window via System Events -
requires Accessibility permission for osascript."
  (interactive)
  (let ((tab (navegosa-media--ensure-tab)))
    (navegosa-media--call-async
     "windowFullscreenToggle"
     (list (navegosa--browser) (plist-get tab :windowIndex))
     (lambda (result err)
       (if err
           (message "navegosa-media: %s" err)
         (message "Fullscreen: %s"
                  (if (plist-get result :fullscreen) "on" "off")))))))

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
     (let ((url (navegosa-media--timestamped-url
                 (plist-get state :url)
                 (or (plist-get state :time) 0))))
       (kill-new url)
       (message "Copied: %s" url)))))

;;;###autoload
(defun navegosa-media-open-tab ()
  "Activate the controlled media tab in the browser."
  (interactive)
  (let ((tab (navegosa-media--ensure-tab)))
    (navegosa--run "activateTab" (navegosa--browser)
                   (plist-get tab :windowIndex)
                   (plist-get tab :tabIndex))))

;;;###autoload
(defun navegosa-media-open-url (url)
  "Open URL as the browser window's front tab and control it.
The tab is switched in-window without activating the browser app,
so Emacs keeps focus; media starts once the browser window is
visible on screen (the player defers loading in hidden tabs)."
  (interactive "sMedia URL: ")
  (let ((tab (navegosa-media--call-sync "openMediaTab"
                                        (navegosa--browser) url)))
    (setq navegosa-media--tab tab)
    (message "navegosa-media: opened %s" (plist-get tab :url))
    tab))

(provide 'navegosa-media)
;;; navegosa-media.el ends here
