; ==============================================================================
; Module:       QuickSwitch.ahk
; Description:  登録したウィンドウ/URLにホットキーで素早くジャンプ
;               - ウィンドウが開いていればアクティブ化（再押しで最小化）
;               - 開いていなければ URL / パスを起動
;               - プロファイルで表示するターゲットを切り替え可能
;               - デフォルト設定時は直接ジャンプ、未設定時はメニュー表示
;               - ターゲットごとに 無変換+任意キー を動的登録可能
;
; Usage Example (Main.ahk):
;   #Include "ui\QuickSwitch.ahk"
;   QuickSwitch.Init()
;   #HotIf GetKeyState("vk1D", "P")
;   a::  QuickSwitch.Show()     ; デフォルトに直接ジャンプ（未設定時はメニュー）
;   +a:: QuickSwitch.ShowMenu() ; 常にメニュー表示
;   #HotIf
;
; ==============================================================================
#Requires AutoHotkey v2.0

class QuickSwitch {
    static IniPath        := A_ScriptDir "\ui\QuickSwitch.ini"
    static IniVersion     := 2
    static DefaultTarget  := ""
    static ActiveProfile  := ""
    static _registeredKeys  := []
    static _hotifFn         := ""
    static _pendingCapture  := ""
    static _prevHwnd        := 0
    static _busy            := false
    static _lvTipState      := Map()

    ; メニュー状態（同時に開けるメニューは1つのみ）
    static _menuGui         := 0
    static _menuHwnd        := 0
    static _menuTimerFn     := ""
    static _menuKeys        := []
    static _menuHotifFn     := ""

    ; Win32 ListView メッセージ
    static _LVM_GETITEMRECT    := 0x100E
    static _LVM_SUBITEMHITTEST := 0x1039

    ; 最小化後のフォーカス復元タイミング（ms）
    static _DELAY_MINIMIZE_CHECK   := -80   ; WinMinimize完了待ち
    static _DELAY_MINIMIZE_RECHECK := -120  ; 最小化が遅いアプリの再確認待ち
    static _DELAY_FOCUS_RESTORE    := -150  ; 最小化アニメーション完了待ち
    static _DELAY_MENU_JUMP        := -80   ; メニュー破棄後の OS フォーカス返却待ち

    ; キーリピート/連打によるトグル往復（ブリンク）防止（ms）
    static _DEBOUNCE_JUMP := 300
    static _lastJumpName  := ""
    static _lastJumpTick  := 0

    ; ジャンプの世代番号。古いジャンプが仕掛けたタイマーが後から発火して
    ; 新しいジャンプ先からフォーカスを奪う（ブリンクする）のを防ぐ
    static _jumpSeq := 0

    static Init() {
        if !FileExist(this.IniPath) {
            IniWrite(this.IniVersion,                      this.IniPath, "Settings", "Version")
            IniWrite("",                                   this.IniPath, "Settings", "Default")
            IniWrite("",                                   this.IniPath, "Settings", "ActiveProfile")
            IniWrite("ahk_class CabinetWClass|explorer.exe|MButton", this.IniPath, "Targets", "エクスプローラー")
        }
        ver := Integer(IniRead(this.IniPath, "Settings", "Version", 1))
        if (ver < 2) {
            IniWrite("", this.IniPath, "Settings", "ActiveProfile")
            IniWrite(2,  this.IniPath, "Settings", "Version")
        }
        this.DefaultTarget := IniRead(this.IniPath, "Settings", "Default", "")
        this.ActiveProfile := IniRead(this.IniPath, "Settings", "ActiveProfile", "")
        ; HotIf関数は同一参照で登録/解除する必要があるため一度だけ生成
        this._hotifFn := (_) => GetKeyState("vk1D", "P")
        ; メニュー用も同一参照で使い回し、開くたびのバリアント増殖を防ぐ
        this._menuHotifFn := (_) => this._menuHwnd && WinActive("ahk_id " . this._menuHwnd)
        this._RegisterHotkeys()

        A_TrayMenu.Add()
        A_TrayMenu.Add("QuickSwitch Settings...", (*) => this._ShowSettings())
    }

    ; デフォルト設定時は直接ジャンプ、未設定時はメニュー表示
    static Show() {
        if (this.DefaultTarget != "")
            this._Jump(this.DefaultTarget)
        else
            this.ShowMenu()
    }

    static ShowSettings() {
        this._ShowSettings()
    }

    ; アクティブプロファイルでフィルタされたターゲットポップアップ
    static ShowMenu() {
        this._CloseMenu()

        ; メニュー表示前のアクティブウィンドウを記録（ジャンプのトグル判定基準。
        ; メニュー破棄直後の WinActive はフォーカス復帰と競合して不定になるため）
        prevActive := WinActive("A")
        targets := this._GetActiveTargets()

        pg := Gui("+AlwaysOnTop -Caption +Border +ToolWindow", "QuickSwitch")
        pg.SetFont("s10", "Segoe UI")
        pg.MarginX := 0
        pg.MarginY := 0

        lv := pg.Add("ListView", "xm ym w220 h20 -Hdr -Multi NoSort AltSubmit", ["キー", "名前"])
        lv.ModifyCol(1, 40)
        lv.ModifyCol(2, 176)

        for name in targets {
            key  := this._GetTargetKey(name)
            mark := (name == this.DefaultTarget) ? "★ " : "  "
            lv.Add("", (key != "" ? "[" . key . "]" : ""), mark . name)
        }

        if (targets.Length == 0)
            lv.Add("", "", "（ターゲット未設定）")

        ; 先頭アイテムを選択
        if (lv.GetCount() > 0)
            lv.Modify(1, "Select Focus")

        ; マウス位置に一旦表示して行高さを取得
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        pg.Show("x" . mx . " y" . my . " AutoSize")

        ; 実際の行高さを取得してリサイズ
        RECT := Buffer(16, 0)
        SendMessage(this._LVM_GETITEMRECT, 0, RECT.Ptr, lv)
        rowH := NumGet(RECT, 12, "Int") - NumGet(RECT, 4, "Int")
        if (rowH <= 0)
            rowH := Round(A_ScreenDPI / 96 * 20)  ; 96=標準DPI(100%)、20=デフォルト行高さ(px)

        lvH := rowH * (targets.Length > 0 ? targets.Length : 1) + 2
        lv.Move(0, 0, 220, lvH)
        ; ボーダー差分を実測して補正
        WinGetPos(,, &wW, &wH, "ahk_id " . pg.Hwnd)
        WinGetClientPos(,, &cW, &cH, "ahk_id " . pg.Hwnd)
        WinMove(mx, my, 220 + (wW - cW), lvH + (wH - cH), "ahk_id " . pg.Hwnd)

        ; このウィンドウがアクティブな間だけ有効なホットキーを登録
        this._menuGui  := pg
        this._menuHwnd := pg.Hwnd

        HotIf(this._menuHotifFn)
        Hotkey("Escape", (*) => this._CloseMenu(), "On")
        Hotkey("Enter",  (*) => this._OnMenuEnter(lv, targets, prevActive), "On")
        for name in targets {
            key := this._GetTargetKey(name)
            if (key != "") {
                try {
                    Hotkey(key, this._MakeMenuJumpCallback(name, prevActive), "On")
                    this._menuKeys.Push(key)
                }
            }
        }
        HotIf()

        ; フォーカスを失ったら閉じる（100ms ポーリング）
        winHwnd := pg.Hwnd
        this._menuTimerFn := () => (WinExist("ahk_id " . winHwnd) && !WinActive("ahk_id " . winHwnd)) ? this._CloseMenu() : 0
        SetTimer(this._menuTimerFn, 100)

        pg.OnEvent("Close", (*) => this._CloseMenu())
        lv.OnEvent("Click", (ctrl, row) => this._OnMenuActivate(row, targets, prevActive))
    }

    ; メニューの後始末。Destroy() では Close イベントが発火しないため、
    ; 全ての閉じ経路（Escape / Enter / ジャンプ / フォーカス喪失）からこれを呼ぶ
    static _CloseMenu() {
        if !this._menuGui
            return
        if this._menuTimerFn {
            SetTimer(this._menuTimerFn, 0)
            this._menuTimerFn := ""
        }
        HotIf(this._menuHotifFn)
        try Hotkey("Escape", "Off")
        try Hotkey("Enter",  "Off")
        for key in this._menuKeys
            try Hotkey(key, "Off")
        HotIf()
        pg := this._menuGui
        this._menuGui  := 0
        this._menuHwnd := 0
        this._menuKeys := []
        try pg.Destroy()
    }

    static _MakeMenuJumpCallback(name, refActive) {
        return (*) => this._ExecMenuJump(name, refActive)
    }

    static _ExecMenuJump(name, refActive) {
        this._CloseMenu()
        ; メニュー破棄直後は OS が直前ウィンドウへフォーカスを返す処理と競合して
        ; ブリンクするため、返却が済んでからジャンプする
        SetTimer(() => this._Jump(name, refActive), this._DELAY_MENU_JUMP)
    }

    static _OnMenuEnter(lv, targets, refActive) {
        row := lv.GetNext()
        if (row >= 1 && row <= targets.Length)
            this._ExecMenuJump(targets[row], refActive)
    }

    static _OnMenuActivate(row, targets, refActive) {
        if (row >= 1 && row <= targets.Length)
            this._ExecMenuJump(targets[row], refActive)
    }

    ; =========================================================================
    ; ホットキー動的登録
    ; =========================================================================
    static _RegisterHotkeys() {
        ; 既存ホットキーを解除（登録時のコンテキストに合わせて解除）
        for item in this._registeredKeys {
            if item.global
                HotIf()
            else
                HotIf(this._hotifFn)
            try Hotkey(item.key, "Off")
        }
        HotIf()
        this._registeredKeys := []

        ; ターゲットごとにキーを登録
        ; 修飾キー付き（^!+#）はグローバル登録、プレーンキーは無変換必須
        loop parse, IniRead(this.IniPath, "Targets"), "`n", "`r" {
            if InStr(A_LoopField, "=") {
                kv    := StrSplit(A_LoopField, "=", , 2)
                name  := kv[1]
                parts := StrSplit(kv[2], "|", , 4)
                key   := parts.Length >= 3 ? Trim(parts[3]) : ""
                if (key != "") {
                    isGlobal := RegExMatch(key, "^[!^+#]") || RegExMatch(key, "i)^(Wheel|LButton|RButton|MButton|XButton)")
                    if isGlobal
                        HotIf()
                    else
                        HotIf(this._hotifFn)
                    try {
                        Hotkey(key, this._MakeJumpCallback(name), "On")
                        this._registeredKeys.Push({key: key, global: isGlobal})
                    }
                }
            }
        }
        HotIf()
    }

    ; クロージャ変数キャプチャ問題を回避するファクトリ
    static _MakeJumpCallback(name) {
        return (*) => this._Jump(name)
    }

    ; =========================================================================
    ; ターゲット取得ヘルパー
    ; =========================================================================
    static _GetActiveTargets() {
        allNames := []
        try {
            loop parse, IniRead(this.IniPath, "Targets"), "`n", "`r" {
                if InStr(A_LoopField, "=")
                    allNames.Push(StrSplit(A_LoopField, "=")[1])
            }
        }

        if (this.ActiveProfile == "")
            return allNames

        profileVal := IniRead(this.IniPath, "Profiles", this.ActiveProfile, "")
        if (profileVal == "")
            return allNames

        filtered     := []
        profileNames := StrSplit(profileVal, ",")
        for pName in profileNames {
            pName := Trim(pName)
            for aName in allNames {
                if (aName == pName) {
                    filtered.Push(aName)
                    break
                }
            }
        }
        return filtered
    }

    static _GetTargetKey(name) {
        value := IniRead(this.IniPath, "Targets", name, "")
        parts := StrSplit(value, "|", , 4)
        return parts.Length >= 4 ? Trim(parts[4]) : ""
    }

    ; =========================================================================
    ; ジャンプ
    ; =========================================================================
    ; refActive: 判定基準となる「操作前にアクティブだったウィンドウ」。
    ; メニュー経由ではメニュー表示前の HWND を渡す（省略時はその場で取得）
    static _Jump(name, refActive := 0) {
        if this._busy
            return

        ; 同一ターゲットへの連続発火（キーのオートリピート・ホイール連続入力）を無視。
        ; 毎回タイムスタンプを更新するため、押しっぱなしの間は再発火しない
        now      := A_TickCount
        isRepeat := (name == this._lastJumpName && now - this._lastJumpTick < this._DEBOUNCE_JUMP)
        this._lastJumpName := name
        this._lastJumpTick := now
        if isRepeat
            return

        ; 新しいジャンプ開始 → 古いジャンプ由来のタイマーを世代番号で無効化
        seq := ++this._jumpSeq

        this._busy := true
        try {
            value     := IniRead(this.IniPath, "Targets", name, "")
            parts     := StrSplit(value, "|", , 4)
            windowPat := parts.Length >= 1 ? Trim(parts[1]) : ""
            url       := parts.Length >= 2 ? Trim(parts[2]) : ""

            if (refActive == 0)
                refActive := WinActive("A")

            if (windowPat != "") {
                hwnd := this._FindNonBrowserWindow(windowPat)
                if !hwnd
                    hwnd := WinExist(windowPat)
                if hwnd {
                    isMinimized := WinGetMinMax("ahk_id " . hwnd) == -1
                    if (hwnd == refActive && !isMinimized) {
                        ; 操作対象自身がアクティブ → 最小化して直前ウィンドウへ復元
                        ; prevHwnd が自分自身なら復元先がないのでクリア
                        if (this._prevHwnd == hwnd)
                            this._prevHwnd := 0
                        WinMinimize("ahk_id " . hwnd)
                        SetTimer(() => this._MinimizeFallback(hwnd, seq), this._DELAY_MINIMIZE_CHECK)
                    } else {
                        ; 非アクティブ or 最小化済み → 直前ウィンドウを記録してアクティブ化
                        if (refActive && refActive != hwnd)
                            this._prevHwnd := refActive
                        try {
                            if isMinimized
                                WinRestore("ahk_id " . hwnd)
                            WinActivate("ahk_id " . hwnd)
                            ; フォアグラウンドロックで無視されることがあるため1回だけ再試行
                            if !WinWaitActive("ahk_id " . hwnd, , 0.3)
                                WinActivate("ahk_id " . hwnd)
                        }
                    }
                    return
                }
            }
            ; ウィンドウが存在しない場合のみ起動
            if (url != "")
                Run(url)
            else if (windowPat != "") {
                Run(windowPat)
                try WinWait(windowPat, , 3)
            }
        } finally {
            this._busy := false
        }
    }

    ; WinMinimizeが効かないアプリへのフォールバック（Electron等）
    ; seq が現在の世代と違えば、新しいジャンプが始まっているので何もしない
    static _MinimizeFallback(hwnd, seq) {
        if (seq != this._jumpSeq || !WinExist("ahk_id " . hwnd))
            return
        if (WinGetMinMax("ahk_id " . hwnd) != -1) {
            ; 単に最小化処理が遅いだけの可能性があるため、即座に強制せず
            ; もう一度だけ待って再確認（最小化完了直後の WinActivate は
            ; ウィンドウを復元してしまい、点滅の原因になる）
            SetTimer(() => this._ForceMinimize(hwnd, seq), this._DELAY_MINIMIZE_RECHECK)
            return
        }
        ; 最小化完了後に直前ウィンドウへフォーカス復元
        SetTimer(() => this._RestorePrevFocus(seq), this._DELAY_FOCUS_RESTORE)
    }

    static _ForceMinimize(hwnd, seq) {
        if (seq != this._jumpSeq || !WinExist("ahk_id " . hwnd))
            return
        if (WinGetMinMax("ahk_id " . hwnd) != -1) {
            ; 再確認しても最小化されていない → Win+↓ で強制最小化
            WinActivate("ahk_id " . hwnd)
            SendInput("#{Down}")
        }
        SetTimer(() => this._RestorePrevFocus(seq), this._DELAY_FOCUS_RESTORE)
    }

    static _RestorePrevFocus(seq) {
        if (seq != this._jumpSeq)
            return
        if (this._prevHwnd && WinExist("ahk_id " . this._prevHwnd))
            WinActivate("ahk_id " . this._prevHwnd)
        else
            WinActivate("ahk_class Shell_TrayWnd")
    }

    ; ブラウザタブを除いた単独ウィンドウ（PWA等）のみを返す
    static _FindNonBrowserWindow(pat) {
        static browserSuffixes := [" - Google Chrome", " - Microsoft Edge", " - Mozilla Firefox"]
        for hwnd in WinGetList(pat) {
            title := WinGetTitle("ahk_id " . hwnd)
            for suffix in browserSuffixes {
                if InStr(title, suffix)
                    continue 2
            }
            return hwnd
        }
        return 0
    }

    ; =========================================================================
    ; 設定 GUI
    ; =========================================================================
    static _ShowSettings() {
        sg := Gui("+AlwaysOnTop", "QuickSwitch 設定")
        sg.SetFont("s10", "Segoe UI")
        sg.MarginX := 15
        sg.MarginY := 12

        ; --- ターゲット一覧 ---
        sg.Add("Text", "xm", "ジャンプ先の一覧:")
        lv := sg.Add("ListView", "xm y+6 w560 h180 -Multi", ["名前", "ウィンドウ検索パターン", "URL / パス", "ショートカット", "リストキー"])
        lv.ModifyCol(1, 100)
        lv.ModifyCol(2, 145)
        lv.ModifyCol(3, 193)
        lv.ModifyCol(4, 60)
        lv.ModifyCol(5, 60)

        try {
            loop parse, IniRead(this.IniPath, "Targets"), "`n", "`r" {
                if InStr(A_LoopField, "=") {
                    kv    := StrSplit(A_LoopField, "=", , 2)
                    parts := StrSplit(kv[2], "|", , 4)
                    lv.Add("", kv[1],
                        parts.Length >= 1 ? parts[1] : "",
                        parts.Length >= 2 ? parts[2] : "",
                        parts.Length >= 3 ? parts[3] : "",
                        parts.Length >= 4 ? parts[4] : "")
                }
            }
        }

        btnAdd      := sg.Add("Button", "xm y+8 w70", "追加")
        btnEdit     := sg.Add("Button", "x+5 w70", "編集")
        btnDel      := sg.Add("Button", "x+5 w70", "削除")
        btnUp       := sg.Add("Button", "x+5 w40", "↑")
        btnDown     := sg.Add("Button", "x+5 w40", "↓")
        btnKeyReset := sg.Add("Button", "x+10 w100", "キーを全リセット")

        ; --- プロファイル一覧 ---
        sg.Add("Text", "xm y+16", "プロファイル（ターゲットの表示セットを切り替え）:")
        lvP := sg.Add("ListView", "xm y+6 w560 h120 -Multi", ["プロファイル名", "含むターゲット"])
        lvP.ModifyCol(1, 140)
        lvP.ModifyCol(2, 414)

        try {
            loop parse, IniRead(this.IniPath, "Profiles"), "`n", "`r" {
                if InStr(A_LoopField, "=") {
                    kv := StrSplit(A_LoopField, "=", , 2)
                    lvP.Add("", kv[1], kv[2])
                }
            }
        }

        btnPAdd  := sg.Add("Button", "xm y+8 w70", "追加")
        btnPEdit := sg.Add("Button", "x+5 w70", "編集")
        btnPDel  := sg.Add("Button", "x+5 w70", "削除")

        ; --- アクティブプロファイル ---
        sg.Add("Text", "xm y+16", "アクティブプロファイル:")
        profileNames := ["（全て表示）"]
        try {
            loop parse, IniRead(this.IniPath, "Profiles"), "`n", "`r" {
                if InStr(A_LoopField, "=")
                    profileNames.Push(StrSplit(A_LoopField, "=")[1])
            }
        }
        profileDDL := sg.Add("DropDownList", "xm y+4 w200", profileNames)
        profileDDL.Choose(1)
        curProfile := IniRead(this.IniPath, "Settings", "ActiveProfile", "")
        if (curProfile != "") {
            for i, n in profileNames {
                if (n == curProfile) {
                    profileDDL.Choose(i)
                    break
                }
            }
        }

        ; --- デフォルト（直接ジャンプ） ---
        sg.Add("Text", "xm y+12", "デフォルト（直接ジャンプ）:")
        names := ["（なし — 毎回メニューを表示）"]
        try {
            loop parse, IniRead(this.IniPath, "Targets"), "`n", "`r" {
                if InStr(A_LoopField, "=")
                    names.Push(StrSplit(A_LoopField, "=")[1])
            }
        }
        defaultDDL := sg.Add("DropDownList", "xm y+4 w200", names)
        curDefault  := IniRead(this.IniPath, "Settings", "Default", "")
        defaultDDL.Choose(1)
        if (curDefault != "") {
            for i, n in names {
                if (n == curDefault) {
                    defaultDDL.Choose(i)
                    break
                }
            }
        }

        btnOk     := sg.Add("Button", "xm y+16 w80 Default", "OK")
        btnCancel := sg.Add("Button", "x+10 w80", "キャンセル")

        btnAdd.OnEvent("Click",    (*) => this._EditDialog(lv, 0, sg.Hwnd))
        btnEdit.OnEvent("Click",     (*) => this._OnEditClick(lv, sg.Hwnd))
        btnDel.OnEvent("Click",     (*) => (row := lv.GetNext()) ? lv.Delete(row) : "")
        btnUp.OnEvent("Click",      (*) => this._MoveItem(lv, -1))
        btnDown.OnEvent("Click",    (*) => this._MoveItem(lv, 1))
        btnKeyReset.OnEvent("Click",  (*) => this._ResetAllKeys(lv))
        lv.OnEvent("DoubleClick",    (ctrl, row) => (row ? this._EditDialog(lv, row, sg.Hwnd) : ""))
        lvP.OnEvent("DoubleClick",   (ctrl, row) => (row ? this._EditProfileDialog(lvP, lv, row, sg.Hwnd) : ""))

        btnPAdd.OnEvent("Click",   (*) => this._EditProfileDialog(lvP, lv, 0, sg.Hwnd))
        btnPEdit.OnEvent("Click",  (*) => this._OnProfileEditClick(lvP, lv, sg.Hwnd))
        btnPDel.OnEvent("Click",   (*) => (row := lvP.GetNext()) ? lvP.Delete(row) : "")

        btnOk.OnEvent("Click",     (*) => this._SaveSettings(sg, lv, lvP, profileDDL, defaultDDL))
        btnCancel.OnEvent("Click", (*) => sg.Destroy())
        sg.OnEvent("Close",        (*) => sg.Destroy())

        sg.Show("AutoSize")
        this._SetupLvTooltip(sg, lv)
    }

    static _SetupLvTooltip(sg, lv) {
        key := lv.Hwnd
        this._lvTipState[key] := {prevRow: -1, prevCol: -1}
        fn := () => this._LvTooltipTick(lv, sg)
        sg.OnEvent("Close", (*) => (SetTimer(fn, 0), ToolTip(), this._lvTipState.Delete(key)))
        SetTimer(fn, 100)
    }

    static _LvTooltipTick(lv, sg) {
        try {
            if !WinExist("ahk_id " . sg.Hwnd) {
                SetTimer(, 0)
                return
            }
        } catch {
            SetTimer(, 0)
            return
        }
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        pt := Buffer(8)
        NumPut("Int", mx, pt, 0)
        NumPut("Int", my, pt, 4)
        DllCall("ScreenToClient", "Ptr", lv.Hwnd, "Ptr", pt)
        cx := NumGet(pt, 0, "Int")
        cy := NumGet(pt, 4, "Int")
        hti := Buffer(20, 0)
        NumPut("Int", cx, hti, 0)
        NumPut("Int", cy, hti, 4)
        SendMessage(this._LVM_SUBITEMHITTEST, 0, hti.Ptr, lv)
        row := NumGet(hti, 12, "Int") + 1
        col := NumGet(hti, 16, "Int") + 1
        state := this._lvTipState[lv.Hwnd]
        if (row == state.prevRow && col == state.prevCol)
            return
        state.prevRow := row
        state.prevCol := col
        if (row < 1 || col < 1) {
            ToolTip()
            return
        }
        text := lv.GetText(row, col)
        if (text != "")
            ToolTip(text)
        else
            ToolTip()
    }

    static _SaveSettings(sg, lv, lvP, profileDDL, defaultDDL) {
        newProfile := (profileDDL.Text == "（全て表示）") ? "" : profileDDL.Text
        chosen     := defaultDDL.Text
        newDefault := (chosen == "（なし — 毎回メニューを表示）") ? "" : chosen

        try IniDelete(this.IniPath, "Targets")
        loop lv.GetCount()
            IniWrite(lv.GetText(A_Index, 2) . "|" . lv.GetText(A_Index, 3) . "|" . lv.GetText(A_Index, 4) . "|" . lv.GetText(A_Index, 5),
                     this.IniPath, "Targets", lv.GetText(A_Index, 1))

        try IniDelete(this.IniPath, "Profiles")
        loop lvP.GetCount()
            IniWrite(lvP.GetText(A_Index, 2),
                     this.IniPath, "Profiles", lvP.GetText(A_Index, 1))

        IniWrite(newProfile, this.IniPath, "Settings", "ActiveProfile")
        IniWrite(newDefault, this.IniPath, "Settings", "Default")
        this.ActiveProfile := newProfile
        this.DefaultTarget := newDefault

        this._RegisterHotkeys()

        sg.Destroy()
        ToolTip("保存しました")
        SetTimer(() => ToolTip(), -2000)
    }

    static _OnEditClick(lv, ownerHwnd := 0) {
        if lv.GetNext()
            this._EditDialog(lv, lv.GetNext(), ownerHwnd)
        else {
            ToolTip("編集する項目を選択してください。")
            SetTimer(() => ToolTip(), -2000)
        }
    }

    static _OnProfileEditClick(lvP, lv, ownerHwnd := 0) {
        if lvP.GetNext()
            this._EditProfileDialog(lvP, lv, lvP.GetNext(), ownerHwnd)
        else {
            ToolTip("編集するプロファイルを選択してください。")
            SetTimer(() => ToolTip(), -2000)
        }
    }

    static _MoveItem(lv, dir) {
        row := lv.GetNext()
        if (!row)
            return
        newRow := row + dir
        if (newRow < 1 || newRow > lv.GetCount())
            return
        n1 := lv.GetText(row,    1) , p1 := lv.GetText(row,    2) , u1 := lv.GetText(row,    3) , k1 := lv.GetText(row,    4) , lk1 := lv.GetText(row,    5)
        n2 := lv.GetText(newRow, 1) , p2 := lv.GetText(newRow, 2) , u2 := lv.GetText(newRow, 3) , k2 := lv.GetText(newRow, 4) , lk2 := lv.GetText(newRow, 5)
        lv.Modify(row,    "", n2, p2, u2, k2, lk2)
        lv.Modify(newRow, "", n1, p1, u1, k1, lk1)
        lv.Modify(newRow, "Select Focus")
    }

    static _EditDialog(lv, row, ownerHwnd := 0) {
        isNew := (row == 0)
        dg    := Gui("+AlwaysOnTop" . (ownerHwnd ? " +Owner" . ownerHwnd : ""), isNew ? "ターゲット追加" : "ターゲット編集")
        dg.SetFont("s10", "Segoe UI")
        dg.MarginX := 15
        dg.MarginY := 10

        dg.Add("Text", , "名前（メニューに表示）:")
        nameEdit := dg.Add("Edit", "w440", isNew ? "" : lv.GetText(row, 1))

        dg.Add("Text", "y+8", "ウィンドウ検索パターン（タイトルバーの一部）:")
        patEdit  := dg.Add("Edit", "w370", isNew ? "" : lv.GetText(row, 2))
        btnPick  := dg.Add("Button", "x+8 yp-1 w62", "選択...")

        dg.Add("Text", "xm y+8", "URL / パス（ウィンドウが見つからない場合に起動）:")
        urlEdit  := dg.Add("Edit", "w440", isNew ? "" : lv.GetText(row, 3))

        dg.Add("Text", "xm y+8", "ショートカットキー（直接ジャンプ）:")
        keyEdit     := dg.Add("Edit", "w160", isNew ? "" : lv.GetText(row, 4))
        btnCapture  := dg.Add("Button", "x+8 yp-1 w90", "キー入力...")

        dg.Add("Text", "xm y+8", "リストキー（メニュー表示中のみ）:")
        listKeyEdit  := dg.Add("Edit", "w160", isNew ? "" : lv.GetText(row, 5))
        btnCapture2  := dg.Add("Button", "x+8 yp-1 w90", "キー入力...")

        btnOk     := dg.Add("Button", "y+12 w80 Default", "OK")
        btnCancel := dg.Add("Button", "x+10 w80", "キャンセル")

        ; pickActive: ピック操作中は dg を破棄せず Hide 状態を維持するためのフラグ
        pickActive := {v: false}
        btnOk.OnEvent("Click",       (*) => this._SaveEntry(dg, lv, row, isNew, nameEdit, patEdit, urlEdit, keyEdit, listKeyEdit))
        btnCancel.OnEvent("Click",   (*) => dg.Destroy())
        btnPick.OnEvent("Click",     (*) => (pickActive.v := true, this._PickWindow(dg, patEdit, pickActive)))
        btnCapture.OnEvent("Click",  (*) => this._CaptureKey(keyEdit, dg.Hwnd))
        btnCapture2.OnEvent("Click", (*) => this._CaptureKey(listKeyEdit, dg.Hwnd))
        dg.OnEvent("Close",          (*) => (pickActive.v ? "" : dg.Destroy()))
        dg.Show("AutoSize")
        nameEdit.Focus()
    }

    static _SaveEntry(dg, lv, row, isNew, nameEdit, patEdit, urlEdit, keyEdit, listKeyEdit) {
        name    := Trim(nameEdit.Value)
        pat     := Trim(patEdit.Value)
        url     := Trim(urlEdit.Value)
        key     := Trim(keyEdit.Value)
        listKey := Trim(listKeyEdit.Value)
        if (name == "" || (pat == "" && url == "")) {
            ToolTip("名前と、パターンまたは URL を入力してください。")
            SetTimer(() => ToolTip(), -3000)
            return
        }
        try {
            ; 同じショートカットキーが他の行に既に設定されていないか確認
            if (key != "") {
                loop lv.GetCount() {
                    if (A_Index == row)
                        continue
                    if (lv.GetText(A_Index, 4) == key) {
                        ToolTip("ショートカット「" . key . "」は「" . lv.GetText(A_Index, 1) . "」に既に割り当て済みです。")
                        SetTimer(() => ToolTip(), -3000)
                        return
                    }
                }
            }
            if isNew
                lv.Add("", name, pat, url, key, listKey)
            else
                lv.Modify(row, "", name, pat, url, key, listKey)
        } catch {
            ; 設定画面が閉じられた場合は何もしない
        }
        dg.Destroy()
    }

    ; キー/マウスボタンをキャプチャしてショートカットキーフィールドに入力
    static _CaptureKey(keyEdit, ownerHwnd := 0) {
        static modKeys := ["LControl","RControl","LShift","RShift","LAlt","RAlt","LWin","RWin"]

        capGui := Gui("+AlwaysOnTop -SysMenu +ToolWindow" . (ownerHwnd ? " +Owner" . ownerHwnd : ""), "キー割り当て")
        capGui.SetFont("s10", "Segoe UI")
        capGui.MarginX := 15
        capGui.MarginY := 12
        capGui.Add("Text",, "割り当てるキーを押してください")
        capGui.Add("Text", "y+6 c808080", "Esc でキャンセル  /  マウスボタンも可")
        capGui.Show("AutoSize Center")
        capHwnd := capGui.Hwnd
        WinActivate("ahk_id " . capHwnd)

        ; マウス系は全て一時ホットキーで拾う（グローバルHKを抑制 & 修飾キー検出）
        this._pendingCapture := ""
        static mouseKeys := ["WheelUp","WheelDown","WheelLeft","WheelRight"
                            ,"LButton","RButton","MButton","XButton1","XButton2"]
        capHotifFn := (_) => WinActive("ahk_id " . capHwnd)
        HotIf(capHotifFn)
        for mk in mouseKeys
            Hotkey(mk, this._MakeWheelCapture(mk))
        HotIf()

        ; InputHook でキーボードをキャプチャ（修飾キー単体では終了しない）
        ih := InputHook("L0 T60 I")   ; I = AHKホットキーを無視
        ih.KeyOpt("{All}", "SE")
        for m in modKeys
            ih.KeyOpt("{" . m . "}", "-E")
        ih.Start()

        captured := ""
        Loop {
            if !WinExist("ahk_id " . capHwnd) {
                ih.Stop()
                break
            }
            ; ホイール／LButton（一時ホットキー経由）
            if (this._pendingCapture != "") {
                ih.Stop()
                captured := this._pendingCapture
                this._pendingCapture := ""
                break
            }

            if !ih.InProgress {
                key := ih.EndKey
                if (key == "Escape") {
                    captured := ""
                } else {
                    ; モディファイヤキー単体は無視
                    ismod := false
                    for m in modKeys {
                        if (key == m) {
                            ismod := true
                            break
                        }
                    }
                    if !ismod {
                        ; キー離す前に物理的な修飾キー状態を取得
                        prefix := ""
                        if GetKeyState("Control", "P")
                            prefix .= "^"
                        if GetKeyState("Shift", "P")
                            prefix .= "+"
                        if GetKeyState("Alt", "P")
                            prefix .= "!"
                        if GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
                            prefix .= "#"
                        captured := prefix . key
                    }
                }
                break
            }
            Sleep(10)
        }

        ; 一時ホットキーを解除
        HotIf(capHotifFn)
        for mk in mouseKeys
            try Hotkey(mk, "Off")
        HotIf()

        if WinExist("ahk_id " . capHwnd)
            capGui.Destroy()
        if (captured != "")
            keyEdit.Value := captured
    }

    static _MakeWheelCapture(key) {
        return (*) => this._SetWheelCapture(key)
    }

    static _SetWheelCapture(key) {
        prefix := ""
        if GetKeyState("Control", "P")
            prefix .= "^"
        if GetKeyState("Shift", "P")
            prefix .= "+"
        if GetKeyState("Alt", "P")
            prefix .= "!"
        this._pendingCapture := prefix . key
    }

    ; ウィンドウをクリックして検索パターンを自動入力
    static _PickWindow(dg, patEdit, pickActive) {
        dg.Hide()

        inst := Gui("+AlwaysOnTop -SysMenu +ToolWindow", "ウィンドウを選択")
        inst.SetFont("s10", "Segoe UI")
        inst.MarginX := 15
        inst.MarginY := 12
        inst.Add("Text",, "対象ウィンドウをクリックしてください。")
        inst.Add("Text", "y+4 c808080", "Esc でキャンセル")
        btnCancel := inst.Add("Button", "xm y+10 w80", "キャンセル")
        btnCancel.OnEvent("Click", (*) => inst.Destroy())
        inst.Show("x" . (A_ScreenWidth // 2 - 150) . " y20 AutoSize")
        instHwnd := inst.Hwnd

        KeyWait("LButton")   ; 選択ボタンのクリックが離れるまで待つ

        winHwnd := 0
        Loop {
            if !WinExist("ahk_id " . instHwnd)   ; キャンセルボタンで閉じた
                break
            if GetKeyState("Escape", "P") {
                KeyWait("Escape")
                inst.Destroy()
                break
            }
            if GetKeyState("LButton", "P") {
                MouseGetPos(,, &clickHwnd)
                if (clickHwnd != instHwnd) {
                    KeyWait("LButton")
                    winHwnd := clickHwnd
                    inst.Destroy()
                    break
                }
            }
            Sleep(10)
        }

        if !winHwnd {
            pickActive.v := false
            dg.Show()
            return
        }
        try {
            title := WinGetTitle("ahk_id " . winHwnd)
            exe   := WinGetProcessName("ahk_id " . winHwnd)
            cls   := WinGetClass("ahk_id " . winHwnd)
        } catch {
            pickActive.v := false
            dg.Show()
            return
        }
        this._ShowPickerDialog(dg, patEdit, title, exe, cls, pickActive)
    }

    static _ShowPickerDialog(dg, patEdit, title, exe, cls, pickActive) {
        pk := Gui("+AlwaysOnTop", "パターンを選択")
        pk.SetFont("s10", "Segoe UI")
        pk.MarginX := 15
        pk.MarginY := 12

        pk.Add("Text",, "使用するパターンを選択してください:")
        ; ラジオをまとめて追加することでグループを正しく形成する
        r1 := pk.Add("Radio", "xm y+10 Checked", "タイトル（部分一致）")
        r2 := pk.Add("Radio", "xm y+6", "プロセス名:        ahk_exe " . exe)
        pk.Add("Radio", "xm y+6", "ウィンドウクラス:  ahk_class " . cls)
        ; タイトルはr1選択時のみ使用（他の選択時は無視）
        pk.Add("Text", "xm y+10", "タイトル（編集可）:")
        t1 := pk.Add("Edit", "xm y+4 w380", title)

        btnOk     := pk.Add("Button", "xm y+14 w80 Default", "OK")
        btnCancel := pk.Add("Button", "x+10 w80", "キャンセル")

        btnOk.OnEvent("Click",     (*) => this._OnPickOk(pk, dg, patEdit, r1, r2, t1, exe, cls, pickActive))
        btnCancel.OnEvent("Click", (*) => (pk.Destroy(), pickActive.v := false, dg.Show()))
        pk.OnEvent("Close",        (*) => (pk.Destroy(), pickActive.v := false, dg.Show()))
        pk.Show("AutoSize")
    }

    static _OnPickOk(pk, dg, patEdit, r1, r2, t1, exe, cls, pickActive) {
        val := r1.Value ? t1.Value : r2.Value ? "ahk_exe " . exe : "ahk_class " . cls
        pk.Destroy()
        pickActive.v := false
        if WinExist(dg) {
            patEdit.Value := val
            dg.Show()
        }
    }

    static _ResetAllKeys(lv) {
        loop lv.GetCount()
            lv.Modify(A_Index, "", lv.GetText(A_Index, 1), lv.GetText(A_Index, 2), lv.GetText(A_Index, 3), "", "")
        ToolTip("キーをすべてリセットしました")
        SetTimer(() => ToolTip(), -2000)
    }

    ; プロファイル編集ダイアログ：現在のターゲット一覧からチェックボックスで選択
    static _EditProfileDialog(lvP, lv, row, ownerHwnd := 0) {
        isNew := (row == 0)
        dg    := Gui("+AlwaysOnTop" . (ownerHwnd ? " +Owner" . ownerHwnd : ""), isNew ? "プロファイル追加" : "プロファイル編集")
        dg.SetFont("s10", "Segoe UI")
        dg.MarginX := 15
        dg.MarginY := 10

        dg.Add("Text", , "プロファイル名:")
        nameEdit := dg.Add("Edit", "w300", isNew ? "" : lvP.GetText(row, 1))

        dg.Add("Text", "y+10", "含むターゲット:")

        allTargets := []
        loop lv.GetCount()
            allTargets.Push(lv.GetText(A_Index, 1))

        currentSet := Map()
        if (!isNew) {
            for t in StrSplit(lvP.GetText(row, 2), ",")
                currentSet[Trim(t)] := true
        }

        checkboxes := []
        for i, tName in allTargets {
            opt := (i == 1) ? "xm y+4" : "xm y+2"
            cb  := dg.Add("Checkbox", opt . (currentSet.Has(tName) ? " Checked" : ""), tName)
            checkboxes.Push(cb)
        }

        if (allTargets.Length == 0)
            dg.Add("Text", "xm y+4 cRed", "※ ターゲットが未登録です。先にターゲットを追加してください。")

        btnOk     := dg.Add("Button", "xm y+14 w80 Default", "OK")
        btnCancel := dg.Add("Button", "x+10 w80", "キャンセル")

        btnOk.OnEvent("Click",     (*) => this._SaveProfileEntry(dg, lvP, row, isNew, nameEdit, checkboxes, allTargets))
        btnCancel.OnEvent("Click", (*) => dg.Destroy())
        dg.OnEvent("Close",        (*) => dg.Destroy())
        dg.Show("AutoSize")
        nameEdit.Focus()
    }

    static _SaveProfileEntry(dg, lvP, row, isNew, nameEdit, checkboxes, allTargets) {
        name := Trim(nameEdit.Value)
        if (name == "") {
            ToolTip("プロファイル名を入力してください。")
            SetTimer(() => ToolTip(), -2000)
            return
        }
        selected := []
        for i, cb in checkboxes {
            if cb.Value
                selected.Push(allTargets[i])
        }
        if (selected.Length == 0) {
            ToolTip("少なくとも1つのターゲットを選択してください。")
            SetTimer(() => ToolTip(), -2000)
            return
        }
        joined := ""
        for i, t in selected
            joined .= (i == 1 ? "" : ",") . t

        if isNew
            lvP.Add("", name, joined)
        else
            lvP.Modify(row, "", name, joined)
        dg.Destroy()
    }
}
