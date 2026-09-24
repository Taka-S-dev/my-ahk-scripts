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

    ; ポップアップ・ダイアログの共通の下地（背景色と余白）
    static ApplyPopup(g) {
        g.BackColor := this.BG
        g.MarginX := this.SP_M
        g.MarginY := this.SP_M
        this.SetFont(g, "body")
    }

    ; RGB の 16 進（"0067C0"）を、カスタムドローで使う COLORREF（BGR の整数）にする
    static BGR(hex) {
        return Integer("0x" . SubStr(hex, 5, 2) . SubStr(hex, 3, 2) . SubStr(hex, 1, 2))
    }
}
