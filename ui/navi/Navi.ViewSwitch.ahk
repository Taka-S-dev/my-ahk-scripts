#Requires AutoHotkey v2.0
; ==============================================================================
; Module:      Navi.ViewSwitch.ahk
; Description: 表示の切り替え（ツリー / 一覧 / 3 列）をクリックでできるボタン
;              - エクスプローラーの表示切り替えと同じく、パスの行の右端にアイコンだけで並べる
;              - 今の表示のアイコンは本文の色にして下にアクセントの線を引き、ほかは薄い色にする
;              - マウスを乗せると名前と切り替えのキーを出す（キー操作を覚えるきっかけにもする）
; Usage:       NaviViewSwitch.Init(naviRef) を Navi.Init() から、
;              NaviViewSwitch.Build(gui) を Navi.Show() のパンくず作成後に呼ぶ。
;              並べる位置は NaviBrowse.LayoutNavButtons が Layout を呼んで決める
; ==============================================================================

class NaviViewSwitch {
    static _navi := ""
    static _btns := Map()       ; ボタンの hwnd → { mode, tip }
    static _ctrls := Map()      ; 表示の種類 → { btn, mark（下の線） }
    static _mode := ""          ; 今ボタンで示している表示
    static _tipFor := 0         ; ツールチップを出しているボタンの hwnd
    static _tipTimer := ""
    static _cursorHandler := ""

    static BTN_W  := 24         ; ボタンの幅px
    static MARK_H := 2          ; 今の表示を示す下の線の太さpx
    ; [表示の種類, アイコン（Segoe Fluent Icons）, ツールチップ]
    static MODES := [["tree", 0xF003, "ツリー"]
        , ["list", 0xE8FD, "一覧 (Ctrl+E)"]
        , ["browse", 0xE8C0, "3 列 (Ctrl+B)"]]

    static Init(naviRef) {
        this._navi := naviRef
    }

    /** ボタンと下の線を作る（位置は Layout で決める） */
    static Build(gui) {
        this._btns := Map(), this._ctrls := Map(), this._mode := ""
        for spec in this.MODES {
            ; 線を先に作ると重なり順が上になるので、ボタンとは重ならない位置（ボタンの真下）に置く
            mark := gui.Add("Text", "x0 y0 w" . this.BTN_W . " h" . this.MARK_H . " Hidden Background" . NaviTheme.ACCENT, "")
            ; 0x301 = SS_CENTER | SS_NOTIFY（クリックを受ける）| SS_CENTERIMAGE（縦も中央）
            btn := gui.Add("Text", "x0 y0 w" . this.BTN_W . " h" . NaviBreadcrumb.BREADCRUMB_HEIGHT . " +0x301", Chr(spec[2]))
            btn.SetFont("s" . NaviTheme.ICON_SIZE . " norm c" . NaviTheme.TEXT_SUBTLE, NaviTheme.IconFont())
            fn := ((m, *) => this.Switch(m)).Bind(spec[1])
            btn.OnEvent("Click", fn)
            btn.OnEvent("DoubleClick", fn)
            this._btns[btn.Hwnd] := { mode: spec[1], tip: spec[3] }
            this._ctrls[spec[1]] := { btn: btn, mark: mark }
        }
        NaviTheme.SetFont(gui, "body")
        if (this._cursorHandler == "") {
            this._cursorHandler := (w, l, m, hw) => this._OnSetCursor(w)
            OnMessage(0x0020, this._cursorHandler)  ; WM_SETCURSOR
        }
    }

    /**
     * パスの行（x, y, 幅, 高さ）の右端にボタンを並べ、パスに使えなくなった幅（右側に空ける幅）を返す
     */
    static Layout(x, y, w, h) {
        if (this._ctrls.Count == 0)
            return 0
        n := this.MODES.Length
        left := x + w - n * this.BTN_W
        for i, spec in this.MODES {
            c := this._ctrls[spec[1]]
            bx := left + (i - 1) * this.BTN_W
            c.btn.Move(bx, y, this.BTN_W, h - this.MARK_H)
            c.mark.Move(bx + 4, y + h - this.MARK_H, this.BTN_W - 8, this.MARK_H)
        }
        return n * this.BTN_W + NaviTheme.SP_S
    }

    ; 今の表示
    static CurrentMode() => NaviBrowse.Active ? "browse" : NaviDirList.Active ? "list" : "tree"

    /** 今の表示に合わせて、ボタンの色と下の線を付け直す（表示が変わったときだけ描き直す） */
    static Update() {
        mode := this.CurrentMode()
        if (mode == this._mode || this._ctrls.Count == 0)
            return
        this._mode := mode
        for m, c in this._ctrls {
            on := (m == mode)
            try {
                c.btn.SetFont("c" . (on ? NaviTheme.TEXT : NaviTheme.TEXT_SUBTLE))
                c.mark.Visible := on
            }
        }
    }

    /** ボタンのクリック: その表示に切り替える（今の表示なら何もしない） */
    static Switch(mode) {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj)) || mode == this.CurrentMode()
            return
        switch mode {
            case "tree":
                ; 3 列・一覧で選んでいたものをツリーで表示する（Ctrl+B / Ctrl+E で戻るのと同じ）
                if (NaviBrowse.Active)
                    NaviBrowse.Exit()
                else if (NaviDirList.Active)
                    NaviDirList.RevealInTree()
            case "list":
                NaviDirList.ShowList(NaviDirList.Kind)  ; 前回の種類（フォルダ / ファイル）で開く
            case "browse":
                NaviBrowse.Enter()
        }
        this.Update()
    }

    ; ボタンの上では手の形のカーソルにし、名前とキーを出す（今の表示のボタンは押しても変わらないので矢印のまま）
    static _OnSetCursor(hwnd) {
        if !this._btns.Has(hwnd)
            return
        b := this._btns[hwnd]
        if (this._tipFor != hwnd) {
            this._tipFor := hwnd
            ToolTip(b.tip, , , 4)
            if (this._tipTimer == "")
                this._tipTimer := () => this._HideTipWhenLeft()
            SetTimer(this._tipTimer, 200)
        }
        if (b.mode == this.CurrentMode())
            return
        DllCall("user32\SetCursor", "ptr", DllCall("user32\LoadCursorW", "ptr", 0, "ptr", 32649, "ptr"))  ; IDC_HAND
        return true
    }

    static _HideTipWhenLeft() {
        MouseGetPos(, , , &under, 2)
        if (under == this._tipFor)
            return
        ToolTip(, , , 4)
        this._tipFor := 0
        SetTimer(this._tipTimer, 0)
    }
}
