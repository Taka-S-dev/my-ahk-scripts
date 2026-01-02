; ==============================================================================
; Module:       WrapPalette.ahk
; Description:  選択中のテキストを指定した記号で囲む (Wrap) 機能
;               - 実行後、1.2秒以内に記号キーを入力することで置換を実行
;               - 対応記号: " ' ( [ { < `
; Version:      1.0.0
; License:      MIT
;
; Usage Example (Main.ahk):
;   #Include modules\WrapPalette.ahk
;
;   ; 無変換(vk1D) + r で実行
;   vk1D & r:: WrapPalette.Execute()
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * 選択範囲を記号で囲むパレット・クラス
 */
class WrapPalette {
    ; --- 定数設定 ---
    static TIMEOUT_INPUT := 1.2   ; 入力待機タイムアウト（秒）
    static TIMEOUT_CLIP := 0.25  ; クリップボード待機タイムアウト（秒）
    static DELAY_PASTE := 10    ; 貼り付け後の待機時間（ms）

    /**
     * 囲み処理の実行
     */
    static Execute() {
        ; 1) 選択文字列を切り取って取得
        text := this._CutSelectionText()
        if (text == "") {
            return
        }

        ; 2) 次の1キーを待機 (タイムアウト設定)
        ih := InputHook("L1 T" . this.TIMEOUT_INPUT)
        ih.Start()
        ih.Wait()
        key := ih.Input

        ; タイムアウトまたはキャンセル時は元のテキストをそのまま貼り付けて復元
        if (key == "") {
            this._PasteText(text)
            return
        }

        ; 3) 入力されたキーに応じて囲み記号を決定
        wrapped := ""
        switch key {
            case '"': wrapped := '"' . text . '"'
            case "'": wrapped := "'" . text . "'"
            case "(": wrapped := "(" . text . ")"
            case "[": wrapped := "[" . text . "]"
            case "{": wrapped := "{" . text . "}"
            case "<": wrapped := "<" . text . ">"
            case "``": wrapped := "``" . text . "``"
            default: wrapped := text ; 未対応キーはそのまま復元
        }

        ; 4) 囲んだテキストを貼り付け
        this._PasteText(wrapped)
    }

    /**
     * 現在の選択範囲を切り取ってテキストを返す
     * (クリップボードを一時的に使用し、終了後に復元する)
     */
    static _CutSelectionText() {
        bak := ClipboardAll()
        A_Clipboard := ""

        Send("^x") ; 切り取り
        if !ClipWait(this.TIMEOUT_CLIP) {
            A_Clipboard := bak
            return ""
        }

        text := A_Clipboard
        A_Clipboard := bak
        return text
    }

    /**
     * 指定したテキストを貼り付ける
     * (クリップボードを一時的に使用し、終了後に復元する)
     */
    static _PasteText(text) {
        bak := ClipboardAll()
        A_Clipboard := text
        Send("^v") ; 貼り付け
        Sleep(this.DELAY_PASTE) ; 貼り付け完了待ち
        A_Clipboard := bak
    }
}
