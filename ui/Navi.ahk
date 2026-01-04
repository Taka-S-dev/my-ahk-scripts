; ==============================================================================
; Module:       Navi.ahk
; Description:  汎用フォルダランチャー & アクティブパス実行ツール
;               - フォルダパスのTreeView表示とクイックアクセス
;               - 表示・非表示の個別/一括切り替え機能
;               - リストの順序入れ替え（上下移動）
;               - 外部ファイラー（Tablacus等）やVSCodeへのパス渡し
; Version:      1.0.0
; License:      MIT
;
; Usage Example (Main.ahk):
;   #Include ui\Navi.ahk
;   Navi.Init()
;   vk1D & f:: Navi.Show() ; 無変換 + f で起動
; ==============================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force

class Navi {
    ; --- クラス定数 ---
    static GUI_WIDTH := 450
    static GUI_HEIGHT_APPROX := 520
    static IniPath := A_ScriptDir "\ui\Navi.ini"
    static ExplorerPath := ""
    static TOOLTIP_ERROR_DURATION := 2000
    static TOOLTIP_SUCCESS_DURATION := 1000

    ; GUIオブジェクトを保持するスタティック変数
    static GuiObj := ""

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
    }

    ; --- 1. メイン画面の表示（シングルトン & 位置制御） ---
    static Show() {
        if (this.ExplorerPath == "") {
            this.Init()
        }

        ; すでにウィンドウが開いている場合は一旦破棄する（シングルトン制御）
        if (this.GuiObj) {
            this.GuiObj.Destroy()
        }

        this.GuiObj := Gui("+AlwaysOnTop", "Navi - Folder Launcher")
        this.GuiObj.SetFont("s10", "Segoe UI")

        folderMap := Map(), folderNames := []
        this._LoadFolders(folderMap, folderNames)

        rootDDL := this.GuiObj.Add("DropDownList", "xm w280 Choose1 vRootDDL", folderNames)
        btnEdit := this.GuiObj.Add("Button", "x+5 yp w45 h28 -Tabstop", "Edit")
        this.GuiObj.Add("Checkbox", "x+10 yp vPinCheck -Tabstop", "Pin")
        tv := this.GuiObj.Add("TreeView", "xm w450 r20 vFolderTree")

        ; イベント登録
        rootDDL.OnEvent("Change", (*) => this._RefreshTree(tv, folderMap[rootDDL.Text]))
        btnEdit.OnEvent("Click", (*) => this._ShowEditGui(this.GuiObj))
        tv.OnEvent("ItemExpand", (obj, id, *) => this._OnItemExpand(obj, id))
        tv.OnEvent("DoubleClick", (obj, id, *) => this._HandleGUIAction(this.GuiObj, tv, id, "e"))
        this.GuiObj.OnEvent("Close", (*) => (this.GuiObj := ""))

        ; ホットキー登録
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("vk1D & t", (*) => this._HandleGUIAction(this.GuiObj, tv, tv.GetSelection(), "t"), "On")
        Hotkey("vk1D & v", (*) => this._HandleGUIAction(this.GuiObj, tv, tv.GetSelection(), "v"), "On")
        Hotkey("vk1D & c", (*) => this._HandleGUIAction(this.GuiObj, tv, tv.GetSelection(), "c"), "On")
        Hotkey("vk1D & e", (*) => this._HandleGUIAction(this.GuiObj, tv, tv.GetSelection(), "e"), "On")
        Hotkey("Enter", (*) => this._HandleGUIAction(this.GuiObj, tv, tv.GetSelection(), "e"), "On")
        Hotkey("^k", (*) => (this.GuiObj["PinCheck"].Value := !this.GuiObj["PinCheck"].Value), "On")
        Hotkey("Esc", (*) => this.GuiObj.Destroy(), "On")
        HotIf()

        if (folderNames.Length > 0) {
            this._RefreshTree(tv, folderMap[folderNames[1]])
        }

        ; --- 表示位置の計算（キャレット追従・反転） ---
        CoordMode "Caret", "Screen"
        CoordMode "Mouse", "Screen"

        targetX := 0, targetY := 0

        if CaretGetPos(&cX, &cY) {
            targetX := cX + 5
            monitorNum := this._GetMonitorFromPos(cX, cY)
            MonitorGetWorkArea(monitorNum, &L, &T, &R, &B)

            if (cY + 25 + this.GUI_HEIGHT_APPROX > B) {
                targetY := cY - this.GUI_HEIGHT_APPROX - 10
            } else {
                targetY := cY + 25
            }
        } else {
            MouseGetPos(&mX, &mY)
            targetX := mX + 15, targetY := mY + 15
        }

        this._EnsureInScreen(&targetX, &targetY, this.GUI_WIDTH, this.GUI_HEIGHT_APPROX)
        this.GuiObj.Show("x" . targetX . " y" . targetY)
    }

    ; --- 2. 管理画面（中心揃え） ---
    static _ShowEditGui(parentGui) {
        parentGui.GetPos(&px, &py, &pw, &ph)
        parentGui.Opt("+Disabled")

        editGui := Gui("+Owner" . parentGui.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", "ルートディレクトリ管理")
        editGui.SetFont("s10", "Segoe UI")

        lv := editGui.Add("ListView", "r15 w550 Grid vFolderList", ["名称", "パス", "表示"])
        lv.ModifyCol(1, 120), lv.ModifyCol(2, 350), lv.ModifyCol(3, 50)

        this._LoadLVFolders(lv)

        btnAdd := editGui.Add("Button", "xm w70", "追加")
        btnMod := editGui.Add("Button", "x+5 w70", "修正")
        btnDel := editGui.Add("Button", "x+5 w70", "削除")
        btnUp := editGui.Add("Button", "x+20 w40", "↑")
        btnDown := editGui.Add("Button", "x+5 w40", "↓")
        btnAllShow := editGui.Add("Button", "xm w110", "すべて表示")
        btnAllHide := editGui.Add("Button", "x+5 w110", "すべて非表示")
        btnSave := editGui.Add("Button", "x+105 w110 Default", "保存/再起動")

        btnAdd.OnEvent("Click", (*) => this._ShowEntryGui(editGui, lv))
        btnMod.OnEvent("Click", (*) => this._ShowEntryGui(editGui, lv, lv.GetNext()))
        btnDel.OnEvent("Click", (*) => this._DeleteItem(lv, editGui))
        btnUp.OnEvent("Click", (*) => this._MoveItem(lv, -1))
        btnDown.OnEvent("Click", (*) => this._MoveItem(lv, 1))
        btnAllShow.OnEvent("Click", (*) => this._SetAllVisibility(lv, "○"))
        btnAllHide.OnEvent("Click", (*) => this._SetAllVisibility(lv, "×"))
        btnSave.OnEvent("Click", (*) => this._SaveList(lv))

        lv.OnEvent("DoubleClick", (obj, info) => (info ? this._ShowEntryGui(editGui, lv, info) : 0))
        editGui.OnEvent("Close", (*) => this._CleanupEditGui(parentGui, editGui))

        editGui.Show("Hide")
        editGui.GetPos(, , &ew, &eh)
        editGui.Show("x" . px + (pw - ew) // 2 . " y" . py + (ph - eh) // 2)
    }

    ; --- 3. 項目入力画面（中心揃え） ---
    static _ShowEntryGui(editGui, lv, row := 0) {
        editGui.GetPos(&ex, &ey, &ew, &eh)
        editGui.Opt("+Disabled")

        entryGui := Gui("+Owner" . editGui.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", row ? "項目の修正" : "新規項目の追加")
        entryGui.SetFont("s10", "Segoe UI")

        entryGui.Add("Text", "xm", "名称:")
        nameEdit := entryGui.Add("Edit", "xm w400 vName", row ? lv.GetText(row, 1) : "")
        entryGui.Add("Text", "xm", "パス:")
        pathEdit := entryGui.Add("Edit", "xm w350 vPath", row ? lv.GetText(row, 2) : "")
        btnBrowse := entryGui.Add("Button", "x+5 yp w45 h26", "...")
        btnBrowse.OnEvent("Click", (*) => this._HandleDirSelect(entryGui, pathEdit))

        initVisible := (row == 0 || lv.GetText(row, 3) == "○") ? 1 : 0
        entryGui.Add("Checkbox", "xm vVisible", "プルダウンに表示する").Value := initVisible

        btnOK := entryGui.Add("Button", "xm w100 Default", "OK")
        btnOK.OnEvent("Click", (*) => this._ProcessEntry(editGui, entryGui, lv, row))
        btnCancel := entryGui.Add("Button", "x+5 w100", "キャンセル")
        btnCancel.OnEvent("Click", (*) => this._CloseEntry(editGui, entryGui))
        entryGui.OnEvent("Close", (*) => this._CloseEntry(editGui, entryGui))

        entryGui.Show("Hide")
        entryGui.GetPos(, , &nw, &nh)
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
                if (x + w > right) {
                    x := right - w - 10
                }
                if (y + h > bottom) {
                    y := bottom - h - 10
                }
                if (y < top) {
                    y := top + 10
                }
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

    static _SetAllVisibility(lv, stateText) {
        loop lv.GetCount() {
            lv.Modify(A_Index, , , , stateText)
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
            entryGui.Opt("+OwnDialogs"), MsgBox("名称とパスを入力してください。", "エラー", "Icon! 4096")
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
        row := lv.GetNext()
        if (row == 0) {
            editGui.Opt("+OwnDialogs"), MsgBox("削除する行を選択してください。", "Navi", "Icon! 4096")
            return
        }
        editGui.Opt("+OwnDialogs")
        if (MsgBox("削除しますか？", "確認", "YesNo Icon? 4096") == "Yes") {
            lv.Delete(row)
        }
    }

    static _CloseEntry(editGui, entryGui) {
        entryGui.Destroy()
        editGui.Opt("-Disabled +AlwaysOnTop"), editGui.Show()
    }

    static _CleanupEditGui(parentGui, editGui) {
        editGui.Destroy()
        parentGui.Opt("-Disabled +AlwaysOnTop"), parentGui.Show()
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

    static _HandleGUIAction(guiObj, tvObj, id, key) {
        if (id == 0) {
            id := tvObj.GetNext()
        }
        if (id == 0) {
            return
        }
        fullPath := this._GetTVFullPath(tvObj, id)
        if (fullPath != "" && DirExist(fullPath)) {
            this._ExecuteExtension(key, fullPath)
            if (!guiObj["PinCheck"].Value && !GetKeyState("Shift", "P")) {
                guiObj.Destroy()
            }
            else {
                ToolTip("Opened: " . key), SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
            }
        }
    }

    static _ExecuteExtension(key, path) {
        switch StrLower(key) {
            case "t":
                if (this.ExplorerPath == "explorer.exe") {
                    Run('explorer.exe "' . path . '"')
                }
                else if (FileExist(this.ExplorerPath)) {
                    Run('"' . this.ExplorerPath . '" "' . path . '"')
                }
            case "v": Run(A_ComSpec . ' /c code "' . path . '"', , "Hide")
            case "c": Run(A_ComSpec . ' /K cd /d "' . path . '"')
            case "e": Run('explorer.exe "' . path . '"')
        }
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

    static _GetActiveWindowPath() {
        hwnd := WinExist("A")
        if (hwnd == 0) {
            return ""
        }
        cls := WinGetClass("A")
        if (cls == "CabinetWClass" || cls == "ExploreWClass" || InStr(cls, "Tablacus")) {
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
}
