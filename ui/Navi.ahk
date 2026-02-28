; ==============================================================================
; Module:       Navi.ahk
; Description:  汎用フォルダランチャー & アクティブパス実行ツール
;               - フォルダパスのTreeView表示とクイックアクセス
;               - 表示・非表示の個別/一括切り替え機能
;
; - リストの順序入れ替え（上下移動）
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
#Include ..\lib\TempCopy.ahk

class Navi {
    ; --- クラス定数 ---
    static GUI_WIDTH := 450
    static GUI_HEIGHT_APPROX := 540
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
    static MENU_WIDTH := 250       ; メニューの幅
    static MENU_BTN_W := 230       ; ボタンの幅
    static MENU_BTN_H := 38        ; ボタンの高さ
    static MENU_OFFSET_Y := 320    ; 中央配置の計算用オフセット

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
    static QuickPathFocused := false
    static QuickPathHwnd := 0
    static FilesShown := Map()
    static lastSelectedId := 0  ; パンくず更新用
    static DetailListGuiObj := ""  ; 詳細リストウィンドウ
    static _AllFolderNames := []  ; 全ルート名リスト（フィルタ前）
    static FilteredNames := []    ; フィルタ後のルート名リスト
    static _FolderMap := Map()    ; ルート名→パスマップ
    static DropdownGui := ""      ; フィルタードロップダウンGUI
    static _treeFilterCallback := ""  ; ツリーフィルターデバウンス用コールバック参照
    static _indexBuildCallback := ""  ; インデックス先読み構築タイマー用コールバック参照
    static _FolderIndex := []         ; ツリーフィルター用フォルダパスキャッシュ
    static _IndexedRoot := ""         ; キャッシュが対応するルートパス
    static _ILHandle := 0             ; TreeView 用 ImageList ハンドル
    static _tvY := 0                  ; TreeView の Y 座標（リサイズ計算用）
    static _rootBtnRightGap := 0      ; RootBtn 右側の固定幅（リサイズ計算用）

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
            this.GuiObj.Destroy()
        }
        this.GuiObj := ""

        this.GuiObj := Gui("+AlwaysOnTop +Resize", "Navi")
        this.GuiObj.SetFont("s10", "Yu Gothic UI")

        folderMap := Map(), folderNames := []
        this._LoadFolders(folderMap, folderNames)

        chooseIdx := 1
        for i, name in folderNames {
            if (name == this.lastRoot) {
                chooseIdx := i
                break
            }
        }

        ; クイック登録: フルパス入力→Enterでルート追加（Tab移動ではフォーカスしない）
        quickEdit := this.GuiObj.Add("Edit", "xm w455 vQuickPath -Tabstop", "")
        ; プレースホルダ
        try DllCall("user32\SendMessageW", "ptr", quickEdit.Hwnd, "uint", 0x1501, "ptr", 1, "wstr",
            "Add root: full path + Enter", "ptr")
        quickEdit.SetFont("s9 c808080", "Yu Gothic UI")
        ; フォーカス状態をトラック
        quickEdit.OnEvent("Focus", (*) => (Navi.QuickPathFocused := true))
        quickEdit.OnEvent("LoseFocus", (*) => (Navi.QuickPathFocused := false))
        this.QuickPathHwnd := quickEdit.Hwnd

        ; ルートボタン（クリックでオーバーレイ選択ウィンドウを開く）
        rootBtnText := (this.lastRoot != "") ? this.lastRoot : "ルートを選択..."
        rootBtn := this.GuiObj.Add("Button", "xm w260 h26 vRootBtn", rootBtnText)
        this.GuiObj._rootBtnHwnd := rootBtn.Hwnd  ; Enter判定用にhwndを保存
        btnEdit := this.GuiObj.Add("Button", "x+5 yp w45 h26 -Tabstop", "編集")
        this.GuiObj._btnEditHwnd := btnEdit.Hwnd
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

        ; パンくずリスト（現在のパス表示 & クリックで階層メニュー）
        this.GuiObj.SetFont("s9", "Yu Gothic UI")
        breadcrumb := this.GuiObj.Add("Text", "xm w455 h" . this.BREADCRUMB_HEIGHT . " vBreadcrumb c" . this.BREADCRUMB_COLOR . " +0x8100", "")  ; SS_NOTIFY(0x100)|SS_PATHELLIPSIS(0x8000)
        breadcrumb.OnEvent("Click", (*) => this._OnBreadcrumbClick())
        this.GuiObj.SetFont("s10", "Yu Gothic UI")

        ; ツリーフィルター入力欄
        treeFilter := this.GuiObj.Add("Edit", "xm w455 vTreeFilter -Tabstop", "")
        try DllCall("user32\SendMessageW", "ptr", treeFilter.Hwnd, "uint", 0x1501, "ptr", 1,
            "wstr", "フォルダをフィルター...", "ptr")
        treeFilter.OnEvent("Change", (*) => this._OnTreeFilterChange())
        this.GuiObj._treeFilterHwnd := treeFilter.Hwnd

        tv := this.GuiObj.Add("TreeView", "xm w455 r17 vFolderTree")
        this._SetupTreeIcons(tv)

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

        ; ウィンドウリサイズイベント登録
        this.GuiObj.OnEvent("Size", (g, mm, w, h) => this._OnResize(mm, w, h))

        rootBtn.OnEvent("Click", (*) => this._OpenDropdown())
        btnEdit.OnEvent("Click", (*) => this._ShowEditGui(this.GuiObj))
        tv.OnEvent("ItemExpand", (obj, id, *) => this._OnItemExpand(obj, id))
        tv.OnEvent("DoubleClick", (obj, id, *) => this.Execute("e"))
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
        HotIf()

        ; パンくず更新用タイマー開始
        this.lastSelectedId := 0
        SetTimer(this._BreadcrumbWatcher.Bind(this), this.BREADCRUMB_WATCH_MS)

        if (folderNames.Length > 0) {
            selectedRoot := (this.lastRoot != "" && folderMap.Has(this.lastRoot)) ? this.lastRoot : folderNames[1]
            this.lastRoot := selectedRoot  ; フィルター等で参照できるよう確実にセット
            this._RefreshTree(tv, folderMap[selectedRoot])
            ; ツリーフィルター用インデックスをバックグラウンド的に構築（初回フィルタを高速化）
            local rootForIndex := folderMap[selectedRoot]
            SetTimer(() => this._BuildFolderIndex(rootForIndex), -800)
            if (this.lastPath != "") {
                this._FocusPath(tv, this.lastPath)
            }
            this._RefreshBreadcrumb()
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
        actGui.MarginY := 15

        actGui.SetFont("s11 w700 cWhite", "Yu Gothic UI")
        folderName := (InStr(fullPath, "\")) ? StrSplit(fullPath, "\")[-1] : fullPath
        actGui.Add("Text", "Center w" . this.MENU_BTN_W, "Selected: " . folderName)

        actGui.SetFont("s10 w400")
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

        btnCancel := actGui.Add("Button", "w" . this.MENU_BTN_W . " h" . this.MENU_BTN_H . " xm y+12", "&X: Cancel")
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
                if (k != "f" && !this.GuiObj["PinCheck"].Value && !GetKeyState("Shift", "P")) {
                    this._DestroyGui()
                }
            }
            this._ExecuteAction(key, fullPath)
            if (key != "k" && StrLower(key) != "f") {
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
        ; パンくず監視タイマーを停止
        SetTimer(this._BreadcrumbWatcher.Bind(this), 0)
        ; フィルタータイマーを停止（GUI破棄後に _ApplyTreeFilter が発火するのを防ぐ）
        if (this._treeFilterCallback != "") {
            SetTimer(this._treeFilterCallback, 0)
            this._treeFilterCallback := ""
        }
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
        editGui := Gui("+Owner" . parentGui.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", "ルートディレクトリ管理")
        editGui.SetFont("s10", "Yu Gothic UI")
        lv := editGui.Add("ListView", "r15 w550 Grid Multi vFolderList", ["名称", "パス", "表示"])
        lv.ModifyCol(1, 120), lv.ModifyCol(2, 350), lv.ModifyCol(3, 50)
        this._LoadLVFolders(lv)
        btnAdd := editGui.Add("Button", "xm w70", "追加"), btnMod := editGui.Add("Button", "x+5 w70", "修正"), btnDel :=
            editGui.Add("Button", "x+5 w70", "削除")
        btnUp := editGui.Add("Button", "x+20 w40", "↑"), btnDown := editGui.Add("Button", "x+5 w40", "↓")
        btnSave := editGui.Add("Button", "x+220 w110 Default", "保存/再起動")
        btnAdd.OnEvent("Click", (*) => this._ShowEntryGui(editGui, lv)), btnMod.OnEvent("Click", (*) => this._ShowEntryGui(
            editGui, lv, lv.GetNext())), btnDel.OnEvent("Click", (*) => this._DeleteItem(lv, editGui))
        btnUp.OnEvent("Click", (*) => this._MoveItem(lv, -1)), btnDown.OnEvent("Click", (*) => this._MoveItem(lv, 1)),
            btnSave.OnEvent("Click", (*) => this._SaveList(lv))
        lv.OnEvent("DoubleClick", (obj, info) => (info ? this._ShowEntryGui(editGui, lv, info) : 0))
        editGui.OnEvent("Close", (*) => this._CleanupEditGui(parentGui, editGui))
        HotIfWinActive("ahk_id " editGui.Hwnd)
        Hotkey("Esc", (*) => this._CleanupEditGui(parentGui, editGui), "On")
        HotIf()
        editGui.Show("Hide"), editGui.GetPos(, , &ew, &eh)
        editGui.Show("x" . px + (pw - ew) // 2 . " y" . py + (ph - eh) // 2)
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
        lv.Modify(row, , n2, p2, v2), lv.Modify(target, , n1, p1, v1), lv.Modify(target, "Select Focus")
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

    static _SaveList(lv) {
        IniDelete(this.IniPath, "Folders")
        loop lv.GetCount() {
            name := lv.GetText(A_Index, 1), path := lv.GetText(A_Index, 2)
            visible := (lv.GetText(A_Index, 3) == "○") ? "1" : "0"
            IniWrite(path . "|" . visible, this.IniPath, "Folders", name)
        }
        Reload()
    }

    static _LoadFolders(folderMap, folderNames) {
        try {
            content := FileRead(this.IniPath, "UTF-8")
            sect := ""
            for line in StrSplit(content, "`n", "`r") {
                line := Trim(line)
                if (line == "" || SubStr(line, 1, 1) == ";") {
                    continue
                }
                if (RegExMatch(line, "\[(.*)\]", &match)) {
                    sect := match[1]
                    continue
                }
                if (sect == "Folders" && InStr(line, "=")) {
                    p := StrSplit(line, "=", , 2), vParts := StrSplit(Trim(p[2]), "|")
                    name := Trim(p[1]), path := vParts[1], isVisible := (vParts.Length > 1) ? vParts[2] : "1"
                    folderMap[name] := path
                    if (isVisible == "1") {
                        folderNames.Push(name)
                    }
                }
            }
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
        SIID_DOCNOASSOC := 0   ; 汎用ファイルアイコン（関連付けなし）
        SIID_FOLDER     := 3   ; 標準フォルダアイコン

        ; SHSTOCKICONINFO: cbSize(4) [+4 pad on 64bit] + hIcon(ptr) + iSysImageIndex(4) + iIcon(4) + szPath(MAX_PATH*2)
        ; 64bit: 4+4pad+8+4+4+520=544 / 32bit: 4+4+4+4+520=536
        sii_size     := (A_PtrSize = 8) ? 544 : 536
        hIcon_offset := A_PtrSize  ; 64bit=8(cbSize+padding), 32bit=4(cbSize)

        hIL := IL_Create(2)

        ; フォルダアイコン（Index 1 = "Icon1"）
        sii := Buffer(sii_size, 0)
        NumPut("uint", sii_size, sii, 0)
        DllCall("shell32\SHGetStockIconInfo", "uint", SIID_FOLDER,
            "uint", SHGSI_ICON | SHGSI_SMALLICON, "ptr", sii)
        hIcon := NumGet(sii, hIcon_offset, "ptr")
        DllCall("comctl32\ImageList_AddIcon", "ptr", hIL, "ptr", hIcon)
        DllCall("user32\DestroyIcon", "ptr", hIcon)

        ; 汎用ファイルアイコン（Index 2 = "Icon2"）
        sii2 := Buffer(sii_size, 0)
        NumPut("uint", sii_size, sii2, 0)
        DllCall("shell32\SHGetStockIconInfo", "uint", SIID_DOCNOASSOC,
            "uint", SHGSI_ICON | SHGSI_SMALLICON, "ptr", sii2)
        hIcon2 := NumGet(sii2, hIcon_offset, "ptr")
        DllCall("comctl32\ImageList_AddIcon", "ptr", hIL, "ptr", hIcon2)
        DllCall("user32\DestroyIcon", "ptr", hIcon2)

        tv.SetImageList(hIL)
        this._ILHandle := hIL
    }

    /**
     * ルート配下のフォルダパスを再帰的にメモリへキャッシュする
     */
    static _BuildFolderIndex(rootPath) {
        this._FolderIndex := []
        this._IndexedRoot := rootPath
        loop files, rootPath . "\*", "DR" {
            if (SubStr(A_LoopFileName, 1, 1) == "." || InStr(A_LoopFileAttrib, "H"))
                continue
            this._FolderIndex.Push(A_LoopFilePath)
        }
    }

    /**
     * ツリーフィルター入力変更: 300ms デバウンスで _ApplyTreeFilter を呼ぶ
     */
    static _OnTreeFilterChange() {
        if (this._treeFilterCallback != "")
            SetTimer(this._treeFilterCallback, 0)
        query := this.GuiObj["TreeFilter"].Value
        cb := () => this._ApplyTreeFilter(query)
        this._treeFilterCallback := cb
        SetTimer(cb, -300)
    }

    /**
     * ツリーフィルター適用: query が空なら通常ツリーに戻す、あれば再帰検索してツリー再構築
     */
    static _ApplyTreeFilter(query) {
        this._treeFilterCallback := ""
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        tv := this.GuiObj["FolderTree"]
        rootPath := this._FolderMap.Has(this.lastRoot) ? this._FolderMap[this.lastRoot] : ""
        if (rootPath == "")
            return
        if (Trim(query) == "") {
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
        if (this._IndexedRoot != rootPath)
            this._BuildFolderIndex(rootPath)
        ; キャッシュからメモリ内検索（スペース=AND、"|"=OR）
        results := []
        for fullPath in this._FolderIndex {
            matched := true
            for orGroup in terms {
                groupMatched := false
                for alt in orGroup {
                    if (alt != "" && InStr(fullPath, alt, false)) {
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
        ; ツリー再構築
        tv.Delete()
        this.FilesShown := Map()
        if (results.Length == 0) {
            tv.Add("(一致なし)", 0)
            return
        }
        rootID := tv.Add(rootPath, 0, "Expand Icon1")
        addedPaths := Map()
        addedPaths[StrLower(rootPath)] := rootID
        firstMatch := true
        for fullPath in results {
            rel := SubStr(fullPath, StrLen(rootPath) + 2)
            parts := StrSplit(rel, "\")
            parentID := rootID
            currentPath := rootPath
            for i, part in parts {
                currentPath .= "\" . part
                key := StrLower(currentPath)
                if addedPaths.Has(key) {
                    parentID := addedPaths[key]
                } else {
                    isMatch := (i == parts.Length)
                    opts := isMatch ? "Bold" : "Expand"
                    if (isMatch && firstMatch) {
                        opts .= " Select"
                        firstMatch := false
                    }
                    nodeID := tv.Add(part, parentID, opts . " Icon1")
                    addedPaths[key] := nodeID
                    parentID := nodeID
                }
            }
        }
        ; ファイル表示モードがONならフィルタ結果の各フォルダにもファイルを表示
        if (this.GuiObj["AutoFilesCheck"].Value) {
            fileMax := 200
            try fileMax := Integer(IniRead(this.IniPath, "Settings", "FileMax", "200"))
            rootKey := StrLower(rootPath)
            for folderKey, nodeID in addedPaths {
                if (folderKey == rootKey)
                    continue
                shown := []
                count := 0
                try {
                    loop files, folderKey . "\*", "F" {
                        if InStr(A_LoopFileAttrib, "H")
                            continue
                        shown.Push(tv.Add(A_LoopFileName, nodeID, "Icon2"))
                        if (++count >= fileMax)
                            break
                    }
                } catch {
                    return  ; GUI が破棄された場合は安全に中断
                }
                if (shown.Length > 0)
                    this.FilesShown[nodeID] := shown
            }
        }
    }

    static _RefreshTree(tv, rootPath, setFocus := true) {
        tv.Delete()
        this.FilesShown := Map()  ; ノードIDが無効化されるためクリア
        if (!DirExist(rootPath)) {
            return
        }
        rootID := tv.Add(rootPath, 0, "Expand Select Icon1")
        this._LoadSub(tv, rootPath, rootID)
        if (setFocus)
            tv.Focus()
        ; ツリー描画完了後 800ms でインデックスを先読み構築（フィルタ初回遅延を隠す）
        if (this._indexBuildCallback != "")
            SetTimer(this._indexBuildCallback, 0)
        cb := () => this._BuildFolderIndex(rootPath)
        this._indexBuildCallback := cb
        SetTimer(cb, -800)
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
        if (this.GuiObj && this.GuiObj["AutoFilesCheck"].Value && !this.FilesShown.Has(id)) {
            fullPath := this._GetTVFullPath(tv, id)
            fileMax := 200
            try fileMax := Integer(IniRead(this.IniPath, "Settings", "FileMax", "200"))
            shown := []
            count := 0
            loop files, fullPath . "\*", "F" {
                if InStr(A_LoopFileAttrib, "H")
                    continue
                shown.Push(tv.Add(A_LoopFileName, id, "Icon2"))
                if (++count >= fileMax)
                    break
            }
            this.FilesShown[id] := shown
        }
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
        bcMenu.Show()
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

    static _QuickRegisterFromEdit() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        e := this.GuiObj["QuickPath"]
        path := Trim(e.Value)
        if (path = "")
            return
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

        this.lastRoot := name
        this.lastPath := path
        this._RefreshTree(tv, path)

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
        if (this.GuiObj.HasOwnProp("_btnEditHwnd") && currFocus = this.GuiObj._btnEditHwnd) {
            ; 編集ボタンがフォーカスなら編集GUIを開く
            this._ShowEditGui(this.GuiObj)
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
            ; ツリーフィルター欄がフォーカスの場合: IME変換中なら確定Enterを送る、それ以外はツリーへフォーカス移動
            hIMC := DllCall("imm32\ImmGetContext", "ptr", this.GuiObj._treeFilterHwnd, "ptr")
            if (hIMC) {
                composing := DllCall("imm32\ImmGetCompositionStringW", "ptr", hIMC, "uint", 0x0008, "ptr", 0, "ptr", 0) > 0
                DllCall("imm32\ImmReleaseContext", "ptr", this.GuiObj._treeFilterHwnd, "ptr", hIMC)
                if (composing) {
                    Send "{Enter}"  ; IMEに確定Enterを渡す
                    return
                }
            }
            this.GuiObj["FolderTree"].Focus()
            return
        }
        ; それ以外は従来通りエクスプローラー実行
        this.Execute("e")
    }

    static _HandleSpace() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        currFocus := 0
        try currFocus := DllCall("user32\GetFocus", "ptr")
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

    static _HandleRootBtnDown() {
        if !(this.GuiObj && WinExist(this.GuiObj))
            return
        currFocus := 0
        try currFocus := DllCall("user32\GetFocus", "ptr")
        if (this.GuiObj.HasOwnProp("_rootBtnHwnd") && currFocus = this.GuiObj._rootBtnHwnd) {
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
        actGui.MarginY := 15

        actGui.SetFont("s11 w700 cWhite", "Yu Gothic UI")
        actGui.Add("Text", "Center w" . this.MENU_BTN_W, "Selected: " . itemName)

        actGui.SetFont("s10 w400")
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

        btnCancel := actGui.Add("Button", "w" . this.MENU_BTN_W . " h" . this.MENU_BTN_H . " xm y+12", "&X: Cancel")
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
        ; ユーザーがリストをクリックした際はダブルクリックを待つ（何もしない）
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
        try DllCall("user32\SendMessageW", "ptr", filterEdit.Hwnd, "uint", 0x1501, "ptr", 1,
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
        ; WM_ACTIVATE (0x0006): wParam=0 でウィンドウが非アクティブになった時にオーバーレイを閉じる
        local ddHwnd := ddGui.Hwnd
        local self := this
        wmActivate(wParam, lParam, msg, hwnd) {
            if (hwnd = ddHwnd && wParam = 0) {
                OnMessage(0x0006, wmActivate, 0)  ; 登録解除
                SetTimer(() => self._CloseDropdown(), -50)
            }
        }
        OnMessage(0x0006, wmActivate)

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
            this.lastRoot := selectedTxt
            this.GuiObj["RootBtn"].Text := selectedTxt
            this.GuiObj["TreeFilter"].Value := ""  ; ルート切り替え時にフィルターをクリア
            tv := this.GuiObj["FolderTree"]
            this._RefreshTree(tv, this._FolderMap[selectedTxt])
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
        if (minmax = 1 || !(this.GuiObj && WinExist(this.GuiObj)))
            return
        margin := this.GuiObj.MarginX
        ctrlW  := w - 2 * margin

        ; 全幅コントロールを幅に追従させる
        this.GuiObj["QuickPath"].Move(,, ctrlW)
        this.GuiObj["Breadcrumb"].Move(,, ctrlW)
        this.GuiObj["TreeFilter"].Move(,, ctrlW)

        ; TreeView は StatusBar の上まで高さを埋める
        sbH := 28  ; フォールバック値
        if (this.GuiObj.HasOwnProp("_sbRef"))
            this.GuiObj._sbRef.GetPos(,, , &sbH)
        tvH := Max(60, h - this._tvY - sbH)
        this.GuiObj["FolderTree"].Move(,, ctrlW, tvH)
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
            Run('explorer.exe "' . path . '"')
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
