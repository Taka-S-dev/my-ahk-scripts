; ==============================================================================
; Module:       SnippetPicker.ahk
; Description:  定型文（スニペット）の検索・挿入・管理ツール
;               - グループ（セクション）による分類と検索フィルタリング
;               - 管理画面での追加・修正・一括削除・順序入れ替え (↑/↓) 対応
;               - モーダル制御により、編集時のダイアログ背面隠れを防止
;               - マジックナンバーを定数化し、高い保守性と視認性を確保
; Version:      1.0.0
; License:      MIT
; Requires:     modules\PlaceholderEngine.ahk
;
;
; Usage Example (Main.ahk):
;   #Include ui\SnippetPicker.ahk
;   SnippetPicker.Init()
;   vk1D & s:: SnippetPicker.Show() ; 無変換 + s で起動
;
;
; ==============================================================================

#Requires AutoHotkey v2.0
#Include "..\modules\PlaceholderEngine.ahk"

class SnippetPicker {
    ; --- クラス定数 ---
    static GUI_WIDTH   := 600
    static GROUP_BTN_W := 130
    static GEAR_BTN_W  := 30
    static LV_ROWS := 18
    static FLAG_MODAL := 4096
    static SLEEP_PASTE := 100
    static TIMER_RESTORE := -500

    static IniPath := A_ScriptDir "\ui\SnippetsPicker.ini"
    static SnipList := []
    static GuiObj   := ""
    static LvObj    := ""
    static SearchObj  := ""
    static GroupBtnObj := ""
    static _GroupList  := []
    static _LastGroup  := "*"

    static Init() {
        this._PrepareFile()
        this._LoadData()
        this._BuildGui()
        this._RebuildGroupList()
    }

    static _ProcessPlaceholders(rawText) {
        return PlaceholderEngine.Apply(rawText)  ; {text, cursorOffset}
    }

    ; --- 検索画面の表示 ---
    static Show() {
        this.SearchObj.Value := ""
        this._RestoreGroup()
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

    ;
    ; --- 管理画面（メインウィンドウの中央に配置） ---
    static _ShowEditGui() {
        this._ChildOpen := true
        this.GuiObj.GetPos(&gx, &gy, &gw, &gh)
        this.GuiObj.Opt("+Disabled")

        editGui := Gui("+AlwaysOnTop -MaximizeBox", "登録内容の編集")
        editGui.SetFont("s10", "Segoe UI")

        lv := editGui.Add("ListView", "xm r15 w580 Grid", ["グループ", "名称", "内容"])
        lv.ModifyCol(1, 100), lv.ModifyCol(2, 120), lv.ModifyCol(3, 330)

        for item in this.SnipList {
            lv.Add(, item.group, item.title, item.content)
        }

        lv.OnEvent("DoubleClick", (obj, info) => (info ? this._ShowEntryGui(editGui, lv, info) : 0))

        editGui.Add("Button", "xm w70", "追加").OnEvent("Click", (*) => this._ShowEntryGui(editGui, lv, 0))
        editGui.Add("Button", "x+5 w70", "修正").OnEvent("Click", (*) =>
            (
                (r := lv.GetNext()) ?
                    this._ShowEntryGui(editGui, lv, r) : this._ModalAction(editGui, () => MsgBox(
                        "修正行を選択してください。", "警告", "Icon! " this.FLAG_MODAL))
            ))
        editGui.Add("Button", "x+5 w70", "削除").OnEvent("Click", (*) => this._DeleteItem(lv, editGui))
        editGui.Add("Button", "x+20 w40", "↑").OnEvent("Click", (*) => this._MoveItem(lv, -1))
        editGui.Add("Button", "x+5 w40", "↓").OnEvent("Click", (*) => this._MoveItem(lv, 1))

        btnSave := editGui.Add("Button", "xm w150 Default h30", "保存して反映")

        btnSave.OnEvent("Click", (*) => this._HandleSave(editGui, lv))

        editGui.OnEvent("Close", (*) => this._CleanupEditGui(editGui))

        HotIfWinActive("ahk_id " editGui.Hwnd)
        Hotkey("Del", (*) => this._DeleteItem(lv, editGui), "On")
        Hotkey("Esc", (*) => this._CleanupEditGui(editGui), "On")
        HotIf()

        editGui.Show("Hide")
        editGui.GetPos(&ex, &ey, &ew, &eh)
        editGui.Show("x" . gx + (gw - ew) // 2 . " y" . gy + (gh - eh) // 2)
    }

    ;
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
        entryGui.Add("Edit", "w400 r10 vContent +0x80 +0x100000 -Wrap", row ? lv.GetText(row, 3) : "")
        entryGui.Add("Button", "x+5 yp w24 h24", "?").OnEvent("Click", (*) => MsgBox(
            "{{clip}}        クリップボードの内容`n"
            "{{cursor}}      挿入後のカーソル位置`n"
            "{{N:ラベル}}    穴埋めフィールド (例: {{1:会社名}})`n"
            "                複数フィールドは番号順に入力フォームが表示されます`n"
            "`n"
            "yyyy/mm/dd  今日の日付 (例: 2025/04/29)`n"
            "yyyy/mm     今月      (例: 2025/04)`n"
            "yyyymm      今月      (例: 202504)`n"
            "yy/mm/dd    今日の日付 (例: 25/04/29)`n"
            "yy/mm       今月      (例: 25/04)`n"
            "yymmdd      今日の日付 (例: 250429)`n"
            "yymm        今月      (例: 2504)`n"
            "HH:mm       現在時刻  (例: 09:30)",
            "使えるプレースホルダー", "Iconi Owner" . entryGui.Hwnd))

        btnOk := entryGui.Add("Button", "xm w100 Default", "OK")
        btnOk.OnEvent("Click", (*) => this._ProcessEntry(parentGui, entryGui, lv, row))

        btnCancel := entryGui.Add("Button", "x+5 w100", "キャンセル")
        btnCancel.OnEvent("Click", (*) => this._CloseEntry(parentGui, entryGui))

        entryGui.OnEvent("Close", (*) => this._CloseEntry(parentGui, entryGui))

        entryGui.Show("Hide")
        entryGui.GetPos(&nx, &ny, &nw, &nh)
        entryGui.Show("x" . px + (pw - nw) // 2 . " y" . py + (ph - nh) // 2)
    }

    ; --- 内部ロジック群 ---
    static _ModalAction(targetGui, actionCallback) {
        targetGui.Opt("+OwnDialogs")
        return actionCallback()
    }

    static _HandleSave(editGui, lv) {
        this._SaveList(lv)
        editGui.Destroy()
        this.GuiObj.Opt("-Disabled")
        this.GuiObj.Show()
    }

    static _CleanupEditGui(editGui) {
        editGui.Destroy()
        this._ChildOpen := false
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
        if FileExist(this.IniPath)
            FileDelete(this.IniPath)
        loop lv.GetCount() {
            group   := lv.GetText(A_Index, 1)
            title   := lv.GetText(A_Index, 2)
            content := lv.GetText(A_Index, 3)
            contentSave := StrReplace(StrReplace(content, "`r`n", "\n"), "`n", "\n")
            sec := "item_" A_Index
            IniWrite(group,       this.IniPath, sec, "group")
            IniWrite(title,       this.IniPath, sec, "title")
            IniWrite(contentSave, this.IniPath, sec, "content")
        }
        this._LoadData()
        this._RebuildGroupList()
        this._FilterList(this.SearchObj.Value)
    }

    static _LoadData() {
        this.SnipList := []
        ; 旧フォーマット（グループ名=セクション、タイトル=キー）を検出して移行
        if FileExist(this.IniPath) {
            raw := FileRead(this.IniPath, "UTF-8")
            if !RegExMatch(raw, "m)^\[item_\d+\]")
                this._MigrateOldFormat(raw)
        }
        i := 1
        loop {
            sec := "item_" i
            try group := IniRead(this.IniPath, sec, "group")
            catch
                break
            title   := IniRead(this.IniPath, sec, "title",   "")
            content := IniRead(this.IniPath, sec, "content", "")
            this.SnipList.Push({group: group, title: title, content: StrReplace(content, "\n", "`r`n")})
            i++
        }
    }

    ; 旧フォーマット（[グループ名] title=content）を新フォーマットに変換
    static _MigrateOldFormat(raw) {
        items := []
        currentGroup := "Default"
        for line in StrSplit(raw, "`n", "`r") {
            line := Trim(line)
            if (line = "" || SubStr(line, 1, 1) = ";")
                continue
            if RegExMatch(line, "^\[(.+)\]$", &m) {
                currentGroup := m[1]
                continue
            }
            pos := InStr(line, "=")
            if (pos > 1) {
                t := Trim(SubStr(line, 1, pos - 1))
                v := RegExReplace(Trim(SubStr(line, pos + 1)), '^"|"$', '')
                items.Push({group: currentGroup, title: t, content: v})
            }
        }
        if FileExist(this.IniPath)
            FileDelete(this.IniPath)
        for i, item in items {
            sec := "item_" i
            IniWrite(item.group,   this.IniPath, sec, "group")
            IniWrite(item.title,   this.IniPath, sec, "title")
            IniWrite(item.content, this.IniPath, sec, "content")
        }
    }

    static _BuildGui() {
        this.GuiObj := Gui("+AlwaysOnTop", "Snippet Picker")
        this.GuiObj.SetFont("s10", "Segoe UI")
        searchW := this.GUI_WIDTH - this.GROUP_BTN_W - this.GEAR_BTN_W - 16
        this.SearchObj := this.GuiObj.AddEdit("xm w" searchW " h24")
        SendMessage(0x1501, 1, StrPtr("🔍  検索..."), this.SearchObj)  ; EM_SETCUEBANNER
        this.SearchObj.OnEvent("Change", (ed, *) => this._FilterList(ed.Value))
        this.GroupBtnObj := this.GuiObj.AddButton("x+8 yp w" this.GROUP_BTN_W " h24 -Tabstop", "*")
        this.GroupBtnObj.OnEvent("Click", (*) => this._ShowGroupPicker())
        this.GuiObj.AddButton("x+8 yp w" this.GEAR_BTN_W " h24 -Tabstop", "⚙").OnEvent("Click", (*) => this._ShowEditGui())
        this.LvObj := this.GuiObj.AddListView("xm w" this.GUI_WIDTH " r" this.LV_ROWS " -Multi Grid", ["グループ", "名称", "内容"])
        this.LvObj.ModifyCol(1, 80), this.LvObj.ModifyCol(2, 150)
        this.LvObj.OnEvent("DoubleClick", (*) => this._InsertSelected())


        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Enter", (*) => this._OnEnter(), "On")
        Hotkey("Down",  (*) => this._NavList(1), "On")
        Hotkey("Up",    (*) => this._NavList(-1), "On")
        Hotkey("Esc",   (*) => (this.SearchObj.Value != "" ? (this.SearchObj.Value := "", this._FilterList("")) : this.GuiObj.Hide()), "On")
        Hotkey("^g",    (*) => this._ShowGroupPicker(), "On")
        HotIf()

        OnMessage(0x0006, (w,l,m,h) => SnippetPicker._OnActivate(w,l,m,h))  ; WM_ACTIVATE
        SetTimer(ObjBindMethod(SnippetPicker, "_HoverTick"), 80)             ; ホバーツールチップ
    }

    static _FilterList(query := "") {
        ; --- クイックトリガー（置換エンジン適用） ---
        if (query == ";today") {
            this.GuiObj.Hide()
            result := this._ProcessPlaceholders("yyyy/mm/dd")
            this._QuickPaste(result.text, result.cursorOffset)
            return
        }

        group := this._LastGroup
        try this.GroupBtnObj.Text := group

        ; グループ列: *表示時のみ表示、絞り込み時は非表示
        if (group = "*") {
            this.LvObj.ModifyCol(1, 80)
            this.LvObj.ModifyCol(2, 150)
        } else {
            this.LvObj.ModifyCol(1, 0)
            this.LvObj.ModifyCol(2, 230)
        }
        SendMessage(0x101E, 2, -2, , "ahk_id " this.LvObj.Hwnd)  ; 最終列を残り幅で埋める

        ; プレフィックスで検索列を切り替え: g:→グループ  c:→内容  なし→名称
        searchField := "title"
        searchQuery := query
        if (SubStr(query, 1, 2) = "g:") {
            searchField := "group"
            searchQuery := SubStr(query, 3)
        } else if (SubStr(query, 1, 2) = "c:") {
            searchField := "content"
            searchQuery := SubStr(query, 3)
        }

        this.LvObj.Delete()
        this._LvIndexMap := []
        for i, item in this.SnipList {
            groupMatch := (group = "*" || item.group = group)
            queryMatch := (searchQuery = "")
                || (searchField = "title"   && InStr(item.title,   searchQuery))
                || (searchField = "group"   && InStr(item.group,   searchQuery))
                || (searchField = "content" && InStr(item.content, searchQuery))
            if (groupMatch && queryMatch) {
                this.LvObj.Add(, item.group, item.title, StrReplace(item.content, "`r`n", " "))
                this._LvIndexMap.Push(i)
            }
        }
        if (this.LvObj.GetCount() > 0)
            this.LvObj.Modify(1, "Select Focus")

        try this.GuiObj.Title := "Snippet Picker  [" this.LvObj.GetCount() " 件]"
    }

    static _RebuildGroupList() {
        this._GroupList := ["*"]
        seen := Map()
        for item in this.SnipList {
            if !seen.Has(item.group) {
                seen[item.group] := true
                this._GroupList.Push(item.group)
            }
        }
    }

    static _RestoreGroup() {
        for g in this._GroupList {
            if (g = this._LastGroup)
                return
        }
        this._LastGroup := "*"
    }

    static _ImeGuard    := false
    static _HoverRow    := 0
    static _ChildOpen   := false
    static _FillInState := ""
    static _LvIndexMap  := []

    static _NavList(dir) {
        count   := this.LvObj.GetCount()
        current := this.LvObj.GetNext(0, "F")
        next    := (current = 0) ? 1 : Max(1, Min(count, current + dir))
        if (next > 0)
            this.LvObj.Modify(next, "Select Focus Vis")
    }

    static _OnEnter() {
        if (this._ImeGuard)
            return
        if (this._IsImeComposing()) {
            this._ImeGuard := true
            Send("{Enter}")
            this._ImeGuard := false
        } else {
            this._InsertSelected()
        }
    }

    static _IsImeComposing() {
        hwnd := this.SearchObj.Hwnd
        hIMC := DllCall("imm32\ImmGetContext", "ptr", hwnd, "ptr")
        if !hIMC
            return false
        len := DllCall("imm32\ImmGetCompositionStringW", "ptr", hIMC, "uint", 0x8, "ptr", 0, "uint", 0, "int")
        DllCall("imm32\ImmReleaseContext", "ptr", hwnd, "ptr", hIMC)
        return len > 0
    }

    static _InsertSelected() {

        row := this.LvObj.GetNext(0, "F")
        if (row = 0 || row > this._LvIndexMap.Length)
            return

        item := this.SnipList[this._LvIndexMap[row]]
        this.GuiObj.GetPos(&_spX, &_spY)
        this.GuiObj.Hide()
        fillIns := PlaceholderEngine.ParseFillIns(item.content)
        if (fillIns.Length > 0) {
            this._ShowFillInGui(item.content, fillIns, item.title, _spX, _spY)
        } else {
            result := this._ProcessPlaceholders(item.content)
            this._QuickPaste(result.text, result.cursorOffset)
        }
    }

    ; Fill In GUI — 1フィールドずつ Enter で確定、プレビューをリアルタイム更新
    static _ShowFillInGui(content, fillIns, title := "", refX := -1, refY := -1) {
        this._ChildOpen   := true
        this._FillInState := {
            content:    content,
            fillIns:    fillIns,
            confirmed:  Map(),
            currentIdx: 1,
            total:      fillIns.Length
        }
        s := this._FillInState

        winTitle := title != "" ? "Fill In  —  " title : "Fill In"
        dlg := Gui("+AlwaysOnTop -MaximizeBox", winTitle)
        dlg.SetFont("s10", "Segoe UI")

        dlg.SetFont("s8 cGray", "Segoe UI")
        s.labelCtrl   := dlg.Add("Text", "xm w520", SnippetPicker._FillInLabelText(s))
        dlg.SetFont("s10 cDefault", "Segoe UI")
        s.inputCtrl   := dlg.Add("Edit", "xm w520", "")
        dlg.Add("Text", "xm w520 0x10")
        lineCount     := StrLen(content) - StrLen(StrReplace(content, "`n", "")) + 1
        previewRows   := Max(4, Min(lineCount + 2, 20))
        dlg.SetFont("s9", "Consolas")
        s.previewCtrl := dlg.Add("Edit", "xm w520 r" previewRows " ReadOnly -Tabstop +0x800", "")
        dlg.SetFont("s10 cDefault", "Segoe UI")

        s.inputCtrl.OnEvent("Change", (*) => SnippetPicker._FillInUpdate())
        dlg.OnEvent("Close", (*) => SnippetPicker._FillInClose())

        HotIfWinActive("ahk_id " dlg.Hwnd)
        Hotkey("Tab",    (*) => SnippetPicker._FillInAdvance(), "On")
        Hotkey("+Tab",   (*) => SnippetPicker._FillInBack(),    "On")
        Hotkey("Escape", (*) => SnippetPicker._FillInClose(),   "On")
        HotIf()

        s.dlg := dlg
        SnippetPicker._FillInUpdate()

        dlg.Show("Hide")
        dlg.GetPos(, , &dw, &dh)
        _mon := (refX >= 0) ? this._GetMonitorFromPos(refX, refY) : MonitorGetPrimary()
        MonitorGetWorkArea(_mon, &mL, &mT, &mR, &mB)
        dlg.Show("x" (mL + (mR - mL - dw) // 2) " y" (mT + (mB - mT - dh) // 2))
        s.inputCtrl.Focus()
        SendMessage(0xB1, 0, -1, s.inputCtrl)
    }

    static _FillInLabelText(s) {
        fi := s.fillIns[s.currentIdx]
        if (s.total = 1)
            return fi.label "  — Tab で挿入"
        suffix := (s.currentIdx = s.total) ? "  — Tab で挿入" : "  — Tab で次へ"
        return fi.label "  (" s.currentIdx " / " s.total ")" suffix
    }

    static _FillInClose() {
        SnippetPicker._ChildOpen := false
        try SnippetPicker._FillInState.dlg.Destroy()
        SnippetPicker._FillInState := ""
    }

    static _FillInUpdate() {
        s := SnippetPicker._FillInState
        if (s = "")
            return
        tmp := Map()
        tmp[s.fillIns[s.currentIdx].index] := s.inputCtrl.Value "▌"
        preview := PlaceholderEngine.ApplyFillIns(
            PlaceholderEngine.ApplyFillIns(s.content, s.confirmed), tmp)
        s.previewCtrl.Value := preview
        cursorPos := InStr(preview, "▌")
        if (cursorPos > 0) {
            SendMessage(0xB1, cursorPos - 1, cursorPos - 1, s.previewCtrl)  ; EM_SETSEL
            SendMessage(0xB7, 0, 0, s.previewCtrl)                           ; EM_SCROLLCARET
        }
    }

    static _FillInAdvance() {
        s := SnippetPicker._FillInState
        if (s = "")
            return
        s.confirmed[s.fillIns[s.currentIdx].index] := s.inputCtrl.Value
        if (s.currentIdx >= s.total) {
            content   := s.content
            confirmed := s.confirmed
            SnippetPicker._FillInClose()
            applied := PlaceholderEngine.ApplyFillIns(content, confirmed)
            result  := SnippetPicker._ProcessPlaceholders(applied)
            SnippetPicker._QuickPaste(result.text, result.cursorOffset)
        } else {
            s.currentIdx++
            ; 次フィールドを confirmed から外す（戻ってきた場合に▌が機能するよう）
            nextFiIdx  := s.fillIns[s.currentIdx].index
            restoredVal := s.confirmed.Has(nextFiIdx) ? s.confirmed[nextFiIdx] : ""
            if s.confirmed.Has(nextFiIdx)
                s.confirmed.Delete(nextFiIdx)
            s.labelCtrl.Text  := SnippetPicker._FillInLabelText(s)
            s.inputCtrl.Value := restoredVal
            s.inputCtrl.Focus()
            SendMessage(0xB1, 0, -1, s.inputCtrl)

            SnippetPicker._FillInUpdate()
        }
    }

    static _FillInBack() {
        s := SnippetPicker._FillInState
        if (s = "" || s.currentIdx <= 1)
            return
        s.confirmed[s.fillIns[s.currentIdx].index] := s.inputCtrl.Value
        s.currentIdx--
        ; 前フィールドを confirmed から外す（_FillInUpdate で ▌ が機能するよう）
        prevFiIdx := s.fillIns[s.currentIdx].index
        restoredVal := s.confirmed.Has(prevFiIdx) ? s.confirmed[prevFiIdx] : ""
        if s.confirmed.Has(prevFiIdx)
            s.confirmed.Delete(prevFiIdx)
        s.labelCtrl.Text  := SnippetPicker._FillInLabelText(s)
        s.inputCtrl.Value := restoredVal
        s.inputCtrl.Focus()
        SendMessage(0xB1, 0, -1, s.inputCtrl)
        SnippetPicker._FillInUpdate()
    }

    ; グループ選択フローティングピッカー
    static _ShowGroupPicker() {
        this._ChildOpen := true
        gpGui := Gui("+AlwaysOnTop +ToolWindow", "グループ")
        gpGui.SetFont("s10", "Segoe UI")

        filterEdit := gpGui.AddEdit("xm w200 h24")
        SendMessage(0x1501, 1, StrPtr("名前でフィルター..."), filterEdit)  ; EM_SETCUEBANNER

        lv := gpGui.AddListView("xm w200 r8 -Multi +0x4000", [""])
        SendMessage(0x101E, 0, -2, , "ahk_id " lv.Hwnd)
        lv.OnEvent("DoubleClick", (*) => SnippetPicker._ApplyGroupPicker(gpGui, lv))

        gpGui.Add("Text", "xm w200 Center", "↑↓: 移動  Enter: 選択  Esc: 閉じる")

        ; フィルター処理
        filterEdit.OnEvent("Change", (ed, *) => SnippetPicker._FilterGroupList(lv, ed.Value))
        SnippetPicker._FilterGroupList(lv, "")  ; 初期表示

        closeGp := (*) => (SnippetPicker._ChildOpen := false, gpGui.Destroy(), SnippetPicker.SearchObj.Focus())

        HotIfWinActive("ahk_id " gpGui.Hwnd)
        Hotkey("Enter", (*) => SnippetPicker._ApplyGroupPicker(gpGui, lv), "On")
        Hotkey("Down",  (*) => SnippetPicker._NavGroupList(lv, 1), "On")
        Hotkey("Up",    (*) => SnippetPicker._NavGroupList(lv, -1), "On")
        Hotkey("Esc",   closeGp, "On")
        HotIf()
        gpGui.OnEvent("Close", closeGp)

        ; グループボタンの直下に配置
        this.GroupBtnObj.GetPos(&bx, &by, , &bh)
        pt := Buffer(8, 0)
        NumPut("int", bx, pt, 0)
        NumPut("int", by + bh, pt, 4)
        DllCall("ClientToScreen", "ptr", this.GuiObj.Hwnd, "ptr", pt)
        gpGui.Show("Hide")
        gpGui.GetPos(, , &pw, &ph)
        px := NumGet(pt, 0, "int"), py := NumGet(pt, 4, "int")
        this._EnsureInScreen(&px, &py, pw, ph)
        gpGui.Show("x" px " y" py)
        filterEdit.Focus()
    }

    static _FilterGroupList(lv, query) {
        lv.Delete()
        for g in SnippetPicker._GroupList {
            if (query = "" || InStr(g, query))
                lv.Add(, g)
        }
        if (lv.GetCount() > 0)
            lv.Modify(1, "Select Focus")
    }

    static _NavGroupList(lv, dir) {
        count   := lv.GetCount()
        current := lv.GetNext(0, "F")
        next    := (current = 0) ? 1 : Max(1, Min(count, current + dir))
        if (next > 0)
            lv.Modify(next, "Select Focus Vis")
    }

    static _ApplyGroupPicker(gpGui, lv) {
        row := lv.GetNext(0, "F")
        if (!row)
            return
        SnippetPicker._LastGroup := lv.GetText(row, 1)
        SnippetPicker._ChildOpen := false
        gpGui.Destroy()
        SnippetPicker._FilterList(SnippetPicker.SearchObj.Value)
        SnippetPicker.SearchObj.Focus()
    }

    ; フォーカス外れで自動 Hide (WM_ACTIVATE)
    static _OnActivate(wParam, lParam, msg, hwnd) {
        if (!SnippetPicker.GuiObj || hwnd != SnippetPicker.GuiObj.Hwnd)
            return
        if ((wParam & 0xFFFF) != 0)  ; WA_INACTIVE 以外は無視
            return
        if (SnippetPicker._ChildOpen)  ; 子ダイアログが開いている間は Hide しない
            return
        SnippetPicker.GuiObj.Hide()
        ToolTip()
    }

    ; ホバーツールチップ（タイマー駆動）
    ; - 検索フィールド: プレフィックスヒント
    ; - ListView 内容列: フル内容
    static _HoverTick() {
        if (!SnippetPicker.LvObj || !SnippetPicker.GuiObj)
            return
        if (!WinActive("ahk_id " SnippetPicker.GuiObj.Hwnd)) {
            if (SnippetPicker._HoverRow) {
                ToolTip()
                SnippetPicker._HoverRow := 0
            }
            return
        }

        CoordMode "Mouse", "Screen"
        MouseGetPos(&mx, &my, , &ctrlHwnd, 2)

        ; 検索フィールド上: プレフィックスヒントを表示
        if (ctrlHwnd = SnippetPicker.SearchObj.Hwnd) {
            if (SnippetPicker._HoverRow != -1) {
                SnippetPicker._HoverRow := -1
                ToolTip("g: グループ列  /  c: 内容列  /  プレフィックスなし: 名称列`n{{cursor}}: 挿入後のカーソル位置を指定")
            }
            return
        }

        ; ListView 以外: ツールチップを消す
        if (ctrlHwnd != SnippetPicker.LvObj.Hwnd) {
            if (SnippetPicker._HoverRow) {
                ToolTip()
                SnippetPicker._HoverRow := 0
            }
            return
        }

        ; ListView: 内容列のみフル内容を表示
        lv_hwnd := SnippetPicker.LvObj.Hwnd
        pt := Buffer(8, 0)
        NumPut("int", mx, pt, 0)
        NumPut("int", my, pt, 4)
        DllCall("ScreenToClient", "ptr", lv_hwnd, "ptr", pt)
        cx := NumGet(pt, 0, "int")
        cy := NumGet(pt, 4, "int")

        buf := Buffer(24, 0)
        NumPut("int", cx, buf, 0)
        NumPut("int", cy, buf, 4)
        idx := SendMessage(0x1039, 0, buf.Ptr, , "ahk_id " lv_hwnd)  ; LVM_SUBITEMHITTEST
        row := (idx < 0) ? 0 : idx + 1
        col := NumGet(buf, 16, "int")  ; iSubItem (0-based)

        cacheKey := row * 10 + col
        if (cacheKey = SnippetPicker._HoverRow)
            return
        SnippetPicker._HoverRow := cacheKey

        if (!row || col != 2) {
            ToolTip()
            return
        }

        dispG := SnippetPicker.LvObj.GetText(row, 1)
        dispT := SnippetPicker.LvObj.GetText(row, 2)
        for item in SnippetPicker.SnipList {
            if (item.group = dispG && item.title = dispT) {
                ToolTip(item.content)
                return
            }
        }
    }

    static _QuickPaste(text, cursorOffset := 0) {
        oldClip := ClipboardAll()
        A_Clipboard := text
        Sleep(this.SLEEP_PASTE)
        Send("^v")
        if (cursorOffset > 0)
            Send("{Left " cursorOffset "}")
        SetTimer((*) => (A_Clipboard := oldClip), this.TIMER_RESTORE)
    }

    static _PrepareFile() {
        if !DirExist(A_ScriptDir "\ui") {
            DirCreate(A_ScriptDir "\ui")
        }
        if !FileExist(this.IniPath) {
            FileAppend("", this.IniPath, "UTF-8")
        }
    }
}
