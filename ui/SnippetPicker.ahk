; ==============================================================================
; Module:       SnippetPicker.ahk
; Description:  定型文（スニペット）の検索・挿入・管理ツール
;               - グループ（セクション）による分類と検索フィルタリング
;               - 管理画面での追加・修正・一括削除・順序入れ替え (↑/↓) 対応
;               - モーダル制御により、編集時のダイアログ背面隠れを防止
;               - マジックナンバーを定数化し、高い保守性と視認性を確保
; Version:      1.0.0
; License:      MIT
;
; Usage Example (Main.ahk):
;   #Include ui\SnippetPicker.ahk
;   SnippetPicker.Init()
;   vk1D & p:: SnippetPicker.Show() ; 無変換 + p で起動
;
; ==============================================================================

#Requires AutoHotkey v2.0

class SnippetPicker {
    ; --- クラス定数 ---
    static GUI_WIDTH := 600
    static LV_ROWS := 18
    static BTN_WIDTH := 100
    static COLOR_EDIT_BG := "E1ECF4"
    static COLOR_HEADER := "004080"
    static FLAG_MODAL := 4096
    static SLEEP_PASTE := 100
    static TIMER_RESTORE := -500

    static IniPath := A_ScriptDir "\ui\SnippetsPicker.ini"
    static SnipList := []
    static GuiObj := ""
    static LvObj := ""
    static SearchObj := ""

    static Init() {
        this._PrepareFile()
        this._LoadData()
        this._BuildGui()
    }

    ; --- 検索画面の表示（キャレット追従・反転ロジック） ---
    static Show() {
        this.SearchObj.Value := ""
        this._FilterList("")

        CoordMode "Caret", "Screen"
        CoordMode "Mouse", "Screen"

        this.GuiObj.Opt("+LastFound")
        hWnd := WinExist()
        WinGetPos(, , &curW, &curH, hWnd)

        realH := (curH > 0) ? curH : 480
        realW := (curW > 0) ? curW : this.GUI_WIDTH

        targetX := 0
        targetY := 0

        if CaretGetPos(&cX, &cY) {
            targetX := cX + 5
            monitorNum := this._GetMonitorFromPos(cX, cY)
            MonitorGetWorkArea(monitorNum, &L, &T, &R, &B)

            if (cY + 25 + realH > B) {
                targetY := cY - realH - 10
            } else {
                targetY := cY + 25
            }
        } else {
            MouseGetPos(&mX, &mY)
            targetX := mX + 15
            targetY := mY + 15
        }

        this._EnsureInScreen(&targetX, &targetY, realW, realH)
        this.GuiObj.Show("x" . targetX . " y" . targetY)
        this.SearchObj.Focus()
    }

    ; --- 管理画面（メインウィンドウの中央に配置） ---
    static _ShowEditGui() {
        this.GuiObj.GetPos(&gx, &gy, &gw, &gh)
        this.GuiObj.Opt("+Disabled")

        editGui := Gui("+AlwaysOnTop -MaximizeBox", "登録内容の編集")
        editGui.BackColor := this.COLOR_EDIT_BG
        editGui.SetFont("s11 Bold", "Segoe UI")
        editGui.Add("Text", "xm w580 Center c" this.COLOR_HEADER, "--- 登録内容の編集 ---")
        editGui.SetFont("s10 Norm", "Segoe UI")

        lv := editGui.Add("ListView", "xm r15 w580 Grid", ["グループ", "名称", "内容"])
        lv.ModifyCol(1, 100), lv.ModifyCol(2, 120), lv.ModifyCol(3, 330)

        for item in this.SnipList {
            lv.Add(, item.group, item.title, item.content)
        }

        lv.OnEvent("DoubleClick", (obj, info) => (info ? this._ShowEntryGui(editGui, lv, info) : 0))

        editGui.Add("Button", "xm w70", "追加").OnEvent("Click", (*) => this._ShowEntryGui(editGui, lv, 0))
        editGui.Add("Button", "x+5 w70", "修正").OnEvent("Click", (*) => (
            (r := lv.GetNext()) ? this._ShowEntryGui(editGui, lv, r) : this._ModalAction(editGui, () => MsgBox(
                "修正行を選択してください。", "警告", "Icon! " this.FLAG_MODAL))
        ))
        editGui.Add("Button", "x+5 w70", "削除").OnEvent("Click", (*) => this._DeleteItem(lv, editGui))
        editGui.Add("Button", "x+20 w40", "↑").OnEvent("Click", (*) => this._MoveItem(lv, -1))
        editGui.Add("Button", "x+5 w40", "↓").OnEvent("Click", (*) => this._MoveItem(lv, 1))

        btnSave := editGui.Add("Button", "xm w150 Default h30", "保存して反映")
        btnSave.OnEvent("Click", (*) => this._HandleSave(editGui, lv))

        editGui.OnEvent("Close", (*) => this._CleanupEditGui(editGui))

        editGui.Show("Hide")
        editGui.GetPos(, , &ew, &eh)
        editGui.Show("x" . gx + (gw - ew) // 2 . " y" . gy + (gh - eh) // 2)
    }

    ; --- 追加・修正画面（管理画面の中央に配置） ---
    static _ShowEntryGui(parentGui, lv, row := 0) {
        parentGui.GetPos(&px, &py, &pw, &ph)
        parentGui.Opt("+Disabled")

        entryGui := Gui("+AlwaysOnTop", row ? "項目の修正" : "新規追加")
        entryGui.SetFont("s10", "Segoe UI")
        entryGui.Add("Text", , "グループ:")
        entryGui.Add("Edit", "w400 vGroup", row ? lv.GetText(row, 1) : "Default")
        entryGui.Add("Text", , "名称:")
        entryGui.Add("Edit", "w400 vName", row ? lv.GetText(row, 2) : "")
        entryGui.Add("Text", , "内容:")
        entryGui.Add("Edit", "w400 r10 vContent", row ? lv.GetText(row, 3) : "")

        btnOk := entryGui.Add("Button", "xm w100 Default", "OK")
        btnOk.OnEvent("Click", (*) => this._ProcessEntry(parentGui, entryGui, lv, row))

        btnCancel := entryGui.Add("Button", "x+5 w100", "キャンセル")
        btnCancel.OnEvent("Click", (*) => this._CloseEntry(parentGui, entryGui))

        entryGui.OnEvent("Close", (*) => this._CloseEntry(parentGui, entryGui))

        entryGui.Show("Hide")
        entryGui.GetPos(, , &nw, &nh)
        entryGui.Show("x" . px + (pw - nw) // 2 . " y" . py + (ph - nh) // 2)
    }

    ; --- モーダル制御（MsgBoxの位置固定） ---
    static _ModalAction(targetGui, actionCallback) {
        targetGui.Opt("+OwnDialogs")
        return actionCallback()
    }

    ; --- 以降、内部ロジック ---
    static _HandleSave(editGui, lv) {
        this._SaveList(lv)
        editGui.Destroy()
        this.GuiObj.Opt("-Disabled")
        this.GuiObj.Show()
    }

    static _CleanupEditGui(editGui) {
        editGui.Destroy()
        this.GuiObj.Opt("-Disabled")
        this.GuiObj.Show()
    }

    static _ProcessEntry(parentGui, entryGui, lv, row) {
        res := entryGui.Submit(false)
        if (res.Group == "" || res.Name == "" || res.Content == "") {
            this._ModalAction(entryGui, () => MsgBox("全項目入力してください。", "エラー", "Icon! " this.FLAG_MODAL))
            return
        }
        if (row == 0) {
            lv.Add(, res.Group, res.Name, res.Content)
        } else {
            lv.Modify(row, , res.Group, res.Name, res.Content)
        }
        this._CloseEntry(parentGui, entryGui)
    }

    static _CloseEntry(parentGui, entryGui) {
        entryGui.Destroy()
        parentGui.Opt("-Disabled")
        parentGui.Show()
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
        g1 := lv.GetText(row, 1), t1 := lv.GetText(row, 2), c1 := lv.GetText(row, 3)
        g2 := lv.GetText(target, 1), t2 := lv.GetText(target, 2), c2 := lv.GetText(target, 3)
        lv.Modify(row, , g2, t2, c2)
        lv.Modify(target, , g1, t1, c1)
        lv.Modify(target, "Select Focus")
    }

    static _DeleteItem(lv, editGui) {
        selectedRows := []
        row := 0
        while (row := lv.GetNext(row)) {
            selectedRows.Push(row)
        }
        if (selectedRows.Length == 0) {
            this._ModalAction(editGui, () => MsgBox("削除行を選択してください。", "警告", "Icon! " this.FLAG_MODAL))
            return
        }
        confirmMsg := (selectedRows.Length == 1) ? "削除しますか？" : selectedRows.Length " 件削除しますか？"
        if (this._ModalAction(editGui, () => MsgBox(confirmMsg, "確認", "YesNo Icon? " this.FLAG_MODAL)) == "Yes") {
            loop selectedRows.Length {
                lv.Delete(selectedRows.Pop())
            }
        }
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

    static _SaveList(lv) {
        if FileExist(this.IniPath) {
            FileDelete(this.IniPath)
        }
        loop lv.GetCount() {
            group := lv.GetText(A_Index, 1), title := lv.GetText(A_Index, 2), content := lv.GetText(A_Index, 3)
            contentSave := StrReplace(content, "`r`n", "\n")
            contentSave := StrReplace(contentSave, "`n", "\n")
            IniWrite('"' contentSave '"', this.IniPath, group, title)
        }
        this._LoadData()
        this._FilterList(this.SearchObj.Value)
    }

    static _LoadData() {
        this.SnipList := []
        currentSection := "Default"
        try {
            content := FileRead(this.IniPath, "UTF-8")
            for line in StrSplit(content, "`n", "`r") {
                line := Trim(line)
                if (line == "" || SubStr(line, 1, 1) == ";") {
                    continue
                }
                if (RegExMatch(line, "^\[(.+)\]$", &match)) {
                    currentSection := match[1]
                    continue
                }
                pos := InStr(line, "=")
                if (pos > 1) {
                    key := Trim(SubStr(line, 1, pos - 1)), val := Trim(SubStr(line, pos + 1))
                    val := RegExReplace(val, '^"|"$', '')
                    this.SnipList.Push({ group: currentSection, title: key, content: StrReplace(val, "\n", "`r`n") })
                }
            }
        }
    }

    static _BuildGui() {
        this.GuiObj := Gui("+AlwaysOnTop", "Snippets Picker [検索]")
        this.GuiObj.SetFont("s10", "Segoe UI")
        this.SearchObj := this.GuiObj.AddEdit("xm w" this.GUI_WIDTH)
        this.SearchObj.OnEvent("Change", (ed, *) => this._FilterList(ed.Value))
        this.LvObj := this.GuiObj.AddListView("xm w" this.GUI_WIDTH " r" this.LV_ROWS " -Multi Grid", ["グループ", "名称",
            "内容"])
        this.LvObj.ModifyCol(1, 80), this.LvObj.ModifyCol(2, 150)
        this.LvObj.OnEvent("DoubleClick", (*) => this._InsertSelected())
        this.GuiObj.AddButton("xm w" this.BTN_WIDTH " Default -Tabstop", "Insert").OnEvent("Click", (*) => this._InsertSelected())
        this.GuiObj.AddButton("x+5 w" this.BTN_WIDTH " -Tabstop", "Manage").OnEvent("Click", (*) => this._ShowEditGui())
        this.GuiObj.AddButton("x+5 w" this.BTN_WIDTH " -Tabstop", "Reload").OnEvent("Click", (*) => (this._LoadData(),
        this._FilterList()))
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Enter", (*) => this._InsertSelected(), "On"), Hotkey("Esc", (*) => this.GuiObj.Hide(), "On")
        HotIf()
    }

    static _FilterList(query := "") {
        this.LvObj.Delete()
        for item in this.SnipList {
            if (query == "" || InStr(item.group, query) || InStr(item.title, query) || InStr(item.content, query)) {
                this.LvObj.Add(, item.group, item.title, StrReplace(item.content, "`r`n", " "))
            }
        }
        if (this.LvObj.GetCount() > 0) {
            this.LvObj.Modify(1, "Select Focus")
        }
    }

    static _InsertSelected() {
        row := this.LvObj.GetNext(0, "F")
        if (row == 0) {
            return
        }
        dispG := this.LvObj.GetText(row, 1), dispT := this.LvObj.GetText(row, 2)
        for item in this.SnipList {
            if (item.group == dispG && item.title == dispT) {
                this.GuiObj.Hide()
                this._QuickPaste(item.content)
                return
            }
        }
    }

    static _QuickPaste(text) {
        oldClip := ClipboardAll()
        A_Clipboard := text
        Sleep(this.SLEEP_PASTE)
        Send("^v")
        SetTimer((*) => (A_Clipboard := oldClip), this.TIMER_RESTORE)
    }

    static _PrepareFile() {
        if !DirExist(A_ScriptDir "\ui") {
            DirCreate(A_ScriptDir "\ui")
        }
    }
}
