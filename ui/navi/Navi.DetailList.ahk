#Requires AutoHotkey v2.0
; ==============================================================================
; Module:      Navi.DetailList.ahk
; Description: Navi 詳細リストモジュール
;              - 選択フォルダの中身を、エクスプローラーの詳細表示と同じ列・並び（フォルダが先）で表示
;              - 見出しのクリックで並べ替え（フォルダはいつも先）
;              - 詳細リスト上でのアクションメニュー表示・実行
; Usage:       NaviDetailList.Init(naviRef) を Navi.Init() から呼び出す
; ==============================================================================

class NaviDetailList {
    static _navi := ""
    static _guiObj := ""  ; 詳細リストウィンドウ GUI
    static _lv := ""      ; 一覧
    static _dir := ""     ; 表示しているフォルダ
    static _items := []   ; 中身 [{ name, isDir, size, mtime, ctime, type }]
    static _order := []   ; 一覧の行番号 → 項目（並べ替えた順）
    static _sortCol := 1
    static _sortDesc := false

    static Init(naviRef) {
        this._navi := naviRef
    }

    ; ==============================================================================
    ; 詳細リスト表示
    ; ==============================================================================

    /**
     * 選択中のファイル・フォルダと同一階層の詳細リストを表示
     * 既に開いていれば閉じる（トグル）
     */
    static Show() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return

        if (this._guiObj && WinExist(this._guiObj)) {
            this.Close()
            return
        }

        selectedPath := nv._GetSelectedPath()
        if (selectedPath == "") {
            ToolTip("フォルダを選択してください")
            SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
            return
        }

        ; フォルダでない場合は親フォルダを取得
        targetDir := ""
        if (DirExist(selectedPath)) {
            targetDir := selectedPath
        } else if (FileExist(selectedPath)) {
            SplitPath(selectedPath, , &parentDir)
            targetDir := parentDir
        } else {
            ToolTip("パスが見つかりません")
            SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
            return
        }

        ; 詳細リスト用の GUI を作成
        nv.GuiObj.GetPos(&gx, &gy, &gw)
        nv.GuiObj.Opt("+Disabled")

        dlGui := Gui("+Owner" . nv.GuiObj.Hwnd . " +Resize", "詳細リスト - " . targetDir)
        this._guiObj := dlGui
        NaviTheme.ApplyPopup(dlGui)
        NaviTheme.SetFont(dlGui, "body")

        ; 列はエクスプローラーの詳細表示と同じ並び（作成日時は最後に足す）
        ; 並べ替えは見出しのクリックで自前で行う（フォルダを先に保ち、サイズ・日時は値で比べるため）
        lv := dlGui.Add("ListView", "r20 w900 -Multi NoSort +LV0x10000", ["名前", "更新日時", "種類", "サイズ", "作成日時"])
        lv.SetImageList(nv._ILHandle, 1)
        nv._ApplyExplorerTheme(lv)
        lv.ModifyCol(1, 300)
        lv.ModifyCol(2, 150)
        lv.ModifyCol(3, 170)
        lv.ModifyCol(4, "100 Right")  ; 数字は右にそろえて桁を比べやすくする
        lv.ModifyCol(5, 150)
        this._lv := lv
        this._dir := targetDir
        this._items := this._Collect(targetDir)
        this._sortCol := 1, this._sortDesc := false
        this._Fill()
        lv.OnEvent("ColClick", (obj, col) => this._SortBy(col))
        lv.OnEvent("DoubleClick", (obj, row) => (row ? this._Open(dlGui, row) : 0))

        ; ステータスバー（本体と同じ書き方の案内と件数）
        NaviTheme.SetFont(dlGui, "caption")
        sb := dlGui.Add("StatusBar")
        sb.SetParts(140)
        sb.SetText(" " . this._items.Length . " 項目", 1)
        sb.SetText(" Ctrl+Space メニュー     Enter 開く     Esc 閉じる", 2)
        NaviTheme.SetFont(dlGui, "body")

        ; ホットキー設定（詳細リストウィンドウアクティブ時のみ）。メニューのキーは本体と同じ
        HotIfWinActive("ahk_id " dlGui.Hwnd)
        for key in ["Space", "^Space", "AppsKey", "+F10"]
            Hotkey(key, (*) => this._ShowActionMenu(dlGui, lv, targetDir), "On")
        Hotkey("Enter", (*) => this._Open(dlGui, lv.GetNext()), "On")
        Hotkey("^i",    (*) => this.Close(), "On")  ; 開いたキー（Ctrl+I）でもう一度押すと閉じる
        Hotkey("Esc",   (*) => this.Close(), "On")
        HotIf()

        dlGui.OnEvent("Close", (*) => this.Close())
        dlGui.OnEvent("Size", (g, minMax, w, h) => (minMax = -1) ? 0
            : (sb.GetPos(, , , &sbH), lv.Move(, , w - 2 * g.MarginX, h - 2 * g.MarginY - sbH)))

        ; 親ウィンドウの右隣に表示（10px ギャップ）
        dlGui.Show("x" . (gx + gw + 10) . " y" . gy . " w920")
    }

    ; フォルダの中身を集める（3 列と同じく、隠し属性と . で始まるものは出さない）
    static _Collect(dir) {
        items := []
        loop files, dir . "\*", "FD" {
            if (SubStr(A_LoopFileName, 1, 1) == "." || InStr(A_LoopFileAttrib, "H"))
                continue
            isDir := InStr(A_LoopFileAttrib, "D") > 0
            items.Push({ name: A_LoopFileName, isDir: isDir, size: isDir ? -1 : A_LoopFileSize
                , mtime: A_LoopFileTimeModified, ctime: A_LoopFileTimeCreated
                , type: this._TypeName(A_LoopFileName, isDir) })
        }
        return items
    }

    /**
     * 種類の名前（エクスプローラーと同じ「テキスト ドキュメント」「ファイル フォルダー」など）
     * ファイルを開かずに拡張子だけで引く（SHGFI_USEFILEATTRIBUTES）。拡張子ごとに覚えておく
     */
    static _typeCache := Map()
    static _TypeName(name, isDir) {
        SplitPath(name, , , &ext)
        key := isDir ? "<dir>" : StrLower(ext)
        if this._typeCache.Has(key)
            return this._typeCache[key]
        sfi := Buffer(A_PtrSize + 8 + 520 + 160, 0)  ; SHFILEINFOW
        attr := isDir ? 0x10 : 0x80  ; FILE_ATTRIBUTE_DIRECTORY / NORMAL
        DllCall("shell32\SHGetFileInfoW", "wstr", isDir ? "folder" : "x." . ext, "uint", attr
            , "ptr", sfi, "uint", sfi.Size, "uint", 0x400 | 0x10)  ; SHGFI_TYPENAME | SHGFI_USEFILEATTRIBUTES
        typeName := StrGet(sfi.Ptr + A_PtrSize + 8 + 520, 80, "UTF-16")
        if (typeName == "")
            typeName := (ext != "") ? StrUpper(ext) . " ファイル" : "ファイル"
        this._typeCache[key] := typeName
        return typeName
    }

    ; 見出しのクリック: その列で並べ替える（同じ列をもう一度押すと逆順）。フォルダはいつも先
    static _SortBy(col) {
        this._sortDesc := (col == this._sortCol) ? !this._sortDesc : false
        this._sortCol := col
        this._Fill()
    }

    ; 並べ替えて一覧に入れる。フォルダとファイルを別々に並べてつなぐ（どの並べ方でもフォルダが先）
    static _Fill() {
        nv := this._navi
        lv := this._lv
        Keyed(it) {
            switch this._sortCol {
                case 2: return it.mtime
                case 3: return it.type . "`t" . it.name
                case 4: return Format("{:020}", Max(it.size, 0))
                case 5: return it.ctime
                default: return it.name
            }
        }
        SortGroup(group) {
            if (group.Length < 2)
                return group
            lines := ""
            for i, it in group
                lines .= Keyed(it) . "`t" . i . "`n"
            out := []
            ; CLogical: エクスプローラーと同じく数字を数として比べる（file2 < file10）
            for line in StrSplit(Sort(RTrim(lines, "`n"), "CLogical" . (this._sortDesc ? " R" : "")), "`n") {
                parts := StrSplit(line, "`t")
                out.Push(group[Integer(parts[parts.Length])])
            }
            return out
        }
        dirs := [], files := []
        for it in this._items
            (it.isDir ? dirs : files).Push(it)
        this._order := []
        for it in SortGroup(dirs)
            this._order.Push(it)
        for it in SortGroup(files)
            this._order.Push(it)

        lv.Opt("-Redraw")
        lv.Delete()
        for it in this._order {
            lv.Add(it.isDir ? "Icon1" : nv._GetFileIconStr(it.name), it.name
                , FormatTime(it.mtime, "yyyy/MM/dd H:mm"), it.type, this._SizeText(it)
                , FormatTime(it.ctime, "yyyy/MM/dd H:mm"))
        }
        lv.Opt("+Redraw")
        if (this._order.Length)
            lv.Modify(1, "Select Focus")
    }

    ; サイズはエクスプローラーと同じく KB で切り上げ、3 桁ごとに区切る（フォルダは空欄）
    static _SizeText(it) {
        if (it.isDir)
            return ""
        kb := (it.size == 0) ? 0 : Ceil(it.size / 1024)
        return RegExReplace(kb, "\G\d+?(?=(\d{3})+$)", "$0,") . " KB"
    }

    ; Enter・ダブルクリック: 本体と同じく、フォルダはエクスプローラー、ファイルは関連付けアプリで開く
    static _Open(dlGui, row) {
        if (row == 0 || row > this._order.Length)
            return
        it := this._order[row]
        if (it.isDir) {
            this._Execute(dlGui, this._lv, row, this._dir, "e")
            return
        }
        nv := this._navi
        nv.lastPath := this._dir . "\" . it.name
        try Run('"' . this._dir . "\" . it.name . '"')
        this.Close()
        if (nv.GuiObj && WinExist(nv.GuiObj) && !nv.GuiObj["PinCheck"].Value && !GetKeyState("Shift", "P"))
            nv._DestroyGui()
    }

    /**
     * 詳細リストウィンドウを閉じてメインウィンドウの無効化を解除する
     */
    static Close() {
        nv := this._navi
        if (this._guiObj && WinExist(this._guiObj)) {
            try this._guiObj.Destroy()
            this._guiObj := ""
        }
        if (nv.GuiObj && WinExist(nv.GuiObj)) {
            nv.GuiObj.Opt("-Disabled")
            try nv._FocusMainView()
        }
    }

    ; ==============================================================================
    ; アクションメニュー・実行
    ; ==============================================================================

    /**
     * 詳細リストから選択アイテムのアクションメニューを表示
     */
    static _ShowActionMenu(dlGui, lv, targetDir) {
        nv := this._navi
        row := lv.GetNext()
        if (row == 0) {
            ToolTip("項目を選択してください")
            SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
            return
        }

        itemName := lv.GetText(row, 1)
        fullPath  := targetDir . "\" . itemName
        if (!DirExist(fullPath) && !FileExist(fullPath)) {
            ToolTip("パスが見つかりません")
            SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
            return
        }

        ; メインのアクションメニューと同じ部品・同じ見出しで出す（詳細リストの中央）
        NaviKeyMenu.Show({ owner: dlGui, title: itemName, columns: NaviActions.MENU_COLUMNS
            , items: NaviActions.MenuItems((k) => this._Execute(dlGui, lv, row, targetDir, k)) })
    }

    /**
     * 詳細リストから選択されたアイテムに対してアクションを実行
     */
    static _Execute(dlGui, lv, row, targetDir, key) {
        nv := this._navi
        if (row == 0) {
            ToolTip("項目を選択してください")
            SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
            return
        }

        itemName := lv.GetText(row, 1)
        fullPath  := targetDir . "\" . itemName
        if (!DirExist(fullPath) && !FileExist(fullPath)) {
            ToolTip("パスが見つかりません")
            SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
            return
        }

        ; 操作したパスをメモリに保存（ツリー操作と同様）
        nv.lastPath := fullPath

        NaviActions._ExecuteAction(key, fullPath)

        ; アクション実行後に詳細リストウィンドウを閉じる
        this.Close()

        ; メインの Navi ウィンドウも閉じる（ピン留めと Shift キーを考慮）
        if (nv.GuiObj && WinExist(nv.GuiObj)) {
            if (StrLower(key) != "f") {
                if (!nv.GuiObj["PinCheck"].Value && !GetKeyState("Shift", "P"))
                    nv._DestroyGui()
            }
        }

        if (key != "k" && StrLower(key) != "f")
            ToolTip("実行 [" . key . "]: " . fullPath), SetTimer(() => ToolTip(), -nv.TOOLTIP_SUCCESS_DURATION)
    }
}
