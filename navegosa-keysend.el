;;; navegosa-keysend.el --- Deliver page shortcuts to browser windows -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Linux companion to navegosa-media: MPRIS has no surface for
;; page-level toggles (subtitles, theater mode), but the page answers
;; its own keyboard shortcuts, so this delivers a keypress to the
;; browser window through the compositor.
;;
;; Chromium discards synthetic input while its window lacks keyboard
;; focus, so the Hyprland backend bounces focus in one batched IPC
;; (focus browser -> key -> focus back) - a millisecond excursion that
;; is imperceptible in practice.  Single taps only by design: a held
;; key would race kernel autorepeat into whichever window holds focus
;; mid-bounce.  Continuous controls (volume) belong on the audio
;; server lane instead (navegosa-mpris.el).
;;
;; Other compositors plug in through `navegosa-keysend-function'.

;;; Code:

(require 'seq)

(defgroup navegosa-keysend nil
  "Deliver page shortcuts to browser windows."
  :group 'navegosa
  :prefix "navegosa-keysend-")

(defcustom navegosa-keysend-function #'navegosa-keysend-hyprland
  "Function delivering a page-shortcut keypress to a browser window.
Called with KEY (a string like \"c\"), TITLE (the playing media's
title; the window whose title contains it is the target) and CLASS
(a case-insensitive regexp hinting the browser's window class,
derived from the MPRIS bus name; may be nil).  Must signal
`user-error' with the reason when delivery is impossible.

nil disables the key fallbacks: their commands answer with the
backend's honest unsupported error instead."
  :type '(choice (function :tag "Backend function")
                 (const :tag "Disabled" nil)))

(defcustom navegosa-keysend-keys
  '((subs . "c") (theater . "t") (speed-up . ">") (speed-down . "<"))
  "Page keyboard shortcut per action (YouTube's defaults)."
  :type '(alist :key-type symbol :value-type string))

(defconst navegosa-keysend--key-specs
  '(("<" . "SHIFT,comma") (">" . "SHIFT,period")
    ("," . ",comma") ("." . ",period") (" " . ",space"))
  "Char to sendshortcut MODS,KEYSYM specs.
Shifted characters need explicit mods: Hyprland resolves bare
keysyms only at the keymap's unshifted level (\"greater\" is not
found, SHIFT+period is).")

(defun navegosa-keysend--hyprctl-json (command)
  "Run hyprctl COMMAND -j and return the parsed JSON."
  (with-temp-buffer
    (let ((code (call-process "hyprctl" nil t nil command "-j")))
      (unless (eq code 0)
        (user-error "navegosa-keysend: hyprctl %s failed: %s"
                    command (string-trim (buffer-string)))))
    (json-parse-string (buffer-string)
                       :object-type 'alist :array-type 'list)))

(defun navegosa-keysend--match-window (clients title &optional class)
  "Pick from CLIENTS the window whose title contains TITLE.
CLASS, when given, is matched case-insensitively against the window
class - the guard against another window quoting the media title."
  (seq-find (lambda (win)
              (and (or (null class)
                       (let ((case-fold-search t))
                         (string-match-p class (or (alist-get 'class win) ""))))
                   (string-search title (or (alist-get 'title win) ""))))
            clients))

(defun navegosa-keysend-hyprland (key title &optional class)
  "Deliver KEY to the browser window titled like TITLE via Hyprland.
CLASS restricts candidate windows (see `navegosa-keysend-function').
Chromium ignores compositor-synthesized keys while unfocused, so
when the target is not the active window the key rides a batched
focus bounce (focus target -> sendshortcut -> restore focus); the
whole batch executes inside one compositor IPC."
  (unless (executable-find "hyprctl")
    (user-error
     "navegosa-keysend: hyprctl not found - set `navegosa-keysend-function' for your compositor"))
  (let* ((win (navegosa-keysend--match-window
               (navegosa-keysend--hyprctl-json "clients") title class))
         (target (alist-get 'address win))
         (active (alist-get 'address
                            (navegosa-keysend--hyprctl-json "activewindow")))
         (keyspec (or (cdr (assoc key navegosa-keysend--key-specs))
                      (concat "," key))))
    (unless win
      (user-error
       "navegosa-keysend: no browser window titled like %S - is the video's tab frontmost in its window?"
       title))
    (with-temp-buffer
      (let* ((send (format "dispatch sendshortcut %s,address:%s" keyspec target))
             (args (cond
                    ((equal active target)
                     (list "dispatch" "sendshortcut"
                           (format "%s,address:%s" keyspec target)))
                    (active
                     (list "--batch"
                           (format "dispatch focuswindow address:%s ; %s ; dispatch focuswindow address:%s"
                                   target send active)))
                    (t
                     (list "--batch"
                           (format "dispatch focuswindow address:%s ; %s"
                                   target send)))))
             (code (apply #'call-process "hyprctl" nil t nil args)))
        (unless (eq code 0)
          (user-error "navegosa-keysend: hyprctl dispatch failed: %s"
                      (string-trim (buffer-string))))))
    t))

(provide 'navegosa-keysend)
;;; navegosa-keysend.el ends here
