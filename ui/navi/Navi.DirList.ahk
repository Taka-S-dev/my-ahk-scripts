#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.DirList.ahk
; Description:  ルート配下の全フォルダ・全ファイルを平らなリストで表示するリストビュー
;               - フォルダインデックスは NaviFilter のものを使い回す
;               - ファイルインデックスは files モードに入ったとき fd（なければ loop files）で作る
;               - あいまい一致（入力した文字が間を空けて順に含まれていれば一致）
;               - 'word は続けて並んだものだけに一致
;               - 名前での一致を優先し、スコア順に並べる
;               - Ctrl+E でツリーと切り替え、Shift+Tab でフォルダ ↔ ファイル（状態は Navi.ini に保存）
; Usage:        NaviDirList.Init(naviRef) を Navi.Init() から、
;               NaviDirList.Build(gui, tv) を Navi.Show() の TreeView 作成直後に呼ぶ
; ==============================================================================

class NaviDirList {
    static _navi := ""
    static Active := false          ; true=リストビュー表示中 / false=ツリー表示中
    static Kind := "dirs"           ; "dirs"=フォルダ一覧 / "files"=ファイル一覧
    static _rows := []              ; 表示中の行番号 → 絶対パス
    static _dirs := []              ; 表示中の行番号 → 親のパス（ルートから下。ルート直下は ""）
    static _names := []             ; 表示中の行番号 → 名前（セルは空にして _DrawRow が描く）
    static _hl := []                ; 表示中の行番号 → 一致した文字の位置 { name: Map(位置), dir: Map(位置) }
    static _matchCount := 0         ; 直近の一致件数（表示上限を超えた分も含む）
    static _total := 0              ; 絞り込む前の件数（ステータスバーに「一致 / 全体」で出す）
    static _pending := ""           ; 再入中に届いた最新クエリ
    static _pendingSet := false
    static _running := false
    static _navCond := ""           ; Up / PgUp / PgDn ホットキーの HotIf 条件
    static _lvHwnd := 0
    static _drawHandler := ""       ; 選択行を塗る WM_NOTIFY ハンドラー
    static _listCond := ""          ; Shift+Tab ホットキーの HotIf 条件
    static _netAllowed := Map()     ; 一覧を作ってよいと答えたネットワーク上のルート（Navi を閉じるまで覚える）
    static _asking := false         ; 確認ダイアログを出している間

    ; --- ファイルインデックス（Show のたびに作り直す）---
    static _FileIndex := []
    static _FileIndexedRoot := ""
    static _FileIndexTruncated := false  ; 上限・タイムアウトで打ち切ったか
    static _FilePid := 0
    static _FileTmp := ""
    static _FileRoot := ""
    static _FileStartMs := 0
    static _FilePollCb := ""
    static FILE_INDEX_MAX := 200000        ; 集めるファイルの上限
    static FILE_INDEX_TIMEOUT_MS := 20000  ; fd を打ち切るまでの時間

    ; 直前の結果の使い回し用（クエリを後ろに伸ばしただけなら前回の一致から絞り込む）
    static _cacheIndex := ""
    static _cacheRoot := ""
    static _cacheQuery := ""
    static _cacheRels := []

    static DISPLAY_CAP := 500       ; 表示する最大行数
    static DEBOUNCE_MS := 80        ; 入力から絞り込みまでの待ち時間
    static PAGE_ROWS := 10          ; PgUp / PgDn で移動する行数

    static Init(naviRef) {
        this._navi := naviRef
        this.Active := (IniRead(naviRef.IniPath, "Settings", "DirListMode", "0") == "1")
        this.Kind := (IniRead(naviRef.IniPath, "Settings", "DirListKind", "dirs") == "files") ? "files" : "dirs"
        this._navCond := (*) => this._IsFilterNav()
        this._listCond := (*) => (this.Active && naviRef.GuiObj && WinActive("ahk_id " naviRef.GuiObj.Hwnd))
    }

    /**
     * TreeView と同じ位置・大きさで ListView を作り、リストビュー用ホットキーを登録する
     */
    static Build(gui, tv) {
        nv := this._navi
        tv.GetPos(&x, &y, &w, &h)
        ; 0x8=LVS_SHOWSELALWAYS（フィルター欄にフォーカスがあっても選択行を表示）
        ; 0x40=LVS_SHARESIMAGELISTS（TreeView と共有する ImageList を破棄させない）
        lv := gui.Add("ListView", Format("x{} y{} w{} h{} vDirList -Multi NoSortHdr +0x8 +0x40 +LV0x10000", x, y, w, h),
            ["パス"])
        lv.Visible := false
        lv.SetImageList(nv._ILHandle, 1)
        nv._ApplyExplorerTheme(lv)
        ; ツリーの行の高さを一覧の行の高さにそろえ、表示を切り替えても行の間隔が変わらないようにする
        ; （一覧の行の高さは広げられないので、ツリーの方を合わせる）
        lv.Add(, "x")
        rect := Buffer(16, 0)  ; LVIR_BOUNDS=0
        SendMessage(0x100E, 0, rect.Ptr, lv)  ; LVM_GETITEMRECT
        rowH := NumGet(rect, 12, "int") - NumGet(rect, 4, "int")
        lv.Delete()
        if (rowH > 0)
            SendMessage(0x111B, rowH, 0, tv)  ; TVM_SETITEMHEIGHT
        this._lvHwnd := lv.Hwnd
        if (this._drawHandler == "") {
            this._drawHandler := (w, l, m, h) => this._OnCustomDraw(l)
            OnMessage(nv.WM_NOTIFY, this._drawHandler)
        }
        this._SizeColumns(w)
        lv.OnEvent("DoubleClick", (*) => nv._HandleActivate())
        this._rows := []
        this._ResetCache()
        ; ファイルは前回開いたときから増減しているかもしれないので作り直させる
        this.CancelFileIndex()
        this._FileIndex := []
        this._FileIndexedRoot := ""

        HotIf(this._navCond)
        Hotkey("Up",   (*) => this.Move(-1), "On")
        Hotkey("PgUp", (*) => this.Move(-this.PAGE_ROWS), "On")
        Hotkey("PgDn", (*) => this.Move(this.PAGE_ROWS), "On")
        HotIf(this._listCond)
        Hotkey("+Tab", (*) => this.ToggleKind(), "On")
        HotIf()
    }

    /**
     * 指定した種類の一覧を開く（ツリー表示中なら一覧に切り替える）
     * kind: "dirs" / "files"
     */
    static ShowList(kind) {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this.Kind != kind) {
            this.Kind := kind
            IniWrite(kind, nv.IniPath, "Settings", "DirListKind")
            this._ResetCache()
        }
        if (this.Active) {
            this.ApplyCurrent()
            nv.GuiObj["TreeFilter"].Focus()
        } else {
            this._SetActive(true)
        }
    }

    /** フォルダ一覧 ↔ ファイル一覧を切り替える（Shift+Tab） */
    static ToggleKind() {
        nv := this._navi
        this.Kind := (this.Kind == "files") ? "dirs" : "files"
        IniWrite(this.Kind, nv.IniPath, "Settings", "DirListKind")
        this._ResetCache()
        this.ApplyCurrent()
    }

    ; フィルター欄にフォーカスがあるリストビュー表示中だけ Up / PgUp / PgDn を横取りする
    static _IsFilterNav() {
        nv := this._navi
        if !(this.Active && nv.GuiObj && WinActive("ahk_id " nv.GuiObj.Hwnd))
            return false
        focus := 0
        try focus := DllCall("user32\GetFocus", "ptr")
        return focus != 0 && focus = nv.GuiObj._treeFilterHwnd
    }

    static _ResetCache() {
        this._cacheIndex := ""
        this._cacheRoot := ""
        this._cacheQuery := ""
        this._cacheRels := []
    }

    ; ==============================================================================
    ; 表示切り替え
    ; ==============================================================================

    /**
     * ツリー ↔ リストを切り替える（Ctrl+E）
     * リストからツリーへ戻るときは、リストで選んでいたフォルダをツリーで選択する
     */
    static Toggle() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this.Active)
            this.RevealInTree()
        else
            this._SetActive(true)
    }

    /**
     * リストで選んでいるフォルダをツリーで表示する（リスト上の → / Ctrl+L）
     * フィルターを消してツリーを作り直し、そのフォルダまで展開して選択する
     */
    static RevealInTree() {
        nv := this._navi
        if !(this.Active && nv.GuiObj && WinExist(nv.GuiObj))
            return
        path := this.SelectedPath()
        this._SetActive(false)
        tv := nv.GuiObj["FolderTree"]
        filter := nv.GuiObj["TreeFilter"]
        if (path != "") {
            rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
            filter.Value := ""
            if (rootPath != "")
                nv._RefreshTree(tv, rootPath, false)
            nv._FocusPath(tv, path)
        } else {
            ; 選択がなければ入力中のキーワードをツリーのフィルターとして引き継ぐ
            NaviFilter.ApplyTreeFilter(filter.Value)
            tv.Focus()
        }
    }

    static _SetActive(on) {
        nv := this._navi
        if (on && NaviBrowse.Active)
            NaviBrowse.Exit(false)
        this.Active := on
        IniWrite(on ? "1" : "0", nv.IniPath, "Settings", "DirListMode")
        this.ApplyVisibility()
        if (on) {
            this.Apply(nv.GuiObj["TreeFilter"].Value)
            nv.GuiObj["TreeFilter"].Focus()
        }
        NaviBreadcrumb.Refresh()
        nv._UpdateStatusBar()
    }

    /** Active に合わせて TreeView / ListView の表示を切り替える */
    static ApplyVisibility() {
        nv := this._navi
        nv.GuiObj["FolderTree"].Visible := !this.Active
        nv.GuiObj["DirList"].Visible := this.Active
    }

    /**
     * WM_NOTIFY → NM_CUSTOMDRAW
     * - 行はルートから下のパスを 1 行で描く（_DrawRow）
     * - 入力欄にフォーカスがある間も選択行を薄い青で見せる
     *   （テーマのままだとフォーカスのないリストの選択行はほぼ見えない灰色になる）
     * 他の WM_NOTIFY ハンドラーと共存するため、このリスト以外の通知には "" を返す
     */
    static _OnCustomDraw(l) {
        if (NumGet(l, 0, "ptr") != this._lvHwnd || NumGet(l, A_PtrSize * 2, "int") != -12)  ; NM_CUSTOMDRAW
            return
        x64 := (A_PtrSize = 8)
        stage := NumGet(l, x64 ? 24 : 12, "uint")
        if (stage = 0x1)          ; CDDS_PREPAINT
            return 0x20           ; CDRF_NOTIFYITEMDRAW
        if (stage = 0x10001) {    ; CDDS_ITEMPREPAINT: 列ごとの通知を頼む
            NaviTheme.PaintSoftSelection(l, this._lvHwnd)
            return 0x22           ; CDRF_NOTIFYSUBITEMDRAW | CDRF_NEWFONT
        }
        if (stage = 0x30001) {    ; CDDS_SUBITEM | CDDS_ITEMPREPAINT
            subItem := NumGet(l, x64 ? 88 : 56, "int")  ; NMLVCUSTOMDRAW.iSubItem
            NumPut("uint", NaviTheme.BGR(NaviTheme.TEXT), l, x64 ? 80 : 48)  ; clrText
            NaviTheme.PaintSoftSelection(l, this._lvHwnd)
            ; セルは文字を空にしてあり、背景・選択色・アイコンだけ既定で描かせて文字は後で描く
            ; （一致した文字だけ色を変えるため。メッセージの行は文字が入っているのでそのまま）
            return 0x12  ; CDRF_NOTIFYPOSTPAINT | CDRF_NEWFONT
        }
        if (stage = 0x30002) {    ; CDDS_SUBITEM | CDDS_ITEMPOSTPAINT
            this._DrawRow(l)
            return 0
        }
        return 0
    }

    /**
     * 行を描く。位置は既定の描き方と同じ（ラベルの枠の左端から SM_CXEDGE）
     */
    static _DrawRow(l) {
        x64 := (A_PtrSize = 8)
        row := NumGet(l, x64 ? 56 : 36, "uptr") + 1
        if (row < 1 || row > this._names.Length)
            return
        rect := Buffer(16, 0)
        NumPut("int", 2, rect, 0)  ; LVIR_LABEL
        if !SendMessage(0x100E, row - 1, rect.Ptr, this._lvHwnd)  ; LVM_GETITEMRECT
            return
        hdc := NumGet(l, x64 ? 32 : 16, "ptr")
        left := NumGet(rect, 0, "int") + SysGet(45)  ; SM_CXEDGE
        right := NumGet(rect, 8, "int") - SysGet(45)
        oldFont := DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", SendMessage(0x0031, 0, 0, this._lvHwnd), "ptr")  ; WM_GETFONT
        DllCall("gdi32\SetBkMode", "ptr", hdc, "int", 1)  ; TRANSPARENT
        top := NumGet(rect, 4, "int"), bottom := NumGet(rect, 12, "int")
        this._DrawPath(hdc, left, right, top, bottom, this._dirs[row], this._names[row], this._hl[row])
        DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldFont)
    }

    /**
     * ルートから下のパスを 1 行で描く（fzf と同じく、親子が 1 本でつながって読める）
     * 親のパス（と区切りの \）は TEXT_MUTED、名前は TEXT。絞り込みの語に一致した文字は ACCENT にして、
     * なぜ一覧に出たのかを見せる。見えている文字がそのまま絞り込みの対象と同じになる
     * 入りきらないときは名前を残し、親のパスの頭を … にする（右端で切ると名前が見えなくなるため）
     */
    static _DrawPath(hdc, left, right, top, bottom, dir, name, hl) {
        Ext(s) {
            size := Buffer(8, 0)
            DllCall("gdi32\GetTextExtentPoint32W", "ptr", hdc, "wstr", s, "int", StrLen(s), "ptr", size)
            return NumGet(size, 0, "int")
        }
        if (dir == "") {
            this._DrawRuns(hdc, left, right, top, bottom, name, NaviTheme.TEXT, hl.name)
            return
        }
        avail := right - left
        tail := "\" . name
        shown := dir, skip := 0, prefix := ""
        if (Ext(dir . tail) > avail) {
            ; 親のパスの頭から削り、… を付けて収まるところを探す（収まらなければ名前だけ）
            prefix := "…"
            while (skip < StrLen(dir) && Ext(prefix . SubStr(dir, skip + 1) . tail) > avail)
                skip++
            shown := SubStr(dir, skip + 1)
        }
        if (shown == "") {
            this._DrawRuns(hdc, left, right, top, bottom, name, NaviTheme.TEXT, hl.name)
            return
        }
        dirHl := Map()
        for pos in hl.dir
            if (pos > skip)
                dirHl[pos - skip] := true
        x := left
        if (prefix != "")
            x := this._DrawRuns(hdc, x, right, top, bottom, prefix, NaviTheme.TEXT_MUTED, Map())
        x := this._DrawRuns(hdc, x, right, top, bottom, shown . "\", NaviTheme.TEXT_MUTED, dirHl)
        this._DrawRuns(hdc, x, right, top, bottom, name, NaviTheme.TEXT, hl.name)
    }

    /**
     * text を left から右へ描く。hl にある位置（1 始まり）の文字は ACCENT、それ以外は color
     * 入りきらないときは末尾を … にする。描き終えた右端の x を返す
     */
    static _DrawRuns(hdc, left, right, top, bottom, text, color, hl) {
        Ext(s) {
            size := Buffer(8, 0)
            DllCall("gdi32\GetTextExtentPoint32W", "ptr", hdc, "wstr", s, "int", StrLen(s), "ptr", size)
            return NumGet(size, 0, "int")
        }
        Draw(s, x, c) {
            r := Buffer(16, 0)
            NumPut("int", x, r, 0), NumPut("int", top, r, 4), NumPut("int", right, r, 8), NumPut("int", bottom, r, 12)
            DllCall("gdi32\SetTextColor", "ptr", hdc, "uint", NaviTheme.BGR(c))
            DllCall("user32\DrawTextW", "ptr", hdc, "wstr", s, "int", -1, "ptr", r, "uint", 0x20 | 0x4 | 0x800 | 0x100)  ; SINGLELINE | VCENTER | NOPREFIX | NOCLIP
            return x + Ext(s)
        }
        ; 同じ色の続きをまとめて描く（1 文字ずつ描くより字間が自然になる）
        runs := []
        i := 1, n := StrLen(text)
        while (i <= n) {
            on := hl.Has(i), j := i
            while (j < n && hl.Has(j + 1) == on)
                j++
            runs.Push({ s: SubStr(text, i, j - i + 1), on: on })
            i := j + 1
        }
        ell := "…"
        limit := (left + Ext(text) > right) ? right - Ext(ell) : right
        x := left
        for seg in runs {
            c := seg.on ? NaviTheme.ACCENT : color
            if (x + Ext(seg.s) <= limit) {
                x := Draw(seg.s, x, c)
                continue
            }
            ; 入りきらない: 入る所まで描いて … を付ける
            fit := ""
            for ch in StrSplit(seg.s) {
                if (x + Ext(fit . ch) > limit)
                    break
                fit .= ch
            }
            if (fit != "")
                x := Draw(fit, x, c)
            return Draw(ell, x, color)
        }
        return x
    }

    ; ウィンドウリサイズ時に TreeView と同じ位置・大きさへ合わせる
    static OnResize(w, h) {
        nv := this._navi
        try {
            nv.GuiObj["DirList"].Move(, , w, h)
            this._SizeColumns(w)
        }
    }

    static _SizeColumns(w) {
        lv := this._navi.GuiObj["DirList"]
        ; 縦スクロールバー分を引いて横スクロールバーが出ないようにする
        inner := Max(100, w - SysGet(2) - 4)  ; SM_CXVSCROLL
        lv.ModifyCol(1, inner)
    }

    ; ==============================================================================
    ; 選択・移動
    ; ==============================================================================

    /** 選択中の行の絶対パス（選択がない・一致なしの行なら ""） */
    static SelectedPath() {
        nv := this._navi
        try {
            row := nv.GuiObj["DirList"].GetNext(0)
            if (row > 0 && row <= this._rows.Length)
                return this._rows[row]
        }
        return ""
    }

    /** 選択行を delta 行ずらす（フィルター欄にフォーカスを残したまま） */
    static Move(delta) {
        nv := this._navi
        lv := nv.GuiObj["DirList"]
        n := this._rows.Length
        if (n == 0)
            return
        cur := lv.GetNext(0)
        nxt := (cur == 0) ? 1 : Min(Max(cur + delta, 1), n)
        lv.Modify(0, "-Select")
        lv.Modify(nxt, "Select Focus Vis")
    }

    /**
     * マウス位置の行を選択してそのパスを返す（右クリックメニュー用）
     * RButton ホットキーがクリックを握りつぶすため、選択は自前でヒットテストする
     */
    static SelectRowAtMouse() {
        lv := this._navi.GuiObj["DirList"]
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "ptr", pt)
        DllCall("user32\ScreenToClient", "ptr", lv.Hwnd, "ptr", pt)
        ; LVHITTESTINFO: POINT pt, UINT flags, int iItem, int iSubItem, int iGroup
        hit := Buffer(24, 0)
        NumPut("int", NumGet(pt, 0, "int"), "int", NumGet(pt, 4, "int"), hit, 0)
        idx := SendMessage(0x1012, 0, hit.Ptr, lv)  ; LVM_HITTEST
        if (idx < 0 || idx >= 0xFFFFFFFF || idx + 1 > this._rows.Length)
            return ""
        lv.Modify(0, "-Select")
        lv.Modify(idx + 1, "Select Focus")
        return this._rows[idx + 1]
    }

    /**
     * 選択行の名前欄の右上をスクリーン座標で返す（コンテキストメニューの表示位置）
     * 選択がなければ false
     */
    static GetMenuPoint(&x, &y) {
        lv := this._navi.GuiObj["DirList"]
        row := lv.GetNext(0)
        if (row == 0)
            return false
        rect := Buffer(16, 0)
        NumPut("int", 2, rect, 0)  ; LVIR_LABEL
        if !SendMessage(0x100E, row - 1, rect.Ptr, lv)  ; LVM_GETITEMRECT
            return false
        pt := Buffer(8, 0)
        NumPut("int", NumGet(rect, 8, "int"), "int", NumGet(rect, 4, "int"), pt, 0)
        DllCall("user32\ClientToScreen", "ptr", lv.Hwnd, "ptr", pt)
        x := NumGet(pt, 0, "int")
        y := NumGet(pt, 4, "int")
        return true
    }

    ; ==============================================================================
    ; 絞り込み
    ; ==============================================================================

    /**
     * query で一覧を作り直す
     * 再入防止: 実行中に届いたクエリは保留し、終わってから最新のものだけ処理する
     */
    static Apply(query) {
        if (this._running) {
            this._pending := query
            this._pendingSet := true
            return
        }
        this._running := true
        this._pendingSet := false
        try {
            this._ApplyCore(query)
        } catch Any {
            ; GUI 破棄など想定内の例外は無視する
        } finally {
            this._running := false
            if (this._pendingSet) {
                q := this._pending
                this._pending := ""
                this._pendingSet := false
                SetTimer(() => this.Apply(q), -1)
            }
        }
    }

    ; 現在のフィルター欄の内容で作り直す（インデックス完成時・ルート変更時のコールバック用）
    static ApplyCurrent() {
        nv := this._navi
        if (this.Active && nv.GuiObj && WinExist(nv.GuiObj))
            this.Apply(nv.GuiObj["TreeFilter"].Value)
    }

    static _ApplyCore(query) {
        nv := this._navi
        if !(this.Active && nv.GuiObj && WinExist(nv.GuiObj))
            return
        rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
        if (rootPath == "") {
            this._ShowMessage("ルートが選択されていません")
            return
        }
        isFiles := (this.Kind == "files")
        ; まだ集めていないネットワーク上のルートは、配下を全部読みに行く前に確かめる
        built := isFiles ? (this._FileIndexedRoot == rootPath || (this._FilePid != 0 && this._FileRoot == rootPath))
            : (NaviFilter._IndexedRoot == rootPath)
        if (!built && !this._ConfirmNetwork(rootPath))
            return
        if (isFiles) {
            if (!built)
                this._ShowSlowNotice(rootPath, "ファイル")
            if !this._EnsureFileIndex(rootPath) {
                this._ShowMessage("ファイルを集めています…")
                return
            }
            index := this._FileIndex
        } else {
            if (NaviFilter._IndexedRoot != rootPath) {
                this._ShowSlowNotice(rootPath, "フォルダ")
                onReady := () => SetTimer(() => this.ApplyCurrent(), -1)
                if !NaviFilter._EnsureIndex(rootPath, onReady) {
                    this._ShowMessage("フォルダを集めています…")
                    return
                }
            }
            index := NaviFilter._FolderIndex
        }
        rootBase := RTrim(rootPath, "\")
        terms := this._ParseQuery(query)
        rels := this._Candidates(rootBase, query, index)

        matched := []
        top := this._Rank(rels, terms, matched)
        this._cacheIndex := index
        this._cacheRoot := rootBase
        this._cacheQuery := query
        this._cacheRels := matched
        this._matchCount := matched.Length
        this._total := index.Length

        if (matched.Length == 0) {
            this._ShowMessage("(一致なし)")
            return
        }
        lv := nv.GuiObj["DirList"]
        lv.Opt("-Redraw")
        lv.Delete()
        this._rows := []
        this._dirs := []
        this._names := []
        this._hl := []
        for rel in top {
            SplitPath(rel, &name, &dir)
            ; セルの文字は _DrawRow が一致した文字に色を付けて描くので、一覧には空で入れる
            lv.Add(isFiles ? nv._GetFileIconStr(name) : "Icon1", "", "")
            this._rows.Push(rootBase . "\" . rel)
            this._names.Push(name)
            this._dirs.Push(dir)
            this._hl.Push(this._MatchSpans(rel, name, dir, terms))
        }
        lv.Modify(1, "Select Focus Vis")
        lv.Opt("+Redraw")
        nv._UpdateStatusBar()
    }

    /**
     * rels を terms で絞り込み、表示する上位の相対パスを返す
     * 一致したものはすべて matched に積む（次の絞り込みの候補に使う）
     */
    static _Rank(rels, terms, matched) {
        ; スコア → パス長の 2 段のバケツに振り分ける
        ; （数万件をまとめて Sort() にかけると並べ替え用の文字列作りだけで数百 ms かかるため、
        ;   表示する上位の分だけを後で並べる）
        buckets := Map()  ; score → Map(パス長 → [rel, ...])
        for rel in rels {
            SplitPath(rel, &name)
            score := this._Score(rel, name, terms)
            if (score < 0)
                continue
            matched.Push(rel)
            byLen := buckets.Has(score) ? buckets[score] : (buckets[score] := Map())
            len := StrLen(rel)
            (byLen.Has(len) ? byLen[len] : (byLen[len] := [])).Push(rel)
        }
        return this._TopRels(buckets)
    }

    /**
     * バケツから「スコア降順・パス長昇順・パス昇順」で最大 DISPLAY_CAP 件を取り出す
     * Map は整数キーを昇順で列挙するので、スコアは逆順にたどる
     */
    static _TopRels(buckets) {
        scores := []
        for score in buckets
            scores.Push(score)
        top := []
        i := scores.Length
        while (i >= 1 && top.Length < this.DISPLAY_CAP) {
            for len, arr in buckets[scores[i]] {
                if (arr.Length > 1) {
                    joined := ""
                    for rel in arr
                        joined .= rel . "`n"
                    arr := StrSplit(Sort(RTrim(joined, "`n")), "`n")
                }
                for rel in arr {
                    top.Push(rel)
                    if (top.Length >= this.DISPLAY_CAP)
                        return top
                }
            }
            i--
        }
        return top
    }

    ; 一覧を空にして 1 行だけメッセージを出す（選択しても何も起きない行）
    /**
     * ネットワーク上のルートなら、一覧を作る前に確認する。「いいえ」ならツリーに戻して false を返す
     * 一覧は配下のフォルダ（ファイル）をすべて読むので、ファイルサーバーに負荷がかかり時間もかかる
     */
    static _ConfirmNetwork(rootPath) {
        if (this._netAllowed.Has(StrLower(rootPath)) || !NaviFilter.IsOnNetwork(rootPath))
            return true
        if (this._asking)  ; 確認中に届いた入力による作り直しは、答えが出るまで止めておく
            return false
        nv := this._navi
        this._ShowMessage("ネットワーク上のフォルダです")
        if (this.AskNetwork(rootPath, (this.Kind == "files") ? "ファイル" : "フォルダ") == 1)
            return true
        if (this.Active && nv.GuiObj && WinExist(nv.GuiObj)) {
            this._SetActive(false)
            nv.GuiObj["FolderTree"].Focus()
        }
        return false
    }

    /**
     * ネットワーク上のルートの配下（what: "フォルダ" など）を全部読んでよいか聞く。一覧とツリーの絞り込みで共用
     * 1 = 読んでよい（Navi を閉じるまで覚える。ネットワーク上でなければ聞かずに 1）/ 0 = いいえ / -1 = ほかで確認中
     */
    static AskNetwork(rootPath, what) {
        if (this._netAllowed.Has(StrLower(rootPath)) || !NaviFilter.IsOnNetwork(rootPath))
            return 1
        if (this._asking)
            return -1
        this._asking := true
        ans := this._navi.MsgBoxOver(this._navi.GuiObj
            , rootPath . "`n`nはネットワーク上のフォルダです。絞り込みや一覧のために配下の" . what
            . "をすべて読むため、サーバーに負荷がかかり、時間もかかります。`n`n読みますか？"
            , "Navi", "YesNo Icon! Default2")
        this._asking := false
        if (ans != "Yes")
            return 0
        this._netAllowed[StrLower(rootPath)] := true
        return 1
    }

    /** ネットワーク上のルートを読んでよいか・読まないかの答えを忘れる（Navi を閉じたとき） */
    static ForgetNetworkAnswers() {
        this._netAllowed := Map()
        NaviFilter._netDenied := Map()
    }

    /**
     * fd を使わずに集めるとき（数秒止まる）は、止まる前に理由と待てばよいことを一覧に出しておく
     * fd で集めるときは裏で集めるので何も出さない（_ApplyCore が「集めています…」を出す）
     */
    static _ShowSlowNotice(rootPath, what) {
        reason := NaviFd.SlowWalkReason(rootPath)
        if (reason == "")
            return
        this._ShowMessage(what . "を集めています（" . reason . "、少し時間がかかります）")
        ; この後は集め終わるまで止まるので、今のうちに描かせる
        DllCall("user32\UpdateWindow", "ptr", this._lvHwnd)
        try DllCall("user32\UpdateWindow", "ptr", this._navi.GuiObj._sbRef.Hwnd)
    }

    static _ShowMessage(msg) {
        nv := this._navi
        lv := nv.GuiObj["DirList"]
        lv.Delete()
        lv.Add(, msg)
        this._rows := []
        this._dirs := []
        this._names := []
        this._hl := []
        this._matchCount := 0
        nv._UpdateStatusBar()
    }

    /**
     * 絞り込みの対象にするルートからの相対パス一覧
     * 前回と同じインデックス・ルートで、前回のクエリを後ろに伸ばしただけなら
     * 一致は前回の一致の中にしかないので、そこから絞り込む
     */
    static _Candidates(rootBase, query, index) {
        if (this._cacheIndex != "" && this._cacheIndex == index
            && this._cacheRoot = rootBase && this._cacheQuery != ""
            && SubStr(query, 1, StrLen(this._cacheQuery)) = this._cacheQuery)
            return this._cacheRels
        rels := []
        prefixLen := StrLen(rootBase) + 2
        for fullPath in index {
            rel := SubStr(fullPath, prefixLen)
            if (rel != "")
                rels.Push(rel)
        }
        return rels
    }

    /**
     * クエリを語に分ける（半角・全角スペース区切り、すべての語に一致したものを残す）
     * 各語: { lit: 語そのもの, exact: 'で始まるか, re: あいまい一致用の正規表現 }
     */
    static _ParseQuery(query) {
        terms := []
        for raw in StrSplit(StrReplace(Trim(query), "　", " "), " ") {
            exact := (SubStr(raw, 1, 1) == "'")
            lit := exact ? SubStr(raw, 2) : raw
            if (lit == "")
                continue
            ; re: あいまい一致の判定用 / cap: 同じ一致で各文字の位置も取る用（文字ごとにグループにする）
            re := "i)", cap := "i)"
            for i, ch in StrSplit(lit) {
                if (i > 1)
                    re .= ".*?", cap .= ".*?"
                esc := InStr("\.*?+[](){}|^$", ch) ? "\" . ch : ch
                re .= esc, cap .= "(" . esc . ")"
            }
            terms.Push({ lit: lit, exact: exact, re: re, cap: cap })
        }
        return terms
    }

    /**
     * 相対パスのスコア（どれかの語に一致しなければ -1、語がなければ 0）
     * 語ごとに次の段で評価し、上の段ほど高い（段どうしの値の範囲は重ならない）
     * name はフォルダ名またはファイル名
     *   名前に続けて含む     500〜700（先頭一致と、名前の余りが少ないほど高い）
     *   パスに続けて含む     450
     *   名前にあいまい一致   300〜400（文字の間が詰まっているほど高い）
     *   パスにあいまい一致   100〜199
     * パス全体を 1 行で見せるので、パスのどこかに続けて当たっている行を、名前に飛び飛びに当たった行より上にする
     */
    static _Score(rel, name, terms) {
        total := 0
        for t in terms {
            litLen := StrLen(t.lit)
            if (p := InStr(name, t.lit)) {
                s := 500 + Max(0, 100 - (StrLen(name) - litLen)) + (p == 1 ? 100 : 0)
            } else if (InStr(rel, t.lit)) {
                s := 450
            } else if (!t.exact && RegExMatch(name, t.re, &m)) {
                s := 300 + Max(0, 100 - 3 * (m.Len - litLen))
            } else if (!t.exact && RegExMatch(rel, t.re, &m)) {
                s := 100 + Max(0, 99 - (m.Len - litLen))
            } else {
                return -1
            }
            total += s
        }
        return total
    }

    /**
     * 行の名前と親のパスのどの文字が語に一致したか（_Score と同じ順で、点数に使った一致の位置）
     * 返り値 { name: Map(名前の中の位置), dir: Map(親のパスの中の位置) }
     */
    static _MatchSpans(rel, name, dir, terms) {
        hl := { name: Map(), dir: Map() }
        nameOff := (dir != "") ? StrLen(dir) + 1 : 0  ; rel の中で名前が始まる手前の文字数
        Mark(pos) {
            if (pos > nameOff)
                hl.name[pos - nameOff] := true
            else if (pos <= StrLen(dir))
                hl.dir[pos] := true
        }
        for t in terms {
            litLen := StrLen(t.lit)
            if (p := InStr(name, t.lit)) {
                loop litLen
                    hl.name[p + A_Index - 1] := true
            } else if (p := InStr(rel, t.lit)) {
                loop litLen
                    Mark(p + A_Index - 1)
            } else if (!t.exact && RegExMatch(name, t.cap, &m)) {
                loop m.Count
                    hl.name[m.Pos[A_Index]] := true
            } else if (!t.exact && RegExMatch(rel, t.cap, &m)) {
                loop m.Count
                    Mark(m.Pos[A_Index])
            }
        }
        return hl
    }

    /** ステータスバー左側: 今の一覧と件数 */
    static StatusText() {
        kind := (this.Kind == "files") ? " ファイル一覧" : " フォルダ一覧"
        ; 絞り込み中は「一致 / 全体」にして、絞り込みがどれだけ効いているかを見せる
        count := (this._matchCount < this._total)
            ? this._Num(this._matchCount) . " / " . this._Num(this._total) . " 件"
            : this._Num(this._matchCount) . " 件"
        if (this._matchCount > this.DISPLAY_CAP)
            count .= "（上位 " . this.DISPLAY_CAP . "）"  ; ステータスバーの左の欄に収まる長さにする
        if (this.Kind == "files" && this._FileIndexTruncated)
            count .= " ※打ち切り"
        return kind . "   " . count
    }

    ; 3 桁ごとにカンマを入れる
    static _Num(n) => RegExReplace(n, "\G\d+?(?=(\d{3})+$)", "$0,")

    /** ステータスバー右側: 操作の案内 */
    static StatusHints() {
        ; 入力欄の Space は検索の区切りなので、メニューのキー（Ctrl+Space）をここで示す
        return " Ctrl+Space メニュー     Shift+Tab 切替     Enter 開く     → ツリーで表示"
    }

    ; ==============================================================================
    ; ファイルインデックス
    ; ==============================================================================

    /**
     * rootPath のファイルインデックスを確保する
     * - 準備済み → true
     * - fd で非同期に集め始めた／集めている最中 → false（終わったら ApplyCurrent で作り直す）
     * - fd が使えない → loop files で上限まで同期に集めて true
     */
    static _EnsureFileIndex(rootPath) {
        if (this._FileIndexedRoot == rootPath)
            return true
        if (this._FilePid != 0 && this._FileRoot == rootPath)
            return false
        this.CancelFileIndex()
        ; ネットワークパスは fd を使わない（フォルダインデックスと同じくサーバー負荷対策）
        useFd := !NaviFilter.IsOnNetwork(rootPath)
            && (IniRead(NaviFd.IniPath, "Search", "UseFdForFilter", "1") != "0")
        fdPath := useFd ? NaviFd._FindFd() : ""
        if (fdPath != "" && this._StartFileIndexFd(rootPath, fdPath))
            return false
        this._BuildFileIndex(rootPath)
        return true
    }

    static _StartFileIndexFd(rootPath, fdPath) {
        nv := this._navi
        tmpFile := A_Temp . "\navi_files_" . A_TickCount . ".txt"
        ; 末尾 \ をエスケープ（C ランタイムの \" 解析対策）
        safeRoot := (SubStr(rootPath, -1) = "\") ? rootPath . "\" : rootPath
        ; 深さは制限しない（ツリーの絞り込みの深さとは別。深い所のファイルを見落とさないため）
        ; 集めすぎは件数（FILE_INDEX_MAX）と時間（FILE_INDEX_TIMEOUT_MS）の打ち切りで防ぎ、打ち切ったらステータスバーに出す
        cmd := '"' . fdPath . '" --type f --max-results ' . this.FILE_INDEX_MAX
            . ' --no-ignore-vcs --color never --absolute-path . "' . safeRoot . '"'
        pid := NaviFd._RunNoWindowToFile(cmd, tmpFile)
        if (pid = 0)
            return false
        this._FilePid := pid
        this._FileTmp := tmpFile
        this._FileRoot := rootPath
        this._FileStartMs := A_TickCount
        cb := () => this._PollFileIndex()
        this._FilePollCb := cb
        SetTimer(cb, 200)
        return true
    }

    ; fd の終了（またはタイムアウト）を待って結果を読み込む
    static _PollFileIndex() {
        if (this._FilePid != 0 && ProcessExist(this._FilePid)) {
            if ((A_TickCount - this._FileStartMs) <= this.FILE_INDEX_TIMEOUT_MS)
                return
            try ProcessClose(this._FilePid)
            this._FileIndexTruncated := true
        }
        SetTimer(this._FilePollCb, 0)
        this._FilePollCb := ""
        this._FilePid := 0
        index := []
        try {
            raw := FileRead(this._FileTmp, "UTF-8")
            for line in StrSplit(raw, "`n", "`r") {
                if (line != "")
                    index.Push(line)
            }
        }
        try FileDelete(this._FileTmp)
        this._FileTmp := ""
        if (index.Length >= this.FILE_INDEX_MAX)
            this._FileIndexTruncated := true
        this._FileIndex := index
        this._FileIndexedRoot := this._FileRoot
        this._FileRoot := ""
        ; 索引は一覧とツリーの絞り込み（ファイル）で共用。待っている方をやり直す
        SetTimer(() => (this.ApplyCurrent(), NaviFilter.ReapplyTree()), -1)
    }

    ; フォールバック（fd がない・ネットワーク上）: 上限まで同期に集める。範囲は fd と同じ（NaviFilter.WalkTree）
    static _BuildFileIndex(rootPath) {
        index := NaviFilter.WalkTree(rootPath, "F", this.FILE_INDEX_MAX)
        this._FileIndexTruncated := (index.Length >= this.FILE_INDEX_MAX)
        this._FileIndex := index
        this._FileIndexedRoot := rootPath
    }

    /** 実行中の fd を止める（Show のやり直し・GUI 破棄時） */
    static CancelFileIndex() {
        if (this._FilePollCb != "")
            SetTimer(this._FilePollCb, 0)
        this._FilePollCb := ""
        if (this._FilePid != 0) {
            try ProcessClose(this._FilePid)
            this._FilePid := 0
        }
        if (this._FileTmp != "") {
            try FileDelete(this._FileTmp)
            this._FileTmp := ""
        }
        this._FileRoot := ""
        this._FileIndexTruncated := false
    }
}
