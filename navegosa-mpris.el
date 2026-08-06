;;; navegosa-mpris.el --- Control browser media over MPRIS -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Linux transport for the navegosa-media commands: browsers expose
;; playing media on the D-Bus session bus as org.mpris.MediaPlayer2.*
;; players, and built-in dbus.el talks to them in-process (~1ms per
;; call, no subprocess).
;;
;; Browser MPRIS implementations are narrow; what the protocol lacks
;; is picked up by two side lanes, and the rest degrades honestly:
;; - The bus name lingers in Stopped state long after media ends, so
;;   discovery filters players by playback status, never by name.
;; - Relative Seek is routed to the page's own MediaSession seek
;;   handlers (YouTube quantizes to ~5s), so all seeking goes through
;;   SetPosition, which is exact.
;; - Volume writes are ignored, and muting the tab deregisters the
;;   player, so volume and mute ride the audio server instead: pactl
;;   on the browser's sink-inputs, matched via the bus name.
;;   Server-side mute leaves the media session fully registered.
;; - Rate writes are ignored, and subtitles/theater have no MPRIS
;;   surface at all; those commands send the page's own keyboard
;;   shortcut (< > for speed, c, t) to the browser window through
;;   the compositor (navegosa-keysend.el).  Speed reset alone stays
;;   impossible: the page has no reset key.
;; - Chromium-family metadata carries no xesam:url.

;;; Code:

(require 'dbus)
(require 'seq)
(require 'navegosa-keysend)

;;;; Customization

(defgroup navegosa-mpris nil
  "Control browser media playback over MPRIS."
  :group 'navegosa
  :prefix "navegosa-mpris-")

(defcustom navegosa-mpris-player-priority
  '("brave" "chrome" "chromium" "vivaldi" "opera" "edge"
    "firefox" "librewolf" "zen")
  "Regexps ranking MPRIS players; the earliest match wins.
Browser players lead because controlling browser playback is the
point, but any MPRIS player (mpv-mpris, VLC, Spotify) works -
names matching nothing here sort last."
  :type '(repeat string))

;;;; State

(defvar navegosa-mpris--service nil
  "Cached bus name of the controlled player.")

;;;; D-Bus plumbing

(defconst navegosa-mpris--path "/org/mpris/MediaPlayer2")
(defconst navegosa-mpris--player-interface "org.mpris.MediaPlayer2.Player")
(defconst navegosa-mpris--root-interface "org.mpris.MediaPlayer2")

(defun navegosa-mpris--prop (service prop)
  "Read PROP from SERVICE's Player interface."
  (dbus-get-property :session service navegosa-mpris--path
                     navegosa-mpris--player-interface prop))

(defun navegosa-mpris--call (service method &rest args)
  "Invoke METHOD with ARGS on SERVICE's Player interface."
  (apply #'dbus-call-method :session service navegosa-mpris--path
         navegosa-mpris--player-interface method args))

(defun navegosa-mpris--metadata-get (metadata key)
  "Extract KEY's unwrapped value from an MPRIS METADATA alist."
  (caar (alist-get key metadata nil nil #'equal)))

;;;; Player discovery

(defun navegosa-mpris--active-p (service)
  "Non-nil when SERVICE currently has controllable media.
A browser's bus name lingers in Stopped state with empty metadata
after media ends; only Playing or Paused players are usable."
  (member (dbus-ignore-errors (navegosa-mpris--prop service "PlaybackStatus"))
          '("Playing" "Paused")))

(defun navegosa-mpris--rank (service)
  "Priority rank of SERVICE per `navegosa-mpris-player-priority'."
  (or (seq-position navegosa-mpris-player-priority service
                    (lambda (re name) (string-match-p re name)))
      (length navegosa-mpris-player-priority)))

(defun navegosa-mpris--services ()
  "Return active MPRIS bus names, best candidate first.
Sorted by `navegosa-mpris-player-priority', Playing before Paused
within the same rank."
  (let ((names (seq-filter
                (lambda (name)
                  (and (string-prefix-p "org.mpris.MediaPlayer2." name)
                       (navegosa-mpris--active-p name)))
                (dbus-list-names :session))))
    (seq-sort-by
     (lambda (name)
       (+ (* 2 (navegosa-mpris--rank name))
          (if (equal (dbus-ignore-errors
                       (navegosa-mpris--prop name "PlaybackStatus"))
                     "Playing")
              0 1)))
     #'< names)))

(defun navegosa-mpris--label (service)
  "Completion label for SERVICE: identity and current title."
  (let* ((identity (or (dbus-ignore-errors
                         (dbus-get-property
                          :session service navegosa-mpris--path
                          navegosa-mpris--root-interface "Identity"))
                       service))
         (title (navegosa-mpris--metadata-get
                 (dbus-ignore-errors (navegosa-mpris--prop service "Metadata"))
                 "xesam:title")))
    (if title (format "%s | %s" identity title) identity)))

(defun navegosa-mpris--locate (&optional mode)
  "Locate an active MPRIS player, cache and return its bus name.
MODE mirrors `navegosa-media--locate': nil prompts only among
several candidates, `auto' takes the best without prompting,
`prompt' always prompts.  Signals `user-error' when no player has
controllable media."
  (let ((cands (navegosa-mpris--services)))
    (setq navegosa-mpris--service
          (cond
           ((null cands)
            (user-error "navegosa-mpris: no active MPRIS players"))
           ((or (eq mode 'auto)
                (and (null (cdr cands)) (not (eq mode 'prompt))))
            (car cands))
           (t
            (let* ((alist (mapcar (lambda (s) (cons (navegosa-mpris--label s) s))
                                  cands))
                   (choice (completing-read "MPRIS player: " (mapcar #'car alist)
                                            nil t)))
              (cdr (assoc choice alist))))))))

(defun navegosa-mpris--ensure-service ()
  "Return the cached player, re-locating when it is gone or stopped."
  (if (and navegosa-mpris--service
           (navegosa-mpris--active-p navegosa-mpris--service))
      navegosa-mpris--service
    (navegosa-mpris--locate 'auto)))

;;;; State

(defun navegosa-mpris--state (service)
  "Playback state plist of SERVICE, shaped like the JXA lane's.
No :volume or :muted - browser MPRIS reports a static 1.0
regardless of the real level, so showing it would be a lie."
  (let* ((md (navegosa-mpris--prop service "Metadata"))
         (length-us (or (navegosa-mpris--metadata-get md "mpris:length") 0))
         (position-us (or (navegosa-mpris--prop service "Position") 0))
         (rate (or (navegosa-mpris--prop service "Rate") 1.0)))
    (list :time (/ position-us 1e6)
          :duration (when (< 0 length-us) (/ length-us 1e6))
          ;; Chromium reports Rate 0 while paused; zero is never a real
          ;; playback rate, and echoing "0x" would be noise
          :rate (if (zerop rate) 1.0 rate)
          :paused (equal (navegosa-mpris--prop service "PlaybackStatus")
                         "Paused")
          :title (navegosa-mpris--metadata-get md "xesam:title")
          :url (navegosa-mpris--metadata-get md "xesam:url"))))

;;;; Stream volume (audio server lane)

(defun navegosa-mpris--app-token (service)
  "Browser token from SERVICE's bus name (org.mpris.MediaPlayer2.APP...)."
  (nth 3 (split-string service "\\.")))

(defun navegosa-mpris--pactl (&rest args)
  "Run pactl with ARGS; return stdout, signaling on failure."
  (unless (executable-find "pactl")
    (user-error
     "navegosa-mpris: pactl not found - stream volume needs PipeWire/PulseAudio"))
  (with-temp-buffer
    (let ((code (apply #'call-process "pactl" nil t nil args)))
      (unless (eq code 0)
        (user-error "navegosa-mpris: pactl %s failed: %s"
                    (string-join args " ") (string-trim (buffer-string)))))
    (buffer-string)))

(defun navegosa-mpris--streams (service)
  "SERVICE's browser sink-inputs, matched by the bus-name app token.
The stream exists only while audio flows - a paused tab has none -
and Chromium's media.name is a generic \"Playback\", so matching is
by application: browser-wide volume, which is what the stream lane
can honestly offer."
  (let* ((token (navegosa-mpris--app-token service))
         (streams
          (seq-filter
           (lambda (si)
             (let ((props (alist-get 'properties si))
                   (case-fold-search t))
               (seq-some (lambda (name)
                           (and name token (string-match-p token name)))
                         (list (alist-get 'application.name props)
                               (alist-get 'application.process.binary props)))))
           (json-parse-string (navegosa-mpris--pactl "-f" "json" "list" "sink-inputs")
                              :object-type 'alist :array-type 'list))))
    (or streams
        (user-error
         "navegosa-mpris: no audio stream for %s (media paused or silent?)"
         (or token service)))))

(defun navegosa-mpris--stream-volume (si)
  "Sink-input SI's volume as 0.0-1.0."
  (/ (string-to-number
      (or (alist-get 'value_percent
                     (alist-get 'front-left (alist-get 'volume si)))
          "100%"))
     100.0))

(defun navegosa-mpris--stream-volume-by (service delta)
  "Change SERVICE's browser stream volume by DELTA on the 0-1 scale.
Applies to every matching stream (they cannot be told apart), the
target computed from the first and clamped to 0-100%: audio-server
gain above 100% only distorts.  Returns the new volume, 0.0-1.0."
  (let* ((streams (navegosa-mpris--streams service))
         (target (max 0.0 (min 1.0 (+ (navegosa-mpris--stream-volume
                                       (car streams))
                                      delta)))))
    (dolist (si streams)
      (navegosa-mpris--pactl "set-sink-input-volume"
                             (number-to-string (alist-get 'index si))
                             (format "%d%%" (round (* 100 target)))))
    target))

(defun navegosa-mpris--stream-mute-toggle (service)
  "Toggle SERVICE's browser streams at the audio server; return new state.
Tab-level mute would deregister the player from the bus; muting the
sink-input is invisible to the browser, so the media session stays
controllable.  All matching streams are set, not toggled, so they
converge."
  (let* ((streams (navegosa-mpris--streams service))
         (muted (not (eq (alist-get 'mute (car streams)) t))))
    (dolist (si streams)
      (navegosa-mpris--pactl "set-sink-input-mute"
                             (number-to-string (alist-get 'index si))
                             (if muted "1" "0")))
    muted))

;;;; Page shortcuts (compositor lane)

(defun navegosa-mpris--keysend (service action handler)
  "Send ACTION's page shortcut to SERVICE's browser window.
The effect is not observable over MPRIS, so HANDLER gets the state
with a note of what was sent instead of a verified outcome."
  (let ((key (alist-get action navegosa-keysend-keys)))
    (unless (and navegosa-keysend-function key)
      (navegosa-mpris--unsupported
       (symbol-name action)
       "MPRIS has no such surface and the keysend fallback is off"))
    (let* ((state (navegosa-mpris--state service))
           (title (plist-get state :title)))
      (unless title
        (user-error
         "navegosa-mpris: player exposes no title to find its window"))
      (funcall navegosa-keysend-function key title
               (navegosa-mpris--app-token service))
      (funcall handler
               (plist-put state :warning
                          (format "sent %s for %s" key action))))))

;;;; Commands

(defun navegosa-mpris--set-position (service seconds)
  "Seek SERVICE to SECONDS via SetPosition, clamped to the track.
Relative Seek is off the table: pages intercept it through their
MediaSession seek handlers with their own step.  Returns the
clamped target in seconds."
  (let* ((md (navegosa-mpris--prop service "Metadata"))
         (trackid (navegosa-mpris--metadata-get md "mpris:trackid"))
         (length-us (or (navegosa-mpris--metadata-get md "mpris:length") 0))
         (target-us (max 0 (if (< 0 length-us)
                               (min (floor (* seconds 1e6)) length-us)
                             (floor (* seconds 1e6))))))
    (unless trackid
      (user-error "navegosa-mpris: player exposes no track id to seek"))
    (navegosa-mpris--call service "SetPosition"
                          :object-path trackid :int64 target-us)
    (/ target-us 1e6)))

(defun navegosa-mpris--unsupported (what why)
  "Signal that WHAT cannot work over MPRIS, explaining WHY."
  (user-error "navegosa-mpris: %s unsupported on this backend (%s)" what why))

(defun navegosa-mpris-dispatch (cmd arg handler &optional no-retry)
  "Run media CMD with ARG against the cached player; HANDLER gets state.
CMD vocabulary is the JXA lane's.  Volume and mute ride the audio
server, subtitles and theater the compositor keysend lane; what no
lane can honor signals an honest `user-error' instead of silently
doing nothing.  On a D-Bus error the cache is invalidated and the
command retried once against a freshly located player, unless
NO-RETRY is non-nil.

The echoed state predicts the outcome where the browser applies
commands asynchronously: a seek reports the target position, a
pause/resume the flipped status."
  (let ((service (navegosa-mpris--ensure-service)))
    (condition-case err
        (pcase cmd
          ("status"
           (funcall handler (navegosa-mpris--state service)))
          ("playPause"
           (let ((was-paused (equal (navegosa-mpris--prop service "PlaybackStatus")
                                    "Paused")))
             (navegosa-mpris--call service "PlayPause")
             (funcall handler (plist-put (navegosa-mpris--state service)
                                         :paused (not was-paused)))))
          ("seekBy"
           (let* ((state (navegosa-mpris--state service))
                  (target (navegosa-mpris--set-position
                           service (+ (plist-get state :time) arg))))
             (funcall handler (plist-put state :time target))))
          ("seekTo"
           (let ((target (navegosa-mpris--set-position service arg)))
             (funcall handler (plist-put (navegosa-mpris--state service)
                                         :time target))))
          ("next"
           (unless (navegosa-mpris--prop service "CanGoNext")
             (navegosa-mpris--unsupported
              "next" "the player offers none here; YouTube only in playlists"))
           (navegosa-mpris--call service "Next")
           (funcall handler (navegosa-mpris--state service)))
          ("prev"
           (unless (navegosa-mpris--prop service "CanGoPrevious")
             (navegosa-mpris--unsupported
              "prev" "the player offers none here; YouTube only in playlists"))
           (navegosa-mpris--call service "Previous")
           (funcall handler (navegosa-mpris--state service)))
          ("rateMul"
           ;; MPRIS Rate writes are ignored, but the page steps its own
           ;; speed on < and >: route by direction, YT-quantized (0.25)
           (navegosa-mpris--keysend
            service (if (< 1 arg) 'speed-up 'speed-down) handler))
          ("rateSet"
           (navegosa-mpris--unsupported
            "speed reset" "browsers ignore Rate writes and the page has no reset key"))
          ("volumeBy"
           (let ((volume (navegosa-mpris--stream-volume-by service arg)))
             (funcall handler (plist-put (navegosa-mpris--state service)
                                         :volume volume))))
          ("muteToggle"
           (let ((muted (navegosa-mpris--stream-mute-toggle service)))
             (funcall handler (plist-put (navegosa-mpris--state service)
                                         :muted muted))))
          ("subsToggle" (navegosa-mpris--keysend service 'subs handler))
          ("theaterToggle" (navegosa-mpris--keysend service 'theater handler))
          (_ (error "navegosa-mpris: unknown command %s" cmd)))
      (dbus-error
       (if no-retry
           (user-error "navegosa-mpris: %s" (error-message-string err))
         (setq navegosa-mpris--service nil)
         (navegosa-mpris-dispatch cmd arg handler 'no-retry))))))

(defun navegosa-mpris-select-player ()
  "Pick the MPRIS player to control.
Always prompts, a single candidate showing as the one choice.
MPRIS cannot raise the player's window, so this only re-points
control."
  (let ((service (navegosa-mpris--locate 'prompt)))
    (message "navegosa-mpris: controlling %s" (navegosa-mpris--label service))
    service))

(provide 'navegosa-mpris)
;;; navegosa-mpris.el ends here
