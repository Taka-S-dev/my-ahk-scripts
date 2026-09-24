#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Picker.ahk
; Description:  ボタンの下に出す選択小窓（ルート選択・プロファイル選択で共通）
;               - 本体の一覧と同じ部品・見た目（エクスプローラーのテーマ、2 列目は補足の色）
;               - 入力欄で絞り込み（本体の一覧と同じあいまい一致）、入力欄にいる間も選択行を見せる
;               - タイトルバーのない小窓。Esc・他のウィンドウへの切り替えで閉じる
;               - キー: ↑↓ / Ctrl+J/K 移動、Enter / Ctrl+L 決定、Ctrl+H 1 文字消す、Esc 閉じる
; Usage:        NaviPicker.Open(navi, { anchor, items: [{ text, sub }], selected, placeholder, onConfirm })
; ==============================================================================

class NaviPicker {
    static _navi := ""
    static _gui := ""
    static _lvHwnd := 0
    static _items := []       ; 候補すべて [{ text, sub }]
    static _shown := []       ; 絞り込んで表示中の候補（行番号順）
    static _onConfirm := ""
    static _emptyText := ""
    static _activateCb := ""
    static _drawHandler := ""

    static WIDTH := 380   ; 小窓の中身の最低幅（元のボタンが広ければその幅に合わせる）
    static ROWS  := 9     ; 一度に見せる行数

    static IsOpen() => (this._gui && WinExist(this._gui))

    /**
     * 小窓を開く（開いていれば閉じてから開く）
     * opts.anchor      ... この部品の真下に出す
     * opts.items       ... [{ text: 名前, sub: 補足（省略可） }]。sub があれば 2 列目に出す
     * opts.selected    ... 最初に選んでおく名前
     * opts.placeholder ... 入力欄の案内
     * opts.onConfirm   ... (text) => 決定したときの処理
     * opts.emptyText   ... 候補が 1 つもないときに出す文言
     */
    static Open(nv, opts) {
        this.Close(false)
        this._navi := nv
        this._items := opts.items
        this._onConfirm := opts.onConfirm
        this._emptyText := opts.HasOwnProp("emptyText") ? opts.emptyText : "候補がありません"
        hasSub := false
        for it in this._items
            if (it.HasOwnProp("sub") && it.sub != "")
                hasSub := true

        ; 枠線は付けず、Windows 11 の角丸と縁に任せる（NaviTheme.ApplyFlyout）
        g := Gui("+Owner" . nv.GuiObj.Hwnd . " -Caption +AlwaysOnTop +ToolWindow")
        NaviTheme.ApplyPopup(g)
        NaviTheme.ApplyFlyout(g)
        g.MarginX := NaviTheme.SP_S
        g.MarginY := NaviTheme.SP_S
        this._gui := g
        ; ドロップダウンは元のボタンと同じ幅で出す（狭いボタンでは最低幅を保つ）
        opts.anchor.GetPos(, , &anchorW)
        W := Max(this.WIDTH, anchorW - 2 * NaviTheme.SP_S - 2)

        filter := g.Add("Edit", "xm w" . W . " vPickFilter")
        try DllCall("user32\SendMessageW", "ptr", filter.Hwnd, "uint", nv.EM_SETCUEBANNER, "ptr", 1,
            "wstr", opts.HasOwnProp("placeholder") ? opts.placeholder : "名前で絞り込み...", "ptr")
        ; 0x8=LVS_SHOWSELALWAYS / LV0x10000=LVS_EX_DOUBLEBUFFER
        lv := g.Add("ListView", "xm y+" . NaviTheme.SP_S . " w" . W . " r" . this.ROWS
            . " -Hdr -Multi NoSortHdr +0x8 +LV0x10000 vPickList", hasSub ? ["名前", "場所"] : ["名前"])
        nv._ApplyExplorerTheme(lv)
        this._lvHwnd := lv.Hwnd
        inner := W - SysGet(2) - 4  ; SM_CXVSCROLL
        if (hasSub) {
            lv.ModifyCol(1, Round(inner * 0.4))
            lv.ModifyCol(2, inner - Round(inner * 0.4))
        } else {
            lv.ModifyCol(1, inner)
        }
        NaviTheme.SetFont(g, "caption", NaviTheme.TEXT_SUBTLE)
        g.Add("Text", "xm y+" . NaviTheme.SP_S . " w" . W, "↑↓ 移動     Enter 決定     Esc 閉じる")

        filter.OnEvent("Change", (*) => this._Filter())
        lv.OnEvent("DoubleClick", (*) => this._Confirm())
        if (this._drawHandler == "") {
            this._drawHandler := (w, l, m, h) => this._OnNotify(l)
            OnMessage(nv.WM_NOTIFY, this._drawHandler)
        }
        this._Filter(opts.HasOwnProp("selected") ? opts.selected : "")

        ; ほかのウィンドウに切り替わったら閉じる
        popupHwnd := g.Hwnd
        cb := (wParam, lParam, msg, hwnd) => (hwnd = popupHwnd && (wParam & 0xFFFF) = 0)
            ? SetTimer(() => this.Close(false), -50) : ""
        this._activateCb := cb
        OnMessage(nv.WM_ACTIVATE, cb)

        HotIfWinActive("ahk_id " . g.Hwnd)
        Hotkey("Enter",  (*) => this._Confirm(), "On")
        Hotkey("Escape", (*) => this.Close(), "On")
        Hotkey("Down",   (*) => this._Move(1), "On")
        Hotkey("Up",     (*) => this._Move(-1), "On")
        Hotkey("^j",     (*) => this._Move(1), "On")
        Hotkey("^k",     (*) => this._Move(-1), "On")
        Hotkey("^l",     (*) => this._Confirm(), "On")
        Hotkey("^h",     (*) => this._Backspace(), "On")
        HotIf()

        ; 部品の左下を画面座標にして、その真下に出す
        pt := Buffer(8, 0)
        opts.anchor.GetPos(, , , &ah)
        NumPut("int", 0, "int", Round(ah * A_ScreenDPI / 96) + 2, pt)
        DllCall("user32\ClientToScreen", "ptr", opts.anchor.Hwnd, "ptr", pt)
        g.Show("Hide AutoSize")
        DllCall("user32\SetWindowPos", "ptr", g.Hwnd, "ptr", 0, "int", NumGet(pt, 0, "int"), "int", NumGet(pt, 4, "int")
            , "int", 0, "int", 0, "uint", 0x1 | 0x4 | 0x40)  ; SWP_NOSIZE | SWP_NOZORDER | SWP_SHOWWINDOW
        WinActivate("ahk_id " . g.Hwnd)
        filter.Focus()
    }

    /**
     * 小窓を閉じる
     * backToOwner: Navi を前面に戻すか（他のウィンドウへ切り替わって閉じるときは戻さない）
     */
    static Close(backToOwner := true) {
        nv := this._navi
        if (this._activateCb != "") {
            OnMessage(nv.WM_ACTIVATE, this._activateCb, 0)
            this._activateCb := ""
        }
        g := this._gui
        this._gui := ""  ; 先に外して再入を防ぐ
        this._lvHwnd := 0
        if (g && WinExist(g))
            try g.Destroy()
        if (backToOwner && nv && nv.GuiObj && WinExist(nv.GuiObj))
            WinActivate("ahk_id " . nv.GuiObj.Hwnd)
    }

    ; 入力に合わせて候補を絞り込む。keep に名前を渡すとその行を選んでおく（なければ先頭）
    static _Filter(keep := "") {
        g := this._gui
        if !(g && WinExist(g))
            return
        terms := NaviDirList._ParseQuery(g["PickFilter"].Value)
        if (terms.Length == 0) {
            shown := this._items.Clone()
        } else {
            ; 名前に一致したものを上に。補足（パス）への一致でも残す。同じスコアは元の順
            scored := []
            for i, it in this._items {
                sub := it.HasOwnProp("sub") ? it.sub : ""
                s := NaviDirList._Score(sub != "" ? sub : it.text, it.text, terms)
                if (s >= 0)
                    scored.Push({ item: it, score: s, order: i })
            }
            loop scored.Length - 1 {  ; 件数は少ないので挿入ソートで十分
                j := A_Index + 1
                cur := scored[j]
                while (j > 1 && (scored[j - 1].score < cur.score
                    || (scored[j - 1].score = cur.score && scored[j - 1].order > cur.order))) {
                    scored[j] := scored[j - 1]
                    j--
                }
                scored[j] := cur
            }
            shown := []
            for s in scored
                shown.Push(s.item)
        }
        this._shown := shown
        lv := g["PickList"]
        lv.Opt("-Redraw")
        lv.Delete()
        row := 0
        if (shown.Length == 0) {
            ; 空の状態: 選べない案内の行だけ出す（_shown は空なので決定しても何も起きない）
            lv.Add(, (terms.Length == 0) ? this._emptyText : "一致するものがありません")
            lv.Opt("+Redraw")
            return
        }
        for i, it in shown {
            lv.Add(, it.text, it.HasOwnProp("sub") ? it.sub : "")
            if (keep != "" && it.text == keep)
                row := i
        }
        if (shown.Length > 0)
            lv.Modify(row ? row : 1, "Select Focus Vis")
        lv.Opt("+Redraw")
    }

    static _Move(delta) {
        g := this._gui
        if !(g && WinExist(g))
            return
        lv := g["PickList"]
        n := this._shown.Length
        if (n == 0)
            return
        cur := lv.GetNext(0)
        next := (cur == 0) ? 1 : Mod(cur - 1 + delta + n, n) + 1  ; 端で折り返す
        lv.Modify(0, "-Select")
        lv.Modify(next, "Select Focus Vis")
    }

    ; Ctrl+H: 入力欄を 1 文字消す（左に移る先がないため）
    static _Backspace() {
        g := this._gui
        if !(g && WinExist(g))
            return
        filter := g["PickFilter"]
        ; Focus() は入力欄の全文を選択するので、フォーカスが別の場所にあるときだけ移して末尾に置く
        if (DllCall("user32\GetFocus", "ptr") != filter.Hwnd) {
            filter.Focus()
            len := StrLen(filter.Value)
            SendMessage(0x00B1, len, len, filter)  ; EM_SETSEL
        }
        Navi._EditBackspace(filter)
    }

    static _Confirm() {
        g := this._gui
        if !(g && WinExist(g))
            return
        ; IME 変換中の Enter は確定に使う
        hIMC := DllCall("imm32\ImmGetContext", "ptr", g["PickFilter"].Hwnd, "ptr")
        if (hIMC) {
            composing := DllCall("imm32\ImmGetCompositionStringW", "ptr", hIMC, "uint", 0x0008, "ptr", 0, "ptr", 0) > 0
            DllCall("imm32\ImmReleaseContext", "ptr", g["PickFilter"].Hwnd, "ptr", hIMC)
            if (composing) {
                Send "{Enter}"
                return
            }
        }
        row := g["PickList"].GetNext(0)
        if (row == 0 || row > this._shown.Length)
            return
        text := this._shown[row].text
        cb := this._onConfirm
        this.Close()
        if (cb != "")
            cb.Call(text)
    }

    ; 2 列目を補足の色にし、入力欄にいる間も選択行を薄い青で見せる
    static _OnNotify(l) {
        if (!this._lvHwnd || NumGet(l, 0, "ptr") != this._lvHwnd || NumGet(l, A_PtrSize * 2, "int") != -12)  ; NM_CUSTOMDRAW
            return
        x64 := (A_PtrSize = 8)
        stage := NumGet(l, x64 ? 24 : 12, "uint")
        if (stage = 0x1)            ; CDDS_PREPAINT
            return 0x20             ; CDRF_NOTIFYITEMDRAW
        if (stage = 0x10001) {      ; CDDS_ITEMPREPAINT: 列ごとの通知を頼む
            NaviTheme.PaintSoftSelection(l, this._lvHwnd)
            return 0x22             ; CDRF_NOTIFYSUBITEMDRAW | CDRF_NEWFONT
        }
        if (stage = 0x30001) {      ; CDDS_SUBITEM | CDDS_ITEMPREPAINT
            subItem := NumGet(l, x64 ? 88 : 56, "int")
            ; 空の状態の案内行は選べないので案内の色、それ以外は 1 列目が本文・2 列目が補足
            color := (this._shown.Length == 0) ? NaviTheme.TEXT_SUBTLE
                : (subItem = 1) ? NaviTheme.TEXT_MUTED : NaviTheme.TEXT
            NumPut("uint", NaviTheme.BGR(color), l, x64 ? 80 : 48)
            NaviTheme.PaintSoftSelection(l, this._lvHwnd)
            return 0x2              ; CDRF_NEWFONT
        }
        return 0
    }
}
