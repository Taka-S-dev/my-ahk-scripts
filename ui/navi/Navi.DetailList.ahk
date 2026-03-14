#Requires AutoHotkey v2.0
; ==============================================================================
; Module:      Navi.DetailList.ahk
; Description: Navi 詳細リストモジュール
;              - 選択フォルダと同一階層のファイル・フォルダを ListView で表示
;              - 詳細リスト上でのアクションメニュー表示・実行
; Usage:       NaviDetailList.Init(naviRef) を Navi.Init() から呼び出す
; ==============================================================================

class NaviDetailList {
    static _navi := ""
    static _guiObj := ""  ; 詳細リストウィンドウ GUI

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

        tv := nv.GuiObj["FolderTree"]
        id := tv.GetSelection()
        if (id = 0) {
            ToolTip("フォルダを選択してください")
            SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
            return
        }

        selectedPath := nv._GetTVFullPath(tv, id)

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
        dlGui.SetFont("s10", "Yu Gothic UI")

        ; ListView を作成（名前、種類、サイズ、作成日時、更新日時）
        lv := dlGui.Add("ListView", "r20 w900 Grid Sort", ["名前", "種類", "サイズ", "作成日時", "更新日時"])

        ; 同一階層のすべてのファイル・フォルダを取得
        itemCount := 0
        ; フォルダを先に追加
        loop files, targetDir . "\*", "D" {
            if (SubStr(A_LoopFileName, 1, 1) == "." || InStr(A_LoopFileAttrib, "H"))
                continue
            created  := FormatTime(A_LoopFileTimeCreated,  "yyyy/MM/dd HH:mm:ss")
            modified := FormatTime(A_LoopFileTimeModified, "yyyy/MM/dd HH:mm:ss")
            lv.Add(, A_LoopFileName, "<フォルダ>", "", created, modified)
            itemCount++
        }
        ; ファイルを追加
        loop files, targetDir . "\*", "F" {
            if (InStr(A_LoopFileAttrib, "H"))
                continue
            size := A_LoopFileSize
            if (size < 1024)
                sizeStr := size . " B"
            else if (size < 1048576)
                sizeStr := Round(size / 1024, 2) . " KB"
            else if (size < 1073741824)
                sizeStr := Round(size / 1048576, 2) . " MB"
            else
                sizeStr := Round(size / 1073741824, 2) . " GB"
            SplitPath(A_LoopFileName, , , &ext)
            fileType := (ext != "") ? "." . ext : "ファイル"
            created  := FormatTime(A_LoopFileTimeCreated,  "yyyy/MM/dd HH:mm:ss")
            modified := FormatTime(A_LoopFileTimeModified, "yyyy/MM/dd HH:mm:ss")
            lv.Add(, A_LoopFileName, fileType, sizeStr, created, modified)
            itemCount++
        }

        ; 列幅の設定
        lv.ModifyCol(1, 250)  ; 名前
        lv.ModifyCol(2, 100)  ; 種類
        lv.ModifyCol(3, 100)  ; サイズ
        lv.ModifyCol(4, 180)  ; 作成日時
        lv.ModifyCol(5, 180)  ; 更新日時

        ; ステータスバー
        dlGui.SetFont("s8")
        sb := dlGui.Add("StatusBar")
        sb.SetText(" [Space] アクションメニュー  /  [Enter] エクスプローラー  /  項目数: " . itemCount)

        ; 閉じるボタン
        dlGui.SetFont("s10")
        btnClose := dlGui.Add("Button", "w100 Default", "閉じる")
        btnClose.OnEvent("Click", (*) => this.Close())

        ; ListView イベント
        lv.OnEvent("DoubleClick", (obj, row) => (row ? this._Execute(dlGui, lv, row, targetDir, "e") : 0))

        ; ホットキー設定（詳細リストウィンドウアクティブ時のみ）
        HotIfWinActive("ahk_id " dlGui.Hwnd)
        Hotkey("Space", (*) => this._ShowActionMenu(dlGui, lv, targetDir), "On")
        Hotkey("Enter", (*) => this._Execute(dlGui, lv, lv.GetNext(), targetDir, "e"), "On")
        Hotkey("^d",    (*) => this.Close(), "On")
        Hotkey("Esc",   (*) => this.Close(), "On")
        HotIf()

        dlGui.OnEvent("Close", (*) => this.Close())

        ; 親ウィンドウの右隣に表示（10px ギャップ）
        dlGui.Show("x" . (gx + gw + 10) . " y" . gy . " w920")
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
            try nv.GuiObj["FolderTree"].Focus()
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

        dlGui.GetPos(&gx, &gy, &gw, &gh)
        dlGui.Opt("+Disabled")

        actGui := Gui("+Owner" . dlGui.Hwnd . " -Caption +AlwaysOnTop +Border")
        actGui.BackColor := nv.MENU_BG_COLOR
        actGui.MarginX   := 10
        actGui.MarginY   := 8

        actGui.SetFont("s8 w400 cA0A0A0", "Yu Gothic UI")
        actGui.Add("Text", "Center w" . nv.MENU_BTN_W, itemName)

        actGui.SetFont("s9 w400 cWhite")
        ; NaviActions に登録されたアクションからボタンを生成（ソート済み）
        keys := []
        for k, _ in NaviActions.Actions
            keys.Push(k)
        if (keys.Length > 1) {
            tmp := ""
            for _, kk in keys
                tmp .= kk . "`n"
            tmp := Sort(RTrim(tmp, "`n"))
            keys := StrSplit(tmp, "`n")
        }

        for k in keys {
            act := NaviActions.Actions[k]
            btn := actGui.Add("Button", "w" . nv.MENU_BTN_W . " h" . nv.MENU_BTN_H . " xm", act.label)
            btn.OnEvent("Click", ((kk, *) => (
                dlGui.Opt("-Disabled"),
                actGui.Destroy(),
                this._Execute(dlGui, lv, row, targetDir, kk)
            )).Bind(k))
        }

        btnCancel := actGui.Add("Button", "w" . nv.MENU_BTN_W . " h" . nv.MENU_BTN_H . " xm y+6", "&X: Cancel")
        btnCancel.OnEvent("Click",  (*) => (dlGui.Opt("-Disabled"), actGui.Destroy()))
        actGui.OnEvent("Escape",    (*) => (dlGui.Opt("-Disabled"), actGui.Destroy()))

        actGui.Show("AutoSize x" . gx + (gw - nv.MENU_WIDTH) // 2 . " y" . gy + (gh - nv.MENU_OFFSET_Y) // 2)
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
