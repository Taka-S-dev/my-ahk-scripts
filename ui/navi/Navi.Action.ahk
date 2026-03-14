#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Action.ahk
; Description:  Navi用アクション管理モジュール
;               - アクションの登録・実行・メニュー表示
;               - _DefaultActions テーブルへの1行追加でアクションを拡張可能
;               - Navi.ini [Actions] セクション経由でシェルアクションを追加可能
; Usage:        NaviActions.Init(naviRef) を Navi.Init() から呼び出す
; ==============================================================================

class NaviActions {
    static _navi := ""
    static Actions := Map()  ; key(lower) => {label, run: (path)=>void}

    static Init(naviRef) {
        this._navi := naviRef
        this._InitDefaultActions()
        this._LoadUserActions()
    }

    static RegisterAction(key, label, fn) {
        this.Actions[StrLower(key)] := { label: label, run: fn }
    }

    static RegisterShellAction(key, label, cmdTemplate, runOpt := "") {
        ; {path} を選択パスで置換して実行
        this.RegisterAction(key, label, (path) => (
            Run(StrReplace(cmdTemplate, "{path}", path), , runOpt)
        ))
    }

    static ShowActionMenu() {
        nv := this._navi
        tvObj := nv.GuiObj["FolderTree"]
        if !(id := tvObj.GetSelection()) {
            ToolTip("フォルダを選択してください")
            SetTimer(() => ToolTip(), -1000)
            return
        }

        fullPath := nv._GetTVFullPath(tvObj, id)
        nv.GuiObj.GetPos(&gx, &gy, &gw, &gh)

        nv.GuiObj.Opt("+Disabled")

        actGui := Gui("+Owner" . nv.GuiObj.Hwnd . " -Caption +AlwaysOnTop +Border")
        actGui.BackColor := nv.MENU_BG_COLOR
        actGui.MarginX := 10
        actGui.MarginY := 8

        folderName := (InStr(fullPath, "\")) ? StrSplit(fullPath, "\")[-1] : fullPath
        actGui.SetFont("s8 w400 cA0A0A0", "Yu Gothic UI")
        actGui.Add("Text", "Center w" . nv.MENU_BTN_W, folderName)

        actGui.SetFont("s9 w400 cWhite")
        ; Actions Map に登録されたアクションからボタンを生成
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
            btn := actGui.Add("Button", "w" . nv.MENU_BTN_W . " h" . nv.MENU_BTN_H . " xm", act.label)
            btn.OnEvent("Click", ((kk, *) => (
                nv.GuiObj.Opt("-Disabled"),
                actGui.Destroy(),
                this.Execute(kk)
            )).Bind(k))
        }

        btnCancel := actGui.Add("Button", "w" . nv.MENU_BTN_W . " h" . nv.MENU_BTN_H . " xm y+6", "&X: Cancel")
        btnCancel.OnEvent("Click", (*) => (nv.GuiObj.Opt("-Disabled"), actGui.Destroy()))
        actGui.OnEvent("Escape", (*) => (nv.GuiObj.Opt("-Disabled"), actGui.Destroy()))

        actGui.Show("AutoSize x" . gx + (gw - nv.MENU_WIDTH) // 2 . " y" . gy + (gh - nv.MENU_OFFSET_Y) // 2)
    }

    static Execute(key) {
        nv := this._navi
        fullPath := ""
        if (nv.GuiObj && WinExist(nv.GuiObj)) {
            tvObj := nv.GuiObj["FolderTree"]
            if (id := tvObj.GetSelection()) {
                fullPath := nv._GetTVFullPath(tvObj, id)
                ; 操作したパスをメモリに保存
                nv.lastPath := fullPath
            }
        }
        if (fullPath == "") {
            fullPath := nv._GetActiveWindowPath()
        }

        if (fullPath != "" && (DirExist(fullPath) || FileExist(fullPath))) {
            ; 外部アプリ起動前にGUIを先に閉じる
            ; （ExplorerなどがAlwaysOnTopのNavi裏に隠れたり、ウィンドウアクティベーション競合を防ぐ）
            if (nv.GuiObj && WinExist(nv.GuiObj)) {
                ; actGui破棄後の黒塗り描画崩れを常に回復
                WinRedraw(nv.GuiObj)
                k := StrLower(key)
                if (k != "f" && k != "r" && !nv.GuiObj["PinCheck"].Value && !GetKeyState("Shift", "P")) {
                    if (IniRead(nv.IniPath, "Settings", "AutoMinimizeOnAction", "0") == "1")
                        nv.GuiObj.Minimize()
                    else
                        nv._DestroyGui()
                }
            }
            this._ExecuteAction(key, fullPath)
            if (key != "k" && StrLower(key) != "f" && StrLower(key) != "r") {
                ToolTip("実行 [" . key . "]: " . fullPath)
                SetTimer(() => ToolTip(), -nv.TOOLTIP_SUCCESS_DURATION)
            }
        } else {
            ToolTip("対象のパスが見つかりません")
            SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
        }
    }

    static _ExecuteAction(key, path) {
        nv := this._navi
        k := StrLower(key)
        if (this.Actions.Has(k)) {
            fn := this.Actions[k].run
            try {
                fn.Call(path)
            } catch as e {
                ToolTip("Action error: " . e.Message)
                SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
            }
        } else {
            ToolTip("未定義のアクション: " . key)
            SetTimer(() => ToolTip(), -nv.TOOLTIP_ERROR_DURATION)
        }
    }

    ; ==============================================================================
    ; デフォルトアクション定義テーブル
    ; 新しいアクションを追加するにはここに1行追加するだけ。
    ;
    ; 形式:
    ;   fn    形式: { key: "x", label: "&X: 表示名", fn: (path, nv) => 処理 }
    ;   shell 形式: { key: "x", label: "&X: 表示名", shell: "コマンド {path}", opt: "Hide"(省略可) }
    ;
    ; fn の引数:
    ;   path ... 選択されたフォルダ/ファイルの絶対パス
    ;   nv   ... Navi インスタンス（GuiObj, ExplorerPath, TOOLTIP_* 等にアクセス可）
    ; ==============================================================================
    static _DefaultActions := [{ key: "e", label: "&E: Explorer",
        fn: (path, nv) => (DirExist(path) || SplitPath(path, , &path), nv._ActivateOrOpenExplorer(path)) }, { key: "t", label: "&t: Preferred Explorer",
            fn: (path, nv) => (DirExist(path) || SplitPath(path, , &path),
                (nv.ExplorerPath == "explorer.exe")
                    ? Run('explorer.exe "' . path . '"')
                : (FileExist(nv.ExplorerPath) ? Run('"' . nv.ExplorerPath . '" "' . path . '"') : 0)) }, { key: "v", label: "&V: VS Code", shell: A_ComSpec . ' /c code "{path}"', opt: "Hide" }, { key: "c", label: "&C: Command Prompt", shell: A_ComSpec . ' /K cd /d "{path}"' }, { key: "p", label: "&P: PowerShell",
                    shell: 'powershell.exe -NoExit -Command Set-Location -LiteralPath "{path}"' }, { key: "k", label: "&K: Copy Path",
                        fn: (path, nv) => (A_Clipboard := path, ToolTip("Path Copied: " . path),
                            SetTimer(() => ToolTip(), -nv.TOOLTIP_COPY_DURATION)) }, { key: "n", label: "&N: Copy Name",
                                fn: (path, nv) => (SplitPath(path, &fn), name := (fn != "" ? fn : path),
                                    A_Clipboard := name, ToolTip("Name Copied: " . name),
                                    SetTimer(() => ToolTip(), -nv.TOOLTIP_COPY_DURATION)) }, { key: "o", label: "&O: Open Temp Copy", fn: (path, *) => TempCopy.Open(path) }, { key: "f", label: "&F: Search (Local)", fn: (path, nv) => NaviSearch.RunLocal(nv, path) }, { key: "r", label: "&R: Right-Click Menu", fn: (path, nv) => NaviContextMenu.Show(path, nv) },
    ]

    static _InitDefaultActions() {
        nv := this._navi
        for entry in this._DefaultActions {
            if entry.HasOwnProp("shell") {
                opt := entry.HasOwnProp("opt") ? entry.opt : ""
                this.RegisterShellAction(entry.key, entry.label, entry.shell, opt)
            } else {
                ; .Bind(fn) でループ変数を値キャプチャ（参照キャプチャによる上書き防止）
                this.RegisterAction(entry.key, entry.label, ((f, path) => f(path, nv)).Bind(entry.fn))
            }
        }
    }

    ; Navi.ini の [Actions] セクションにシェルアクションを追加できる。
    ; 形式: key=ラベル|shell|コマンド {path}[|Hide]
    ;
    ; 例:
    ;   g=&G: Git Bash|shell|"C:\Program Files\Git\bin\bash.exe" --cd="{path}"
    ;   z=&Z: 7-Zip|shell|"C:\Program Files\7-Zip\7zFM.exe" "{path}"
    ;   w=&W: WinMerge|shell|"C:\Program Files\WinMerge\WinMergeU.exe" "{path}"
    static _LoadUserActions() {
        nv := this._navi
        try {
            content := IniRead(nv.IniPath, "Actions", , "")
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
