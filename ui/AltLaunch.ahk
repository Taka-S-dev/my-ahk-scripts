; ==============================================================================
; Module:       AltLaunch.ahk
; Description:  無変換キーが使えない環境向けの一時的な代替ホットキー。
;               トレイメニューの「代替ホットキー」でON/OFF（既定OFF）。
;               一時利用を想定した機能のため、設定は永続化しない。
;
; Usage Example (Main.ahk):
;   #Include "ui\AltLaunch.ahk"
;   AltLaunch.Init()
; ==============================================================================
#Requires AutoHotkey v2.0

class AltLaunch {
    static MENU_TEXT := "代替ホットキー（右Alt）"
    static _enabled := false
    static _registered := false

    ; 代替キー -> 起動処理。">!"は右Alt。本来の無変換+キーと同じ文字に揃える。
    ; 対象の変更・追加はこの表を書き換えるだけでよい。
    static Bindings := Map(
        ">!e", () => ExplorerSwitch.Toggle("RAlt"),
        ">!a", () => QuickSwitch.Show(),
        ">!f", () => Navi.Show(),
        ">!s", () => SnippetPicker.Show()
    )

    static Init() {
        A_TrayMenu.Add(this.MENU_TEXT, (*) => this.Toggle())
    }

    static Toggle() {
        if this._enabled
            this.Disable()
        else
            this.Enable()
    }

    static Enable() {
        for key, action in this.Bindings {
            ; クロージャは変数を参照で捕まえるため、そのまま渡すと全キーが
            ; ループ最後のactionを呼んでしまう。Bindで値を固定する。
            handler := ((fn, *) => fn()).Bind(action)
            Hotkey(key, handler, "On")
        }
        this._registered := true
        this._enabled := true
        A_TrayMenu.Check(this.MENU_TEXT)
        TrayTip("右Alt + E / A / F / S で起動できます", "代替ホットキー ON", "Iconi")
    }

    static Disable() {
        if !this._registered
            return
        for key in this.Bindings
            Hotkey(key, "Off")
        this._enabled := false
        A_TrayMenu.Uncheck(this.MENU_TEXT)
        TrayTip("無変換キーの割り当てに戻しました", "代替ホットキー OFF", "Iconi")
    }
}
