; Imports & aliases ///1

(local api vim.api)
(local empty? vim.tbl_isempty)
(local map vim.tbl_map)
(local min math.min)
(local max math.max)
(local ceil math.ceil)


; Fennel utils ///1

(macro ++ [x] `(set ,x (+ ,x 1)))

(macro one-of? [x ...]
  "Expands to an `or` form, like (or (= x y1) (= x y2) ...)"
  `(or ,(unpack
          (icollect [_ y (ipairs [...])]
            `(= ,x ,y)))))

(macro when-not [condition ...]
  `(when (not ,condition) ,...))

(fn inc [x] (+ x 1))
(fn dec [x] (- x 1))

(fn clamp [val min max]
  (if (< val min) min
      (> val max) max
      :else val))

(fn last [tbl] (. tbl (length tbl)))


; Nvim utils ///1

(fn replace-keycodes [s]
  (api.nvim_replace_termcodes s true false true))

(fn echo [msg]
  (vim.cmd :redraw) (api.nvim_echo [[msg]] false []))

(fn operator-pending-mode? []
  (-> (. (api.nvim_get_mode) :mode) (string.match :o)))

(fn is-current-operation? [op-ch]
  (and (operator-pending-mode?) (= vim.v.operator op-ch)))

(fn change-operation? [] (is-current-operation? :c))
(fn delete-operation? [] (is-current-operation? :d))

(fn dot-repeatable-operation? []
  (and (operator-pending-mode?) (not= vim.v.operator :y)))

(fn get-cursor-pos [] [(vim.fn.line ".") (vim.fn.col ".")])

(fn same-pos? [[l1 c1] [l2 c2]] (and (= l1 l2) (= c1 c2)))


(fn char-at-pos [[line byte-col] {: char-offset}]  ; expects (1,1)-indexed input
  "Get character at the given position in a multibyte-aware manner.
An optional offset argument can be given to get the nth-next screen
character instead."
  (let [line-str (vim.fn.getline line)
        char-idx (vim.fn.charidx line-str (dec byte-col))  ; charidx expects 0-indexed col
        char-nr (vim.fn.strgetchar line-str (+ char-idx (or char-offset 0)))]
    (when (not= char-nr -1)
      (vim.fn.nr2char char-nr))))


(fn leftmost-editable-wincol []
  ; Note: This will not have a visible effect if not forcing a redraw.
  (local view (vim.fn.winsaveview))
  (vim.cmd "norm! 0")
  (local wincol (vim.fn.wincol))
  (vim.fn.winrestview view)
  wincol)


(fn get-fold-edge [lnum reverse?]
  (match ((if reverse? vim.fn.foldclosed vim.fn.foldclosedend) lnum)
    -1 nil
    fold-edge fold-edge))


; Glossary ///1

; Instant-repeat (1-char search)
; While Lightspeed is active, repeatedly pressing f/F/t/T goes to (or
; right before/after) the next/previous match (effectively repeats the
; last 1-character search with a count of 1). Pressing any other key
; exits from this "standby" mode; subsequent calls will behave as new
; invocations.

; Beacon (2-char search)
; An extmark positioned over an on-screen matching pair, giving
; information about how it can be reached. It can take on many forms; in
; the common case, the first field shows the 2nd character of the
; original pair, as a reminder (that is, it is shown on top of the
; _first_ character), while the second field shows a "target label"
; (that is possibly a "shortcut"). If there is only one match, the
; extmark shows the pair as it is, with a different highlighting (we
; will jump there automatically then).
; Beacons can also overlap each other - in that case, the invariant to
; be maintained is that the target label (i.e., the second/right field)
; should remain visible in all circumstances.

; Label (2-char search)
; The character needed to be pressed to jump to the match position,
; after the whole search pattern has been given. It is always shown on
; top of the second character of the pair.

; Shortcut (2-char search)
; A position where the assigned label itself is enough to determine the
; target you want to jump to (for example when a character is always
; followed by a certain other character in the search area). Those you
; can reach via typing the label character right after the first input,
; bypassing the second one. The label gets a different highlight in
; these cases.


; Setup ///1

(var opts 
     (do
       ; Heuristics behind the defaults: 
       ; - At least the first few labels should be the same on the two lists,
       ;   since those become muscle memory, and might be used automatically, a
       ;   bit like [count] values.
       ; - Since the commands themselves are mapped to left-hand keys, we tend
       ;   to prioritize right-hand keys to get a better balance for the whole
       ;   sequence on average.
       (local safe-labels 
              ; Autojump is disabled only in case of > 18 match - that seems a
              ; tolerable compromise.
              ["s" "f" "n"
               "u" "t"
               "/" "S" "F" "L" "N" "H" "G" "M" "U" "T" "?" "Z"])
       (local labels
              ["s" "f" "n"
               "j" "k" "l" "o" "i" "w" "e" "h" "g"
               "u" "t"
               "m" "v" "c" "." "z" ";" "a"
               "/" "S" "F" "L" "N" "H" "G" "M" "U" "T" "?" "Z"])

       {:jump_on_partial_input_safety_timeout 400
        :exit_after_idle_msecs {:labeled 1500 :unlabeled 1000}
        :highlight_unique_chars true
        :grey_out_search_area true
        :match_only_the_start_of_same_char_seqs true
        :limit_ft_matches 4
        :x_mode_prefix_key "<c-x>"
        :substitute_chars {"\r" "¬"}  ; 0x00AC
        :safe_labels safe-labels
        :labels labels
        :instant_repeat_fwd_key nil
        :instant_repeat_bwd_key nil
        :cycle_group_fwd_key "<space>"
        :cycle_group_bwd_key "<tab>"
        ; deprecated (still valid)
        ; :full_incusive_prefix_key "<c-x>"
        }))

(fn setup [user-opts]
  (set opts (setmetatable user-opts {:__index opts})))


; Highlight ///1

(local hl
  {:group {:label                    "LightspeedLabel"
           :label-distant            "LightspeedLabelDistant"
           :label-overlapped         "LightspeedLabelOverlapped"
           :label-distant-overlapped "LightspeedLabelDistantOverlapped"
           :shortcut                 "LightspeedShortcut"
           :shortcut-overlapped      "LightspeedShortcutOverlapped"
           :masked-ch                "LightspeedMaskedChar"
           :unlabeled-match          "LightspeedUnlabeledMatch"
           :one-char-match           "LightspeedOneCharMatch"
           :unique-ch                "LightspeedUniqueChar"
           :pending-op-area          "LightspeedPendingOpArea"
           :greywash                 "LightspeedGreyWash"
           :cursor                   "LightspeedCursor"}
   :ns (api.nvim_create_namespace "")
   :add-hl (fn [self hl-group line startcol endcol]
             (api.nvim_buf_add_highlight 0 self.ns hl-group line startcol endcol))
   :set-extmark (fn [self line col opts]
                  (api.nvim_buf_set_extmark 0 self.ns line col opts))
   :cleanup (fn [self] (api.nvim_buf_clear_namespace 0 self.ns 0 -1))})


(fn init-highlight [force?]
  (local bg vim.o.background)
  (local groupdefs
    [[hl.group.label                    {:guifg (match bg :light "#f02077" _ "#ff2f87")
                                         :ctermfg "Red"
                                         :guibg :NONE :ctermbg :NONE
                                         :gui "bold,underline"
                                         :cterm "bold,underline"}]
     [hl.group.label-overlapped         {:guifg (match bg :light "#ff4090" _ "#e01067")
                                         :ctermfg "Magenta"
                                         :guibg :NONE :ctermbg :NONE
                                         :gui "underline"
                                         :cterm "underline"}]
     [hl.group.label-distant            {:guifg (match bg :light "#399d9f" _ "#99ddff")
                                         :ctermfg (match bg :light "Blue" _ "Cyan")
                                         :guibg :NONE :ctermbg :NONE
                                         :gui "bold,underline"
                                         :cterm "bold,underline"}]
     [hl.group.label-distant-overlapped {:guifg (match bg :light "#59bdbf" _ "#79bddf")
                                         :ctermfg (match bg :light "Cyan" _ "Blue")
                                         :gui "underline" :cterm "underline"}]
     [hl.group.shortcut                 {:guibg "#f00077" :ctermbg "Red"
                                         :guifg "#ffffff" :ctermfg "White"
                                         :gui "bold,underline" :cterm "bold,underline"}]  ; ~inverse of label
     [hl.group.one-char-match           {:guibg "#f00077" :ctermbg "Red"
                                         :guifg "#ffffff" :ctermfg "White"
                                         :gui "bold" :cterm "bold"}]  ; shortcut without underline
     [hl.group.masked-ch                {:guifg (match bg :light "#cc9999" _ "#b38080")
                                         :ctermfg "DarkGrey"
                                         :guibg :NONE :ctermbg :NONE
                                         :gui :NONE :cterm :NONE}]
     [hl.group.unlabeled-match          {:guifg (match bg :light "#272020" _ "#f3ecec")
                                         :ctermfg (match bg :light "Black" _ "White")
                                         :guibg :NONE :ctermbg :NONE
                                         :gui "bold"
                                         :cterm "bold"}]
     [hl.group.pending-op-area          {:guibg "#f00077" :ctermbg "Red"
                                         :guifg "#ffffff" :ctermfg "White"}]  ; ~shortcut without bold/underline
     [hl.group.greywash                 {:guifg "#777777" :ctermfg "Grey"
                                         :guibg :NONE :ctermbg :NONE
                                         :gui :NONE :cterm :NONE}]])
  ; Defining groups.
  (each [_ [group attrs] (ipairs groupdefs)]
    (let [attrs-str (-> (icollect [k v (pairs attrs)] (.. k "=" v))
                        (table.concat " "))]
      ; "default" = do not override any existing definition for the group.
      (vim.cmd (.. "highlight "
                   (if force? "" "default ")
                   group " " attrs-str))))
  ; Setting linked groups.
  (each [_ [from-group to-group]
         (ipairs [[hl.group.unique-ch hl.group.unlabeled-match]
                  [hl.group.shortcut-overlapped hl.group.shortcut]
                  [hl.group.cursor "Cursor"]])]
    (vim.cmd (.. "highlight "
                 (if force? "" "default ")
                 "link " from-group " " to-group))))


(fn grey-out-search-area [reverse?]
  (let [[curline curcol] (map dec (get-cursor-pos))
        [win-top win-bot] [(dec (vim.fn.line "w0")) (dec (vim.fn.line "w$"))]
        [start finish] (if reverse?
                         [[win-top 0] [curline curcol]]
                         [[curline (inc curcol)] [win-bot -1]])]
    ; Expects 0,0-indexed args; `finish` is exclusive.
    (vim.highlight.range 0 hl.ns hl.group.greywash start finish)))


(fn highlight-range [hl-group
                     [startline startcol &as start]
                     [endline endcol &as end]
                     {: forced-motion : inclusive-motion?}]
  "A wrapper around `vim.highlight.range` that handles forced motion
types properly."
  (let [ctrl-v (replace-keycodes "<c-v>")
        hl-range (fn [start end end-inclusive?]
                   (vim.highlight.range
                     0 hl.ns hl-group start end nil end-inclusive?))]
    (match forced-motion
      ctrl-v (let [[startcol endcol] [(min startcol endcol)
                                      (max startcol endcol)]]
               (for [line startline endline]
                 ; Blockwise operations make the motion inclusive on
                 ; both ends, unconditionally.
                 (hl-range [line startcol] [line endcol] true)))
      :V (hl-range [startline 0] [endline -1])
      ; We are in OP mode, doing chairwise motion, so 'v' _flips_ its
      ; inclusive/exclusive behaviour (:h o_v).
      :v (hl-range start end (not inclusive-motion?))
      _ (hl-range start end inclusive-motion?))))


; Common ///1

(fn echo-no-prev-search [] (echo "no previous search"))

(fn echo-not-found [s] (echo (.. "not found: " s)))


(fn push-cursor! [direction]
  "Push cursor 1 character to the left or right, possibly beyond EOL."
  (vim.fn.search "\\_." (match direction :fwd "W" :bwd "bW")))


(fn cursor-before-eof? []
  (and (= (vim.fn.line ".") (vim.fn.line "$"))
       (= (vim.fn.virtcol ".") (dec (vim.fn.virtcol "$")))))


(fn force-matchparen-refresh []
  ; HACK: :DoMatchParen turns matchparen on simply by triggering
  ;       CursorMoved events (see matchparen.vim). We can do the same,
  ;       which is cleaner for us than calling :DoMatchParen directly,
  ;       since that would wrap this in a `windo`, and might visit
  ;       another buffer, breaking our visual selection (and thus also
  ;       dot-repeat, apparently). (See :h visual-start, and the
  ;       discussion at #38.)
  ;       Programming against the API would be more robust of course,
  ;       but in the unlikely case that the implementation details would
  ;       change, this still cannot do any damage on our side if called
  ;       silent!-ly (the feature just ceases to work then).
  (vim.cmd "silent! doautocmd matchparen CursorMoved")
  ; If vim-matchup is installed, it can similarly be forced to refresh
  ; by triggering a CursorMoved event. (The same caveats apply.)
  (vim.cmd "silent! doautocmd matchup_matchparen CursorMoved"))


(macro jump-to!* [target
                 {: add-to-jumplist? : after : reverse? : inclusive-motion?}]
  `(let [op-mode?# (operator-pending-mode?)
         ; Needs to be here, inside the returned form, as we need to get
         ; `vim.o.virtualedit` at runtime.
         restore-virtualedit-autocmd#
         (.. "autocmd CursorMoved,WinLeave,BufLeave"
             ",InsertEnter,CmdlineEnter,CmdwinEnter"
             " * ++once set virtualedit="
             vim.o.virtualedit)]
     ; <C-o> will unfortunately ignore this if the line has not changed.
     ; See https://github.com/neovim/neovim/issues/9874
     (when ,add-to-jumplist? (vim.cmd "norm! m`"))
     (vim.fn.cursor ,target)
     ; Adjust position after the jump (for t-motion or x-mode).
     ,after

     ; Simulating inclusive/exclusive behaviour for operator-pending mode by
     ; adjusting the cursor position.

     ; For operators, our jump is always interpreted by Vim as an exclusive
     ; motion, so whenever we'd like to behave as an inclusive one, an
     ; additional push is needed to even that out (:h inclusive).
     ; (This is only relevant in the forward direction.)
     (when (and op-mode?# (not ,reverse?) ,inclusive-motion?)
       ; Check for modifiers forcing motion types. (:h forced-motion)
       (match (string.sub (vim.fn.mode :t) -1)
         ; Note that we should _never_ push the cursor in the linewise case,
         ; as we might push it beyond EOL, and that would add another line
         ; to the selection.

         ; Blockwise (<c-v>) itself makes the motion inclusive, we're done.

         ; We want the `v` modifier to behave in the native way, that is, to
         ; toggle between inclusive/exclusive if applied to a charwise
         ; motion (:h o_v). As our jump is technically - i.e., from Vim's
         ; perspective - an exclusive motion, `v` will change it to
         ; _inclusive_, so we should push the cursor back to "undo" that.
         ; (Previous column as inclusive = target column as exclusive.)
         :v (push-cursor! :bwd)

         ; Else, in the normal case (no modifier), we should push the cursor
         ; forward (next column as exclusive = target column as inclusive).
         :o (if (not (cursor-before-eof?)) (push-cursor! :fwd)
                ; The EOF edge case requires some hackery.
                ; (Note: The cursor will be moved to the end of the operated
                ; area anyway, no need to undo the `l` afterwards.)
                (do (vim.cmd "set virtualedit=onemore")
                    (vim.cmd "norm! l")
                    (vim.cmd restore-virtualedit-autocmd#)))))
     (when (not op-mode?#)
       (force-matchparen-refresh))))


(fn get-onscreen-lines [{: reverse? : skip-folds?}]
  (let [lines {}  ; {lnum : line-str}
        wintop (vim.fn.line "w0")
        winbot (vim.fn.line "w$")]
    (var lnum (vim.fn.line "."))
    (while (if reverse? (>= lnum wintop) (<= lnum winbot))
      (local fold-edge (get-fold-edge lnum reverse?))
      (if (and skip-folds? fold-edge)
          (set lnum ((if reverse? dec inc) fold-edge))
          (do (tset lines lnum (vim.fn.getline lnum))
              (set lnum ((if reverse? dec inc) lnum)))))
    lines))


(fn get-horizontal-bounds [{: match-width}]
  (let [gutter-width (dec (leftmost-editable-wincol))  ; sign/number/foldcolumn
        offset-in-win (vim.fn.wincol)  ; including gutter
        offset-in-editable-win (- offset-in-win gutter-width)
        ; I.e., screen-column of the first visible column in the editable area.
        left-bound (- (vim.fn.virtcol ".") (dec offset-in-editable-win))
        window-width (api.nvim_win_get_width 0)
        right-edge (+ left-bound (dec (- window-width gutter-width)))
        right-bound (- right-edge (dec match-width))]  ; the whole match should be visible
    [left-bound right-bound]))  ; screen columns (TODO: multibyte?)


(fn onscreen-match-positions [pattern reverse? {: ft-search? : limit}]
  "Returns an iterator streaming the return values of `searchpos` for
the given pattern, stopping at the window edge; in case of 2-character
search, folds and offscreen parts of non-wrapped lines are skipped too.
Caveat: side-effects take place here (cursor movement, &cpo), and the
clean-up happens only when the iterator is exhausted, so be careful with
early termination in loops."
  (let [view (vim.fn.winsaveview)
        cpo vim.o.cpo
        opts (if reverse? "b" "")
        stopline (vim.fn.line (if reverse? "w0" "w$"))  ; top/bottom of window
        cleanup #(do (vim.fn.winrestview view) (set vim.o.cpo cpo) nil)
        [left-bound right-bound] (get-horizontal-bounds
                                   {:match-width (if ft-search? 1 2)})]

    (fn skip-to-fold-edge! []
      (match ((if reverse? vim.fn.foldclosed vim.fn.foldclosedend)
              (vim.fn.line "."))
        -1 :not-in-fold
        fold-edge (do (vim.fn.cursor fold-edge 0)
                      (vim.fn.cursor 0 (if reverse? 1 (vim.fn.col "$")))
                      ; ...regardless of whether it _actually_ moved
                      :moved-the-cursor)))

    (fn skip-to-next-in-window-pos! []
      (local [line col &as from-pos] (get-cursor-pos))
      (match (if (< col left-bound) (if reverse? (when (>= (dec line) stopline)
                                                   [(dec line) right-bound])
                                        [line left-bound])
                 (> col right-bound) (if reverse? [line right-bound]
                                         (when (<= (inc line) stopline)
                                           [(inc line) left-bound])))
        to-pos (when (not= from-pos to-pos)
                 (vim.fn.cursor to-pos)
                 :moved-the-cursor)))

    (set vim.o.cpo (cpo:gsub "c" ""))  ; do not skip overlapping matches
    (var match-count 0)
    (fn recur [match-at-curpos?]
      (if (and limit (>= match-count limit)) (cleanup)
          (match (vim.fn.searchpos
                   pattern (.. opts (if match-at-curpos? "c" "")) stopline)
            [0 _] (cleanup)
            [line col &as pos]
            (if ft-search? (do (++ match-count) pos)
                (match (skip-to-fold-edge!)
                  :moved-the-cursor (recur false)
                  :not-in-fold
                  (if (or vim.wo.wrap (<= left-bound col right-bound))  ; = on-screen
                    (do (++ match-count) pos)
                    (match (skip-to-next-in-window-pos!)
                      :moved-the-cursor (recur true)  ; true, as we might be _on_ a match
                      _ (cleanup))))))))))


(fn highlight-cursor [?pos]
  "The cursor is down on the command line during `getchar`,
so we set a temporary highlight on it to see where we are."
  (let [[line col &as pos] (or ?pos (get-cursor-pos))
        ; nil means the cursor is on an empty line.
        ch-at-curpos (or (char-at-pos pos {}) " ")]  ; char-at-pos needs 1,1-idx
    ; (Ab)using extmarks even here, to be able to highlight the cursor on empty lines too.
    (hl:set-extmark (dec line)
                    (dec col)
                    {:virt_text [[ch-at-curpos hl.group.cursor]]
                     :virt_text_pos "overlay"
                     :hl_mode "combine"})))


(fn handle-interrupted-change-op! []
  "Return to previous mode and adjust cursor position if needed after
interrupted change-operation."
  ; Cannot really follow why, but this cleanup is needed here, else
  ; there is a short blink on the command line (the cursor jumps ahead,
  ; as if something has been echoed and then erased immediately).
  (echo "")
  (let [curcol (vim.fn.col ".")
        endcol (vim.fn.col "$")
        ?right (if (and (not vim.o.insertmode) (> curcol 1) (< curcol endcol))
                 "<RIGHT>"
                  "")]
    (-> (replace-keycodes (.. "<C-\\><C-G>" ?right))  ; :h CTRL-\_CTRL-G
        (api.nvim_feedkeys :n true))))


(fn doau-when-exists [event]
  (when (vim.fn.exists (.. :#User# event))
    (vim.cmd (.. "doautocmd <nomodeline> User " event))))


(fn enter [mode]
  (doau-when-exists :LightspeedEnter)
  (match mode
    :sx (doau-when-exists :LightspeedSxEnter)
    :ft (doau-when-exists :LightspeedFtEnter)))


; Note: One of the main purpose of these macros, besides wrapping cleanup stuff,
; is to enforce and encapsulate the requirement that tail-positioned "exit"
; forms in `match` blocks should always return nil. (Interop with side-effecting
; VimL functions can be dangerous, they might return 0 for example, like
; `feedkey`, and with that they can screw up Fennel match forms in a breeze,
; resulting in misterious bugs, so it's better to be paranoid.)
(macro exit-template [mode early-exit? ...]
  `(do
     ; Be sure _not_ to call the macro twice accidentally,
     ; `handle-interrupted-change-op!` might move the cursor twice then!
     ,(when early-exit?
        `(when (change-operation?) (handle-interrupted-change-op!)))
     ; Putting the form here, after the change-op handler, because it might feed
     ; keys too. (Is that a valid problem? Change operation can only be
     ; interrupted by <c-c> or <esc> I guess...)
     ; (Note: I'd like to understand why it's necessary to wrap the varargs in
     ; an additional `do` - else only sees the first item.)
     (do ,...)
     ,(match mode
        :sx `(doau-when-exists :LightspeedSxLeave)
        :ft `(doau-when-exists :LightspeedFtLeave))
     (doau-when-exists :LightspeedLeave)
     nil))


(macro with-highlight-cleanup [...]
  `(let [res# (do ,...)]
     (hl:cleanup)
     res#))


(fn get-input [?timeout]
  (let [esc-keycode 27
        char-available? #(not= 0 (vim.fn.getchar 1))
        getchar-timeout #(when (vim.wait ?timeout char-available? 100)
                           (vim.fn.getchar 0))
        ; pcall for handling <C-c>.
        (ok? ch) (pcall (if ?timeout getchar-timeout vim.fn.getchar))]
    ; <esc> should cleanly exit anytime.
    (when (and ok? (not= ch esc-keycode))
      (if (= (type ch) :number) (vim.fn.nr2char ch) ch))))


; repeat.vim support
; (see the docs in the script:
; https://github.com/tpope/vim-repeat/blob/master/autoload/repeat.vim)
(fn set-dot-repeat [cmd ?count]
  (when (operator-pending-mode?)
    (local op vim.v.operator)
    (when (not= op :y)
      (let [change (when (= op :c)
                     ; We cannot getreg('.') at this point, since the
                     ; change has not happened yet - therefore the
                     ; below hack (thx Sneak).
                     (replace-keycodes "<c-r>.<esc>"))
            seq (.. op (or ?count "") cmd (or change ""))]
        ; Using pcall, since vim-repeat might not be installed.
        ; Use the same register for the repeated operation.
        (pcall vim.fn.repeat#setreg seq vim.v.register)
        ; Note: we're feeding count inside the seq itself.
        (pcall vim.fn.repeat#set seq -1)))))


(fn get-plug-key [kind reverse? x-or-t? repeat-invoc]
  (.. "<Plug>Lightspeed_"
      (match repeat-invoc :dot "dotrepeat_" _ "")
      ; Forcing to bools with not-not, as those values can be nils.
      (match [kind (not (not reverse?)) (not (not x-or-t?))]
        [:ft false false] "f" 
        [:ft true  false] "F"
        [:ft false true ] "t"
        [:ft true  true ] "T"
        [:sx false false] "s"
        [:sx true  false] "S"
        [:sx false true ] "x"
        [:sx true  true ] "X")))


; 1-character search ///1

; Precursory remarks: do not readily succumb to the siren call of
; generality here. 1- and 2-character search, according to this plugin's
; concept, are specialized tools for different purposes, and their
; behaviour is different enough to validate a separate implementation,
; without an encompassing wrapper function. There are annoying overlaps
; for sure, but this is a case where mindless DRY-ing (if that makes
; sense) might ultimately introduce more complexity and maintenance
; issues than it absorbs, I guess. Time might prove me wrong.

; State for 1-character search that is persisted between invocations.
(local ft {:state {:instant {:in nil
                             :stack []}
                   :dot {:in nil}
                   :cold {:in nil
                          :reverse? nil
                          :t-mode? nil}}})

(fn ft.go [self reverse? t-mode? repeat-invoc]
  "Entry point for 1-character search."
  (let [instant-repeat? (or (= repeat-invoc :instant)
                            (= repeat-invoc :reverted-instant))
        reverted-instant-repeat? (= repeat-invoc :reverted-instant)
        cold-repeat? (= repeat-invoc :cold)
        dot-repeat? (= repeat-invoc :dot)
        ; After a reverted repeat , we highlight the next n matches as always,
        ; as per `limit_ft_matches`, but _stay_ where we are. (We have already
        ; moved the cursor back to the previous position on the stack!)
        count (if reverted-instant-repeat? 0 vim.v.count1)
        ; In case of instant-repeating t/T (this includes reverting), we have to
        ; skip the first match, else we would find the same target in front of
        ; us again and again, and be stuck. (Instant-repeat implies that we are
        ; right before a target, so it's fine to simply increment `count` here.)
        count (if (and instant-repeat? t-mode?) (inc count) count)
        [repeat-key revert-key] (->> [opts.instant_repeat_fwd_key
                                      opts.instant_repeat_bwd_key]
                                     (map replace-keycodes))
        op-mode? (operator-pending-mode?)
        dot-repeatable-op? (dot-repeatable-operation?)
        cmd-for-dot-repeat (replace-keycodes
                             (get-plug-key :ft reverse? t-mode? :dot))
        reset-instant-state #(set self.state.instant {:in nil :stack []})]

    (macro exit [...] `(exit-template :ft false ,...))
    (macro exit-early [...] `(exit-template :ft true ,...))

    (when-not instant-repeat? (enter :ft))
    (when-not repeat-invoc
      (echo "")
      (highlight-cursor)
      (vim.cmd :redraw))

    (match (if instant-repeat? self.state.instant.in
               dot-repeat? self.state.dot.in
               cold-repeat? self.state.cold.in
               (match (or (with-highlight-cleanup (get-input))
                          (exit-early))
                 "\r" (or self.state.cold.in
                          (exit-early (echo-no-prev-search)))
                 in in))
      in1
      (do
        (when-not repeat-invoc
          (set self.state.cold {:in in1 : reverse? : t-mode?}))  ; endnote #1
        (var jump-pos nil)
        (var match-count 0)
        (let [next-pos (vim.fn.searchpos "\\_." (if reverse? :nWb :nW))
              pattern (.. "\\V" (in1:gsub "\\" "\\\\"))
              ; When instant-repeating, keep highlighting the same one group of
              ; matches, and do not shift until reaching the end of the group -
              ; it is less disorienting if the "snake" does not move
              ; continuously, on every repeat.
              stack-size (length self.state.instant.stack)
              group-limit (or opts.limit_ft_matches 0)
              eaten-up (if (= group-limit 0) 0 (% stack-size group-limit))
              remaining (- group-limit eaten-up)
              ; Switch if no remaining matches.
              to-be-highlighted (if (= remaining 0) group-limit remaining)
              limit (+ count to-be-highlighted)]
          (each [[line col &as pos]
                 (onscreen-match-positions pattern reverse? {:ft-search? true : limit})]
            ; If we've started cold-repeating t/T from right before a match,
            ; then skip that match (endnote #2).
            (when-not (and (= match-count 0) cold-repeat? t-mode? (same-pos? pos next-pos))
              (if (<= match-count (dec count)) (set jump-pos pos)
                  (when-not op-mode?
                    (hl:add-hl hl.group.one-char-match (dec line) (dec col) col)))
              (++ match-count))))
        (if (and (not reverted-instant-repeat?)
                 (or (= match-count 0)
                     ; Just the character in front of us, but no more matches.
                     (and (= match-count 1) instant-repeat? t-mode?)))
            (exit-early (reset-instant-state)
                        (echo-not-found in1))
            (do
              (when-not reverted-instant-repeat?
                (jump-to!* jump-pos
                           {:add-to-jumplist? (not instant-repeat?)
                            :after (when t-mode?
                                     (push-cursor! (if reverse? :fwd :bwd)))
                            : reverse?
                            :inclusive-motion? true}))  ; like the native f/t
              (if op-mode? (exit (when dot-repeatable-op?
                                   (set self.state.dot {:in in1})
                                   (set-dot-repeat cmd-for-dot-repeat count)))
                  (do
                    (highlight-cursor)
                    (vim.cmd :redraw)
                    (match (or (with-highlight-cleanup
                                 (get-input opts.exit_after_idle_msecs.unlabeled))
                               (exit (reset-instant-state)))
                      in2
                      (let [mode (if (= (vim.fn.mode) :n) :n :x)  ; vim-cutlass compat (#28)
                            repeat? (or (= (vim.fn.maparg in2 mode)
                                           (get-plug-key :ft false t-mode?))
                                        (= in2 repeat-key))
                            revert? (or (= (vim.fn.maparg in2 mode)
                                           (get-plug-key :ft true t-mode?))
                                        (= in2 revert-key))
                            do-instant-repeat? (or repeat? revert?)]
                        (if do-instant-repeat?
                            (do
                              (when-not instant-repeat? (set self.state.instant.in in1))
                              (if revert? (match (table.remove self.state.instant.stack)
                                            ; Moving the cursor!
                                            old-pos (vim.fn.cursor old-pos))
                                  repeat? (table.insert self.state.instant.stack
                                                        (get-cursor-pos)))
                              (ft:go reverse? t-mode? (if revert?
                                                          :reverted-instant
                                                          :instant)))
                            (exit (reset-instant-state)
                                  (vim.fn.feedkeys in2 :i)))))))))))))


; The workaround described in :h lightspeed-custom-ft-repeat-mappings used these fields.
(let [deprec-msg [["ligthspeed.nvim" :Question]
                  [": You're trying to access deprecated fields in the lightspeed.ft table.\n"]
                  ["There are dedicated <Plug> keys available for native-like "]
                  [";" :Visual] [" and "] ["," :Visual] [" functionality now.\n"]
                  ["See "] [":h lightspeed-custom-mappings" :Visual] ["."]]]
  (setmetatable ft {:__index (fn [t k]
                               (when (one-of? k :instant-repeat? :prev-t-like?)
                                 (api.nvim_echo deprec-msg true {})))}))


; 2-character search ///1

; Helpers ///

(fn highlight-unique-chars [reverse?]
  (let [unique-chars {}
        [left-bound right-bound] (get-horizontal-bounds {:match-width 2})
        [curline curcol] (get-cursor-pos)]
    (each [lnum line (pairs (get-onscreen-lines {: reverse? :skip-folds? true}))]
      (let [on-curline? (= lnum curline)
            startcol (if (and on-curline? (not reverse?)) (inc curcol) 1)
            endcol (if (and on-curline? reverse?) (dec curcol) (length line))]
        (for [col startcol endcol]
          (when (or vim.wo.wrap (and (>= col left-bound) (<= col right-bound)))
            ; TODO: multibyte?
            (let [ch (line:sub col col)]
              (tset unique-chars ch (match (. unique-chars ch)
                                      pos-already-there false
                                      _ [lnum col])))))))
    (each [ch pos (pairs unique-chars)]
      (match pos  ; don't try to destructure `false` values above
        [lnum col] 
        (hl:add-hl hl.group.unique-ch (dec lnum) (dec col) col)))))


(fn get-targets [ch1 reverse?]
  "Return a table that will store the positions and other metadata of
all on-screen pairs that start with `ch1`, in the order of discovery
(i.e., distance from cursor).

A target element in its final form has the following fields (the latter
ones might be set by subsequent functions):

   pos         : [line col]
   pair        : [char char]
  ?overlapped? : bool
  ?label       : char
  ?label-state : 'active-primary' | 'active-secondary' | 'inactive'
  ?beacon      : [col [char hl-group] ?[char hl-group]]
"
  (local targets [])
  (var prev-match {})
  (var added-prev-match? nil)
  (let [pattern (.. "\\V\\C"                ; force matching case (for the moment)
                    (ch1:gsub "\\" "\\\\")  ; backslash still needs to be escaped for \V
                    "\\_.")]                ; match anything (including EOL) after ch1
    (each [[line col &as pos] (onscreen-match-positions pattern reverse? {})]
      (let [ch2 (or (char-at-pos pos {:char-offset 1})
                    "\r")  ; <enter> is the expected input for line breaks
            overlaps-prev-match? (and (= line prev-match.line)
                                      (= col ((if reverse? dec inc) prev-match.col)))
            same-char-triplet? (and overlaps-prev-match? (= ch2 prev-match.ch2))
            overlaps-prev-target? (and overlaps-prev-match? added-prev-match?)]
        (set prev-match {: line : col : ch2})
        (if (and same-char-triplet?
                 (or added-prev-match?  ; the 2nd 'xx' in 'xxx' is _always_ skipped
                     opts.match_only_the_start_of_same_char_seqs))
            (set added-prev-match? false)
            (let [target {: pos :pair [ch1 ch2]}]
              (when overlaps-prev-target?
                ; The _label_ should remain visible in any case.
                (tset (if reverse? (last targets) target) :overlapped? true))
              (table.insert targets target)
              (set added-prev-match? true)))))
    (when (next targets) targets)))


(fn populate-sublists [targets]
  "Populate a sub-table in `targets` containing lists that allow for
easy iteration through each subset of targets with a given successor
char separately."
  (tset targets :sublists {})
  (each [_ {:pair [_ ch2] &as target} (ipairs targets)]
    (when-not (. targets :sublists ch2)
      (tset targets :sublists ch2 []))
    (table.insert (. targets :sublists ch2) target)))


; Note: Sets the :autojump? field of the sublist the first time called.
(fn get-labels [sublist]
  (match sublist.autojump?
    true opts.safe_labels
    false opts.labels
    nil (do (tset sublist :autojump?
                 ; We _never_ want to autojump in OP mode, since that
                 ; would execute the operation without allowing us to
                 ; select a labeled target.
                 (and (not (operator-pending-mode?))
                      (<= (dec (length sublist))
                          (length opts.safe_labels))))
            (get-labels sublist))))


(fn set-labels [targets]
  "Assign label characters to targets. Note: `label` is a fixed,
implicit attribute of the target - whether and how it should actually be
displayed depends on `label-state`."
  (each [_ sublist (pairs targets.sublists)]
    (when (> (length sublist) 1)  ; else we'll jump automatically anyway
      (let [labels (get-labels sublist)]
        (each [i target (ipairs sublist)]
          (tset target :label
                (when-not (and sublist.autojump? (= i 1))
                  ; In case of `autojump?`, the i-th label is assigned
                  ; to the i+1th position (we skipped the first one).
                  (match (% (if sublist.autojump? (dec i) i) (length labels))
                    ; 1-indexing is not a great match for modulo arithmetic.
                    0 (last labels)
                    n (. labels n)))))))))


(fn set-label-states-for-sublist [sublist {: group-offset}]
  (let [labels (get-labels sublist)
        |labels| (length labels)
        offset (* group-offset |labels|)
        primary-start (+ offset (if sublist.autojump? 2 1))
        primary-end (+ primary-start (dec |labels|))
        secondary-end (+ primary-end |labels|)]
    (each [i target (ipairs sublist)]
      (tset target :label-state
            (when (. target :label)
              (if (or (< i primary-start) (> i secondary-end)) :inactive
                  (<= i primary-end) :active-primary
                  :active-secondary))))))


(fn set-label-states [targets]
  (each [_ sublist (pairs targets.sublists)]
    (set-label-states-for-sublist sublist {:group-offset 0})))


(fn set-shortcuts-and-populate-shortcuts-map [targets]
  "Set the `shortcut?` attribute of those targets where the label can be
used right after the first input (see Glossary), while populating a
sub-table containing label-target k-v pairs for these targets."
  (tset targets :shortcuts {})
  (let [potential-2nd-inputs (collect [ch2 _ (pairs targets.sublists)]
                               (values ch2 true))
        labels-used-up-as-shortcut {}]
    (each [_ {: label : label-state &as target} (ipairs targets)]
      ; Shortcutting only makes sense for the first match group,
      ; we're ignoring the distant one(s).
      (when (= label-state :active-primary)
        (when-not (or (. potential-2nd-inputs label)
                      (. labels-used-up-as-shortcut label))
          (tset target :shortcut? true)
          (tset targets.shortcuts label target)
          (tset labels-used-up-as-shortcut label true))))))


; The first principle of Lightspeed's interface is that after a beacon appears
; on screen, it should not change in appearance unless strictly necessary. That
; is because the brain has to be given as much time as possible to familiarize
; itself with the beacon, and any sudden change would only be confusing and
; ultimately counterproductive.
; Therefore, labels will not change into "shortcuts" after the second input,
; even though, in a way, it would be logical. If a label was part of an
; overlapped beacon, it will not get transformed back into a regular label when
; the first column gets uncovered. For the same reason, the masked characters
; will not disappear before the labels in the second round. The look of a beacon
; only changes with group switching, when its active/passive or
; primary/secondary state changes.
(fn set-beacon [{:pos [_ col] :pair [ch1 ch2]
                 : label : label-state : overlapped? : shortcut?
                 &as target}
                repeat?]
  (let [[ch1 ch2] (map #(or (. opts.substitute_chars $) $) [ch1 ch2])]
    (set target.beacon
         (match label-state
           ; No label-state = unlabeled match. (Note: there are no unlabeled
           ; matches when repeating, as we have the full input sequence
           ; available then, and we will have jumped to the first match already
           ; if it was on the "winning" sublist.)
           nil (if overlapped? [(inc col) [ch2 hl.group.unlabeled-match]]
                   [col [(.. ch1 ch2) hl.group.unlabeled-match]])

           ; Note: `repeat?` is also mutually exclusive with both `overlapped?`
           ; and `shortcut?`.
           :active-primary
           (if repeat? [(inc col) [label hl.group.label]]
               shortcut? (if overlapped?
                             [(inc col) [label hl.group.shortcut-overlapped]]
                             [col [ch2 hl.group.masked-ch] [label hl.group.shortcut]])
               overlapped? [(inc col) [label hl.group.label-overlapped]]
               [col [ch2 hl.group.masked-ch] [label hl.group.label]])

           :active-secondary
           (if repeat? [(inc col) [label hl.group.label-distant]]
               overlapped? [(inc col) [label hl.group.label-distant-overlapped]]
               [col [ch2 hl.group.masked-ch] [label hl.group.label-distant]])

           :inactive nil))))


(fn set-beacons [target-list {: repeat?}]
  (each [_ target (ipairs target-list)]
    (set-beacon target repeat?)))


(fn light-up-beacons [target-list]
  (each [_ {:pos [line _] : beacon} (ipairs target-list)]
    (match beacon  ; might be nil, if the state is inactive
      [startcol chunk1 ?chunk2]
      (hl:set-extmark (dec line)
                      (dec startcol)
                      {:virt_text [chunk1 ?chunk2]
                       :virt_text_pos "overlay"}))))


(fn get-target-with-active-primary-label [target-list input]
  (var res nil)
  (each [_ {: label : label-state &as target} (ipairs target-list)
         :until res]
    (when (and (= label input) (= label-state :active-primary))
      (set res target)))
  res)


(fn ignore-input-until-timeout [char-to-ignore]
  (match (get-input opts.jump_on_partial_input_safety_timeout)
    input (when (not= input char-to-ignore)
            (vim.fn.feedkeys input :i))))


; //> Helpers

; State for 2-character search that is persisted between invocations.
(local sx {:state {:dot {:in1 nil
                         :in2 nil
                         :in3 nil
                         ; Note: we don't need `reverse?`, since we
                         ; hardcode it into the dot-repeat command.
                         :x-mode? nil}
                   ; Enter-repeat uses these inputs too.
                   :cold {:in1 nil
                          :in2 nil
                          :reverse? nil
                          :x-mode? nil}}})

(fn sx.go [self reverse? invoked-in-x-mode? repeat-invoc]
  "Entry point for 2-character search."
  (let [dot-repeat? (= repeat-invoc :dot)
        cold-repeat? (= repeat-invoc :cold)
        op-mode? (operator-pending-mode?)
        change-op? (change-operation?)
        delete-op? (delete-operation?)
        dot-repeatable-op? (dot-repeatable-operation?)
        x-mode-prefix-key (replace-keycodes
                            (or opts.x_mode_prefix_key
                                opts.full_inclusive_prefix_key))  ; deprecated
        [cycle-fwd-key cycle-bwd-key] (->> [opts.cycle_group_fwd_key
                                            opts.cycle_group_bwd_key]
                                           (map replace-keycodes))
        cmd-for-dot-repeat (replace-keycodes
                             (get-plug-key :sx reverse? invoked-in-x-mode? :dot))]

    ; Top-level vars

    (var x-mode? invoked-in-x-mode?)
    (var enter-repeat? nil)
    (var new-search? nil)

    ; Helpers ///

    (macro exit [...]
      `(exit-template :sx false
                      (do (when dot-repeatable-op?
                            (set-dot-repeat cmd-for-dot-repeat))
                          ,...)))

    (macro exit-early [...] `(exit-template :sx true ,...))

    (macro with-highlight-chores [...]
      `(do (when (and opts.grey_out_search_area (not cold-repeat?))
             (grey-out-search-area reverse?))
           (do ,...)
           (highlight-cursor)
           (vim.cmd :redraw)))

    (fn get-first-input []
      (if dot-repeat? (do (set x-mode? self.state.dot.x-mode?)
                          self.state.dot.in1)
          cold-repeat? self.state.cold.in1
          (match (or (with-highlight-cleanup (get-input))
                     (exit-early))
            ; Here we can handle any other modifier key as "zeroth" input,
            ; if the need arises (e.g. regex search).
            in0 (do (match in0
                      "\r" (set enter-repeat? true)
                      x-mode-prefix-key (set x-mode? true))
                    (var res in0)
                    (when (and x-mode? (not invoked-in-x-mode?))
                      ; Get the "true" first input then.
                      (match (or (get-input)
                                 (exit-early))
                        "\r" (set enter-repeat? true)
                        in0* (set res in0*)))
                    (set new-search? (not (or repeat-invoc enter-repeat?)))
                    (if enter-repeat? (or self.state.cold.in1
                                          (exit-early (echo-no-prev-search)))
                        res)))))

    ; No need to pass in `in1` every time once we have it, so let's curry this.
    (fn update-state* [in1]
      (fn [{: cold : dot}]
        (when new-search?  ; not dot-repeat? / cold-repeat? / enter-repeat?
          (when cold
            (set self.state.cold (doto cold
                                   (tset :in1 in1)
                                   (tset :x-mode? x-mode?)
                                   (tset :reverse? reverse?))))
          (when dot
            (when dot-repeatable-op?
              (set self.state.dot (doto dot
                                    (tset :in1 in1)
                                    (tset :x-mode? x-mode?))))))))

    ; `first-jump?` should only be persisted inside `to` (i.e. the
    ; lifetime is one invocation), and better be managed by the function
    ; itself, so setting up a closure here.
    (local jump-to!
           (do (var first-jump? true)
               (fn [target]
                 (jump-to!* target
                            {:add-to-jumplist? first-jump?
                             :after (when x-mode?
                                      (push-cursor! :fwd)
                                      (when reverse? (push-cursor! :fwd)))
                             : reverse?
                             :inclusive-motion? (and x-mode? (not reverse?))})
                 (set first-jump? false))))

    ; Jumping based on partial input is nice, but it's annoying that we
    ; don't see the actual changes right away (we are staying in the main
    ; function, waiting for another input, so that we can introduce a safety
    ; timespan to ignore the character in the next column).
    ; Therefore we need to provide visual feedback, to tell the user that the
    ; target has been found, and they can continue editing.
    (fn highlight-new-curpos-and-op-area [from-pos]  ; 1,1
      (let [forced-motion (string.sub (vim.fn.mode :t) -1)
            blockwise? (= forced-motion (replace-keycodes "<c-v>"))
            to-pos (get-cursor-pos)  ; 1,1
            ; Preliminary boundaries of the highlighted - operated - area
            ; (forced-motion might affect these).
            [startline startcol &as start] (if reverse? to-pos from-pos)
            [_ endcol &as end] (if reverse? from-pos to-pos)
            ; In OP-mode, the cursor always ends up at the beginning of the
            ; operated area, that might differ from the targeted position.
            ; (Caveat: linewise works as if there would be no forcing modifier.)
            new-curpos (if op-mode? (if blockwise?  ; get the top/leftmost corner
                                        [startline (min startcol endcol)]
                                        start)
                           to-pos)]
        (when-not change-op?  ; then we're entering insert mode anyway (couldn't move away)
          (highlight-cursor new-curpos))
        (when op-mode?
          (highlight-range hl.group.pending-op-area (map dec start) (map dec end)
                           {: forced-motion
                            :inclusive-motion? (and x-mode? (not reverse?))}))
        (vim.cmd :redraw)))

    (fn get-sublist [targets ch]
      (match (. targets.sublists ch)  ; note: if not nil, a sublist is never []
        sublist
        ; Handling cold-repeating backward x-motion. (The same problem as with
        ; instant-repeating t/T - we might have to skip the first target. In
        ; case of x, this is irrelevant in the forward direction, since in
        ; OP-mode - when we would land right before the target - we always have
        ; to choose a label.)
        (let [[{:pos [line col]} & rest] sublist
              target-tail [line (inc col)]
              prev-pos (vim.fn.searchpos "\\_." :nWb)
              cursor-touches-first-target? (same-pos? target-tail prev-pos)]
          (if (and cold-repeat? x-mode? reverse? cursor-touches-first-target?)
              (when-not (empty? rest) rest)
              sublist))))

    ; In case of "cold" repeat, we just wait for another input and
    ; unconditionally feed it, to be able to highlight the remaining
    ; matches in a clean way.
    (fn after-cold-repeat [target-list]
      (when-not op-mode?
        (with-highlight-chores
          (each [_ {:pos [line col]} (ipairs target-list)]
            (hl:add-hl hl.group.one-char-match (dec line) (dec col) (inc col))))
        (-> (or (with-highlight-cleanup 
                  (get-input opts.exit_after_idle_msecs.unlabeled))
                "")
            (vim.fn.feedkeys :i))))

    (fn get-last-input [sublist]
      ((fn recur [group-offset initial-invoc?]
         (set-beacons sublist {:repeat? enter-repeat?})
         (with-highlight-chores (light-up-beacons sublist))
         (match (with-highlight-cleanup
                  (get-input (when initial-invoc?
                               opts.exit_after_idle_msecs.labeled)))
           input
           (if sublist.autojump?
               [input 0]

               (one-of? input cycle-fwd-key cycle-bwd-key)
               (let [labels (get-labels sublist)
                     num-of-groups (ceil (/ (length sublist) (length labels)))
                     max-offset (dec num-of-groups)
                     group-offset* (-> group-offset
                                       ((match input cycle-fwd-key inc _ dec))
                                       (clamp 0 max-offset))]
                 (set-label-states-for-sublist
                   sublist {:group-offset group-offset*})
                 (recur group-offset*))

               [input group-offset])))
       0 true))

    ; //> Helpers

    ; After all the stage-setting, here comes the main action you've all been
    ; waiting for:

    (enter :sx)
    (when-not repeat-invoc
      (echo "")  ; clean up the command line
      (with-highlight-chores
        (when opts.highlight_unique_chars
          (highlight-unique-chars reverse?))))

    (match (get-first-input)
      in1
      (let [from-pos (get-cursor-pos)
            update-state (update-state* in1)
            prev-in2 (if (or cold-repeat? enter-repeat?) self.state.cold.in2
                         dot-repeat? self.state.dot.in2)]
        (match (or (get-targets in1 reverse?)
                   (exit-early (echo-not-found (.. in1 (or prev-in2 "")))))
          [{:pair [_ ch2] &as only} nil]
          (if (or new-search? (= ch2 prev-in2))
              (exit (update-state
                      ; Note: In OP mode, we _always_ use `opts.labels` (no
                      ; autojump), so the problem of non-deterministic label
                      ; assignment does not arise - that is, for dot-repeat, we
                      ; can safely save either an item from `opts.labels` or the
                      ; actual user input from here on.
                      {:cold {:in2 ch2} :dot {:in2 ch2 :in3 (. opts.labels 1)}})
                    (jump-to! only.pos)
                    (when new-search?  ; i.e. user is actually typing the pattern
                      (with-highlight-cleanup
                        (highlight-new-curpos-and-op-area from-pos)
                        (ignore-input-until-timeout ch2))))
              (exit-early (echo-not-found (.. in1 prev-in2))))

          targets
          (do
            (doto targets
              (populate-sublists)
              (set-labels)
              (set-label-states))
            (when new-search?
              (doto targets
                (set-shortcuts-and-populate-shortcuts-map)
                (set-beacons {:repeat? false}))
              (with-highlight-chores (light-up-beacons targets)))
            (match (or prev-in2
                       (with-highlight-cleanup (get-input))
                       (exit-early))
              in2
              (match (?. targets.shortcuts in2)
                {:pair [_ ch2] &as shortcut}
                (exit (update-state {:cold {:in2 ch2} :dot {:in2 ch2 :in3 in2}})
                      (jump-to! shortcut.pos))

                _
                (do
                  (update-state {:cold {: in2}})  ; endnote #1
                  (match (or (get-sublist targets in2)
                             (exit-early (echo-not-found (.. in1 in2))))
                    [only nil]
                    (exit (update-state {:dot {: in2 :in3 (. opts.labels 1)}})
                          (jump-to! only.pos))

                    sublist
                    (let [[first & rest] sublist
                          autojump? sublist.autojump?]
                      (when (or autojump? cold-repeat?)
                        (jump-to! first.pos))
                      (if cold-repeat? (exit (after-cold-repeat rest))
                          (match (or (when (and dot-repeat? self.state.dot.in3)  ; endnote #3
                                       [self.state.dot.in3 0])
                                     (get-last-input sublist)
                                     (exit-early))
                            [in3 group-offset]
                            (match (or (get-target-with-active-primary-label sublist in3)
                                       (if autojump?
                                           (exit (vim.fn.feedkeys in3 :i))
                                           (exit-early)))
                              target
                              (exit (update-state
                                      {:dot {: in2 :in3 (if (> group-offset 0) nil in3)}})  ; endnote #3
                                    (jump-to! target.pos))))))))))))))))


; Handling editor options ///1

; Quick-and-dirty code, we'll tidy up/expand/rethink this section later.

; We will probably expose this table in the future, as an `opts` field.
(local temporary-editor-opts {:vim.wo.conceallevel 0
                              :vim.wo.scrolloff 0})

(local saved-editor-opts {})


(fn save-editor-opts []
  (each [opt _ (pairs temporary-editor-opts)]
    (let [[_ scope name] (vim.split opt "." true)]
      (tset saved-editor-opts
            opt
            ; Workaround for Nvim #13964.
            (if (= opt :vim.wo.scrolloff) (api.nvim_eval "&l:scrolloff")
                ; (= opt :vim.o.scrolloff) (api.nvim_eval "&scrolloff")
                ; (= opt :vim.wo.sidescrolloff) (api.nvim_eval "&l:sidescrolloff")
                ; (= opt :vim.o.sidescrolloff) (api.nvim_eval "&sidescrolloff")
                (. _G.vim scope name))))))


(fn set-editor-opts [opts]
  (each [opt val (pairs opts)]
    (let [[_ scope name] (vim.split opt "." true)]
      (tset _G.vim scope name val))))


(fn set-temporary-editor-opts []
  (set-editor-opts temporary-editor-opts))


(fn restore-editor-opts []
  (set-editor-opts saved-editor-opts))


; Mappings ///1

(fn set-plug-keys []
  (local plug-keys
    [
     ; params: reverse? [x-mode?] [repeat-invoc]
     ["<Plug>Lightspeed_s" "sx:go(false)"]
     ["<Plug>Lightspeed_S" "sx:go(true)"]
     ["<Plug>Lightspeed_x" "sx:go(false, true)"]
     ["<Plug>Lightspeed_X" "sx:go(true, true)"]

     ; params: reverse? [t-mode?] [repeat-invoc]
     ["<Plug>Lightspeed_f" "ft:go(false)"]
     ["<Plug>Lightspeed_F" "ft:go(true)"]
     ["<Plug>Lightspeed_t" "ft:go(false, true)"]
     ["<Plug>Lightspeed_T" "ft:go(true, true)"]

     ; "cold" repeat (;/,-like) (note: we should not start the name with ft_ or sx_ if using `hasmapto`)
     ["<Plug>Lightspeed_;_sx" "sx:go(require'lightspeed'.sx.state.cold['reverse?'], require'lightspeed'.sx.state.cold['x-mode?'], 'cold')"]
     ["<Plug>Lightspeed_,_sx" "sx:go(not require'lightspeed'.sx.state.cold['reverse?'], require'lightspeed'.sx.state.cold['x-mode?'], 'cold')"]

     ["<Plug>Lightspeed_;_ft" "ft:go(require'lightspeed'.ft.state.cold['reverse?'], require'lightspeed'.ft.state.cold['t-mode?'], 'cold')"]
     ["<Plug>Lightspeed_,_ft" "ft:go(not require'lightspeed'.ft.state.cold['reverse?'], require'lightspeed'.ft.state.cold['t-mode?'], 'cold')"]

     ; TODO: let these repeat the last one
     ["<Plug>Lightspeed_;" "ft:go(require'lightspeed'.ft.state.cold['reverse?'], require'lightspeed'.ft.state.cold['t-mode?'], 'cold')"]
     ["<Plug>Lightspeed_," "ft:go(not require'lightspeed'.ft.state.cold['reverse?'], require'lightspeed'.ft.state.cold['t-mode?'], 'cold')"]
     ])

  (each [_ [lhs rhs-call] (ipairs plug-keys)]
    (each [_ mode (ipairs [:n :x :o])]
      (api.nvim_set_keymap mode lhs (.. "<cmd>lua require'lightspeed'." rhs-call "<cr>")
                           {:noremap true :silent true})))
  
  ; Just for our convenience, to be used here in the script.
  (each [_ [lhs rhs-call]
         (ipairs
           [["<Plug>Lightspeed_dotrepeat_s" "sx:go(false, false, 'dot')"]
            ["<Plug>Lightspeed_dotrepeat_S" "sx:go(true, false, 'dot')"]
            ["<Plug>Lightspeed_dotrepeat_x" "sx:go(false, true, 'dot')"]
            ["<Plug>Lightspeed_dotrepeat_X" "sx:go(true, true, 'dot')"]

            ["<Plug>Lightspeed_dotrepeat_f" "ft:go(false, false, 'dot')"]
            ["<Plug>Lightspeed_dotrepeat_F" "ft:go(true, false, 'dot')"]
            ["<Plug>Lightspeed_dotrepeat_t" "ft:go(false, true, 'dot')"]
            ["<Plug>Lightspeed_dotrepeat_T" "ft:go(true, true, 'dot')"]])]
    (api.nvim_set_keymap :o lhs (.. "<cmd>lua require'lightspeed'." rhs-call "<cr>")
                         {:noremap true :silent true})))


(fn set-default-keymaps []
  (local default-keymaps
    [[:n "s" "<Plug>Lightspeed_s"]
     [:n "S" "<Plug>Lightspeed_S"]
     [:x "s" "<Plug>Lightspeed_s"]
     [:x "S" "<Plug>Lightspeed_S"]
     [:o "z" "<Plug>Lightspeed_s"]
     [:o "Z" "<Plug>Lightspeed_S"]

     [:o "x" "<Plug>Lightspeed_x"]
     [:o "X" "<Plug>Lightspeed_X"]

     [:n "f" "<Plug>Lightspeed_f"]
     [:n "F" "<Plug>Lightspeed_F"]
     [:x "f" "<Plug>Lightspeed_f"]
     [:x "F" "<Plug>Lightspeed_F"]
     [:o "f" "<Plug>Lightspeed_f"]
     [:o "F" "<Plug>Lightspeed_F"]

     [:n "t" "<Plug>Lightspeed_t"]
     [:n "T" "<Plug>Lightspeed_T"]
     [:x "t" "<Plug>Lightspeed_t"]
     [:x "T" "<Plug>Lightspeed_T"]
     [:o "t" "<Plug>Lightspeed_t"]
     [:o "T" "<Plug>Lightspeed_T"]])

  (each [_ [mode lhs rhs] (ipairs default-keymaps)]
    (when (and
            ; User has not mapped (a keyseq starting with) `lhs` to something else.
            (= (vim.fn.mapcheck lhs mode) "")
            ; User has not already mapped something to the <Plug> key.
            (= (vim.fn.hasmapto rhs mode) 0))
      (api.nvim_set_keymap mode lhs rhs {:silent true}))))


; Init ///1

(init-highlight)
(set-plug-keys)
(set-default-keymaps)

; Colorscheme plugins might clear out our highlight definitions, without
; defining their own.
(vim.cmd
  "augroup lightspeed_reinit_highlight
   autocmd!
   autocmd ColorScheme * lua require'lightspeed'.init_highlight()
   augroup end")

(vim.cmd
  "augroup lightspeed_editor_opts
   autocmd!
   autocmd User LightspeedEnter lua require'lightspeed'.save_editor_opts(); require'lightspeed'.set_temporary_editor_opts()
   autocmd User LightspeedLeave lua require'lightspeed'.restore_editor_opts()
   augroup end")


; Endnotes ///1

; (1) This should be saved right here, because the repeated search might
;     have a match anyway.

; (2) This is in fact coupled with `onscreen-match-positions`, so it's
;     _much_ cleaner to implement the logic here than in `count`. In
;     that case, we would have to duplicate the whole logic of
;     transforming the input to the actual pattern (that might get
;     arbitrarily complex with future enhancements).

; (3) If the operation spanned beyond the first group, we clear
;     self.state.dot.in3, and will ask for input. It makes no practical
;     sense to dot-repeat such an operation exactly as it went ("delete
;     again till the 27th match..."?). The most intuitive/logical
;     behaviour is repeating as <enter>-repeat in these cases, prompting
;     for a target label again.
;     Note: `save-state-for-repeat` only executes on new searches - if
;     we're currently dot-repeating, then it won't overwrite the state,
;     we can safely get `self.state.dot.in3` for the previous value.


; Module ///1

{: opts
 : setup
 : ft
 : sx

 :save_editor_opts save-editor-opts
 :set_temporary_editor_opts set-temporary-editor-opts
 :restore_editor_opts restore-editor-opts

 :init_highlight init-highlight
 :set_default_keymaps set-default-keymaps}


; vim: foldmethod=marker foldmarker=///,//>
