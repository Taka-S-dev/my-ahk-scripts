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
#Include *i Navi.Search.ahk
#Include *i Navi.ContextMenu.ahk
#Include *i Navi.Action.ahk
#Include *i Navi.Filter.ahk
#Include *i Navi.Tab.ahk
#Include *i Navi.Profile.ahk
#Include *i Navi.DetailList.ahk
#Include *i Navi.Breadcrumb.ahk
#Include *i Navi.Mark.ahk
#Include ..\..\lib\TempCopy.ahk

class Navi {
    ; --- クラス定数 ---
    static GUI_WIDTH := 450
    static GUI_HEIGHT_APPROX := 565
    static WINDOW_FRAME_WIDTH := 14  ; ウィンドウフレーム補正値（Win10/11標準テーマ）
    static IniPath := A_ScriptDir "\ui\navi\Navi.ini"
    static ExplorerPath := ""
    static TOOLTIP_ERROR_DURATION := 2000
    static TOOLTIP_SUCCESS_DURATION := 1000
    static TOOLTIP_COPY_DURATION := 2000
    static TEMP_DIR_SUBPATH := "\temp"
    static TEMP_PREFIX := "TEMP_"

    ; --- アクションメニュー用の定数 ---
    static MENU_BG_COLOR := "262626"  ; メニューの背景色
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
    static QuickPathFocused := false
    static QuickPathHwnd := 0
    static _TreeFilterFocused := false
    static FilesShown := Map()
    ; 詳細リスト関連状態は NaviDetailList クラスで管理（Navi.DetailList.ahk）
    ; パンくず関連定数・状態は NaviBreadcrumb クラスで管理（Navi.Breadcrumb.ahk）
    static _AllFolderNames := []  ; 全ルート名リスト（フィルタ前）
    static FilteredNames := []    ; フィルタ後のルート名リスト
    static _FolderMap := Map()    ; ルート名→パスマップ
    static DropdownGui := ""             ; ルート選択ドロップダウンGUI
    ; プロファイル関連状態は NaviProfile クラスで管理（Navi.Profile.ahk）
    ; フィルタ関連状態は NaviFilter クラスで管理（Navi.Filter.ahk）
    ; マーク関連状態・定数は NaviMark クラスで管理（Navi.Mark.ahk）

    ; --- アイコン管理 ---
    static _ILHandle := 0           ; TreeView 用 ImageList ハンドル
    static _IconCache := Map()       ; 拡張子→ImageList インデックスキャッシュ
    static _ILNextIdx := 5           ; 次に追加するアイコンのインデックス（1-4 は固定枠）
    static _tvY := 0                  ; TreeView の Y 座標（リサイズ計算用）
    static _rootBtnRightGap := 0      ; RootBtn 右側の固定幅（リサイズ計算用）
    static _tvHwnd := 0        ; TreeView の Hwnd
    static _quickPathH := 22       ; QuickPath 欄の高さ（リサイズ計算用）
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
                NaviFilter.ApplyTreeFilter("")
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
        this.GuiObj.SetFont("s10", "Yu Gothic UI")

        ; --- ヘッダー行（プロファイル・ルート選択・編集・設定・チェックボックス）---
        rootBtnText := (this.lastRoot != "") ? this._TruncRootLabel(this.lastRoot) : "ルートを選択..."
        ; Profile は小さいフォントで控えめに（文脈ラベル的な扱い）
        this.GuiObj.SetFont("s8", "Yu Gothic UI")
        btnProfile := this.GuiObj.Add("Button", "xm y+2 w95 h26 -Tabstop vProfileBtn", NaviProfile.GetProfileBtnText())
        this.GuiObj._profileBtnHwnd := btnProfile.Hwnd
        ; › セパレーターで階層を表現
        this.GuiObj.SetFont("s10", "Yu Gothic UI")
        this.GuiObj.Add("Text", "x+3 yp w14 h26 +0x201 vProfileSep", "›")  ; SS_CENTER|SS_NOTIFY
        ; Root は主役として大きめに
        rootBtn := this.GuiObj.Add("Button", "x+3 yp w190 h26 vRootBtn", rootBtnText)
        this.GuiObj._rootBtnHwnd := rootBtn.Hwnd
        btnEdit := this.GuiObj.Add("Button", "x+5 yp w40 h26 -Tabstop", "編集")
        this.GuiObj._btnEditHwnd := btnEdit.Hwnd
        this.GuiObj._btnEditCtrl := btnEdit
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
        breadcrumb := this.GuiObj.Add("Text", "xm w455 h" . NaviBreadcrumb.BREADCRUMB_HEIGHT . " vBreadcrumb c" . NaviBreadcrumb.BREADCRUMB_COLOR . " +0x8100", "")  ; SS_NOTIFY(0x100)|SS_PATHELLIPSIS(0x8000)
        breadcrumb.OnEvent("Click", (*) => NaviBreadcrumb._OnClick())
        NaviBreadcrumb._hwnd := breadcrumb.Hwnd
        OnMessage(this.WM_SETCURSOR, NaviBreadcrumb._OnSetCursor.Bind(NaviBreadcrumb))
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
        tv := this.GuiObj.Add("TreeView", "xm w455 r15 vFolderTree")
        this._SetupTreeIcons(tv)
        this._tvHwnd := tv.Hwnd

        ; --- クイック登録欄（下部）---
        quickEdit := this.GuiObj.Add("Edit", "xm w455 vQuickPath -Tabstop", "")
        try DllCall("user32\SendMessageW", "ptr", quickEdit.Hwnd, "uint", this.EM_SETCUEBANNER, "ptr", 1, "wstr",
            "Add root: full path + Enter", "ptr")
        quickEdit.SetFont("s9 c808080", "Yu Gothic UI")
        quickEdit.OnEvent("Focus", (*) => (Navi.QuickPathFocused := true))
        quickEdit.OnEvent("LoseFocus", (*) => (Navi.QuickPathFocused := false))
        this.QuickPathHwnd := quickEdit.Hwnd
        quickEdit.GetPos(, , , &_qpH_)
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
        NaviTab._tabBarShift := _headerY_ - _tabBarTopY_
        NaviTab._tabBarVisible := true

        ; タブ1枚のときはタブバーを初期非表示にする
        if (NaviTab._TabCount == 1)
            NaviTab.SetTabBarVisible(false)

        ; ウィンドウリサイズイベント登録
        this.GuiObj.OnEvent("Size", (g, mm, w, h) => this._OnResize(mm, w, h))

        rootBtn.OnEvent("Click", (*) => this._OpenDropdown())
        btnEdit.OnEvent("Click", (*) => this._ShowEditGui(this.GuiObj))
        btnSettings.OnEvent("Click", (*) => this._ShowSettingsGui(this.GuiObj))
        btnProfile.OnEvent("Click", (*) => NaviProfile.OpenProfileDropdown())
        tv.OnEvent("ItemExpand", (obj, id, *) => this._OnItemExpand(obj, id))
        tv.OnEvent("DoubleClick", (obj, id, *) => this._HandleActivate())
        this.GuiObj.OnEvent("Close", (*) => (this.GuiObj := ""))

        ; ホットキー設定（Naviアクティブ時のみ）
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Space", (*) => this._HandleSpace(), "On")
        Hotkey("Enter", (*) => this._HandleEnter(), "On")
        Hotkey("^Enter", (*) => this.ToggleFilesUnderSelection(), "On")
        Hotkey("^p", (*) => (this.GuiObj["PinCheck"].Value := !this.GuiObj["PinCheck"].Value), "On")
        Hotkey("^d", (*) => NaviDetailList.Show(), "On")
        Hotkey("^f", (*) => this.GuiObj["TreeFilter"].Focus(), "On")
        Hotkey("F1", (*) => this._ShowHelp(), "On")
        Hotkey("Esc", (*) => this._HandleEsc(), "On")
        Hotkey("~Down", (*) => this._HandleRootBtnDown(), "On")
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

        winW := this.GUI_WIDTH + this.WINDOW_FRAME_WIDTH
        winH := this.GUI_HEIGHT_APPROX
        centerX := waL + (waR - waL - winW) // 2
        centerY := waT + (waB - waT - winH) // 2

        this.GuiObj.Show("x" . centerX . " y" . centerY)
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
        NaviTab.SaveCurrentTab()
        NaviTab.SaveTabsToIni()
        ; パンくず監視タイマーを停止
        NaviBreadcrumb.StopWatcher()
        ; フィルタータイマーを停止（GUI破棄後に ApplyTreeFilter が発火するのを防ぐ）
        NaviFilter.CancelDebounce()
        ; マーク状態をリセット
        NaviMark.Reset()
        ; プロファイルドロップダウンを閉じる
        NaviProfile.CloseProfileDropdown()
        ; 詳細リスト参照をリセット（+Owner で親破棄時に自動クローズされるため Destroy 不要）
        NaviDetailList._guiObj := ""
        ; タブボタンコントロールはGUI依存のためリセット（タブ状態は次回起動時に再利用）
        NaviTab.Cleanup()
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

    static _ShowEditGui(parentGui) {
        parentGui.GetPos(&px, &py, &pw, &ph)
        parentGui.Opt("+Disabled")
        editGui := Gui("+Owner" . parentGui.Hwnd . " +AlwaysOnTop -MinimizeBox +Resize", "ルートディレクトリ編集")
        editGui.SetFont("s10", "Yu Gothic UI")
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
        settGui.SetFont("s10", "Yu Gothic UI")
        settGui.MarginX := 16
        settGui.MarginY := 12

        ; --- 外部ファイラー ---
        settGui.SetFont("s10 Bold")
        settGui.Add("Text", "xm", "外部ファイラー")
        settGui.SetFont("s10 Norm")
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
        settGui.SetFont("s10 Bold")
        settGui.Add("Text", "xm y+10", "動作")
        settGui.SetFont("s10 Norm")
        autoMinCb := settGui.Add("CheckBox", "xm y+8", "アクション実行後に自動最小化する（ピン留めON時は無効）")
        autoMinCb.Value := (IniRead(this.IniPath, "Settings", "AutoMinimizeOnAction", "0") == "1") ? 1 : 0

        ; --- フォルダフィルター ---
        settGui.Add("Text", "xm y+14 w400 0x10")
        settGui.SetFont("s10 Bold")
        settGui.Add("Text", "xm y+10", "フォルダフィルター")
        settGui.SetFont("s10 Norm")
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
        if (setFocus)
            tv.Focus()
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


    static _UpdateStatusBar() {
        try {
            sb := this.GuiObj._sbRef
            base := " [Space]メニュー  [Enter]開く  [Ctrl+D]詳細  [F1]ヘルプ"
            sb.SetText(NaviMark._MarkFilterActive ? base . "  [mark]" : base)
        }
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
    static _TruncRootLabel(name) {
        return (StrLen(name) > 18) ? SubStr(name, 1, 16) . "..." : name
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
        this.FilteredNames := newNames.Clone()
        this._FolderMap := folderMap
        this._FolderMap[name] := path

        ; UIを更新
        rootBtn := this.GuiObj["RootBtn"]
        tv := this.GuiObj["FolderTree"]
        rootBtn.Text := name

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
            NaviProfile.OpenProfileDropdown()
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
        tv := this.GuiObj["FolderTree"]
        id := tv.GetSelection()
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
        local ddHwnd := ddGui.Hwnd
        local self := this
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
            NaviTab.PushTabHistory()  ; 現在のルートを履歴に積んでから切り替え
            this.lastRoot := selectedTxt
            this.GuiObj["RootBtn"].Text := this._TruncRootLabel(selectedTxt)
            this.GuiObj["TreeFilter"].Value := ""
            tv := this.GuiObj["FolderTree"]
            this._RefreshTree(tv, this._FolderMap[selectedTxt])
            NaviTab.UpdateTabBar()  ; タブラベルに新ルート名を反映
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
        ctrlW := w - 2 * margin

        ; 全幅コントロールを幅に追従させる
        this.GuiObj["Breadcrumb"].Move(, , ctrlW)
        if (NaviTab._TabSepCtrl)
            NaviTab._TabSepCtrl.Move(0, , w)  ; 境界線はクライアント全幅
        ; TreeFilter は左端が FilterToggle(+SearchTypeBtn) 分ずれているので x 座標を考慮した幅にする
        this.GuiObj["TreeFilter"].GetPos(&_tfX_)
        this.GuiObj["TreeFilter"].Move(, , w - margin - _tfX_)

        ; TreeView は QuickPath と StatusBar の上まで高さを埋める
        sbH := 28  ; フォールバック値
        if (this.GuiObj.HasOwnProp("_sbRef"))
            this.GuiObj._sbRef.GetPos(, , , &sbH)
        qpH := this._quickPathH
        tvH := Max(60, h - this._tvY - qpH - sbH)
        this.GuiObj["FolderTree"].Move(, , ctrlW, tvH)
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
            NaviFilter.ApplyTreeFilter("")
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

    ; 右クリック: TreeView 上のアイテムを選択して Shell コンテキストメニューを表示
    static _HandleRButton() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        tv := this.GuiObj["FolderTree"]
        MouseGetPos(, , , &underHwnd, 2)
        if (underHwnd != tv.Hwnd)
            return
        ; 右クリック後に選択が確定するよう 1 tick 待つ
        SetTimer(() => (
            id := tv.GetSelection(),
            id ? NaviContextMenu.Show(this._GetTVFullPath(tv, id), this) : 0
        ), -1)
    }

}
