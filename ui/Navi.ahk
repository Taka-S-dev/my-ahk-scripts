; ==============================================================================
; Module:       Navi.ahk
; Description:  汎用フォルダランチャー & アクティブパス実行ツール
;               - フォルダパスのTreeView表示とクイックアクセス
;               - 表示・非表示の個別/一括切り替え機能
;               - リストの順序入れ替え（上下移動）
;               - 外部ファイラー（Tablacus等）やVSCodeへのパス渡し
; Version:      1.0.0
; License:      MIT
;
;
; Usage Example (Main.ahk):
;   #Include ui\Navi.ahk
;   Navi.Init()
;   vk1D & f:: Navi.Show() ; 無変換 + f で起動
;
; ==============================================================================
#Requires AutoHotkey v2.0
#Include *i Navi.Search.ahk
#Include *i Navi.ContextMenu.ahk
#Include ..\lib\TempCopy.ahk

class Navi {
    ; --- クラス定数 ---
    static GUI_WIDTH := 450
    static GUI_HEIGHT_APPROX := 565
    static WINDOW_FRAME_WIDTH := 14  ; ウィンドウフレーム補正値（Win10/11標準テーマ）
    static IniPath := A_ScriptDir "\ui\Navi.ini"
    static ExplorerPath := ""
    static TOOLTIP_ERROR_DURATION := 2000
    static TOOLTIP_SUCCESS_DURATION := 1000
    static TOOLTIP_COPY_DURATION := 2000
    static TEMP_DIR_SUBPATH := "\ui\NaviTemp"
    static TEMP_PREFIX := "TEMP_"

    ; --- [追加] アクションメニュー用の定数 ---
    static MENU_BG_COLOR := "262626"  ; メニューの背景色
    static MENU_WIDTH := 210       ; メニューの幅
    static MENU_BTN_W := 190       ; ボタンの幅
    static MENU_BTN_H := 26        ; ボタンの高さ
    static MENU_OFFSET_Y := 240    ; 中央配置の計算用オフセット

    ; --- 位置決定用の定数（魔法数の明示化） ---
    static CARET_OFFSET_X := 5     ; キャレットからのXオフセット
    static CARET_GAP_Y := 25       ; キャレット下に表示する際の縦方向ギャップ
    static SCREEN_MARGIN := 10     ; 画面端からのマージン
    static MOUSE_OFFSET := 15      ; マウス位置からのオフセット

    ; --- パンくずリスト用の定数 ---
    static BREADCRUMB_COLOR := "505050"      ; パンくずテキスト色
    static BREADCRUMB_HEIGHT := 20           ; パンくずの高さ
    static BREADCRUMB_WATCH_MS := 100        ; 選択監視タイマー間隔

    ; --- セッション内メモリ ---
    static lastRoot := ""
    static lastPath := ""
    static GuiObj := ""
    static QuickPathFocused    := false
    static QuickPathHwnd       := 0
    static _TreeFilterFocused  := false
    static FilesShown := Map()
    static lastSelectedId := 0  ; パンくず更新用
    static DetailListGuiObj := ""  ; 詳細リストウィンドウ
    static _AllFolderNames := []  ; 全ルート名リスト（フィルタ前）
    static FilteredNames := []    ; フィルタ後のルート名リスト
    static _FolderMap := Map()    ; ルート名→パスマップ
    static DropdownGui := ""             ; ルート選択ドロップダウンGUI
    static ProfileDropdownGui := ""      ; プロファイル選択ドロップダウンGUI
    static _AllProfileNames   := []      ; 全プロファイル名リスト
    static _ProfileFilteredNames := []   ; フィルター後プロファイル名リスト
    static _treeFilterCallback := ""  ; ツリーフィルターデバウンス用コールバック参照
    static _indexBuildCallback := ""  ; インデックス先読み構築タイマー用コールバック参照
    static _FolderIndex := []         ; ツリーフィルター用フォルダパスキャッシュ
    static _IndexedRoot := ""         ; キャッシュが対応するルートパス
    static _FilterRunning    := false ; 再入防止フラグ
    static _FilterPending    := ""    ; 再入中に届いた最新クエリ（false=保留なし、文字列=保留あり）
    static _FilterPendingSet := false ; _FilterPending が有効かどうか（""と未設定を区別）
    static _FilterCancelled  := false ; ルート切り替え時にフィルタ処理を強制中止するフラグ
    static _FdIndexPid      := 0     ; fd 非同期インデックス構築のプロセスID
    static _FdIndexFile     := ""    ; fd 出力先一時ファイル
    static _FdIndexRoot     := ""    ; 非同期構築中のルートパス
    static _FdPollCb        := ""    ; fd 完了ポーリングタイマーコールバック
    static _OnIndexReadyCb  := ""    ; fd 完了後に呼ぶコールバック
    static _FilterMatchIdSet := Map() ; マッチノードID集合（カスタムドロー用）
    static _FilterTvHwnd     := 0     ; フィルタカスタムドロー対象 TreeView の Hwnd
    static _FilterDrawHandler := ""   ; WM_NOTIFY ハンドラー参照
    static FILTER_MATCH_COLOR := 0x00CC5500  ; フィルタマッチ着色色 BGR: RGB(0,85,204)=青
    static _MarkedPaths      := Map()   ; マーク済みパス集合（小文字キー→元パス）
    static _MarkedIdSet      := Map()   ; マークノードID集合（カスタムドロー用）
    static _MarkFilterActive := false   ; マークフィルタービュー中フラグ
    static MARK_COLOR        := 0x0000AA00  ; マーク着色色 BGR: 緑
    static _LastTreeRootPath := ""      ; 前回の _RefreshTree ルートパス（マーク初期化判定用）
    static TAB_HISTORY_MAX := 20   ; タブ内ルート履歴の最大保持件数
    static _Tabs          := []    ; タブ配列（各要素: {root, filter, marks, markFilter, path, history, future}）
    static _CurrentTab    := 1     ; アクティブタブ番号（1-based）
    static _TabCount      := 1     ; 現在開いているタブ数
    static TAB_MAX        := 5     ; タブ最大数
    static TAB_WIDTH      := 85    ; タブ1枠の幅px（(GUI_WIDTH-2*MarginX - (TAB_MAX-1)) / TAB_MAX）
    static _TabBtnCtrls   := []    ; タブラベルコントロール配列（GuiControl）
    static _TabULCtrl     := ""    ; アクティブタブ下線インジケーター（Progress コントロール）
    static _TabSepCtrl    := ""    ; タブ/ヘッダー境界線
    static TAB_ACTIVE_COLOR := 0x00CC5500  ; アンダーライン色（COLORREF BGR: 青系）
    static _ILHandle    := 0           ; TreeView 用 ImageList ハンドル
    static _IconCache   := Map()       ; 拡張子→ImageList インデックスキャッシュ
    static _ILNextIdx   := 5           ; 次に追加するアイコンのインデックス（1-4 は固定枠）
    static _tvY := 0                  ; TreeView の Y 座標（リサイズ計算用）
    static _rootBtnRightGap := 0      ; RootBtn 右側の固定幅（リサイズ計算用）
    static _BreadcrumbHwnd := 0       ; パンくずコントロールのHwnd（カーソル変更用）
    static _tvHwnd        := 0        ; TreeView の Hwnd
    static _quickPathH    := 22       ; QuickPath 欄の高さ（リサイズ計算用）
    static _tabBarVisible := true     ; タブバー表示状態（1タブ時は非表示）
    static _tabBarShift   := 25      ; タブバー非表示時にコントロールを上げるpx
    static _SearchMode       := false  ; フィルター欄の動作モード（false=フォルダフィルター / true=ファイル検索）
    static _SearchTypeFilter := "all"  ; 検索対象種別（"all" / "dir" / "file"）

    ; --- Windows API メッセージ定数 ---
    static WM_SETCURSOR   := 0x0020   ; カーソル形状変更通知
    static WM_ACTIVATE    := 0x0006   ; ウィンドウアクティブ状態変更
    static WM_SETTEXT     := 0x000C   ; コントロールテキスト設定（プレースホルダー等）
    static WM_NOTIFY      := 0x004E   ; コモンコントロール通知（カスタムドロー等）
    static PBM_SETBARCOLOR := 0x0409  ; プログレスバー前景色設定
    static PBM_SETBKCOLOR  := 0x040A  ; プログレスバー背景色設定
    static EM_SETCUEBANNER := 0x1501  ; Edit コントロールのプレースホルダーテキスト設定
    static TAB_UL_BACKGROUND_COLOR := 0xF0F0F0  ; タブ下線の背景色（ウィンドウ背景と合わせて透過風に）

    ; ---- Action registry ----
    static Actions := Map()  ; key(lower) => {label, run: (path)=>void}

    static RegisterAction(key, label, fn) {
        this.Actions[StrLower(key)] := { label: label, run: fn }
    }

    static RegisterShellAction(key, label, cmdTemplate, runOpt := "") {
        ; {path} を選択パスで置換して実行
        this.RegisterAction(key, label, (path) => (
            Run(StrReplace(cmdTemplate, "{path}", path), , runOpt)
        ))
    }

    static Init() {
        uiDir := A_ScriptDir "\ui"
        if (!DirExist(uiDir)) {
            try {
                DirCreate(uiDir)
            } catch as e {
                MsgBox("ディレクトリ作成失敗: " . e.Message, "Navi Error", 4096)
                return
            }
        }
        this._EnsureDefaultFolders()
        this.ExplorerPath := this._LoadConfig()
        this._InitDefaultActions()
        this._LoadUserActions()
    }

    static Show() {
        if (this.ExplorerPath == "") {
            this.Init()
        }

        if (this.GuiObj && WinExist(this.GuiObj)) {
            if WinActive(this.GuiObj) {
                this.GuiObj.Minimize()
            } else {
                ; フィルター欄をクリアしてから再表示（モードは維持）
                this.GuiObj["TreeFilter"].Value := ""
                this._ApplyTreeFilter("")
                this.GuiObj.Show()
                WinActivate(this.GuiObj)
                this.GuiObj["FolderTree"].Focus()
            }
            return
        }
        this.GuiObj := ""

        this.GuiObj := Gui("+AlwaysOnTop +Resize", "Navi")
        this.GuiObj.SetFont("s10", "Yu Gothic UI")

        folderMap := Map(), folderNames := []
        this._LoadFolders(folderMap, folderNames)
        this._LoadTabsFromIni()  ; タブ状態を INI から復元（_TabCount が確定するのでタブバー生成前に呼ぶ）

        chooseIdx := 1
        for i, name in folderNames {
            if (name == this.lastRoot) {
                chooseIdx := i
                break
            }
        }

        ; --- タブバー（最上部）---
        this._TabBtnCtrls := []
        this.GuiObj.SetFont("s8", "Yu Gothic UI")
        Loop this.TAB_MAX {
            n    := A_Index
            w    := this.TAB_WIDTH
            xOpt := (n = 1) ? "xm w" . w . " h20 +0x101" : "x+1 yp w" . w . " h20 +0x101"
            lbl  := this.GuiObj.Add("Text", xOpt, this._GetTabLabel(n))
            this._TabBtnCtrls.Push(lbl)
            lbl.OnEvent("Click",       this._MakeTabHandler(n))
            lbl.OnEvent("DoubleClick", this._MakeTabDblClickHandler(n))
            if (n > this._TabCount)
                lbl.Visible := false
        }
        ; アクティブタブ下線（Progress バーを流用）
        ulCtrl := this.GuiObj.Add("Progress", "xm y+0 w" . this.TAB_WIDTH . " h3 -Smooth -Border", 100)
        DllCall("SendMessage", "ptr", ulCtrl.Hwnd, "uint", this.PBM_SETBARCOLOR, "ptr", 0, "uint", this.TAB_ACTIVE_COLOR)
        DllCall("SendMessage", "ptr", ulCtrl.Hwnd, "uint", this.PBM_SETBKCOLOR,  "ptr", 0, "uint", this.TAB_UL_BACKGROUND_COLOR)
        this._TabULCtrl := ulCtrl
        ; タブとヘッダーの境界線（ブラウザ風の区切り線）
        tabSep := this.GuiObj.Add("Text", "x0 y+0 w471 h2 +0x10")  ; SS_ETCHEDHORZ 全幅（xm8+content455+rm8）
        this._TabSepCtrl := tabSep
        ; タブバーの実際の高さを計測（非表示時のシフト量として使用）
        this._TabBtnCtrls[1].GetPos(, &_tabBarTopY_)
        this.GuiObj.SetFont("s10", "Yu Gothic UI")

        ; --- ヘッダー行（プロファイル・ルート選択・編集・設定・チェックボックス）---
        rootBtnText := (this.lastRoot != "") ? this._TruncRootLabel(this.lastRoot) : "ルートを選択..."
        ; Profile は小さいフォントで控えめに（文脈ラベル的な扱い）
        this.GuiObj.SetFont("s8", "Yu Gothic UI")
        btnProfile := this.GuiObj.Add("Button", "xm y+2 w95 h26 -Tabstop vProfileBtn", this._GetProfileBtnText())
        this.GuiObj._profileBtnHwnd := btnProfile.Hwnd
        ; › セパレーターで階層を表現
        this.GuiObj.SetFont("s10", "Yu Gothic UI")
        this.GuiObj.Add("Text", "x+3 yp w14 h26 +0x201 vProfileSep", "›")  ; SS_CENTER|SS_NOTIFY
        ; Root は主役として大きめに
        rootBtn := this.GuiObj.Add("Button", "x+3 yp w190 h26 vRootBtn", rootBtnText)
        this.GuiObj._rootBtnHwnd := rootBtn.Hwnd
        btnEdit     := this.GuiObj.Add("Button", "x+5 yp w40 h26 -Tabstop", "編集")
        this.GuiObj._btnEditHwnd    := btnEdit.Hwnd
        this.GuiObj._btnEditCtrl    := btnEdit
        btnSettings := this.GuiObj.Add("Button", "x+3 yp w26 h26 -Tabstop", "⚙")
        this.GuiObj._btnSettingsCtrl := btnSettings
        pinCheck := this.GuiObj.Add("Checkbox", "x+8 yp+4 vPinCheck -Tabstop", "ピン留め")
        this.GuiObj._pinCheckHwnd := pinCheck.Hwnd
        autoFilesCheck := this.GuiObj.Add("Checkbox", "x+5 yp vAutoFilesCheck -Tabstop", "ファイル表示")
        autoFilesCheck.Value := (IniRead(this.IniPath, "Settings", "AutoShowFiles", "0") == "1")
        autoFilesCheck.OnEvent("Click", (*) => IniWrite(
            this.GuiObj["AutoFilesCheck"].Value ? "1" : "0", this.IniPath, "Settings", "AutoShowFiles"))
        this.GuiObj._autoFilesCheckHwnd := autoFilesCheck.Hwnd
        this._AllFolderNames := folderNames
        this.FilteredNames := folderNames.Clone()
        this._FolderMap := folderMap

        ; --- パンくずリスト ---
        this.GuiObj.SetFont("s9", "Yu Gothic UI")
        breadcrumb := this.GuiObj.Add("Text", "xm w455 h" . this.BREADCRUMB_HEIGHT . " vBreadcrumb c" . this.BREADCRUMB_COLOR . " +0x8100", "")  ; SS_NOTIFY(0x100)|SS_PATHELLIPSIS(0x8000)
        breadcrumb.OnEvent("Click", (*) => this._OnBreadcrumbClick())
        this._BreadcrumbHwnd := breadcrumb.Hwnd
        OnMessage(this.WM_SETCURSOR, Navi._OnSetCursor.Bind(Navi))
        this.GuiObj.SetFont("s10", "Yu Gothic UI")

        ; --- ツリーフィルター入力欄（モードトグルボタン付き）---
        filterToggle := this.GuiObj.Add("Button", "xm w28 h22 -Tabstop vFilterToggle", "📁")
        filterToggle.OnEvent("Click", (*) => this._ToggleSearchMode())
        this.GuiObj._filterToggleHwnd := filterToggle.Hwnd
        searchTypeBtn := this.GuiObj.Add("Button", "x+3 yp w28 h22 -Tabstop vSearchTypeBtn", "*")
        searchTypeBtn.OnEvent("Click", (*) => this._CycleSearchType())
        searchTypeBtn.Visible := false
        this.GuiObj._searchTypeBtnHwnd := searchTypeBtn.Hwnd
        ; 初期はフィルターモード: x=39, w=424(右端=TreeViewと同じ463)
        treeFilter := this.GuiObj.Add("Edit", "x39 yp w424 vTreeFilter -Tabstop", "")
        ; セッション中に検索モードだった場合は復元
        if (this._SearchMode) {
            filterToggle.Text := "🔍"
            searchTypeBtn.Visible := true
            searchTypeBtn.Text := (this._SearchTypeFilter = "dir") ? "📁" : (this._SearchTypeFilter = "file") ? "📄" : "*"
            treeFilter.Move(70,, 393)  ; 幅は後の _OnResize で正確に調整される
        }
        cue := this._SearchMode ? "ファイルを検索... (Enter で実行)" : "フォルダをフィルター..."
        try DllCall("user32\SendMessageW", "ptr", treeFilter.Hwnd, "uint", this.EM_SETCUEBANNER, "ptr", 1,
            "wstr", cue, "ptr")
        treeFilter.OnEvent("Change", (*) => this._OnTreeFilterChange())
        treeFilter.OnEvent("Focus",    (*) => (Navi._TreeFilterFocused := true))
        treeFilter.OnEvent("LoseFocus", (*) => (Navi._TreeFilterFocused := false))
        this.GuiObj._treeFilterHwnd := treeFilter.Hwnd

        ; --- TreeView ---
        tv := this.GuiObj.Add("TreeView", "xm w455 r15 vFolderTree")
        this._SetupTreeIcons(tv)
        this._tvHwnd := tv.Hwnd

        ; --- クイック登録欄（下部）---
        quickEdit := this.GuiObj.Add("Edit", "xm w455 vQuickPath -Tabstop", "")
        try DllCall("user32\SendMessageW", "ptr", quickEdit.Hwnd, "uint", this.EM_SETCUEBANNER, "ptr", 1, "wstr",
            "Add root: full path + Enter", "ptr")
        quickEdit.SetFont("s9 c808080", "Yu Gothic UI")
        quickEdit.OnEvent("Focus",    (*) => (Navi.QuickPathFocused := true))
        quickEdit.OnEvent("LoseFocus", (*) => (Navi.QuickPathFocused := false))
        this.QuickPathHwnd := quickEdit.Hwnd
        quickEdit.GetPos(,, , &_qpH_)
        this._quickPathH := _qpH_

        ; ステータスバーによる操作案内
        this.GuiObj.SetFont("s8", "Yu Gothic UI")
        sb := this.GuiObj.Add("StatusBar")
        sb.SetText(" [Space]メニュー  [Enter]開く  [Ctrl+D]詳細  [F1]ヘルプ")
        this.GuiObj._sbRef := sb

        ; リサイズ計算用に TreeView・RootBtn の位置を記録
        tv.GetPos(, &_tvY_)
        this._tvY := _tvY_
        this.GuiObj["RootBtn"].GetPos(, , &_rbW_)
        this._rootBtnRightGap := 455 - _rbW_
        ; タブバー非表示時のシフト量を確定（ヘッダーY - タブバー開始Y）
        btnProfile.GetPos(, &_headerY_)
        this._tabBarShift   := _headerY_ - _tabBarTopY_
        this._tabBarVisible := true

        ; タブ1枚のときはタブバーを初期非表示にする
        if (this._TabCount == 1)
            this._SetTabBarVisible(false)

        ; ウィンドウリサイズイベント登録
        this.GuiObj.OnEvent("Size", (g, mm, w, h) => this._OnResize(mm, w, h))

        rootBtn.OnEvent("Click", (*) => this._OpenDropdown())
        btnEdit.OnEvent("Click", (*) => this._ShowEditGui(this.GuiObj))
        btnSettings.OnEvent("Click", (*) => this._ShowSettingsGui(this.GuiObj))
        btnProfile.OnEvent("Click", (*) => this._OpenProfileDropdown())
        tv.OnEvent("ItemExpand", (obj, id, *) => this._OnItemExpand(obj, id))
        tv.OnEvent("DoubleClick", (obj, id, *) => this._HandleActivate())
        this.GuiObj.OnEvent("Close", (*) => (this.GuiObj := ""))

        ; ホットキー設定（Naviアクティブ時のみ）
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Space", (*) => this._HandleSpace(), "On")
        Hotkey("Enter", (*) => this._HandleEnter(), "On")
        Hotkey("^Enter", (*) => this.ToggleFilesUnderSelection(), "On")
        Hotkey("^p", (*) => (this.GuiObj["PinCheck"].Value := !this.GuiObj["PinCheck"].Value), "On")
        Hotkey("^d", (*) => this.ShowDetailList(), "On")
        Hotkey("^f", (*) => this.GuiObj["TreeFilter"].Focus(), "On")
        Hotkey("F1", (*) => this._ShowHelp(), "On")
        Hotkey("Esc", (*) => this._HandleEsc(), "On")
        Hotkey("~Down", (*) => this._HandleRootBtnDown(), "On")
        Hotkey("Left",  (*) => this._HandleLeftKey(),  "On")
        Hotkey("Right", (*) => this._HandleRightKey(), "On")
        Hotkey("RButton", (*) => this._HandleRButton(), "On")
        Hotkey("!m", (*) => this._ToggleMark(), "On")
        Hotkey("^m", (*) => this._ToggleMarkFilter(), "On")
        Hotkey("!+m", (*) => this._ClearAllMarks(), "On")
        Loop this.TAB_MAX {
            Hotkey("^" . A_Index, this._MakeTabHandler(A_Index), "On")
        }
        Hotkey("^t", (*) => this._NewTab(), "On")
        Hotkey("^w", (*) => this._CloseTab(), "On")
        Hotkey("^Tab",   (*) => this._SwitchToTab(Mod(this._CurrentTab, this._TabCount) + 1), "On")
        Hotkey("^+Tab",  (*) => this._SwitchToTab(Mod(this._CurrentTab - 2 + this._TabCount, this._TabCount) + 1), "On")
        Hotkey("!Left",  (*) => this._TabNavBack(), "On")
        Hotkey("!Right", (*) => this._TabNavForward(), "On")
        Hotkey("^+h", (*) => this._ClearTabHistory(), "On")
        HotIf()

        ; パンくず更新用タイマー開始
        this.lastSelectedId := 0
        SetTimer(this._BreadcrumbWatcher.Bind(this), this.BREADCRUMB_WATCH_MS)

        if (folderNames.Length > 0) {
            ; タブ状態が保存されていれば復元、なければデフォルト初期化
            if (!this._RestoreCurrentTab(tv)) {
                selectedRoot := (this.lastRoot != "" && folderMap.Has(this.lastRoot)) ? this.lastRoot : folderNames[1]
                this.lastRoot := selectedRoot
                this.GuiObj["RootBtn"].Text := this._TruncRootLabel(selectedRoot)
                this._RefreshTree(tv, folderMap[selectedRoot])
                if (this.lastPath != "") {
                    this._FocusPath(tv, this.lastPath)
                }
            }
            this._RefreshBreadcrumb()
            this._UpdateTabBar()
            this._UpdateStatusBar()
        }

        ; マウスカーソルがあるモニタの作業領域中央に配置
        CoordMode "Mouse", "Screen"
        MouseGetPos(&mX, &mY)
        monitorNum := this._GetMonitorFromPos(mX, mY)
        MonitorGetWorkArea(monitorNum, &waL, &waT, &waR, &waB)

        winW := this.GUI_WIDTH + this.WINDOW_FRAME_WIDTH
        winH := this.GUI_HEIGHT_APPROX
        centerX := waL + (waR - waL - winW) // 2
        centerY := waT + (waB - waT - winH) // 2

        this.GuiObj.Show("x" . centerX . " y" . centerY)
    }

    /**
     * アクション選択用のオーバーレイメニュー
     */
    static ShowActionMenu() {
        tvObj := this.GuiObj["FolderTree"]
        if !(id := tvObj.GetSelection()) {
            ToolTip("フォルダを選択してください")
            SetTimer(() => ToolTip(), -1000)
            return
        }

        fullPath := this._GetTVFullPath(tvObj, id)
        this.GuiObj.GetPos(&gx, &gy, &gw, &gh)

        this.GuiObj.Opt("+Disabled")

        actGui := Gui("+Owner" . this.GuiObj.Hwnd . " -Caption +AlwaysOnTop +Border")
        actGui.BackColor := this.MENU_BG_COLOR
        actGui.MarginX := 10
        actGui.MarginY := 8

        folderName := (InStr(fullPath, "\")) ? StrSplit(fullPath, "\")[-1] : fullPath
        actGui.SetFont("s8 w400 cA0A0A0", "Yu Gothic UI")
        actGui.Add("Text", "Center w" . this.MENU_BTN_W, folderName)

        actGui.SetFont("s9 w400 cWhite")
        ; レジストリに登録されたアクションからボタンを生成
        keys := []
        for k, _ in this.Actions
            keys.Push(k)
        ; AHK v2 arrays don't have a Sort method. Use global Sort() on a joined string.
        if (keys.Length > 1) {
            tmp := ""
            for _, kk in keys
                tmp .= kk . "`n"
            tmp := Sort(RTrim(tmp, "`n"))
            keys := StrSplit(tmp, "`n")
        }

        for k in keys {
            act := this.Actions[k]
            btn := actGui.Add("Button", "w" . this.MENU_BTN_W . " h" . this.MENU_BTN_H . " xm", act.label)
            btn.OnEvent("Click", ((kk, *) => (
                this.GuiObj.Opt("-Disabled"),
                actGui.Destroy(),
                this.Execute(kk)
            )).Bind(k))
        }

        btnCancel := actGui.Add("Button", "w" . this.MENU_BTN_W . " h" . this.MENU_BTN_H . " xm y+6", "&X: Cancel")
        btnCancel.OnEvent("Click", (*) => (this.GuiObj.Opt("-Disabled"), actGui.Destroy()))
        actGui.OnEvent("Escape", (*) => (this.GuiObj.Opt("-Disabled"), actGui.Destroy()))

        actGui.Show("AutoSize x" . gx + (gw - this.MENU_WIDTH) // 2 . " y" . gy + (gh - this.MENU_OFFSET_Y) // 2)
    }

    static Execute(key) {
        fullPath := ""
        if (this.GuiObj && WinExist(this.GuiObj)) {
            tvObj := this.GuiObj["FolderTree"]
            if (id := tvObj.GetSelection()) {
                fullPath := this._GetTVFullPath(tvObj, id)
                ; 操作したパスとルート名をメモリに保存
                this.lastPath := fullPath
            }
        }
        if (fullPath == "") {
            fullPath := this._GetActiveWindowPath()
        }

        if (fullPath != "" && (DirExist(fullPath) || FileExist(fullPath))) {
            ; 外部アプリ起動前にGUIを先に閉じる
            ; （ExplorerなどがAlwaysOnTopのNavi裏に隠れたり、ウィンドウアクティベーション競合を防ぐ）
            if (this.GuiObj && WinExist(this.GuiObj)) {
                ; actGui破棄後の黒塗り描画崩れを常に回復
                WinRedraw(this.GuiObj)
                k := StrLower(key)
                if (k != "f" && k != "r" && !this.GuiObj["PinCheck"].Value && !GetKeyState("Shift", "P")) {
                    if (IniRead(this.IniPath, "Settings", "AutoMinimizeOnAction", "0") == "1")
                        this.GuiObj.Minimize()
                    else
                        this._DestroyGui()
                }
            }
            this._ExecuteAction(key, fullPath)
            if (key != "k" && StrLower(key) != "f" && StrLower(key) != "r") {
                ToolTip("実行 [" . key . "]: " . fullPath)
                SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
            }
        } else {
            ToolTip("対象のパスが見つかりません")
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
        }
    }

    static _FocusPath(tv, targetPath) {
        if (!DirExist(targetPath) && !FileExist(targetPath))
            return

        currentID := tv.GetNext(0, "Full")
        if (currentID == 0)
            return

        rootPath := tv.GetText(currentID)
        if (!InStr(targetPath, rootPath))
            return

        relPath := LTrim(StrReplace(targetPath, rootPath, ""), "\")
        parts := StrSplit(relPath, "\")

        for part in parts {
            tv.Modify(currentID, "Expand")
            this._OnItemExpand(tv, currentID)

            childID := tv.GetChild(currentID)
            found := false
            while (childID != 0) {
                if (tv.GetText(childID) == part) {
                    currentID := childID
                    found := true
                    break
                }
                childID := tv.GetNext(childID)
            }
            if (!found)
                break
        }
        tv.Modify(currentID, "Select Vis")
        tv.Focus()
    }

    static _DestroyGui() {
        ; 現在のタブ状態を保存してから破棄（次回起動時に復元できるようにする）
        this._SaveCurrentTab()
        this._SaveTabsToIni()
        ; パンくず監視タイマーを停止
        SetTimer(this._BreadcrumbWatcher.Bind(this), 0)
        ; フィルタータイマーを停止（GUI破棄後に _ApplyTreeFilter が発火するのを防ぐ）
        if (this._treeFilterCallback != "") {
            SetTimer(this._treeFilterCallback, 0)
            this._treeFilterCallback := ""
        }
        ; マーク状態をリセット
        this._MarkedPaths      := Map()
        this._MarkedIdSet      := Map()
        this._MarkFilterActive := false
        this._LastTreeRootPath := ""
        ; プロファイルドロップダウンを閉じる
        this._CloseProfileDropdown()
        ; タブボタンコントロールはGUI依存のためリセット（タブ状態は次回起動時に再利用）
        this._TabBtnCtrls := []
        this._TabULCtrl  := ""
        this._TabSepCtrl := ""
        if (this.GuiObj && WinExist(this.GuiObj)) {
            ; 検索ウィンドウなど付随UIも確実に閉じる
            try NaviSearch._DestroyJumpGui()
            this._CloseDropdown()
            this.GuiObj.Destroy()
            this.GuiObj := ""
        }
    }

    /**
     * ショートカット一覧ヘルプを表示
     */
    static _ShowHelp() {
        helpText := "
        (
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                  Navi - ショートカット一覧
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            【基本操作】
              Space         アクションメニューを表示
              Enter         エクスプローラーで開く
              Esc           ウィンドウを閉じる

            【表示切替】
              Ctrl+Enter    ファイル表示トグル
              Ctrl+D        詳細リスト表示
              Ctrl+F        フォルダフィルターにフォーカス

            【マーク】
              Alt+M         選択アイテムのマークをトグル（緑でハイライト）
              Ctrl+M        マーク済みアイテムのみ表示 / 全体に戻す
              Alt+Shift+M   全マーク解除

            【タブ】
              Ctrl+T        新規タブ（現在のルートで開く）
              Ctrl+W        現在のタブを閉じる
              Ctrl+Tab      次のタブへ
              Ctrl+Shift+Tab 前のタブへ
              Ctrl+1-5      タブ直接切り替え
              Alt+←         タブ内でルート履歴を戻る
              Alt+→         タブ内でルート履歴を進む
              Ctrl+Shift+H  現在タブの履歴をクリア

            【その他】
              Ctrl+P        ピン留めトグル
              F1            このヘルプを表示
        )"

    MsgBox(helpText, "Navi ショートカット", "Iconi 4096")
    }

    static _ExecuteAction(key, path) {
        k := StrLower(key)
        if (this.Actions.Has(k)) {
            fn := this.Actions[k].run
            ; 関数オブジェクトをプロパティから呼ぶ場合は .Call() を使用
            try {
                fn.Call(path)
            } catch as e {
                ToolTip("Action error: " . e.Message)
                SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            }
        } else {
            ToolTip("未定義のアクション: " . key)
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
        }
    }

    static _ShowEditGui(parentGui) {
        parentGui.GetPos(&px, &py, &pw, &ph)
        parentGui.Opt("+Disabled")
        editGui := Gui("+Owner" . parentGui.Hwnd . " +AlwaysOnTop -MinimizeBox +Resize", "ルートディレクトリ編集")
        editGui.SetFont("s10", "Yu Gothic UI")
        ; --- プロファイル管理 GroupBox（最上部）---
        profBox := editGui.Add("GroupBox", "xm w550 h54", "プロファイル管理")
        profNames := this._GetProfileList()
        profDDL := editGui.Add("DropDownList", "xm+10 yp+20 w200 vEditProfileDDL", profNames)
        if (profNames.Length > 0) {
            currentP := IniRead(this.IniPath, "Settings", "LastProfile", "")
            currentN := (currentP != "") ? RegExReplace(RegExReplace(currentP, ".*\\", ""), "\.txt$", "") : ""
            chosen := 1
            for i, n in profNames {
                if (n = currentN) {
                    chosen := i
                    break
                }
            }
            profDDL.Choose(chosen)
        }
        btnProfNew := editGui.Add("Button", "x+6 yp w50 h22 -Tabstop", "新規")
        btnProfDup := editGui.Add("Button", "x+4 yp w50 h22 -Tabstop", "複製")
        btnProfDel := editGui.Add("Button", "x+4 yp w50 h22 -Tabstop", "削除")
        btnProfRen := editGui.Add("Button", "x+4 yp w70 h22 -Tabstop", "名前変更")
        ; --- ルートリスト ---
        lv := editGui.Add("ListView", "xm y+22 r15 w550 Grid Multi vFolderList", ["名称", "パス", "表示"])
        lv.ModifyCol(1, 120), lv.ModifyCol(2, 350), lv.ModifyCol(3, 50)
        this._LoadLVFolders(lv)
        btnAdd := editGui.Add("Button", "xm w70", "追加"), btnMod := editGui.Add("Button", "x+5 w70", "修正"), btnDel :=
            editGui.Add("Button", "x+5 w70", "削除")
        btnUp := editGui.Add("Button", "x+20 w40", "↑"), btnDown := editGui.Add("Button", "x+5 w40", "↓")
        btnSave := editGui.Add("Button", "xm+440 y+6 w110 Default", "保存")
        btnAdd.OnEvent("Click", (*) => this._ShowEntryGui(editGui, lv)), btnMod.OnEvent("Click", (*) => this._ShowEntryGui(
            editGui, lv, lv.GetNext())), btnDel.OnEvent("Click", (*) => this._DeleteItem(lv, editGui))
        btnUp.OnEvent("Click", (*) => this._MoveItem(lv, -1)), btnDown.OnEvent("Click", (*) => this._MoveItem(lv, 1))
        btnSave.OnEvent("Click", (*) => this._SaveList(lv, editGui, parentGui))
        profDDL.OnEvent("Change", (*) => this._LoadProfileIntoLV(lv, editGui["EditProfileDDL"].Text))
        btnProfNew.OnEvent("Click", (*) => this._NewProfileDialogFromEdit(editGui))
        btnProfDup.OnEvent("Click", (*) => this._DupProfileDialogFromEdit(editGui, lv))
        btnProfDel.OnEvent("Click", (*) => this._DeleteProfileFromEdit(editGui))
        btnProfRen.OnEvent("Click", (*) => this._RenameProfileFromEdit(editGui))
        lv.OnEvent("Click", (_, row) => (row > 0) ? this._ToggleVisibleOnClick(lv, row) : 0)
        lv.OnEvent("DoubleClick", (_, info) => (info && !this._IsVisibleColClick(lv)) ? this._ShowEntryGui(editGui, lv, info) : 0)

        editGui.OnEvent("Close", (*) => this._CleanupEditGui(parentGui, editGui))
        HotIfWinActive("ahk_id " editGui.Hwnd)
        Hotkey("Esc", (*) => this._CleanupEditGui(parentGui, editGui), "On")
        HotIf()
        editGui.Show("Hide")
        editGui.GetPos(, , &initW, &initH)
        lv.GetPos(, , &initLvW, &initLvH)
        btnSave.GetPos(&initBtnSaveX, &initBtnSaveY)

        ; パス列をLV幅いっぱいに伸ばす（内側クライアント幅から固定列を除いた残り）
        rc := Buffer(16, 0)
        DllCall("user32\GetClientRect", "ptr", lv.Hwnd, "ptr", rc)
        lvClientW    := NumGet(rc, 8, "int")
        initPathColW := lvClientW - 120 - 50
        lv.ModifyCol(2, initPathColW)
        profBox.GetPos(,, &initProfBoxW)

        ; 垂直移動が必要なコントロールの初期 Y を収集（LV下のボタン行のみ）
        vertCtrls := [btnAdd, btnMod, btnDel, btnUp, btnDown]
        vertY := []
        for ctrl in vertCtrls {
            ctrl.GetPos(, &cy)
            vertY.Push(cy)
        }

        editGui.OnEvent("Size", _OnEditSize)
        _OnEditSize(_, minMax, w, h) {
            if (minMax == -1)
                return
            dw := w - initW, dh := h - initH
            lv.Move(, , initLvW + dw, initLvH + dh)
            lv.ModifyCol(2, initPathColW + dw)
            btnSave.Move(initBtnSaveX + dw, initBtnSaveY + dh)
            profBox.Move(,, initProfBoxW + dw)
            for i, ctrl in vertCtrls
                ctrl.Move(, vertY[i] + dh)
        }

        editGui.Show("x" . px + (pw - initW) // 2 . " y" . py + (ph - initH) // 2)
    }

    static _ShowSettingsGui(parentGui) {
        parentGui.GetPos(&px, &py, &pw, &ph)
        parentGui.Opt("+Disabled")
        settGui := Gui("+Owner" . parentGui.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", "Navi 設定")
        settGui.SetFont("s10", "Yu Gothic UI")

        settGui.Add("Text", "xm", "動作")
        autoMinCb := settGui.Add("CheckBox", "xm y+6", "アクション実行後に自動最小化する（ピン留めON時は無効）")
        autoMinCb.Value := (IniRead(this.IniPath, "Settings", "AutoMinimizeOnAction", "0") == "1") ? 1 : 0
        autoMinCb.OnEvent("Click", (*) => IniWrite(autoMinCb.Value, this.IniPath, "Settings", "AutoMinimizeOnAction"))

        settGui.Add("Text", "xm y+12 w380 0x10")  ; 区切り線
        settGui.Add("Text", "xm y+8", "フォルダフィルター")
        fdFilterCb := settGui.Add("CheckBox", "xm y+6", "フォルダフィルターを高速化する（fd.exe が必要）")
        fdFilterCb.Value := (IniRead(this.IniPath, "Search", "UseFdForFilter", "1") != "0") ? 1 : 0
        fdFilterCb.OnEvent("Click", (*) => IniWrite(fdFilterCb.Value, this.IniPath, "Search", "UseFdForFilter"))

        _close := (*) => (settGui.Destroy(), parentGui.Opt("-Disabled +AlwaysOnTop"), parentGui.Show())
        settGui.OnEvent("Close", _close)
        HotIfWinActive("ahk_id " settGui.Hwnd)
        Hotkey("Esc", _close, "On")
        HotIf()
        settGui.Show("Hide")
        settGui.GetPos(, , &sw, &sh)
        settGui.Show("x" . px + (pw - sw) // 2 . " y" . py + (ph - sh) // 2)
    }

    static _ShowEntryGui(editGui, lv, row := 0) {
        editGui.GetPos(&ex, &ey, &ew, &eh), editGui.Opt("+Disabled")
        entryGui := Gui("+Owner" . editGui.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", row ? "項目の修正" : "項目の追加")
        entryGui.SetFont("s10", "Yu Gothic UI")
        entryGui.Add("Text", "xm", "名称:"), nameEdit := entryGui.Add("Edit", "xm w400 vName", row ? lv.GetText(row, 1) :
            "")
        entryGui.Add("Text", "xm", "パス:"), pathEdit := entryGui.Add("Edit", "xm w350 vPath", row ? lv.GetText(row, 2) :
            "")
        btnBrowse := entryGui.Add("Button", "x+5 yp w45 h26", "..."), btnBrowse.OnEvent("Click", (*) => this._HandleDirSelect(
            entryGui, pathEdit))
        entryGui.Add("Checkbox", "xm vVisible", "プルダウンに表示する").Value := (row == 0 || lv.GetText(row, 3) == "○") ? 1 : 0
        btnOK := entryGui.Add("Button", "xm w100 Default", "OK"), btnOK.OnEvent("Click", (*) => this._ProcessEntry(
            editGui, entryGui, lv, row))
        entryGui.OnEvent("Close", (*) => this._CloseEntry(editGui, entryGui))
        entryGui.Show("Hide"), entryGui.GetPos(, , &nw, &nh)
        entryGui.Show("x" . ex + (ew - nw) // 2 . " y" . ey + (eh - nh) // 2)
    }

    static _GetMonitorFromPos(x, y) {
        loop MonitorGetCount() {
            MonitorGet(A_Index, &L, &T, &R, &B)
            if (x >= L && x <= R && y >= T && y <= B) {
                return A_Index
            }
        }
        return MonitorGetPrimary()
    }

    static _EnsureInScreen(&x, &y, w, h) {
        loop MonitorGetCount() {
            MonitorGetWorkArea(A_Index, &left, &top, &right, &bottom)
            if (x >= left && x <= right && y >= top && y <= bottom) {
                if (x + w > right)
                    x := right - w - this.SCREEN_MARGIN
                if (y + h > bottom)
                    y := bottom - h - this.SCREEN_MARGIN
                if (y < top)
                    y := top + this.SCREEN_MARGIN
                return
            }
        }
    }

    static _HandleDirSelect(gui, edit) {
        gui.Opt("+OwnDialogs")
        sel := DirSelect("*" . edit.Value, 3)
        if (sel != "") {
            edit.Value := sel
        }
    }

    static _LoadLVFolders(lv) {
        try {
            content := IniRead(this.IniPath, "Folders")
            for line in StrSplit(content, "`n") {
                if (InStr(line, "=")) {
                    p := StrSplit(line, "=", , 2), vParts := StrSplit(p[2], "|")
                    isVisible := (vParts.Length > 1 && vParts[2] == "0") ? "×" : "○"
                    lv.Add(, Trim(p[1]), vParts[1], isVisible)
                }
            }
        }
    }

    static _MoveItem(lv, direction) {
        row := lv.GetNext()
        if (row == 0) {
            return
        }
        target := row + direction
        if (target < 1 || target > lv.GetCount()) {
            return
        }
        n1 := lv.GetText(row, 1), p1 := lv.GetText(row, 2), v1 := lv.GetText(row, 3)
        n2 := lv.GetText(target, 1), p2 := lv.GetText(target, 2), v2 := lv.GetText(target, 3)
        lv.Modify(row, , n2, p2, v2), lv.Modify(target, , n1, p1, v1)
        lv.Modify(row, "-Select"), lv.Modify(target, "Select Focus")
    }

    static _GetClickSubItem(lv) {
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "ptr", pt)
        DllCall("user32\ScreenToClient", "ptr", lv.Hwnd, "ptr", pt)
        hti := Buffer(24, 0)
        NumPut("int", NumGet(pt, 0, "int"), hti, 0)
        NumPut("int", NumGet(pt, 4, "int"), hti, 4)
        SendMessage(0x1039, 0, hti, lv)  ; LVM_SUBITEMHITTEST
        return NumGet(hti, 16, "int")    ; iSubItem（0始まり）
    }

    static _ToggleVisibleOnClick(lv, row) {
        if (this._GetClickSubItem(lv) == 2)  ; 表示列（0始まり）
            lv.Modify(row, , , , (lv.GetText(row, 3) == "○") ? "×" : "○")
    }

    static _IsVisibleColClick(lv) {
        return this._GetClickSubItem(lv) == 2
    }

    static _ProcessEntry(editGui, entryGui, lv, row) {
        val := entryGui.Submit(false)
        if (val.Name == "" || val.Path == "") {
            return
        }
        visText := val.Visible ? "○" : "×"
        if (row == 0) {
            lv.Add(, val.Name, val.Path, visText)
        }
        else {
            lv.Modify(row, , val.Name, val.Path, visText)
        }
        this._CloseEntry(editGui, entryGui)
    }

    static _DeleteItem(lv, editGui) {
        ; すべての選択行を取得
        selected := []
        r := 0
        while (r := lv.GetNext(r)) {
            selected.Push(r)
        }
        if (selected.Length > 0) {
            editGui.Opt("+OwnDialogs")
            msg := (selected.Length = 1)
                ? "選択した項目を削除しますか？"
                : selected.Length . " 件の項目を削除しますか？"
            if (MsgBox(msg, "削除確認", "YesNo Icon? 4096") == "Yes") {
                ; 下から削除してインデックスずれを防ぐ
                for i, _ in selected {
                    lv.Delete(selected[selected.Length - i + 1])
                }
            }
        }
    }

    static _CloseEntry(editGui, entryGui) {
        entryGui.Destroy(), editGui.Opt("-Disabled +AlwaysOnTop"), editGui.Show()
    }

    static _CleanupEditGui(parentGui, editGui) {
        editGui.Destroy(), parentGui.Opt("-Disabled +AlwaysOnTop"), parentGui.Show()
    }

    static _SaveList(lv, editGui := "", parentGui := "") {
        IniDelete(this.IniPath, "Folders")
        loop lv.GetCount() {
            name := lv.GetText(A_Index, 1), path := lv.GetText(A_Index, 2)
            visible := (lv.GetText(A_Index, 3) == "○") ? "1" : "0"
            IniWrite(path . "|" . visible, this.IniPath, "Folders", name)
        }
        ; プロファイルが設定されている場合は自動的にファイルへ書き出す
        lastProfile := IniRead(this.IniPath, "Settings", "LastProfile", "")
        if (lastProfile != "")
            this._WriteProfileFile(lv, lastProfile)
        ; GUI が開いていればインプレース更新、なければ再起動
        if (this.GuiObj && WinExist(this.GuiObj)) {
            if (editGui != "")
                this._CleanupEditGui(parentGui, editGui)
            this._ReloadProfileInPlace()
        } else {
            Reload()
        }
    }

    static _LoadFolders(folderMap, folderNames) {
        raw := ""
        try {
            raw := IniRead(this.IniPath, "Folders")
        } catch {
            ; Folders セクションが未作成の場合はデフォルトにフォールバック
        }
        for line in StrSplit(raw, "`n", "`r") {
            line := Trim(line)
            if (line == "" || !InStr(line, "="))
                continue
            p := StrSplit(line, "=", , 2)
            if (p.Length < 2)
                continue
            name := Trim(p[1])
            if (name == "")
                continue
            vParts := StrSplit(Trim(p[2]), "|")
            path := vParts[1]
            isVisible := (vParts.Length > 1) ? Trim(vParts[2]) : "1"
            folderMap[name] := path
            if (isVisible == "1")
                folderNames.Push(name)
        }
        if (folderNames.Length == 0 && folderMap.Count == 0) {
            folderNames.Push("Desktop"), folderMap["Desktop"] := A_Desktop
        }
    }

    static _EnsureDefaultFolders() {
        try {
            if (IniRead(this.IniPath, "Folders", , "") == "") {
                IniWrite(A_Desktop . "|1", this.IniPath, "Folders", "Desktop")
            }
        } catch {
            IniWrite(A_Desktop . "|1", this.IniPath, "Folders", "Desktop")
        }
    }

    static _LoadConfig() {
        path := ""
        if (FileExist(this.IniPath)) {
            path := IniRead(this.IniPath, "Settings", "ExplorerPath", "")
        }
        if (path == "" || (path != "explorer.exe" && !FileExist(path))) {
            msg := "ファイラーを設定してください。`n[はい] 外部ファイラー / [いいえ] 標準エクスプローラー"
            if (MsgBox(msg, "Navi - 初期設定", "YesNo Icon? 4096") == "Yes") {
                sel := FileSelect(3, , "exeを選択", "(*.exe)"), path := (sel != "") ? sel : "explorer.exe"
            } else {
                path := "explorer.exe"
            }
            IniWrite(path, this.IniPath, "Settings", "ExplorerPath")
        }
        return path
    }

    /**
     * TreeView にシェルアイコン（フォルダ/ファイル）を設定する
     * SHGetStockIconInfo でストックアイコンを取得（ファイル関連付けに左右されない）
     * ImageList[0]=フォルダ → "Icon1"、ImageList[1]=ファイル → "Icon2"
     */
    static _SetupTreeIcons(tv) {
        SHGSI_ICON      := 0x100
        SHGSI_SMALLICON := 0x1
        SIID_DOCNOASSOC  := 0   ; 汎用ファイルアイコン（関連付けなし）
        SIID_FOLDER      := 3   ; 標準フォルダアイコン
        SIID_FOLDEROPEN  := 4   ; 開いたフォルダ（ハイライトフォルダ用）
        SIID_FIND        := 22  ; 検索アイコン（ハイライトファイル用）

        ; SHSTOCKICONINFO: cbSize(4) [+4 pad on 64bit] + hIcon(ptr) + iSysImageIndex(4) + iIcon(4) + szPath(MAX_PATH*2)
        ; 64bit: 4+4pad+8+4+4+520=544 / 32bit: 4+4+4+4+520=536
        sii_size     := (A_PtrSize = 8) ? 544 : 536
        hIcon_offset := A_PtrSize  ; 64bit=8(cbSize+padding), 32bit=4(cbSize)

        ; Icon1=フォルダ, Icon2=汎用ファイル, Icon3=ハイライトフォルダ, Icon4=ハイライトファイル
        ; Icon5以降: 拡張子別アイコンを動的追加（初期32スロット、不足時32ずつ拡張）
        hIL := IL_Create(32, 32)
        this._IconCache := Map()
        this._ILNextIdx := 5

        _AddIcon(siid) {
            sii := Buffer(sii_size, 0)
            NumPut("uint", sii_size, sii, 0)
            DllCall("shell32\SHGetStockIconInfo", "uint", siid,
                "uint", SHGSI_ICON | SHGSI_SMALLICON, "ptr", sii)
            hIcon := NumGet(sii, hIcon_offset, "ptr")
            DllCall("comctl32\ImageList_AddIcon", "ptr", hIL, "ptr", hIcon)
            DllCall("user32\DestroyIcon", "ptr", hIcon)
        }

        _AddIcon(SIID_FOLDER)      ; Icon1
        _AddIcon(SIID_DOCNOASSOC)  ; Icon2
        _AddIcon(SIID_FOLDEROPEN)  ; Icon3 ハイライトフォルダ
        _AddIcon(SIID_FIND)        ; Icon4 ハイライトファイル

        tv.SetImageList(hIL)
        this._ILHandle := hIL
    }

    /**
     * ファイル名から TreeView 用アイコン文字列を返す（例: "Icon5"）
     * SHGetFileInfoW + SHGFI_USEFILEATTRIBUTES で拡張子からシェルアイコンを取得し、
     * ImageList に追加してキャッシュする。ディスクアクセスなし。
     */
    static _GetFileIconStr(fileName) {
        dotPos := InStr(fileName, ".", , -1)
        ext := dotPos ? StrLower(SubStr(fileName, dotPos)) : ""
        if (ext == "" || ext == ".")
            return "Icon2"
        if this._IconCache.Has(ext)
            return "Icon" . this._IconCache[ext]

        sfi_size := A_PtrSize + 4 + 4 + 520 + 160  ; hIcon + iIcon + dwAttributes + szDisplayName + szTypeName
        sfi := Buffer(sfi_size, 0)
        DllCall("shell32\SHGetFileInfoW",
            "wstr", "file" . ext,
            "uint", 0x80,           ; FILE_ATTRIBUTE_NORMAL
            "ptr",  sfi,
            "uint", sfi_size,
            "uint", 0x111)          ; SHGFI_ICON | SHGFI_SMALLICON | SHGFI_USEFILEATTRIBUTES
        hIcon := NumGet(sfi, 0, "ptr")
        if (hIcon == 0) {
            this._IconCache[ext] := 2
            return "Icon2"
        }
        DllCall("comctl32\ImageList_AddIcon", "ptr", this._ILHandle, "ptr", hIcon)
        DllCall("user32\DestroyIcon", "ptr", hIcon)
        idx := this._ILNextIdx++
        this._IconCache[ext] := idx
        return "Icon" . idx
    }

    /**
     * ルート配下のフォルダパスを同期的にキャッシュする（fd が使えない場合のフォールバック）
     */
    static _BuildFolderIndex(rootPath) {
        this._FolderIndex := []
        this._IndexedRoot := ""
        try {
            loop files, rootPath . "\*", "DR" {
                if (SubStr(A_LoopFileName, 1, 1) == "." || InStr(A_LoopFileAttrib, "H"))
                    continue
                this._FolderIndex.Push(A_LoopFilePath)
            }
        }
        this._IndexedRoot := rootPath
    }

    /**
     * fd.exe でフォルダ一覧を非同期列挙開始する
     * fd プロセスを起動してすぐ返る。完了は _PollFdIndex が検出する。
     * 戻り値: 成功=true、失敗=false（呼び出し元が _BuildFolderIndex にフォールバックする）
     */
    static _StartFolderIndexFd(rootPath, fdPath) {
        ; 既存の fd プロセスがあればキャンセル
        if (this._FdIndexPid != 0) {
            try ProcessClose(this._FdIndexPid)
            try FileDelete(this._FdIndexFile)
            this._FdIndexPid := 0
        }
        if (this._FdPollCb != "")
            SetTimer(this._FdPollCb, 0)
        tmpFile := A_Temp . "\navi_fidx_" . A_TickCount . ".txt"
        ; 末尾 \ をエスケープ（C ランタイムの \" 解析対策）
        safeRoot := (SubStr(rootPath, -1) = "\") ? rootPath . "\" : rootPath
        cmd := '"' . fdPath . '" --type d --no-ignore-vcs --color never --absolute-path . "' . safeRoot . '"'
        pid := NaviSearch._RunNoWindowToFile(cmd, tmpFile)
        if (pid = 0)
            return false
        this._FdIndexPid  := pid
        this._FdIndexFile := tmpFile
        this._FdIndexRoot := rootPath
        cb := () => this._PollFdIndex()
        this._FdPollCb := cb
        SetTimer(cb, 200)
        return true
    }

    /**
     * fd インデックス構築完了をポーリングするタイマーコールバック
     * fd プロセス完了後に結果を読み込み、保留クエリがあれば _ApplyTreeFilter を呼ぶ
     */
    static _PollFdIndex() {
        if (this._FdIndexPid = 0 || ProcessExist(this._FdIndexPid)) {
            ; fd 実行中: ステータスバーにアニメーションドットを表示
            try {
            if (this.GuiObj && WinExist(this.GuiObj)) {
                static dots := [" .", " ..", " ..."]
                static frame := 0
                frame := Mod(frame, 3) + 1
                this.GuiObj._sbRef.SetText(" インデックス構築中" . dots[frame])
            }
        }
            return
        }
        ; 完了: タイマーを停止
        SetTimer(this._FdPollCb, 0)
        this._FdPollCb := ""
        this._FdIndexPid := 0
        ; 結果を読み込んでインデックスを構築（Loop Read で行単位処理: 大ファイル対策）
        this._FolderIndex := []
        try {
            loop read, this._FdIndexFile {
                p := Trim(A_LoopReadLine)
                if (p = "")
                    continue
                if (SubStr(p, -1) = "\" && StrLen(p) > 3)
                    p := SubStr(p, 1, -1)
                SplitPath(p, &fname)
                if (SubStr(fname, 1, 1) != ".")
                    this._FolderIndex.Push(p)
            }
        }
        try FileDelete(this._FdIndexFile)
        this._FdIndexFile := ""
        this._IndexedRoot := this._FdIndexRoot
        this._FdIndexRoot := ""
        ; ステータスバーを通常表示に戻す
        this._UpdateStatusBar()
        ; 保留コールバックがあれば実行（フィルタ再適用など）
        if (this._OnIndexReadyCb != "") {
            cb := this._OnIndexReadyCb
            this._OnIndexReadyCb := ""
            SetTimer(cb, -1)
        }
    }

    /**
     * fd プロセスと関連状態をすべてリセットする
     * ルート切り替え時や初期化時に呼ぶ
     */
    static _CancelFdIndex() {
        if (this._FdIndexPid != 0) {
            try ProcessClose(this._FdIndexPid)
            try FileDelete(this._FdIndexFile)
            this._FdIndexPid  := 0
            this._FdIndexFile := ""
            this._FdIndexRoot := ""
        }
        if (this._FdPollCb != "")
            SetTimer(this._FdPollCb, 0)
        this._FdPollCb      := ""
        this._OnIndexReadyCb := ""
    }

    /**
     * rootPath のフォルダインデックスを確保する
     * - 既に準備済み → true を返す（インデックス利用可能）
     * - fd 非同期構築中/開始 → onReady を完了後コールバックに登録して false を返す
     * - fd が使えない場合 → 同期構築して true を返す
     */
    static _EnsureIndex(rootPath, onReady) {
        if (this._IndexedRoot == rootPath)
            return true
        if (this._FdIndexPid != 0 && this._FdIndexRoot == rootPath) {
            ; 同じルートの fd 非同期構築が進行中: コールバックを保留
            this._OnIndexReadyCb := onReady
            return false
        }
        useFd := (IniRead(NaviSearch.IniPath, "Search", "UseFdForFilter", "1") != "0")
        fdPath := useFd ? NaviSearch._FindFd() : ""
        if (fdPath != "" && this._StartFolderIndexFd(rootPath, fdPath)) {
            ; fd 非同期開始: 完了時に _PollFdIndex がコールバックを実行する
            this._OnIndexReadyCb := onReady
            return false
        }
        ; フォールバック: 同期 loop files（fd が使えない場合）
        this._BuildFolderIndex(rootPath)
        return true
    }

    /**
     * フォルダインデックスを先読み構築する（_RefreshTree の 800ms タイマーから呼ばれる）
     * fd が使えれば非同期で、なければ同期フォールバック
     */
    static _PrefetchFolderIndex(rootPath) {
        if (this._IndexedRoot == rootPath || (this._FdIndexPid != 0 && this._FdIndexRoot == rootPath))
            return  ; 既に準備済みか構築中
        this._EnsureIndex(rootPath, () => "")
    }

    /**
     * ツリーフィルター入力変更: 300ms デバウンスで _ApplyTreeFilter を呼ぶ
     */
    static _OnTreeFilterChange() {
        if (this._SearchMode)
            return  ; 検索モード中はリアルタイムフィルターをスキップ
        if (this._treeFilterCallback != "")
            SetTimer(this._treeFilterCallback, 0)
        query := this.GuiObj["TreeFilter"].Value
        cb := () => this._ApplyTreeFilter(query)
        this._treeFilterCallback := cb
        SetTimer(cb, -300)
    }

    /**
     * ツリーフィルター適用: query が空なら通常ツリーに戻す、あれば再帰検索してツリー再構築
     * 再入防止: ファイル列挙 loop files のイテレーション間にタイマーが割り込む場合があるため
     * _FilterRunning フラグで二重実行を防ぎ、最新クエリを _FilterPending に保留して処理する
     */
    static _ApplyTreeFilter(query) {
        this._treeFilterCallback := ""
        this._FilterCancelled := false  ; 新しいフィルタ要求でキャンセルフラグをリセット
        ; 再入防止: 実行中なら最新クエリを保留して即リターン
        if (this._FilterRunning) {
            this._FilterPending    := query
            this._FilterPendingSet := true   ; "" もクリア操作として区別できるようにフラグで管理
            return
        }
        this._FilterRunning    := true
        this._FilterPendingSet := false
        this._FilterPending    := ""
        try {
            if !(this.GuiObj && WinExist(this.GuiObj))
                return
            tv := this.GuiObj["FolderTree"]
            rootPath := this._FolderMap.Has(this.lastRoot) ? this._FolderMap[this.lastRoot] : ""
            if (rootPath == "")
                return
            if (Trim(query) == "") {
                this._FilterMatchIdSet := Map()
                ; フィルタクリア時は fd 完了後の再適用を防ぐため保留コールバックをリセット
                this._OnIndexReadyCb := ""
                this._RefreshTree(tv, rootPath, false)
                return
            }
            ; スペース区切り=AND、"|"区切り=OR でターム分割
            terms := []
            for t in StrSplit(query, " ") {
                if (Trim(t) != "")
                    terms.Push(StrSplit(Trim(t), "|"))  ; 各要素は OR 候補の配列
            }
            ; キャッシュが古ければ再構築
            if (this._IndexedRoot != rootPath) {
                ; fd 完了後コールバック: フィルタを再スケジュール（_FilterPendingSet は return 前にリセット済み）
                onReady := () => SetTimer(() => this._ApplyTreeFilter(query), -1)
                if !this._EnsureIndex(rootPath, onReady) {
                    ; fd 非同期待ち: 完了後に _OnIndexReadyCb が再実行する
                    this._FilterPendingSet := false
                    return
                }
            }
            ; キャッシュからメモリ内検索（スペース=AND、"|"=OR）
            ; 最後のタームはフォルダ名にマッチ、それ以前のタームはパス全体にマッチ
            ; 例: "myapp src" → パスに "myapp" を含み、かつフォルダ名に "src" を含む
            lastTermIdx := terms.Length
            results := []
            for fullPath in this._FolderIndex {
                SplitPath(fullPath, &fname)
                matched := true
                for tIdx, orGroup in terms {
                    target := (tIdx = lastTermIdx) ? fname : fullPath
                    groupMatched := false
                    for alt in orGroup {
                        if (alt != "" && InStr(target, alt, false)) {
                            groupMatched := true
                            break
                        }
                    }
                    if !groupMatched {
                        matched := false
                        break
                    }
                }
                if matched
                    results.Push(fullPath)
            }
            ; ツリー再構築（ノードIDが再利用されるため検索ハイライトの古いIDをリセット）
            tv.Delete()
            this.FilesShown := Map()
            this._FilterMatchIdSet := Map()
            this._MarkFilterActive := false
            NaviSearch._HighlightedIdSet := Map()
            if (results.Length == 0) {
                tv.Add("(一致なし)", 0)
                return
            }
            ; 結果件数が多すぎると tv.Add ループが GUI を長時間ブロックするためキャップする
            static filterResultCap := 300
            tooMany := results.Length > filterResultCap
            if (tooMany)
                results.Length := filterResultCap
            ; rootPath 末尾の \ を除去（C:\ など末尾 \ があると currentPath 構築時に
            ; ダブルスラッシュ・StrLen オフセット誤りが起きるため正規化する）
            rootBase := RTrim(rootPath, "\")
            rootID := tv.Add(rootPath, 0, "Expand Icon1")
            if (tooMany)
                tv.Add("… 上位 " . filterResultCap . " 件を表示（キーワードを追加して絞り込んでください）", rootID)
            addedPaths := Map()
            addedPaths[StrLower(rootBase)] := rootID
            firstMatch := true
            for idx, fullPath in results {
                if (this._FilterCancelled)
                    return
                rel := SubStr(fullPath, StrLen(rootBase) + 2)
                parts := StrSplit(rel, "\")
                parentID := rootID
                currentPath := rootBase
                for i, part in parts {
                    currentPath .= "\" . part
                    key := StrLower(currentPath)
                    isMatch := (i == parts.Length)
                    if addedPaths.Has(key) {
                        existingID := addedPaths[key]
                        ; 既存ノードが今回の結果ではマッチノードになる場合は着色対象に追加
                        if (isMatch && !this._FilterMatchIdSet.Has(existingID))
                            this._FilterMatchIdSet[existingID] := true
                        parentID := existingID
                    } else {
                        opts := isMatch ? "Bold" : ""  ; "Expand" は子追加前に無効なため後処理で行う
                        if (isMatch && firstMatch) {
                            opts .= " Select"
                            firstMatch := false
                        }
                        nodeID := tv.Add(part, parentID, opts . " Icon1")
                        if (isMatch)
                            this._FilterMatchIdSet[nodeID] := true  ; カスタムドロー着色用
                        addedPaths[key] := nodeID
                        parentID := nodeID
                    }
                }
                ; 50件ごとに GUI イベントを処理してUIの応答性を保つ
                if (Mod(idx, 50) = 0)
                    Sleep(0)
            }
            ; 子を持つノードを展開（Add 時点では子がないため "Expand" オプションが無効のため後処理）
            for _, nodeID in addedPaths {
                if (nodeID != rootID && tv.GetChild(nodeID) != 0)
                    tv.Modify(nodeID, "Expand")
            }
            this._EnsureFilterDraw(tv)
            ; ファイル表示モードがONならフィルタ結果の各フォルダにもファイルを表示
            if (this.GuiObj["AutoFilesCheck"].Value) {
                fileMax := 200
                try fileMax := Integer(IniRead(this.IniPath, "Settings", "FileMax", "200"))
                rootKey := StrLower(rootBase)
                folderCount := 0
                for folderKey, nodeID in addedPaths {
                    if (this._FilterCancelled)
                        return
                    if (folderKey == rootKey)
                        continue
                    shown := []
                    count := 0
                    try {
                        loop files, folderKey . "\*", "F" {
                            if InStr(A_LoopFileAttrib, "H")
                                continue
                            shown.Push(tv.Add(A_LoopFileName, nodeID, this._GetFileIconStr(A_LoopFileName)))
                            if (++count >= fileMax)
                                break
                        }
                    }  ; catch なし: 例外は外側 finally でクリーンアップ
                    if (shown.Length > 0)
                        this.FilesShown[nodeID] := shown
                    ; 20フォルダごとに GUI イベントを処理
                    if (++folderCount >= 20) {
                        folderCount := 0
                        Sleep(0)
                    }
                }
            }
            ; フィルタ結果の上にマーク色を復元
            this._RebuildMarkedIdSet(tv)
        } catch Any {
            ; GUI 破棄など想定内の例外は無視して finally でクリーンアップ
        } finally {
            this._FilterRunning := false
            ; 保留クエリがあれば次のイベントループで処理（"" もクリア操作として正しく処理）
            if (this._FilterPendingSet) {
                pending := this._FilterPending
                this._FilterPending    := ""
                this._FilterPendingSet := false
                SetTimer(() => this._ApplyTreeFilter(pending), -1)
            }
        }
    }

    ; フィルタマッチ着色カスタムドロー登録（初回のみ）
    static _EnsureFilterDraw(tv) {
        this._FilterTvHwnd := tv.Hwnd
        if (this._FilterDrawHandler != "")
            return
        handler := (w, l, m, h) => Navi._OnFilterNotify(w, l, m, h)
        OnMessage(this.WM_NOTIFY, handler)
        this._FilterDrawHandler := handler
    }

    ; WM_NOTIFY → NM_CUSTOMDRAW ハンドラー（フィルタマッチノードの着色）
    ; NaviSearch の検索ハイライトハンドラーと共存: マッチ無しは "" を返し次のハンドラーへ委譲
    static _OnFilterNotify(wParam, lParam, msg, hwnd) {
        if (NumGet(lParam, 0, "ptr") != Navi._FilterTvHwnd)
            return
        if (NumGet(lParam, A_PtrSize * 2, "int") != -12)  ; NM_CUSTOMDRAW
            return
        stageOff := (A_PtrSize = 8) ? 24 : 12
        stage    := NumGet(lParam, stageOff, "uint")
        if (stage = 0x1) {  ; CDDS_PREPAINT
            ; マッチまたはマーク済みノードがあれば CDRF_NOTIFYITEMDRAW を返す
            return (Navi._FilterMatchIdSet.Count > 0 || Navi._MarkedIdSet.Count > 0) ? 0x20 : ""
        }
        if (stage = 0x10001) {  ; CDDS_ITEMPREPAINT
            specOff := (A_PtrSize = 8) ? 56 : 36
            itemId  := NumGet(lParam, specOff, "ptr")
            clrOff  := (A_PtrSize = 8) ? 80 : 48
            ; マーク色はフィルタマッチ色より優先
            if (Navi._MarkedIdSet.Has(itemId)) {
                NumPut("uint", Navi.MARK_COLOR, lParam, clrOff)
                return 0
            }
            if (Navi._FilterMatchIdSet.Has(itemId)) {
                NumPut("uint", Navi.FILTER_MATCH_COLOR, lParam, clrOff)
                return 0
            }
        }
    }

    static _RefreshTree(tv, rootPath, setFocus := true) {
        ; ルートが変わった場合: 進行中の fd 構築とフィルタ処理をキャンセルして状態をリセット
        if ((this._IndexedRoot != "" && this._IndexedRoot != rootPath)
            || (this._FdIndexPid != 0 && this._FdIndexRoot != rootPath)) {
            this._CancelFdIndex()
            ; 実行中の _ApplyTreeFilter ループを次の Sleep(0) チェックで中止させる
            this._FilterCancelled  := true
            this._FilterRunning    := false
            this._FilterPendingSet := false
            this._FilterPending    := ""
            this._IndexedRoot      := ""
            this._FolderIndex      := []
        }
        tv.Delete()
        this.FilesShown := Map()  ; ノードIDが無効化されるためクリア
        this._MarkedIdSet      := Map()
        this._MarkFilterActive := false
        ; 別ルートへ切り替え時はマークをリセット
        if (rootPath != this._LastTreeRootPath) {
            this._MarkedPaths      := Map()
            this._LastTreeRootPath := rootPath
        }
        if (!DirExist(rootPath)) {
            return
        }
        rootID := tv.Add(rootPath, 0, "Expand Select Icon1")
        this._LoadSub(tv, rootPath, rootID)
        this._ShowFilesIfEnabled(tv, rootID, rootPath)
        ; ツリー再構築後にマークノードIDを復元
        this._RebuildMarkedIdSet(tv)
        if (setFocus)
            tv.Focus()
        ; ツリー描画完了後 800ms でインデックスを先読み構築（フィルタ初回遅延を隠す）
        if (this._indexBuildCallback != "")
            SetTimer(this._indexBuildCallback, 0)
        cb := () => this._PrefetchFolderIndex(rootPath)
        this._indexBuildCallback := cb
        SetTimer(cb, -800)
    }

    ; --- マーク / マークフィルター機能 ---

    static _ToggleMark() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        tv := this.GuiObj["FolderTree"]
        selId := tv.GetSelection()
        if (!selId)
            return
        path := this._GetTVFullPath(tv, selId)
        if (path == "")
            return
        key := StrLower(path)
        if (this._MarkedPaths.Has(key))
            this._MarkedPaths.Delete(key)
        else
            this._MarkedPaths[key] := path
        this._RebuildMarkedIdSet(tv)
        this._EnsureFilterDraw(tv)
        DllCall("user32\InvalidateRect", "ptr", tv.Hwnd, "ptr", 0, "int", 1)
    }

    static _ClearAllMarks() {
        if (this._MarkedPaths.Count == 0 || !(this.GuiObj && WinExist(this.GuiObj)))
            return
        this._MarkedPaths := Map()
        tv := this.GuiObj["FolderTree"]
        rootPath := this._FolderMap.Has(this.lastRoot) ? this._FolderMap[this.lastRoot] : ""
        if (this._MarkFilterActive && rootPath != "") {
            ; マークフィルタービューを終了して元のビューへ戻す
            this._MarkFilterActive := false
            query := Trim(this.GuiObj["TreeFilter"].Value)
            if (query != "")
                this._ApplyTreeFilter(query)
            else
                this._RefreshTree(tv, rootPath, false)
        } else {
            this._MarkedIdSet := Map()
            DllCall("user32\InvalidateRect", "ptr", tv.Hwnd, "ptr", 0, "int", 1)
        }
        this._UpdateStatusBar()
    }

    ; --- タブ機能 ---

    /**
     * タブNのクリック・ホットキー用クロージャを生成（ループ変数キャプチャ対策）
     */
    static _MakeTabHandler(n) {
        return (*) => this._SwitchToTab(n)
    }

    /**
     * タブダブルクリック: そのタブに切り替えてルート選択を開く
     */
    static _MakeTabDblClickHandler(n) {
        return (*) => (this._SwitchToTab(n), this._OpenDropdown())
    }


    /**
     * _AllFolderNames + _FolderMap からプロファイルファイルを書き出す
     * ドラッグ追加など ListView を介さずにメモリ上のマップから直接書き出す場合に使用する。
     * ListView を持つ編集 GUI 経由の書き出しは _WriteProfileFile(lv, outPath) を使う。
     */
    static _WriteProfileFileFromMap(outPath) {
        txt := ""
        for name in this._AllFolderNames
            if (this._FolderMap.Has(name))
                txt .= name . "=" . this._FolderMap[name] . "`n"
        try FileDelete(outPath)
        FileAppend(txt, outPath, "UTF-8")
    }

    /**
     * タブNのラベルを返す（下線がアクティブを示すため、ラベルはルート名のみ）
     */
    static _GetTabLabel(n) {
        if (n > this._TabCount)
            return ""
        root := (n == this._CurrentTab) ? this.lastRoot
              : (n <= this._Tabs.Length && this._Tabs[n] != "") ? this._Tabs[n].root : ""
        if (root == "")
            root := "New"
        ; 85px幅: 日本語全角7文字≈70px、ASCII14文字≈84px → 7文字超で切り詰め
        return (StrLen(root) > 7) ? SubStr(root, 1, 6) . ".." : root
    }

    /**
     * タブバーのラベルと下線インジケーター位置を更新
     * タブ数が1のときは非表示、2以上のときは表示する
     */
    static _UpdateTabBar() {
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
                "uint", this.WM_SETTEXT, "ptr", 0, "wstr", this._GetTabLabel(n))
        }
        if (this._TabULCtrl) {
            this._TabULCtrl.Visible := (this._TabCount > 1)
            margin := this.GuiObj.MarginX
            this._TabULCtrl.Move(margin + (this._CurrentTab - 1) * (this.TAB_WIDTH + 1))
        }
        ; タブ数変化に応じてタブバー表示/非表示を切り替え
        this._SetTabBarVisible(this._TabCount > 1)
    }

    /**
     * タブバーの表示/非表示を切り替え、他コントロールを上下にシフトする
     */
    static _SetTabBarVisible(show) {
        if !(this.GuiObj && WinExist(this.GuiObj))
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
            this.GuiObj["ProfileBtn"],  this.GuiObj["ProfileSep"],
            this.GuiObj["RootBtn"],
            this.GuiObj._btnEditCtrl,   this.GuiObj._btnSettingsCtrl,
            this.GuiObj["PinCheck"],    this.GuiObj["AutoFilesCheck"],
            this.GuiObj["Breadcrumb"],  this.GuiObj["FilterToggle"],
            this.GuiObj["SearchTypeBtn"], this.GuiObj["TreeFilter"],
            this.GuiObj["FolderTree"],
            this.GuiObj["QuickPath"]
        ]
        for ctrl in ctrls {
            ctrl.GetPos(, &cy)
            ctrl.Move(, cy + shift)
        }
        this._tvY += shift
    }

    /**
     * GUIから現在の表示状態を読み取って返す
     */
    static _GetLiveState() {
        marks := Map()
        for k, v in this._MarkedPaths
            marks[k] := v
        tv := this.GuiObj["FolderTree"]
        selPath := ""
        selId := tv.GetSelection()
        if (selId)
            try selPath := this._GetTVFullPath(tv, selId)
        return {
            root:       this.lastRoot,
            filter:     this.GuiObj["TreeFilter"].Value,
            marks:      marks,
            markFilter: this._MarkFilterActive,
            path:       selPath
        }
    }

    /**
     * 現在のタブに表示状態を保存
     */
    static _SaveCurrentTab() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        s := this._GetLiveState()
        while (this._Tabs.Length < this._CurrentTab)
            this._Tabs.Push({root: "", filter: "", marks: Map(), markFilter: false, path: "", history: [], future: []})
        tab := this._Tabs[this._CurrentTab]
        tab.root := s.root, tab.filter := s.filter, tab.marks := s.marks
        tab.markFilter := s.markFilter, tab.path := s.path
    }

    /**
     * 現在のルート操作前に呼ぶ: 現在の状態をタブ内履歴に積む（Alt+← で戻れる）
     */
    static _PushTabHistory() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        while (this._Tabs.Length < this._CurrentTab)
            this._Tabs.Push({root: "", filter: "", marks: Map(), markFilter: false, path: "", history: [], future: []})
        tab := this._Tabs[this._CurrentTab]
        s   := this._GetLiveState()
        tab.history.Push({root: s.root, filter: s.filter, marks: s.marks, markFilter: s.markFilter, path: s.path})
        if (tab.history.Length > this.TAB_HISTORY_MAX)
            tab.history.RemoveAt(1)
        tab.future := []
    }

    /**
     * 状態オブジェクトを TreeView に適用する共通ヘルパー
     */
    static _ApplyTabState(state, tv) {
        if (state.root != "" && this._FolderMap.Has(state.root) && state.root != this.lastRoot) {
            this.lastRoot := state.root
            this.GuiObj["RootBtn"].Text := this._TruncRootLabel(state.root)
        }
        rootPath := this._FolderMap.Has(this.lastRoot) ? this._FolderMap[this.lastRoot] : ""
        this.GuiObj["TreeFilter"].Value := state.filter
        if (state.markFilter && rootPath != "") {
            this._MarkedPaths      := state.marks
            this._MarkFilterActive := true
            this._ApplyMarkFilter(tv, rootPath)
        } else if (state.filter != "" && rootPath != "") {
            this._MarkFilterActive := false
            this._MarkedPaths      := state.marks
            this._ApplyTreeFilter(state.filter)
        } else if (rootPath != "") {
            this._MarkFilterActive := false
            this._RefreshTree(tv, rootPath, false)
            this._MarkedPaths := state.marks
            this._RebuildMarkedIdSet(tv)
            this._EnsureFilterDraw(tv)
            DllCall("user32\InvalidateRect", "ptr", tv.Hwnd, "ptr", 0, "int", 1)
        }
        if (state.path != "" && rootPath != "")
            this._FocusPath(tv, state.path)
    }

    /**
     * 現在のタブ状態を TreeView に復元する（Show() 初期化用）
     */
    static _RestoreCurrentTab(tv) {
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return false
        tab := this._Tabs[this._CurrentTab]
        if (tab.root == "" || !this._FolderMap.Has(tab.root))
            return false
        this._ApplyTabState(tab, tv)
        return true
    }

    /**
     * タブNに切り替える（現在の状態を保存してから復元）
     */
    static _SwitchToTab(n) {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        if (n < 1 || n > this._TabCount)
            return
        this._SaveCurrentTab()
        this._CurrentTab := n
        tv := this.GuiObj["FolderTree"]
        tab := (n <= this._Tabs.Length) ? this._Tabs[n] : ""
        if (tab == "" || tab.root == "") {
            this.GuiObj["TreeFilter"].Value := ""
            this._MarkFilterActive := false
            rootPath := this._FolderMap.Has(this.lastRoot) ? this._FolderMap[this.lastRoot] : ""
            if (rootPath != "")
                this._RefreshTree(tv, rootPath, false)
            this._MarkedPaths := Map()
            this._MarkedIdSet := Map()
        } else {
            this._ApplyTabState(tab, tv)
        }
        this._UpdateTabBar()
        this._UpdateStatusBar()
    }

    /**
     * 新しいタブを開く（Ctrl+T）: 現在のルートで初期化、フィルター・マークはクリア
     */
    static _NewTab() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        if (this._TabCount >= this.TAB_MAX)
            return
        this._SaveCurrentTab()
        this._TabCount++
        while (this._Tabs.Length < this._TabCount)
            this._Tabs.Push({root: "", filter: "", marks: Map(), markFilter: false, path: "", history: [], future: []})
        this._Tabs[this._TabCount] := {
            root: this.lastRoot, filter: "", marks: Map(),
            markFilter: false, path: "", history: [], future: []
        }
        this._CurrentTab := this._TabCount
        tv := this.GuiObj["FolderTree"]
        this.GuiObj["TreeFilter"].Value := ""
        this._MarkFilterActive := false
        this._MarkedPaths := Map()
        this._MarkedIdSet := Map()
        rootPath := this._FolderMap.Has(this.lastRoot) ? this._FolderMap[this.lastRoot] : ""
        if (rootPath != "")
            this._RefreshTree(tv, rootPath, false)
        this._UpdateTabBar()
        this._UpdateStatusBar()
    }

    /**
     * 現在のタブを閉じる（Ctrl+W）: タブが1枚のときは何もしない
     */
    static _CloseTab() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        if (this._TabCount <= 1)
            return
        this._Tabs.RemoveAt(this._CurrentTab)
        this._TabCount--
        if (this._CurrentTab > this._TabCount)
            this._CurrentTab := this._TabCount
        tv := this.GuiObj["FolderTree"]
        tab := (this._CurrentTab <= this._Tabs.Length) ? this._Tabs[this._CurrentTab] : ""
        if (tab == "" || tab.root == "") {
            this.GuiObj["TreeFilter"].Value := ""
            this._MarkFilterActive := false
            this._MarkedPaths := Map()
            this._MarkedIdSet := Map()
            rootPath := this._FolderMap.Has(this.lastRoot) ? this._FolderMap[this.lastRoot] : ""
            if (rootPath != "")
                this._RefreshTree(tv, rootPath, false)
        } else {
            this._ApplyTabState(tab, tv)
        }
        this._UpdateTabBar()
        this._UpdateStatusBar()
    }

    /**
     * タブ内履歴を戻る（Alt+←）
     */
    static _TabNavBack() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return
        tab := this._Tabs[this._CurrentTab]
        if (tab.history.Length == 0)
            return
        s := this._GetLiveState()
        tab.future.Push({root: s.root, filter: s.filter, marks: s.marks, markFilter: s.markFilter, path: s.path})
        prev := tab.history.Pop()
        tab.root := prev.root, tab.filter := prev.filter, tab.marks := prev.marks
        tab.markFilter := prev.markFilter, tab.path := prev.path
        this._ApplyTabState(tab, this.GuiObj["FolderTree"])
        this._UpdateTabBar()
        this._UpdateStatusBar()
    }

    /**
     * タブ内履歴を進む（Alt+→）
     */
    static _TabNavForward() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return
        tab := this._Tabs[this._CurrentTab]
        if (tab.future.Length == 0)
            return
        s := this._GetLiveState()
        tab.history.Push({root: s.root, filter: s.filter, marks: s.marks, markFilter: s.markFilter, path: s.path})
        next := tab.future.Pop()
        tab.root := next.root, tab.filter := next.filter, tab.marks := next.marks
        tab.markFilter := next.markFilter, tab.path := next.path
        this._ApplyTabState(tab, this.GuiObj["FolderTree"])
        this._UpdateTabBar()
        this._UpdateStatusBar()
    }

    /**
     * 現在のタブの履歴（戻る・進む）をクリア（Ctrl+Shift+H）
     */
    static _ClearTabHistory() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return
        tab := this._Tabs[this._CurrentTab]
        tab.history := []
        tab.future  := []
        ToolTip("タブ履歴をクリアしました"), SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
    }

    /**
     * プロファイルパスから INI セクション名を生成（例: "Tabs_work"）
     * プロファイル未設定時は "Tabs" を返す
     */
    static _ProfileTabSection(profilePath := "") {
        if (profilePath == "")
            profilePath := IniRead(this.IniPath, "Settings", "LastProfile", "")
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
    static _SaveTabsToIni() {
        sec := this._ProfileTabSection()
        try IniDelete(this.IniPath, sec)
        IniWrite(this._TabCount,   this.IniPath, sec, "Count")
        IniWrite(this._CurrentTab, this.IniPath, sec, "Current")
        Loop this._TabCount {
            n   := A_Index
            tab := (n <= this._Tabs.Length) ? this._Tabs[n] : ""
            if (tab == "")
                continue
            IniWrite(tab.root,               this.IniPath, sec, "Tab" . n . "Root")
            IniWrite(tab.filter,             this.IniPath, sec, "Tab" . n . "Filter")
            IniWrite(tab.path,               this.IniPath, sec, "Tab" . n . "Path")
            IniWrite(tab.markFilter ? "1" : "0", this.IniPath, sec, "Tab" . n . "MarkFilter")
            markStr := ""
            for k, v in tab.marks
                markStr .= (markStr == "" ? "" : "|") . v
            IniWrite(markStr, this.IniPath, sec, "Tab" . n . "Marks")
        }
    }

    /**
     * Navi.ini のプロファイル別セクションからタブ状態を復元
     * Show() の _LoadFolders 直後に呼ぶこと（タブバー生成前に _TabCount を確定させるため）
     */
    static _LoadTabsFromIni() {
        sec   := this._ProfileTabSection()
        ; プロファイル別セクションになければ旧来の [Tabs] にフォールバック
        if (IniRead(this.IniPath, sec, "Count", "") == "")
            sec := "Tabs"
        count   := Max(1, Min(Integer(IniRead(this.IniPath, sec, "Count",   "1")), this.TAB_MAX))
        current := Max(1, Min(Integer(IniRead(this.IniPath, sec, "Current", "1")), count))
        this._TabCount   := count
        this._CurrentTab := current
        this._Tabs       := []

        Loop count {
            n    := A_Index
            root := IniRead(this.IniPath, sec, "Tab" . n . "Root",       "")
            filt := IniRead(this.IniPath, sec, "Tab" . n . "Filter",     "")
            pth  := IniRead(this.IniPath, sec, "Tab" . n . "Path",       "")
            mf   := IniRead(this.IniPath, sec, "Tab" . n . "MarkFilter", "0")
            mStr := IniRead(this.IniPath, sec, "Tab" . n . "Marks",      "")

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


    static _ToggleMarkFilter() {
        if (this._MarkedPaths.Count == 0 || !(this.GuiObj && WinExist(this.GuiObj)))
            return
        tv := this.GuiObj["FolderTree"]
        rootPath := this._FolderMap.Has(this.lastRoot) ? this._FolderMap[this.lastRoot] : ""
        if (rootPath == "")
            return
        if (this._MarkFilterActive) {
            this._MarkFilterActive := false
            query := Trim(this.GuiObj["TreeFilter"].Value)
            if (query != "") {
                ; フォルダフィルタービューへ戻す（_ApplyTreeFilter 内でマーク色も復元）
                this._ApplyTreeFilter(query)
            } else {
                ; 全体ツリーへ戻してマーク色を復元
                savedMarks := Map()
                for k, v in this._MarkedPaths
                    savedMarks[k] := v
                this._RefreshTree(tv, rootPath, false)
                this._MarkedPaths := savedMarks
                this._RebuildMarkedIdSet(tv)
                this._EnsureFilterDraw(tv)
                DllCall("user32\InvalidateRect", "ptr", tv.Hwnd, "ptr", 0, "int", 1)
            }
            this._UpdateStatusBar()
        } else {
            this._MarkFilterActive := true
            this._ApplyMarkFilter(tv, rootPath)
        }
    }

    static _ApplyMarkFilter(tv, rootPath) {
        tv.Delete()
        this.FilesShown := Map()
        this._FilterMatchIdSet := Map()
        this._MarkedIdSet      := Map()
        NaviSearch._HighlightedIdSet := Map()

        rootBase := RTrim(rootPath, "\")
        rootID   := tv.Add(rootPath, 0, "Expand Icon1")
        addedPaths := Map()
        addedPaths[StrLower(rootBase)] := rootID

        firstMark := true
        for key, markedPath in this._MarkedPaths {
            rel   := SubStr(markedPath, StrLen(rootBase) + 2)
            parts := StrSplit(rel, "\")
            parentID    := rootID
            currentPath := rootBase
            for i, part in parts {
                currentPath .= "\" . part
                pathKey := StrLower(currentPath)
                isMatch := (i == parts.Length)
                if addedPaths.Has(pathKey) {
                    existingID := addedPaths[pathKey]
                    if (isMatch)
                        this._MarkedIdSet[existingID] := true
                    parentID := existingID
                } else {
                    opts    := isMatch ? "Bold" : ""
                    if (isMatch && firstMark) {
                        opts .= " Select"
                        firstMark := false
                    }
                    isDir   := DirExist(currentPath) ? true : false
                    iconStr := isDir ? "Icon1" : this._GetFileIconStr(part)
                    nodeID  := tv.Add(part, parentID, opts . " " . iconStr)
                    if (isMatch)
                        this._MarkedIdSet[nodeID] := true
                    addedPaths[pathKey] := nodeID
                    parentID := nodeID
                    ; マークフォルダの子を読み込み手動展開できるようにする
                    if (isMatch && isDir) {
                        this._LoadSub(tv, currentPath, nodeID)
                        this._ShowFilesIfEnabled(tv, nodeID, currentPath)
                    }
                }
            }
        }

        ; 中間親ノードのみ展開（マークノード自体は折り畳み状態を維持）
        for pathKey, nodeID in addedPaths {
            if (nodeID != rootID && !this._MarkedIdSet.Has(nodeID) && tv.GetChild(nodeID) != 0)
                tv.Modify(nodeID, "Expand")
        }

        this._EnsureFilterDraw(tv)
        this._UpdateStatusBar()
    }

    static _RebuildMarkedIdSet(tv) {
        this._MarkedIdSet := Map()
        if (this._MarkedPaths.Count == 0)
            return
        nodeId := tv.GetNext(0, "Full")  ; "Full" = 兄弟のみでなくツリー全体をDFS順に走査
        while (nodeId) {
            path := this._GetTVFullPath(tv, nodeId)
            if (this._MarkedPaths.Has(StrLower(path)))
                this._MarkedIdSet[nodeId] := true
            nodeId := tv.GetNext(nodeId, "Full")
        }
    }

    static _LoadSub(tv, path, parentID) {
        loop files, path . "\*", "D" {
            if (SubStr(A_LoopFileName, 1, 1) == "." || InStr(A_LoopFileAttrib, "H")) {
                continue
            }
            tv.Add("...loading...", tv.Add(A_LoopFileName, parentID, "Icon1"))
        }
    }

    static _OnItemExpand(tv, id) {
        child := tv.GetChild(id)
        if (child == 0 || tv.GetText(child) != "...loading...") {
            return
        }
        tv.Delete(child)
        this._LoadSub(tv, this._GetTVFullPath(tv, id), id)
        ; ファイル表示モードがONなら展開と同時にファイルも自動表示
        this._ShowFilesIfEnabled(tv, id, this._GetTVFullPath(tv, id))
    }

    static _ShowFilesIfEnabled(tv, nodeID, fullPath) {
        if !(this.GuiObj && this.GuiObj["AutoFilesCheck"].Value && !this.FilesShown.Has(nodeID))
            return
        fileMax := 200
        try fileMax := Integer(IniRead(this.IniPath, "Settings", "FileMax", "200"))
        shown := []
        count := 0
        loop files, fullPath . "\*", "F" {
            if InStr(A_LoopFileAttrib, "H")
                continue
            shown.Push(tv.Add(A_LoopFileName, nodeID, this._GetFileIconStr(A_LoopFileName)))
            if (++count >= fileMax)
                break
        }
        this.FilesShown[nodeID] := shown
    }

    static _GetTVFullPath(tv, id) {
        parts := [], currID := id
        while (currID != 0) {
            txt := tv.GetText(currID), parts.InsertAt(1, txt)
            if (InStr(txt, ":\")) {
                break
            }
            currID := tv.GetParent(currID)
        }
        path := ""
        for i, p in parts {
            path := (i == 1) ? p : RTrim(path, "\") . "\" . p
        }
        return path
    }

    ; --- パンくずリスト関連 ---
    static _BreadcrumbWatcher() {
        try {
            if !(this.GuiObj && this.GuiObj.Hwnd && WinExist("ahk_id " this.GuiObj.Hwnd)) {
                SetTimer(this._BreadcrumbWatcher.Bind(this), 0)
                return
            }
            tv := this.GuiObj["FolderTree"]
            id := tv.GetSelection()
            if (id != this.lastSelectedId) {
                this.lastSelectedId := id
                this._UpdateBreadcrumb(tv, id)
            }
        }
    }

    static _RefreshBreadcrumb() {
        try {
            if !(this.GuiObj && this.GuiObj.Hwnd && WinExist("ahk_id " this.GuiObj.Hwnd))
                return
            tv := this.GuiObj["FolderTree"]
            id := tv.GetSelection()
            this.lastSelectedId := id
            this._UpdateBreadcrumb(tv, id)
        }
    }

    static _UpdateBreadcrumb(tv, id) {
        try {
            if !(this.GuiObj && this.GuiObj.Hwnd)
                return
            if (id = 0) {
                this.GuiObj["Breadcrumb"].Value := ""
                return
            }
            fullPath := this._GetTVFullPath(tv, id)
            this.GuiObj["Breadcrumb"].Value := fullPath
        }
    }

    static _UpdateStatusBar() {
        try {
            sb := this.GuiObj._sbRef
            base := " [Space]メニュー  [Enter]開く  [Ctrl+D]詳細  [F1]ヘルプ"
            sb.SetText(this._MarkFilterActive ? base . "  [mark]" : base)
        }
    }

    static _OnSetCursor(wParam, lParam, msg, hwnd) {
        if (wParam != Navi._BreadcrumbHwnd)
            return
        DllCall("user32\SetCursor", "ptr", DllCall("user32\LoadCursorW", "ptr", 0, "ptr", 32649, "ptr"))
        return true  ; デフォルト処理をスキップ
    }

    static _OnBreadcrumbClick() {
        tv := this.GuiObj["FolderTree"]
        id := tv.GetSelection()
        if (id = 0)
            return

        ; 現在のパスから各階層をメニューに表示
        pathParts := []
        currID := id
        while (currID != 0) {
            pathParts.InsertAt(1, { id: currID, name: tv.GetText(currID) })
            currID := tv.GetParent(currID)
        }

        if (pathParts.Length = 0)
            return

        ; ポップアップメニューを作成
        bcMenu := Menu()
        for i, part in pathParts {
            partID := part.id
            indent := ""
            loop i - 1
                indent .= "    "
            bcMenu.Add(indent . part.name, ((pid, *) => this._JumpToTreeItem(pid)).Bind(partID))
        }
        ; Esc ホットキーを一時無効化（メニューの Esc 閉じを AHK が横取りするため）
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Esc", "Off")
        HotIf()
        bcMenu.Show()
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Esc", "On")
        HotIf()
    }

    static _JumpToTreeItem(id) {
        tv := this.GuiObj["FolderTree"]
        tv.Modify(id, "Select Vis")
        if (tv.GetChild(id)) {
            tv.Modify(id, "Expand")
            this._OnItemExpand(tv, id)
        }
        tv.Focus()
    }

    static _GetActiveWindowPath() {
        hwnd := WinExist("A")
        if (hwnd == 0) {
            return ""
        }
        cls := WinGetClass("A")
        if (cls == "CabinetWClass" || cls == "ExploreWClass" || cls == "Progman" || cls == "WorkerW" || InStr(cls,
            "Tablacus")) {
            try {
                shellApp := ComObject("Shell.Application")
                for window in shellApp.Windows {
                    if (window && window.hwnd == hwnd) {
                        return window.Document.Folder.Self.Path
                    }
                }
            }
        }
        return ""
    }

    /**
     * 編集 GUI の ListView からプロファイルファイルを書き出す（フォーマット: name=path）
     * メモリ上のマップから直接書き出す場合は _WriteProfileFileFromMap(outPath) を使う。
     */
    static _WriteProfileFile(lv, outPath) {
        txt := ""
        Loop lv.GetCount() {
            name := lv.GetText(A_Index, 1)
            path := lv.GetText(A_Index, 2)
            if (name != "" && path != "")
                txt .= name . "=" . path . "`n"
        }
        try FileDelete(outPath)
        FileAppend(txt, outPath, "UTF-8")
    }

    /**
     * .txt プロファイルを読み込んでルートリストを置き換え、タブをリセットして再起動
     * フォーマット: name=path または path のみ（名前はフォルダ名から自動生成）
     */
    static _ImportProfile(txtPath) {
        if (!FileExist(txtPath)) {
            ToolTip("ファイルが見つかりません: " . txtPath), SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }
        txt := FileRead(txtPath, "UTF-8")
        if (txt == "")
            txt := FileRead(txtPath)  ; UTF-8 BOMなしフォールバック
        entries := []
        for line in StrSplit(txt, "`n", "`r") {
            line := Trim(line)
            if (line == "" || SubStr(line, 1, 1) == ";")
                continue
            if (InStr(line, "=")) {
                p    := StrSplit(line, "=", , 2)
                name := Trim(p[1])
                path := Trim(p[2])
            } else {
                path := Trim(line)
                name := StrSplit(RTrim(path, "\"), "\")[-1]
            }
            if (name != "" && path != "")
                entries.Push({name: name, path: path})
        }
        ; [Folders] セクションを新しいリストで上書き（空プロファイルはセクションをクリア）
        IniDelete(this.IniPath, "Folders")
        for e in entries
            IniWrite(e.path . "|1", this.IniPath, "Folders", e.name)
        ; 現プロファイルのタブ状態を保存（プロファイル別セクションに書き込む）
        this._SaveCurrentTab()
        this._SaveTabsToIni()
        ; 最後に使ったプロファイルパスを更新
        IniWrite(txtPath, this.IniPath, "Settings", "LastProfile")
        ; GUI が開いていればインプレース更新、なければ再起動
        if (this.GuiObj && WinExist(this.GuiObj))
            this._ReloadProfileInPlace()
        else
            Reload()
    }

    /**
     * プロファイル切り替え・保存後のインプレース更新
     * GUI を閉じずにフォルダマップ・タブ・ツリーを現在の INI 内容で再構築する。
     * プロファイルロード（_ImportProfile）とリスト保存（_SaveList）の*方から呼ばれる。
     */
    static _ReloadProfileInPlace() {
        ; フォルダデータを再読み込み
        newFolderMap := Map(), newFolderNames := []
        this._LoadFolders(newFolderMap, newFolderNames)
        this._AllFolderNames := newFolderNames
        this.FilteredNames   := newFolderNames.Clone()
        this._FolderMap      := newFolderMap

        ; 新プロファイルのタブ状態を読み込み
        this._LoadTabsFromIni()

        ; マーク状態をリセット
        this._MarkedPaths      := Map()
        this._MarkedIdSet      := Map()
        this._MarkFilterActive := false

        ; ツリーを新プロファイルで復元
        tv := this.GuiObj["FolderTree"]
        this.GuiObj["TreeFilter"].Value := ""
        if (newFolderNames.Length == 0) {
            ; 空プロファイル: ツリーをクリアして RootBtn をリセット
            tv.Delete()
            this.lastRoot := ""
            this.lastPath := ""
        } else if (!this._RestoreCurrentTab(tv)) {
            ; 新プロファイルに前のルートがなければ先頭ルートへ
            this.lastRoot := newFolderNames[1]
            this._RefreshTree(tv, newFolderMap[this.lastRoot])
        }

        ; UI 更新
        this.GuiObj["RootBtn"].Text := (this.lastRoot != "") ? this._TruncRootLabel(this.lastRoot) : "ルートを選択..."
        this._UpdateProfileBtn()
        this._UpdateTabBar()
        this._UpdateStatusBar()
    }

    ; --- プロファイル機能 ---

    static _GetProfilesDir() {
        return A_ScriptDir . "\ui\profiles"
    }

    static _GetProfileList() {
        dir := this._GetProfilesDir()
        if (!DirExist(dir))
            DirCreate(dir)
        names := []
        Loop Files dir . "\*.txt"
            names.Push(RegExReplace(A_LoopFileName, "\.txt$", ""))
        return names
    }

    static _GetProfileBtnText() {
        last := IniRead(this.IniPath, "Settings", "LastProfile", "")
        if (last == "")
            return "Profile"
        name := RegExReplace(last, ".*\\")
        name := RegExReplace(name, "\.txt$")
        return (StrLen(name) > 10) ? SubStr(name, 1, 9) . ".." : name
    }

    ; RootBtn (w190) に収まるよう長い名前を切り詰める
    static _TruncRootLabel(name) {
        return (StrLen(name) > 18) ? SubStr(name, 1, 16) . "..." : name
    }

    static _UpdateProfileBtn() {
        if (this.GuiObj && WinExist(this.GuiObj))
            this.GuiObj["ProfileBtn"].Text := this._GetProfileBtnText()
    }

    static _OpenProfileDropdown() {
        if (this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        if !(this.GuiObj && WinExist(this.GuiObj))
            return

        this._AllProfileNames      := this._GetProfileList()
        this._ProfileFilteredNames := this._AllProfileNames.Clone()

        ddGui := Gui("+Owner" . this.GuiObj.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", "プロファイル")
        ddGui.MarginX := 8
        ddGui.MarginY := 8
        ddGui.SetFont("s10", "Yu Gothic UI")

        filterEdit := ddGui.Add("Edit", "xm w200 vProfileFilter")
        try DllCall("user32\SendMessageW", "ptr", filterEdit.Hwnd, "uint", this.EM_SETCUEBANNER, "ptr", 1,
            "wstr", "名前でフィルター...", "ptr")

        ddList := ddGui.Add("ListBox", "xm w200 r8 vProfileList", this._ProfileFilteredNames)
        if (this._ProfileFilteredNames.Length > 0)
            ddList.Choose(1)

        ddGui.SetFont("s8")
        ddGui.Add("Text", "xm c808080", "↑↓: 移動  Enter: ロード  Esc: 閉じる")
        this.ProfileDropdownGui := ddGui

        filterEdit.OnEvent("Change",      (*) => this._ProfileOverlayFilterChange())
        ddList.OnEvent("DoubleClick",     (*) => this._ConfirmProfileDropdown())
        ddGui.OnEvent("Close",            (*) => this._CloseProfileDropdown())

        local ddHwnd   := ddGui.Hwnd
        local self     := this
        local wmActMsg := Navi.WM_ACTIVATE
        wmAct(wParam, lParam, msg, hwnd) {
            if (hwnd = ddHwnd && wParam = 0) {
                OnMessage(wmActMsg, wmAct, 0)
                SetTimer(() => self._CloseProfileDropdown(), -50)
            }
        }
        OnMessage(wmActMsg, wmAct)

        HotIfWinActive("ahk_id " ddGui.Hwnd)
        Hotkey("Enter",   (*) => this._ConfirmProfileDropdown(), "On")
        Hotkey("Escape",  (*) => this._CloseProfileDropdown(), "On")
        Hotkey("~Down",   (*) => this._ProfileNavDown(), "On")
        Hotkey("~Up",     (*) => this._ProfileNavUp(), "On")
        HotIf()

        this.GuiObj.GetPos(&gx, &gy)
        this.GuiObj["ProfileBtn"].GetPos(&bx, &by, &bw, &bh)
        ddGui.Show("x" . (gx + bx) . " y" . (gy + by) . " w220 AutoSize")
        filterEdit.Focus()
    }

    static _CloseProfileDropdown() {
        if !(this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        local ddGui := this.ProfileDropdownGui
        this.ProfileDropdownGui := ""
        try ddGui.Destroy()
    }

    ; プロファイル一覧を再スキャンしてドロップダウンのListBoxを更新する
    static _RefreshProfileDropdownList() {
        this._AllProfileNames := this._GetProfileList()
        query := (this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            ? this.ProfileDropdownGui["ProfileFilter"].Value : ""
        this._ProfileFilteredNames := []
        for name in this._AllProfileNames
            if (query == "" || InStr(name, query, false))
                this._ProfileFilteredNames.Push(name)
        if !(this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        ddList := this.ProfileDropdownGui["ProfileList"]
        ddList.Delete()
        if (this._ProfileFilteredNames.Length > 0) {
            ddList.Add(this._ProfileFilteredNames)
            ddList.Choose(1)
        }
    }

    ; 現在のルートを新しい名前のプロファイルとして保存（上書き不可）
    static _NewProfileDialog() {
        this._CloseProfileDropdown()
        result := InputBox("新しいプロファイル名を入力してください:", "新規プロファイル", "w260 h100")
        if (result.Result != "OK" || Trim(result.Value) == "")
            return
        name := Trim(RegExReplace(result.Value, '[\\/:*?"<>|]', "_"))
        if (name == "")
            return
        dir := this._GetProfilesDir()
        if (!DirExist(dir))
            DirCreate(dir)
        outPath := dir . "\" . name . ".txt"
        if (FileExist(outPath)) {
            MsgBox("同名のプロファイルが既に存在します。", "エラー", "Icon!")
            return
        }
        txt := ""
        for n in this._AllFolderNames {
            p := this._FolderMap.Has(n) ? this._FolderMap[n] : ""
            if (p != "")
                txt .= n . "=" . p . "`n"
        }
        FileAppend(txt, outPath, "UTF-8")
        IniWrite(outPath, this.IniPath, "Settings", "LastProfile")
        this._UpdateProfileBtn()
        ToolTip("作成しました: " . name), SetTimer(() => ToolTip(), -this.TOOLTIP_COPY_DURATION)
    }

    ; 空の新規プロファイルを作成（LV もクリアして編集状態にする）
    static _NewProfileDialogFromEdit(editGui) {
        editGui.Opt("-AlwaysOnTop")
        result := InputBox("新しいプロファイル名を入力してください:", "新規プロファイル", "w260 h100")
        editGui.Opt("+AlwaysOnTop")
        if (result.Result != "OK" || Trim(result.Value) == "")
            return
        name := Trim(RegExReplace(result.Value, '[\\/:*?"<>|]', "_"))
        if (name == "")
            return
        dir := this._GetProfilesDir()
        if (!DirExist(dir))
            DirCreate(dir)
        outPath := dir . "\" . name . ".txt"
        if (FileExist(outPath)) {
            editGui.Opt("-AlwaysOnTop")
            MsgBox("同名のプロファイルが既に存在します。", "エラー", "Icon!")
            editGui.Opt("+AlwaysOnTop")
            return
        }
        FileAppend("", outPath, "UTF-8")  ; 空ファイル作成
        IniWrite(outPath, this.IniPath, "Settings", "LastProfile")
        this._UpdateProfileBtn()
        this._RefreshEditProfileList(editGui, name)
        this._LoadProfileIntoLV(editGui["FolderList"], name)  ; 空のLVに切り替え
        ToolTip("作成しました: " . name), SetTimer(() => ToolTip(), -this.TOOLTIP_COPY_DURATION)
    }

    ; 現在の LV 内容をコピーして新規プロファイルを作成
    static _DupProfileDialogFromEdit(editGui, lv) {
        editGui.Opt("-AlwaysOnTop")
        result := InputBox("複製後のプロファイル名を入力してください:", "プロファイルを複製", "w260 h100")
        editGui.Opt("+AlwaysOnTop")
        if (result.Result != "OK" || Trim(result.Value) == "")
            return
        name := Trim(RegExReplace(result.Value, '[\\/:*?"<>|]', "_"))
        if (name == "")
            return
        dir := this._GetProfilesDir()
        if (!DirExist(dir))
            DirCreate(dir)
        outPath := dir . "\" . name . ".txt"
        if (FileExist(outPath)) {
            editGui.Opt("-AlwaysOnTop")
            MsgBox("同名のプロファイルが既に存在します。", "エラー", "Icon!")
            editGui.Opt("+AlwaysOnTop")
            return
        }
        this._WriteProfileFile(lv, outPath)
        IniWrite(outPath, this.IniPath, "Settings", "LastProfile")
        this._UpdateProfileBtn()
        this._RefreshEditProfileList(editGui, name)
        this._LoadProfileIntoLV(editGui["FolderList"], name)  ; 複製内容をLVに反映
        ToolTip("複製しました: " . name), SetTimer(() => ToolTip(), -this.TOOLTIP_COPY_DURATION)
    }

    ; 編集ダイアログのドロップダウンで選択中のプロファイルを削除
    static _DeleteProfileFromEdit(editGui) {
        name := editGui["EditProfileDDL"].Text
        if (name == "")
            return
        path := this._GetProfilesDir() . "\" . name . ".txt"
        if (!FileExist(path))
            return
        editGui.Opt("-AlwaysOnTop")
        ans := MsgBox("「" . name . "」を削除しますか？", "プロファイル削除", "YesNo Icon!")
        editGui.Opt("+AlwaysOnTop")
        if (ans != "Yes")
            return
        lastProfile := IniRead(this.IniPath, "Settings", "LastProfile", "")
        if (lastProfile = path) {
            IniDelete(this.IniPath, "Settings", "LastProfile")
            this._UpdateProfileBtn()
        }
        FileDelete(path)
        this._RefreshEditProfileList(editGui)
        this._LoadProfileIntoLV(editGui["FolderList"], editGui["EditProfileDDL"].Text)
    }

    ; 編集ダイアログのドロップダウンで選択中のプロファイルの名前を変更
    static _RenameProfileFromEdit(editGui) {
        name := editGui["EditProfileDDL"].Text
        if (name == "")
            return
        oldPath := this._GetProfilesDir() . "\" . name . ".txt"
        if (!FileExist(oldPath))
            return
        editGui.Opt("-AlwaysOnTop")
        result := InputBox("新しい名前を入力してください:", "名前変更", "w260 h100", name)
        editGui.Opt("+AlwaysOnTop")
        if (result.Result != "OK" || Trim(result.Value) == "" || Trim(result.Value) = name)
            return
        newName := Trim(RegExReplace(result.Value, '[\\/:*?"<>|]', "_"))
        if (newName == "")
            return
        newPath := this._GetProfilesDir() . "\" . newName . ".txt"
        if (FileExist(newPath)) {
            editGui.Opt("-AlwaysOnTop")
            MsgBox("同名のプロファイルが既に存在します。", "エラー", "Icon!")
            editGui.Opt("+AlwaysOnTop")
            return
        }
        FileMove(oldPath, newPath)
        lastProfile := IniRead(this.IniPath, "Settings", "LastProfile", "")
        if (lastProfile = oldPath) {
            IniWrite(newPath, this.IniPath, "Settings", "LastProfile")
            this._UpdateProfileBtn()
        }
        this._RefreshEditProfileList(editGui, newName)
    }

    ; 編集ダイアログのプロファイルドロップダウンリストを再構築
    ; selectName を指定するとその項目を選択する（省略時は先頭）
    static _RefreshEditProfileList(editGui, selectName := "") {
        try {
            if !(editGui && WinExist(editGui))
                return
            names := this._GetProfileList()
            ddl := editGui["EditProfileDDL"]
            ddl.Delete()
            if (names.Length > 0) {
                ddl.Add(names)
                chosen := 1
                if (selectName != "") {
                    for i, n in names {
                        if (n = selectName) {
                            chosen := i
                            break
                        }
                    }
                }
                ddl.Choose(chosen)
            }
        }
    }

    ; 指定プロファイルの内容を ListView に読み込む
    static _LoadProfileIntoLV(lv, profileName) {
        if (profileName == "")
            return
        path := this._GetProfilesDir() . "\" . profileName . ".txt"
        if (!FileExist(path))
            return
        lv.Delete()
        try {
            loop read path {
                line := Trim(A_LoopReadLine)
                if (line == "" || !InStr(line, "="))
                    continue
                parts := StrSplit(line, "=", , 2)
                lv.Add(, Trim(parts[1]), parts[2], "○")
            }
        }
    }

    ; 選択中のプロファイルを削除する
    static _DeleteSelectedProfile() {
        if !(this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        name := this.ProfileDropdownGui["ProfileList"].Text
        if (name == "")
            return
        path := this._GetProfilesDir() . "\" . name . ".txt"
        if (!FileExist(path))
            return
        if (MsgBox("「" . name . "」を削除しますか？", "プロファイル削除", "YesNo Icon!") != "Yes")
            return
        lastProfile := IniRead(this.IniPath, "Settings", "LastProfile", "")
        if (lastProfile = path) {
            IniDelete(this.IniPath, "Settings", "LastProfile")
            this._UpdateProfileBtn()
        }
        FileDelete(path)
        this._RefreshProfileDropdownList()
    }

    ; 選択中のプロファイルの名前を変更する
    static _RenameSelectedProfile() {
        if !(this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        name := this.ProfileDropdownGui["ProfileList"].Text
        if (name == "")
            return
        oldPath := this._GetProfilesDir() . "\" . name . ".txt"
        if (!FileExist(oldPath))
            return
        result := InputBox("新しい名前を入力してください:", "名前変更", "w260 h100", name)
        if (result.Result != "OK" || Trim(result.Value) == "" || Trim(result.Value) = name)
            return
        newName := Trim(RegExReplace(result.Value, '[\\/:*?"<>|]', "_"))
        if (newName == "")
            return
        newPath := this._GetProfilesDir() . "\" . newName . ".txt"
        if (FileExist(newPath)) {
            MsgBox("同名のプロファイルが既に存在します。", "エラー", "Icon!")
            return
        }
        FileMove(oldPath, newPath)
        lastProfile := IniRead(this.IniPath, "Settings", "LastProfile", "")
        if (lastProfile = oldPath) {
            IniWrite(newPath, this.IniPath, "Settings", "LastProfile")
            this._UpdateProfileBtn()
        }
        this._RefreshProfileDropdownList()
    }

    static _ConfirmProfileDropdown() {
        if !(this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        name := this.ProfileDropdownGui["ProfileList"].Text
        this._CloseProfileDropdown()
        if (name == "")
            return
        path := this._GetProfilesDir() . "\" . name . ".txt"
        this._ImportProfile(path)
    }

    static _ProfileOverlayFilterChange() {
        if !(this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        query := this.ProfileDropdownGui["ProfileFilter"].Value
        this._ProfileFilteredNames := []
        for name in this._AllProfileNames
            if (query == "" || InStr(name, query, false))
                this._ProfileFilteredNames.Push(name)
        ddList := this.ProfileDropdownGui["ProfileList"]
        ddList.Delete()
        if (this._ProfileFilteredNames.Length > 0) {
            ddList.Add(this._ProfileFilteredNames)
            ddList.Choose(1)
        }
    }

    static _ProfileNavDown() {
        if !(this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        focus := 0
        try focus := DllCall("user32\GetFocus", "ptr")
        if (focus != this.ProfileDropdownGui["ProfileFilter"].Hwnd)
            return
        ddList := this.ProfileDropdownGui["ProfileList"]
        cur   := ddList.Value
        total := this._ProfileFilteredNames.Length
        if (total == 0)
            return
        ddList.Choose((cur <= 0 || cur >= total) ? 1 : cur + 1)
    }

    static _ProfileNavUp() {
        if !(this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        focus := 0
        try focus := DllCall("user32\GetFocus", "ptr")
        if (focus != this.ProfileDropdownGui["ProfileFilter"].Hwnd)
            return
        ddList := this.ProfileDropdownGui["ProfileList"]
        cur   := ddList.Value
        total := this._ProfileFilteredNames.Length
        if (total == 0)
            return
        ddList.Choose((cur <= 1) ? total : cur - 1)
    }

    static _QuickRegisterFromEdit() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        e := this.GuiObj["QuickPath"]
        path := Trim(e.Value)
        if (path = "")
            return
        ; .txt ファイルならプロファイルとしてインポート
        if (SubStr(StrLower(path), -3) == ".txt") {
            e.Value := ""
            this._ImportProfile(path)
            return
        }
        if (!DirExist(path)) {
            ToolTip("無効なパスです"), SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }
        name := StrSplit(RTrim(path, "\"), "\")[-1]

        ; INIへ書き込み（表示=1）
        IniWrite(path . "|1", this.IniPath, "Folders", name)

        ; リストの先頭に表示させる（新しいリストを作り直す）
        folderMap := Map(), folderNames := []
        this._LoadFolders(folderMap, folderNames)

        newNames := [name]
        for n in folderNames {
            if (n != name)
                newNames.Push(n)
        }

        ; クラス状態を更新
        this._AllFolderNames := newNames
        this.FilteredNames := newNames.Clone()
        this._FolderMap := folderMap
        this._FolderMap[name] := path

        ; UIを更新
        rootBtn := this.GuiObj["RootBtn"]
        tv := this.GuiObj["FolderTree"]
        rootBtn.Text := name

        this._PushTabHistory()  ; 現在のルートを履歴に積んでから切り替え
        this.lastRoot := name
        this.lastPath := path
        this._RefreshTree(tv, path)
        this._UpdateTabBar()  ; タブラベルに新ルート名を反映

        ; プロファイルが設定されている場合は自動保存
        lastProfile := IniRead(this.IniPath, "Settings", "LastProfile", "")
        if (lastProfile != "")
            this._WriteProfileFileFromMap(lastProfile)

        e.Value := ""
        ToolTip("Root added: " . name), SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
    }

    static _HandleEnter() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        ; 現在のフォーカスHWNDを取得（まずはAHK API、失敗時はWinAPIにフォールバック）
        currFocus := 0
        try {
            ctrl := ControlGetFocus("ahk_id " this.GuiObj.Hwnd)
            currFocus := ControlGetHwnd(ctrl, "ahk_id " this.GuiObj.Hwnd)
        } catch {
            try {
                currFocus := DllCall("user32\GetFocus", "ptr")
            } catch {
                currFocus := 0
            }
        }

        if (this.QuickPathHwnd && currFocus = this.QuickPathHwnd) {
            ; クイック登録欄がフォーカスなら登録を優先
            this._QuickRegisterFromEdit()
            return
        }
        if (this.GuiObj.HasOwnProp("_rootBtnHwnd") && currFocus = this.GuiObj._rootBtnHwnd) {
            ; ルートボタンがフォーカスならオーバーレイを開く
            this._OpenDropdown()
            return
        }
        if (this.GuiObj.HasOwnProp("_filterToggleHwnd") && currFocus = this.GuiObj._filterToggleHwnd) {
            this._ToggleSearchMode()
            return
        }
        if (this.GuiObj.HasOwnProp("_searchTypeBtnHwnd") && currFocus = this.GuiObj._searchTypeBtnHwnd) {
            this._CycleSearchType()
            return
        }
        if (this.GuiObj.HasOwnProp("_btnEditHwnd") && currFocus = this.GuiObj._btnEditHwnd) {
            ; 編集ボタンがフォーカスなら編集GUIを開く
            this._ShowEditGui(this.GuiObj)
            return
        }
        if (this.GuiObj.HasOwnProp("_profileBtnHwnd") && currFocus = this.GuiObj._profileBtnHwnd) {
            ; プロファイルボタンがフォーカスならドロップダウンを開く
            this._OpenProfileDropdown()
            return
        }
        if (this.GuiObj.HasOwnProp("_pinCheckHwnd") && currFocus = this.GuiObj._pinCheckHwnd) {
            ; ピン留めチェックボックスがフォーカスならトグル
            this.GuiObj["PinCheck"].Value := !this.GuiObj["PinCheck"].Value
            return
        }
        if (this.GuiObj.HasOwnProp("_autoFilesCheckHwnd") && currFocus = this.GuiObj._autoFilesCheckHwnd) {
            ; ファイル表示チェックボックスがフォーカスならトグル
            this.GuiObj["AutoFilesCheck"].Value := !this.GuiObj["AutoFilesCheck"].Value
            IniWrite(this.GuiObj["AutoFilesCheck"].Value ? "1" : "0", this.IniPath, "Settings", "AutoShowFiles")
            return
        }
        if (this.GuiObj.HasOwnProp("_treeFilterHwnd") && currFocus = this.GuiObj._treeFilterHwnd) {
            ; ツリーフィルター欄がフォーカスの場合: IME変換中なら確定Enterを送る
            hIMC := DllCall("imm32\ImmGetContext", "ptr", this.GuiObj._treeFilterHwnd, "ptr")
            if (hIMC) {
                composing := DllCall("imm32\ImmGetCompositionStringW", "ptr", hIMC, "uint", 0x0008, "ptr", 0, "ptr", 0) > 0
                DllCall("imm32\ImmReleaseContext", "ptr", this.GuiObj._treeFilterHwnd, "ptr", hIMC)
                if (composing) {
                    Send "{Enter}"  ; IMEに確定Enterを渡す
                    return
                }
            }
            ; 検索モードなら検索実行、フィルターモードならツリーへフォーカス移動
            if (this._SearchMode) {
                this._RunSearchFromFilter()
            } else {
                this.GuiObj["FolderTree"].Focus()
            }
            return
        }
        ; それ以外はアクティベート（ファイルなら直接開く、フォルダならExplorer）
        this._HandleActivate()
    }

    /**
     * フィルター欄のモードをフォルダフィルター ↔ ファイル検索で切り替える
     */
    static _ToggleSearchMode() {
        this._SearchMode := !this._SearchMode
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        this.GuiObj["FilterToggle"].Text := this._SearchMode ? "🔍" : "📁"
        ; 検索タイプボタンの表示切替・リセット
        this.GuiObj["SearchTypeBtn"].Visible := this._SearchMode
        if (!this._SearchMode) {
            this._SearchTypeFilter := "all"
            this.GuiObj["SearchTypeBtn"].Text := "*"
        }
        ; TreeFilter の右端を TreeView の右端に揃える（幅 = margin + tvW - tfX）
        _margin_ := this.GuiObj.MarginX
        this.GuiObj["FolderTree"].GetPos(,, &_tvW_)
        if (this._SearchMode)
            this.GuiObj["TreeFilter"].Move(70,, _margin_ + _tvW_ - 70)
        else
            this.GuiObj["TreeFilter"].Move(39,, _margin_ + _tvW_ - 39)
        cue := this._SearchMode ? "ファイルを検索... (Enter で実行)" : "フォルダをフィルター..."
        try DllCall("user32\SendMessageW", "ptr", this.GuiObj["TreeFilter"].Hwnd,
            "uint", this.EM_SETCUEBANNER, "ptr", 1, "wstr", cue, "ptr")
        this.GuiObj["TreeFilter"].Value := ""
        this._ApplyTreeFilter("")  ; どちらのモードに切り替えても必ずツリーフィルターをリセット
        if (!this._SearchMode)    ; フォルダフィルターに戻したら検索結果も閉じる
            try NaviSearch.ClearHighlights(this)
        this.GuiObj["TreeFilter"].Focus()
    }

    /**
     * 検索モード時: フィルター欄のテキストを使ってファイル検索を実行する
     */
    static _RunSearchFromFilter() {
        query := this.GuiObj["TreeFilter"].Value
        if (query == "")
            return
        tv := this.GuiObj["FolderTree"]
        selId := tv.GetSelection()
        basePath := selId ? this._GetTVFullPath(tv, selId) : ""
        if (basePath == "" || !DirExist(basePath))
            basePath := this._FolderMap.Has(this.lastRoot) ? this._FolderMap[this.lastRoot] : ""
        if (basePath == "")
            return
        NaviSearch.RunLocalDirect(this, basePath, query, this._SearchTypeFilter)
    }

    /**
     * 検索対象種別を循環切替: *方 → フォルダのみ → ファイルのみ → *方...
     */
    static _CycleSearchType() {
        if (this._SearchTypeFilter = "all") {
            this._SearchTypeFilter := "dir"
            this.GuiObj["SearchTypeBtn"].Text := "📁"
        } else if (this._SearchTypeFilter = "dir") {
            this._SearchTypeFilter := "file"
            this.GuiObj["SearchTypeBtn"].Text := "📄"
        } else {
            this._SearchTypeFilter := "all"
            this.GuiObj["SearchTypeBtn"].Text := "*"
        }
    }

    static _HandleActivate() {
        tv   := this.GuiObj["FolderTree"]
        id   := tv.GetSelection()
        path := id ? this._GetTVFullPath(tv, id) : ""
        if (path == "")
            return
        ; ファイルノード: 関連付けアプリで直接開く
        if (!DirExist(path) && FileExist(path)) {
            try Run('"' . path . '"')
            if (!this.GuiObj["PinCheck"].Value)
                this._DestroyGui()
            return
        }
        ; フォルダノード: 既存 Explorer があればアクティブ化、なければ新規
        this.Execute("e")
    }

    /**
     * 指定パスが既に Explorer で開かれていればそのウィンドウをアクティブ化する。
     * 開かれていなければ新規で explorer.exe を起動する。
     */
    static _ActivateOrOpenExplorer(path) {
        path := RTrim(path, "\")
        try {
            shell := ComObject("Shell.Application")
            for w in shell.Windows() {
                try {
                    expPath := RTrim(w.Document.Folder.Self.Path, "\")
                    if (expPath = path) {
                        hwnd := w.HWND
                        WinRestore("ahk_id " hwnd)
                        WinActivate("ahk_id " hwnd)
                        return
                    }
                }
            }
        }
        Run('explorer.exe "' . path . '"')
    }

    static _HandleSpace() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        currFocus := 0
        try currFocus := DllCall("user32\GetFocus", "ptr")
        if (this.GuiObj.HasOwnProp("_filterToggleHwnd") && currFocus = this.GuiObj._filterToggleHwnd) {
            this._ToggleSearchMode()
            return
        }
        if (this.GuiObj.HasOwnProp("_searchTypeBtnHwnd") && currFocus = this.GuiObj._searchTypeBtnHwnd) {
            this._CycleSearchType()
            return
        }
        ; ツリーフィルター欄にフォーカスがある場合はスペースを手動で送る
        if (this.GuiObj.HasOwnProp("_treeFilterHwnd") && currFocus = this.GuiObj._treeFilterHwnd) {
            Send "{Space}"  ; IMEのスペース変換も通るよう実キーとして送信
            return
        }
        ; ピン留めチェックボックスがフォーカスならトグル
        if (this.GuiObj.HasOwnProp("_pinCheckHwnd") && currFocus = this.GuiObj._pinCheckHwnd) {
            this.GuiObj["PinCheck"].Value := !this.GuiObj["PinCheck"].Value
            return
        }
        ; ファイル表示チェックボックスがフォーカスならトグル
        if (this.GuiObj.HasOwnProp("_autoFilesCheckHwnd") && currFocus = this.GuiObj._autoFilesCheckHwnd) {
            this.GuiObj["AutoFilesCheck"].Value := !this.GuiObj["AutoFilesCheck"].Value
            IniWrite(this.GuiObj["AutoFilesCheck"].Value ? "1" : "0", this.IniPath, "Settings", "AutoShowFiles")
            return
        }
        this.ShowActionMenu()
    }

    static _HandleLeftKey() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        currFocus := 0
        try currFocus := DllCall("user32\GetFocus", "ptr")
        if (this.GuiObj.HasOwnProp("_rootBtnHwnd") && currFocus = this.GuiObj._rootBtnHwnd) {
            this.GuiObj["ProfileBtn"].Focus()
        } else if (this.GuiObj.HasOwnProp("_searchTypeBtnHwnd") && currFocus = this.GuiObj._searchTypeBtnHwnd) {
            this.GuiObj["FilterToggle"].Focus()
        } else if (this.GuiObj.HasOwnProp("_treeFilterHwnd") && currFocus = this.GuiObj._treeFilterHwnd) {
            ; カーソルが先頭ならトグルボタンへ、そうでなければ通常の←（カーソル移動）
            sel := SendMessage(0x00B0, 0, 0, this.GuiObj["TreeFilter"])  ; EM_GETSEL
            if ((sel & 0xFFFF) = 0) {
                ; 検索モード中はSearchTypeBtnが表示されているのでそちらへ
                if (this._SearchMode && this.GuiObj.HasOwnProp("_searchTypeBtnHwnd"))
                    this.GuiObj["SearchTypeBtn"].Focus()
                else
                    this.GuiObj["FilterToggle"].Focus()
            } else
                Send "{Left}"
        } else if (this._tvHwnd != 0 && currFocus = this._tvHwnd) {
            PostMessage(0x0100, 0x25, 0, this._tvHwnd)  ; WM_KEYDOWN VK_LEFT: TreeView折りたたみ
            PostMessage(0x0101, 0x25, 0, this._tvHwnd)  ; WM_KEYUP
        }
    }

    static _HandleRightKey() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        currFocus := 0
        try currFocus := DllCall("user32\GetFocus", "ptr")
        if (this.GuiObj.HasOwnProp("_profileBtnHwnd") && currFocus = this.GuiObj._profileBtnHwnd)
            this.GuiObj["RootBtn"].Focus()
        else if (this.GuiObj.HasOwnProp("_filterToggleHwnd") && currFocus = this.GuiObj._filterToggleHwnd) {
            ; 検索モード中はSearchTypeBtnが表示されているのでそちらへ
            if (this._SearchMode && this.GuiObj.HasOwnProp("_searchTypeBtnHwnd"))
                this.GuiObj["SearchTypeBtn"].Focus()
            else
                this.GuiObj["TreeFilter"].Focus()
        } else if (this.GuiObj.HasOwnProp("_searchTypeBtnHwnd") && currFocus = this.GuiObj._searchTypeBtnHwnd)
            this.GuiObj["TreeFilter"].Focus()
        else if (this._tvHwnd != 0 && currFocus = this._tvHwnd) {
            PostMessage(0x0100, 0x27, 0, this._tvHwnd)  ; WM_KEYDOWN VK_RIGHT: TreeView展開
            PostMessage(0x0101, 0x27, 0, this._tvHwnd)  ; WM_KEYUP
        }
    }

    static _HandleRootBtnDown() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        currFocus := 0
        try currFocus := DllCall("user32\GetFocus", "ptr")
        if (this.GuiObj.HasOwnProp("_profileBtnHwnd") && currFocus = this.GuiObj._profileBtnHwnd) {
            ; プロファイルボタン → ツリーフィルター欄へ
            this.GuiObj["TreeFilter"].Focus()
        } else if (this.GuiObj.HasOwnProp("_rootBtnHwnd") && currFocus = this.GuiObj._rootBtnHwnd) {
            ; ルートボタン → ツリーフィルター欄へ
            this.GuiObj["TreeFilter"].Focus()
        } else if (this.GuiObj.HasOwnProp("_treeFilterHwnd") && currFocus = this.GuiObj._treeFilterHwnd) {
            ; ツリーフィルター欄 → ツリーへ
            this.GuiObj["FolderTree"].Focus()
        }
    }

    static ToggleFilesUnderSelection() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        tv := this.GuiObj["FolderTree"]
        id := tv.GetSelection()
        if (id = 0)
            return
        full := this._GetTVFullPath(tv, id)
        if (!DirExist(full)) {
            return
        }
        ; 既に表示済みなら削除
        if (this.FilesShown.Has(id)) {
            for _, cid in this.FilesShown[id] {
                try tv.Delete(cid)
            }
            this.FilesShown.Delete(id)
            ToolTip("Files hidden"), SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
            return
        }
        ; 表示（上限FileMax、既定200）
        fileMax := 200
        try fileMax := Integer(IniRead(this.IniPath, "Settings", "FileMax", "200"))
        shown := []
        count := 0
        loop files, full . "\*", "F" {
            if InStr(A_LoopFileAttrib, "H")
                continue
            fid := tv.Add(A_LoopFileName, id, "Icon2")
            shown.Push(fid)
            count += 1
            if (count >= fileMax)
                break
        }
        this.FilesShown[id] := shown
        ToolTip("Files shown: " . count), SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
    }

    /**
     * 選択中のファイル・フォルダと同一階層の詳細リストを表示
     */
    static ShowDetailList() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return

        ; 既に詳細リストウィンドウが表示されている場合は閉じる
        if (this.DetailListGuiObj && WinExist(this.DetailListGuiObj)) {
            this._CloseDetailListGui()
            return
        }

        tv := this.GuiObj["FolderTree"]
        id := tv.GetSelection()
        if (id = 0) {
            ToolTip("フォルダを選択してください")
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }

        selectedPath := this._GetTVFullPath(tv, id)

        ; フォルダでない場合は親フォルダを取得
        targetDir := ""
        if (DirExist(selectedPath)) {
            targetDir := selectedPath
        } else if (FileExist(selectedPath)) {
            SplitPath(selectedPath, , &parentDir)
            targetDir := parentDir
        } else {
            ToolTip("パスが見つかりません")
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }

        ; 詳細リスト用のGUIを作成
        this.GuiObj.GetPos(&gx, &gy, &gw, &gh)
        this.GuiObj.Opt("+Disabled")

        dlGui := Gui("+Owner" . this.GuiObj.Hwnd . " +Resize", "詳細リスト - " . targetDir)
        this.DetailListGuiObj := dlGui
        dlGui.SetFont("s10", "Yu Gothic UI")

        ; ListViewを作成（名前、種類、サイズ、作成日時、更新日時）
        lv := dlGui.Add("ListView", "r20 w900 Grid Sort", ["名前", "種類", "サイズ", "作成日時", "更新日時"])

        ; 同一階層のすべてのファイル・フォルダを取得
        itemCount := 0
        ; フォルダを先に追加
        loop files, targetDir . "\*", "D" {
            if (SubStr(A_LoopFileName, 1, 1) == "." || InStr(A_LoopFileAttrib, "H"))
                continue

            created := FormatTime(A_LoopFileTimeCreated, "yyyy/MM/dd HH:mm:ss")
            modified := FormatTime(A_LoopFileTimeModified, "yyyy/MM/dd HH:mm:ss")

            lv.Add(, A_LoopFileName, "<フォルダ>", "", created, modified)
            itemCount++
        }

        ; ファイルを追加
        loop files, targetDir . "\*", "F" {
            if (InStr(A_LoopFileAttrib, "H"))
                continue

            ; ファイルサイズを適切な単位で表示
            size := A_LoopFileSize
            sizeStr := ""
            if (size < 1024)
                sizeStr := size . " B"
            else if (size < 1048576)
                sizeStr := Round(size / 1024, 2) . " KB"
            else if (size < 1073741824)
                sizeStr := Round(size / 1048576, 2) . " MB"
            else
                sizeStr := Round(size / 1073741824, 2) . " GB"

            ; ファイル種類（拡張子）
            SplitPath(A_LoopFileName, , , &ext)
            fileType := (ext != "") ? "." . ext : "ファイル"

            created := FormatTime(A_LoopFileTimeCreated, "yyyy/MM/dd HH:mm:ss")
            modified := FormatTime(A_LoopFileTimeModified, "yyyy/MM/dd HH:mm:ss")

            lv.Add(, A_LoopFileName, fileType, sizeStr, created, modified)
            itemCount++
        }

        ; 列幅の自動調整
        lv.ModifyCol(1, 250)  ; 名前
        lv.ModifyCol(2, 100)  ; 種類
        lv.ModifyCol(3, 100)  ; サイズ
        lv.ModifyCol(4, 180)  ; 作成日時
        lv.ModifyCol(5, 180)  ; 更新日時

        ; ステータスバー
        dlGui.SetFont("s8")
        sb := dlGui.Add("StatusBar")
        sb.SetText(" [Space] アクションメニュー  /  [Enter] エクスプローラー  /  項目数: " . itemCount)

        ; 閉じるボタン
        dlGui.SetFont("s10")
        btnClose := dlGui.Add("Button", "w100 Default", "閉じる")
        btnClose.OnEvent("Click", (*) => this._CloseDetailListGui())

        ; ListViewイベント
        lv.OnEvent("DoubleClick", (obj, row) => (row ? this._ExecuteFromDetailList(dlGui, lv, row, targetDir, "e") : 0))

        ; ホットキー設定（詳細リストウィンドウアクティブ時のみ）
        HotIfWinActive("ahk_id " dlGui.Hwnd)
        Hotkey("Space", (*) => this._ShowDetailListActionMenu(dlGui, lv, targetDir), "On")
        Hotkey("Enter", (*) => this._ExecuteFromDetailList(dlGui, lv, lv.GetNext(), targetDir, "e"), "On")
        Hotkey("^d", (*) => this._CloseDetailListGui(), "On")
        Hotkey("Esc", (*) => this._CloseDetailListGui(), "On")
        HotIf()

        dlGui.OnEvent("Close", (*) => this._CloseDetailListGui())

        ; ウィンドウを親ウィンドウの右側に表示
        dlGui.Show("x" . (gx + gw + 10) . " y" . gy . " w920")
    }

    /**
     * 詳細リストからアクションメニューを表示
     */
    static _ShowDetailListActionMenu(dlGui, lv, targetDir) {
        row := lv.GetNext()
        if (row == 0) {
            ToolTip("項目を選択してください")
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }

        itemName := lv.GetText(row, 1)
        fullPath := targetDir . "\" . itemName

        if (!DirExist(fullPath) && !FileExist(fullPath)) {
            ToolTip("パスが見つかりません")
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }

        dlGui.GetPos(&gx, &gy, &gw, &gh)
        dlGui.Opt("+Disabled")

        actGui := Gui("+Owner" . dlGui.Hwnd . " -Caption +AlwaysOnTop +Border")
        actGui.BackColor := this.MENU_BG_COLOR
        actGui.MarginX := 10
        actGui.MarginY := 8

        actGui.SetFont("s8 w400 cA0A0A0", "Yu Gothic UI")
        actGui.Add("Text", "Center w" . this.MENU_BTN_W, itemName)

        actGui.SetFont("s9 w400 cWhite")
        ; レジストリに登録されたアクションからボタンを生成
        keys := []
        for k, _ in this.Actions
            keys.Push(k)
        ; ソート
        if (keys.Length > 1) {
            tmp := ""
            for _, kk in keys
                tmp .= kk . "`n"
            tmp := Sort(RTrim(tmp, "`n"))
            keys := StrSplit(tmp, "`n")
        }

        for k in keys {
            act := this.Actions[k]
            btn := actGui.Add("Button", "w" . this.MENU_BTN_W . " h" . this.MENU_BTN_H . " xm", act.label)
            btn.OnEvent("Click", ((kk, *) => (
                dlGui.Opt("-Disabled"),
                actGui.Destroy(),
                this._ExecuteFromDetailList(dlGui, lv, row, targetDir, kk)
            )).Bind(k))
        }

        btnCancel := actGui.Add("Button", "w" . this.MENU_BTN_W . " h" . this.MENU_BTN_H . " xm y+6", "&X: Cancel")
        btnCancel.OnEvent("Click", (*) => (dlGui.Opt("-Disabled"), actGui.Destroy()))
        actGui.OnEvent("Escape", (*) => (dlGui.Opt("-Disabled"), actGui.Destroy()))

        actGui.Show("AutoSize x" . gx + (gw - this.MENU_WIDTH) // 2 . " y" . gy + (gh - this.MENU_OFFSET_Y) // 2)
    }

    /**
     * 詳細リストから選択されたアイテムに対してアクションを実行
     */
    static _ExecuteFromDetailList(dlGui, lv, row, targetDir, key) {
        if (row == 0) {
            ToolTip("項目を選択してください")
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }

        itemName := lv.GetText(row, 1)
        fullPath := targetDir . "\" . itemName

        if (!DirExist(fullPath) && !FileExist(fullPath)) {
            ToolTip("パスが見つかりません")
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }

        ; 操作したパスとルート名をメモリに保存（ツリーと同じように）
        this.lastPath := fullPath

        this._ExecuteAction(key, fullPath)

        ; アクション実行後に詳細リストウィンドウを閉じる
        this._CloseDetailListGui()

        ; メインのNaviウィンドウも閉じる（ピン留めとShiftキーを考慮）
        if (this.GuiObj && WinExist(this.GuiObj)) {
            k := StrLower(key)
            ; 検索アクション(f)以外の場合
            if (k != "f") {
                ; ピン留めされていない、かつShiftキーが押されていない場合に閉じる
                if (!this.GuiObj["PinCheck"].Value && !GetKeyState("Shift", "P")) {
                    this._DestroyGui()
                }
            }
        }

        if (key != "k" && StrLower(key) != "f") {
            ToolTip("実行 [" . key . "]: " . fullPath)
            SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
        }
    }

    /**
     * 詳細リストウィンドウを閉じる
     */
    static _CloseDetailListGui() {
        if (this.DetailListGuiObj && WinExist(this.DetailListGuiObj)) {
            try this.DetailListGuiObj.Destroy()
            this.DetailListGuiObj := ""
        }
        if (this.GuiObj && WinExist(this.GuiObj)) {
            this.GuiObj.Opt("-Disabled")
            ; ツリーにフォーカスを戻す
            try {
                tv := this.GuiObj["FolderTree"]
                tv.Focus()
            }
        }
    }

    /**
     * 選択ファイルをNaviと同階層(ui)の一時フォルダにコピーし、既定アプリで開く
     * TempCopyライブラリを使用
     */
    static _OpenTempCopy(path) {
        TempCopy.Open(path)
    }

    /**
     * オーバーレイのリスト選択変更（クリック時）: ユーザーに見せるだけ。確定はEnter/ダブルクリック。
     */
    static _OnDropdownListChange() {
    }

    /**
     * ルート選択オーバーレイを開く（rootBtnクリックで起動）
     */
    static _OpenDropdown() {
        if (this.DropdownGui && WinExist(this.DropdownGui))
            return  ; すでに開いている
        if !(this.GuiObj && WinExist(this.GuiObj))
            return

        ; 全ルートをFilteredNamesにリセット
        this.FilteredNames := this._AllFolderNames.Clone()

        ; オーバーレイGUIを作成
        ddGui := Gui("+Owner" . this.GuiObj.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", "ルート選択")
        ddGui.MarginX := 8
        ddGui.MarginY := 8
        ddGui.SetFont("s10", "Yu Gothic UI")

        filterEdit := ddGui.Add("Edit", "xm w260 vOverlayFilter")
        try DllCall("user32\SendMessageW", "ptr", filterEdit.Hwnd, "uint", this.EM_SETCUEBANNER, "ptr", 1,
            "wstr", "名前でフィルター...", "ptr")

        ddList := ddGui.Add("ListBox", "xm w260 r8 vDDList", this.FilteredNames)

        ; lastRootを選択
        for i, n in this.FilteredNames {
            if (n == this.lastRoot) {
                ddList.Choose(i)
                break
            }
        }

        ddGui.SetFont("s8")
        ddGui.Add("Text", "xm w260 c808080", "↑↓: 移動  /  Enter: 選択  /  Esc: キャンセル")

        this.DropdownGui := ddGui

        filterEdit.OnEvent("Change", (*) => this._OverlayFilterChange())
        ddList.OnEvent("Change", (*) => this._OnDropdownListChange())
        ddList.OnEvent("DoubleClick", (*) => this._ConfirmDropdown())
        ddGui.OnEvent("Close", (*) => this._CloseDropdown())
        ; WM_ACTIVATE: wParam=0 でウィンドウが非アクティブになった時にオーバーレイを閉じる
        local ddHwnd    := ddGui.Hwnd
        local self      := this
        local wmActMsg2 := Navi.WM_ACTIVATE
        wmActivate(wParam, lParam, msg, hwnd) {
            if (hwnd = ddHwnd && wParam = 0) {
                OnMessage(wmActMsg2, wmActivate, 0)  ; 登録解除
                SetTimer(() => self._CloseDropdown(), -50)
            }
        }
        OnMessage(wmActMsg2, wmActivate)

        HotIfWinActive("ahk_id " ddGui.Hwnd)
        Hotkey("~Enter", (*) => this._ConfirmDropdown(), "On")
        Hotkey("Escape", (*) => this._CloseDropdown(), "On")
        Hotkey("~Down", (*) => this._OverlayNavDown(), "On")
        Hotkey("~Up", (*) => this._OverlayNavUp(), "On")
        HotIf()

        ; rootBtnの位置にオーバーレイを配置
        this.GuiObj.GetPos(&gx, &gy)
        this.GuiObj["RootBtn"].GetPos(&bx, &by, &bw, &bh)
        ddGui.Show("x" . (gx + bx) . " y" . (gy + by) . " w280 AutoSize")
    }

    /**
     * オーバーレイを閉じる（再入防止付き）
     */
    static _CloseDropdown() {
        if !(this.DropdownGui && WinExist(this.DropdownGui))
            return
        local ddGui := this.DropdownGui
        this.DropdownGui := ""  ; 先にクリアして再入防止
        try ddGui.Destroy()
    }

    /**
     * オーバーレイ選択を確定 → rootBtnを更新、ツリーを再描画してフォーカス移動
     */
    static _ConfirmDropdown() {
        ; IME変換中のEnterは無視（日本語フィルタ確定操作を妨げない）
        if (this.DropdownGui && WinExist(this.DropdownGui)) {
            filterHwnd := this.DropdownGui["OverlayFilter"].Hwnd
            hIMC := DllCall("imm32\ImmGetContext", "ptr", filterHwnd, "ptr")
            if (hIMC) {
                composing := DllCall("imm32\ImmGetCompositionStringW", "ptr", hIMC, "uint", 0x0008, "ptr", 0, "ptr", 0) > 0
                DllCall("imm32\ImmReleaseContext", "ptr", filterHwnd, "ptr", hIMC)
                if (composing)
                    return
            }
        }
        selectedTxt := ""
        if (this.DropdownGui && WinExist(this.DropdownGui)) {
            ddList := this.DropdownGui["DDList"]
            selectedTxt := ddList.Text
        }
        this._CloseDropdown()
        if (selectedTxt != "" && this._FolderMap.Has(selectedTxt) && this.GuiObj && WinExist(this.GuiObj)) {
            this._PushTabHistory()  ; 現在のルートを履歴に積んでから切り替え
            this.lastRoot := selectedTxt
            this.GuiObj["RootBtn"].Text := this._TruncRootLabel(selectedTxt)
            this.GuiObj["TreeFilter"].Value := ""
            tv := this.GuiObj["FolderTree"]
            this._RefreshTree(tv, this._FolderMap[selectedTxt])
            this._UpdateTabBar()  ; タブラベルに新ルート名を反映
        } else if (this.GuiObj && WinExist(this.GuiObj)) {
            WinActivate("ahk_id " this.GuiObj.Hwnd)
            this.GuiObj["FolderTree"].Focus()
        }
    }

    /**
     * ウィンドウリサイズ: 幅は全幅コントロールが追従、高さは TreeView が伸縮する
     * RootBtn 行（編集・ピン留め・ファイル表示）は固定のまま
     */
    static _OnResize(minmax, w, h) {
        if (minmax = -1 || !(this.GuiObj && WinExist(this.GuiObj)))
            return
        margin := this.GuiObj.MarginX
        ctrlW  := w - 2 * margin

        ; 全幅コントロールを幅に追従させる
        this.GuiObj["Breadcrumb"].Move(,, ctrlW)
        if (this._TabSepCtrl)
            this._TabSepCtrl.Move(0,, w)  ; 境界線はクライアント全幅
        ; TreeFilter は左端が FilterToggle(+SearchTypeBtn) 分ずれているので x 座標を考慮した幅にする
        this.GuiObj["TreeFilter"].GetPos(&_tfX_)
        this.GuiObj["TreeFilter"].Move(,, w - margin - _tfX_)

        ; TreeView は QuickPath と StatusBar の上まで高さを埋める
        sbH := 28  ; フォールバック値
        if (this.GuiObj.HasOwnProp("_sbRef"))
            this.GuiObj._sbRef.GetPos(,, , &sbH)
        qpH := this._quickPathH
        tvH := Max(60, h - this._tvY - qpH - sbH)
        this.GuiObj["FolderTree"].Move(,, ctrlW, tvH)
        ; QuickPath を TreeView 直下に追従
        this.GuiObj["QuickPath"].Move(, this._tvY + tvH, ctrlW, qpH)
    }

    /**
     * Escキー: オーバーレイが開いていれば閉じる（選択変更なし）、なければNaviを閉じる
     */
    static _HandleEsc() {
        if (this.DropdownGui && WinExist(this.DropdownGui)) {
            this._CloseDropdown()
            if (this.GuiObj && WinExist(this.GuiObj))
                WinActivate("ahk_id " this.GuiObj.Hwnd)
        } else if (this.GuiObj && WinExist(this.GuiObj) && this.GuiObj["TreeFilter"].Value != "") {
            ; ツリーフィルターにテキストがあればクリアしてツリーへフォーカス
            this.GuiObj["TreeFilter"].Value := ""
            this._ApplyTreeFilter("")
            this.GuiObj["FolderTree"].Focus()
        } else {
            this._DestroyGui()
        }
    }

    /**
     * オーバーレイのフィルターEdit変更: FilteredNamesを更新してリストに反映
     */
    static _OverlayFilterChange() {
        if !(this.DropdownGui && WinExist(this.DropdownGui))
            return
        query := this.DropdownGui["OverlayFilter"].Value
        this.FilteredNames := []
        for name in this._AllFolderNames {
            if (query = "" || InStr(name, query, false))
                this.FilteredNames.Push(name)
        }
        ddList := this.DropdownGui["DDList"]
        ddList.Delete()
        if (this.FilteredNames.Length > 0) {
            ddList.Add(this.FilteredNames)
            ddList.Choose(1)
        }
    }

    /**
     * オーバーレイのFilterEdit上でDown: リスト選択を1つ下に移動（ラップあり）
     */
    static _OverlayNavDown() {
        if !(this.DropdownGui && WinExist(this.DropdownGui))
            return
        try currFocus := DllCall("user32\GetFocus", "ptr")
        catch
            return
        if (currFocus != this.DropdownGui["OverlayFilter"].Hwnd)
            return  ; ListBoxにフォーカスがあれば~でネイティブ処理
        ddList := this.DropdownGui["DDList"]
        cur := ddList.Value
        total := this.FilteredNames.Length
        if (total = 0)
            return
        ddList.Choose((cur <= 0 || cur >= total) ? 1 : cur + 1)
    }

    /**
     * オーバーレイのFilterEdit上でUp: リスト選択を1つ上に移動（ラップあり）
     */
    static _OverlayNavUp() {
        if !(this.DropdownGui && WinExist(this.DropdownGui))
            return
        try currFocus := DllCall("user32\GetFocus", "ptr")
        catch
            return
        if (currFocus != this.DropdownGui["OverlayFilter"].Hwnd)
            return
        ddList := this.DropdownGui["DDList"]
        cur := ddList.Value
        total := this.FilteredNames.Length
        if (total = 0)
            return
        ddList.Choose((cur <= 1) ? total : cur - 1)
    }

    static _InitDefaultActions() {
        this.RegisterAction("e", "&E: Explorer", (path) => (
            DirExist(path) || SplitPath(path, , &path),
            this._ActivateOrOpenExplorer(path)
        ))
        this.RegisterAction("t", "&t: Preferred Explorer", (path) => (
            DirExist(path) || SplitPath(path, , &path),
            (this.ExplorerPath == "explorer.exe")
                ? Run('explorer.exe "' . path . '"')
                : (FileExist(this.ExplorerPath) ? Run('"' . this.ExplorerPath . '" "' . path . '"') : 0)
        ))
        this.RegisterShellAction("v", "&V: VS Code", A_ComSpec . ' /c code "{path}"', "Hide")
        this.RegisterShellAction("c", "&C: Command Prompt", A_ComSpec . ' /K cd /d "{path}"')
        this.RegisterShellAction("p", "&P: PowerShell",
            'powershell.exe -NoExit -Command Set-Location -LiteralPath "{path}"')
        this.RegisterAction("k", "&K: Copy Path", (path) => (A_Clipboard := path, ToolTip("Path Copied: " . path),
            SetTimer(() => ToolTip(), -this.TOOLTIP_COPY_DURATION)))
        ; ファイル/フォルダ名のみをコピー
        this.RegisterAction("n", "&N: Copy Name", (path) => (
            SplitPath(path, &fn),
            name := (fn != "" ? fn : path),
            A_Clipboard := name,
            ToolTip("Name Copied: " . name),
            SetTimer(() => ToolTip(), -this.TOOLTIP_COPY_DURATION)
        ))
        ; 一時コピーを作成して開く
        this.RegisterAction("o", "&O: Open Temp Copy", (path) => this._OpenTempCopy(path))
        ; ローカル再帰検索
        this.RegisterAction("f", "&F: Search (Local)", (path) => NaviSearch.RunLocal(this, path))
        ; Shell 右クリックメニュー
        this.RegisterAction("r", "&R: Right-Click Menu", (path) => NaviContextMenu.Show(path, this))
    }

    ; 右クリック: TreeView 上のアイテムを選択して Shell コンテキストメニューを表示
    static _HandleRButton() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        tv := this.GuiObj["FolderTree"]
        MouseGetPos(,,,&underHwnd, 2)
        if (underHwnd != tv.Hwnd)
            return
        ; 右クリック後に選択が確定するよう 1 tick 待つ
        SetTimer(() => (
            id := tv.GetSelection(),
            id ? NaviContextMenu.Show(this._GetTVFullPath(tv, id), this) : 0
        ), -1)
    }

    static _LoadUserActions() {
        try {
            content := IniRead(this.IniPath, "Actions", , "")
            for line in StrSplit(content, "`n", "`r") {
                if !InStr(line, "=")
                    continue
                kv := StrSplit(line, "=", , 2)
                key := Trim(kv[1])
                parts := StrSplit(Trim(kv[2]), "|")
                if (parts.Length >= 3) {
                    label := parts[1]
                    kind := StrLower(parts[2])
                    if (kind = "shell") {
                        cmd := parts[3]
                        opt := (parts.Length >= 4) ? parts[4] : ""
                        this.RegisterShellAction(key, label, cmd, opt)
                    }
                }
            }
        }
    }
}
