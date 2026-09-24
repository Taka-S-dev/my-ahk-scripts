#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.TreeDraw.ahk
; Description:  Navi ツリーの描画をまとめて受け持つ（NM_CUSTOMDRAW を 1 か所で処理する）
;               - 文字色: マーク > フィルター一致 > 検索で見つかった項目
;               - 入力欄にフォーカスがある間も、選択行を薄い青で見せる
;               - VSCode のようなインデントガイド（親の開閉矢印の真下に縦線）を描く
;               以前はフィルター・マーク・検索がそれぞれ WM_NOTIFY を受けて塗っており、
;               先に登録された方が描画を打ち切ると他方の色が付かなかったため、ここに集約した
; Usage:        NaviTreeDraw.Attach(tv) をツリー作成後に呼ぶ（何度呼んでもよい）
; ==============================================================================

class NaviTreeDraw {
    static _tvHwnd  := 0
    static _handler := ""
    static _pen     := 0
    static ICON_GAP := 3  ; アイコンと名前の間の余白px（ツリーコントロールの既定）

    static Attach(tv) {
        this._tvHwnd := tv.Hwnd
        if (this._handler == "") {
            this._handler := (w, l, m, h) => this._OnNotify(l)
            OnMessage(0x004E, this._handler)  ; WM_NOTIFY
        }
        if (!this._pen)
            this._pen := DllCall("gdi32\CreatePen", "int", 0, "int", 1, "uint", NaviTheme.BGR(NaviTheme.GUIDE), "ptr")
    }

    ; 色の付け直しを画面に反映する
    static Redraw() {
        if (this._tvHwnd)
            DllCall("user32\InvalidateRect", "ptr", this._tvHwnd, "ptr", 0, "int", 1)
    }

    static _OnNotify(l) {
        if (NumGet(l, 0, "ptr") != this._tvHwnd || NumGet(l, A_PtrSize * 2, "int") != -12)  ; NM_CUSTOMDRAW
            return
        x64 := (A_PtrSize = 8)
        stage := NumGet(l, x64 ? 24 : 12, "uint")
        if (stage = 0x1)       ; CDDS_PREPAINT
            return 0x20        ; CDRF_NOTIFYITEMDRAW
        item := NumGet(l, x64 ? 56 : 36, "ptr")
        if (stage = 0x10001) { ; CDDS_ITEMPREPAINT
            result := 0x10     ; CDRF_NOTIFYPOSTPAINT（ガイドを描くため）
            color := this._TextColor(item)
            if (color != "") {
                NumPut("uint", color, l, x64 ? 80 : 48)  ; clrText
                result |= 0x2                            ; CDRF_NEWFONT
            }
            ; ツリー自体にフォーカスがない間は、テーマの灰色の選択をやめて薄い青で塗る
            if (DllCall("user32\GetFocus", "ptr") != this._tvHwnd) {
                stateOff := x64 ? 64 : 40
                state := NumGet(l, stateOff, "uint")
                if (state & 0x1) {  ; CDIS_SELECTED
                    NumPut("uint", state & ~0x1, l, stateOff)
                    NumPut("uint", NaviTheme.BGR(NaviTheme.ACCENT_SOFT), l, x64 ? 84 : 52)  ; clrTextBk
                    result |= 0x2
                }
            }
            return result
        }
        if (stage = 0x10002) { ; CDDS_ITEMPOSTPAINT
            this._DrawGuides(l, item)
            return 0
        }
    }

    ; 文字色（COLORREF）。特別な色がなければ ""
    static _TextColor(item) {
        if (NaviMark._MarkedIdSet.Has(item))
            return NaviTheme.BGR(NaviTheme.MARK)
        if (NaviFilter._FilterMatchIdSet.Has(item))
            return NaviTheme.BGR(NaviTheme.MATCH)
        if (NaviSearch._HighlightedIdSet.Has(item))
            return NaviTheme.BGR(NaviTheme.FOUND)
        return ""
    }

    /**
     * この行を通るインデントガイドを描く
     * 祖先ごとに、その祖先の開閉矢印の中央に縦線を引く。行の上端から下端まで引くので、
     * 同じ祖先の下にある行がつながって 1 本の線になる
     */
    static _DrawGuides(l, item) {
        tv := this._tvHwnd
        depth := 0
        p := item
        while (p := SendMessage(0x110A, 3, p, tv))  ; TVM_GETNEXTITEM: TVGN_PARENT
            depth++
        if (depth = 0)
            return
        rect := Buffer(16, 0)
        NumPut("ptr", item, rect, 0)
        if !SendMessage(0x1104, 1, rect.Ptr, tv)  ; TVM_GETITEMRECT（名前部分）
            return
        textL  := NumGet(rect, 0, "int")
        indent := SendMessage(0x1106, 0, 0, tv)   ; TVM_GETINDENT
        iconW  := SysGet(49)                      ; SM_CXSMICON
        gap    := Round(this.ICON_GAP * A_ScreenDPI / 96)
        x64 := (A_PtrSize = 8)
        hdc := NumGet(l, x64 ? 32 : 16, "ptr")
        rcOff := x64 ? 40 : 20
        top    := NumGet(l, rcOff + 4, "int")
        bottom := NumGet(l, rcOff + 12, "int")
        old := DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", this._pen, "ptr")
        loop depth {
            ; k 段上の祖先の開閉矢印の中央
            x := textL - A_Index * indent - gap - iconW - indent // 2
            DllCall("gdi32\MoveToEx", "ptr", hdc, "int", x, "int", top, "ptr", 0)
            DllCall("gdi32\LineTo", "ptr", hdc, "int", x, "int", bottom)
        }
        DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", old)
    }
}
