; ============================================================
; Main entry script
; ------------------------------------------------------------
; 目的:
;   - 個人用 AutoHotkey v2 環境の統合エントリポイント
;   - 各種モジュール（IME制御 / Vim操作 / スニペットUI 等）を
;     一元的に読み込み、共通設定を初期化する
;
; 特徴:
;   - 機能単位で modules / ui に分離
;   - 本ファイルは「配線（glue）」のみを担当し、
;     個別ロジックは持たない
;
; 対象:
;   - AutoHotkey v2.0 以降
;
; ============================================================

#Requires AutoHotkey v2.0
#SingleInstance Force   ; 二重起動防止
#Warn                   ; 潜在的な問題を警告
SetWorkingDir A_ScriptDir  ; 相対パス基準をスクリプト配置先に固定

; ============================================================
; 修飾キーの定義 (Define Modifier Key)
; ============================================================
; 記述例:
;   - "vk1D"      : 無変換 (JISキーボード推奨)
;   - "vk1C"      : 変換
;   - "CapsLock"  : CapsLock
;   - "RAlt"      : 右Alt (USキーボード等で親指位置にある場合)
;   - "AppsKey"   : メニューキー
;   - "Space"     : スペースキー (※長押し判定等の微調整が必要な場合あり)
; ============================================================
MOD_KEY := "vk1D" ; デフォルト：無変換キー

; ============================================================
; Global hotkeys (maintenance)
; ============================================================
^!r:: Reload     ; Ctrl + Alt + R : スクリプト再読み込み
^!q:: ExitApp    ; Ctrl + Alt + Q : スクリプト終了

; ------------------------------------------------------------
; Core behavior modules
; ------------------------------------------------------------
#Include "tests\TestScript.ahk"                	   ; 検証用（通常は無効）

; ------------------------------------------------------------
; IME 操作の定義 関連
; ------------------------------------------------------------
#Include "modules\ImeControl.ahk"                  ; IME ON/OFF 制御
; --- IME 操作の定義 ---
; 1. 変換(vk1C) 単押し：IME ON
vk1C:: ImeControl.Toggle(true)

; ------------------------------------------------------------
; Excel風の日付入力の設定
; ------------------------------------------------------------
#Include "modules\DateTimeInsert.ahk" ; Excel 風の日付時刻入力
; 日付入力 (Ctrl + ;) のみ定義
^;:: DateTimeInsert.Execute()

; ------------------------------------------------------------
; 【修飾キー制御】選択可能な2つのモード
; ------------------------------------------------------------
#Include "modules\ModifierKeyHandler.ahk"

; ------------------------------------------------------------
; モード1: 空打ちでIME切り替え + キー無効化（デフォルト）
; ------------------------------------------------------------
ModifierKeyHandler.Init("vk1D", "sc07B")  ; 無変換キー (Muhenkan)
ModifierKeyHandler.OnTap := (*) => ImeControl.Toggle(false)

; ------------------------------------------------------------
; モード2: キー無効化のみ（IME切り替えなし）
; 上記をコメントアウトし、以下を有効化:
; ------------------------------------------------------------
; ModifierKeyHandler.Init("vk1D", "sc07B")
; ; OnTapを設定しない = キー無効化のみ

; ------------------------------------------------------------
; 他のキーに変更する例:
; ------------------------------------------------------------
; CapsLock:  ModifierKeyHandler.Init("vkF0", "sc03A")
; Space:     ModifierKeyHandler.Init("vk20", "sc039")
; Right Alt: ModifierKeyHandler.Init("vkA5", "sc138")
; ------------------------------------------------------------

; ------------------------------------------------------------
; Excel専用ホットキー（VimNavigation より優先）
; 使用する場合は /* と */ を外してください
; ------------------------------------------------------------
/*
#Include modules\ExcelFontStyle.ahk
#HotIf WinActive("ahk_class XLMAIN") && GetKeyState(MOD_KEY, "P")

; 無変換 + e で赤字
e:: ExcelFontStyle.SetFontColorRed()

; 無変換 + q で黒字 (Ctrl+Qよりさらに押しやすい)
q:: ExcelFontStyle.SetFontColorBlack()

; 無変換 + x で取り消し線
x:: ExcelFontStyle.SetFontColorStrikethrough()

; 無変換 + g でグレー塗りつぶし
g:: ExcelFontStyle.ToggleFillColor(0x808080)

; 無変換 + i で行挿入 / Shift+i で列挿入
i:: ExcelFontStyle.InsertRow()
+i:: ExcelFontStyle.InsertColumn()

; 無変換 + d で行削除 / Shift+d で列削除
d:: ExcelFontStyle.DeleteRow()
+d:: ExcelFontStyle.DeleteColumn()

; 無変換 + n でセル結合/解除トグル
n:: ExcelFontStyle.ToggleMerge()
#HotIf
*/

; ------------------------------------------------------------
;  Vim 風ナビゲーション定義
; ------------------------------------------------------------
#Include "modules\VimNavigation.ahk"                    ; Vim 風キーバインド
#HotIf GetKeyState(MOD_KEY, "P")

; hjkl: 基本移動
*h:: VimNavigation.Move("{Left}", "+{Left}")
*j:: VimNavigation.Move("{Down}", "+{Down}")
*k:: VimNavigation.Move("{Up}", "+{Up}")
*l:: VimNavigation.Move("{Right}", "+{Right}")

; w/b: 単語単位移動
*w:: VimNavigation.Move("^{Right}", "+^{Right}")
*b:: VimNavigation.Move("^{Left}", "+^{Left}")

; 0/4: 行頭・行末移動
*0:: VimNavigation.Move("{Home}", "+{Home}")
*4:: VimNavigation.Move("{End}", "+{End}")

; --- 編集系（単一キー） ---
; *x:: Send("{Del}")
*x:: VimNavigation.Move("{Del}", "{BackSpace}")
u:: Send("^z")        ; 元に戻す
p:: Send("^v")        ; 貼り付け

; Vimの o / O (行の挿入)
*o:: VimNavigation.OpenLine(GetKeyState("Shift", "P"))

; --- 削除命令 (d) : dd  ---
d:: VimNavigation.HandleDoubleKey("d", VimNavigation.DeleteLine)

; --- 二度打ち系 ( yy: 行コピー) ---
; HandleDoubleKey メソッドをクラス側に追加している前提です
y:: VimNavigation.HandleDoubleKey("y", VimNavigation.CopyLine)
#HotIf


; ============================================================
; UI components
; ============================================================
; ------------------------------------------------------------
;  Navi ショートカット定義
; ------------------------------------------------------------
#Include "ui\navi\Navi.ahk"  ; ナビゲーション / ランチャ UI

#HotIf GetKeyState(MOD_KEY, "P")
; Navi: GUI 起動
f:: Navi.Show()
#HotIf

; ------------------------------------------------------------
;  スニペット選択 UI
; ------------------------------------------------------------
; 1. インクルード（ここで SnippetPicker クラスを読み込む）
#Include "ui\SnippetPicker.ahk"
SnippetPicker.Init()

#HotIf GetKeyState(MOD_KEY, "P")
s:: SnippetPicker.Show()
#HotIf

; ------------------------------------------------------------
;  テンポラリメモ
; ------------------------------------------------------------
#Include "ui\TempMemo.ahk"
TempMemo.Init()

#HotIf GetKeyState(MOD_KEY, "P")
m:: TempMemo.Toggle()
#HotIf

; ------------------------------------------------------------
;  ホットストリングマネージャ
; ------------------------------------------------------------
#Include "ui\HotstringManager.ahk"
HotstringManager.Init()
; 無変換を押しながら Ctrl + H
#HotIf GetKeyState(MOD_KEY, "P")
^h:: HotstringManager.Show()
#HotIf

; ------------------------------------------------------------
; WrapPaletteホットキー
; ------------------------------------------------------------
#Include ui\WrapPalette.ahk

#HotIf GetKeyState(MOD_KEY, "P")
r:: WrapPalette.Execute()
#HotIf

; ============================================================
; Global Explorer Enhancements
; ============================================================
; ------------------------------------------------------------
; エクスプローラーでテンポラリコピーオープン
; ------------------------------------------------------------
; 使用する場合は、以下のコメントアウト（/* と */）を外してください。
; これにより、エクスプローラーがアクティブな時だけ以下のショートカットが有効になります。
/*
#Include lib\TempCopy.ahk

; エクスプローラーで無変換 + T → 選択中のファイルをテンポラリコピーで開く（無選択時はテンポラリフォルダを開く）
; 対応: Windows Explorer, Tablacus Explorer
; 他のファイルマネージャーを追加する場合は、Window Spy (AutoHotkey付属) でウィンドウクラスを調べて追加してください
#HotIf (WinActive("ahk_class CabinetWClass") || WinActive("ahk_class ExploreWClass") || WinActive("ahk_class TablacusExplorer")) && GetKeyState(MOD_KEY, "P")
t:: TempCopy.Open(TempCopy.GetSelectedPath())
#HotIf
*/

; ------------------------------------------------------------
;  QuickSwitch - ウィンドウ/URLジャンプ
; ------------------------------------------------------------
#Include "ui\QuickSwitch.ahk"
QuickSwitch.Init()
#HotIf GetKeyState("vk1D", "P")
a:: QuickSwitch.Show()         ; デフォルトに直接ジャンプ（未設定時はメニュー）
+a:: QuickSwitch.ShowMenu()     ; 常にメニュー表示
^+a:: QuickSwitch.ShowSettings() ; 設定画面
#HotIf
