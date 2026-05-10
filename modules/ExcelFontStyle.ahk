; ==============================================================================
; Module:       ExcelFontStyle.ahk
; Description:  Excel操作に関連する機能
;               - 選択中の文字列を赤色に変更
;               - 選択中の文字列を黒色(自動)に変更
;               - 選択範囲の取り消し線(Strikethrough)を切り替え
;               - セルの背景色トグル
;               - 行・列の挿入/削除
;               - セルの結合/解除トグル
; Version:      1.2.0
; License:      MIT
;
; 単独起動（直接実行）またはMain.ahkからの #Include 両方に対応
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Force
SetWorkingDir A_ScriptDir

class ExcelFontStyle {
    /**
     * 選択中の文字列を赤にする
     */
    static SetFontColorRed() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("{Alt}hfc")
        Sleep(150)
        Send("{Down 7}{Right 1}{Enter}")
    }

    /**
     * 選択中の文字列を黒(自動)に戻す
     */
    static SetFontColorBlack() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("{Alt}hfc")
        Sleep(150)
        Send("{Enter}")
    }

    /**
     * 取り消し線の切り替え (Strikethrough)
     */
    static SetFontColorStrikethrough() {
        if !WinActive("ahk_class XLMAIN")
            return
        ; ホーム(H) -> フォント設定(FN) を開き、取り消し線(Alt+K)をチェックして確定
        Send("{Alt}hfn")
        Sleep(200)
        Send("!k{Enter}")
    }

    /**
     * セルの背景色を指定色と塗りつぶしなしでトグル
     * color: BGR形式の色コード (例: 0x808080)
     */
    static ToggleFillColor(color) {
        if !WinActive("ahk_class XLMAIN")
            return
        try {
            xl  := ComObjActive("Excel.Application")
            sel := xl.Selection
            if (sel.Interior.Color = color)
                sel.Interior.ColorIndex := -4142  ; xlColorIndexNone
            else
                sel.Interior.Color := color
        } catch Error as e {
            MsgBox("Excel操作失敗: " . e.Message)
        }
    }

    static InsertRow() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("+{Space}")   ; 行全体を選択
        Send("^+{+}")      ; 行挿入
    }

    static InsertColumn() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("^{Space}")   ; 列全体を選択
        Send("^+{+}")      ; 列挿入
    }

    static DeleteRow() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("+{Space}")   ; 行全体を選択
        Send("^{-}")       ; 行削除
    }

    static DeleteColumn() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("^{Space}")   ; 列全体を選択
        Send("^{-}")       ; 列削除
    }

    static ToggleMerge() {
        if !WinActive("ahk_class XLMAIN")
            return
        try {
            isMerged := ComObjActive("Excel.Application").Selection.MergeCells
        } catch Error as e {
            MsgBox("Excel操作失敗: " . e.Message)
            return
        }
        if (isMerged)
            Send("{Alt}hmu")   ; 結合解除
        else
            Send("{Alt}hmm")   ; セルの結合（中央揃えなし）
    }
}

; 単独起動時のみホットキーを登録
#HotIf WinActive("ahk_class XLMAIN") && GetKeyState("vk1D", "P")
e:: ExcelFontStyle.SetFontColorRed()
q:: ExcelFontStyle.SetFontColorBlack()
x:: ExcelFontStyle.SetFontColorStrikethrough()
g:: ExcelFontStyle.ToggleFillColor(0x808080)
i:: ExcelFontStyle.InsertRow()
+i:: ExcelFontStyle.InsertColumn()
d:: ExcelFontStyle.DeleteRow()
+d:: ExcelFontStyle.DeleteColumn()
n:: ExcelFontStyle.ToggleMerge()
#HotIf
