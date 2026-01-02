; ==============================================================================
; Module:       DateTimeInsert.ahk
; Description:  Excel風のショートカットで日付を入力するユーティリティ
;               - Ctrl + ; で現在の日付を素早く入力
;               - 連続入力でフォーマット（yyyy/MM/dd ↔ yyyyMMdd）を切り替え
;               - 短時間での再入力時に前回の内容を自動置換
; Version:      1.0.0
; License:      MIT
;
; Usage Example:
;   #Include DateTimeInsert.ahk
;   ^;:: DateTimeInsert.Execute() ; Ctrl + ; で実行
; ==============================================================================
#Requires AutoHotkey v2.0

/**
 * DateTimeInsert.ahk
 * Excel風のショートカットで日付を入力するクラス
 */
class DateTimeInsert {
    static mode := 0
    static lastLen := 0

    /**
     * 日付入力 (Ctrl + ;) の実行
     */
    static Execute() {
        ; 直前も同じホットキーかつ短時間なら、前の入力を消して置換する
        if (A_PriorHotkey = "^;") && (A_TimeSincePriorHotkey < 1200) && (this.lastLen > 0) {
            SendInput("{Backspace " this.lastLen "}")
        }

        ; フォーマットを切り替えて入力 (yyyy/MM/dd ↔ yyyyMMdd)
        txt := this.mode ? FormatTime(A_Now, "yyyy/MM/dd") : FormatTime(A_Now, "yyyyMMdd")

        SendText(txt)
        this.lastLen := StrLen(txt)
        this.mode := !this.mode
    }
}
