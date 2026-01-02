; ==============================================================================
; Module:       VimNavigation.ahk
; Description:  無変換(vk1D)との組み合わせで Vim 風のカーソル操作を実現
;               - hjkl: 左/下/上/右 への移動
;               - Shift キーとの組み合わせにより範囲選択をサポート
; Version:      1.0.0
; License:      MIT
;
; Usage Example (Main.ahk):
;   #Include modules\VimNavigation.ahk
;
;   ; 無変換(vk1D) を押している間のみ有効にする例
;   #HotIf GetKeyState("vk1D", "P")
;   h:: VimNavigation.Move("{Left}", "+{Left}")
;   j:: VimNavigation.Move("{Down}", "+{Down}")
;   #HotIf
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Vim風ナビゲーション・クラス
 */
class VimNavigation {
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
}
