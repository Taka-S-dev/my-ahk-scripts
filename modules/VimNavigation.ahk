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
    /**
     * Shift 状態に応じて入力を送り分ける（範囲選択対応）
     * @param noShift Shiftなし時のキー（例: "{Left}"）
     * @param withShift Shiftあり時のキー（例: "+{Left}"）
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
     * /**
     * 二度打ち (dd, yy) の判定ロジック
     * @param key 押されたキー
     * @param callback 二度打ち成立時に実行する関数
     */
    static HandleDoubleKey(key, callback) {
        currentTime := A_TickCount
        ; 500ms以内の同一キー打鍵を「二度打ち」と判定
        if (this.lastKey == key && currentTime - this.lastTime < 500) {
            callback.Call(this)
            this.lastKey := "" ; リセット
        } else {
            this.lastKey := key
            this.lastTime := currentTime
        }
    }

    /**
     * 行削除 (Vimの dd)
     * 最終行(EOF)でも行ごと削除されるように調整
     */
    static DeleteLine() {
        ; 行頭に移動 -> 行全体を選択して削除
        ; EOF対策として、文字削除後に空行が残る場合はDeleteとBSで掃除
        Send("{Home}{Home}+{Down}{Delete}")
    }

    /**
     * 単語削除 (dw)
     */
    /**
     * 単語削除 (dw) - Vim本来の動作を再現
     * カーソル位置から次の単語の先頭まで（スペース含む）削除
     * 
     * 例1: "☆I have a pen" → "☆have a pen" (☆がカーソル位置、単語の先頭)
     * 例2: "I ☆have a pen" → "I ☆a pen" (☆がカーソル位置、単語の途中/先頭)
     */
    static DeleteWord() {
        ; 無変換キー(vk1D)を一時的に離す
        Send("{vk1D up}")

        ; 単語の終わりまで選択して削除
        Send("+^{Right}{Delete}")

        ; 無変換キーを押し直す
        Send("{vk1D down}")
    }

    /**
     * 行コピー (Vimの yy)
     */
    static CopyLine() {
        ; 行全体を選択してコピー -> 選択解除して元の位置付近へ
        Send("{Home}{Home}+{Down}^c{Left}")
    }

    /**
     * 新しい行を開いて挿入状態にする (Vimの o/O)
     */
    static OpenLine(isAbove := false) {
        if isAbove {
            Send("{Home}{Enter}{Up}")
        } else {
            Send("{End}{Enter}")
        }
    }

}
