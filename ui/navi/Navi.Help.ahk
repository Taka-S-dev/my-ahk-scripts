#Requires AutoHotkey v2.0
; ==============================================================================
; Module:      Navi.Help.ahk
; Description: ショートカット一覧（F1 / コマンド一覧の ?）
;              - コマンド一覧と同じ角丸のポップアップに、キーと説明を見出しごとに並べる
;              - 何かキーを押す・ほかをクリックすると閉じる
;              - 中身は SECTIONS の表だけで持つ（キーを足したら、ここに 1 行足す）
; Usage:       NaviHelp.Show(owner)
; ==============================================================================

class NaviHelp {
    static _gui := ""
    static _owner := ""
    static _ih := ""
    static _activateCb := ""

    static COL_W := 330    ; 1 列の幅
    static KEY_W := 118    ; キーの欄の幅
    static WM_ACTIVATE := 0x0006

    ; 列ごとの見出し。各行は [キー, 説明]
    static SECTIONS := [
        [{ title: "基本", rows: [
            ["Ctrl+Space", "アクションメニュー（入力中でも）"],
            ["Space", "アクションメニュー（入力欄の外で）"],
            ["Enter", "開く（ファイルは関連付けアプリで）"],
            ["Esc", "入力を消す / 閉じる"],
            ["Ctrl+;", "コマンド一覧（1 文字で実行）"],
            ["Ctrl+P", "ピン留め（開いても閉じない）"],
            ["F1", "このショートカット一覧"]] },
         { title: "マウス", rows: [
            ["右クリック", "エクスプローラーと同じメニュー"],
            ["中クリック", "タブを閉じる"],
            ["戻る / 進む", "3 列で戻る / 進む"],
            ["右上のボタン", "ツリー / 一覧 / 3 列の切り替え"]] }],
        [{ title: "表示", rows: [
            ["Ctrl+E", "ツリー ↔ 一覧"],
            ["Ctrl+B", "ツリー ↔ 3 列"],
            ["Shift+Tab", "一覧のフォルダ ↔ ファイル"],
            ["Ctrl+Enter", "ツリーにファイルも表示"],
            ["Ctrl+I", "詳細リスト"],
            ["Ctrl+F", "入力欄へ"]] },
         { title: "移動", rows: [
            ["Ctrl+H/J/K/L", "← ↓ ↑ →（Vim と同じ）"],
            ["← / →", "3 列で上がる / 入る"],
            ["Alt+← / →", "3 列: 戻る / 進む　ツリー: ルート履歴"],
            ["Alt+↑", "3 列で 1 つ上へ"],
            ["Ctrl+Shift+B", "今のフォルダをルートとして開く（一時）"]] },
         { title: "一覧の絞り込み", rows: [
            ["文字", "あいまい一致（opsl → openssl）"],
            ["'word", "続けて並んだものだけに一致"],
            ["スペース", "語を区切って AND"],
            ["↑↓ PgUp/Dn", "入力欄のまま選ぶ"],
            ["→", "選んだものをツリーで表示"]] }],
        [{ title: "タブ", rows: [
            ["Ctrl+T", "新しいタブ"],
            ["Ctrl+W", "タブを閉じる（× でも）"],
            ["Ctrl+Tab", "次のタブ（Shift で前のタブ）"],
            ["Ctrl+1〜5", "そのタブへ"],
            ["Ctrl+Shift+H", "このタブのルート履歴を消す"]] },
         { title: "マーク（ツリー）", rows: [
            ["Alt+M", "マークを付ける / 外す"],
            ["Ctrl+M", "マークしたものだけ表示"],
            ["Alt+Shift+M", "マークを全部外す"]] }]
    ]

    static IsOpen() => (this._gui != "")

    /** 一覧を開く（開いていれば閉じる） */
    static Show(owner) {
        if (this._gui) {
            this.Close()
            return
        }
        if !(owner && WinExist(owner))
            return
        this._owner := owner
        g := Gui("+Owner" . owner.Hwnd . " -Caption +AlwaysOnTop +ToolWindow")
        NaviTheme.ApplyPopup(g)
        NaviTheme.ApplyFlyout(g)
        g.MarginX := NaviTheme.SP_L
        this._gui := g

        NaviTheme.SetFont(g, "heading")
        g.Add("Text", "x" . g.MarginX . " y" . g.MarginY, "ショートカット一覧").GetPos(, &ty, , &th)
        top := ty + th + NaviTheme.SP_M
        bottom := top
        descW := this.COL_W - this.KEY_W - NaviTheme.SP_L
        for ci, sections in this.SECTIONS {
            x := g.MarginX + (ci - 1) * this.COL_W
            for si, sec in sections {
                NaviTheme.SetFont(g, "caption", NaviTheme.TEXT_SUBTLE)
                pos := (si == 1) ? "x" . x . " y" . top : "x" . x . " y+" . NaviTheme.SP_M
                g.Add("Text", pos . " w" . (this.COL_W - NaviTheme.SP_L), sec.title)
                for row in sec.rows {
                    NaviTheme.SetFont(g, "caption", NaviTheme.ACCENT)
                    g.Add("Text", "x" . x . " y+" . NaviTheme.SP_XS . " w" . this.KEY_W, row[1])
                    NaviTheme.SetFont(g, "caption")
                    d := g.Add("Text", "x+0 yp w" . descW, row[2])
                    d.GetPos(, &dy, , &dh)
                    bottom := Max(bottom, dy + dh)
                }
            }
        }
        NaviTheme.SetFont(g, "caption", NaviTheme.TEXT_SUBTLE)
        g.Add("Text", "x" . g.MarginX . " y" . (bottom + NaviTheme.SP_M), "何かキーを押すか、ほかをクリックすると閉じる")
        NaviTheme.SetFont(g, "body")

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

        ; 何かキーを押したら閉じる（読むだけの画面なので、どのキーでもよい）
        ih := InputHook("L1 T120", "{Esc}{Enter}{F1}{Space}{Tab}{Left}{Right}{Up}{Down}")
        ih.OnEnd := (h) => SetTimer(() => (h == this._ih) ? this.Close() : 0, -1)
        this._ih := ih
        ih.Start()
    }

    /** 閉じる。backToOwner: 持ち主を前面に戻すか（ほかのウィンドウへ切り替わって閉じるときは戻さない） */
    static Close(backToOwner := true) {
        if (this._activateCb != "") {
            OnMessage(this.WM_ACTIVATE, this._activateCb, 0)
            this._activateCb := ""
        }
        if (this._ih) {
            ih := this._ih
            this._ih := ""
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
