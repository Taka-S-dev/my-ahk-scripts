; ==============================================================================
; Module:       ImeControl.ahk
; Description:  IME（日本語入力）の状態を正確に制御するためのクラス
;               - IMEのON/OFF状態の取得および設定
;               - ウィンドウやコントロールのフォーカスを考慮した安定した動作
;               - IMM32 API と WM_IME_CONTROL メッセージによる多角的な制御
;               - デバッグ用のツールチップ表示機能（任意設定）
; Version:      1.0.0
; License:      MIT
;
; Usage Example (Main.ahk):
;   #Include ImeControl.ahk
;   F13:: ImeControl.Toggle(false) ; IMEを無効化（OFF）
;   F14:: ImeControl.Toggle(true)  ; IMEを有効化（ON）
; ==============================================================================
#Requires AutoHotkey v2.0

class ImeControl {
    ; --- 定数設定 ---
    static DEBUG_TIMEOUT := -800   ; ツールチップ表示時間 (ms)
    static WM_IME_CONTROL := 0x0283 ; IME制御メッセージ
    static IMC_SETOPENSTATUS := 0x0006 ; IME状態設定コマンド
    static STATUS_ON := 1      ; IME有効値
    static STATUS_OFF := 0      ; IME無効値

    static Debug := false

    static Toggle(open) {
        ok := this.SetOpenStatus(open)

        if this.Debug {
            st := this.GetOpenStatus()
            ToolTip((open ? "IME ON " : "IME OFF ") "ok=" ok " st=" st)
            SetTimer(() => ToolTip(), this.DEBUG_TIMEOUT)
        }
    }

    static SetOpenStatus(open := true, hwnd := 0) {
        if !hwnd
            hwnd := WinGetID("A")

        try
            hwndFocus := ControlGetHwnd(ControlGetFocus("ahk_id " hwnd), "ahk_id " hwnd)
        catch
            hwndFocus := hwnd

        ; IMM32: フォーカス先で取得
        if this._ImmSetOpenStatus(hwndFocus, open) {
            return true
        }

        ; IMM32: 親ウィンドウで再試行
        if (hwndFocus != hwnd) && this._ImmSetOpenStatus(hwnd, open) {
            return true
        }

        ; フォールバック: WM_IME_CONTROL
        return this._SendImeControl(hwndFocus, hwnd, open)
    }

    static GetOpenStatus(hwnd := 0) {
        if !hwnd
            hwnd := WinGetID("A")

        try
            hwndFocus := ControlGetHwnd(ControlGetFocus("ahk_id " hwnd), "ahk_id " hwnd)
        catch
            hwndFocus := hwnd

        st := this._ImmGetOpenStatus(hwndFocus)
        if (st !== "") {
            return st
        }

        if (hwndFocus != hwnd) {
            st := this._ImmGetOpenStatus(hwnd)
            if (st !== "") {
                return st
            }
        }
        return ""
    }

    static _ImmSetOpenStatus(targetHwnd, open) {
        hIMC := DllCall("imm32\ImmGetContext", "ptr", targetHwnd, "ptr")
        if !hIMC {
            return false
        }
        DllCall("imm32\ImmSetOpenStatus", "ptr", hIMC, "int", open ? this.STATUS_ON : this.STATUS_OFF)
        DllCall("imm32\ImmReleaseContext", "ptr", targetHwnd, "ptr", hIMC)
        return true
    }

    static _ImmGetOpenStatus(targetHwnd) {
        hIMC := DllCall("imm32\ImmGetContext", "ptr", targetHwnd, "ptr")
        if !hIMC {
            return ""
        }
        st := DllCall("imm32\ImmGetOpenStatus", "ptr", hIMC, "int")
        DllCall("imm32\ImmReleaseContext", "ptr", targetHwnd, "ptr", hIMC)
        return st
    }

    static _SendImeControl(hwndFocus, hwnd, open) {
        imeWnd := DllCall("imm32\ImmGetDefaultIMEWnd", "ptr", hwndFocus, "ptr")
        if !imeWnd
            imeWnd := DllCall("imm32\ImmGetDefaultIMEWnd", "ptr", hwnd, "ptr")

        if !imeWnd || !DllCall("user32\IsWindow", "ptr", imeWnd, "int") {
            return false
        }

        DllCall("user32\SendMessageW", "ptr", imeWnd, "uint", this.WM_IME_CONTROL, "ptr", this.IMC_SETOPENSTATUS, "ptr",
            open ? this.STATUS_ON : this.STATUS_OFF, "ptr")
        return true
    }
}
