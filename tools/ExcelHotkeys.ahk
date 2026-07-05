; ==============================================================================
; Module:       ExcelHotkeys.ahk
; Description:  Excel操作に関連する機能
;               - 文字色（赤/黒）・取り消し線
;               - 背景色（黄/灰）と塗りつぶしなし
;               - 罫線（格子/外枠/なし）・揃え（左/中央/右）
;               - セルの結合/解除・書式のクリア・折り返して全体表示
;               - 行・列の挿入/削除（ホットキーのみ）
;               - クリック用ポップアップパネル（無変換+Shift 2回でマウス位置に表示）
;                 ホットキーを忘れても・誤爆が怖くても、アイコンボタンをクリックして
;                 操作できる（ホバーで名前表示）。ボタンを選ぶ・マウスが離れる・
;                 Excel を離れると自動で閉じる。汎用部品 FloatingPanel.ahk を利用。
; Version:      1.4.0
; License:      MIT
;
; 単独起動（直接実行）またはMain.ahkからの #Include 両方に対応
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Force
SetWorkingDir A_ScriptDir

#Include "FloatingPanel.ahk"

class ExcelHotkeys {
    /**
     * 選択中の文字列を赤にする
     */
    static SetFontColorRed() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("{Alt}hfc")
        Sleep(150)
        Send("{Down 7}{Right 1}{Enter}")
    }

    /**
     * 選択中の文字列を黒(自動)に戻す
     */
    static SetFontColorBlack() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("{Alt}hfc")
        Sleep(150)
        Send("{Enter}")
    }

    /**
     * 取り消し線の切り替え (Strikethrough)
     */
    static SetFontColorStrikethrough() {
        if !WinActive("ahk_class XLMAIN")
            return
        ; ホーム(H) -> フォント設定(FN) を開き、取り消し線(Alt+K)をチェックして確定
        Send("{Alt}hfn")
        Sleep(200)
        Send("!k{Enter}")
    }

    /**
     * セルの背景色を指定色と塗りつぶしなしでトグル
     * color: BGR形式の色コード (例: 0x808080)
     * ※特定色の塗りはリボンに固定キーが無く、色を正確に出すため COM を使用。
     *   COM 変更は Ctrl+Z で戻せない（undo 履歴も消える）。ただしセルの値は
     *   壊さないため、当初懸念の「文字が消える」系の危険とは別物。誤ったら
     *   「塗りつぶしなし」（キー操作＝戻せる）で消せる。
     */
    static ToggleFillColor(color) {
        if !WinActive("ahk_class XLMAIN")
            return
        try {
            xl  := ComObjActive("Excel.Application")
            sel := xl.Selection
            if (sel.Interior.Color = color)
                sel.Interior.ColorIndex := -4142  ; xlColorIndexNone
            else
                sel.Interior.Color := color
        } catch Error as e {
            MsgBox("Excel操作失敗: " . e.Message)
        }
    }

    /**
     * 塗りつぶしを解除（「塗りつぶしなし」）。
     * 「塗りつぶしなし」はリボンに固定キー(Alt+H+H→N)があるためキー操作で行い、
     * Ctrl+Z で元に戻せる（特定色の黄/灰は固定キーが無いので COM のまま）。
     */
    static ClearFillColor() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("{Alt}hh")   ; 塗りつぶし色メニューを開く
        Sleep(150)
        Send("n")         ; 塗りつぶしなし
    }

    ; --- リボン経由の書式操作（キー送信なので Ctrl+Z で元に戻せる） ---
    ; 1発で送れるもの（キーチップ列を続けて送る）
    static _Ribbon(keys) {
        if !WinActive("ahk_class XLMAIN")
            return
        Send(keys)
    }
    ; サブメニューを開いてから項目を選ぶもの（メニューが開くのを待ってから項目キー）
    static _RibbonSub(openKeys, itemKey) {
        if !WinActive("ahk_class XLMAIN")
            return
        Send(openKeys)
        Sleep(150)
        Send(itemKey)
    }

    static AlignLeft()      => this._Ribbon("{Alt}hal")   ; 左揃え
    static AlignCenter()    => this._Ribbon("{Alt}hac")   ; 中央揃え
    static AlignRight()     => this._Ribbon("{Alt}har")   ; 右揃え
    static ToggleWrapText() => this._Ribbon("{Alt}hw")    ; 折り返して全体表示

    static BordersAll()     => this._RibbonSub("{Alt}hb", "a")  ; すべての罫線(格子)
    static BordersOutline() => this._RibbonSub("{Alt}hb", "s")  ; 外枠
    static BordersNone()    => this._RibbonSub("{Alt}hb", "n")  ; 罫線なし
    static ClearFormats()   => this._RibbonSub("{Alt}he", "f")  ; 書式のクリア(値は残す)

    static InsertRow() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("+{Space}")   ; 行全体を選択
        Send("^+{+}")      ; 行挿入
    }

    static InsertColumn() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("^{Space}")   ; 列全体を選択
        Send("^+{+}")      ; 列挿入
    }

    static DeleteRow() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("+{Space}")   ; 行全体を選択
        Send("^{-}")       ; 行削除
    }

    static DeleteColumn() {
        if !WinActive("ahk_class XLMAIN")
            return
        Send("^{Space}")   ; 列全体を選択
        Send("^{-}")       ; 列削除
    }

    static ToggleMerge() {
        if !WinActive("ahk_class XLMAIN")
            return
        try {
            isMerged := ComObjActive("Excel.Application").Selection.MergeCells
        } catch Error as e {
            MsgBox("Excel操作失敗: " . e.Message)
            return
        }
        if (isMerged)
            Send("{Alt}hmu")   ; 結合解除
        else
            Send("{Alt}hmm")   ; セルの結合（中央揃えなし）
    }

    ; ==========================================================================
    ; クリック用フローティングパネル（FloatingPanel.ahk を利用）
    ; ホットキーを覚えなくても・誤爆が怖くても、ラベル付きボタンをクリックで操作。
    ; パネルは NOACTIVATE なのでクリックしても Excel からフォーカスを奪わず、
    ; 各操作の WinActive("ahk_class XLMAIN") ガードを満たしたまま送信できる。
    ; ==========================================================================
    static _panel    := ""
    static _IniPath  => A_ScriptDir . "\ExcelHotkeys.ini"
    static TRAY_ITEM := "Excel パネルを表示/非表示"
    static _shiftTapTick    := 0    ; 直前に Shift を押した時刻（二度押し判定用）
    static SHIFT_TAP_WINDOW := 400  ; この ms 以内に 2 回目が来たら二度押しと判定

    /**
     * パネルのボタン定義（▼ ここを編集。各行が独立なのでカンマ管理は不要）
     *   - 追加     : b.Push(...) の行を足す（既存行をコピペでOK）
     *   - 非表示   : 行を削除 or 先頭に ";" を付けてコメントアウト
     *   - 並べ替え : 行を上下に移動するだけ
     *   - 見出し   : b.Push({ group: "見出し" }) でグループ区切り（列カウントもリセット）
     * フィールド: label=アイコン文字(必須) / tip=ホバー説明(推奨) / action=処理(必須) /
     *            color=文字色(省略可) / bg=背景色(省略可) / font=フォント(省略可) / h=高さ(省略可)
     * アイコンのみだと分かりにくいため tip でマウスホバー時に名前を表示する。
     * 記号: A=文字色 / ■=塗り色スウォッチ / ▢=塗りなし / ▦◻⬚=罫線 / ◫=結合
     * 色の例: 白FFFFFF 灰CCCCCC 緑89D185 青4FC1FF 黄F2D024 赤F48771
     */
    static _PanelButtons() {
        b := []
        b.Push({ group: "文字" })
        b.Push({ label: "A",   tip: "文字を赤",        color: "F48771", action: () => ExcelHotkeys.SetFontColorRed() })
        b.Push({ label: "A",   tip: "文字を黒(自動)",  color: "E0E0E0", action: () => ExcelHotkeys.SetFontColorBlack() })
        b.Push({ label: "S̶",   tip: "取り消し線",      color: "CCCCCC", action: () => ExcelHotkeys.SetFontColorStrikethrough() })
        b.Push({ group: "塗り" })
        b.Push({ label: "■",   tip: "背景色 ： 黄",    color: "F2D024", action: () => ExcelHotkeys.ToggleFillColor(0xFFFF) })
        b.Push({ label: "■",   tip: "背景色 ： 灰",    color: "9A9A9A", action: () => ExcelHotkeys.ToggleFillColor(0x808080) })
        b.Push({ label: "▢",   tip: "背景色 ： なし",  color: "CCCCCC", action: () => ExcelHotkeys.ClearFillColor() })
        b.Push({ group: "罫線" })
        b.Push({ label: "▦",   tip: "格子（全罫線）", color: "CCCCCC", action: () => ExcelHotkeys.BordersAll() })
        b.Push({ label: "◻",   tip: "外枠",          color: "CCCCCC", action: () => ExcelHotkeys.BordersOutline() })
        b.Push({ label: "⬚",   tip: "罫線なし",      color: "888888", action: () => ExcelHotkeys.BordersNone() })
        b.Push({ group: "揃え" })
        ; 整列アイコンは Segoe MDL2 Assets のグリフを使用（AlignLeft/Center/Right）
        b.Push({ label: Chr(0xE8E4), font: "Segoe MDL2 Assets", tip: "左揃え",   color: "CCCCCC", action: () => ExcelHotkeys.AlignLeft() })
        b.Push({ label: Chr(0xE8E3), font: "Segoe MDL2 Assets", tip: "中央揃え", color: "CCCCCC", action: () => ExcelHotkeys.AlignCenter() })
        b.Push({ label: Chr(0xE8E2), font: "Segoe MDL2 Assets", tip: "右揃え",   color: "CCCCCC", action: () => ExcelHotkeys.AlignRight() })
        b.Push({ group: "セル" })
        b.Push({ label: "◫",         tip: "セルの結合 / 解除",   color: "4FC1FF", action: () => ExcelHotkeys.ToggleMerge() })
        b.Push({ label: "🧹",        tip: "書式のクリア（値は残す）", color: "CCCCCC", action: () => ExcelHotkeys.ClearFormats() })
        b.Push({ label: "↵",         tip: "折り返して全体表示",     color: "CCCCCC", action: () => ExcelHotkeys.ToggleWrapText() })
        return b
    }
    ; ※ 行/列の挿入・削除は誤操作防止のためパネルには置かず、ホットキーに残している
    ;    挿入: 無変換+i / 無変換+Shift+i    削除: 無変換+d / 無変換+Shift+d

    ; パネルインスタンスを遅延生成して返す
    static _GetPanel() {
        if (this._panel == "")
            this._panel := FloatingPanel({
                name:    "excel",
                title:   "Excel",
                iniPath: this._IniPath,
                width:    134,   ; 3列ぶんの幅（大きく/小さく）
                fontSize: 15,    ; アイコンサイズ（上げるとパネルも拡大）
                columns:  3,     ; 各グループ(3個)がちょうど1行に収まる
                btnHeight: 26,   ; ボタン高（余白を詰める）
                opacity:  255,   ; 透過度 0-255（例: 220 で少し透ける）
                popup:    true,  ; カーソル位置に一時表示（選ぶ/離れると消える）
                activeWhen: () => WinActive("ahk_class XLMAIN"),  ; Excel を離れたら自動で閉じる
                onVisible: (v) => ExcelHotkeys._SyncTray(v),  ; 全経路でトレイのチェックを同期
                buttons: this._PanelButtons()
            })
        return this._panel
    }

    /**
     * フローティングパネルをマウスカーソル位置にトグル表示
     */
    static TogglePanel() {
        this._GetPanel().ToggleAtCursor()
    }

    /**
     * 無変換を押しながら Shift を素早く2回 → パネルをトグル。
     * （~Shift で拾うため Shift 本来の動作はそのまま。Shift 単体は Excel で
     *   何も起きないので passthrough でも安全。修飾キーは自動リピートしないので
     *   「2回押し」は必ず2回の独立した押下になる）
     */
    static OnShiftDoubleTap() {
        now := A_TickCount
        if (now - this._shiftTapTick <= this.SHIFT_TAP_WINDOW) {
            this._shiftTapTick := 0
            this.TogglePanel()
        } else {
            this._shiftTapTick := now
        }
    }

    /**
     * トレイメニューにパネル切替項目を追加する（ホットキーを忘れても操作可能）
     */
    static SetupTray() {
        tray := A_TrayMenu
        tray.Add()  ; 区切り線
        tray.Add(this.TRAY_ITEM, (*) => ExcelHotkeys.TogglePanel())
        tray.Default := this.TRAY_ITEM
        tray.Add("パネル設定…（透過/サイズ）", (*) => ExcelHotkeys._GetPanel().ShowSettings())
    }

    ; トレイメニューのチェック状態をパネル表示状態に同期（未登録でも安全）
    static _SyncTray(visible) {
        try visible ? A_TrayMenu.Check(this.TRAY_ITEM) : A_TrayMenu.Uncheck(this.TRAY_ITEM)
    }
}

; トレイメニューからもパネルを切り替えられるようにする（ホットキーを忘れても操作可能）
ExcelHotkeys.SetupTray()

; 単独起動時のみホットキーを登録
#HotIf WinActive("ahk_class XLMAIN") && GetKeyState("vk1D", "P")
e:: ExcelHotkeys.SetFontColorRed()
q:: ExcelHotkeys.SetFontColorBlack()
x:: ExcelHotkeys.SetFontColorStrikethrough()
g:: ExcelHotkeys.ToggleFillColor(0x808080)
i:: ExcelHotkeys.InsertRow()
+i:: ExcelHotkeys.InsertColumn()
d:: ExcelHotkeys.DeleteRow()
+d:: ExcelHotkeys.DeleteColumn()
n:: ExcelHotkeys.ToggleMerge()
; 無変換を押しながら Shift を素早く2回でパネルをマウス位置にポップアップ
; （~ で Shift 本来の動作は保持。L/R どちらの Shift でも可。Ctrl はクイック分析等と
;   干渉するため Shift を採用）
~LShift:: ExcelHotkeys.OnShiftDoubleTap()
~RShift:: ExcelHotkeys.OnShiftDoubleTap()
#HotIf
