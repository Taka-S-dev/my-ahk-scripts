; ==============================================================================
; Module:       Navi.ahk
; Description:  汎用フォルダランチャー & アクティブパス実行ツール
;               - フォルダパスのTreeView表示とクイックアクセス
;               - 表示・非表示の個別/一括切り替え機能
;
; - リストの順序入れ替え（上下移動）
;               - 外部ファイラー（Tablacus等）やVSCodeへのパス渡し
; Version:      1.0.0
; License:      MIT
;
;
; Usage Example (Main.ahk):
;   #Include ui\Navi.ahk
;   Navi.Init()
;   vk1D & f:: Navi.Show() ; 無変換 + f で起動
;
; ==============================================================================
#Requires AutoHotkey v2.0
#Include *i Navi.Search.ahk

class Navi {
    ; --- クラス定数 ---
    static GUI_WIDTH := 450
    static GUI_HEIGHT_APPROX := 540
    static WINDOW_FRAME_WIDTH := 14  ; ウィンドウフレーム補正値（Win10/11標準テーマ）
    static IniPath := A_ScriptDir "\ui\Navi.ini"
    static ExplorerPath := ""
    static TOOLTIP_ERROR_DURATION := 2000
    static TOOLTIP_SUCCESS_DURATION := 1000
    static TOOLTIP_COPY_DURATION := 2000
    static TEMP_DIR_SUBPATH := "\ui\NaviTemp"
    static TEMP_PREFIX := "TEMP_"

    ; --- [追加] アクションメニュー用の定数 ---
    static MENU_BG_COLOR := "262626"  ; メニューの背景色
    static MENU_WIDTH := 250       ; メニューの幅
    static MENU_BTN_W := 230       ; ボタンの幅
    static MENU_BTN_H := 38        ; ボタンの高さ
    static MENU_OFFSET_Y := 320    ; 中央配置の計算用オフセット

    ; --- 位置決定用の定数（魔法数の明示化） ---
    static CARET_OFFSET_X := 5     ; キャレットからのXオフセット
    static CARET_GAP_Y := 25       ; キャレット下に表示する際の縦方向ギャップ
    static SCREEN_MARGIN := 10     ; 画面端からのマージン
    static MOUSE_OFFSET := 15      ; マウス位置からのオフセット

    ; --- パンくずリスト用の定数 ---
    static BREADCRUMB_COLOR := "505050"      ; パンくずテキスト色
    static BREADCRUMB_HEIGHT := 20           ; パンくずの高さ
    static BREADCRUMB_MAX_LEN := 70          ; パス表示の最大文字数
    static BREADCRUMB_WATCH_MS := 100        ; 選択監視タイマー間隔

    ; --- セッション内メモリ ---
    static lastRoot := ""
    static lastPath := ""
    static GuiObj := ""
    static QuickPathFocused := false
    static QuickPathHwnd := 0
    static FilesShown := Map()
    static lastSelectedId := 0  ; パンくず更新用

    ; ---- Action registry ----
    static Actions := Map()  ; key(lower) => {label, run: (path)=>void}

    static RegisterAction(key, label, fn) {
        this.Actions[StrLower(key)] := { label: label, run: fn }
    }

    static RegisterShellAction(key, label, cmdTemplate, runOpt := "") {
        ; {path} を選択パスで置換して実行
        this.RegisterAction(key, label, (path) => (
            Run(StrReplace(cmdTemplate, "{path}", path), , runOpt)
        ))
    }

    static Init() {
        uiDir := A_ScriptDir "\ui"
        if (!DirExist(uiDir)) {
            try {
                DirCreate(uiDir)
            } catch as e {
                MsgBox("ディレクトリ作成失敗: " . e.Message, "Navi Error", 4096)
                return
            }
        }
        this._EnsureDefaultFolders()
        this.ExplorerPath := this._LoadConfig()
        this._InitDefaultActions()
        this._LoadUserActions()
    }

    static Show() {
        if (this.ExplorerPath == "") {
            this.Init()
        }

        if (this.GuiObj && WinExist(this.GuiObj)) {
            this.GuiObj.Destroy()
        }
        this.GuiObj := ""

        this.GuiObj := Gui("+AlwaysOnTop", "Navi - フォルダランチャー")
        this.GuiObj.SetFont("s10", "Segoe UI")

        folderMap := Map(), folderNames := []
        this._LoadFolders(folderMap, folderNames)

        chooseIdx := 1
        for i, name in folderNames {
            if (name == this.lastRoot) {
                chooseIdx := i
                break
            }
        }

        ; クイック登録: フルパス入力→Enterでルート追加（Tab移動ではフォーカスしない）
        quickEdit := this.GuiObj.Add("Edit", "xm w455 vQuickPath -Tabstop", "")
        ; プレースホルダ
        try DllCall("user32\SendMessageW", "ptr", quickEdit.Hwnd, "uint", 0x1501, "ptr", 1, "wstr",
            "Add root: full path + Enter", "ptr")
        quickEdit.SetFont("s8 c808080")
        this.GuiObj.Add("Text", "xm c808080", "Add root: paste full path and press Enter")
        ; フォーカス状態をトラック
        quickEdit.OnEvent("Focus", (*) => (Navi.QuickPathFocused := true))
        quickEdit.OnEvent("LoseFocus", (*) => (Navi.QuickPathFocused := false))
        this.QuickPathHwnd := quickEdit.Hwnd

        rootDDL := this.GuiObj.Add("DropDownList", "xm w280 Choose" . chooseIdx . " vRootDDL", folderNames)
        btnEdit := this.GuiObj.Add("Button", "x+5 yp w45 h28 -Tabstop", "編集")
        this.GuiObj.Add("Checkbox", "x+50 yp+5 vPinCheck -Tabstop", "ピン留め")

        ; パンくずリスト（現在のパス表示 & クリックで階層メニュー）
        this.GuiObj.SetFont("s8", "Segoe UI")
        breadcrumb := this.GuiObj.Add("Text", "xm w455 h" . this.BREADCRUMB_HEIGHT . " vBreadcrumb c" . this.BREADCRUMB_COLOR . " +0x100", "")  ; +0x100 = SS_NOTIFY for click
        breadcrumb.OnEvent("Click", (*) => this._OnBreadcrumbClick())
        this.GuiObj.SetFont("s10", "Segoe UI")

        tv := this.GuiObj.Add("TreeView", "xm w455 r18 vFolderTree")

        ; ステータスバーによる操作案内
        this.GuiObj.SetFont("s7")
        sb := this.GuiObj.Add("StatusBar")
        sb.SetText(" [Space] アクションメニューを表示   /   [Enter] エクスプローラー  /   [Ctrl + Enter] ファイル表示   /  [Ctrl+P] ピン留め")

        rootDDL.OnEvent("Change", (*) => (
            this.lastRoot := rootDDL.Text,
            this._RefreshTree(tv, folderMap[rootDDL.Text])
        ))

        btnEdit.OnEvent("Click", (*) => this._ShowEditGui(this.GuiObj))
        tv.OnEvent("ItemExpand", (obj, id, *) => this._OnItemExpand(obj, id))
        tv.OnEvent("DoubleClick", (obj, id, *) => this.Execute("e"))
        this.GuiObj.OnEvent("Close", (*) => (this.GuiObj := ""))

        ; ホットキー設定（Naviアクティブ時のみ）
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Space", (*) => this.ShowActionMenu(), "On")
        Hotkey("Enter", (*) => this._HandleEnter(), "On")
        Hotkey("^Enter", (*) => this.ToggleFilesUnderSelection(), "On")
        Hotkey("^p", (*) => (this.GuiObj["PinCheck"].Value := !this.GuiObj["PinCheck"].Value), "On")
        Hotkey("Esc", (*) => this._DestroyGui(), "On")
        HotIf()

        ; パンくず更新用タイマー開始
        this.lastSelectedId := 0
        SetTimer(this._BreadcrumbWatcher.Bind(this), this.BREADCRUMB_WATCH_MS)

        if (folderNames.Length > 0) {
            this._RefreshTree(tv, folderMap[rootDDL.Text])
            if (this.lastPath != "") {
                this._FocusPath(tv, this.lastPath)
            }
            this._RefreshBreadcrumb()
        }

        ; マウスカーソルがあるモニタの作業領域中央に配置
        CoordMode "Mouse", "Screen"
        MouseGetPos(&mX, &mY)
        monitorNum := this._GetMonitorFromPos(mX, mY)
        MonitorGetWorkArea(monitorNum, &waL, &waT, &waR, &waB)

        winW := this.GUI_WIDTH + this.WINDOW_FRAME_WIDTH
        winH := this.GUI_HEIGHT_APPROX
        centerX := waL + (waR - waL - winW) // 2
        centerY := waT + (waB - waT - winH) // 2

        this.GuiObj.Show("x" . centerX . " y" . centerY)
    }

    /**
     * アクション選択用のオーバーレイメニュー
     */
    static ShowActionMenu() {
        tvObj := this.GuiObj["FolderTree"]
        if !(id := tvObj.GetSelection()) {
            ToolTip("フォルダを選択してください")
            SetTimer(() => ToolTip(), -1000)
            return
        }

        fullPath := this._GetTVFullPath(tvObj, id)
        this.GuiObj.GetPos(&gx, &gy, &gw, &gh)

        this.GuiObj.Opt("+Disabled")

        actGui := Gui("+Owner" . this.GuiObj.Hwnd . " -Caption +AlwaysOnTop +Border")
        actGui.BackColor := this.MENU_BG_COLOR
        actGui.MarginX := 10
        actGui.MarginY := 15

        actGui.SetFont("s11 w700 cWhite", "Segoe UI")
        folderName := (InStr(fullPath, "\")) ? StrSplit(fullPath, "\")[-1] : fullPath
        actGui.Add("Text", "Center w" . this.MENU_BTN_W, "Selected: " . folderName)

        actGui.SetFont("s10 w400")
        ; レジストリに登録されたアクションからボタンを生成
        keys := []
        for k, _ in this.Actions
            keys.Push(k)
        ; AHK v2 arrays don't have a Sort method. Use global Sort() on a joined string.
        if (keys.Length > 1) {
            tmp := ""
            for _, kk in keys
                tmp .= kk . "`n"
            tmp := Sort(RTrim(tmp, "`n"))
            keys := StrSplit(tmp, "`n")
        }

        for k in keys {
            act := this.Actions[k]
            btn := actGui.Add("Button", "w" . this.MENU_BTN_W . " h" . this.MENU_BTN_H . " xm", act.label)
            btn.OnEvent("Click", ((kk, *) => (
                this.GuiObj.Opt("-Disabled"),
                actGui.Destroy(),
                this.Execute(kk)
            )).Bind(k))
        }

        btnCancel := actGui.Add("Button", "w" . this.MENU_BTN_W . " h" . this.MENU_BTN_H . " xm y+12", "&X: Cancel")
        btnCancel.OnEvent("Click", (*) => (this.GuiObj.Opt("-Disabled"), actGui.Destroy()))
        actGui.OnEvent("Escape", (*) => (this.GuiObj.Opt("-Disabled"), actGui.Destroy()))

        actGui.Show("AutoSize x" . gx + (gw - this.MENU_WIDTH) // 2 . " y" . gy + (gh - this.MENU_OFFSET_Y) // 2)
    }

    static Execute(key) {
        fullPath := ""
        if (this.GuiObj && WinExist(this.GuiObj)) {
            tvObj := this.GuiObj["FolderTree"]
            if (id := tvObj.GetSelection()) {
                fullPath := this._GetTVFullPath(tvObj, id)
                ; 操作したパスとルート名をメモリに保存
                this.lastPath := fullPath
                this.lastRoot := this.GuiObj["RootDDL"].Text
            }
        }
        if (fullPath == "") {
            fullPath := this._GetActiveWindowPath()
        }

        if (fullPath != "" && (DirExist(fullPath) || FileExist(fullPath))) {
            this._ExecuteAction(key, fullPath)
            if (this.GuiObj && WinExist(this.GuiObj)) {
                ; 検索アクション(f:Local)はクローズしない
                k := StrLower(key)
                if (k != "f") {
                    if (!this.GuiObj["PinCheck"].Value && !GetKeyState("Shift", "P")) {
                        this._DestroyGui()
                    }
                }
            }
            if (key != "k" && StrLower(key) != "f") {
                ToolTip("実行 [" . key . "]: " . fullPath)
                SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
            }
        } else {
            ToolTip("対象のパスが見つかりません")
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
        }
    }

    static _FocusPath(tv, targetPath) {
        if (!DirExist(targetPath) && !FileExist(targetPath))
            return

        currentID := tv.GetNext(0, "Full")
        if (currentID == 0)
            return

        rootPath := tv.GetText(currentID)
        if (!InStr(targetPath, rootPath))
            return

        relPath := LTrim(StrReplace(targetPath, rootPath, ""), "\")
        parts := StrSplit(relPath, "\")

        for part in parts {
            tv.Modify(currentID, "Expand")
            this._OnItemExpand(tv, currentID)

            childID := tv.GetChild(currentID)
            found := false
            while (childID != 0) {
                if (tv.GetText(childID) == part) {
                    currentID := childID
                    found := true
                    break
                }
                childID := tv.GetNext(childID)
            }
            if (!found)
                break
        }
        tv.Modify(currentID, "Select Vis")
        tv.Focus()
    }

    static _DestroyGui() {
        ; パンくず監視タイマーを停止
        SetTimer(this._BreadcrumbWatcher.Bind(this), 0)
        if (this.GuiObj && WinExist(this.GuiObj)) {
            ; 検索ウィンドウなど付随UIも確実に閉じる
            try NaviSearch._DestroyJumpGui()
            this.GuiObj.Destroy()
            this.GuiObj := ""
        }
    }

    static _ExecuteAction(key, path) {
        k := StrLower(key)
        if (this.Actions.Has(k)) {
            fn := this.Actions[k].run
            ; 関数オブジェクトをプロパティから呼ぶ場合は .Call() を使用
            try {
                fn.Call(path)
            } catch as e {
                ToolTip("Action error: " . e.Message)
                SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            }
        } else {
            ToolTip("未定義のアクション: " . key)
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
        }
    }

    static _ShowEditGui(parentGui) {
        parentGui.GetPos(&px, &py, &pw, &ph)
        parentGui.Opt("+Disabled")
        editGui := Gui("+Owner" . parentGui.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", "ルートディレクトリ管理")
        editGui.SetFont("s10", "Segoe UI")
        lv := editGui.Add("ListView", "r15 w550 Grid Multi vFolderList", ["名称", "パス", "表示"])
        lv.ModifyCol(1, 120), lv.ModifyCol(2, 350), lv.ModifyCol(3, 50)
        this._LoadLVFolders(lv)
        btnAdd := editGui.Add("Button", "xm w70", "追加"), btnMod := editGui.Add("Button", "x+5 w70", "修正"), btnDel :=
        editGui.Add("Button", "x+5 w70", "削除")
        btnUp := editGui.Add("Button", "x+20 w40", "↑"), btnDown := editGui.Add("Button", "x+5 w40", "↓")
        btnSave := editGui.Add("Button", "x+220 w110 Default", "保存/再起動")
        btnAdd.OnEvent("Click", (*) => this._ShowEntryGui(editGui, lv)), btnMod.OnEvent("Click", (*) => this._ShowEntryGui(
            editGui, lv, lv.GetNext())), btnDel.OnEvent("Click", (*) => this._DeleteItem(lv, editGui))
        btnUp.OnEvent("Click", (*) => this._MoveItem(lv, -1)), btnDown.OnEvent("Click", (*) => this._MoveItem(lv, 1)),
        btnSave.OnEvent("Click", (*) => this._SaveList(lv))
        lv.OnEvent("DoubleClick", (obj, info) => (info ? this._ShowEntryGui(editGui, lv, info) : 0))
        editGui.OnEvent("Close", (*) => this._CleanupEditGui(parentGui, editGui))
        editGui.Show("Hide"), editGui.GetPos(, , &ew, &eh)
        editGui.Show("x" . px + (pw - ew) // 2 . " y" . py + (ph - eh) // 2)
    }

    static _ShowEntryGui(editGui, lv, row := 0) {
        editGui.GetPos(&ex, &ey, &ew, &eh), editGui.Opt("+Disabled")
        entryGui := Gui("+Owner" . editGui.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", row ? "項目の修正" : "項目の追加")
        entryGui.SetFont("s10", "Segoe UI")
        entryGui.Add("Text", "xm", "名称:"), nameEdit := entryGui.Add("Edit", "xm w400 vName", row ? lv.GetText(row, 1) :
            "")
        entryGui.Add("Text", "xm", "パス:"), pathEdit := entryGui.Add("Edit", "xm w350 vPath", row ? lv.GetText(row, 2) :
            "")
        btnBrowse := entryGui.Add("Button", "x+5 yp w45 h26", "..."), btnBrowse.OnEvent("Click", (*) => this._HandleDirSelect(
            entryGui, pathEdit))
        entryGui.Add("Checkbox", "xm vVisible", "プルダウンに表示する").Value := (row == 0 || lv.GetText(row, 3) == "○") ? 1 : 0
        btnOK := entryGui.Add("Button", "xm w100 Default", "OK"), btnOK.OnEvent("Click", (*) => this._ProcessEntry(
            editGui, entryGui, lv, row))
        entryGui.OnEvent("Close", (*) => this._CloseEntry(editGui, entryGui))
        entryGui.Show("Hide"), entryGui.GetPos(, , &nw, &nh)
        entryGui.Show("x" . ex + (ew - nw) // 2 . " y" . ey + (eh - nh) // 2)
    }

    static _GetMonitorFromPos(x, y) {
        loop MonitorGetCount() {
            MonitorGet(A_Index, &L, &T, &R, &B)
            if (x >= L && x <= R && y >= T && y <= B) {
                return A_Index
            }
        }
        return MonitorGetPrimary()
    }

    static _EnsureInScreen(&x, &y, w, h) {
        loop MonitorGetCount() {
            MonitorGetWorkArea(A_Index, &left, &top, &right, &bottom)
            if (x >= left && x <= right && y >= top && y <= bottom) {
                if (x + w > right)
                    x := right - w - this.SCREEN_MARGIN
                if (y + h > bottom)
                    y := bottom - h - this.SCREEN_MARGIN
                if (y < top)
                    y := top + this.SCREEN_MARGIN
                return
            }
        }
    }

    static _HandleDirSelect(gui, edit) {
        gui.Opt("+OwnDialogs")
        sel := DirSelect("*" . edit.Value, 3)
        if (sel != "") {
            edit.Value := sel
        }
    }

    static _LoadLVFolders(lv) {
        try {
            content := IniRead(this.IniPath, "Folders")
            for line in StrSplit(content, "`n") {
                if (InStr(line, "=")) {
                    p := StrSplit(line, "=", , 2), vParts := StrSplit(p[2], "|")
                    isVisible := (vParts.Length > 1 && vParts[2] == "0") ? "×" : "○"
                    lv.Add(, Trim(p[1]), vParts[1], isVisible)
                }
            }
        }
    }

    static _MoveItem(lv, direction) {
        row := lv.GetNext()
        if (row == 0) {
            return
        }
        target := row + direction
        if (target < 1 || target > lv.GetCount()) {
            return
        }
        n1 := lv.GetText(row, 1), p1 := lv.GetText(row, 2), v1 := lv.GetText(row, 3)
        n2 := lv.GetText(target, 1), p2 := lv.GetText(target, 2), v2 := lv.GetText(target, 3)
        lv.Modify(row, , n2, p2, v2), lv.Modify(target, , n1, p1, v1), lv.Modify(target, "Select Focus")
    }

    static _ProcessEntry(editGui, entryGui, lv, row) {
        val := entryGui.Submit(false)
        if (val.Name == "" || val.Path == "") {
            return
        }
        visText := val.Visible ? "○" : "×"
        if (row == 0) {
            lv.Add(, val.Name, val.Path, visText)
        }
        else {
            lv.Modify(row, , val.Name, val.Path, visText)
        }
        this._CloseEntry(editGui, entryGui)
    }

    static _DeleteItem(lv, editGui) {
        ; すべての選択行を取得
        selected := []
        r := 0
        while (r := lv.GetNext(r)) {
            selected.Push(r)
        }
        if (selected.Length > 0) {
            editGui.Opt("+OwnDialogs")
            msg := (selected.Length = 1)
                ? "選択した項目を削除しますか？"
                : selected.Length . " 件の項目を削除しますか？"
            if (MsgBox(msg, "削除確認", "YesNo Icon? 4096") == "Yes") {
                ; 下から削除してインデックスずれを防ぐ
                for i, _ in selected {
                    lv.Delete(selected[selected.Length - i + 1])
                }
            }
        }
    }

    static _CloseEntry(editGui, entryGui) {
        entryGui.Destroy(), editGui.Opt("-Disabled +AlwaysOnTop"), editGui.Show()
    }

    static _CleanupEditGui(parentGui, editGui) {
        editGui.Destroy(), parentGui.Opt("-Disabled +AlwaysOnTop"), parentGui.Show()
    }

    static _SaveList(lv) {
        IniDelete(this.IniPath, "Folders")
        loop lv.GetCount() {
            name := lv.GetText(A_Index, 1), path := lv.GetText(A_Index, 2)
            visible := (lv.GetText(A_Index, 3) == "○") ? "1" : "0"
            IniWrite(path . "|" . visible, this.IniPath, "Folders", name)
        }
        Reload()
    }

    static _LoadFolders(folderMap, folderNames) {
        try {
            content := FileRead(this.IniPath, "UTF-8")
            sect := ""
            for line in StrSplit(content, "`n", "`r") {
                line := Trim(line)
                if (line == "" || SubStr(line, 1, 1) == ";") {
                    continue
                }
                if (RegExMatch(line, "\[(.*)\]", &match)) {
                    sect := match[1]
                    continue
                }
                if (sect == "Folders" && InStr(line, "=")) {
                    p := StrSplit(line, "=", , 2), vParts := StrSplit(Trim(p[2]), "|")
                    name := Trim(p[1]), path := vParts[1], isVisible := (vParts.Length > 1) ? vParts[2] : "1"
                    folderMap[name] := path
                    if (isVisible == "1") {
                        folderNames.Push(name)
                    }
                }
            }
        }
        if (folderNames.Length == 0 && folderMap.Count == 0) {
            folderNames.Push("Desktop"), folderMap["Desktop"] := A_Desktop
        }
    }

    static _EnsureDefaultFolders() {
        try {
            if (IniRead(this.IniPath, "Folders", , "") == "") {
                IniWrite(A_Desktop . "|1", this.IniPath, "Folders", "Desktop")
            }
        } catch {
            IniWrite(A_Desktop . "|1", this.IniPath, "Folders", "Desktop")
        }
    }

    static _LoadConfig() {
        path := ""
        if (FileExist(this.IniPath)) {
            path := IniRead(this.IniPath, "Settings", "ExplorerPath", "")
        }
        if (path == "" || (path != "explorer.exe" && !FileExist(path))) {
            msg := "ファイラーを設定してください。`n[はい] 外部ファイラー / [いいえ] 標準エクスプローラー"
            if (MsgBox(msg, "Navi - 初期設定", "YesNo Icon? 4096") == "Yes") {
                sel := FileSelect(3, , "exeを選択", "(*.exe)"), path := (sel != "") ? sel : "explorer.exe"
            } else {
                path := "explorer.exe"
            }
            IniWrite(path, this.IniPath, "Settings", "ExplorerPath")
        }
        return path
    }

    static _RefreshTree(tv, rootPath) {
        tv.Delete()
        if (!DirExist(rootPath)) {
            return
        }
        rootID := tv.Add(rootPath, 0, "Expand Select"), this._LoadSub(tv, rootPath, rootID), tv.Focus()
    }

    static _LoadSub(tv, path, parentID) {
        loop files, path . "\*", "D" {
            if (SubStr(A_LoopFileName, 1, 1) == "." || InStr(A_LoopFileAttrib, "H")) {
                continue
            }
            tv.Add("...loading...", tv.Add(A_LoopFileName, parentID))
        }
    }

    static _OnItemExpand(tv, id) {
        child := tv.GetChild(id)
        if (child == 0 || tv.GetText(child) != "...loading...") {
            return
        }
        tv.Delete(child), this._LoadSub(tv, this._GetTVFullPath(tv, id), id)
    }

    static _GetTVFullPath(tv, id) {
        parts := [], currID := id
        while (currID != 0) {
            txt := tv.GetText(currID), parts.InsertAt(1, txt)
            if (InStr(txt, ":\")) {
                break
            }
            currID := tv.GetParent(currID)
        }
        path := ""
        for i, p in parts {
            path := (i == 1) ? p : RTrim(path, "\") . "\" . p
        }
        return path
    }

    ; --- パンくずリスト関連 ---
    static _BreadcrumbWatcher() {
        try {
            if !(this.GuiObj && this.GuiObj.Hwnd && WinExist("ahk_id " this.GuiObj.Hwnd)) {
                SetTimer(this._BreadcrumbWatcher.Bind(this), 0)
                return
            }
            tv := this.GuiObj["FolderTree"]
            id := tv.GetSelection()
            if (id != this.lastSelectedId) {
                this.lastSelectedId := id
                this._UpdateBreadcrumb(tv, id)
            }
        }
    }

    static _RefreshBreadcrumb() {
        try {
            if !(this.GuiObj && this.GuiObj.Hwnd && WinExist("ahk_id " this.GuiObj.Hwnd))
                return
            tv := this.GuiObj["FolderTree"]
            id := tv.GetSelection()
            this.lastSelectedId := id
            this._UpdateBreadcrumb(tv, id)
        }
    }

    static _UpdateBreadcrumb(tv, id) {
        try {
            if !(this.GuiObj && this.GuiObj.Hwnd)
                return
            if (id = 0) {
                this.GuiObj["Breadcrumb"].Value := ""
                return
            }
            fullPath := this._GetTVFullPath(tv, id)
            displayPath := fullPath
            if (StrLen(displayPath) > this.BREADCRUMB_MAX_LEN) {
                displayPath := "..." . SubStr(displayPath, -(this.BREADCRUMB_MAX_LEN - 3))
            }
            this.GuiObj["Breadcrumb"].Value := displayPath
        }
    }

    static _OnBreadcrumbClick() {
        tv := this.GuiObj["FolderTree"]
        id := tv.GetSelection()
        if (id = 0)
            return

        ; 現在のパスから各階層をメニューに表示
        pathParts := []
        currID := id
        while (currID != 0) {
            pathParts.InsertAt(1, {id: currID, name: tv.GetText(currID)})
            currID := tv.GetParent(currID)
        }

        if (pathParts.Length = 0)
            return

        ; ポップアップメニューを作成
        bcMenu := Menu()
        for i, part in pathParts {
            partID := part.id
            indent := ""
            loop i - 1
                indent .= "    "
            bcMenu.Add(indent . part.name, ((pid, *) => this._JumpToTreeItem(pid)).Bind(partID))
        }
        bcMenu.Show()
    }

    static _JumpToTreeItem(id) {
        tv := this.GuiObj["FolderTree"]
        tv.Modify(id, "Select Vis")
        if (tv.GetChild(id)) {
            tv.Modify(id, "Expand")
            this._OnItemExpand(tv, id)
        }
        tv.Focus()
    }

    static _GetActiveWindowPath() {
        hwnd := WinExist("A")
        if (hwnd == 0) {
            return ""
        }
        cls := WinGetClass("A")
        if (cls == "CabinetWClass" || cls == "ExploreWClass" || cls == "Progman" || cls == "WorkerW" || InStr(cls,
            "Tablacus")) {
            try {
                shellApp := ComObject("Shell.Application")
                for window in shellApp.Windows {
                    if (window && window.hwnd == hwnd) {
                        return window.Document.Folder.Self.Path
                    }
                }
            }
        }
        return ""
    }

    static _QuickRegisterFromEdit() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        e := this.GuiObj["QuickPath"]
        path := Trim(e.Value)
        if (path = "")
            return
        if (!DirExist(path)) {
            ToolTip("無効なパスです"), SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }
        name := StrSplit(RTrim(path, "\"), "\")[-1]

        ; INIへ書き込み（表示=1）
        IniWrite(path . "|1", this.IniPath, "Folders", name)

        ; DDLの先頭に表示させる（新しいリストを作り直す）
        folderMap := Map(), folderNames := []
        this._LoadFolders(folderMap, folderNames)

        newNames := [name]
        for n in folderNames {
            if (n != name)
                newNames.Push(n)
        }

        ddl := this.GuiObj["RootDDL"]
        tv := this.GuiObj["FolderTree"]
        ddl.Delete()
        ddl.Add(newNames)
        ddl.Text := name

        this.lastRoot := name
        this.lastPath := path
        this._RefreshTree(tv, path)

        e.Value := ""
        ToolTip("Root added: " . name), SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
    }

    static _HandleEnter() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        ; 現在のフォーカスHWNDを取得（まずはAHK API、失敗時はWinAPIにフォールバック）
        currFocus := 0
        try {
            ctrl := ControlGetFocus("ahk_id " this.GuiObj.Hwnd)
            currFocus := ControlGetHwnd(ctrl, "ahk_id " this.GuiObj.Hwnd)
        } catch {
            try {
                currFocus := DllCall("user32\GetFocus", "ptr")
            } catch {
                currFocus := 0
            }
        }

        if (this.QuickPathHwnd && currFocus = this.QuickPathHwnd) {
            ; クイック登録欄がフォーカスなら登録を優先
            this._QuickRegisterFromEdit()
            return
        }
        ; それ以外は従来通りエクスプローラー実行
        this.Execute("e")
    }

    static ToggleFilesUnderSelection() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        tv := this.GuiObj["FolderTree"]
        id := tv.GetSelection()
        if (id = 0)
            return
        full := this._GetTVFullPath(tv, id)
        if (!DirExist(full)) {
            return
        }
        ; 既に表示済みなら削除
        if (this.FilesShown.Has(id)) {
            for _, cid in this.FilesShown[id] {
                try tv.Delete(cid)
            }
            this.FilesShown.Delete(id)
            ToolTip("Files hidden"), SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
            return
        }
        ; 表示（上限FileMax、既定200）
        fileMax := 200
        try fileMax := Integer(IniRead(this.IniPath, "Settings", "FileMax", "200"))
        shown := []
        count := 0
        loop files, full . "\*", "F" {
            if InStr(A_LoopFileAttrib, "H")
                continue
            fid := tv.Add(A_LoopFileName, id)
            shown.Push(fid)
            count += 1
            if (count >= fileMax)
                break
        }
        this.FilesShown[id] := shown
        ToolTip("Files shown: " . count), SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
    }

    /**
     * 選択ファイルをNaviと同階層(ui)の一時フォルダにコピーし、既定アプリで開く
     * ファイル名に TEMP_YYYYMMDD-HHMMSS_ の接頭辞を付与
     */
    static _OpenTempCopy(path) {
        tempDir := A_ScriptDir . this.TEMP_DIR_SUBPATH
        try {
            if (!DirExist(tempDir))
                DirCreate(tempDir)
        } catch as e {
            ToolTip("一時フォルダ作成失敗: " . e.Message)
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }
        if (DirExist(path)) {
            ; フォルダ選択時はテンポラリフォルダを開く
            Run('explorer.exe "' . tempDir . '"')
            ToolTip("Temp folder opened: " . tempDir)
            SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
            return
        }
        if (!FileExist(path)) {
            ToolTip("ファイルが見つかりません")
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }
        SplitPath(path, &fileName)
        ts := FormatTime(, "yyyyMMdd-HHmmss") ; YYYYMMDD-HHMMSS
        dest := tempDir . "\" . this.TEMP_PREFIX . ts . "_" . fileName
        try {
            FileCopy(path, dest, true)
            Run('"' . dest . '"')
            ToolTip("Temp copy opened: " . dest)
            SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
        } catch as e {
            ToolTip("コピーまたは起動に失敗: " . e.Message)
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
        }
    }

    static _InitDefaultActions() {
        this.RegisterAction("e", "&E: Explorer", (path) => Run('explorer.exe "' . path . '"'))
        this.RegisterAction("t", "&t: Preferred Explorer", (path) => (
            (this.ExplorerPath == "explorer.exe")
                ? Run('explorer.exe "' . path . '"')
                : (FileExist(this.ExplorerPath) ? Run('"' . this.ExplorerPath . '" "' . path . '"') : 0)
        ))
        this.RegisterShellAction("v", "&V: VS Code", A_ComSpec . ' /c code "{path}"', "Hide")
        this.RegisterShellAction("c", "&C: Command Prompt", A_ComSpec . ' /K cd /d "{path}"')
        this.RegisterShellAction("p", "&P: PowerShell",
            'powershell.exe -NoExit -Command Set-Location -LiteralPath "{path}"')
        this.RegisterAction("k", "&K: Copy Path", (path) => (A_Clipboard := path, ToolTip("Path Copied: " . path),
        SetTimer(() => ToolTip(), -this.TOOLTIP_COPY_DURATION)))
        ; ファイル/フォルダ名のみをコピー
        this.RegisterAction("n", "&N: Copy Name", (path) => (
            SplitPath(path, &fn),
            name := (fn != "" ? fn : path),
            A_Clipboard := name,
            ToolTip("Name Copied: " . name),
            SetTimer(() => ToolTip(), -this.TOOLTIP_COPY_DURATION)
        ))
        ; 一時コピーを作成して開く
        this.RegisterAction("o", "&O: Open Temp Copy", (path) => this._OpenTempCopy(path))
        ; ローカル再帰検索
        this.RegisterAction("f", "&F: Search (Local)", (path) => NaviSearch.RunLocal(this, path))
    }

    static _LoadUserActions() {
        try {
            content := IniRead(this.IniPath, "Actions", , "")
            for line in StrSplit(content, "`n", "`r") {
                if !InStr(line, "=")
                    continue
                kv := StrSplit(line, "=", , 2)
                key := Trim(kv[1])
                parts := StrSplit(Trim(kv[2]), "|")
                if (parts.Length >= 3) {
                    label := parts[1]
                    kind := StrLower(parts[2])
                    if (kind = "shell") {
                        cmd := parts[3]
                        opt := (parts.Length >= 4) ? parts[4] : ""
                        this.RegisterShellAction(key, label, cmd, opt)
                    }
                }
            }
        }
    }
}
