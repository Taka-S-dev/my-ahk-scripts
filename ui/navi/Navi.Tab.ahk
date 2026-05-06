#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Tab.ahk
; Description:  Navi タブ管理モジュール
;               - タブ状態の保存・復元・切り替え
;               - タブバー GUI の構築と表示/非表示切り替え
;               - タブ内ルート履歴（戻る/進む）
;               - INI へのタブ状態永続化
; Usage:        NaviTab.Init(naviRef) を Navi.Init() から呼び出す
; ==============================================================================

class NaviTab {
    static _navi := ""

    ; --- タブ定数 ---
    static TAB_MAX    := 5   ; タブ最大数
    static TAB_WIDTH  := 85  ; タブ1枠の幅px（(GUI_WIDTH-2*MarginX - (TAB_MAX-1)) / TAB_MAX）
    static TAB_HISTORY_MAX := 20  ; タブ内ルート履歴の最大保持件数
    static TAB_ACTIVE_COLOR        := 0x00CC5500  ; 下線色（COLORREF BGR: 青系）
    static TAB_UL_BACKGROUND_COLOR := 0xF0F0F0   ; 下線背景色（ウィンドウ背景と合わせて透過風に）
    static PBM_SETBARCOLOR         := 0x0409     ; プログレスバー前景色設定
    static PBM_SETBKCOLOR          := 0x040A     ; プログレスバー背景色設定

    ; --- タブ状態 ---
    static _Tabs       := []  ; タブ配列（各要素: {root, filter, marks, markFilter, path, history, future}）
    static _CurrentTab := 1   ; アクティブタブ番号（1-based）
    static _TabCount   := 1   ; 現在開いているタブ数

    ; --- タブバー GUI コントロール参照 ---
    static _TabBtnCtrls := []  ; タブラベルコントロール配列
    static _TabULCtrl   := ""  ; アクティブタブ下線インジケーター（Progress コントロール）
    static _TabSepCtrl  := ""  ; タブ/ヘッダー境界線
    static _tabBarVisible := true  ; タブバー表示状態（1タブ時は非表示）
    static _tabBarShift   := 0     ; タブバー非表示時にコントロールを上げるpx（Show()で実測値に確定）

    static Init(naviRef) {
        this._navi := naviRef
    }

    ; ==============================================================================
    ; GUI 構築
    ; ==============================================================================

    /**
     * タブバーコントロールを guiObj に追加し、タブバー先頭の Y 座標を返す
     * Show() から呼ぶ。戻り値は _tabBarShift 計算に使用する。
     */
    static BuildTabBar(guiObj) {
        nv := this._navi
        this._TabBtnCtrls := []
        guiObj.SetFont("s9", "Yu Gothic UI")
        Loop this.TAB_MAX {
            n    := A_Index
            w    := this.TAB_WIDTH
            xOpt := (n = 1) ? "xm w" . w . " h20 +0x101" : "x+1 yp w" . w . " h20 +0x101"  ; SS_CENTER|SS_NOTIFY（クリック通知有効）
            lbl  := guiObj.Add("Text", xOpt, this._GetTabLabel(n))
            this._TabBtnCtrls.Push(lbl)
            lbl.OnEvent("Click",       this.MakeTabHandler(n))
            lbl.OnEvent("DoubleClick", this._MakeTabDblClickHandler(n))
            if (n > this._TabCount)
                lbl.Visible := false
        }
        ; アクティブタブ下線（Progress バーを流用）
        ulCtrl := guiObj.Add("Progress", "xm y+0 w" . this.TAB_WIDTH . " h3 -Smooth -Border", 100)
        DllCall("SendMessage", "ptr", ulCtrl.Hwnd, "uint", this.PBM_SETBARCOLOR, "ptr", 0, "uint", this.TAB_ACTIVE_COLOR)
        DllCall("SendMessage", "ptr", ulCtrl.Hwnd, "uint", this.PBM_SETBKCOLOR,  "ptr", 0, "uint", this.TAB_UL_BACKGROUND_COLOR)
        this._TabULCtrl := ulCtrl
        ; タブとヘッダーの境界線（ブラウザ風の区切り線）
        tabSep := guiObj.Add("Text", "x0 y+0 w" . (nv.GUI_WIDTH + 2 * guiObj.MarginX) . " h2 +0x10")  ; SS_ETCHEDHORZ 全幅
        this._TabSepCtrl := tabSep
        ; タブバー先頭の Y 座標を返す（_tabBarShift 計算用）
        tabBarTopY := 0
        this._TabBtnCtrls[1].GetPos(, &tabBarTopY)
        return tabBarTopY
    }

    /**
     * タブ関連ホットキーを登録する（Show() の HotIf ブロック内から呼ぶ）
     */
    static RegisterHotkeys() {
        Loop this.TAB_MAX {
            Hotkey("^" . A_Index, this.MakeTabHandler(A_Index), "On")
        }
        Hotkey("^t",    (*) => this.NewTab(),         "On")
        Hotkey("^w",    (*) => this.CloseTab(),        "On")
        Hotkey("^Tab",  (*) => this.SwitchToTab(Mod(this._CurrentTab, this._TabCount) + 1), "On")
        Hotkey("^+Tab", (*) => this.SwitchToTab(Mod(this._CurrentTab - 2 + this._TabCount, this._TabCount) + 1), "On")
        Hotkey("!Left",  (*) => this.TabNavBack(),    "On")
        Hotkey("!Right", (*) => this.TabNavForward(), "On")
        Hotkey("^+h",    (*) => this.ClearTabHistory(), "On")
    }

    /**
     * GUI 破棄時にコントロール参照をリセット（タブ状態は保持して次回起動時に再利用）
     */
    static Cleanup() {
        this._TabBtnCtrls := []
        this._TabULCtrl   := ""
        this._TabSepCtrl  := ""
    }

    ; ==============================================================================
    ; タブバー表示更新
    ; ==============================================================================

    /**
     * タブバーのラベルと下線インジケーター位置を更新
     * タブ数が1のときは非表示、2以上のときは表示する
     */
    static UpdateTabBar() {
        nv := this._navi
        Loop this.TAB_MAX {
            n := A_Index
            if (n > this._TabBtnCtrls.Length)
                break
            ctrl := this._TabBtnCtrls[n]
            if (n > this._TabCount) {
                ctrl.Visible := false
                continue
            }
            ctrl.Visible := (this._TabCount > 1)
            DllCall("user32\SendMessageW", "ptr", ctrl.Hwnd,
                "uint", nv.WM_SETTEXT, "ptr", 0, "wstr", this._GetTabLabel(n))
        }
        if (this._TabULCtrl) {
            this._TabULCtrl.Visible := (this._TabCount > 1)
            margin := nv.GuiObj.MarginX
            this._TabULCtrl.Move(margin + (this._CurrentTab - 1) * (this.TAB_WIDTH + 1))
        }
        this.SetTabBarVisible(this._TabCount > 1)
    }

    /**
     * タブバーの表示/非表示を切り替え、他コントロールを上下にシフトする
     */
    static SetTabBarVisible(show) {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (show == this._tabBarVisible)
            return
        this._tabBarVisible := show
        shift := show ? this._tabBarShift : -this._tabBarShift

        ; タブラベルと下線の表示切り替え
        for ctrl in this._TabBtnCtrls
            ctrl.Visible := show
        if (this._TabULCtrl)
            this._TabULCtrl.Visible := show
        if (this._TabSepCtrl)
            this._TabSepCtrl.Visible := show

        ; タブバー下のコントロールを全て上下にシフト
        ctrls := [
            nv.GuiObj["ProfileBtn"], nv.GuiObj["ProfileSep"],
            nv.GuiObj["RootBtn"],
            nv.GuiObj._btnEditCtrl, nv.GuiObj._btnSettingsCtrl,
            nv.GuiObj["PinCheck"], nv.GuiObj["AutoFilesCheck"],
            nv.GuiObj["Breadcrumb"], nv.GuiObj["FilterToggle"],
            nv.GuiObj["SearchTypeBtn"], nv.GuiObj["TreeFilter"],
            nv.GuiObj["FolderTree"],
            nv.GuiObj["QuickPath"]
        ]
        for ctrl in ctrls {
            ctrl.GetPos(, &cy)
            ctrl.Move(, cy + shift)
        }
        nv._tvY += shift
    }

    ; ==============================================================================
    ; タブ状態の読み書き
    ; ==============================================================================

    /**
     * GUIから現在の表示状態を読み取って返す
     */
    static _GetLiveState() {
        nv := this._navi
        marks := Map()
        for k, v in NaviMark._MarkedPaths
            marks[k] := v
        tv    := nv.GuiObj["FolderTree"]
        selPath := ""
        selId := tv.GetSelection()
        if (selId)
            try selPath := nv._GetTVFullPath(tv, selId)
        return {
            root:       nv.lastRoot,
            filter:     nv.GuiObj["TreeFilter"].Value,
            marks:      marks,
            markFilter: NaviMark._MarkFilterActive,
            path:       selPath
        }
    }

    /**
     * 現在のタブに表示状態を保存
     */
    static SaveCurrentTab() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        s := this._GetLiveState()
        while (this._Tabs.Length < this._CurrentTab)
            this._Tabs.Push({ root: "", filter: "", marks: Map(), markFilter: false, path: "", history: [], future: [] })
        tab := this._Tabs[this._CurrentTab]
        tab.root := s.root, tab.filter := s.filter, tab.marks := s.marks
        tab.markFilter := s.markFilter, tab.path := s.path
    }

    /**
     * 現在のルート操作前に呼ぶ: 現在の状態をタブ内履歴に積む（Alt+← で戻れる）
     */
    static PushTabHistory() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        while (this._Tabs.Length < this._CurrentTab)
            this._Tabs.Push({ root: "", filter: "", marks: Map(), markFilter: false, path: "", history: [], future: [] })
        tab := this._Tabs[this._CurrentTab]
        s := this._GetLiveState()
        tab.history.Push({ root: s.root, filter: s.filter, marks: s.marks, markFilter: s.markFilter, path: s.path })
        if (tab.history.Length > this.TAB_HISTORY_MAX)
            tab.history.RemoveAt(1)
        tab.future := []
    }

    /**
     * 状態オブジェクトを TreeView に適用する共通ヘルパー
     */
    static _ApplyTabState(state, tv) {
        nv := this._navi
        if (state.root != "" && nv._FolderMap.Has(state.root) && state.root != nv.lastRoot) {
            nv.lastRoot := state.root
            nv.GuiObj["RootBtn"].Text := nv._TruncRootLabel(state.root)
        }
        rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
        nv.GuiObj["TreeFilter"].Value := state.filter
        if (state.markFilter && rootPath != "") {
            NaviMark._MarkedPaths    := state.marks
            NaviMark._MarkFilterActive := true
            NaviMark._ApplyMarkFilter(tv, rootPath)
        } else if (state.filter != "" && rootPath != "") {
            NaviMark._MarkFilterActive := false
            NaviMark._MarkedPaths    := state.marks
            NaviFilter.ApplyTreeFilter(state.filter)
        } else if (rootPath != "") {
            NaviMark._MarkFilterActive := false
            nv._RefreshTree(tv, rootPath, false)
            NaviMark._MarkedPaths := state.marks
            NaviMark._RebuildMarkedIdSet(tv)
            NaviFilter.EnsureFilterDraw(tv)
            DllCall("user32\InvalidateRect", "ptr", tv.Hwnd, "ptr", 0, "int", 1)
        }
        if (state.path != "" && rootPath != "")
            nv._FocusPath(tv, state.path)
    }

    /**
     * 現在のタブ状態を TreeView に復元する（Show() 初期化用）
     */
    static RestoreCurrentTab(tv) {
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return false
        tab := this._Tabs[this._CurrentTab]
        nv  := this._navi
        if (tab.root == "" || !nv._FolderMap.Has(tab.root))
            return false
        this._ApplyTabState(tab, tv)
        return true
    }

    ; ==============================================================================
    ; タブ操作
    ; ==============================================================================

    /**
     * タブNのクリック・ホットキー用クロージャを生成（ループ変数キャプチャ対策）
     */
    static MakeTabHandler(n) {
        return (*) => this.SwitchToTab(n)
    }

    /**
     * タブダブルクリック: そのタブに切り替えてルート選択を開く
     */
    static _MakeTabDblClickHandler(n) {
        nv := this._navi
        return (*) => (this.SwitchToTab(n), nv._OpenDropdown())
    }

    /**
     * タブNのラベルを返す（下線がアクティブを示すため、ラベルはルート名のみ）
     */
    static _GetTabLabel(n) {
        if (n > this._TabCount)
            return ""
        root := (n == this._CurrentTab) ? this._navi.lastRoot
            : (n <= this._Tabs.Length && this._Tabs[n] != "") ? this._Tabs[n].root : ""
        if (root == "")
            root := "New"
        ; 85px幅: 日本語全角7文字≈70px、ASCII14文字≈84px → 7文字超で切り詰め
        return (StrLen(root) > 7) ? SubStr(root, 1, 6) . ".." : root
    }

    /**
     * タブNに切り替える（現在の状態を保存してから復元）
     */
    static SwitchToTab(n) {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (n < 1 || n > this._TabCount)
            return
        this.SaveCurrentTab()
        this._CurrentTab := n
        tv  := nv.GuiObj["FolderTree"]
        tab := (n <= this._Tabs.Length) ? this._Tabs[n] : ""
        if (tab == "" || tab.root == "") {
            nv.GuiObj["TreeFilter"].Value := ""
            NaviMark._MarkFilterActive := false
            rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
            if (rootPath != "")
                nv._RefreshTree(tv, rootPath, false)
            NaviMark._MarkedPaths := Map()
            NaviMark._MarkedIdSet := Map()
        } else {
            this._ApplyTabState(tab, tv)
        }
        this.UpdateTabBar()
        nv._UpdateStatusBar()
        nv.GuiObj["TreeFilter"].Focus()
    }

    /**
     * 新しいタブを開く（Ctrl+T）: 現在のルートで初期化、フィルター・マークはクリア
     */
    static NewTab() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this._TabCount >= this.TAB_MAX)
            return
        this.SaveCurrentTab()
        this._TabCount++
        while (this._Tabs.Length < this._TabCount)
            this._Tabs.Push({ root: "", filter: "", marks: Map(), markFilter: false, path: "", history: [], future: [] })
        this._Tabs[this._TabCount] := {
            root: nv.lastRoot, filter: "", marks: Map(),
            markFilter: false, path: "", history: [], future: []
        }
        this._CurrentTab := this._TabCount
        tv := nv.GuiObj["FolderTree"]
        nv.GuiObj["TreeFilter"].Value := ""
        NaviMark._MarkFilterActive := false
        NaviMark._MarkedPaths := Map()
        NaviMark._MarkedIdSet := Map()
        rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
        if (rootPath != "")
            nv._RefreshTree(tv, rootPath, false)
        this.UpdateTabBar()
        nv._UpdateStatusBar()
    }

    /**
     * 現在のタブを閉じる（Ctrl+W）: タブが1枚のときは何もしない
     */
    static CloseTab() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this._TabCount <= 1)
            return
        this._Tabs.RemoveAt(this._CurrentTab)
        this._TabCount--
        if (this._CurrentTab > this._TabCount)
            this._CurrentTab := this._TabCount
        tv  := nv.GuiObj["FolderTree"]
        tab := (this._CurrentTab <= this._Tabs.Length) ? this._Tabs[this._CurrentTab] : ""
        if (tab == "" || tab.root == "") {
            nv.GuiObj["TreeFilter"].Value := ""
            NaviMark._MarkFilterActive := false
            NaviMark._MarkedPaths := Map()
            NaviMark._MarkedIdSet := Map()
            rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
            if (rootPath != "")
                nv._RefreshTree(tv, rootPath, false)
        } else {
            this._ApplyTabState(tab, tv)
        }
        this.UpdateTabBar()
        nv._UpdateStatusBar()
    }

    /**
     * タブ内履歴を戻る（Alt+←）
     */
    static TabNavBack() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return
        tab := this._Tabs[this._CurrentTab]
        if (tab.history.Length == 0)
            return
        s := this._GetLiveState()
        tab.future.Push({ root: s.root, filter: s.filter, marks: s.marks, markFilter: s.markFilter, path: s.path })
        prev := tab.history.Pop()
        tab.root := prev.root, tab.filter := prev.filter, tab.marks := prev.marks
        tab.markFilter := prev.markFilter, tab.path := prev.path
        this._ApplyTabState(tab, nv.GuiObj["FolderTree"])
        this.UpdateTabBar()
        nv._UpdateStatusBar()
    }

    /**
     * タブ内履歴を進む（Alt+→）
     */
    static TabNavForward() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return
        tab := this._Tabs[this._CurrentTab]
        if (tab.future.Length == 0)
            return
        s := this._GetLiveState()
        tab.history.Push({ root: s.root, filter: s.filter, marks: s.marks, markFilter: s.markFilter, path: s.path })
        next := tab.future.Pop()
        tab.root := next.root, tab.filter := next.filter, tab.marks := next.marks
        tab.markFilter := next.markFilter, tab.path := next.path
        this._ApplyTabState(tab, nv.GuiObj["FolderTree"])
        this.UpdateTabBar()
        nv._UpdateStatusBar()
    }

    /**
     * 現在のタブの履歴（戻る・進む）をクリア（Ctrl+Shift+H）
     */
    static ClearTabHistory() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return
        tab := this._Tabs[this._CurrentTab]
        tab.history := []
        tab.future  := []
        ToolTip("タブ履歴をクリアしました"), SetTimer(() => ToolTip(), -nv.TOOLTIP_SUCCESS_DURATION)
    }

    ; ==============================================================================
    ; INI 永続化
    ; ==============================================================================

    /**
     * プロファイルパスから INI セクション名を生成（例: "Tabs_work"）
     * プロファイル未設定時は "Tabs" を返す
     */
    static _ProfileTabSection(profilePath := "") {
        nv := this._navi
        if (profilePath == "")
            profilePath := IniRead(nv.IniPath, "Settings", "LastProfile", "")
        if (profilePath == "")
            return "Tabs"
        name := RegExReplace(profilePath, ".*\\")   ; basename
        name := RegExReplace(name, "\.txt$", "")    ; 拡張子除去
        name := RegExReplace(name, "[^\w]", "_")    ; 使用不可文字を _
        return "Tabs_" . name
    }

    /**
     * 全タブ状態を Navi.ini のプロファイル別セクションに保存
     */
    static SaveTabsToIni() {
        nv  := this._navi
        sec := this._ProfileTabSection()
        try IniDelete(nv.IniPath, sec)
        IniWrite(this._TabCount,   nv.IniPath, sec, "Count")
        IniWrite(this._CurrentTab, nv.IniPath, sec, "Current")
        Loop this._TabCount {
            n   := A_Index
            tab := (n <= this._Tabs.Length) ? this._Tabs[n] : ""
            if (tab == "")
                continue
            IniWrite(tab.root,                     nv.IniPath, sec, "Tab" . n . "Root")
            IniWrite(tab.filter,                   nv.IniPath, sec, "Tab" . n . "Filter")
            IniWrite(tab.path,                     nv.IniPath, sec, "Tab" . n . "Path")
            IniWrite(tab.markFilter ? "1" : "0",   nv.IniPath, sec, "Tab" . n . "MarkFilter")
            markStr := ""
            for k, v in tab.marks
                markStr .= (markStr == "" ? "" : "|") . v
            IniWrite(markStr, nv.IniPath, sec, "Tab" . n . "Marks")
        }
    }

    /**
     * Navi.ini のプロファイル別セクションからタブ状態を復元
     * Show() の _LoadFolders 直後に呼ぶこと（タブバー生成前に _TabCount を確定させるため）
     */
    static LoadTabsFromIni() {
        nv  := this._navi
        sec := this._ProfileTabSection()
        ; プロファイル別セクションになければ旧来の [Tabs] にフォールバック
        if (IniRead(nv.IniPath, sec, "Count", "") == "")
            sec := "Tabs"
        count   := Max(1, Min(Integer(IniRead(nv.IniPath, sec, "Count",   "1")), this.TAB_MAX))
        current := Max(1, Min(Integer(IniRead(nv.IniPath, sec, "Current", "1")), count))
        this._TabCount   := count
        this._CurrentTab := current
        this._Tabs       := []

        Loop count {
            n    := A_Index
            root := IniRead(nv.IniPath, sec, "Tab" . n . "Root",       "")
            filt := IniRead(nv.IniPath, sec, "Tab" . n . "Filter",     "")
            pth  := IniRead(nv.IniPath, sec, "Tab" . n . "Path",       "")
            mf   := IniRead(nv.IniPath, sec, "Tab" . n . "MarkFilter", "0")
            mStr := IniRead(nv.IniPath, sec, "Tab" . n . "Marks",      "")

            marks := Map()
            if (mStr != "")
                for p in StrSplit(mStr, "|")
                    if (p != "")
                        marks[StrLower(p)] := p

            this._Tabs.Push({
                root: root, filter: filt, path: pth,
                markFilter: (mf == "1"), marks: marks,
                history: [], future: []
            })
        }
    }
}
