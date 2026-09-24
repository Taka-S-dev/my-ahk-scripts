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
;   #Include ui\navi\Navi.ahk
;   Navi.Init()
;   vk1D & f:: Navi.Show() ; 無変換 + f で起動
;
; ==============================================================================
#Requires AutoHotkey v2.0
#Include *i Navi.Theme.ahk
#Include *i Navi.TreeDraw.ahk
#Include *i Navi.Search.ahk
#Include *i Navi.ContextMenu.ahk
#Include *i Navi.Action.ahk
#Include *i Navi.Filter.ahk
#Include *i Navi.Tab.ahk
#Include *i Navi.Profile.ahk
#Include *i Navi.DetailList.ahk
#Include *i Navi.Breadcrumb.ahk
#Include *i Navi.Mark.ahk
#Include *i Navi.DirList.ahk
#Include *i Navi.Leader.ahk
#Include *i Navi.Picker.ahk
#Include ..\..\lib\TempCopy.ahk

class Navi {
    ; --- クラス定数 ---
    static GUI_WIDTH := 600
    static STATUS_LEFT_W := 210      ; ステータスバー左側（表示と件数）の幅
    static GUI_HEIGHT_APPROX := 565
    static _savedW := 0
    static _savedH := 0
    static WINDOW_FRAME_WIDTH := 14  ; ウィンドウフレーム補正値（Win10/11標準テーマ）
    static IniPath := A_ScriptDir "\ui\navi\Navi.ini"
    static ExplorerPath := ""
    static TOOLTIP_ERROR_DURATION := 2000
    static TOOLTIP_SUCCESS_DURATION := 1000
    static TOOLTIP_COPY_DURATION := 2000
    static TEMP_DIR_SUBPATH := "\temp"
    static TEMP_PREFIX := "TEMP_"

    ; --- アクションメニュー用の定数 ---
    static MENU_WIDTH := 210       ; メニューの幅
    static MENU_BTN_W := 190       ; ボタンの幅
    static MENU_BTN_H := 26        ; ボタンの高さ
    static MENU_OFFSET_Y := 240    ; 中央配置の計算用オフセット

    ; --- 位置決定用の定数 ---
    static CARET_OFFSET_X := 5     ; キャレットからのXオフセット
    static CARET_GAP_Y := 25       ; キャレット下に表示する際の縦方向ギャップ
    static SCREEN_MARGIN := 10     ; 画面端からのマージン
    static MOUSE_OFFSET := 15      ; マウス位置からのオフセット

    ; --- セッション内メモリ ---
    static lastRoot := ""
    static lastPath := ""
    static GuiObj := ""
    static QuickPathHwnd := 0
    static _TreeFilterFocused := false
    static FilesShown := Map()
    static _EnsureSelectionVisibleRetries := 0  ; Show 後の選択スクロールリトライ回数
    static _RestoreTargetPath := ""             ; Show 後にリトライ復元する目標パス
    ; 詳細リスト関連状態は NaviDetailList クラスで管理（Navi.DetailList.ahk）
    ; パンくず関連定数・状態は NaviBreadcrumb クラスで管理（Navi.Breadcrumb.ahk）
    static _AllFolderNames := []  ; 全ルート名リスト（フィルタ前）
    static _FolderMap := Map()    ; ルート名→パスマップ
    static _addRootGui := ""             ; ルートを追加する小窓
    static _addRootBrowsing := false     ; 「…」でフォルダ選択ダイアログを開いている間 true
    ; プロファイル関連状態は NaviProfile クラスで管理（Navi.Profile.ahk）
    ; フィルタ関連状態は NaviFilter クラスで管理（Navi.Filter.ahk）
    ; マーク関連状態・定数は NaviMark クラスで管理（Navi.Mark.ahk）

    ; --- アイコン管理 ---
    static _ILHandle := 0           ; TreeView 用 ImageList ハンドル
    static _IconCache := Map()       ; 拡張子→ImageList インデックスキャッシュ
    static _ILNextIdx := 5           ; 次に追加するアイコンのインデックス（1-4 は固定枠）
    static _tvY := 0                  ; TreeView の Y 座標（リサイズ計算用）
    static _tvHwnd := 0        ; TreeView の Hwnd
    static _SearchMode := false  ; フィルター欄の動作モード（false=フォルダフィルター / true=ファイル検索）
    static _SearchTypeFilter := "all"  ; 検索対象種別（"all" / "dir" / "file"）

    ; --- Windows API メッセージ定数 ---
    static WM_SETCURSOR := 0x0020   ; カーソル形状変更通知
    static WM_ACTIVATE := 0x0006   ; ウィンドウアクティブ状態変更
    static WM_SETTEXT := 0x000C   ; コントロールテキスト設定（プレースホルダー等）
    static WM_NOTIFY := 0x004E   ; コモンコントロール通知（カスタムドロー等）
    static EM_SETCUEBANNER := 0x1501  ; Edit コントロールのプレースホルダーテキスト設定

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
        NaviActions.Init(this)
        NaviFilter.Init(this)
        NaviTab.Init(this)
        NaviProfile.Init(this)
        NaviDetailList.Init(this)
        NaviBreadcrumb.Init(this)
        NaviMark.Init(this)
        NaviDirList.Init(this)
        NaviLeader.Init(this)
    }

    static Show() {
        if (this.ExplorerPath == "") {
            this.Init()
        }

        if (this.GuiObj && WinExist(this.GuiObj)) {
            if WinActive(this.GuiObj) {
                this.GuiObj.Minimize()
            } else {
                this.GuiObj.Show()
                WinActivate(this.GuiObj)
                this.GuiObj["TreeFilter"].Focus()
            }
            return
        }
        this.GuiObj := ""

        this.GuiObj := Gui("+AlwaysOnTop +Resize", "Navi")
        this.GuiObj.BackColor := NaviTheme.BG
        NaviTheme.SetFont(this.GuiObj, "body")

        folderMap := Map(), folderNames := []
        this._LoadFolders(folderMap, folderNames)
        NaviTab.LoadTabsFromIni()  ; タブ状態を INI から復元（_TabCount が確定するのでタブバー生成前に呼ぶ）

        chooseIdx := 1
        for i, name in folderNames {
            if (name == this.lastRoot) {
                chooseIdx := i
                break
            }
        }

        ; --- タブバー（最上部）---
        _tabBarTopY_ := NaviTab.BuildTabBar(this.GuiObj)
        NaviTheme.SetFont(this.GuiObj, "body")

        ; --- ヘッダー行 ---
        ; 「今どこを見ているか」（プロファイル › ルート）だけを左に置き、設定類は右端の ⚙ メニューにまとめる
        ; 0x100=BS_LEFT: 選択欄として読めるよう文字を左寄せにする
        sp := NaviTheme.SP_S
        rootBtnText := this._TruncRootLabel(this.lastRoot)
        btnProfile := this.GuiObj.Add("Button", "xm y+" . sp . " w95 h" . NaviTheme.CONTROL_H . " -Tabstop +0x100 vProfileBtn"
            , NaviProfile.GetProfileBtnText())
        this.GuiObj._profileBtnHwnd := btnProfile.Hwnd
        ; › セパレーターで階層を表現
        NaviTheme.SetFont(this.GuiObj, "body", NaviTheme.TEXT_SUBTLE)
        this.GuiObj.Add("Text", "x+3 yp w14 h" . NaviTheme.CONTROL_H . " +0x201 vProfileSep", "›")  ; SS_CENTER|SS_NOTIFY
        NaviTheme.SetFont(this.GuiObj, "body")
        ; ルートは主役なので ⚙ の手前まで伸ばす（幅は _OnResize で窓に合わせる）
        rootBtn := this.GuiObj.Add("Button", "x+3 yp w" . (455 - 95 - 3 - 14 - 3 - sp - NaviTheme.CONTROL_H)
            . " h" . NaviTheme.CONTROL_H . " +0x100 vRootBtn", rootBtnText)
        this.GuiObj._rootBtnHwnd := rootBtn.Hwnd
        btnSettings := this.GuiObj.Add("Button", "x+" . sp . " yp w" . NaviTheme.CONTROL_H . " h" . NaviTheme.CONTROL_H
            . " -Tabstop vSettingsBtn")
        NaviTheme.SetIcon(btnSettings, NaviTheme.ICON_SETTINGS)
        this.GuiObj._btnSettingsCtrl := btnSettings
        ; 以下は表示しない。ピン留め・ファイル表示の状態の置き場として残し（各所が .Value を読む）、
        ; 切り替えは ⚙ メニュー・コマンド一覧・Ctrl+P から行う
        pinCheck := this.GuiObj.Add("Checkbox", "xp yp vPinCheck -Tabstop", "ピン留め")
        pinCheck.Visible := false
        autoFilesCheck := this.GuiObj.Add("Checkbox", "xp yp vAutoFilesCheck -Tabstop", "ファイル表示")
        autoFilesCheck.Visible := false
        autoFilesCheck.Value := (IniRead(this.IniPath, "Settings", "AutoShowFiles", "0") == "1")
        this._AllFolderNames := folderNames
        this._FolderMap := folderMap

        ; --- パンくずリスト ---
        NaviTheme.SetFont(this.GuiObj, "body", NaviTheme.TEXT_MUTED)
        ; 直前は非表示の小さな部品なので、ヘッダー行の下端から位置を決める
        btnProfile.GetPos(, &_hdrY_, , &_hdrH_)
        breadcrumb := this.GuiObj.Add("Text", "xm y" . (_hdrY_ + _hdrH_ + sp) . " w455 h" . NaviBreadcrumb.BREADCRUMB_HEIGHT . " vBreadcrumb +0x8100", "")  ; SS_NOTIFY(0x100)|SS_PATHELLIPSIS(0x8000)
        breadcrumb.OnEvent("Click", (*) => NaviBreadcrumb._OnClick())
        NaviBreadcrumb._hwnd := breadcrumb.Hwnd
        OnMessage(this.WM_SETCURSOR, NaviBreadcrumb._OnSetCursor.Bind(NaviBreadcrumb))
        OnMessage(this.WM_SETCURSOR, NaviTab._OnSetCursor.Bind(NaviTab))
        NaviTheme.SetFont(this.GuiObj, "body")

        ; --- ツリーフィルター入力欄（モードトグルボタン付き）---
        filterToggle := this.GuiObj.Add("Button", "xm y+" . sp . " w28 h22 -Tabstop vFilterToggle")
        NaviTheme.SetIcon(filterToggle, NaviTheme.ICON_FOLDER)
        filterToggle.OnEvent("Click", (*) => this._ToggleSearchMode())
        this.GuiObj._filterToggleHwnd := filterToggle.Hwnd
        searchTypeBtn := this.GuiObj.Add("Button", "x+3 yp w28 h22 -Tabstop vSearchTypeBtn")
        NaviTheme.SetIcon(searchTypeBtn, NaviTheme.ICON_ALL)
        searchTypeBtn.OnEvent("Click", (*) => this._CycleSearchType())
        searchTypeBtn.Visible := false
        this.GuiObj._searchTypeBtnHwnd := searchTypeBtn.Hwnd
        ; 初期はフィルターモード: x=39, w=424(右端=TreeViewと同じ463)
        treeFilter := this.GuiObj.Add("Edit", "x39 yp w424 vTreeFilter -Tabstop", "")
        ; セッション中に検索モードだった場合は復元
        if (this._SearchMode) {
            filterToggle.Text := NaviTheme.ICON_SEARCH
            searchTypeBtn.Visible := true
            searchTypeBtn.Text := (this._SearchTypeFilter = "dir") ? NaviTheme.ICON_FOLDER
                : (this._SearchTypeFilter = "file") ? NaviTheme.ICON_FILE : NaviTheme.ICON_ALL
            treeFilter.Move(70, , 393)  ; 幅は後の _OnResize で正確に調整される
        }
        cue := this._SearchMode ? "ファイルを検索... (Enter で実行)" : "フォルダをフィルター..."
        try DllCall("user32\SendMessageW", "ptr", treeFilter.Hwnd, "uint", this.EM_SETCUEBANNER, "ptr", 1,
            "wstr", cue, "ptr")
        treeFilter.OnEvent("Change", (*) => NaviFilter.OnTreeFilterChange())
        treeFilter.OnEvent("Focus", (*) => (Navi._TreeFilterFocused := true))
        treeFilter.OnEvent("LoseFocus", (*) => (Navi._TreeFilterFocused := false))
        this.GuiObj._treeFilterHwnd := treeFilter.Hwnd

        ; --- TreeView ---
        ; 点線の代わりにインデントガイドを描き（NaviTreeDraw）、行全体を選択（0x1000=TVS_FULLROWSELECT）
        ; 0x4=TVS_LINESATROOT: ルートにも開閉矢印を付け、ガイドの位置を全階層でそろえる
        tv := this.GuiObj.Add("TreeView", "xm y+" . sp . " w455 r15 vFolderTree -Lines +0x1004")
        this._SetupTreeIcons(tv)
        this._tvHwnd := tv.Hwnd
        this._ApplyExplorerTheme(tv)
        SendMessage(0x112C, 0x4, 0x4, tv)                 ; TVM_SETEXTENDEDSTYLE: TVS_EX_DOUBLEBUFFER
        NaviTreeDraw.Attach(tv)  ; 文字色・選択行・インデントガイド

        ; --- フォルダ一覧（ツリーと同じ場所に重ね、Ctrl+E で切り替え）---
        NaviDirList.Build(this.GuiObj, tv)

        ; --- ルート登録用の入力欄 ---
        ; 常に出すと 2 つ目の検索欄に見えて迷うので表示しない。ルートの追加は ⚙ メニューのフォルダ選択から行い、
        ; 選んだパスをこの欄に入れて既存の登録処理（_QuickRegisterFromEdit）に渡す
        quickEdit := this.GuiObj.Add("Edit", "xm w455 h1 vQuickPath -Tabstop", "")
        quickEdit.Visible := false
        this.QuickPathHwnd := quickEdit.Hwnd

        ; ステータスバーによる操作案内
        NaviTheme.SetFont(this.GuiObj, "caption")
        ; 左: 今の表示と件数 / 右: 操作の案内
        sb := this.GuiObj.Add("StatusBar")
        sb.SetParts(this.STATUS_LEFT_W)
        this.GuiObj._sbRef := sb
        this._UpdateStatusBar()

        ; リサイズ計算用に TreeView・RootBtn の位置を記録
        tv.GetPos(, &_tvY_)
        this._tvY := _tvY_
        ; タブバー非表示時のシフト量を確定（ヘッダーY - タブバー開始Y）
        btnProfile.GetPos(, &_headerY_)
        NaviTab._tabBarShift := _headerY_ - _tabBarTopY_
        NaviTab._tabBarVisible := true  ; タブバーは 1 枚のときも常に表示する（ブラウザ・VSCode と同じ）

        ; ウィンドウリサイズイベント登録
        this.GuiObj.OnEvent("Size", (g, mm, w, h) => this._OnResize(mm, w, h))

        rootBtn.OnEvent("Click", (*) => this._OpenDropdown())
        btnSettings.OnEvent("Click", (*) => this._ShowSettingsMenu())
        btnProfile.OnEvent("Click", (*) => NaviProfile.OpenProfileDropdown())
        tv.OnEvent("ItemExpand", (obj, id, *) => this._OnItemExpand(obj, id))
        tv.OnEvent("DoubleClick", (obj, id, *) => this._HandleActivate())
        this.GuiObj.OnEvent("Close", (*) => this._OnXClose())

        ; ホットキー設定（Naviアクティブ時のみ）
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Space", (*) => this._HandleSpace(), "On")
        Hotkey("Enter", (*) => this._HandleEnter(), "On")
        Hotkey("^Enter", (*) => this.ToggleFilesUnderSelection(), "On")
        Hotkey("^p", (*) => this._TogglePin(), "On")
        Hotkey("^d", (*) => NaviDetailList.Show(), "On")
        Hotkey("^f", (*) => this.GuiObj["TreeFilter"].Focus(), "On")
        Hotkey("^e", (*) => NaviDirList.Toggle(), "On")
        ; コマンド一覧（Navi の中ではグローバルの日付入力より優先される）
        Hotkey("^;", (*) => NaviLeader.Show(), "On")
        ; Ctrl+H/J/K/L は Vim と同じく ←↓↑→（Ctrl+H はグローバルの HotstringManager より優先される）
        Hotkey("^h", (*) => this._HandleCtrlArrow("h"), "On")
        Hotkey("^j", (*) => this._HandleCtrlArrow("j"), "On")
        Hotkey("^k", (*) => this._HandleCtrlArrow("k"), "On")
        Hotkey("^l", (*) => this._HandleCtrlArrow("l"), "On")
        Hotkey("F3",  (*) => NaviFilter.JumpToMatch(this.GuiObj["FolderTree"], +1), "On")
        Hotkey("+F3", (*) => NaviFilter.JumpToMatch(this.GuiObj["FolderTree"], -1), "On")
        Hotkey("F1", (*) => this._ShowHelp(), "On")
        Hotkey("Esc", (*) => this._HandleEsc(), "On")
        Hotkey("Down", (*) => this._HandleRootBtnDown(), "On")
        Hotkey("Left", (*) => this._HandleLeftKey(), "On")
        Hotkey("Right", (*) => this._HandleRightKey(), "On")
        Hotkey("RButton", (*) => this._HandleRButton(), "On")
        Hotkey("!m",  (*) => NaviMark._ToggleMark(), "On")
        Hotkey("^m",  (*) => NaviMark._ToggleMarkFilter(), "On")
        Hotkey("!+m", (*) => NaviMark._ClearAllMarks(), "On")
        NaviTab.RegisterHotkeys()
        HotIf()

        ; パンくず更新用タイマー開始
        NaviBreadcrumb.StartWatcher()

        if (folderNames.Length > 0) {
            ; タブ状態が保存されていれば復元、なければデフォルト初期化
            if (!NaviTab.RestoreCurrentTab(tv)) {
                selectedRoot := (this.lastRoot != "" && folderMap.Has(this.lastRoot)) ? this.lastRoot : folderNames[1]
                this.lastRoot := selectedRoot
                this.GuiObj["RootBtn"].Text := this._TruncRootLabel(selectedRoot)
                this._RefreshTree(tv, folderMap[selectedRoot])
                if (this.lastPath != "") {
                    this._FocusPath(tv, this.lastPath)
                }
            }
            NaviBreadcrumb.Refresh()
            NaviTab.UpdateTabBar()
            this._UpdateStatusBar()
        }

        ; マウスカーソルがあるモニタの作業領域中央に配置
        CoordMode "Mouse", "Screen"
        MouseGetPos(&mX, &mY)
        monitorNum := this._GetMonitorFromPos(mX, mY)
        MonitorGetWorkArea(monitorNum, &waL, &waT, &waR, &waB)

        winW := (this._savedW > 0 ? this._savedW : this.GUI_WIDTH + this.WINDOW_FRAME_WIDTH)
        winH := (this._savedH > 0 ? this._savedH : this.GUI_HEIGHT_APPROX)
        centerX := waL + (waR - waL - winW) // 2
        centerY := waT + (waB - waT - winH) // 2

        NaviDirList.ApplyVisibility()
        this.GuiObj.Show("x" . centerX . " y" . centerY . " w" . winW . " h" . winH)
        ; 一覧の作成は WinExist が通る表示後に行う
        NaviDirList.ApplyCurrent()
        ; GUI 表示後に選択項目を再度可視化（フィルタの非同期処理を考慮して複数回リトライ）
        this._EnsureSelectionVisibleRetries := 0
        this._EnsureSelectionVisible()
        this.GuiObj["TreeFilter"].Focus()
    }

    /**
     * 選択項目を可視範囲にスクロール（フィルタ非同期完了を待つため最大 10 回リトライ）
     * 復元目標パスがあれば、選択が一致するまで _FocusPath をリトライする
     */
    static _EnsureSelectionVisible() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        tv := this.GuiObj["FolderTree"]
        targetPath := this._RestoreTargetPath
        if (targetPath != "") {
            ; 現在の選択が目標パスと一致しているかチェック
            selId := tv.GetSelection()
            matched := false
            if (selId) {
                try {
                    if (StrLower(this._GetTVFullPath(tv, selId)) == StrLower(targetPath))
                        matched := true
                }
            }
            if (matched) {
                tv.Modify(selId, "Vis")
                this._RestoreTargetPath := ""
                return
            }
            ; まだ一致してない → _FocusPath で再試行
            if (DirExist(targetPath) || FileExist(targetPath))
                this._FocusPath(tv, targetPath)
        } else {
            ; 復元目標なし → 現在の選択を可視化するだけ
            selId := tv.GetSelection()
            if (selId) {
                tv.Modify(selId, "Vis")
                return
            }
        }
        if (++this._EnsureSelectionVisibleRetries < 10)
            SetTimer(this._EnsureSelectionVisible.Bind(this), -100)
        else
            this._RestoreTargetPath := ""  ; リトライ上限 → 諦める
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
        ; リスト表示中は隠れているツリーにフォーカスを移さない
        if (!NaviDirList.Active)
            tv.Focus()
    }

    ; X ボタンで閉じた場合: GUI は AHK が破棄するため Destroy は不要
    static _OnXClose() {
        this._CleanupState()
        this.GuiObj := ""
    }

    static _DestroyGui() {
        this._CleanupState()
        if (this.GuiObj && WinExist(this.GuiObj)) {
            this.GuiObj.GetPos(, , &_w_, &_h_)
            if (_w_ > 0 && _h_ > 0) {
                this._savedW := _w_
                this._savedH := _h_
            }
            ; 検索ウィンドウなど付随UIも確実に閉じる
            try NaviSearch._DestroyJumpGui()
            NaviPicker.Close(false)
            this.GuiObj.Destroy()
            this.GuiObj := ""
        }
    }

    ; GUI 破棄・クローズ共通クリーンアップ（タブ保存・タイマー停止・状態リセット）
    static _CleanupState() {
        ; 現在のタブ状態を保存してから破棄（次回起動時に復元できるようにする）
        NaviTab.SaveCurrentTab()
        NaviTab.SaveTabsToIni()
        ; パンくず監視タイマーを停止
        NaviBreadcrumb.StopWatcher()
        ; フィルタータイマー・ディレクトリ監視・インデックスをリセット
        ; _IndexedRoot を残すと次回起動時に _EnsureIndex が「有効」と誤判定し
        ; _StartDirWatch が呼ばれないまま古いインデックスを使い続ける
        NaviFilter.CancelDebounce()
        NaviFilter.ResetForNewRoot()
        NaviDirList.CancelFileIndex()
        NaviLeader.Close(false)
        ; マーク状態をリセット
        NaviMark.Reset()
        ; プロファイルドロップダウンを閉じる
        NaviPicker.Close(false)
        ; 詳細リスト参照をリセット（+Owner で親破棄時に自動クローズされるため Destroy 不要）
        NaviDetailList._guiObj := ""
        ; タブボタンコントロールはGUI依存のためリセット（タブ状態は次回起動時に再利用）
        NaviTab.Cleanup()
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
              Ctrl+;        コマンド一覧（1 文字で実行）
              Ctrl+E        ツリー ↔ 一覧
              Ctrl+H/J/K/L  ←↓↑→（Vim と同じ）

            【一覧】
              Shift+Tab     フォルダ一覧 ↔ ファイル一覧
              文字入力      あいまい一致で絞り込み（'word は続けて一致）
              ↑↓ PgUp/Dn   入力欄のまま選択行を移動（Ctrl+J/K も同じ）
              Enter         フォルダはエクスプローラーで、ファイルは関連付けアプリで開く
              → / Ctrl+L    選択行をツリーで表示

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

    static _ShowEditGui(parentGui) {
        parentGui.GetPos(&px, &py, &pw, &ph)
        parentGui.Opt("+Disabled")
        editGui := Gui("+Owner" . parentGui.Hwnd . " +AlwaysOnTop -MinimizeBox +Resize", "ルートディレクトリ編集")
        NaviTheme.ApplyPopup(editGui)
        ; --- プロファイル管理 GroupBox（最上部）---
        profBox := editGui.Add("GroupBox", "xm w550 h54", "プロファイル管理")
        profNames := NaviProfile.GetProfileList()
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
        profDDL.OnEvent("Change", (*) => NaviProfile.LoadProfileIntoLV(lv, editGui["EditProfileDDL"].Text))
        btnProfNew.OnEvent("Click", (*) => NaviProfile.NewProfileDialogFromEdit(editGui))
        btnProfDup.OnEvent("Click", (*) => NaviProfile.DupProfileDialogFromEdit(editGui, lv))
        btnProfDel.OnEvent("Click", (*) => NaviProfile.DeleteProfileFromEdit(editGui))
        btnProfRen.OnEvent("Click", (*) => NaviProfile.RenameProfileFromEdit(editGui))
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
        lvClientW := NumGet(rc, 8, "int")
        initPathColW := lvClientW - 120 - 50
        lv.ModifyCol(2, initPathColW)
        profBox.GetPos(, , &initProfBoxW)

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
            profBox.Move(, , initProfBoxW + dw)
            for i, ctrl in vertCtrls
                ctrl.Move(, vertY[i] + dh)
        }

        editGui.Show("x" . px + (pw - initW) // 2 . " y" . py + (ph - initH) // 2)
    }

    static _ShowSettingsGui(parentGui) {
        parentGui.GetPos(&px, &py, &pw, &ph)
        parentGui.Opt("+Disabled")
        settGui := Gui("+Owner" . parentGui.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", "Navi 設定")
        NaviTheme.ApplyPopup(settGui)
        settGui.MarginX := NaviTheme.SP_L

        ; --- 外部ファイラー ---
        NaviTheme.SetFont(settGui, "heading")
        settGui.Add("Text", "xm", "外部ファイラー")
        NaviTheme.SetFont(settGui, "body")
        explorerPath := IniRead(this.IniPath, "Settings", "ExplorerPath", "explorer.exe")
        useDefaultCb := settGui.Add("CheckBox", "xm y+8", "標準エクスプローラーを使用する")
        useDefaultCb.Value := (explorerPath == "explorer.exe") ? 1 : 0
        explorerEdit := settGui.Add("Edit", "xm y+6 w320", explorerPath == "explorer.exe" ? "" : explorerPath)
        explorerEdit.Enabled := (explorerPath != "explorer.exe")
        btnBrowseExplorer := settGui.Add("Button", "x+4 yp w40 h26", "...")
        btnBrowseExplorer.Enabled := (explorerPath != "explorer.exe")
        useDefaultCb.OnEvent("Click", (*) => (
            useDefaultCb.Value ? (explorerEdit.Enabled := false, btnBrowseExplorer.Enabled := false)
            : (explorerEdit.Enabled := true, btnBrowseExplorer.Enabled := true)
        ))
        btnBrowseExplorer.OnEvent("Click", (*) => (
            sel := FileSelect(3, explorerEdit.Value, "ファイラーを選択", "(*.exe)"),
            sel != "" ? explorerEdit.Value := sel : 0
        ))

        ; --- 動作 ---
        settGui.Add("Text", "xm y+14 w400 0x10")
        NaviTheme.SetFont(settGui, "heading")
        settGui.Add("Text", "xm y+10", "動作")
        NaviTheme.SetFont(settGui, "body")
        autoMinCb := settGui.Add("CheckBox", "xm y+8", "アクション実行後に自動最小化する（ピン留めON時は無効）")
        autoMinCb.Value := (IniRead(this.IniPath, "Settings", "AutoMinimizeOnAction", "0") == "1") ? 1 : 0

        ; --- フォルダフィルター ---
        settGui.Add("Text", "xm y+14 w400 0x10")
        NaviTheme.SetFont(settGui, "heading")
        settGui.Add("Text", "xm y+10", "フォルダフィルター")
        NaviTheme.SetFont(settGui, "body")
        fdFilterCb := settGui.Add("CheckBox", "xm y+8", "高速化する（fd.exe が必要）")
        fdFilterCb.Value := (IniRead(this.IniPath, "Search", "UseFdForFilter", "1") != "0") ? 1 : 0
        settGui.Add("Text", "xm y+10", "最大階層深度（0 = 無制限）:")
        depthEdit := settGui.Add("Edit", "x+8 yp-2 w50 Number", IniRead(this.IniPath, "Search", "FilterMaxDepth", "8"))

        ; --- OK ボタン ---
        settGui.Add("Text", "xm y+14 w400 0x10")
        btnOK := settGui.Add("Button", "xm y+10 w80 Default", "OK")
        btnOK.OnEvent("Click", (*) => (
            this.ExplorerPath := useDefaultCb.Value ? "explorer.exe" : explorerEdit.Value,
            IniWrite(this.ExplorerPath, this.IniPath, "Settings", "ExplorerPath"),
            IniWrite(autoMinCb.Value, this.IniPath, "Settings", "AutoMinimizeOnAction"),
            IniWrite(fdFilterCb.Value, this.IniPath, "Search", "UseFdForFilter"),
            IniWrite(depthEdit.Value, this.IniPath, "Search", "FilterMaxDepth"),
            settGui.Destroy(),
            parentGui.Opt("-Disabled +AlwaysOnTop"),
            parentGui.Show()
        ))

        _close := (*) => (settGui.Destroy(), parentGui.Opt("-Disabled +AlwaysOnTop"), parentGui.Show())
        settGui.OnEvent("Close", _close)
        HotIfWinActive("ahk_id " settGui.Hwnd)
        Hotkey("Esc", _close, "On")
        HotIf()
        settGui.Show("Hide")
        settGui.GetPos(, , &sw, &sh)
        settGui.Show("x" . px + (pw - sw) // 2 . " y" . py + (ph - sh) // 2)
        btnOK.Focus()
    }

    static _ShowEntryGui(editGui, lv, row := 0) {
        editGui.GetPos(&ex, &ey, &ew, &eh), editGui.Opt("+Disabled")
        entryGui := Gui("+Owner" . editGui.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", row ? "項目の修正" : "項目の追加")
        NaviTheme.ApplyPopup(entryGui)
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
            NaviProfile.WriteProfileFile(lv, lastProfile)
        ; GUI が開いていればインプレース更新、なければ再起動
        if (this.GuiObj && WinExist(this.GuiObj)) {
            if (editGui != "")
                this._CleanupEditGui(parentGui, editGui)
            NaviProfile.ReloadProfileInPlace()
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
        SHGSI_ICON := 0x100
        SHGSI_SMALLICON := 0x1
        SIID_DOCNOASSOC := 0   ; 汎用ファイルアイコン（関連付けなし）
        SIID_FOLDER := 3   ; 標準フォルダアイコン
        SIID_FOLDEROPEN := 4   ; 開いたフォルダ（ハイライトフォルダ用）
        SIID_FIND := 22  ; 検索アイコン（ハイライトファイル用）

        ; SHSTOCKICONINFO: cbSize(4) [+4 pad on 64bit] + hIcon(ptr) + iSysImageIndex(4) + iIcon(4) + szPath(MAX_PATH*2)
        ; 64bit: 4+4pad+8+4+4+520=544 / 32bit: 4+4+4+4+520=536
        sii_size := (A_PtrSize = 8) ? 544 : 536
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
            "ptr", sfi,
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

    static _RefreshTree(tv, rootPath, setFocus := true) {
        ; ルートが変わった場合: 進行中の fd 構築とフィルタ処理をキャンセルして状態をリセット
        if ((NaviFilter._IndexedRoot != "" && NaviFilter._IndexedRoot != rootPath)
            || (NaviFilter._FdIndexPid != 0 && NaviFilter._FdIndexRoot != rootPath)) {
            NaviFilter.ResetForNewRoot()
        }
        tv.Delete()
        this.FilesShown := Map()  ; ノードIDが無効化されるためクリア
        NaviFilter._FilterMatchIdSet := Map()  ; ノードIDが無効化されるためクリア
        NaviMark._MarkedIdSet := Map()
        NaviMark._MarkFilterActive := false
        ; 別ルートへ切り替え時はマークをリセット
        if (rootPath != NaviMark._LastTreeRootPath) {
            NaviMark._MarkedPaths := Map()
            NaviMark._LastTreeRootPath := rootPath
        }
        if (!DirExist(rootPath)) {
            return
        }
        rootID := tv.Add(rootPath, 0, "Expand Select Icon1")
        this._LoadSub(tv, rootPath, rootID)
        this._ShowFilesIfEnabled(tv, rootID, rootPath)
        ; ツリー再構築後にマークノードIDを復元
        NaviMark._RebuildMarkedIdSet(tv)
        if (NaviDirList.Active) {
            ; ルートが変わったのでリストも作り直す（フォーカスは入力欄へ）
            if (setFocus)
                this.GuiObj["TreeFilter"].Focus()
            SetTimer(() => NaviDirList.ApplyCurrent(), -1)
        } else if (setFocus) {
            tv.Focus()
        }
        ; ツリー描画完了後 800ms でインデックスを先読み構築（フィルタ初回遅延を隠す）
        NaviFilter.CancelDebounce()
        cb := () => NaviFilter.PrefetchFolderIndex(rootPath)
        NaviFilter._indexBuildCallback := cb
        SetTimer(cb, -800)
    }

    ; マーク / マークフィルター機能は NaviMark クラスで管理（Navi.Mark.ahk）

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
        if (child != 0 && tv.GetText(child) == "...loading...") {
            tv.Delete(child)
            this._LoadSub(tv, this._GetTVFullPath(tv, id), id)
            ; ファイル表示モードがONなら展開と同時にファイルも自動表示
            this._ShowFilesIfEnabled(tv, id, this._GetTVFullPath(tv, id))
            return
        }
        ; フィルタ中は未ロードの子フォルダを動的追加
        if (NaviFilter._FilterMatchIdSet.Count > 0)
            this._LoadFilterSub(tv, id)
    }

    ; フィルタ中: フィルタツリーに未追加の子フォルダを動的に追加する
    static _LoadFilterSub(tv, parentID) {
        fullPath := this._GetTVFullPath(tv, parentID)
        if (!DirExist(fullPath))
            return
        ; 既存の子ノード名を収集（フィルタ結果として既に追加済みのもの）
        existing := Map()
        childID := tv.GetChild(parentID)
        while (childID != 0) {
            existing[StrLower(tv.GetText(childID))] := true
            childID := tv.GetNext(childID)
        }
        ; 未追加のサブフォルダを追加（通常ツリーと同じ lazy expand 形式で）
        loop files, fullPath . "\*", "D" {
            if (SubStr(A_LoopFileName, 1, 1) == "." || InStr(A_LoopFileAttrib, "H"))
                continue
            if (!existing.Has(StrLower(A_LoopFileName)))
                tv.Add("...loading...", tv.Add(A_LoopFileName, parentID, "Icon1"))
        }
        this._ShowFilesIfEnabled(tv, parentID, fullPath)
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


    static _UpdateStatusBar() {
        try {
            sb := this.GuiObj._sbRef
            ; ピン留めのチェックボックスは表示しないので、状態はここに出す
            pin := this.GuiObj["PinCheck"].Value ? "   📌 ピン留め中" : ""
            if (NaviDirList.Active) {
                sb.SetText(NaviDirList.StatusText() . pin, 1)
                sb.SetText(NaviDirList.StatusHints(), 2)
                return
            }
            sb.SetText((NaviMark._MarkFilterActive ? " ツリー（マークのみ）" : " ツリー") . pin, 1)
            sb.SetText(" Ctrl+; コマンド     Space メニュー     Enter 開く     F1 ヘルプ", 2)
        }
    }

    ; ピン留め（操作後もウィンドウを閉じない）を切り替える
    static _TogglePin() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        this.GuiObj["PinCheck"].Value := !this.GuiObj["PinCheck"].Value
        this._UpdateStatusBar()
    }

    ; ツリーでフォルダを開いたときにファイルも表示するかを切り替える
    static _ToggleAutoFiles() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        cb := this.GuiObj["AutoFilesCheck"]
        cb.Value := !cb.Value
        IniWrite(cb.Value ? "1" : "0", this.IniPath, "Settings", "AutoShowFiles")
    }

    /**
     * ⚙ ボタンのメニュー（ヘッダー行から外した設定類をまとめる）
     * オン・オフのある項目はチェックで今の状態を示す
     */
    static _ShowSettingsMenu() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        m := Menu()
        m.Add("ピン留め`tCtrl+P", (*) => this._TogglePin())
        if (this.GuiObj["PinCheck"].Value)
            m.Check("ピン留め`tCtrl+P")
        m.Add("ツリーにファイルも表示", (*) => this._ToggleAutoFiles())
        if (this.GuiObj["AutoFilesCheck"].Value)
            m.Check("ツリーにファイルも表示")
        m.Add()
        m.Add("ルートを追加...", (*) => this._AddRootDialog())
        m.Add("ルートを編集...", (*) => this._ShowEditGui(this.GuiObj))
        m.Add()
        m.Add("設定...", (*) => this._ShowSettingsGui(this.GuiObj))
        ; ⚙ の真下に出す。Esc はメニューを閉じるのに使うので、Navi を閉じるホットキーを一時的に止める
        this.GuiObj["SettingsBtn"].GetPos(&bx, &by, &bw, &bh)
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Esc", "Off")
        HotIf()
        m.Show(bx + bw, by + bh)
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Esc", "On")
        HotIf()
    }

    /**
     * ルートを追加する小窓（ルート選択と同じ見た目・位置）
     * フルパスを入力して Enter で登録する。.txt ならプロファイルとして読み込む
     * クリップボードにフォルダのパスがあれば最初から入れておく
     * 登録は非表示の QuickPath にパスを入れて既存の _QuickRegisterFromEdit に渡す
     */
    static _AddRootDialog() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        if (this._addRootGui && WinExist(this._addRootGui))
            return
        g := Gui("+Owner" . this.GuiObj.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", "ルートを追加")
        NaviTheme.ApplyPopup(g)
        this._addRootGui := g
        pathEdit := g.Add("Edit", "xm w360 vRootPath")
        try DllCall("user32\SendMessageW", "ptr", pathEdit.Hwnd, "uint", this.EM_SETCUEBANNER, "ptr", 1,
            "wstr", "フォルダのフルパス（.txt ならプロファイルを読み込み）", "ptr")
        browse := g.Add("Button", "x+" . NaviTheme.SP_XS . " yp hp w32", "…")
        NaviTheme.SetFont(g, "caption", NaviTheme.TEXT_SUBTLE)
        g.Add("Text", "xm w400 vRootMsg", "Enter: 追加  /  Esc: キャンセル")
        ; クリップボードにフォルダのパスがあれば入れておく（コピーして開けば Enter だけで済む）
        clip := Trim(A_Clipboard, " `t`r`n`"")
        if (clip != "" && !InStr(clip, "`n") && DirExist(clip))
            pathEdit.Value := clip

        browse.OnEvent("Click", (*) => this._AddRootBrowse())
        g.OnEvent("Close", (*) => this._CloseAddRoot())
        ; 他のウィンドウに切り替わったら閉じる（ルート選択の小窓と同じ）
        local ddHwnd := g.Hwnd
        local self := this
        local wmActMsg := this.WM_ACTIVATE
        wmAct(wParam, lParam, msg, hwnd) {
            if (hwnd = ddHwnd && (wParam & 0xFFFF) = 0 && !self._addRootBrowsing) {
                OnMessage(wmActMsg, wmAct, 0)
                SetTimer(() => self._CloseAddRoot(), -50)
            }
        }
        OnMessage(wmActMsg, wmAct)
        HotIfWinActive("ahk_id " g.Hwnd)
        Hotkey("Enter", (*) => this._SubmitAddRoot(), "On")
        Hotkey("Escape", (*) => this._CloseAddRoot(), "On")
        HotIf()

        this.GuiObj.GetPos(&gx, &gy)
        this.GuiObj["RootBtn"].GetPos(&bx, &by, &bw, &bh)
        g.Show("x" . (gx + bx) . " y" . (gy + by + bh) . " AutoSize")
        pathEdit.Focus()
        SendMessage(0x00B1, 0, -1, pathEdit)  ; EM_SETSEL: 全選択して、打てばすぐ置き換えられるようにする
    }

    ; 「…」: フォルダを選んで入力欄に入れる（登録は Enter で行う）
    static _AddRootBrowse() {
        g := this._addRootGui
        if !(g && WinExist(g))
            return
        this._addRootBrowsing := true  ; ダイアログを開いている間は小窓を閉じない
        g.Opt("+OwnDialogs")
        start := Trim(g["RootPath"].Value, ' "')
        if !DirExist(start)
            start := this._FolderMap.Has(this.lastRoot) ? this._FolderMap[this.lastRoot] : ""
        path := DirSelect("*" . start, 3, "ルートに追加するフォルダを選択")
        this._addRootBrowsing := false
        if (path != "" && g && WinExist(g)) {
            g["RootPath"].Value := path
            g["RootPath"].Focus()
        }
    }

    ; Enter: 入力を確かめて登録する。見つからなければ小窓を閉じずに知らせる
    static _SubmitAddRoot() {
        g := this._addRootGui
        if !(g && WinExist(g))
            return
        ; IME 変換中の Enter は確定に使う
        hIMC := DllCall("imm32\ImmGetContext", "ptr", g["RootPath"].Hwnd, "ptr")
        if (hIMC) {
            composing := DllCall("imm32\ImmGetCompositionStringW", "ptr", hIMC, "uint", 0x0008, "ptr", 0, "ptr", 0) > 0
            DllCall("imm32\ImmReleaseContext", "ptr", g["RootPath"].Hwnd, "ptr", hIMC)
            if (composing) {
                Send "{Enter}"
                return
            }
        }
        path := RTrim(Trim(g["RootPath"].Value, ' "'), "\")
        if (StrLen(path) == 2 && SubStr(path, 2) == ":")
            path .= "\"  ; C: → C:\（ドライブ直下）
        isProfile := (SubStr(StrLower(path), -3) == ".txt") && FileExist(path)
        if (path == "" || !(DirExist(path) || isProfile)) {
            msg := g["RootMsg"]
            msg.Opt("c" . NaviTheme.FOUND)
            msg.Value := (path == "") ? "パスを入力してください" : "フォルダが見つかりません: " . path
            return
        }
        this._CloseAddRoot()
        this.GuiObj["QuickPath"].Value := path
        this._QuickRegisterFromEdit()
    }

    static _CloseAddRoot() {
        g := this._addRootGui
        this._addRootGui := ""
        if (g && WinExist(g))
            try g.Destroy()
        if (this.GuiObj && WinExist(this.GuiObj))
            WinActivate("ahk_id " this.GuiObj.Hwnd)
    }

    ; ツリー・リストを Windows 11 のエクスプローラーと同じ見た目（ホバー表示・選択の色）にする
    static _ApplyExplorerTheme(ctrl) {
        try DllCall("uxtheme\SetWindowTheme", "ptr", ctrl.Hwnd, "wstr", "Explorer", "ptr", 0)
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

    ; RootBtn (w190) に収まるよう長い名前を切り詰める
    ; ▾ を付けて、押すと選べるボタンだと分かるようにする
    ; ボタンは左寄せ（BS_LEFT）なので、枠に文字がくっつかないよう先頭に余白を入れる
    static _TruncRootLabel(name) {
        if (name == "")
            return "  ルートを選択 ▾"
        return "  " . ((StrLen(name) > 40) ? SubStr(name, 1, 38) . "…" : name) . " ▾"
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
            NaviProfile.ImportProfile(path)
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
        this._FolderMap := folderMap
        this._FolderMap[name] := path

        ; UIを更新
        rootBtn := this.GuiObj["RootBtn"]
        tv := this.GuiObj["FolderTree"]
        rootBtn.Text := this._TruncRootLabel(name)

        NaviTab.PushTabHistory()  ; 現在のルートを履歴に積んでから切り替え
        this.lastRoot := name
        this.lastPath := path
        this._RefreshTree(tv, path)
        NaviTab.UpdateTabBar()  ; タブラベルに新ルート名を反映

        ; プロファイルが設定されている場合は自動保存
        lastProfile := IniRead(this.IniPath, "Settings", "LastProfile", "")
        if (lastProfile != "")
            NaviProfile.WriteProfileFileFromMap(lastProfile)

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
        if (this.GuiObj.HasOwnProp("_profileBtnHwnd") && currFocus = this.GuiObj._profileBtnHwnd) {
            ; プロファイルボタンがフォーカスならドロップダウンを開く
            NaviProfile.OpenProfileDropdown()
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
            ; 検索モードなら検索実行、リスト表示なら選択行を開く、フィルターモードならツリーへフォーカス移動
            if (this._SearchMode) {
                this._RunSearchFromFilter()
            } else if (NaviDirList.Active) {
                this._HandleActivate()
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
        ; ファイル検索の結果はツリー上に出すので、リスト表示中ならツリーに戻す
        if (this._SearchMode && NaviDirList.Active)
            NaviDirList._SetActive(false)
        this.GuiObj["FilterToggle"].Text := this._SearchMode ? NaviTheme.ICON_SEARCH : NaviTheme.ICON_FOLDER
        ; 検索タイプボタンの表示切替・リセット
        this.GuiObj["SearchTypeBtn"].Visible := this._SearchMode
        if (!this._SearchMode) {
            this._SearchTypeFilter := "all"
            this.GuiObj["SearchTypeBtn"].Text := NaviTheme.ICON_ALL
        }
        ; TreeFilter の右端を TreeView の右端に揃える（幅 = margin + tvW - tfX）
        _margin_ := this.GuiObj.MarginX
        this.GuiObj["FolderTree"].GetPos(, , &_tvW_)
        if (this._SearchMode)
            this.GuiObj["TreeFilter"].Move(70, , _margin_ + _tvW_ - 70)
        else
            this.GuiObj["TreeFilter"].Move(39, , _margin_ + _tvW_ - 39)
        cue := this._SearchMode ? "ファイルを検索... (Enter で実行)" : "フォルダをフィルター..."
        try DllCall("user32\SendMessageW", "ptr", this.GuiObj["TreeFilter"].Hwnd,
            "uint", this.EM_SETCUEBANNER, "ptr", 1, "wstr", cue, "ptr")
        this.GuiObj["TreeFilter"].Value := ""
        NaviFilter.ApplyTreeFilter("")  ; どちらのモードに切り替えても必ずツリーフィルターをリセット
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
            this.GuiObj["SearchTypeBtn"].Text := NaviTheme.ICON_FOLDER
        } else if (this._SearchTypeFilter = "dir") {
            this._SearchTypeFilter := "file"
            this.GuiObj["SearchTypeBtn"].Text := NaviTheme.ICON_FILE
        } else {
            this._SearchTypeFilter := "all"
            this.GuiObj["SearchTypeBtn"].Text := NaviTheme.ICON_ALL
        }
    }

    /**
     * 選択中のフォルダ/ファイルの絶対パス（リスト表示中はリストの選択行、なければ ""）
     */
    static _GetSelectedPath() {
        if (NaviDirList.Active)
            return NaviDirList.SelectedPath()
        tv := this.GuiObj["FolderTree"]
        id := tv.GetSelection()
        return id ? this._GetTVFullPath(tv, id) : ""
    }

    ; 一覧の本体（表示中のツリーまたはリスト）にフォーカスを移す
    static _FocusMainView() {
        this.GuiObj[NaviDirList.Active ? "DirList" : "FolderTree"].Focus()
    }

    static _HandleActivate() {
        path := this._GetSelectedPath()
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
        NaviActions.Execute("e")
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
        NaviActions.ShowActionMenu()
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
        } else if (NaviDirList.Active && currFocus = this.GuiObj["DirList"].Hwnd) {
            this.GuiObj["TreeFilter"].Focus()
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
        else if (NaviDirList.Active && currFocus = this.GuiObj["DirList"].Hwnd)
            NaviDirList.RevealInTree()
        else if (NaviDirList.Active && this.GuiObj.HasOwnProp("_treeFilterHwnd") && currFocus = this.GuiObj._treeFilterHwnd) {
            ; カーソルが末尾ならリストの選択行をツリーで表示、そうでなければ通常の→
            sel := SendMessage(0x00B0, 0, 0, this.GuiObj["TreeFilter"])  ; EM_GETSEL
            len := StrLen(this.GuiObj["TreeFilter"].Value)
            if ((sel & 0xFFFF) = len && ((sel >> 16) & 0xFFFF) = len)
                NaviDirList.RevealInTree()
            else
                Send "{Right}"
        } else if (this._tvHwnd != 0 && currFocus = this._tvHwnd) {
            PostMessage(0x0100, 0x27, 0, this._tvHwnd)  ; WM_KEYDOWN VK_RIGHT: TreeView展開
            PostMessage(0x0101, 0x27, 0, this._tvHwnd)  ; WM_KEYUP
        }
    }

    ; Ctrl を押したままキーを送ると Ctrl+Backspace / Ctrl+←→（単語単位）になるため、
    ; 入力欄の 1 文字削除・カーソル移動はメッセージで直接行う
    static _EditBackspace(edit) {
        sel := SendMessage(0x00B0, 0, 0, edit)  ; EM_GETSEL
        s := sel & 0xFFFF, e := (sel >> 16) & 0xFFFF
        if (s = e) {
            if (s = 0)
                return
            SendMessage(0x00B1, s - 1, e, edit)  ; EM_SETSEL: 直前の 1 文字を選ぶ
        }
        SendMessage(0x00C2, 1, StrPtr(""), edit)  ; EM_REPLACESEL（Change イベントも発生する）
    }

    static _EditMoveCaret(edit, delta) {
        sel := SendMessage(0x00B0, 0, 0, edit)  ; EM_GETSEL
        pos := Min(Max((sel & 0xFFFF) + delta, 0), StrLen(edit.Value))
        SendMessage(0x00B1, pos, pos, edit)  ; EM_SETSEL
    }

    /**
     * Ctrl+H/J/K/L を ←↓↑→ として扱う
     * Ctrl を押したまま矢印キーを送るとコントロールが Ctrl+矢印（選択せずにスクロール等）と
     * 解釈するため、ツリーとリストは選択を直接動かす
     */
    static _HandleCtrlArrow(key) {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        currFocus := 0
        try currFocus := DllCall("user32\GetFocus", "ptr")
        filterHwnd := this.GuiObj.HasOwnProp("_treeFilterHwnd") ? this.GuiObj._treeFilterHwnd : 0
        lvHwnd := this.GuiObj["DirList"].Hwnd

        ; 入力欄の h: カーソルを 1 文字左へ（先頭なら ← と同じく左のボタンへ）
        ; 入力欄の l: 一覧表示中は選択行をツリーで表示、ツリー表示中はカーソルを 1 文字右へ
        if (currFocus != 0 && currFocus = filterHwnd && (key = "h" || key = "l")) {
            filter := this.GuiObj["TreeFilter"]
            if (key = "h") {
                if ((SendMessage(0x00B0, 0, 0, filter) & 0xFFFF) = 0)  ; EM_GETSEL
                    this._HandleLeftKey()
                else
                    this._EditMoveCaret(filter, -1)
            } else if (NaviDirList.Active) {
                NaviDirList.RevealInTree()
            } else {
                this._EditMoveCaret(filter, 1)
            }
            return
        }
        ; 一覧表示中の入力欄・リスト: j/k で選択行を移動、リスト上の l でツリーに表示、h で入力欄へ
        if (NaviDirList.Active && (currFocus = filterHwnd || currFocus = lvHwnd)) {
            switch key {
                case "j": NaviDirList.Move(1)
                case "k": NaviDirList.Move(-1)
                case "l": NaviDirList.RevealInTree()
                case "h": this.GuiObj["TreeFilter"].Focus()
            }
            return
        }
        if (this._tvHwnd != 0 && currFocus = this._tvHwnd) {
            this._TreeStep(this.GuiObj["FolderTree"], key)
            return
        }
        ; それ以外（入力欄・ボタン類）は矢印キーの処理に任せる。↑ はツリー表示の入力欄では何もしない
        switch key {
            case "h": this._HandleLeftKey()
            case "j": this._HandleRootBtnDown()
            case "l": this._HandleRightKey()
        }
    }

    ; ツリーの選択を矢印キーと同じように動かす（j/k=前後の表示項目、h=閉じる/親へ、l=開く/最初の子へ）
    static _TreeStep(tv, key) {
        id := tv.GetSelection()
        if (!id) {
            if (first := tv.GetNext())
                tv.Modify(first, "Select Vis")
            return
        }
        switch key {
            case "j", "k":
                ; TVM_GETNEXTITEM: TVGN_NEXTVISIBLE=6 / TVGN_PREVIOUSVISIBLE=7
                next := SendMessage(0x110A, key == "j" ? 6 : 7, id, tv)
                if (next)
                    tv.Modify(next, "Select Vis")
            case "h":
                if (tv.GetChild(id) && tv.Get(id, "Expand"))
                    tv.Modify(id, "-Expand")
                else if (parent := tv.GetParent(id))
                    tv.Modify(parent, "Select Vis")
            case "l":
                if (!tv.GetChild(id))
                    return
                if (!tv.Get(id, "Expand")) {
                    ; Modify の展開では ItemExpand イベントが来ないので、遅延ロードを先に済ませる
                    this._OnItemExpand(tv, id)
                    tv.Modify(id, "Expand")
                } else if (child := tv.GetChild(id)) {
                    tv.Modify(child, "Select Vis")
                }
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
        } else if (NaviDirList.Active && this.GuiObj.HasOwnProp("_treeFilterHwnd") && currFocus = this.GuiObj._treeFilterHwnd) {
            ; リスト表示中は入力欄にフォーカスを残したまま選択行を下へ
            NaviDirList.Move(1)
        } else if (NaviDirList.Active && currFocus = this.GuiObj["DirList"].Hwnd) {
            PostMessage(0x0100, 0x28, 0, this.GuiObj["DirList"])  ; WM_KEYDOWN VK_DOWN
            PostMessage(0x0101, 0x28, 0, this.GuiObj["DirList"])  ; WM_KEYUP
        } else if (this.GuiObj.HasOwnProp("_treeFilterHwnd") && currFocus = this.GuiObj._treeFilterHwnd) {
            ; ツリーフィルター欄 → ツリーへ。選択がない場合は前回保存パスを復元
            tv := this.GuiObj["FolderTree"]
            if (tv.GetSelection() == 0 && NaviTab._CurrentTab <= NaviTab._Tabs.Length) {
                tab := NaviTab._Tabs[NaviTab._CurrentTab]
                if (tab != "" && tab.path != "" && (DirExist(tab.path) || FileExist(tab.path)))
                    this._FocusPath(tv, tab.path)
            }
            tv.Focus()
        } else {
            ; それ以外（ツリー上など）→ Down をツリーへ送る
            PostMessage(0x0100, 0x28, 0, this._tvHwnd)  ; WM_KEYDOWN VK_DOWN
            PostMessage(0x0101, 0x28, 0, this._tvHwnd)  ; WM_KEYUP
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
     * 選択ファイルをNaviと同階層(ui)の一時フォルダにコピーし、既定アプリで開く
     * TempCopyライブラリを使用
     */
    static _OpenTempCopy(path) {
        TempCopy.Open(path)
    }

    /**
     * ルート選択（ルートのボタン・Enter・コマンド一覧の r）
     * 2 列目にフルパスを補足として出す。決定したらそのルートへ切り替える
     */
    static _OpenDropdown() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        items := []
        for name in this._AllFolderNames
            items.Push({ text: name, sub: this._FolderMap.Has(name) ? this._FolderMap[name] : "" })
        NaviPicker.Open(this, {
            anchor: this.GuiObj["RootBtn"], items: items, selected: this.lastRoot,
            placeholder: "ルートを名前やパスで絞り込み...",
            emptyText: "ルートがありません（⚙ → ルートを追加 から登録できます）",
            onConfirm: (name) => this._SelectRoot(name)
        })
    }

    ; 選んだルートへ切り替える（今のルートは履歴に積む）
    static _SelectRoot(name) {
        if !(name != "" && this._FolderMap.Has(name) && this.GuiObj && WinExist(this.GuiObj))
            return
        NaviTab.PushTabHistory()  ; 現在のルートを履歴に積んでから切り替え
        this.lastRoot := name
        this.GuiObj["RootBtn"].Text := this._TruncRootLabel(name)
        this.GuiObj["TreeFilter"].Value := ""
        this._RefreshTree(this.GuiObj["FolderTree"], this._FolderMap[name])
        NaviTab.UpdateTabBar()  ; タブラベルに新ルート名を反映
    }

    /**
     * ウィンドウリサイズ: 幅は全幅コントロールが追従、高さは TreeView が伸縮する
     * ヘッダー行は ⚙ を右端に置き、ルートのボタンをその手前まで伸ばす
     */
    static _OnResize(minmax, w, h) {
        if (minmax = -1 || !(this.GuiObj && WinExist(this.GuiObj)))
            return
        margin := this.GuiObj.MarginX
        ctrlW := w - 2 * margin

        ; ヘッダー行: ⚙ を右端へ、ルートのボタンを ⚙ の手前まで
        settingsBtn := this.GuiObj["SettingsBtn"]
        settingsBtn.GetPos(, , &_sbtnW_)
        settingsX := w - margin - _sbtnW_
        settingsBtn.Move(settingsX)
        this.GuiObj["RootBtn"].GetPos(&_rootX_)
        this.GuiObj["RootBtn"].Move(, , Max(80, settingsX - NaviTheme.SP_S - _rootX_))

        ; 全幅コントロールを幅に追従させる
        this.GuiObj["Breadcrumb"].Move(, , ctrlW)
        if (NaviTab._TabSepCtrl)
            NaviTab._TabSepCtrl.Move(0, , w)  ; タブ下の余白はクライアント全幅
        if (NaviTab._TabStripCtrl)
            NaviTab._TabStripCtrl.Move(0, , w)  ; タブの帯もクライアント全幅
        ; 窓の幅が変わるとタブが入りきるかが変わるので、タブ幅を計算し直す
        if (NaviTab._TabBtnCtrls.Length)
            NaviTab.UpdateTabBar()
        ; TreeFilter は左端が FilterToggle(+SearchTypeBtn) 分ずれているので x 座標を考慮した幅にする
        this.GuiObj["TreeFilter"].GetPos(&_tfX_)
        this.GuiObj["TreeFilter"].Move(, , w - margin - _tfX_)

        ; TreeView は StatusBar の上まで高さを埋める（ステータスバーとの間は SP_S あける）
        sbH := 28  ; フォールバック値
        if (this.GuiObj.HasOwnProp("_sbRef"))
            this.GuiObj._sbRef.GetPos(, , , &sbH)
        tvH := Max(60, h - this._tvY - sbH - NaviTheme.SP_S)
        this.GuiObj["FolderTree"].Move(, , ctrlW, tvH)
        NaviDirList.OnResize(ctrlW, tvH)
    }

    /**
     * Escキー: オーバーレイが開いていれば閉じる（選択変更なし）、なければNaviを閉じる
     */
    static _HandleEsc() {
        if (NaviPicker.IsOpen()) {
            NaviPicker.Close()
        } else if (this.GuiObj && WinExist(this.GuiObj) && this.GuiObj["TreeFilter"].Value != "") {
            ; ツリーフィルターにテキストがあればクリアしてフィルター欄にフォーカスを残す
            this.GuiObj["TreeFilter"].Value := ""
            NaviFilter.ApplyTreeFilter("")
            this.GuiObj["TreeFilter"].Focus()
        } else {
            this._DestroyGui()
        }
    }

    ; 右クリック: TreeView 上のアイテムを選択して Shell コンテキストメニューを表示
    static _HandleRButton() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        ; タブ上の右クリックなら閉じるメニューを表示
        if (NaviTab.HandleRightClick())
            return
        tv := this.GuiObj["FolderTree"]
        MouseGetPos(, , , &underHwnd, 2)
        if (NaviDirList.Active && underHwnd = this.GuiObj["DirList"].Hwnd) {
            path := NaviDirList.SelectRowAtMouse()
            if (path != "")
                SetTimer(() => NaviContextMenu.Show(path, this), -1)
            return
        }
        if (underHwnd != tv.Hwnd)
            return
        ; 右クリック後に選択が確定するよう 1 tick 待つ
        SetTimer(() => (
            id := tv.GetSelection(),
            id ? NaviContextMenu.Show(this._GetTVFullPath(tv, id), this) : 0
        ), -1)
    }

}
