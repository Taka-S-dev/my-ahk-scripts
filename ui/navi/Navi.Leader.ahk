#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Leader.ahk
; Description:  Navi のコマンド一覧（LazyVim の which-key のような 1 文字コマンド）
;               - Ctrl+; で一覧を出し、1 文字押すとその場で実行して閉じる
;               - 行のクリックでも実行できる。Esc・他のウィンドウへの切り替えで閉じる
;               - コマンドは Commands に 1 行足すだけで増やせる
; Usage:        NaviLeader.Init(naviRef) を Navi.Init() から呼び出す
; ==============================================================================

class NaviLeader {
    static _navi := ""
    static _gui := ""
    static _ih := ""
    static _activateCb := ""

    ; 色・文字・余白は NaviTheme を使う（キー=ACCENT の等幅太字、項目=本文、見出し・案内=TEXT_SUBTLE）
    static COL_W       := 200  ; 1 列の幅
    static TIMEOUT_S   := 30   ; 何も押さなければ閉じるまでの秒数

    ; 列ごとに並べるグループ
    static COLUMNS := [["表示", "移動"], ["選択中", "ウィンドウ"]]

    ; ==============================================================================
    ; コマンド定義テーブル
    ; 形式: { key: "x", group: "表示", label: "表示名", run: (nv) => 処理, on: (nv) => 真偽（省略可） }
    ;   key   ... 1 文字。大文字は Shift 付き（"M" と "m" は別のコマンド）
    ;   on    ... オン・オフのあるコマンドで、今オンなら ✓ を付ける
    ; ==============================================================================
    static Commands := [
        { key: "d", group: "表示", label: "フォルダ一覧",
            run: (nv) => NaviDirList.ShowList("dirs"),
            on: (nv) => NaviDirList.Active && NaviDirList.Kind == "dirs" },
        { key: "f", group: "表示", label: "ファイル一覧",
            run: (nv) => NaviDirList.ShowList("files"),
            on: (nv) => NaviDirList.Active && NaviDirList.Kind == "files" },
        { key: "t", group: "表示", label: "ツリー",
            run: (nv) => NaviDirList.Active ? NaviDirList.RevealInTree() : nv.GuiObj["FolderTree"].Focus(),
            on: (nv) => !NaviDirList.Active },
        { key: "a", group: "表示", label: "ツリーにファイルも表示",
            run: (nv) => NaviLeader._ToggleAutoFiles(nv),
            on: (nv) => nv.GuiObj["AutoFilesCheck"].Value },
        { key: "r", group: "移動", label: "ルートを選ぶ", run: (nv) => nv._OpenDropdown() },
        { key: "s", group: "移動", label: "プロファイルを選ぶ", run: (nv) => NaviProfile.OpenProfileDropdown() },
        { key: "[", group: "移動", label: "前のルートへ戻る", run: (nv) => NaviTab.TabNavBack() },
        { key: "]", group: "移動", label: "次のルートへ進む", run: (nv) => NaviTab.TabNavForward() },
        { key: "/", group: "移動", label: "入力欄へ", run: (nv) => nv.GuiObj["TreeFilter"].Focus() },
        { key: "x", group: "選択中", label: "アクションメニュー", run: (nv) => NaviActions.ShowActionMenu() },
        { key: "i", group: "選択中", label: "詳細リスト", run: (nv) => NaviDetailList.Show() },
        { key: "m", group: "選択中", label: "マークを付ける・外す", run: (nv) => NaviMark._ToggleMark() },
        { key: "M", group: "選択中", label: "マークだけ表示",
            run: (nv) => NaviMark._ToggleMarkFilter(),
            on: (nv) => NaviMark._MarkFilterActive },
        { key: "n", group: "ウィンドウ", label: "新しいタブ", run: (nv) => NaviTab.NewTab() },
        { key: "w", group: "ウィンドウ", label: "タブを閉じる", run: (nv) => NaviTab.CloseTab() },
        { key: "p", group: "ウィンドウ", label: "ピン留め",
            run: (nv) => (nv.GuiObj["PinCheck"].Value := !nv.GuiObj["PinCheck"].Value),
            on: (nv) => nv.GuiObj["PinCheck"].Value },
        { key: "e", group: "ウィンドウ", label: "ルートを編集", run: (nv) => nv._ShowEditGui(nv.GuiObj) },
        { key: ",", group: "ウィンドウ", label: "設定", run: (nv) => nv._ShowSettingsGui(nv.GuiObj) },
        { key: "?", group: "ウィンドウ", label: "ショートカット一覧", run: (nv) => nv._ShowHelp() },
    ]

    static Init(naviRef) {
        this._navi := naviRef
    }

    ; 一覧を開く（開いていれば閉じる）
    static Show() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this._gui) {
            this.Close()
            return
        }

        g := Gui("+Owner" . nv.GuiObj.Hwnd . " -Caption +AlwaysOnTop +Border +ToolWindow")
        NaviTheme.ApplyPopup(g)
        g.MarginX := NaviTheme.SP_L
        this._gui := g

        bottom := 0
        for ci, groups in this.COLUMNS {
            x := g.MarginX + (ci - 1) * this.COL_W
            for gi, group in groups {
                NaviTheme.SetFont(g, "caption", NaviTheme.TEXT_SUBTLE)
                pos := (gi == 1) ? "x" . x . " y" . g.MarginY : "x" . x . " y+" . NaviTheme.SP_M
                g.Add("Text", pos . " w" . (this.COL_W - 10), group)
                for cmd in this.Commands {
                    if (cmd.group != group)
                        continue
                    isOn := false
                    if cmd.HasOwnProp("on")
                        try isOn := cmd.on.Call(nv)
                    NaviTheme.SetFont(g, "key", NaviTheme.ACCENT)
                    k := g.Add("Text", "x" . x . " y+" . NaviTheme.SP_XS . " w22", cmd.key)
                    NaviTheme.SetFont(g, "body")
                    l := g.Add("Text", "x+6 yp+1 w" . (this.COL_W - 38), (isOn ? "✓ " : "") . cmd.label)
                    k.OnEvent("Click", ((c, *) => this._Run(c)).Bind(cmd))
                    l.OnEvent("Click", ((c, *) => this._Run(c)).Bind(cmd))
                    l.GetPos(, &ly, , &lh)
                    bottom := Max(bottom, ly + lh)
                }
            }
        }
        NaviTheme.SetFont(g, "caption", NaviTheme.TEXT_SUBTLE)
        g.Add("Text", "x" . g.MarginX . " y" . (bottom + NaviTheme.SP_M),"1 文字で実行 ・ クリックでも実行 ・ Esc で閉じる")

        ; Navi の中央に出す
        g.Show("Hide AutoSize")
        nv.GuiObj.GetPos(&nx, &ny, &nw, &nh)
        g.GetPos(, , &w, &h)
        g.Show("x" . (nx + (nw - w) // 2) . " y" . (ny + (nh - h) // 2))

        ; ほかのウィンドウに切り替わったら閉じる
        popupHwnd := g.Hwnd
        cb := (wParam, lParam, msg, hwnd) => (hwnd = popupHwnd && (wParam & 0xFFFF) = 0)
            ? SetTimer(() => this.Close(false), -1) : ""
        this._activateCb := cb
        OnMessage(Navi.WM_ACTIVATE, cb)

        ; 1 文字だけ受け取る（一覧が前面にあるので Navi のホットキーには渡らない）
        ih := InputHook("L1 T" . this.TIMEOUT_S, "{Esc}")
        ih.OnEnd := (h) => SetTimer(() => this._OnInputEnd(h), -1)
        this._ih := ih
        ih.Start()
    }

    static _OnInputEnd(ih) {
        if (ih != this._ih)
            return
        key := (ih.EndReason = "Max") ? ih.Input : ""
        if (key == "") {
            this.Close()
            return
        }
        ; 大文字小文字を区別して探し、なければ小文字のコマンドを使う
        cmd := this._Find(key)
        if (!cmd && key != StrLower(key))
            cmd := this._Find(StrLower(key))
        if (cmd)
            this._Run(cmd)
        else
            this.Close()
    }

    static _Find(key) {
        for cmd in this.Commands {
            if (cmd.key == key)
                return cmd
        }
        return ""
    }

    ; 一覧を閉じて Navi に戻り、コマンドを実行する
    static _Run(cmd) {
        nv := this._navi
        this.Close()
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        try cmd.run.Call(nv)
        catch as e {
            ToolTip("コマンドエラー: " . e.Message)
            SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
        }
        nv._UpdateStatusBar()
    }

    /**
     * 一覧を閉じる
     * backToNavi: Navi を前面に戻すか（他のウィンドウに切り替わって閉じるときは戻さない）
     */
    static Close(backToNavi := true) {
        nv := this._navi
        if (this._activateCb != "") {
            OnMessage(Navi.WM_ACTIVATE, this._activateCb, 0)
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
            if (backToNavi && nv.GuiObj && WinExist(nv.GuiObj))
                WinActivate("ahk_id " . nv.GuiObj.Hwnd)
        }
    }

    ; ツリーにファイルも表示する設定を切り替える（ヘッダーのチェックボックスと同じ）
    static _ToggleAutoFiles(nv) {
        cb := nv.GuiObj["AutoFilesCheck"]
        cb.Value := !cb.Value
        IniWrite(cb.Value ? "1" : "0", nv.IniPath, "Settings", "AutoShowFiles")
    }
}
