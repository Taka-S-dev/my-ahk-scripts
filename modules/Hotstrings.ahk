; ==============================================================================
; Module:       Hotstrings.ahk
; Description:  定型文およびコマンドの自動置換定義
;               - 日本語定型文は文字化け防止のため SendText を使用
;               - 開発用コマンドはエディタやターミナルでの利用を想定
; Author:       Taka.S
; Version:      1.0.0
; License:      MIT
; Usage:
;   #Include modules\Hotstrings.ahk
; ==============================================================================

#Requires AutoHotkey v2.0

; ---- 日本語定型文（ビジネス） ----
; :*: にすると、確定（SpaceやEnter）を待たずに即時置換されます。
; 必要に応じて使い分けてください。

::yor::
{
    SendText "よろしくお願いいたします。"
}

::otu::
{
    SendText "お疲れ様です。"
}

; ---- 開発者用コマンド ----
; 本来は特定のウィンドウ（VS CodeやWindows Terminal）に限定するとより安全です。

::gitst::git status
::gitad::git add .
::gitcm::git commit -m ""