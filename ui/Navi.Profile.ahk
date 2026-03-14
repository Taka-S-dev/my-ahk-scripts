#Requires AutoHotkey v2.0
; ==============================================================================
; Module:      Navi.Profile.ahk
; Description: Navi プロファイル管理モジュール
;              - プロファイルファイルの読み書き・インポート
;              - プロファイル選択ドロップダウン GUI
;              - 編集ダイアログ向けプロファイル操作（新規/複製/削除/リネーム）
;              - プロファイル切り替え時のインプレース UI 再構築
; Usage:       NaviProfile.Init(naviRef) を Navi.Init() から呼び出す
; ==============================================================================

class NaviProfile {
    static _navi := ""

    ; --- プロファイル状態 ---
    static ProfileDropdownGui    := ""   ; プロファイル選択ドロップダウン GUI
    static _AllProfileNames      := []   ; 全プロファイル名リスト
    static _ProfileFilteredNames := []   ; フィルター後プロファイル名リスト

    ; --- InputBox サイズ（プロファイル名入力ダイアログ共通） ---
    static _INPUTBOX_SIZE := "w260 h100"

    ; --- ProfileBtn の表示文字数上限（ボタン幅 w95 に合わせた値） ---
    static _PROFILE_BTN_MAX_LEN := 10

    static Init(naviRef) {
        this._navi := naviRef
    }

    ; ==============================================================================
    ; ファイル I/O
    ; ==============================================================================

    /**
     * ListView の内容をプロファイルファイルに書き出す（フォーマット: name=path）
     * メモリ上のマップから書き出す場合は WriteProfileFileFromMap() を使う。
     */
    static WriteProfileFile(lv, outPath) {
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
     * _AllFolderNames + _FolderMap からプロファイルファイルを書き出す
     * ドラッグ追加など ListView を介さずにメモリ上のマップから直接書き出す場合に使用する。
     */
    static WriteProfileFileFromMap(outPath) {
        nv := this._navi
        txt := ""
        for name in nv._AllFolderNames
            if (nv._FolderMap.Has(name))
                txt .= name . "=" . nv._FolderMap[name] . "`n"
        try FileDelete(outPath)
        FileAppend(txt, outPath, "UTF-8")
    }

    /**
     * .txt プロファイルを読み込んでルートリストを置き換え、インプレース更新または再起動する
     * フォーマット: name=path または path のみ（名前はフォルダ名から自動生成）
     */
    static ImportProfile(txtPath) {
        nv := this._navi
        if (!FileExist(txtPath)) {
            ToolTip("ファイルが見つかりません: " . txtPath), SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
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
                p := StrSplit(line, "=", , 2)
                name := Trim(p[1])
                path := Trim(p[2])
            } else {
                path := Trim(line)
                name := StrSplit(RTrim(path, "\"), "\")[-1]
            }
            if (name != "" && path != "")
                entries.Push({ name: name, path: path })
        }
        ; [Folders] セクションを新しいリストで上書き（空プロファイルはセクションをクリア）
        IniDelete(nv.IniPath, "Folders")
        for e in entries
            IniWrite(e.path . "|1", nv.IniPath, "Folders", e.name)
        ; 現プロファイルのタブ状態を保存（プロファイル別セクションに書き込む）
        NaviTab.SaveCurrentTab()
        NaviTab.SaveTabsToIni()
        ; 最後に使ったプロファイルパスを更新
        IniWrite(txtPath, nv.IniPath, "Settings", "LastProfile")
        ; GUI が開いていればインプレース更新、なければ再起動
        if (nv.GuiObj && WinExist(nv.GuiObj))
            this.ReloadProfileInPlace()
        else
            Reload()
    }

    /**
     * プロファイル切り替え・保存後のインプレース更新
     * GUI を閉じずにフォルダマップ・タブ・ツリーを現在の INI 内容で再構築する。
     * ImportProfile と _SaveList の両方から呼ばれる。
     */
    static ReloadProfileInPlace() {
        nv := this._navi
        ; フォルダデータを再読み込み
        newFolderMap := Map(), newFolderNames := []
        nv._LoadFolders(newFolderMap, newFolderNames)
        nv._AllFolderNames := newFolderNames
        nv.FilteredNames   := newFolderNames.Clone()
        nv._FolderMap      := newFolderMap

        ; 新プロファイルのタブ状態を読み込み
        NaviTab.LoadTabsFromIni()

        ; マーク状態をリセット
        nv._MarkedPaths      := Map()
        nv._MarkedIdSet      := Map()
        nv._MarkFilterActive := false

        ; ツリーを新プロファイルで復元
        tv := nv.GuiObj["FolderTree"]
        nv.GuiObj["TreeFilter"].Value := ""
        if (newFolderNames.Length == 0) {
            ; 空プロファイル: ツリーをクリアして RootBtn をリセット
            tv.Delete()
            nv.lastRoot := ""
            nv.lastPath := ""
        } else if (!NaviTab.RestoreCurrentTab(tv)) {
            ; 新プロファイルに前のルートがなければ先頭ルートへ
            nv.lastRoot := newFolderNames[1]
            nv._RefreshTree(tv, newFolderMap[nv.lastRoot])
        }

        ; UI 更新
        nv.GuiObj["RootBtn"].Text := (nv.lastRoot != "") ? nv._TruncRootLabel(nv.lastRoot) : "ルートを選択..."
        this.UpdateProfileBtn()
        NaviTab.UpdateTabBar()
        nv._UpdateStatusBar()
    }

    ; ==============================================================================
    ; プロファイル一覧
    ; ==============================================================================

    static _GetProfilesDir() {
        return A_ScriptDir . "\ui\Navi_profiles"
    }

    static GetProfileList() {
        dir := this._GetProfilesDir()
        if (!DirExist(dir))
            DirCreate(dir)
        names := []
        Loop Files dir . "\*.txt"
            names.Push(RegExReplace(A_LoopFileName, "\.txt$", ""))
        return names
    }

    static GetProfileBtnText() {
        nv := this._navi
        last := IniRead(nv.IniPath, "Settings", "LastProfile", "")
        if (last == "")
            return "Profile"
        name := RegExReplace(last, ".*\\")
        name := RegExReplace(name, "\.txt$")
        maxLen := this._PROFILE_BTN_MAX_LEN
        return (StrLen(name) > maxLen) ? SubStr(name, 1, maxLen - 1) . ".." : name
    }

    static UpdateProfileBtn() {
        nv := this._navi
        if (nv.GuiObj && WinExist(nv.GuiObj))
            nv.GuiObj["ProfileBtn"].Text := this.GetProfileBtnText()
    }

    ; ==============================================================================
    ; プロファイル選択ドロップダウン
    ; ==============================================================================

    static OpenProfileDropdown() {
        nv := this._navi
        if (this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return

        this._AllProfileNames      := this.GetProfileList()
        this._ProfileFilteredNames := this._AllProfileNames.Clone()

        ddGui := Gui("+Owner" . nv.GuiObj.Hwnd . " +AlwaysOnTop -MaximizeBox -MinimizeBox", "プロファイル")
        ddGui.MarginX := 8
        ddGui.MarginY := 8
        ddGui.SetFont("s10", "Yu Gothic UI")

        filterEdit := ddGui.Add("Edit", "xm w200 vProfileFilter")
        try DllCall("user32\SendMessageW", "ptr", filterEdit.Hwnd, "uint", nv.EM_SETCUEBANNER, "ptr", 1,
            "wstr", "名前でフィルター...", "ptr")

        ddList := ddGui.Add("ListBox", "xm w200 r8 vProfileList", this._ProfileFilteredNames)
        if (this._ProfileFilteredNames.Length > 0)
            ddList.Choose(1)

        ddGui.SetFont("s8")
        ddGui.Add("Text", "xm c808080", "↑↓: 移動  Enter: ロード  Esc: 閉じる")
        this.ProfileDropdownGui := ddGui

        filterEdit.OnEvent("Change",      (*) => this._ProfileOverlayFilterChange())
        ddList.OnEvent("DoubleClick",     (*) => this.ConfirmProfileDropdown())
        ddGui.OnEvent("Close",            (*) => this.CloseProfileDropdown())

        local ddHwnd   := ddGui.Hwnd
        local self     := this
        local wmActMsg := nv.WM_ACTIVATE
        wmAct(wParam, lParam, msg, hwnd) {
            if (hwnd = ddHwnd && wParam = 0) {
                OnMessage(wmActMsg, wmAct, 0)
                SetTimer(() => self.CloseProfileDropdown(), -50)  ; 非アクティブ検知後に即閉じると GUI 破棄中にイベントが再入する場合があるため 1 フレーム遅延
            }
        }
        OnMessage(wmActMsg, wmAct)

        HotIfWinActive("ahk_id " ddGui.Hwnd)
        Hotkey("Enter",  (*) => this.ConfirmProfileDropdown(), "On")
        Hotkey("Escape", (*) => this.CloseProfileDropdown(),   "On")
        Hotkey("~Down",  (*) => this._ProfileNavDown(),         "On")
        Hotkey("~Up",    (*) => this._ProfileNavUp(),           "On")
        HotIf()

        nv.GuiObj.GetPos(&gx, &gy)
        nv.GuiObj["ProfileBtn"].GetPos(&bx, &by, &bw, &bh)
        ddGui.Show("x" . (gx + bx) . " y" . (gy + by) . " w220 AutoSize")
        filterEdit.Focus()
    }

    static CloseProfileDropdown() {
        if !(this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        local ddGui := this.ProfileDropdownGui
        this.ProfileDropdownGui := ""
        try ddGui.Destroy()
    }

    ; プロファイル一覧を再スキャンしてドロップダウンの ListBox を更新する
    static _RefreshProfileDropdownList() {
        this._AllProfileNames := this.GetProfileList()
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
    static NewProfileDialog() {
        nv := this._navi
        this.CloseProfileDropdown()
        result := InputBox("新しいプロファイル名を入力してください:", "新規プロファイル", this._INPUTBOX_SIZE)
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
        this.WriteProfileFileFromMap(outPath)
        IniWrite(outPath, nv.IniPath, "Settings", "LastProfile")
        this.UpdateProfileBtn()
        ToolTip("作成しました: " . name), SetTimer(() => ToolTip(), -nv.TOOLTIP_COPY_DURATION)
    }

    static ConfirmProfileDropdown() {
        if !(this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        name := this.ProfileDropdownGui["ProfileList"].Text
        this.CloseProfileDropdown()
        if (name == "")
            return
        path := this._GetProfilesDir() . "\" . name . ".txt"
        this.ImportProfile(path)
    }

    static DeleteSelectedProfile() {
        nv := this._navi
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
        lastProfile := IniRead(nv.IniPath, "Settings", "LastProfile", "")
        if (lastProfile = path) {
            IniDelete(nv.IniPath, "Settings", "LastProfile")
            this.UpdateProfileBtn()
        }
        FileDelete(path)
        this._RefreshProfileDropdownList()
    }

    static RenameSelectedProfile() {
        nv := this._navi
        if !(this.ProfileDropdownGui && WinExist(this.ProfileDropdownGui))
            return
        name := this.ProfileDropdownGui["ProfileList"].Text
        if (name == "")
            return
        oldPath := this._GetProfilesDir() . "\" . name . ".txt"
        if (!FileExist(oldPath))
            return
        result := InputBox("新しい名前を入力してください:", "名前変更", this._INPUTBOX_SIZE, name)
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
        lastProfile := IniRead(nv.IniPath, "Settings", "LastProfile", "")
        if (lastProfile = oldPath) {
            IniWrite(newPath, nv.IniPath, "Settings", "LastProfile")
            this.UpdateProfileBtn()
        }
        this._RefreshProfileDropdownList()
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

    ; ==============================================================================
    ; 編集ダイアログ向けプロファイル操作
    ; ==============================================================================

    ; 空の新規プロファイルを作成（LV もクリアして編集状態にする）
    static NewProfileDialogFromEdit(editGui) {
        nv := this._navi
        editGui.Opt("-AlwaysOnTop")
        result := InputBox("新しいプロファイル名を入力してください:", "新規プロファイル", this._INPUTBOX_SIZE)
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
        IniWrite(outPath, nv.IniPath, "Settings", "LastProfile")
        this.UpdateProfileBtn()
        this.RefreshEditProfileList(editGui, name)
        this.LoadProfileIntoLV(editGui["FolderList"], name)  ; 空の LV に切り替え
        ToolTip("作成しました: " . name), SetTimer(() => ToolTip(), -nv.TOOLTIP_COPY_DURATION)
    }

    ; 現在の LV 内容をコピーして新規プロファイルを作成
    static DupProfileDialogFromEdit(editGui, lv) {
        nv := this._navi
        editGui.Opt("-AlwaysOnTop")
        result := InputBox("複製後のプロファイル名を入力してください:", "プロファイルを複製", this._INPUTBOX_SIZE)
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
        this.WriteProfileFile(lv, outPath)
        IniWrite(outPath, nv.IniPath, "Settings", "LastProfile")
        this.UpdateProfileBtn()
        this.RefreshEditProfileList(editGui, name)
        this.LoadProfileIntoLV(editGui["FolderList"], name)  ; 複製内容を LV に反映
        ToolTip("複製しました: " . name), SetTimer(() => ToolTip(), -nv.TOOLTIP_COPY_DURATION)
    }

    ; 編集ダイアログのドロップダウンで選択中のプロファイルを削除
    static DeleteProfileFromEdit(editGui) {
        nv := this._navi
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
        lastProfile := IniRead(nv.IniPath, "Settings", "LastProfile", "")
        if (lastProfile = path) {
            IniDelete(nv.IniPath, "Settings", "LastProfile")
            this.UpdateProfileBtn()
        }
        FileDelete(path)
        this.RefreshEditProfileList(editGui)
        this.LoadProfileIntoLV(editGui["FolderList"], editGui["EditProfileDDL"].Text)
    }

    ; 編集ダイアログのドロップダウンで選択中のプロファイルの名前を変更
    static RenameProfileFromEdit(editGui) {
        nv := this._navi
        name := editGui["EditProfileDDL"].Text
        if (name == "")
            return
        oldPath := this._GetProfilesDir() . "\" . name . ".txt"
        if (!FileExist(oldPath))
            return
        editGui.Opt("-AlwaysOnTop")
        result := InputBox("新しい名前を入力してください:", "名前変更", this._INPUTBOX_SIZE, name)
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
        lastProfile := IniRead(nv.IniPath, "Settings", "LastProfile", "")
        if (lastProfile = oldPath) {
            IniWrite(newPath, nv.IniPath, "Settings", "LastProfile")
            this.UpdateProfileBtn()
        }
        this.RefreshEditProfileList(editGui, newName)
    }

    ; 編集ダイアログのプロファイルドロップダウンリストを再構築
    ; selectName を指定するとその項目を選択する（省略時は先頭）
    static RefreshEditProfileList(editGui, selectName := "") {
        try {
            if !(editGui && WinExist(editGui))
                return
            names := this.GetProfileList()
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
    static LoadProfileIntoLV(lv, profileName) {
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
}
