; ==============================================================================
; Module      : TempMemo.ahk
; Description : メモ帳互換の挙動を持つ、高度な一時テキスト保管用 GUI (Scrap Pad)
;               - 各タブの内容を個別の .txt ファイルに自動保存
;               - 貼り付け時、ブラウザ等の LF 改行を CRLF へ自動変換 (1行化を防止)
;               - 等幅フォント、折り返しなし、スクロールバー、内部余白による高い視認性
;               - 透明度の動的調整およびウィンドウのリサイズ追随機能
; Version     : 1.0.0
; License     : MIT
;
; Usage Example (Main.ahk):
;   #Include ui\TempMemo.ahk
;   TempMemo.Init()
;   vk1D & m:: TempMemo.Toggle() ; 無変換 + m で起動
; ==============================================================================
#Requires AutoHotkey v2.0

class TempMemo {
    ; --- 基本設定 ---
    static MEMO_DIR := A_ScriptDir "\ui\memos"
    static GUI_ALPHA_INIT := 235
    static TAB_NAMES := ["Memo 1", "Memo 2", "Memo 3", "Work"]
    static GUI_WIDTH_DEFAULT := 600
    static GUI_HEIGHT_DEFAULT := 450
    static WINDOW_FRAME_WIDTH := 14  ; ウィンドウフレーム補正値（Win10/11標準テーマ）

    static GuiObj := ""
    static TabObj := ""
    static EditObjs := []
    static SliderObj := ""
    static LabelObj := ""

    static Init() {
        if (!DirExist(this.MEMO_DIR)) {
            DirCreate(this.MEMO_DIR)
        }
        this._BuildGui()
        this._LoadAll()

        OnExit((*) => this.SaveAll())
    }

    ; --- 表示・非表示の切り替え（シングルトン & 位置制御） ---
    static Toggle(*) {
        ; ウィンドウが既にアクティブなら保存して隠す
        if (this.GuiObj && WinActive("ahk_id " this.GuiObj.Hwnd)) {
            this.SaveAll()
            this.GuiObj.Hide()
            return
        }

        ; マウスカーソルがあるモニタの作業領域中央に配置
        CoordMode "Mouse", "Screen"
        MouseGetPos(&mX, &mY)
        monitorNum := this._GetMonitorFromPos(mX, mY)
        MonitorGetWorkArea(monitorNum, &waL, &waT, &waR, &waB)

        winW := this.GUI_WIDTH_DEFAULT + this.WINDOW_FRAME_WIDTH
        winH := this.GUI_HEIGHT_DEFAULT
        centerX := waL + (waR - waL - winW) // 2
        centerY := waT + (waB - waT - winH) // 2

        this.GuiObj.Show("x" . centerX . " y" . centerY)

        ; フォーカス処理
        if (this.EditObjs.Length >= this.TabObj.Value) {
            this.EditObjs[this.TabObj.Value].Focus()
        }
    }

    ; --- 座標・モニター判定ヘルパー ---
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

    ; --- データ管理ロジック ---
    static SaveAll(*) {
        for index, name in this.TAB_NAMES {
            filePath := this.MEMO_DIR "\Tab" index ".txt"
            try {
                if (FileExist(filePath)) {
                    FileDelete(filePath)
                }
                FileAppend(this.EditObjs[index].Value, filePath, "UTF-8")
            }
        }
    }

    static _LoadAll() {
        for index, name in this.TAB_NAMES {
            filePath := this.MEMO_DIR "\Tab" index ".txt"
            if (FileExist(filePath)) {
                this.EditObjs[index].Value := FileRead(filePath, "UTF-8")
            }
        }
    }

    ; --- GUI構築 ---
    static _BuildGui() {
        this.GuiObj := Gui("+AlwaysOnTop +ToolWindow +Resize", "Temp Memo")
        this.GuiObj.Opt("+MinSize350x250")

        this.GuiObj.OnEvent("Close", (guiObj) => this.Toggle())
        this.GuiObj.OnEvent("Size", (guiObj, minMax, width, height) => this._OnSize(width, height))

        this.TabObj := this.GuiObj.Add("Tab3", "x5 y5", this.TAB_NAMES)

        this.EditObjs := []
        for index, name in this.TAB_NAMES {
            this.TabObj.UseTab(index)
            ; 0x100: ES_NOHIDESEL (フォーカスが外れても選択範囲を維持)
            editCtrl := this.GuiObj.AddEdit("Multi WantTab -Wrap HScroll VScroll +0x100 x10 y35")
            editCtrl.SetFont("s11", "Consolas")

            ; 左右の余白（8px）を設定
            SendMessage(0x00D3, 3, 8 | (8 << 16), editCtrl.Hwnd)
            this.EditObjs.Push(editCtrl)
        }
        this.TabObj.UseTab()

        this.GuiObj.SetFont("s9", "Segoe UI")
        this.LabelObj := this.GuiObj.AddText("Center")
        this.SliderObj := this.GuiObj.AddSlider("h30 Range50-255", this.GUI_ALPHA_INIT)
        this.SliderObj.OnEvent("Change", (sd, *) => this._OnAlphaChange(sd))

        ; 初回生成時は隠した状態でサイズを適用
        this.GuiObj.Show("w" this.GUI_WIDTH_DEFAULT " h" this.GUI_HEIGHT_DEFAULT " Hide")
        this._OnSize(this.GUI_WIDTH_DEFAULT, this.GUI_HEIGHT_DEFAULT)
        this._OnAlphaChange(this.SliderObj)

        ; ホットキーの設定
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("^v", (*) => this._PasteCorrected())
        Hotkey("Esc", (*) => this.Toggle())
        HotIf()
    }

    static _PasteCorrected() {
        ; 改行コードをCRLFに統一して貼り付け
        cleanText := RegExReplace(A_Clipboard, "\R", "`r`n")
        focusedHwnd := ControlGetFocus("ahk_id " this.GuiObj.Hwnd)
        if (focusedHwnd) {
            SendMessage(0x00C2, 1, StrPtr(cleanText), focusedHwnd)
        }
    }

    static _OnAlphaChange(sd) {
        WinSetTransparent(sd.Value, this.GuiObj.Hwnd)
        percent := Round((sd.Value / 255) * 100)
        this.LabelObj.Value := "Opacity: " percent "%"
    }

    static _OnSize(w, h) {
        if (w == 0 || h == 0) {
            return
        }
        tabW := w - 10
        tabH := h - 15 - 30
        this.TabObj.Move(, , tabW, tabH)
        editW := tabW - 15
        editH := tabH - 30 - 10
        for editCtrl in this.EditObjs {
            editCtrl.Move(, , editW, editH)
        }
        sliderY := 10 + tabH
        this.LabelObj.Move(5, sliderY + 5, 110)
        this.SliderObj.Move(115, sliderY, tabW - 110)
    }
}
