;;; yankee.el --- GFM / Org-mode source block yanker   -*- lexical-binding: t; -*-

;; Copyright (C) 2019 Jake Romer

;; Author: Jake Romer <mail@jakeromer.com>
;; Package-Version: 0.2.0
;; Keywords: lisp, markdown, github-flavored markdown, org-mode
;; URL: https://github.com/jmromer/yankee.el
;; Package-Requires: ((copy-as-format "0.0.8") (emacs "27.1"))


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

;; Provides the following interactive function:
;; yankee-yank

;;; Code:

;; Interactive function
(defun yankee-yank (start end)
  "Yank the region bounded by START and END as code block.
Prompt for output format."
  (interactive "r")

  (defvar file-name)
  (defvar mode-atom)
  (defvar mode-string)
  (defvar selection-range)
  (defvar start-linenum)
  (defvar end-linenum)

  (setq file-name (yankee--abbreviated-project-or-home-path-to-file)
        mode-name (buffer-local-value 'major-mode (current-buffer)))

  (setq mode-atom (intern (yankee--mode-string mode-name))
        mode-string (yankee--mode-string mode-name))

  (setq start-linenum (line-number-at-pos start))

  ;; The line number of the end of the selection
  (setq end-linenum (line-number-at-pos (- end 1)))

  ;; Selection range, formatted for display. e.g. L5 or L5-L9
  (setq selection-range (yankee--selected-lines 'path start-linenum end-linenum))

  ;; Get line numbers and file number
  (setq current-prefix-arg '(4))
  (if (fboundp 'copy-as-format)
      (copy-as-format)
    (error "Package yankee.el requires copy-as-format")))

(defun yankee--in-project-p ()
  "Check if we're in a project."
  (condition-case nil
      (yankee--project-root)
    (error nil)))

(defun yankee--expand-file-name (file-name)
  "A thin wrapper around `expand-file-name' that handles nil.
Expand FILE-NAME using `default-directory'."
  (when file-name
    (expand-file-name file-name)))

(defun yankee--project-root ()
  "Retrieves the root directory of a project if available."
  (cond
   ((boundp 'projectile-project-root)
    (projectile-project-root))
   ((eq 'Git (vc-backend (buffer-file-name)))
    (replace-regexp-in-string
     "\n\\'" ""
     (shell-command-to-string "git rev-parse --show-toplevel")))))

;; `copy-as-format' functions
;; - Redefine copy-as-format--github to add url
(with-eval-after-load 'copy-as-format
  (defun copy-as-format--github (text multiline)
    "Create a GFM code block with TEXT as body.
MULTILINE is a boolean indicating if the selected text spans multiple lines."
    (if multiline
        (format "```%s\n%s\n```\n%s"
                (copy-as-format--language)
                text
                (if (and (boundp 'snippet-url) snippet-url)
                    (format "<sup>[[source](%s)]</sup>\n" snippet-url)
                  ""))
      (copy-as-format--inline-markdown text))))

;; - Define a template for folded github-flavored markdown
(defun yankee-copy-as-format--github-folded (text multiline)
  "Create a foldable GFM code block with TEXT as body.
MULTILINE is a boolean indicating if the selected text spans multiple lines."
  (let* ((file-path (yankee--abbreviated-project-or-home-path-to-file))
         (summary (read-string "Summary: " (format "<code>%s</code>" file-path))))
    (if multiline
        (format "<details>\n<summary>%s</summary>\n\n```%s\n%s\n```\n%s</details>\n"
                summary
                (copy-as-format--language)
                text
                (if (and (boundp 'snippet-url) snippet-url)
                    (format "<sup>[[source](%s)]</sup>\n" snippet-url)
                  ""))
      (copy-as-format--inline-markdown text))))

;; - Add template to `copy-as-format-format-alist'
(with-eval-after-load 'copy-as-format
  (if (boundp 'copy-as-format-format-alist)
      (add-to-list 'copy-as-format-format-alist
                   '("github-folded" yankee-copy-as-format--github-folded))
    (error "`copy-as-format-format-alist' not defined")))

;; - Override `copy-as-format' function to provide informative comment
(with-eval-after-load 'copy-as-format
  (defun copy-as-format--extract-text ()
    "Override function in `copy-as-format' to add filename comment."

    (defvar file-name)
    (defvar mode-atom)
    (defvar selection-range)
    (defvar start-linenum)
    (defvar end-linenum)
    (defvar commit-hash)
    (defvar snippet-url)

    (setq commit-hash (yankee--current-commit-ref))
    (setq snippet-url (and commit-hash
                        (yankee--code-snippet-url
                         (yankee--current-commit-remote)
                         commit-hash
                         file-name
                         start-linenum
                         end-linenum)))

    (if (not (use-region-p))
        (buffer-substring-no-properties (line-beginning-position) (line-end-position))
      ;; Avoid adding an extra blank line to the selection. This happens when
      ;; point or mark is at the start of the next line.
      ;;
      ;; When selection is from bottom to top, exchange point and mark
      ;; so that the `point' and `(region-end)' are the same.
      (when (< (point) (mark))
        (exchange-point-and-mark))

      (let (n min text (end (region-end)))
        (when (= end (line-beginning-position))
          (setq end (1- end)))

        ;; Let's trim unnecessary leading space from the region
        (let* ((text (buffer-substring-no-properties (region-beginning) end))
               (commit-hash-str (if commit-hash (format "(%s)" commit-hash) ""))
               (info-line (format "%s %s %s" file-name selection-range commit-hash-str)))
          (with-temp-buffer
            ;; Enable the source buffer's major-mode in the temp buffer.
            ;; Avoid rjsx-mode because it takes long to load, which creates a
            ;; race condition with `comment-region'.
            (funcall (if (eq mode-atom 'rjsx-mode) 'js-mode mode-atom))

            (insert info-line)
            (comment-region (point-min) (point-max))
            (goto-char (point-max))
            (insert "\n\n")

            ;; trim leading whitespace so the code listing renders well excerpted
            (insert (yankee--clean-leading-whitepace text))

            (goto-char (point-min))
            ;; The length of the match (see below) determines how much leading
            ;; space to trim.
            ;; Without this only one space would be trimmed for each tab
            (untabify (point-min) (point-max))
            (while (search-forward-regexp "^\\([[:space:]]*\\)[^[:space:]]" nil t)
              (setq n (length (match-string 1)))
              (when (or (null min) (< n min))
                (setq min n)))

            (when (and (not (null min)) (> min 0))
              (indent-rigidly 1 (point-max) (- min)))
            (buffer-string)))))))

;; Utility yankee functions
(defun yankee--abbreviated-project-or-home-path-to-file ()
  "The path to the current buffer's file.
If in a project, the path is relative to the project root.
If not in a project, the path is an abbreviated absolute path."
  (interactive)
  (if (yankee--in-project-p)
      (yankee--path-relative-to-project-root)
    (abbreviate-file-name (or (buffer-file-name) ""))))

(defun yankee--clean-leading-whitepace (text)
  "Strip leading whitespace from each line of TEXT.
The amount stripped from each line is equal to the amount stripped from the
line with the left-most text."
  (defun chomp-trailing-newlines (string)
    (replace-regexp-in-string "\n\+\\'" "" string))

  (defun leading-whitespace-length (string)
    (let ((first-non-whitespace-char-posn
           (string-match-p "[^[:space:]]" string)))
      (or first-non-whitespace-char-posn 0)))

  (defun least-leading-whitespace-length (lines)
    (car (sort (mapcar #'leading-whitespace-length lines) '<)))

  (defun trim-leading-chars-and-join (num-chars-to-trim lines)
    (defun trim-line-unless-blank (line)
      (if (not (string= "" line))
          (substring line num-chars-to-trim)
        line))
    (mapconcat #'trim-line-unless-blank lines "\n"))

  (let* ((all-lines        ;; a list of all selected lines
          (split-string (chomp-trailing-newlines text) "\n"))
         (non-blank-lines  ;; only those with non-whitespace chars
          (seq-filter (lambda (line) (not (string= line ""))) all-lines))
         (start-index      ;; index of leftmost non-whitespace char
          (least-leading-whitespace-length non-blank-lines))
         (trimmed-text     ;; re-joined text, with leading whitespace text
          (trim-leading-chars-and-join start-index all-lines)))
    trimmed-text))

(defun yankee--current-commit-ref ()
  "The most recent commit for the file.
If not under version control or uncommitted changes exist in the file, return
nil. Currently only supports Git and git-timemachine mode."
  (cond
   ((bound-and-true-p git-timemachine-mode)
    (yankee--current-commit-ref-git-timemachine))
   ((eq 'Git (vc-backend (buffer-file-name)))
    (yankee--current-commit-ref-git))))

(defun yankee--current-commit-ref-git-timemachine ()
  "Return the current commit's ref."
  (substring (git-timemachine-kill-revision) 0 8))

(defun yankee--current-commit-ref-git ()
  "Using Git, return the latest commit ref in the file.
If dirty or untracked, return nil."
  (let* ((filename (or (buffer-file-name) ""))
         (commit-ref (replace-regexp-in-string
                      "\n\\'" ""
                      (shell-command-to-string
                       (format "git rev-list -1 HEAD %s" filename)))))
    (when (not (member (yankee--abbreviated-project-or-home-path-to-file)
                       (yankee--list-dirty-files-git)))
      (substring commit-ref 0 8))))

(defun yankee--mode-string (modename)
  "Return the current buffer's major mode, MODENAME, as a string."
  (cond ((string= modename nil) "text-mode")
        ((string= modename "fundamental-mode") "text-mode")
        (t (format "%s" modename))))

(defun yankee--path-relative-to-project-root ()
  "The current file's path relative to the project root."
  (interactive)
  (replace-regexp-in-string (yankee--project-root) ""
                            (expand-file-name (or (buffer-file-name) ""))))

(defun yankee--selected-lines (format start-line end-line)
  "Return the selected line numbers as a string.
In the given FORMAT, generate the selection range string for the selection with
the given START-LINE and END-LINE (e.g., 'L5-L10', 'L5-10', or 'lines-5:10')."
  (cond ((equal format 'path)
         (if (equal start-line end-line)
             (format "L%s" (number-to-string start-line))
           (format "L%s-%s" (number-to-string start-line) (number-to-string end-line))))
        ((equal format 'github)
         (format "L%s-L%s" (number-to-string start-line) (number-to-string end-line)))
        ((equal format 'gitlab)
         (format "L%s-%s" (number-to-string start-line) (number-to-string end-line)))
        ((equal format 'bitbucket)
         (format "lines-%s:%s" (number-to-string start-line) (number-to-string end-line)))))

(defun yankee--code-snippet-url (commit-remote commit-ref file-name start-line end-line)
  "Generate the snippet url in the appropriate format depending on the service.
Supports GitHub, GitLab, and Bitbucket.
Examples:
COMMIT-REMOTE: https://github.com/orgname/reponame/file.py
COMMIT-REF: 105561ec24
FILE-NAME: file.py
START-LINE: 4
END-LINE: 8"
  (and commit-remote commit-ref file-name start-line end-line
      (cond
       ;; GitHub URL format
       ((string-match-p "github.com" commit-remote)
        (format "%s/blob/%s/%s#%s"
                 commit-remote
                 commit-ref
                 file-name
                 (yankee--selected-lines 'github start-line end-line)))
       ;; GitLab URL format
       ((string-match-p "gitlab.com" commit-remote)
        (format "%s/blob/%s/%s#%s"
                 commit-remote
                 commit-ref
                 file-name
                 (yankee--selected-lines 'gitlab start-line end-line)))
       ;; BitBucket URL format
       ((string-match-p "bitbucket.org" commit-remote)
        (format "%s/src/%s/%s#%s"
                 commit-remote
                 commit-ref
                 file-name
                 (yankee--selected-lines 'bitbucket start-line end-line))))))

(defun yankee--remote-url-git (remote-name)
  "Using Git, return the url for the remote named REMOTE-NAME."
  (shell-command-to-string
   (format "git remote -v |\
     grep %s |\
     awk '/fetch/{print $2}' |\
     sed -Ee 's#(git@|git://)#http://#' -e 's@com:@com/@' -e 's/\.git$//'" remote-name)))

(defun yankee--current-commit-remote ()
  "The current commit's remote URL, if under version control with a remote set.
Currently only supports Git and remotes named `origin`. TODO: Use a prompt when multiple remotes found."
  (when (eq 'Git (vc-backend (buffer-file-name)))
    (let ((remote-url (replace-regexp-in-string
                       "\n$" ""
                       (yankee--remote-url-git "origin"))))
      (and (string-match-p "http" remote-url) remote-url))))

(defun yankee--list-dirty-files-git ()
  "Using Git, list the repository's currently dirty files.
Includes files with modifications and new files not yet in the index."
  (split-string
   (replace-regexp-in-string
    "\n\\'" ""
    (shell-command-to-string
     "git status --porcelain --ignore-submodules | awk '{ print $2 }'"))))

(provide 'yankee)
;;; yankee.el ends here
