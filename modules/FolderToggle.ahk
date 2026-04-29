; ==============================================================================
; Module:       FolderToggle.ahk
; Description:  ファイラー（エクスプローラー/Tablacus等）の表示・非表示切り替え
;               - アクティブ時は最小化、非アクティブ時は表示・アクティブ化
;               - 最小化時に直前のウィンドウへフォーカスを自動復元する機能を搭載
;               - 複数ファイラーをINIに登録してトレイメニューから切り替え可能
;               - 初回起動時に実行ファイルのパスを自動設定・INI保存する機能
; Version:      1.0.0
; License:      MIT
;
; Usage Example (Main.ahk):
;   #Include FolderToggle.ahk
;   FolderToggle.Init("config.ini")
;   FolderToggle.BuildTrayMenu()
;   MButton:: FolderToggle.Execute()
;
; INI Format:
;   [Common]
;   Explorer1=C:\path\to\tablacus.exe
;   Explorer2=C:\Windows\explorer.exe
;   ActiveExplorer=1
; ==============================================================================
#Requires AutoHotkey v2.0

class FolderToggle {
    ; ============ 設定 =====================
    static FILE_SELECT_OPT := 3
    static WINDOW_MINIMIZED := -1
    static WAIT_TIMEOUT_SEC := 3
    static SLEEP_FOCUS_BUFFER := 10
    static SLEEP_ANIMATION := 100
    static SLEEP_RETRY_ACT := 50
    ; ========================================

    static PrevHwnd := 0
    static _Busy := false
    static IniPath := ""
    static _Section := "Common"
    static _Explorers := []   ; [{path, name, winClass}, ...]
    static _ActiveIdx := 1

    ; 後方互換プロパティ
    static ExplorerPath => (this._Explorers.Length > 0) ? this._Explorers[this._ActiveIdx].path : ""
    static TargetWin => (this._Explorers.Length > 0) ? this._Explorers[this._ActiveIdx].winClass : ""

    static Init(iniPath, section := "Common") {
        this.IniPath := iniPath
        this._Section := section
        this._LoadConfig()
    }

    static _LoadConfig() {
        this._Explorers := []
        ; Explorer1, Explorer2, ... を順に読み込む
        i := 1
        loop {
            path := IniRead(this.IniPath, this._Section, "Explorer" . i, "")
            if (path = "")
                break
            this._Explorers.Push(this._MakeEntry(path))
            i++
        }
        ; 後方互換: 旧 ExplorerPath キーから移行
        if (this._Explorers.Length = 0) {
            path := IniRead(this.IniPath, this._Section, "ExplorerPath", "")
            if (path != "") {
                this._Explorers.Push(this._MakeEntry(path))
                IniWrite(path, this.IniPath, this._Section, "Explorer1")
            }
        }
        ; 初回セットアップ
        if (this._Explorers.Length = 0) {
            path := this._FirstTimeSetup()
            this._Explorers.Push(this._MakeEntry(path))
            IniWrite(path, this.IniPath, this._Section, "Explorer1")
        }
        ; アクティブインデックス読み込み
        idx := Integer(IniRead(this.IniPath, this._Section, "ActiveExplorer", "1"))
        this._ActiveIdx := (idx >= 1 && idx <= this._Explorers.Length) ? idx : 1
    }

    static _MakeEntry(path) {
        SplitPath(path, &exeName)
        name := SubStr(exeName, 1, InStr(exeName, ".", , , -1) - 1)
        winClass := this._ResolveWinClass(exeName)
        return { path: path, name: name, winClass: winClass }
    }

    static _ResolveWinClass(exeName) {
        switch StrLower(exeName) {
            case "explorer.exe":
                return "ahk_class CabinetWClass"
            case "tablacusexplorer.exe", "te.exe":
                return "ahk_class TablacusExplorer"
            default:
                return "ahk_exe " . exeName
        }
    }

    static _FirstTimeSetup() {
        msg := "エクスプローラーのパスが未設定です。`n`n[Yes]: 外部ファイラーを選択`n[No]: 標準エクスプローラー"
        if (MsgBox(msg, "初期設定", "YesNo") == "Yes") {
            selected := FileSelect(this.FILE_SELECT_OPT, , "exeを選択", "*.exe")
            return (selected != "") ? selected : ExitApp()
        }
        return "explorer.exe"
    }

    /**
     * トレイメニューに設定項目を追加する
     * Init() の後に呼ぶ。設定変更後は RebuildTrayMenu() で再構築する
     */
    static BuildTrayMenu() {
        A_TrayMenu.Add()
        this._AddTrayItems()
    }

    static RebuildTrayMenu() {
        try A_TrayMenu.Delete("Explorer Settings...")
        this._AddTrayItems()
    }

    static _AddTrayItems() {
        A_TrayMenu.Add("Explorer Settings...", (*) => this.ShowSettings())
    }

    /**
     * ファイラー登録・切替の設定GUIを表示する
     * activeRef は [activeIdx] の1要素配列でヘルパーメソッド間の可変共有に使う
     */
    static ShowSettings() {
        g := Gui("+AlwaysOnTop -MaximizeBox -MinimizeBox", "ファイラー設定")
        g.SetFont("s9", "Yu Gothic UI")
        g.MarginX := 12
        g.MarginY := 10

        g.Add("Text", "xm", "登録済みファイラー（ダブルクリックでアクティブに設定）")
        lv := g.Add("ListView", "xm y+6 w460 r6 -Multi", ["", "名前", "パス"])
        lv.ModifyCol(1, 20)
        lv.ModifyCol(2, 100)
        lv.ModifyCol(3, 320)

        rows := []
        for i, e in this._Explorers
            rows.Push({ path: e.path, name: e.name })
        activeRef := [this._ActiveIdx]

        FolderToggle._SettingsPopulate(lv, rows, activeRef)

        btnAdd := g.Add("Button", "xm y+6 w70", "追加 ▼")
        btnRemove := g.Add("Button", "x+4 yp w70", "削除")
        btnUp := g.Add("Button", "x+4 yp w40", "↑")
        btnDown := g.Add("Button", "x+4 yp w40", "↓")
        btnActive := g.Add("Button", "x+4 yp w130", "アクティブに設定")
        g.Add("Text", "xm y+10 w460 0x10")
        btnOK := g.Add("Button", "xm y+8 w80 Default", "OK")
        btnCancel := g.Add("Button", "x+4 yp w80", "キャンセル")

        lv.OnEvent("DoubleClick", (ctrl, row) => FolderToggle._SettingsDblClick(ctrl, rows, activeRef, row))
        btnAdd.OnEvent("Click", (*) => FolderToggle._SettingsAddMenu(lv, rows, activeRef))
        btnRemove.OnEvent("Click", (*) => FolderToggle._SettingsRemove(lv, rows, activeRef))
        btnUp.OnEvent("Click", (*) => FolderToggle._SettingsMove(lv, rows, activeRef, -1))
        btnDown.OnEvent("Click", (*) => FolderToggle._SettingsMove(lv, rows, activeRef, 1))
        btnActive.OnEvent("Click", (*) => FolderToggle._SettingsSetActive(lv, rows, activeRef))
        btnOK.OnEvent("Click", (*) => FolderToggle._SettingsSave(rows, activeRef, g))
        btnCancel.OnEvent("Click", (*) => g.Destroy())
        g.OnEvent("Close", (*) => g.Destroy())

        g.Show("AutoSize")
    }

    static _SettingsPopulate(lv, rows, activeRef) {
        lv.Delete()
        for i, r in rows {
            mark := (i = activeRef[1]) ? "✓" : ""
            lv.Add(, mark, r.name, r.path)
        }
    }

    static _SettingsDblClick(lv, rows, activeRef, row) {
        if (row <= 0)
            return
        activeRef[1] := row
        FolderToggle._SettingsPopulate(lv, rows, activeRef)
    }

    static _SettingsAddMenu(lv, rows, activeRef) {
        m := Menu()
        m.Add("ファイルを選択...", (*) => FolderToggle._SettingsAddFile(lv, rows, activeRef))
        m.Add("標準エクスプローラー", (*) => FolderToggle._SettingsAddExplorer(lv, rows, activeRef))
        m.Show()
    }

    static _SettingsAddFile(lv, rows, activeRef) {
        sel := FileSelect(3, , "ファイラーの exe を選択", "実行ファイル (*.exe)")
        if (sel = "")
            return
        SplitPath(sel, &exeName)
        name := SubStr(exeName, 1, InStr(exeName, ".", , , -1) - 1)
        rows.Push({ path: sel, name: name })
        FolderToggle._SettingsPopulate(lv, rows, activeRef)
    }

    static _SettingsAddExplorer(lv, rows, activeRef) {
        rows.Push({ path: "explorer.exe", name: "explorer" })
        FolderToggle._SettingsPopulate(lv, rows, activeRef)
    }

    static _SettingsRemove(lv, rows, activeRef) {
        row := lv.GetNext()
        if (row = 0 || rows.Length <= 1)
            return
        rows.RemoveAt(row)
        if (activeRef[1] > rows.Length)
            activeRef[1] := rows.Length
        FolderToggle._SettingsPopulate(lv, rows, activeRef)
    }

    static _SettingsMove(lv, rows, activeRef, dir) {
        row := lv.GetNext()
        newRow := row + dir
        if (row = 0 || newRow < 1 || newRow > rows.Length)
            return
        tmp := rows[newRow], rows[newRow] := rows[row], rows[row] := tmp
        if (activeRef[1] = row)
            activeRef[1] := newRow
        else if (activeRef[1] = newRow)
            activeRef[1] := row
        FolderToggle._SettingsPopulate(lv, rows, activeRef)
        lv.Modify(newRow, "Select Focus")
    }

    static _SettingsSetActive(lv, rows, activeRef) {
        row := lv.GetNext()
        if (row <= 0)
            return
        activeRef[1] := row
        FolderToggle._SettingsPopulate(lv, rows, activeRef)
    }

    static _SettingsSave(rows, activeRef, g) {
        loop 20
            IniDelete(FolderToggle.IniPath, FolderToggle._Section, "Explorer" . A_Index)
        for i, r in rows
            IniWrite(r.path, FolderToggle.IniPath, FolderToggle._Section, "Explorer" . i)
        IniWrite(activeRef[1], FolderToggle.IniPath, FolderToggle._Section, "ActiveExplorer")
        FolderToggle._LoadConfig()
        FolderToggle.RebuildTrayMenu()
        g.Destroy()
    }

    static Execute() {
        if (this._Busy)
            return
        this._Busy := true
        try {
            targetHwnd := WinExist(this.TargetWin)

            if (targetHwnd && WinActive("ahk_id " . targetHwnd)) {
                WinMinimize("ahk_id " . targetHwnd)
                this._RestoreFocus()
                return
            }

            activeID := WinActive("A")
            if (activeID && activeID != targetHwnd)
                this.PrevHwnd := activeID

            if (targetHwnd) {
                if (WinGetMinMax("ahk_id " . targetHwnd) = this.WINDOW_MINIMIZED)
                    WinRestore("ahk_id " . targetHwnd)
                WinActivate("ahk_id " . targetHwnd)
                Sleep(this.SLEEP_FOCUS_BUFFER)
            } else {
                try {
                    Run(this.ExplorerPath)
                    if (WinWait(this.TargetWin, , this.WAIT_TIMEOUT_SEC))
                        WinActivate(this.TargetWin)
                } catch Error as e {
                    MsgBox("起動失敗: " . e.Message)
                }
            }
        } finally {
            this._Busy := false
        }
    }

    static _RestoreFocus() {
        Sleep(this.SLEEP_ANIMATION)
        if (this.PrevHwnd && WinExist("ahk_id " . this.PrevHwnd)) {
            WinActivate("ahk_id " . this.PrevHwnd)
            if (!WinActive("ahk_id " . this.PrevHwnd)) {
                Sleep(this.SLEEP_RETRY_ACT)
                WinActivate("ahk_id " . this.PrevHwnd)
            }
        } else {
            WinActivate("ahk_class Shell_TrayWnd")
        }
    }
}
