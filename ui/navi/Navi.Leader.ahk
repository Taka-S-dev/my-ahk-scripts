#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Leader.ahk
; Description:  Navi のコマンド一覧（LazyVim の which-key のような 1 文字コマンド）
;               - Ctrl+; で一覧を出し、1 文字押すとその場で実行して閉じる（表示は NaviKeyMenu）
;               - コマンドは Commands に 1 行足すだけで増やせる
; Usage:        NaviLeader.Init(naviRef) を Navi.Init() から呼び出す
; ==============================================================================

class NaviLeader {
    static _navi := ""

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
        { key: "b", group: "表示", label: "3 列ブラウズ",
            run: (nv) => NaviBrowse.Active ? 0 : NaviBrowse.Enter(),
            on: (nv) => NaviBrowse.Active },
        { key: "t", group: "表示", label: "ツリー",
            run: (nv) => NaviBrowse.Active ? NaviBrowse.Exit()
                : NaviDirList.Active ? NaviDirList.RevealInTree() : nv.GuiObj["FolderTree"].Focus(),
            on: (nv) => !NaviDirList.Active && !NaviBrowse.Active },
        { key: "a", group: "表示", label: "ツリーにファイルも表示",
            run: (nv) => nv._ToggleAutoFiles(),
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
            run: (nv) => nv._TogglePin(),
            on: (nv) => nv.GuiObj["PinCheck"].Value },
        { key: "+", group: "ウィンドウ", label: "ルートを追加", run: (nv) => nv._AddRootDialog() },
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
        items := []
        for cmd in this.Commands {
            item := { key: cmd.key, label: cmd.label, group: cmd.group, run: ((c) => c.run.Call(nv)).Bind(cmd) }
            if cmd.HasOwnProp("on")
                item.on := ((c) => c.on.Call(nv)).Bind(cmd)
            items.Push(item)
        }
        NaviKeyMenu.Show({ owner: nv.GuiObj, columns: this.COLUMNS, items: items
            , afterRun: () => nv._UpdateStatusBar() })
    }

    static Close(backToNavi := true) => NaviKeyMenu.Close(backToNavi)
}
