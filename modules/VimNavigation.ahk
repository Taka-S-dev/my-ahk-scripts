; ==============================================================================
; Module:       VimNavigation.ahk
; Description:  無変換キー(vk1D)との組み合わせで Vim 風の操作を実現
; Features:     - hjkl: カーソル移動 (Shift 併用で範囲選択) [cite: 1, 2]
;               - dd / yy: 行削除 / 行コピー (二度打ち判定)
;               - o / O: 下 / 上 に新しい行を挿入 [cite: 5, 6, 7, 8]
; Version:      1.1.0
; License:      MIT
;
; Usage Example (Main.ahk):
;   #Include modules\VimNavigation.ahk
;
;   #HotIf GetKeyState("vk1D", "P")
;   h:: VimNavigation.Move("{Left}", "+{Left}")
;   d:: VimNavigation.HandleDoubleKey("d", VimNavigation.DeleteLine)
;   y:: VimNavigation.HandleDoubleKey("y", VimNavigation.CopyLine)
;   *o:: VimNavigation.OpenLine(GetKeyState("Shift", "P"))
;   #HotIf
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Vim風ナビゲーション・クラス
 */
class VimNavigation {

    static lastKey := ""
    static lastTime := 0
    static DOUBLE_TAP_GAP := 300  ; 二度打ち判定の時間間隔(ミリ秒)

    /**
     * Shift 状態に応じて入力を送り分ける(範囲選択対応)
     * @param noShift Shiftなし時のキー(例: "{Left}")
     * @param withShift Shiftあり時のキー(例: "+{Left}")
     */
    static Move(noShift, withShift) {
        ; 物理的な Shift キーの押下状態を確認
        if GetKeyState("Shift", "P") {
            Send(withShift)
        } else {
            Send(noShift)
        }
    }

    /**
     * 二度打ち (dd, yy) の判定ロジック
     */
    static HandleDoubleKey(key, callback) {
        currentTime := A_TickCount

        if (this.lastKey == key && currentTime - this.lastTime < this.DOUBLE_TAP_GAP) {
            this.lastKey := ""
            this.lastTime := 0
            callback.Call(this)
        } else {
            this.lastKey := key
            this.lastTime := currentTime
        }
    }

    /**
     * 行削除 (Vim: dd)
     * 最後の一行でも確実に削除するため、End -> Shift+Home のシーケンスを使用
     */
    static DeleteLine(*) {
        this._SafeSend("{End}+{Home 2}{Delete}{BackSpace}", false)
    }

    /**
     * 行コピー (Vim: yy)
     */
    static CopyLine(*) {
        this._SafeSend("{End}+{Home 2}^c{Left}", false)
    }

    /**
     * 行の挿入 (Vim: o/O)
     * Excel の場合はセル内改行 (Alt+Enter) を実行する
     * 修正: IMEのカタカナ変換を防ぐため、Enter後に無変換キーを復元しない
     */
    static OpenLine(isAbove := false) {
        isExcel := WinActive("ahk_exe EXCEL.EXE")
        enterKey := isExcel ? "!{Enter}" : "{Enter}"

        if isAbove {
            this._SafeSend("{Home}" enterKey "{Up}", false)
        } else {
            this._SafeSend("{End}" enterKey, false)
        }
    }

    /**
     * 修飾キー(無変換)との干渉を防ぎつつキーを送信する内部メソッド
     * @param keys 送信するキー
     * @param restoreModifier 送信後に無変換キーの状態を復元するか (デフォルト: true)
     */
    static _SafeSend(keys, restoreModifier := true) {
        ; 無変換キーを物理的に押していても、一旦離した状態にして送信する
        wasDown := GetKeyState("vk1D", "P")
        if wasDown {
            Send("{vk1D up}")
        }

        ; 安定性の高い SendEvent を使用
        SendEvent(keys)

        ; restoreModifier が true で、元々押されていた場合のみ復元
        if wasDown && restoreModifier {
            Send("{vk1D down}")
        }
    }
}
