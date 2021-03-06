;;; ldg-reconcile.el --- Helper code for use with the "ledger" command-line tool

;; Copyright (C) 2003-2013 John Wiegley (johnw AT gnu DOT org)

;; This file is not part of GNU Emacs.

;; This is free software; you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free
;; Software Foundation; either version 2, or (at your option) any later
;; version.
;;
;; This is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
;; for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
;; MA 02111-1307, USA.

;; Reconcile mode


;;; Commentary:
;; 

;;; Code:

(defvar ledger-buf nil)
(defvar ledger-bufs nil)
(defvar ledger-acct nil)
(defvar ledger-target nil)

(defcustom ledger-recon-buffer-name "*Reconcile*"
  "Name to use for reconciliation window."
  :group 'ledger)

(defcustom ledger-fold-on-reconcile t
  "If t, limit transactions shown in main buffer to those matching the reconcile regex."
  :type 'boolean
  :group 'ledger)

(defcustom ledger-buffer-tracks-reconcile-buffer t
  "If t, then when the cursor is moved to a new xact in the recon window.
Then that transaction will be shown in its source buffer."
  :type 'boolean
  :group 'ledger)

(defcustom ledger-reconcile-force-window-bottom nil
  "If t make the reconcile window appear along the bottom of the register window and resize."
  :type 'boolean
  :group 'ledger)

(defcustom ledger-reconcile-toggle-to-pending t
  "If true then toggle between uncleared and pending.
reconcile-finish will mark all pending posting cleared."
   :type 'boolean
   :group 'ledger)


(defun ledger-reconcile-get-balances ()
  "Calculate the cleared and uncleared balance of the account.
Return a list with the account, uncleared and cleared balances as
numbers"
  (interactive)
  (let ((buffer ledger-buf)
        (account ledger-acct)
	(val nil))
    (with-temp-buffer
      (ledger-exec-ledger buffer (current-buffer)
	   ; note that in the line below, the --format option is
           ; separated from the actual format string.  emacs does not
           ; split arguments like the shell does, so you need to
           ; specify the individual fields in the command line.
	   "balance" "--limit" "cleared or pending"
	   "--format" "(\"%(display_total)\")" account)
      (setq val (read (buffer-substring-no-properties (point-min) (point-max)))))))

(defun ledger-display-balance ()
  "Calculate the cleared balance of the account being reconciled."
  (interactive)
  (let* ((pending (car (ledger-string-balance-to-commoditized-amount
			(car (ledger-reconcile-get-balances)))))
	 (target-delta (if ledger-target
			   (-commodity ledger-target pending)
			   nil)))
    
    (if target-delta
	(message "Pending balance: %s,   Difference from target: %s"
		 (ledger-commodity-to-string pending)
		 (ledger-commodity-to-string target-delta))
	(message "Pending balance: %s"
		 (ledger-commodity-to-string pending)))))
		 
		 


(defun is-stdin (file)
  "True if ledger FILE is standard input."
  (or
   (equal file "")
   (equal file "<stdin>")
   (equal file "/dev/stdin")))

(defun ledger-reconcile-get-buffer (where)
  "Return a buffer from WHERE the transaction is."
  (if (bufferp (car where))
      (car where)
      (error "ledger-reconcile-get-buffer: Buffer not set")))

(defun ledger-reconcile-toggle ()
  "Toggle the current transaction, and mark the recon window."
  (interactive)
  (let ((where (get-text-property (point) 'where))
        (inhibit-read-only t)
        status)
    (when (ledger-reconcile-get-buffer where)
      (with-current-buffer (ledger-reconcile-get-buffer where)
	(ledger-goto-line (cdr where))
	(forward-char)
	(setq status (ledger-toggle-current (if ledger-reconcile-toggle-to-pending
						'pending
						'cleared))))
	;; remove the existing face and add the new face
      (remove-text-properties (line-beginning-position)
			      (line-end-position)
			      (list 'face))
      (cond ((eq status 'pending)
	     (add-text-properties (line-beginning-position)
				  (line-end-position)
				  (list 'face 'ledger-font-reconciler-pending-face )))
	    ((eq status 'cleared)
	     (add-text-properties (line-beginning-position)
				  (line-end-position)
				  (list 'face 'ledger-font-reconciler-cleared-face )))
	    (t
	     (add-text-properties (line-beginning-position)
				  (line-end-position)
				  (list 'face 'ledger-font-reconciler-uncleared-face )))))
    (forward-line)
    (beginning-of-line)
    (ledger-display-balance)))

(defun ledger-reconcile-refresh ()
  "Force the reconciliation window to refresh."
  (interactive)
  (let ((inhibit-read-only t)
        (line (count-lines (point-min) (point))))
    (erase-buffer)
    (ledger-do-reconcile)
    (set-buffer-modified-p t)
    (goto-char (point-min))
    (forward-line line)))

(defun ledger-reconcile-refresh-after-save ()
  "Refresh the recon-window after the ledger buffer is saved."
  (let ((buf (get-buffer ledger-recon-buffer-name)))
    (if buf
        (with-current-buffer buf
          (ledger-reconcile-refresh)
          (set-buffer-modified-p nil)))))

(defun ledger-reconcile-add ()
  "Use ledger xact to add a new transaction."
  (interactive)
  (with-current-buffer ledger-buf
    (call-interactively #'ledger-add-transaction))
  (ledger-reconcile-refresh))

(defun ledger-reconcile-delete ()
  "Delete the transactions pointed to in the recon window."
  (interactive)
  (let ((where (get-text-property (point) 'where)))
    (when (ledger-reconcile-get-buffer where)
      (with-current-buffer (ledger-reconcile-get-buffer where)
        (ledger-goto-line (cdr where))
        (ledger-delete-current-transaction))
      (let ((inhibit-read-only t))
        (goto-char (line-beginning-position))
        (delete-region (point) (1+ (line-end-position)))
        (set-buffer-modified-p t)))))

(defun ledger-reconcile-visit (&optional come-back)
  "Recenter ledger buffer on transaction and COME-BACK if non-nil."
  (interactive)
  (progn
    (beginning-of-line)
    (let* ((where (get-text-property (1+ (point)) 'where))
	   (target-buffer (if where
			      (ledger-reconcile-get-buffer where)
			      nil))
	   (cur-buf (get-buffer ledger-recon-buffer-name)))
      (when target-buffer
	(switch-to-buffer-other-window target-buffer)
	(ledger-goto-line (cdr where))
	(forward-char)
	(recenter)
	(ledger-highlight-xact-under-point)
	(if come-back
	    (switch-to-buffer-other-window cur-buf))))))

(defun ledger-reconcile-save ()
  "Save the ledger buffer."
  (interactive)
  (dolist (buf (cons ledger-buf ledger-bufs))
    (with-current-buffer buf
      (save-buffer)))
  (set-buffer-modified-p nil)
  (ledger-display-balance))

(defun ledger-reconcile-finish ()
  "Mark all pending posting or transactions as cleared.
Depends on ledger-reconcile-clear-whole-transactions, save the buffers
and exit reconcile mode"
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (let ((where (get-text-property (point) 'where))
            (face  (get-text-property (point) 'face)))
        (if (eq face 'ledger-font-reconciler-pending-face)
            (with-current-buffer (ledger-reconcile-get-buffer where)
              (ledger-goto-line (cdr where))
              (ledger-toggle-current 'cleared))))
      (forward-line 1)))
  (ledger-reconcile-save))


(defun ledger-reconcile-quit ()
  "Quite the reconcile window without saving ledger buffer."
  (interactive)
  (ledger-reconcile-quit-cleanup)
  (let ((buf ledger-buf)
	(recon-buf  (get-buffer ledger-recon-buffer-name)))
    ;; Make sure you delete the window before you delete the buffer,
    ;; otherwise, madness ensues
    (with-current-buffer recon-buf
      (delete-window (get-buffer-window recon-buf))
      (kill-buffer recon-buf))
    (set-window-buffer (selected-window) buf)))

(defun ledger-reconcile-quit-cleanup ()
  "Cleanup all hooks established by reconcile mode."
  (interactive)
  (let ((buf ledger-buf)
	(reconcile-buf (get-buffer ledger-recon-buffer-name)))
    (with-current-buffer buf
      (remove-hook 'after-save-hook 'ledger-reconcile-refresh-after-save t)
      (if ledger-fold-on-reconcile
	  (ledger-occur-quit-buffer buf)))))

(defun ledger-marker-where-xact-is (emacs-xact posting)
  "Find the position of the EMACS-XACT in the `ledger-buf'.
POSTING is used in `ledger-clear-whole-transactions' is nil."
  (let ((buf (if (is-stdin (nth 0 emacs-xact))
		 ledger-buf
		 (find-file-noselect (nth 0 emacs-xact)))))
    (cons
     buf
     (if ledger-clear-whole-transactions
	 (nth 1 emacs-xact)  ;; return line-no of xact
	 (nth 0 posting))))) ;; return line-no of posting

(defun ledger-do-reconcile ()
  "Get the uncleared transactions in the account and display them in the *Reconcile* buffer."
  (let* ((buf ledger-buf)
         (account ledger-acct)
         (xacts
          (with-temp-buffer
	    (ledger-exec-ledger buf (current-buffer)
				"--uncleared" "--real" "emacs" account)
	    (goto-char (point-min))
	    (unless (eobp)
	      (unless (looking-at "(")
		(error (concat "ledger-do-reconcile: " (buffer-string))))
	      (read (current-buffer)))))) ;current-buffer is the *temp* created above
    (if (> (length xacts) 0)
	(progn
	  (dolist (xact xacts)
	      (dolist (posting (nthcdr 5 xact))
		(let ((beg (point))
		      (where (ledger-marker-where-xact-is xact posting)))
		  (insert (format "%s %-4s %-30s %-30s %15s\n"
				  (format-time-string "%Y/%m/%d" (nth 2 xact))
				  (if (nth 3 xact)
				      (nth 3 xact)
				      "")
				  (nth 4 xact) (nth 1 posting) (nth 2 posting)))
		  (if (nth 3 posting)
		      (if (eq (nth 3 posting) 'pending)
			  (set-text-properties beg (1- (point))
					       (list 'face 'ledger-font-reconciler-pending-face
						     'where where))
			  (set-text-properties beg (1- (point))
					       (list 'face 'ledger-font-reconciler-cleared-face
						     'where where)))
		      (set-text-properties beg (1- (point))
					   (list 'face 'ledger-font-reconciler-uncleared-face
						 'where where))))  ))
	  (goto-char (point-max))
	  (delete-char -1)) ;gets rid of the extra line feed at the bottom of the list
	(insert (concat "There are no uncleared entries for " account)))
    (goto-char (point-min))
    (set-buffer-modified-p nil)
    (toggle-read-only t)

    ;; this next piece of code ensures that the last of the visible
    ;; transactions in the ledger buffer is at the bottom of the main
    ;; window.  The key to this is to ensure the window is selected
    ;; when the buffer point is moved and recentered.  If they aren't
    ;; strange things happen.
    
    (let ((recon-window (get-buffer-window (get-buffer ledger-recon-buffer-name))))
      (when recon-window
	(fit-window-to-buffer recon-window)
	(with-current-buffer buf
	  (select-window (get-buffer-window buf))
	  (goto-char (point-max))
	  (recenter -1))
        
        (select-window recon-window)
        (ledger-reconcile-visit t))
      (add-hook 'post-command-hook 'ledger-reconcile-track-xact nil t))))

(defun ledger-reconcile-track-xact ()
  "Force the ledger buffer to recenter on the transactionat point in the reconcile buffer."
  (if (member this-command (list 'next-line
				 'previous-line
				 'mouse-set-point
				 'ledger-reconcile-toggle))
      (if ledger-buffer-tracks-reconcile-buffer
	  (save-excursion
	    (ledger-reconcile-visit t)))))

(defun ledger-reconcile-open-windows (buf rbuf)
  "Ensure that the ledger buffer BUF is split by RBUF."
  (if ledger-reconcile-force-window-bottom
      ;;create the *Reconcile* window directly below the ledger buffer.
      (set-window-buffer (split-window (get-buffer-window buf) nil nil) rbuf)
      (pop-to-buffer rbuf)))

(defun ledger-reconcile (account)
  "Start reconciling ACCOUNT."
  (interactive "sAccount to reconcile: ")
  (let ((buf (current-buffer))
        (rbuf (get-buffer ledger-recon-buffer-name)))  ;; this means
						       ;; only one
						       ;; *Reconcile*
						       ;; buffer, ever
    (if rbuf  ;; *Reconcile* already exists
	(with-current-buffer rbuf
	  (set 'ledger-acct account)  ;; already buffer local
	  (if (not (eq buf rbuf))
	      (progn ;; called from some other ledger-mode buffer
		(ledger-reconcile-quit-cleanup)
		(set 'ledger-buf buf)))  ;; should already be
					 ;; buffer-local
	  (if ledger-fold-on-reconcile
	      (ledger-occur-change-regex account ledger-buf))
	  (set-buffer (get-buffer ledger-recon-buffer-name))
	  (setq ledger-target
		(ledger-read-commodity-string "Set reconciliation target"))
	  (unless (get-buffer-window rbuf)
	    (ledger-reconcile-open-windows buf rbuf))
	  (ledger-reconcile-refresh)
	  (goto-char (point-min)))

	  (progn  ;; no recon-buffer, starting from scratch.
	    (add-hook 'after-save-hook 'ledger-reconcile-refresh-after-save nil t)
	    (if ledger-fold-on-reconcile
		(ledger-occur-mode account buf))
	    
	    (with-current-buffer (get-buffer-create ledger-recon-buffer-name)
	      (ledger-reconcile-open-windows buf (current-buffer))
	      (ledger-reconcile-mode)
	      (set (make-local-variable 'ledger-buf) buf)
	      (set (make-local-variable 'ledger-acct) account)
	      (set (make-local-variable 'ledger-target)
		   (ledger-read-commodity-string "Set reconciliation target"))
	      (ledger-do-reconcile))))))

(defvar ledger-reconcile-mode-abbrev-table)

(defun ledger-reconcile-change-target ()
  "Change the traget amount for the reconciliation process."
  (interactive)
  (setq ledger-target (ledger-read-commodity-string "Set reconciliation target")))

(define-derived-mode ledger-reconcile-mode text-mode "Reconcile"
   "A mode for reconciling ledger entries."
   (let ((map (make-sparse-keymap)))
     (define-key map [(control ?m)] 'ledger-reconcile-visit)
     (define-key map [return] 'ledger-reconcile-visit)
     (define-key map [(control ?l)] 'ledger-reconcile-refresh)
     (define-key map [(control ?c) (control ?c)] 'ledger-reconcile-finish)
     (define-key map [? ] 'ledger-reconcile-toggle)
     (define-key map [?a] 'ledger-reconcile-add)
     (define-key map [?d] 'ledger-reconcile-delete)
     (define-key map [?g] 'ledger-reconcile);
     (define-key map [?n] 'next-line)
     (define-key map [?p] 'previous-line)
     (define-key map [?t] 'ledger-reconcile-change-target)
     (define-key map [?s] 'ledger-reconcile-save)
     (define-key map [?q] 'ledger-reconcile-quit)
     (define-key map [?b] 'ledger-display-balance)
     
     (define-key map [menu-bar] (make-sparse-keymap "ldg-recon-menu"))
     (define-key map [menu-bar ldg-recon-menu] (cons "Reconcile" map))
     (define-key map [menu-bar ldg-recon-menu qui] '("Quit" . ledger-reconcile-quit))
     (define-key map [menu-bar ldg-recon-menu sep1] '("--"))
     (define-key map [menu-bar ldg-recon-menu pre] '("Previous Entry" . previous-line))
     (define-key map [menu-bar ldg-recon-menu vis] '("Visit Entry" . ledger-reconcile-visit))
     (define-key map [menu-bar ldg-recon-menu nex] '("Next Entry" . next-line))
     (define-key map [menu-bar ldg-recon-menu sep2] '("--"))
     (define-key map [menu-bar ldg-recon-menu del] '("Delete Entry" . ledger-reconcile-delete))
     (define-key map [menu-bar ldg-recon-menu add] '("Add Entry" . ledger-reconcile-add))
     (define-key map [menu-bar ldg-recon-menu tog] '("Toggle Entry" . ledger-reconcile-toggle))
     (define-key map [menu-bar ldg-recon-menu sep3] '("--"))
     (define-key map [menu-bar ldg-recon-menu bal] '("Show Cleared Balance" . ledger-display-balance))
     (define-key map [menu-bar ldg-recon-menu tgt] '("Change Target Balance" . ledger-reconcile-change-target))
     (define-key map [menu-bar ldg-recon-menu sep4] '("--"))
     (define-key map [menu-bar ldg-recon-menu rna] '("Reconcile New Account" . ledger-reconcile))
     (define-key map [menu-bar ldg-recon-menu sep5] '("--"))
     (define-key map [menu-bar ldg-recon-menu fin] '("Finish" . ledger-reconcile-finish))
     (define-key map [menu-bar ldg-recon-menu ref] '("Refresh" . ledger-reconcile-refresh))
     (define-key map [menu-bar ldg-recon-menu sav] '("Save" . ledger-reconcile-save))
     
     (use-local-map map)
     
     (add-hook 'kill-buffer-hook 'ledger-reconcile-quit-cleanup nil t)))

(provide 'ldg-reconcile)
(provide 'ldg-reconcile)

;;; ldg-reconcile.el ends here
