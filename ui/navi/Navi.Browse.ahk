#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Browse.ahk
; Description:  3 列のブラウズ表示（yazi と同じ Miller columns）
;               - 左: 親フォルダの中身（今いるフォルダを選択） / 中央: 今いるフォルダ / 右: 選んだものの中身
;               - 右の列は、フォルダなら中身、テキストファイルなら先頭の内容、その他はサイズと更新日時
;               - → / l で入る、← / h で上がる（ルートの外やドライブの一覧まで上がれる）
;               - 入力欄で中央の列をあいまい一致で絞り込む。フォルダを移ると絞り込みは消える
;               - Ctrl+B でツリーと切り替え（状態は Navi.ini に保存）
; Usage:        NaviBrowse.Init(naviRef) を Navi.Init() から、
;               NaviBrowse.Build(gui, tv) を Navi.Show() の TreeView 作成後に呼ぶ
; ==============================================================================

class NaviBrowse {
    static _navi := ""
    static Active := false          ; true=3 列表示中
    static _cur := ""               ; 今いるフォルダ（"" はドライブの一覧）
    static _entries := []           ; 中央の列の全件 [{ name, path, isDir }]
    static _shown := []             ; 絞り込んで中央の列に出している分
    static _parentShown := []       ; 左の列に出している分
    static _previewShown := []      ; 右の列に出している分
    static _lastSel := Map()        ; フォルダ（小文字のパス）→ 最後に選んでいた名前
    static _previewTimer := ""
    static _drawHandler := ""
    static _roles := Map()          ; 一覧の hwnd → "parent" / "cur" / "preview"
    static _filling := false        ; 中央の列を作り直している間は右の列の更新を止める

    ; 中央（今いるフォルダ）を一番広くして主役にする（yazi の既定も中央が最も広い）
    static COL_LEFT := 0.20         ; 左の列の幅（全体に対する比率）
    static COL_MID  := 0.42         ; 中央の列の幅
    static GAP      := 4            ; 列の間の隙間 px
    static CAP      := 2000         ; 1 列に出す最大件数
    static PREVIEW_MAX_BYTES := 512 * 1024  ; これより大きいファイルは内容を読まない
    static PREVIEW_MAX_LINES := 300

    static Init(naviRef) {
        this._navi := naviRef
        this.Active := (IniRead(naviRef.IniPath, "Settings", "BrowseMode", "0") == "1")
    }

    ; ==============================================================================
    ; 部品の作成・配置
    ; ==============================================================================

    /** TreeView と同じ場所に 3 列の一覧と、右の列用のテキスト表示を作る */
    static Build(gui, tv) {
        nv := this._navi
        tv.GetPos(&x, &y, &w, &h)
        ; 0x8=LVS_SHOWSELALWAYS / 0x40=LVS_SHARESIMAGELISTS（ツリーのアイコンを共有） / LV0x10000=LVS_EX_DOUBLEBUFFER
        ; 見出しには列の役割（‹ 上の階層 / 今いるフォルダ / 中身 ›）をフォルダ名で出す
        ; 左右の列は SURFACE の面にして一段下げ、白い中央の列を主役にする
        opt := " -Multi NoSortHdr +0x8 +0x40 +LV0x10000"
        ; 左右の列は枠なしの面にし、スクロールバーは Layout で見える範囲の外へ切り落とす（ホイールでは動く）
        ; Tab ではツリーのときと同じく中央の列とルートのボタンだけを行き来させる（左右の列はマウスで使う）
        side := " Background" . NaviTheme.SURFACE . " -E0x200 -Tabstop"  ; -E0x200: WS_EX_CLIENTEDGE（枠）を外す
        parent  := gui.Add("ListView", "x" . x . " y" . y . " w100 h" . h . opt . side . " vBrowseParent", [""])
        cur     := gui.Add("ListView", "x" . x . " y" . y . " w100 h" . h . opt . " vBrowseCur", [""])
        preview := gui.Add("ListView", "x" . x . " y" . y . " w100 h" . h . opt . side . " vBrowsePreview", [""])
        gui.SetFont("s" . NaviTheme.SIZE_BODY . " norm c" . NaviTheme.TEXT, NaviTheme.FONT_MONO)
        text := gui.Add("Edit", "x" . x . " y" . y . " w100 h" . h . " ReadOnly -Wrap +HScroll +VScroll -Tabstop" . side . " vBrowseText")
        ; 中央の列の見出しだけ太字にする（フォントは見えない部品から借りる）
        NaviTheme.SetFont(gui, "heading")
        boldSrc := gui.Add("Text", "x0 y0 w0 h0 Hidden", "")
        hdr := SendMessage(0x101F, 0, 0, cur)  ; LVM_GETHEADER
        SendMessage(0x0030, SendMessage(0x0031, 0, 0, boldSrc), 1, hdr)  ; WM_SETFONT ← WM_GETFONT
        NaviTheme.SetFont(gui, "body")
        this._roles := Map()
        for role, lv in Map("parent", parent, "cur", cur, "preview", preview) {
            lv.SetImageList(nv._ILHandle, 1)
            ; エクスプローラーのテーマは背景色の指定と選択行の色を無視して自分の色で描くので、
            ; 灰色の面にする左右の列には当てない（中央の列だけホバーや選択の見た目をテーマに任せる）
            if (role == "cur")
                nv._ApplyExplorerTheme(lv)
            lv.Visible := false
            this._roles[lv.Hwnd] := role
        }
        text.Visible := false

        cur.OnEvent("ItemSelect", (*) => this._SchedulePreview())
        cur.OnEvent("DoubleClick", (*) => this.Activate())
        parent.OnEvent("Click", (*) => this._ClickParent())
        preview.OnEvent("Click", (*) => this._ClickPreview())
        if (this._drawHandler == "") {
            this._drawHandler := (w, l, m, hw) => this._OnCustomDraw(l)
            OnMessage(nv.WM_NOTIFY, this._drawHandler)
        }
        this.Layout(x, y, w, h)
    }

    /**
     * 3 列を x, y, w, h の範囲に並べる（左:中央:右 = COL_LEFT : COL_MID : 残り）
     * 左右の列は、スクロールバーの幅だけ広く作ってリージョンで切り、スクロールバーを見せない
     * （補助の列なので位置の目安は要らず、常に出ているスクロールバーの方がうるさいため。ホイールは効く）
     */
    static Layout(x, y, w, h) {
        g := this._navi.GuiObj
        wl := Round(w * this.COL_LEFT)
        wc := Round(w * this.COL_MID)
        wr := Max(40, w - wl - wc - 2 * this.GAP)
        sbw := Round(SysGet(2) * 96 / A_ScreenDPI)  ; SM_CXVSCROLL（Move と同じ DPI 換算の単位）
        sbh := Round(SysGet(3) * 96 / A_ScreenDPI)  ; SM_CYHSCROLL
        g["BrowseParent"].Move(x, y, wl + sbw, h)
        g["BrowseCur"].Move(x + wl + this.GAP, y, wc, h)
        g["BrowsePreview"].Move(x + wl + wc + 2 * this.GAP, y, wr + sbw, h)
        g["BrowseText"].Move(x + wl + wc + 2 * this.GAP, y, wr + sbw, h + sbh)
        this._ClipTo(g["BrowseParent"], wl, h)
        this._ClipTo(g["BrowsePreview"], wr, h)
        this._ClipTo(g["BrowseText"], wr, h)
        ; 左右の列は見える幅いっぱいにして、見出しの区切り線を切り落とす範囲に追い出す
        g["BrowseParent"].ModifyCol(1, Max(40, wl))
        g["BrowseCur"].ModifyCol(1, Max(40, wc - SysGet(2) - 4))
        g["BrowsePreview"].ModifyCol(1, Max(40, wr))
    }

    ; 部品の見える範囲を左上から w x h（Move と同じ単位）に切る
    static _ClipTo(ctrl, w, h) {
        rgn := DllCall("gdi32\CreateRectRgn", "int", 0, "int", 0
            , "int", Round(w * A_ScreenDPI / 96), "int", Round(h * A_ScreenDPI / 96), "ptr")
        DllCall("user32\SetWindowRgn", "ptr", ctrl.Hwnd, "ptr", rgn, "int", true)  ; リージョンは Windows が持つ
    }

    ; ウィンドウリサイズ: ツリーと同じ範囲に合わせる
    static OnResize(w, h) {
        g := this._navi.GuiObj
        try {
            g["FolderTree"].GetPos(&x, &y)
            this.Layout(x, y, w, h)
        }
    }

    /** Active に合わせて 3 列の表示を切り替える（右の列は中身の種類で一覧かテキストのどちらか） */
    static ApplyVisibility() {
        g := this._navi.GuiObj
        g["BrowseParent"].Visible := this.Active
        g["BrowseCur"].Visible := this.Active
        if (!this.Active) {
            g["BrowsePreview"].Visible := false
            g["BrowseText"].Visible := false
        }
    }

    ; ==============================================================================
    ; ツリーとの切り替え
    ; ==============================================================================

    /** ツリー（または一覧）↔ 3 列を切り替える（Ctrl+B） */
    static Toggle() {
        if (this.Active)
            this.Exit()
        else
            this.Enter()
    }

    /**
     * 3 列にする。ツリー・一覧で選んでいたのがフォルダならその中を開き、
     * ファイルならその親フォルダを開いてファイルを選ぶ（なければルートを開く）
     */
    static Enter() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (nv._SearchMode)
            nv._ToggleSearchMode()
        sel := nv._GetSelectedPath()
        if (NaviDirList.Active)
            NaviDirList._SetActive(false)
        this.Active := true
        IniWrite("1", nv.IniPath, "Settings", "BrowseMode")
        nv.GuiObj["FolderTree"].Visible := false
        this.ApplyVisibility()
        if (sel != "" && DirExist(sel)) {
            this.Open(sel)
        } else if (sel != "" && FileExist(sel)) {
            SplitPath(sel, &selName)
            this.Open(this._ParentOf(sel), selName)
        } else {
            this.Open(this._RootPath())
        }
        this.FocusList()
    }

    /**
     * 中央の列にフォーカスを移す（ツリーと同じく、一覧では文字キーがその文字で始まる行へ飛ぶ。
     * 絞り込みは Ctrl+F で入力欄へ移ってから打つ）。選んでいる行がなければ先頭を選ぶ
     */
    static FocusList() {
        lv := this._navi.GuiObj["BrowseCur"]
        if (lv.GetNext(0) == 0 && this._shown.Length > 0) {
            lv.Modify(1, "Select Focus Vis")
            this._SchedulePreview()
        }
        lv.Focus()
    }

    /**
     * ツリーに戻す。reveal なら 3 列で選んでいたものをツリーで表示する（ルートの中にある場合）
     */
    static Exit(reveal := true) {
        nv := this._navi
        if !(this.Active && nv.GuiObj && WinExist(nv.GuiObj))
            return
        path := this.SelectedPath()
        this.Active := false
        IniWrite("0", nv.IniPath, "Settings", "BrowseMode")
        this.ApplyVisibility()
        tv := nv.GuiObj["FolderTree"]
        tv.Visible := true
        filter := nv.GuiObj["TreeFilter"]
        if (reveal && path != "") {
            filter.Value := ""
            root := this._RootPath()
            if (root != "")
                nv._RefreshTree(tv, root, false)
            nv._FocusPath(tv, path)
        }
        tv.Focus()
        NaviBreadcrumb.Refresh()
        nv._UpdateStatusBar()
    }

    static _RootPath() {
        nv := this._navi
        return nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
    }

    ; ==============================================================================
    ; 移動
    ; ==============================================================================

    /**
     * path を中央の列に開く。selectName があればその行を選ぶ（なければ前回そのフォルダで選んでいた行）
     * path が "" ならドライブの一覧
     */
    static Open(path, selectName := "") {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (path != "" && !DirExist(path))
            path := this._RootPath()
        this._cur := path
        if (selectName == "" && this._lastSel.Has(StrLower(path)))
            selectName := this._lastSel[StrLower(path)]
        this._entries := this._List(path)
        ; フォルダを移ったら絞り込みは消す。打ちかけの絞り込みが待っていれば、新しいフォルダに効かないよう取り消す
        if (NaviFilter._treeFilterCallback != "") {
            SetTimer(NaviFilter._treeFilterCallback, 0)
            NaviFilter._treeFilterCallback := ""
        }
        filter := nv.GuiObj["TreeFilter"]
        if (filter.Value != "")
            filter.Value := ""
        this._FillCur(selectName)
        this._FillParent()
        this._UpdatePreview()
        NaviBreadcrumb.Refresh()
        nv._UpdateStatusBar()
    }

    /** 1 つ上のフォルダへ。今いたフォルダを選んだ状態にする（ドライブの一番上からはドライブの一覧へ） */
    static Up() {
        if (!this.Active || this._cur == "")
            return
        this._Remember()
        this.Open(this._ParentOf(this._cur), this._NameOf(this._cur))
    }

    /** 選んでいるフォルダに入る（ファイルなら何もしない） */
    static Down() {
        item := this._SelectedItem()
        if (!this.Active || !item || !item.isDir)
            return
        ; メディアのない CD ドライブや切断されたネットワークドライブなど、開けないときはその場に留まる
        if !DirExist(item.path) {
            ToolTip("開けません: " . item.path)
            SetTimer(() => ToolTip(), -this._navi.TOOLTIP_ERROR_DURATION)
            return
        }
        this._Remember()
        this.Open(item.path)
    }

    /** ダブルクリック: フォルダなら入る、ファイルなら開く */
    static Activate() {
        item := this._SelectedItem()
        if (!item)
            return
        if (item.isDir)
            this.Down()
        else
            this._navi._HandleActivate()
    }

    /** 中央の列の選択を delta 行ずらす */
    static Move(delta) {
        lv := this._navi.GuiObj["BrowseCur"]
        n := this._shown.Length
        if (n == 0)
            return
        cur := lv.GetNext(0)
        next := (cur == 0) ? 1 : Min(Max(cur + delta, 1), n)
        lv.Modify(0, "-Select")
        lv.Modify(next, "Select Focus Vis")
        ; スクリプトから選択を変えたときは ItemSelect が来ないので、右の列は自分で作り直す
        this._SchedulePreview()
    }

    ; 左の列のクリック: そのフォルダへ移る（ファイルなら親を開いてそれを選ぶ）
    static _ClickParent() {
        row := this._navi.GuiObj["BrowseParent"].GetNext(0)
        if (row == 0 || row > this._parentShown.Length)
            return
        item := this._parentShown[row]
        this._Remember()
        if (item.isDir)
            this.Open(item.path)
        else
            this.Open(this._ParentOf(this._cur), item.name)
    }

    ; 右の列のクリック: 選んでいるフォルダに入り、クリックした行を選ぶ
    static _ClickPreview() {
        row := this._navi.GuiObj["BrowsePreview"].GetNext(0)
        sel := this._SelectedItem()
        if (row == 0 || row > this._previewShown.Length || !sel || !sel.isDir)
            return
        this._Remember()
        this.Open(sel.path, this._previewShown[row].name)
    }

    ; 今いるフォルダで選んでいる名前を覚える（戻ってきたときに同じ行を選ぶため）
    static _Remember() {
        item := this._SelectedItem()
        if (item)
            this._lastSel[StrLower(this._cur)] := item.name
    }

    /**
     * 中央の列のマウス位置の行を選んでそのパスを返す（右クリックメニュー用）
     * RButton ホットキーがクリックを握りつぶすため、選択は自前でヒットテストする
     */
    static SelectRowAtMouse() {
        lv := this._navi.GuiObj["BrowseCur"]
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "ptr", pt)
        DllCall("user32\ScreenToClient", "ptr", lv.Hwnd, "ptr", pt)
        hit := Buffer(24, 0)  ; LVHITTESTINFO
        NumPut("int", NumGet(pt, 0, "int"), "int", NumGet(pt, 4, "int"), hit, 0)
        idx := SendMessage(0x1012, 0, hit.Ptr, lv)  ; LVM_HITTEST
        if (idx < 0 || idx >= 0xFFFFFFFF || idx + 1 > this._shown.Length)
            return ""
        lv.Modify(0, "-Select")
        lv.Modify(idx + 1, "Select Focus")
        return this._shown[idx + 1].path
    }

    /** 中央の列で選んでいるもののパス（なければ ""） */
    static SelectedPath() {
        item := this._SelectedItem()
        return item ? item.path : ""
    }

    static _SelectedItem() {
        try {
            row := this._navi.GuiObj["BrowseCur"].GetNext(0)
            if (row > 0 && row <= this._shown.Length)
                return this._shown[row]
        }
        return ""
    }

    ; ==============================================================================
    ; 絞り込み（入力欄）
    ; ==============================================================================

    /** 入力に合わせて中央の列を絞り込む（並び順はそのまま、選んでいた行はできるだけ残す） */
    static ApplyFilter(query) {
        if (!this.Active)
            return
        item := this._SelectedItem()
        this._FillCur(item ? item.name : "", query)
        this._UpdatePreview()
        this._navi._UpdateStatusBar()
    }

    ; ==============================================================================
    ; 一覧の中身
    ; ==============================================================================

    /** path の中身（フォルダが先、それぞれ名前順）。"" ならドライブの一覧 */
    static _List(path) {
        items := []
        if (path == "") {
            for d in StrSplit(DriveGetList())
                items.Push({ name: d . ":", path: d . ":\", isDir: true })
            return items
        }
        base := RTrim(path, "\")
        dirs := "", files := ""
        try {
            loop files, base . "\*", "DF" {
                if (SubStr(A_LoopFileName, 1, 1) == "." || InStr(A_LoopFileAttrib, "H"))
                    continue
                if InStr(A_LoopFileAttrib, "D")
                    dirs .= A_LoopFileName . "`n"
                else
                    files .= A_LoopFileName . "`n"
            }
        }
        for kind, names in [dirs, files] {
            if (names == "")
                continue
            for name in StrSplit(Sort(RTrim(names, "`n")), "`n") {
                items.Push({ name: name, path: base . "\" . name, isDir: kind == 1 })
                if (items.Length >= this.CAP)
                    return items
            }
        }
        return items
    }

    ; 一覧の部品に items を入れる。selectName の行を選ぶ（なければ先頭。select=false なら選ばない）
    ; items が空なら emptyText を選べない案内の行として出す（真っ白だと読み込めていないように見えるため）
    static _Fill(lv, items, selectName := "", select := true, emptyText := "空のフォルダ") {
        nv := this._navi
        lv.Opt("-Redraw")
        lv.Delete()
        if (items.Length == 0) {
            lv.Add("Icon0", emptyText)  ; 案内の行なのでアイコンは付けない
            lv.Opt("+Redraw")
            return
        }
        row := 0
        for i, it in items {
            lv.Add(it.isDir ? "Icon1" : nv._GetFileIconStr(it.name), it.name)
            if (selectName != "" && StrLower(it.name) == StrLower(selectName))
                row := i
        }
        if (select && items.Length > 0)
            lv.Modify(row ? row : 1, "Select Focus Vis")
        lv.Opt("+Redraw")
    }

    static _FillCur(selectName := "", query := "") {
        terms := NaviDirList._ParseQuery(query)
        if (terms.Length == 0) {
            shown := this._entries
        } else {
            shown := []
            for it in this._entries
                if (NaviDirList._Score(it.name, it.name, terms) >= 0)
                    shown.Push(it)
        }
        this._shown := shown
        this._filling := true
        this._Fill(this._navi.GuiObj["BrowseCur"], shown, selectName, true
            , (terms.Length == 0) ? "空のフォルダ" : "一致するものがありません")
        this._filling := false
    }

    static _FillParent() {
        lv := this._navi.GuiObj["BrowseParent"]
        if (this._cur == "") {
            this._parentShown := []
            lv.Delete()
            return
        }
        this._parentShown := this._List(this._ParentOf(this._cur))
        this._Fill(lv, this._parentShown, this._NameOf(this._cur))
    }

    ; 中央の列の選択が変わったら右の列を作り直す（キーを押し続けたときに毎回読まないよう少し待つ）
    static _SchedulePreview() {
        if (this._filling)
            return
        if (this._previewTimer != "")
            SetTimer(this._previewTimer, 0)
        this._previewTimer := () => (this._previewTimer := "", this._UpdatePreview(), NaviBreadcrumb.Refresh())
        SetTimer(this._previewTimer, -30)
    }

    /**
     * 列の見出しを今の場所に合わせる: 左「‹ 親フォルダ名」/ 中央「今いるフォルダ名」/ 右「選んだものの名前 ›」
     * 矢印で、左が上の階層・右が下の階層だと分かるようにする
     */
    static _UpdateHeaders() {
        g := this._navi.GuiObj
        parent := this._ParentOf(this._cur)
        left := (this._cur == "") ? "" : "‹ " . (parent == "" ? "ドライブ" : this._NameOf(parent))
        mid := (this._cur == "") ? "ドライブ" : this._NameOf(this._cur)
        item := this._SelectedItem()
        right := !item ? "" : item.isDir ? item.name . " ›" : item.name
        g["BrowseParent"].ModifyCol(1, , left)
        g["BrowseCur"].ModifyCol(1, , mid)
        g["BrowsePreview"].ModifyCol(1, , right)
    }

    /** 右の列: フォルダなら中身、ファイルなら内容またはサイズと更新日時 */
    static _UpdatePreview() {
        g := this._navi.GuiObj
        if !(this.Active && g)
            return
        lv := g["BrowsePreview"], text := g["BrowseText"]
        item := this._SelectedItem()
        if (!item) {
            this._previewShown := []
            lv.Delete()
            lv.Visible := true, text.Visible := false
            this._UpdateHeaders()
            return
        }
        if (item.isDir) {
            this._previewShown := this._List(item.path)
            this._Fill(lv, this._previewShown, "", false)
            text.Visible := false, lv.Visible := true
            this._UpdateHeaders()
            return
        }
        text.Value := this._FilePreview(item.path)
        lv.Visible := false, text.Visible := true
        this._UpdateHeaders()
    }

    ; ファイルの右の列: 名前・サイズ・更新日時と、テキストなら先頭の内容
    static _FilePreview(path) {
        SplitPath(path, &name)
        size := 0, time := ""
        try size := FileGetSize(path)
        try time := FormatTime(FileGetTime(path, "M"), "yyyy/MM/dd HH:mm")
        head := name . "`r`n" . this._FormatSize(size) . "   " . time . "`r`n" . "────────────────────`r`n"
        if (size > this.PREVIEW_MAX_BYTES)
            return head . "（大きいファイルなので内容は表示しません）"
        enc := this._TextEncoding(path)
        if (enc == "")
            return head . "（テキストではないため内容は表示しません）"
        body := ""
        try body := FileRead(path, enc)
        lines := StrSplit(body, "`n", "`r")
        out := ""
        for i, line in lines {
            if (i > this.PREVIEW_MAX_LINES) {
                out .= "…"
                break
            }
            out .= line . "`r`n"
        }
        return head . out
    }

    /**
     * テキストとして読むときの文字コード。テキストでなければ ""
     * 先頭 4KB を見て、BOM があればそれに従い、NUL があればバイナリとみなす。
     * BOM がなければ UTF-8 として正しい並びかを調べ、違えば Shift-JIS（CP932）として読む
     */
    static _TextEncoding(path) {
        n := 0
        buf := Buffer(4096, 0)
        try {
            f := FileOpen(path, "r")
            n := f.RawRead(buf, 4096)
            f.Close()
        } catch {
            return ""  ; 読めないファイル
        }
        b(i) => NumGet(buf, i, "uchar")
        if (n >= 2 && b(0) = 0xFF && b(1) = 0xFE)
            return "UTF-16"
        if (n >= 3 && b(0) = 0xEF && b(1) = 0xBB && b(2) = 0xBF)
            return "UTF-8"
        loop n {
            if (b(A_Index - 1) = 0)
                return ""
        }
        return this._IsUtf8(buf, n) ? "UTF-8" : "CP932"
    }

    ; buf の先頭 n バイトが UTF-8 として正しい並びか（末尾で途切れた 1 文字は許す）
    static _IsUtf8(buf, n) {
        i := 0
        while (i < n) {
            c := NumGet(buf, i, "uchar")
            if (c < 0x80) {
                i++
                continue
            }
            len := (c >= 0xC2 && c <= 0xDF) ? 2 : (c >= 0xE0 && c <= 0xEF) ? 3 : (c >= 0xF0 && c <= 0xF4) ? 4 : 0
            if (len == 0)
                return false
            loop len - 1 {
                if (i + A_Index >= n)
                    return true  ; 4KB の境目で途切れた文字
                if ((NumGet(buf, i + A_Index, "uchar") & 0xC0) != 0x80)
                    return false
            }
            i += len
        }
        return true
    }

    static _FormatSize(size) {
        if (size < 1024)
            return size . " B"
        if (size < 1048576)
            return Round(size / 1024, 1) . " KB"
        if (size < 1073741824)
            return Round(size / 1048576, 1) . " MB"
        return Round(size / 1073741824, 2) . " GB"
    }

    ; path の 1 つ上（ドライブの一番上の上はドライブの一覧 ""）
    static _ParentOf(path) {
        p := RTrim(path, "\")
        if (p == "" || RegExMatch(p, "^[A-Za-z]:$"))
            return ""
        SplitPath(p, , &dir)
        return (StrLen(dir) == 2 && SubStr(dir, 2) == ":") ? dir . "\" : dir
    }

    ; 表示用の名前（C:\ は C:）
    static _NameOf(path) {
        p := RTrim(path, "\")
        if RegExMatch(p, "^[A-Za-z]:$")
            return p
        SplitPath(p, &name)
        return name
    }

    ; ==============================================================================
    ; 表示
    ; ==============================================================================

    /** ステータスバー左側: 今いるフォルダと件数 */
    static StatusText() {
        where := (this._cur == "") ? "ドライブ" : this._NameOf(this._cur)
        return " 3 列   " . where . "   " . this._shown.Length . " 件"
    }

    /** ステータスバー右側: 操作の案内 */
    static StatusHints() {
        return " ←→ 移動     Enter 開く     Space メニュー     Ctrl+B ツリー"
    }

    /**
     * WM_NOTIFY → NM_CUSTOMDRAW
     * 中央の列は本文の色、左右の列は補足の色にして、今いる場所を目立たせる
     * 中央の列の選択は（入力欄にいる間も）薄い青、左の列の「今いるフォルダ」は薄い灰色にして、
     * 操作しているのが中央の列だと分かるようにする。空の案内の行は案内の色にする
     */
    static _OnCustomDraw(l) {
        hwnd := NumGet(l, 0, "ptr")
        if (!this._roles.Has(hwnd) || NumGet(l, A_PtrSize * 2, "int") != -12)  ; NM_CUSTOMDRAW
            return
        x64 := (A_PtrSize = 8)
        stage := NumGet(l, x64 ? 24 : 12, "uint")
        if (stage = 0x1)          ; CDDS_PREPAINT
            return 0x20           ; CDRF_NOTIFYITEMDRAW
        if (stage = 0x10001) {    ; CDDS_ITEMPREPAINT
            role := this._roles[hwnd]
            shown := (role = "cur") ? this._shown : (role = "parent") ? this._parentShown : this._previewShown
            color := (shown.Length == 0) ? NaviTheme.TEXT_SUBTLE
                : (role = "cur") ? NaviTheme.TEXT : NaviTheme.TEXT_MUTED
            NumPut("uint", NaviTheme.BGR(color), l, x64 ? 80 : 48)  ; clrText
            if (role = "cur") {
                NaviTheme.PaintSoftSelection(l, hwnd)
            } else if (role = "parent") {
                item := NumGet(l, x64 ? 56 : 36, "uptr")
                if (SendMessage(0x102C, item, 0x2, hwnd) & 0x2) {  ; LVM_GETITEMSTATE: LVIS_SELECTED
                    stateOff := x64 ? 64 : 40
                    ; CDIS_SELECTED と CDIS_FOCUS を外し、テーマに選択色と青い枠を描かせない
                    NumPut("uint", NumGet(l, stateOff, "uint") & ~0x11, l, stateOff)
                    NumPut("uint", NaviTheme.BGR(NaviTheme.HOVER), l, x64 ? 84 : 52)  ; clrTextBk
                }
            }
            return 0x2            ; CDRF_NEWFONT
        }
        return 0
    }
}
