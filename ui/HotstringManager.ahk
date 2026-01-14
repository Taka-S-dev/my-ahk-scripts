; ==============================================================================
; Module:       HotstringManager.ahk
; Description:  Dynamic Hotstring Registration & Management Tool
;               - INIファイルによる永続化と、スクリプト再起動なしの動的反映 [cite: 41, 42]
;               - プレースホルダ展開機能 ({{clip}}, yyyy/mm/dd, HH:mm)
;               - マウス/キャレット追従表示およびモニター境界の自動補正 [cite: 68, 85, 87]
;               - トレイメニューへの統合によるホットキーの節約
;               - マジックナンバーを排除した定数管理による高い保守性 [cite: 9]
; Author:       Taka-S-dev
; Version:      1.1.0
; License:      MIT
; Usage Example (Main.ahk):
;   #Include modules\HotstringManager.ahk
;   HotstringManager.Init()
;   ; 管理画面はタスクバーの右クリックメニューから、または以下を定義
;   vk1D & h:: HotstringManager.Show() ; 無変換 + h で起動
; ==============================================================================

#Requires AutoHotkey v2.0

class HotstringManager {
    ; --- クラス定数（可読性と保守性のための定数値） ---
    static GUI_WIDTH := 420
    static GUI_HEIGHT_EST := 350
    static LV_ROWS := 10
    static COL_WIDTH_TRIG := 100
    static COL_WIDTH_REPL := 280

    static OFFSET_CARET := 5
    static OFFSET_MOUSE := 15
    static OFFSET_SCREEN := 10
    static OFFSET_LINE := 25

    static FLAG_MODAL := 4096 ; System Modal
    static IniPath := A_ScriptDir "\ui\Hotstrings.ini"

    ; --- 内部変数 ---
    static GuiObj := ""
    static LvObj := ""
    static EditTrig := ""
    static EditRepl := ""

    ; --- 初期化：トレイメニュー登録と既存設定の読み込み ---
    static Init() {
        this._PrepareFile()
        this._BuildGui()
        this._RegisterFromIni()

        ; トレイメニューに管理画面を追加
        A_TrayMenu.Add()
        A_TrayMenu.Add("Hotstring Manager (&H)", (*) => this.Show())
    }

    ; --- プレースホルダ置換エンジン（拡張性を維持しつつシンプルに） ---
    static _ApplyPlaceholders(rawText) {
        text := rawText

        ; 1. クリップボード同期
        text := StrReplace(text, "{{clip}}", A_Clipboard)

        ; 2. 基本の日付・時刻フォーマット
        text := StrReplace(text, "yymmdd", FormatTime(, "yyMMdd"))
        text := StrReplace(text, "yy/mm/dd", FormatTime(, "yy/MM/dd"))
        text := StrReplace(text, "yyyy/mm/dd", FormatTime(, "yyyy/MM/dd"))
        text := StrReplace(text, "HH:mm", FormatTime(, "HH:mm"))

        return text
    }

    ; --- 内部ロジック：ホットストリングの実行と動的登録 ---
    static _SendProcessedText(repl) {
        processed := this._ApplyPlaceholders(repl)
        SendText(processed)
    }

    static _RegisterFromIni() {
        try {
            content := IniRead(this.IniPath, "Custom")
            for line in StrSplit(content, "`n") {
                parts := StrSplit(line, "=", , 2)
                if (parts.Length >= 2) {
                    this._AddHS(parts[1], parts[2])
                }
            }
        }
    }

    static _AddHS(trig, repl) => Hotstring("::" . trig, (n) => this._SendProcessedText(repl), "On")

    ; --- GUI制御：座標計算と表示 ---
    static Show(*) {
        if (!this.GuiObj) {
            this._BuildGui()
        }

        CoordMode "Caret", "Screen"
        CoordMode "Mouse", "Screen"

        targetX := 0
        targetY := 0

        ; キャレット位置を優先的に取得
        if CaretGetPos(&cX, &cY) {
            targetX := cX + this.OFFSET_CARET
            monitorNum := this._GetMonitorFromPos(cX, cY)
            MonitorGetWorkArea(monitorNum, &L, &T, &R, &B)

            if (cY + this.OFFSET_LINE + this.GUI_HEIGHT_EST > B) {
                targetY := cY - this.GUI_HEIGHT_EST - this.OFFSET_SCREEN
            } else {
                targetY := cY + this.OFFSET_LINE
            }
        } else {
            MouseGetPos(&mX, &mY)
            targetX := mX + this.OFFSET_MOUSE
            targetY := mY + this.OFFSET_MOUSE
        }

        this._EnsureInScreen(&targetX, &targetY, this.GUI_WIDTH, this.GUI_HEIGHT_EST)
        this.GuiObj.Show("x" . targetX . " y" . targetY)
        this.EditTrig.Focus()
    }

    static _BuildGui() {
        this.GuiObj := Gui("+AlwaysOnTop", "Hotstring Manager")
        this.GuiObj.SetFont("s9", "Segoe UI")

        this.GuiObj.Add("Text", "xm", "Trigger:")
        this.EditTrig := this.GuiObj.Add("Edit", "vTrig w100 xm")
        this.GuiObj.Add("Text", "x+10", "Replacement:")
        this.EditRepl := this.GuiObj.Add("Edit", "vRepl w200 x+5")

        this.GuiObj.Add("Button", "x+10 w60 Default", "Add").OnEvent("Click", (*) => this._ProcessAdd())

        this.LvObj := this.GuiObj.Add("ListView", "xm w400 r" . this.LV_ROWS . " Grid", ["Trigger", "Replacement"])
        this.LvObj.ModifyCol(1, this.COL_WIDTH_TRIG)
        this.LvObj.ModifyCol(2, this.COL_WIDTH_REPL)
        this._RefreshList()

        this.GuiObj.Add("Button", "xm w100", "Delete Selected").OnEvent("Click", (*) => this._Delete())
        this.GuiObj.Add("Button", "x+10 w100", "Edit Selected").OnEvent("Click", (*) => this._Edit())

        ; 行のダブルクリックで編集開始
        this.LvObj.OnEvent("DoubleClick", (lv, row) => (row ? this._Edit(row) : 0))

        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Esc", (*) => this.GuiObj.Hide(), "On")
        HotIf()
    }

    static _RefreshList() {
        this.LvObj.Delete()
        try {
            content := IniRead(this.IniPath, "Custom")
            for line in StrSplit(content, "`n") {
                parts := StrSplit(line, "=", , 2)
                if (parts.Length >= 2) {
                    this.LvObj.Add(, parts[1], parts[2])
                }
            }
        }
    }

    static _ProcessAdd() {
        t := this.EditTrig.Value
        r := this.EditRepl.Value
        if (t !== "" && r !== "") {
            IniWrite(r, this.IniPath, "Custom", t)
            this._AddHS(t, r)
            this._RefreshList()
            this.EditTrig.Value := ""
            this.EditRepl.Value := ""
            this.EditTrig.Focus()
        }
    }

    static _Delete() {
        selectedTriggers := []
        row := 0
        while (row := this.LvObj.GetNext(row)) {
            selectedTriggers.Push(this.LvObj.GetText(row, 1))
        }

        if (selectedTriggers.Length > 0) {
            this.GuiObj.Opt("+Disabled +OwnDialogs")
            msg := (selectedTriggers.Length == 1)
                ? "Delete '" . selectedTriggers[1] . "'?"
                : "Delete " . selectedTriggers.Length . " items?"

            if (MsgBox(msg, "Confirmation", "YesNo Icon? " . this.FLAG_MODAL) == "Yes") {
                for trig in selectedTriggers {
                    IniDelete(this.IniPath, "Custom", trig)
                    try Hotstring("::" . trig, , "Off")
                }
                this._RefreshList()
            }
            this.GuiObj.Opt("-Disabled")
            this.GuiObj.Show()
        }
    }

    static _Edit(row := 0) {
        if (row = 0) {
            row := this.LvObj.GetNext()
            if (row = 0)
                return
        }
        oldTrig := this.LvObj.GetText(row, 1)
        oldRepl := this.LvObj.GetText(row, 2)
        this._ShowEditDialog(oldTrig, oldRepl)
    }

    static _ShowEditDialog(oldTrig, oldRepl) {
        parent := this.GuiObj
        parent.Opt("+Disabled +OwnDialogs")

        dlg := Gui("+Owner" . parent.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", "Edit Hotstring")
        dlg.SetFont("s9", "Segoe UI")

        dlg.Add("Text", "xm", "Trigger:")
        trigEdit := dlg.Add("Edit", "vTrig w120 xm", oldTrig)
        dlg.Add("Text", "x+10", "Replacement:")
        replEdit := dlg.Add("Edit", "vRepl w240 x+5", oldRepl)

        okBtn := dlg.Add("Button", "xm w80 Default", "Save")
        cancelBtn := dlg.Add("Button", "x+10 w80", "Cancel")

        okBtn.OnEvent("Click", (*) => (
            vals := dlg.Submit(false),
            this._UpsertHotstring(oldTrig, vals.Trig, vals.Repl),
            dlg.Destroy(),
            parent.Opt("-Disabled"),
            parent.Show()
        ))
        cancelBtn.OnEvent("Click", (*) => (dlg.Destroy(), parent.Opt("-Disabled"), parent.Show()))
        dlg.OnEvent("Close", (*) => (dlg.Destroy(), parent.Opt("-Disabled"), parent.Show()))

        ; 親ウィンドウの中央に表示
        parent.GetPos(&px, &py, &pw, &ph)
        dlg.Show("Hide")
        dlg.GetPos(, , &dw, &dh)
        dlg.Show("x" . px + (pw - dw) // 2 . " y" . py + (ph - dh) // 2)
    }

    static _UpsertHotstring(oldTrig, newTrig, newRepl) {
        newTrig := Trim(newTrig)
        if (newTrig = "" || newRepl = "")
            return

        ; トリガー変更時は競合を確認
        if (newTrig != oldTrig) {
            try existing := IniRead(this.IniPath, "Custom", newTrig, "")
            if (existing != "") {
                if (MsgBox("Overwrite existing trigger '" . newTrig . "'?", "Confirm", "YesNo Icon? 4096") != "Yes")
                    return
            }
        }

        ; 古い登録を外す（トリガー変更時）
        if (oldTrig != "" && oldTrig != newTrig) {
            IniDelete(this.IniPath, "Custom", oldTrig)
            try Hotstring("::" . oldTrig, , "Off")
        }

        ; 書き込み（新規 or 更新）
        IniWrite(newRepl, this.IniPath, "Custom", newTrig)

        ; 再登録（置換のみ変更時も念のため外して入れ直す）
        try Hotstring("::" . newTrig, , "Off")
        this._AddHS(newTrig, newRepl)

        this._RefreshList()
    }

    ; --- ユーティリティ：座標補正とモニター取得 ---
    static _EnsureInScreen(&x, &y, w, h) {
        loop MonitorGetCount() {
            MonitorGetWorkArea(A_Index, &L, &T, &R, &B)
            if (x >= L && x <= R && y >= T && y <= B) {
                if (x + w > R)
                    x := R - w - this.OFFSET_SCREEN
                if (y + h > B)
                    y := B - h - this.OFFSET_SCREEN
                if (y < T)
                    y := T + this.OFFSET_SCREEN
            }
        }
    }

    static _GetMonitorFromPos(x, y) {
        monitor := MonitorGetPrimary()
        loop MonitorGetCount() {
            MonitorGet(A_Index, &L, &T, &R, &B)
            if (x >= L && x <= R && y >= T && y <= B)
                monitor := A_Index
        }
        return monitor
    }

    static _PrepareFile() {
        if !DirExist(A_ScriptDir "\ui")
            DirCreate(A_ScriptDir "\ui")
        if !FileExist(this.IniPath)
            FileAppend("[Custom]`n", this.IniPath, "UTF-8")
    }
}
