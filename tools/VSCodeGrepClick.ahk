; ==============================================================================
; Module:       VSCodeGrepClick.ahk
; Description:  VSCode で 無変換+クリック → クリック位置の単語で Find in Files を起動
;               VSCode の設定 editor.find.seedSearchStringFromSelection = "always"
;               と組み合わせて、クリック → Ctrl+Shift+F だけで grep を自動入力させる
; Version:      1.0.0
; License:      MIT
;
; 単独起動専用スクリプト（直接実行）
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Force
SetWorkingDir A_ScriptDir

; VSCode 上で 無変換(vk1D) を押しながら左クリック → Find in Files
; combo構文（vk1D & LButton）を使うことで ModifierKeyHandler と共存
#HotIf WinActive("ahk_exe Code.exe")
~vk1D & LButton::
{
    ; 既存の選択範囲を確認（Ctrl+C で取得、クリップボードは即復元）
    savedClip := ClipboardAll()
    A_Clipboard := ""
    Send "^c"
    ClipWait 0.2, 0
    selText := A_Clipboard
    A_Clipboard := savedClip

    ; VSCode は選択なしで Ctrl+C すると現在行が末尾改行付きでコピーされるため、
    ; 末尾が改行でない場合のみ「単一行の選択」と判定する
    hasSelection := selText != ""
        && SubStr(selText, -1) != "`n"
        && SubStr(selText, -1) != "`r"

    if (hasSelection) {
        ; 選択あり → クリックせず（解除されないように）、選択をそのまま使う
        Send "^+f"   ; Find in Files（VSCode 設定で選択が自動入力される）
    } else {
        ; 選択なし → クリック位置の単語を選択して検索
        Click
        Sleep 50
        Send "^d"    ; VSCode: カーソル位置の単語を選択
        Sleep 50
        Send "^+f"
    }
}
#HotIf
