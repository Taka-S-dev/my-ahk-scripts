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
    ; --- 文字を埋め込む場合はyyyy/mm/dd'User1' のようにシングルクォートで囲むことで、s を秒として解釈させない ---
    static Formats := [
        "yyyy/MM/dd",        ; パターン1: 2026/01/10
        "yyyyMMdd",          ; パターン2: 20260110
    ]

    static index := 1
    static lastLen := 0

    /**
     * 日付入力 (Ctrl + ;) の実行 
     */
    static Execute() {
        ; 直前も同じホットキーかつ短時間なら、前の入力を消して置換
        if (A_PriorHotkey = "^;") && (A_TimeSincePriorHotkey < 1200) && (this.lastLen > 0) {
            SendInput("{Backspace " this.lastLen "}")
        } else {
            this.index := 1
        }

        ; フォーマットを適用して文字列を生成 [cite: 93, 94]
        targetFormat := this.Formats[this.index]
        txt := FormatTime(A_Now, targetFormat)

        ; 入力実行
        SendText(txt)
        this.lastLen := StrLen(txt)

        ; 次のインデックスへ更新
        this.index := Mod(this.index, this.Formats.Length) + 1
    }
}
