#Requires AutoHotkey v2.0
; ==============================================================================
; Module:      Navi.Breadcrumb.ahk
; Description: Navi パンくずリストモジュール
;              - TreeView の選択変更を監視してパスを更新（ポーリング方式）
;              - パンくずクリック時の階層ポップアップメニュー表示
;              - ハンドカーソル表示（WM_SETCURSOR ハンドラー）
; Usage:       NaviBreadcrumb.Init(naviRef) を Navi.Init() から呼び出す
; ==============================================================================

class NaviBreadcrumb {
    static _navi := ""
    static _hwnd          := 0    ; パンくずコントロールの Hwnd（カーソル変更用）
    static _lastSelectedId := 0   ; 前回の選択ノード ID（変更検知用）

    ; --- 定数 ---
    static BREADCRUMB_COLOR    := "505050"  ; パンくずテキスト色（グレー）
    static BREADCRUMB_HEIGHT   := 20        ; パンくずコントロールの高さ（px）
    static BREADCRUMB_WATCH_MS := 100       ; 選択監視タイマー間隔（ms）

    static Init(naviRef) {
        this._navi := naviRef
    }

    ; ==============================================================================
    ; タイマー制御
    ; ==============================================================================

    /** パンくず選択監視タイマーを開始する（Show() から呼ぶ） */
    static StartWatcher() {
        this._lastSelectedId := 0
        SetTimer(NaviBreadcrumb._Watcher.Bind(NaviBreadcrumb), this.BREADCRUMB_WATCH_MS)
    }

    /** パンくず選択監視タイマーを停止する（_DestroyGui() から呼ぶ） */
    static StopWatcher() {
        SetTimer(NaviBreadcrumb._Watcher.Bind(NaviBreadcrumb), 0)
    }

    ; ==============================================================================
    ; パンくず更新
    ; ==============================================================================

    /**
     * TreeView の選択変更を監視してパンくずを更新する（ポーリングタイマー）
     * GUI がなくなった場合はタイマーを自己停止する。
     */
    static _Watcher() {
        nv := this._navi
        try {
            if !(nv.GuiObj && nv.GuiObj.Hwnd && WinExist("ahk_id " nv.GuiObj.Hwnd)) {
                this.StopWatcher()
                return
            }
            tv := nv.GuiObj["FolderTree"]
            id := tv.GetSelection()
            if (id != this._lastSelectedId) {
                this._lastSelectedId := id
                this._Update(tv, id)
            }
        }
    }

    /**
     * 現在の TreeView 選択からパンくずを即時更新する（Show() 初期化・タブ切り替え後用）
     */
    static Refresh() {
        nv := this._navi
        try {
            if !(nv.GuiObj && nv.GuiObj.Hwnd && WinExist("ahk_id " nv.GuiObj.Hwnd))
                return
            tv := nv.GuiObj["FolderTree"]
            id := tv.GetSelection()
            this._lastSelectedId := id
            this._Update(tv, id)
        }
    }

    static _Update(tv, id) {
        nv := this._navi
        try {
            if !(nv.GuiObj && nv.GuiObj.Hwnd)
                return
            nv.GuiObj["Breadcrumb"].Value := (id = 0) ? "" : nv._GetTVFullPath(tv, id)
        }
    }

    ; ==============================================================================
    ; カーソル・クリックイベント
    ; ==============================================================================

    /**
     * WM_SETCURSOR ハンドラー: パンくずコントロール上でハンドカーソルを表示する
     * OnMessage(WM_SETCURSOR, NaviBreadcrumb._OnSetCursor.Bind(NaviBreadcrumb)) で登録。
     */
    static _OnSetCursor(wParam, lParam, msg, hwnd) {
        if (wParam != this._hwnd)
            return
        DllCall("user32\SetCursor", "ptr", DllCall("user32\LoadCursorW", "ptr", 0, "ptr", 32649, "ptr"))  ; IDC_HAND
        return true  ; デフォルト処理をスキップ
    }

    /**
     * パンくずクリック: 選択ノードの各階層をポップアップメニューで表示し、
     * 選択するとそのノードへジャンプする
     */
    static _OnClick() {
        nv := this._navi
        tv := nv.GuiObj["FolderTree"]
        id := tv.GetSelection()
        if (id = 0)
            return

        pathParts := []
        currID := id
        while (currID != 0) {
            pathParts.InsertAt(1, { id: currID, name: tv.GetText(currID) })
            currID := tv.GetParent(currID)
        }
        bcMenu := Menu()
        for i, part in pathParts {
            partID := part.id
            indent := ""
            loop i - 1
                indent .= "    "
            bcMenu.Add(indent . part.name, ((pid, *) => this._JumpToItem(pid)).Bind(partID))
        }
        ; Esc ホットキーを一時無効化（メニューの Esc 閉じを AHK が横取りするため）
        HotIfWinActive("ahk_id " nv.GuiObj.Hwnd)
        Hotkey("Esc", "Off")
        HotIf()
        bcMenu.Show()
        HotIfWinActive("ahk_id " nv.GuiObj.Hwnd)
        Hotkey("Esc", "On")
        HotIf()
    }

    /** 指定ノードを選択・展開してフォーカスを移す */
    static _JumpToItem(id) {
        nv := this._navi
        tv := nv.GuiObj["FolderTree"]
        tv.Modify(id, "Select Vis")
        if (tv.GetChild(id)) {
            tv.Modify(id, "Expand")
            nv._OnItemExpand(tv, id)
        }
        tv.Focus()
    }
}
