;;; ycm.el --- Emacs client for the YouCompleteMe auto-completion server.

;; Copyright (C) 2014  Ajay Gopinathan

;; Author: Ajay Gopinathan <ajay@gopinathan.net>
;; Keywords: c, abbrev

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This library provides a client for the YouCompleteMe
;; (https://github.com/Valloric/YouCompleteMe) code-completion engine.

;;; Code:

(require 'cl-lib)
(require 'request)
(require 'json)

;; (setq request-log-level `debug)
;; (setq request-message-level `debug)

(defgroup ycm nil
  "YouCompleteMe emacs client."
  :group 'abbrev
  :group 'convenience)

(defcustom ycm-server-directory nil
  "The location of the YCMD server files."
  :group 'ycm
  :type 'directory
  :tag "YCM server directory")

(defcustom ycm-options-file nil
  "The options file to use when starting the YCMD server."
  :group 'ycm
  :type '(file :must-match t)
  :tag "YCM options file")

(defcustom ycm-extra-conf-file nil
  "ycm_extra_conf.py file to load for semantic completion.

This can be nil, in which case it's best to specify a global
extra conf file in YCM-OPTIONS-FILE. "
  :group 'ycm
  :type '(file :must-match t)
  :tag "YCM options file")

(defcustom ycm-modes '(c-mode c++-mode python-mode js-mode js2-mode)
  "Major modes in which YCM may complete."
  :group 'ycm
  :type 'symbol
  :tag "YCM modes")

;; Private variables and functions.

(defconst ycm--server-host "http://127.0.0.1"
  "YCMD server address.")

(defvar ycm--server-port nil
  "YCMD server port.")

(defvar ycm--secret nil
  "HMAC authentication secret currently in use.")

(defvar ycm--signal-file-ready-to-parse-timer nil
  "The timer used to ask ycm to parse a file every 2 seconds when
emacs is idle.")

(cl-defun ycm--start-server (&key options-file)
  "Starts the YCM server if it's not already running."
  (unless (process-status "ycmd")
    (let ((command `("ycmd"
                     "*ycmd-output*"
                     "python"
                     ,ycm-server-directory
                     ,(concat "--options_file=" options-file))))

      (apply #'start-process command))

    ;; No need to query when killing the process.
    (set-process-query-on-exit-flag (get-process "ycmd") nil)))

(defun ycm--stop-server ()
  "Stops the server if it's running."
  (when (process-status "ycmd")
    (quit-process "ycmd")))

(defun ycm--server-address ()
  "Computes the server address."
  (unless ycm--server-port
    (unless (process-status "ycmd")
      (error "ERROR getting ycmd port. Process not running."))
    (with-current-buffer "*ycmd-output*"
      (goto-char (point-max))
      (re-search-backward "serving on http://127[.]0[.]0[.]1:\\\([0-9]+\\\)")
      (setq ycm--server-port (match-string-no-properties 1))))
      (concat ycm--server-host ":" ycm--server-port))

(defun ycm--generate-secret ()
  "Compute a random secret key for HMAC authentication."
  (let* ((ran (number-to-string (random t))))
    (secure-hash 'sha256 ran)))


(defun ycm--generate-hmac (key text)
  "Generates a HMAC given the KEY and TEXT."
  (let* ((block-size 64)
        (opad (make-string block-size ?\x5c))
        (ipad (make-string block-size ?\x36))
        (keypad (cond
                 ((> (length key) block-size)
                  (secure-hash 'sha256 key nil nil t))

                 ((< (length key) block-size)
                  (concat key (make-string
                               (- block-size (length key))
                               ?\x00)))

                 (t key))))

    (cl-assert (eq 64 (length keypad)) t "key is %d bytes, should be 64 bytes")

    (dotimes (i block-size)
      (aset opad i (logxor (aref opad i) (aref keypad i)))
      (aset ipad i (logxor (aref ipad i) (aref keypad i))))


    (let* ((inner (concat ipad text))
           (inner-digest (secure-hash 'sha256 inner nil nil t))
           (outer (concat opad inner-digest)))
      (secure-hash 'sha256 outer nil nil nil))))

(cl-defun ycm--post (path request-data &key success-fn error-fn)
  "Send a POST request to the YCMD server.

Encodes REQUEST-DATA as JSON and posts it to PATH. If a
successful response is received, the callback SUCCESS-FN is
called if specified.  If the server responds with an error, the
callback ERROR-FN is called instead. Both callbacks must follow
the callback format as specified in request.el."
  (let* ((request-in-json (json-encode request-data))
         (hmac-header (base64-encode-string
                       (ycm--generate-hmac ycm--secret request-in-json) t)))

    (request
     (concat (file-name-as-directory (ycm--server-address)) path)
     :type "POST"
     :data request-in-json
     :headers
     `(("Content-Type" . "application/json")
       ("X-Ycm-Hmac" . ,hmac-header))

     :parser (lambda() (ignore-errors (json-read)))
     :success success-fn
     :error (lambda() nil)
    )))

(defun ycm--get-filetypes ()
  "Get a list of filetypes that apply to the current buffer."
  (cl-case major-mode
    (js-mode ["javascript"])
    (js2-mode ["javascript"])
    (python-mode ["python"])
    (c-mode ["cpp"])
    (c++-mode ["cpp"])
    (t ["unknown"])))

(defun ycm-load-extra-conf-file (filename)
  "Loads extra conf file in FILENAME for C-family semantic completions."
  (interactive "fWhich ycm_extra_conf.py? > ")
  (let ((request (list (cons 'filepath filename)))
        (path "load_extra_conf_file"))
    (ycm--post path request)))

(defun ycm--current-ycm-buffers ()
  "Returns a list of current buffers with YCM enabled major modes."
  (cl-remove-if-not (lambda (buf)
                      (with-current-buffer buf
                        (memq major-mode ycm-modes)))
                    (buffer-list)))

(defun ycm--build-file-data-for-buffer (buf)
  "Given the buffer BUF, builds the file data for it."
  (with-current-buffer buf
    (let ((bufcontents (buffer-substring-no-properties
                        (point-min)
                        (point-max)))
          (filetypes (ycm--get-filetypes))
          (buffer-name (buffer-file-name)))
      (cons buffer-name
            (list (cons "contents" bufcontents)
                  (cons "filetypes" filetypes))))))

(defun ycm--build-file-data ()
  "Builds file data for all current buffers."
  (let ((buffers (ycm--current-ycm-buffers)))
    (mapcar #'ycm--build-file-data-for-buffer buffers)))

(defun ycm--build-request-base ()
  "Builds a standard request, as a plist"
  (let ((bufcontents (buffer-substring-no-properties (point-min) (point-max))))
    (list (cons "column_num" (+ (current-column) 1))
          (cons "line_num" (line-number-at-pos))
          (cons "filepath" (buffer-file-name))
          (cons "file_data" (ycm--build-file-data)))))

(defun ycm--signal-file-ready-to-parse ()
  "Signals to YCMD the current buffer is ready to be parsed."
  (when (memq major-mode ycm-modes)
    (let* ((base-request (ycm--build-request-base))
           (request (push (cons 'event_name "FileReadyToParse") base-request))
           (path "event_notification"))
      (ycm--post path request))))

(defun ycm--generate-tmpfilename ()
  "Generate a random temporary file under tmp."
  (concat "/tmp/" (md5 (number-to-string (random t)))))

(defun ycm--init-temp-options-file (tmpfile)
  "Initialize TMPFILE with ycm options, using DEFAULT as the base."
  (let* ((json-object-type 'hash-table)
         (options (json-read-file ycm-options-file)))
    (unless ycm--secret
      (setq ycm--secret (ycm--generate-secret)))
    (remhash "hmac_secret" options)
    (puthash "hmac_secret" (base64-encode-string ycm--secret t) options)
    ;; Other options go here.
    (with-temp-file tmpfile
      (insert (json-encode options))))
  )

(defun ycm-startup ()
  "Necessary initialization stuff."
  (interactive)
  (let ((tmp-options-file (ycm--generate-tmpfilename)))
    (ycm--init-temp-options-file tmp-options-file)
    (ycm--start-server :options-file tmp-options-file))

  ;; Wait for one second, then try to load extra conf file
  ;; if one is specified.
  (when ycm-extra-conf-file
    (run-at-time 1 nil
                 (lambda ()
                   (ycm--load-extra-conf-file ycm--extra-conf-file))))

  ;; Set up timer to signal file ready to parse.
  (unless ycm--signal-file-ready-to-parse-timer
    (setq ycm--signal-file-ready-to-parse-timer
          (run-with-idle-timer
           2 t (lambda () (ycm--signal-file-ready-to-parse)))))

  ;; Clean up when emacs exits.
  (add-hook 'kill-emacs-hook (lambda () (ycm-shutdown))))

(defun ycm-shutdown ()
  "Shut down YCM."
  (interactive)
  (when ycm--signal-file-ready-to-parse-timer
    (cancel-timer ycm--signal-file-ready-to-parse-timer))
  (setq ycm--secret nil)
  (setq ycm--server-port nil)
  (ycm--stop-server))

(defun ycm--parse-insertions (completions)
  "Parses insertion candidates from COMPLETIONS.

COMPLETIONS is a vector of alists, json-decoded from the YCMD
server response."
  (mapcar
   (lambda (completion-data)
     (let ((completion (assoc-default 'insertion_text completion-data)))
       (propertize completion
                   :detailed_info (assoc-default 'detailed_info completion-data)
                   :kind (assoc-default 'kind completion-data)
                   :extra_menu_info (assoc-default 'extra_menu_info completion-data)
                   :menu_text (assoc-default 'menu_text completion-data))))
   completions))

;;;###autoload
(defun ycm-query-completions (callback)
  "Queries YCMD for completions, then calls callback with the results."
  (lexical-let* ((request (ycm--build-request-base))
                 (path "completions")
                 (insertions-callback callback)
                 (success-callback
                  (function*
                   (lambda (&key data &allow-other-keys)
                     (let* ((completions (assoc-default 'completions data))
                            (insertions (ycm--parse-insertions completions)))
                       (funcall insertions-callback insertions))))))

    (ycm--post path request :success-fn success-callback)))

(provide 'ycm)

;;; ycm.el ends here
