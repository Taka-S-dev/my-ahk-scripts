#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.KeyMenu.ahk
; Description:  1 文字キーで実行するメニューの共通部品
;               コマンド一覧（Ctrl+;）・アクションメニュー（Space）・詳細リストのアクションメニューで使う
;               - 左にキー（強調色の等幅）、右に名前の行を、見出しごとに列へ並べる
;               - 1 文字押すとその項目を実行して閉じる。行のクリックでも実行できる
;               - Esc・一覧にないキー・他のウィンドウへの切り替えで閉じる
; Usage:        NaviKeyMenu.Show({ owner, title, columns, items, afterRun })
; ==============================================================================

class NaviKeyMenu {
    static _gui := ""
    static _owner := ""
    static _ih := ""
    static _activateCb := ""
    static _items := []
    static _afterRun := ""

    static COL_W     := 200  ; 1 列の幅
    static TIMEOUT_S := 30   ; 何も押さなければ閉じるまでの秒数
    static WM_ACTIVATE := 0x0006

    static IsOpen() => (this._gui != "")

    /**
     * メニューを開く（開いていれば閉じるだけ。同じキーでの開閉にそのまま使える）
     * opts.owner    ... 持ち主の Gui（この中央に出し、閉じたら前面に戻す）
     * opts.title    ... 上に出す見出し（省略可。例: 対象のフォルダ名）
     * opts.columns  ... 列ごとに並べる見出しの配列 [["開く"], ["コピー", "その他"]]
     * opts.items    ... [{ key, label, group, run: () => 処理, on: () => 真偽（省略可） }]
     *                   on が真なら名前の前に ✓ を付ける。columns にない group は最後の列に入れる
     * opts.afterRun ... 項目を実行した後に呼ぶ処理（省略可）
     */
    static Show(opts) {
        if (this._gui) {
            this.Close()
            return
        }
        owner := opts.owner
        if !(owner && WinExist(owner))
            return
        this._owner := owner
        this._items := opts.items
        this._afterRun := opts.HasOwnProp("afterRun") ? opts.afterRun : ""

        ; 枠線は付けず、Windows 11 の角丸と縁に任せる（NaviTheme.ApplyFlyout）
        g := Gui("+Owner" . owner.Hwnd . " -Caption +AlwaysOnTop +ToolWindow")
        NaviTheme.ApplyPopup(g)
        NaviTheme.ApplyFlyout(g)
        g.MarginX := NaviTheme.SP_L
        this._gui := g

        columns := this._Columns(opts.columns)
        top := g.MarginY
        if (opts.HasOwnProp("title") && opts.title != "") {
            NaviTheme.SetFont(g, "heading")
            g.Add("Text", "x" . g.MarginX . " y" . top . " w" . (columns.Length * this.COL_W - 10), opts.title)
                .GetPos(, &ty, , &th)
            top := ty + th + NaviTheme.SP_S
        }
        bottom := top
        for ci, groups in columns {
            x := g.MarginX + (ci - 1) * this.COL_W
            for gi, group in groups {
                NaviTheme.SetFont(g, "caption", NaviTheme.TEXT_SUBTLE)
                pos := (gi == 1) ? "x" . x . " y" . top : "x" . x . " y+" . NaviTheme.SP_M
                g.Add("Text", pos . " w" . (this.COL_W - 10), group)
                for item in this._items {
                    if (item.group != group)
                        continue
                    isOn := false
                    if item.HasOwnProp("on")
                        try isOn := item.on.Call()
                    NaviTheme.SetFont(g, "key", NaviTheme.ACCENT)
                    k := g.Add("Text", "x" . x . " y+" . NaviTheme.SP_XS . " w22", item.key)
                    NaviTheme.SetFont(g, "body")
                    l := g.Add("Text", "x+6 yp+1 w" . (this.COL_W - 38), (isOn ? "✓ " : "") . item.label)
                    k.OnEvent("Click", ((it, *) => this._Run(it)).Bind(item))
                    l.OnEvent("Click", ((it, *) => this._Run(it)).Bind(item))
                    l.GetPos(, &ly, , &lh)
                    bottom := Max(bottom, ly + lh)
                }
            }
        }
        NaviTheme.SetFont(g, "caption", NaviTheme.TEXT_SUBTLE)
        g.Add("Text", "x" . g.MarginX . " y" . (bottom + NaviTheme.SP_M), "1 文字で実行 ・ クリックでも実行 ・ Esc で閉じる")

        ; 持ち主の中央に出す
        g.Show("Hide AutoSize")
        owner.GetPos(&ox, &oy, &ow, &oh)
        g.GetPos(, , &w, &h)
        g.Show("x" . (ox + (ow - w) // 2) . " y" . (oy + (oh - h) // 2))

        ; ほかのウィンドウに切り替わったら閉じる
        popupHwnd := g.Hwnd
        cb := (wParam, lParam, msg, hwnd) => (hwnd = popupHwnd && (wParam & 0xFFFF) = 0)
            ? SetTimer(() => this.Close(false), -1) : ""
        this._activateCb := cb
        OnMessage(this.WM_ACTIVATE, cb)

        ; 1 文字だけ受け取る（メニューが前面にあるので持ち主のホットキーには渡らない）
        ih := InputHook("L1 T" . this.TIMEOUT_S, "{Esc}")
        ih.OnEnd := (h) => SetTimer(() => this._OnInputEnd(h), -1)
        this._ih := ih
        ih.Start()
    }

    ; columns に出てこない見出しは、最後の列の末尾に足す（設定ファイルで足したアクションなど）
    static _Columns(columns) {
        known := Map()
        cols := []
        for groups in columns {
            cols.Push(groups.Clone())
            for g in groups
                known[g] := true
        }
        for item in this._items {
            if !known.Has(item.group) {
                known[item.group] := true
                cols[cols.Length].Push(item.group)
            }
        }
        return cols
    }

    static _OnInputEnd(ih) {
        if (ih != this._ih)
            return
        key := (ih.EndReason = "Max") ? ih.Input : ""
        if (key == "") {
            this.Close()
            return
        }
        ; 大文字小文字を区別して探し、なければ小文字の項目を使う（Shift+E でも e が動く）
        item := this._Find(key)
        if (!item && key != StrLower(key))
            item := this._Find(StrLower(key))
        if (item)
            this._Run(item)
        else
            this.Close()  ; 一覧にないキー（もう一度 Space など）は閉じるだけ
    }

    static _Find(key) {
        for item in this._items {
            if (item.key == key)
                return item
        }
        return ""
    }

    ; メニューを閉じて持ち主に戻り、項目を実行する
    static _Run(item) {
        owner := this._owner
        after := this._afterRun
        this.Close()
        if !(owner && WinExist(owner))
            return
        try item.run.Call()
        catch as e {
            ToolTip("コマンドエラー: " . e.Message)
            SetTimer(() => ToolTip(), -2000)
        }
        if (after != "")
            try after.Call()
    }

    /**
     * メニューを閉じる
     * backToOwner: 持ち主を前面に戻すか（他のウィンドウに切り替わって閉じるときは戻さない）
     */
    static Close(backToOwner := true) {
        if (this._activateCb != "") {
            OnMessage(this.WM_ACTIVATE, this._activateCb, 0)
            this._activateCb := ""
        }
        if (this._ih) {
            ih := this._ih
            this._ih := ""  ; 先に外して _OnInputEnd の再入を防ぐ
            try ih.Stop()
        }
        if (this._gui) {
            g := this._gui
            this._gui := ""
            try g.Destroy()
            owner := this._owner
            if (backToOwner && owner && WinExist(owner))
                WinActivate("ahk_id " . owner.Hwnd)
        }
    }
}
