#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Theme.ahk
; Description:  Navi の見た目の定義（色・文字・余白）を 1 か所にまとめる
;               - 画面ごとに色やフォントを直書きせず、ここの値を参照する
;               - 色は Windows 11（Fluent）の既定の色味に合わせる
;               - 灰色は役割で 3 段に絞る（本文 TEXT / 補足 TEXT_MUTED / 案内 TEXT_SUBTLE）
; Usage:        NaviTheme.SetFont(gui, "body") / NaviTheme.BGR(NaviTheme.ACCENT) など
; ==============================================================================

class NaviTheme {
    ; --- 面の色（RGB の 16 進） ---
    static BG          := "FFFFFF"  ; 本体・ポップアップの背景
    static SURFACE     := "F3F3F3"  ; タブの帯など、本体より一段下がった面
    static HOVER       := "E5E5E5"  ; マウスを乗せたときの面
    static GUIDE       := "DCDCDC"  ; ツリーのインデントガイド
    static DIVIDER     := "C8C8C8"  ; タブの間の区切り線

    ; --- 文字の色 ---
    static TEXT        := "1F1F1F"  ; 本文
    static TEXT_MUTED  := "5C5C5C"  ; 補足（パンくず・見出し・非アクティブのタブ）
    static TEXT_SUBTLE := "8A8A8A"  ; 案内文・プレースホルダーに近い控えめな文字

    ; --- 意味のある色 ---
    static ACCENT      := "0067C0"  ; 強調・選択中のタブの線・コマンドのキー
    static ACCENT_SOFT := "CCE4F7"  ; 選択行の背景（フォーカスが入力欄にある間）
    static MATCH       := "0067C0"  ; フィルターに一致したフォルダの文字
    static MARK        := "0F7B0F"  ; マークしたフォルダの文字
    static FOUND       := "BC4B09"  ; 検索で見つかった項目の文字

    ; --- 文字 ---
    ; 英数字と日本語の大きさ・字間がそろい、小さくてもくっきりする Meiryo UI
    ; （Segoe UI は日本語を別フォントで補うため日本語だけ大きく間延びし、
    ;   Yu Gothic UI は 9pt だと線が細く薄く見えた）
    static FONT        := "Meiryo UI"
    static FONT_MONO   := "Consolas"
    static SIZE_BODY    := 9   ; 本文・ボタン・入力欄
    static SIZE_CAPTION := 8   ; 見出し・案内文・ステータスバー
    static SIZE_KEY     := 10  ; コマンド一覧のキー

    ; --- アイコン ---
    ; 絵文字は小さいボタンでは潰れるので、Windows のアイコンフォント（エクスプローラーや設定アプリと同じ絵柄）を使う
    ; 文字コードは Segoe Fluent Icons（Windows 11）と Segoe MDL2 Assets（Windows 10）で共通
    static ICON_SIZE     := 10
    static ICON_SETTINGS := Chr(0xE713)  ; 歯車
    static ICON_FOLDER   := Chr(0xE8B7)  ; フォルダー
    static ICON_SEARCH   := Chr(0xE721)  ; 虫めがね
    static ICON_FILE     := Chr(0xE8A5)  ; 文書
    static ICON_ALL      := Chr(0xE71D)  ; すべて
    static _iconFont     := ""

    ; --- 余白・大きさ（4 の倍数でそろえる） ---
    static SP_XS := 4
    static SP_S  := 8
    static SP_M  := 12
    static SP_L  := 16
    static CONTROL_H := 26  ; ボタン・入力欄の高さ

    /**
     * 役割名でフォントを設定する
     * role: "body" / "heading"（本文の太字）/ "caption" / "key"（等幅・太字）
     * color: 文字色（RGB の 16 進）。省略時は本文の色
     */
    static SetFont(target, role := "body", color := "") {
        c := " c" . (color != "" ? color : this.TEXT)
        switch role {
            case "heading": target.SetFont("s" . this.SIZE_BODY . " bold" . c, this.FONT)
            case "caption": target.SetFont("s" . this.SIZE_CAPTION . " norm" . c, this.FONT)
            case "key":     target.SetFont("s" . this.SIZE_KEY . " bold" . c, this.FONT_MONO)
            default:        target.SetFont("s" . this.SIZE_BODY . " norm" . c, this.FONT)
        }
    }

    ; 使えるアイコンフォント（Windows 11 の Segoe Fluent Icons、なければ Windows 10 の Segoe MDL2 Assets）
    static IconFont() {
        if (this._iconFont == "") {
            installed := ""
            try installed := RegRead("HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts", "Segoe Fluent Icons (TrueType)")
            this._iconFont := (installed != "") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"
        }
        return this._iconFont
    }

    ; ボタンなどにアイコンを付ける（以後 .Text に別の ICON_* を入れれば絵柄だけ替わる）
    static SetIcon(ctrl, glyph) {
        ctrl.SetFont("s" . this.ICON_SIZE . " norm c" . this.TEXT, this.IconFont())
        ctrl.Text := glyph
    }

    /**
     * 重なって出る小窓（メニュー・選択小窓）を Windows 11 の flyout と同じ見た目にする
     * DWM に角丸を頼むと、Windows 11 が角丸の縁と影を描く（Windows 10 では何も起きない）
     * 表示する前（Gui 作成直後）に呼ぶ
     */
    static ApplyFlyout(g) {
        pref := Buffer(4, 0)
        NumPut("int", 3, pref)  ; DWMWCP_ROUNDSMALL（メニューと同じ小さめの角丸）
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "int", 33, "ptr", pref, "int", 4)  ; DWMWA_WINDOW_CORNER_PREFERENCE
    }

    ; ポップアップ・ダイアログの共通の下地（背景色と余白）
    static ApplyPopup(g) {
        g.BackColor := this.BG
        g.MarginX := this.SP_M
        g.MarginY := this.SP_M
        this.SetFont(g, "body")
    }

    /**
     * 一覧（ListView）の NM_CUSTOMDRAW で、一覧自体にフォーカスがない間の選択行を ACCENT_SOFT で塗る
     * テーマのままだと、入力欄で打っている間の選択行はほぼ見えない灰色になるため
     * ITEMPREPAINT・SUBITEM の ITEMPREPAINT の両方で呼ぶ（CDRF_NEWFONT を返すこと）
     */
    static PaintSoftSelection(l, lvHwnd) {
        if (DllCall("user32\GetFocus", "ptr") = lvHwnd)
            return  ; 一覧にフォーカスがあればテーマの選択色のまま
        x64 := (A_PtrSize = 8)
        item := NumGet(l, x64 ? 56 : 36, "uptr")
        if !(SendMessage(0x102C, item, 0x2, lvHwnd) & 0x2)  ; LVM_GETITEMSTATE: LVIS_SELECTED
            return
        stateOff := x64 ? 64 : 40
        ; CDIS_SELECTED を外してテーマの灰色を描かせず、背景色だけ指定する
        NumPut("uint", NumGet(l, stateOff, "uint") & ~0x1, l, stateOff)
        NumPut("uint", this.BGR(this.ACCENT_SOFT), l, x64 ? 84 : 52)  ; clrTextBk
    }

    ; RGB の 16 進（"0067C0"）を、カスタムドローで使う COLORREF（BGR の整数）にする
    static BGR(hex) {
        return Integer("0x" . SubStr(hex, 5, 2) . SubStr(hex, 3, 2) . SubStr(hex, 1, 2))
    }
}
