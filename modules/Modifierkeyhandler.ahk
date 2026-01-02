; ==============================================================================
; Module:       ModifierKeyHandler.ahk
; Description:  修飾キーの動作を制御: OS標準の動作をブロックし、
;               空打ち（タップ）と長押し（ホールド）を判別
;
; 機能:
;   - OS側にキーを渡さない（日本語キーボードのカタカナ化を防止）
;   - キー単体での押下 vs 他のキーとの組み合わせを検出
;   - 空打ち時のコールバック実行（オプション）
;
; Version:      1.0.0
; License:      MIT
;
; Usage Example (Main.ahk):
;   #Include "modules\ModifierKeyHandler.ahk"
;   #Include "modules\ImeControl.ahk"
;
;   ; モード1: 空打ちでIME切り替え + キー無効化
;   ModifierKeyHandler.Init("vk1D", "sc07B")  ; 無変換キー
;   ModifierKeyHandler.OnTap := (*) => ImeControl.Toggle(false)
;
;   ; モード2: キー無効化のみ（IME切り替えなし）
;   ; ModifierKeyHandler.Init("vk1D", "sc07B")
;   ; OnTapを設定しない = キー無効化のみ
;
;   ; 他のキーに変更する例:
;   ; ModifierKeyHandler.Init("vkF0", "sc03A")  ; CapsLock
;   ; ModifierKeyHandler.Init("vk20", "sc039")  ; Space
;   ; ModifierKeyHandler.Init("vkA5", "sc138")  ; Right Alt
; ==============================================================================
#Requires AutoHotkey v2.0

global ModifierKeyHandler := ModifierKeyHandlerClass()

class ModifierKeyHandlerClass {
    OnTap := 0           ; 空打ち時に実行するコールバック関数（設定すると空打ち検出が有効化）
    _downTick := 0       ; キー押下時のタイムスタンプ
    _vk := ""           ; 仮想キーコード（Init で設定）
    _sc := ""           ; スキャンコード（Init で設定）
    _initialized := false

    ; ------------------------------------------------------------
    ; 対象キーを指定して初期化
    ; ------------------------------------------------------------
    ; パラメータ:
    ;   virtualKey - 仮想キーコード（例: 無変換は "vk1D"）
    ;   scanCode   - スキャンコード（省略可、例: 無変換は "sc07B"）
    ;
    ; キーコード例:
    ;   無変換 (Muhenkan): Init("vk1D", "sc07B")
    ;   CapsLock:          Init("vkF0", "sc03A")
    ;   Space:             Init("vk20", "sc039")
    ;   Right Alt:         Init("vkA5", "sc138")
    ; ------------------------------------------------------------
    Init(virtualKey, scanCode := "") {
        if this._initialized {
            throw Error("ModifierKeyHandler は既に初期化されています")
        }

        this._vk := virtualKey
        this._sc := scanCode
        this._initialized := true

        ; ホットキーを動的に登録
        Hotkey("*" . virtualKey, (*) => this._OnDown())
        Hotkey("*" . virtualKey . " up", (*) => this._OnUp())
    }

    _OnDown() {
        this._downTick := A_TickCount
    }

    _OnUp() {
        ; OnTap が設定されていない場合、このハンドラーはキーをブロックするだけ
        ; （空打ち検出なし、OS側にキーを渡さないだけ）
        if !IsObject(this.OnTap) {
            return
        }

        priorKey := A_PriorKey

        ; 修飾キーが単体で押されたかチェック
        ; 各条件は A_PriorKey が返す可能性のある形式をチェック:
        isModifierOnly := (
            priorKey = this._vk ||  ; ワイルドカードなしの仮想キー（例: "vk1D"）
            priorKey = "*" . this._vk ||  ; ワイルドカード付き仮想キー（例: "*vk1D"）← 最も一般的
            priorKey = this._sc ||  ; ワイルドカードなしのスキャンコード（例: "sc07B"）
            priorKey = "*" . this._sc ||  ; ワイルドカード付きスキャンコード（例: "*sc07B"）
            priorKey = ""                    ; 空文字列（前のキーがない場合のエッジケース）
        )

        ; コールバック実行条件:
        ; - キーが単体で押された（他のキーとの組み合わせではない）
        ; - 500ms 以内にリリースされた（タップ、長押しではない）
        ; - コールバックが設定されている
        if isModifierOnly && (A_TickCount - this._downTick < 500) {
            this.OnTap.Call()
        }
    }
}
