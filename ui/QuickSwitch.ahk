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
;   a::  QuickSwitch.Show()           ; デフォルトに直接ジャンプ（未設定時はメニュー）
;   +a:: QuickSwitch.ShowMenu()       ; 常にメニュー表示
;   q::  QuickSwitch.ShowTempMenu()   ; 一時マークメニュー（1〜9 でジャンプ）
;   +q:: QuickSwitch.ToggleTempMark() ; アクティブウィンドウを一時マーク登録/解除
;   #HotIf
;
; ==============================================================================
#Requires AutoHotkey v2.0

class QuickSwitch {
    static IniPath        := A_ScriptDir "\ui\QuickSwitch.ini"
    static IniVersion     := 2
    static DefaultTarget  := ""
    static ActiveProfile  := ""
    ; ターゲットのインメモリキャッシュ [{name,pat,url,key,listkey}, ...]（表示順）。
    ; ジャンプ/メニューのホットパスでの INI 読み込みを無くすため保持し、
    ; Init と保存時に _LoadTargets で再構築する
    static _targets         := []
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

    ; 設定画面状態（二重起動すると後から閉じた方の内容で上書きされるため1枚のみ）
    static _settingsGui     := 0
    static _settingsHwnd    := 0
    static _settingsHotifFn := ""
    static _settingsTipFn   := ""
    static _helpHwnd        := 0
    ; 破棄確認用: 設定画面を開いた時点の内容スナップショットとコントロール参照
    static _settingsState   := 0

    ; Win32 ListView メッセージ
    static _LVM_APPROXIMATEVIEWRECT := 0x1040
    static _LVM_SUBITEMHITTEST      := 0x1039

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

    ; 一時マーク（セッション限り。INI には保存せず、リロードで消える）
    static _tempMarks := []
    static TEMP_MAX   := 9

    ; メニュー選択後の遅延ジャンプ（_DELAY_MENU_JUMP 待ち中）のタイマー。
    ; 発火前にメニューを開き直した場合はキャンセルする
    static _pendingJumpFn := ""

    ; メニューセッションのトグル基準ウィンドウ。開き直し（二度押し・マーク解除後の
    ; 再表示）では破棄直後の WinActive が不定なため、最初に開いた時の値を維持する
    static _menuRefActive := 0

    ; ToolTip 消去タイマーの単一参照。呼び出しごとに同じ関数で再アームすることで
    ; 古いタイマーが新しい通知を消してしまう多重発火を防ぐ
    static _tipTimerFn := ""

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
        this._settingsHotifFn := (_) => this._settingsHwnd && WinActive("ahk_id " . this._settingsHwnd)
        this._LoadTargets()
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
        ; トグル基準は「メニューを開く前にアクティブだったウィンドウ」。既にメニューが
        ; 開いている場合（開き直し）は破棄直後の WinActive が不定なため元の基準を保つ
        if ((a := WinActive("A")) && a != this._menuHwnd)
            this._menuRefActive := a
        this._CloseMenu()
        this._CancelPendingJump()

        prevActive := this._menuRefActive
        targets := this._GetActiveTargets()

        rows := []
        for name in targets {
            key  := this._GetTargetKey(name)
            mark := (name == this.DefaultTarget) ? "★ " : "  "
            rows.Push([(key != "" ? "[" . key . "]" : ""), mark . name])
        }
        ui := this._CreateMenuListGui(rows)
        pg := ui.pg
        lv := ui.lv

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

        this._StartMenuWatch(pg.Hwnd)

        pg.OnEvent("Close", (*) => this._CloseMenu())
        lv.OnEvent("Click", (ctrl, row) => this._OnMenuActivate(row, targets, prevActive))
    }

    ; フォーカス喪失でメニューを閉じる監視（100ms ポーリング）。
    ; 表示直後は前のメニュー破棄に伴う OS のフォーカス返却と競合して一瞬非アクティブ
    ; になることがある。そこで「一度もアクティブになれていない表示直後」だけ再アクティブ
    ; 化で立て直し、一度フォーカスを得た後の喪失は「ユーザーが他へ移った」とみなして閉じる。
    ; これによりメニュー使用後に他ウィンドウを意図的にクリックしたケースでフォーカスを
    ; 奪い返さずに済む
    static _StartMenuWatch(winHwnd) {
        born := A_TickCount
        st   := {everActive: false}
        this._menuTimerFn := () => this._MenuWatchTick(winHwnd, born, st)
        SetTimer(this._menuTimerFn, 100)
    }

    static _MenuWatchTick(winHwnd, born, st) {
        if !WinExist("ahk_id " . winHwnd)
            return
        if WinActive("ahk_id " . winHwnd) {
            st.everActive := true
            return
        }
        ; まだ一度もアクティブになれていない表示直後 → フォーカス返却との競合。
        ; 立て直しを試みる（成功すれば次ティックで everActive=true になる）
        if (!st.everActive && A_TickCount - born < 500) {
            try WinActivate("ahk_id " . winHwnd)
            return
        }
        this._CloseMenu()
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
        this._ScheduleJump(() => this._Jump(name, refActive))
    }

    ; メニューを閉じ、フォーカス返却との競合を避けて遅延ジャンプを予約する。
    ; メニュー系ジャンプの共通経路（保留キャンセル機構もここに一本化）
    static _ScheduleJump(jumpFn) {
        this._CloseMenu()
        ; メニュー破棄直後は OS が直前ウィンドウへフォーカスを返す処理と競合して
        ; ブリンクするため、返却が済んでからジャンプする
        fn := () => (this._pendingJumpFn := "", jumpFn())
        this._pendingJumpFn := fn
        SetTimer(fn, this._DELAY_MENU_JUMP)
    }

    ; 保留中の遅延ジャンプを取り消す（メニュー開き直し時・新規ジャンプ時）
    static _CancelPendingJump() {
        if this._pendingJumpFn {
            try SetTimer(this._pendingJumpFn, 0)
            this._pendingJumpFn := ""
        }
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

    ; ポップアップメニュー共通部：rows（[キー表示, 名前] の配列）から GUI を生成
    static _CreateMenuListGui(rows, width := 220) {
        pg := Gui("+AlwaysOnTop -Caption +Border +ToolWindow", "QuickSwitch")
        pg.SetFont("s10", "Segoe UI")
        pg.MarginX := 0
        pg.MarginY := 0

        lv := pg.Add("ListView", "xm ym w" . width . " h20 -Hdr -Multi NoSort AltSubmit", ["キー", "名前"])
        lv.ModifyCol(1, 40)
        lv.ModifyCol(2, width - 44)

        for r in rows
            lv.Add("", r[1], r[2])
        if (rows.Length == 0)
            lv.Add("", "", "（ターゲット未設定）")

        ; 先頭アイテムを選択
        if (lv.GetCount() > 0)
            lv.Modify(1, "Select Focus")

        ; マウス位置に一旦表示して行高さを取得
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        pg.Show("x" . mx . " y" . my . " AutoSize")

        ; 全行の表示に必要な高さを ListView 自身に問い合わせてリサイズ
        ; （行高さの手計算は実際の描画高さと数px ずれてスクロールバーが出る）
        res := SendMessage(this._LVM_APPROXIMATEVIEWRECT, -1, -1, lv)
        lvH := (res >> 16) & 0xFFFF
        if (lvH <= 0 || lvH >= 0xFFFF)
            lvH := Round(A_ScreenDPI / 96 * 25) * lv.GetCount() + 4  ; フォールバック
        lv.Move(0, 0, width, lvH)
        ; ボーダー差分を実測して補正
        WinGetPos(,, &wW, &wH, "ahk_id " . pg.Hwnd)
        WinGetClientPos(,, &cW, &cH, "ahk_id " . pg.Hwnd)
        WinMove(mx, my, width + (wW - cW), lvH + (wH - cH), "ahk_id " . pg.Hwnd)
        return {pg: pg, lv: lv}
    }

    ; =========================================================================
    ; 一時マークメニュー（無変換+Q）
    ; 1〜9: ジャンプ / Shift+数字・Delete・右クリック: 解除 / Ctrl+Delete: 全解除
    ; =========================================================================
    static ShowTempMenu(keepRef := false) {
        ; keepRef: マーク解除後の再表示など、基準ウィンドウを維持したい場合 true
        if (!keepRef && (a := WinActive("A")) && a != this._menuHwnd)
            this._menuRefActive := a
        this._CloseMenu()
        this._CancelPendingJump()
        this._PruneTempMarks()
        if (this._tempMarks.Length == 0) {
            this._TempTip("一時マークはありません（無変換+Shift+Q で登録）")
            return
        }

        prevActive := this._menuRefActive
        marks := this._tempMarks.Clone()

        rows := []
        for i, m in marks
            rows.Push(["[" . i . "]", this._TempMarkLabel(m)])
        ui := this._CreateMenuListGui(rows, 340)
        pg := ui.pg
        lv := ui.lv

        this._menuGui  := pg
        this._menuHwnd := pg.Hwnd

        HotIf(this._menuHotifFn)
        Hotkey("Escape",  (*) => this._CloseMenu(), "On")
        Hotkey("Enter",   (*) => this._OnTempMenuEnter(lv, marks, prevActive), "On")
        Hotkey("Delete",  (*) => this._OnTempMenuDeleteSel(lv, marks), "On")
        Hotkey("^Delete", (*) => this._ClearTempMarks(), "On")
        for i, m in marks {
            Hotkey(String(i),  this._MakeTempJumpCallback(m.hwnd, prevActive), "On")
            Hotkey("+" . i,    this._MakeTempRemoveCallback(m.hwnd), "On")
            this._menuKeys.Push(String(i), "+" . i)
        }
        ; 無変換を押し続けたまま未使用の数字を押しても Main.ahk の Vim 層
        ; （*0 の {Home} 等）へ漏れないよう、残りの 0〜9 を無反応で吸収する
        noop := (*) => 0
        loop 10 {
            d := A_Index - 1
            if (d >= 1 && d <= marks.Length)
                continue
            Hotkey(String(d), noop, "On")
            Hotkey("+" . d,   noop, "On")
            this._menuKeys.Push(String(d), "+" . d)
        }
        this._menuKeys.Push("Delete", "^Delete")
        HotIf()

        this._StartMenuWatch(pg.Hwnd)

        pg.OnEvent("Close", (*) => this._CloseMenu())
        lv.OnEvent("Click", (ctrl, row) => this._OnTempMenuActivate(row, marks, prevActive))
        pg.OnEvent("ContextMenu", (o, ctrl, item, rc, x, y) => (ctrl == lv && item) ? this._ShowTempContextMenu(marks, item) : "")
    }

    ; 一時メニューの行を右クリック → 解除メニュー
    static _ShowTempContextMenu(marks, row) {
        if (row < 1 || row > marks.Length)
            return
        m := Menu()
        m.Add("「" . this._TempMarkLabel(marks[row]) . "」を解除", (*) => this._RemoveTempMark(marks[row].hwnd))
        m.Add()
        m.Add("全て解除", (*) => this._ClearTempMarks())
        m.Show()
    }

    static _MakeTempJumpCallback(hwnd, refActive) {
        return (*) => this._ExecTempJump(hwnd, refActive)
    }

    static _ExecTempJump(hwnd, refActive) {
        this._ScheduleJump(() => this._JumpTempMark(hwnd, refActive))
    }

    static _MakeTempRemoveCallback(hwnd) {
        return (*) => this._RemoveTempMark(hwnd)
    }

    ; 指定マークを解除し、残りがあれば番号を振り直してメニューを開き直す
    static _RemoveTempMark(hwnd) {
        for i, m in this._tempMarks {
            if (m.hwnd == hwnd) {
                this._tempMarks.RemoveAt(i)
                break
            }
        }
        this._CloseMenu()
        ; 基準ウィンドウを維持したまま番号を振り直して開き直す
        if (this._tempMarks.Length > 0)
            SetTimer(() => this.ShowTempMenu(true), -1)
    }

    static _OnTempMenuEnter(lv, marks, refActive) {
        row := lv.GetNext()
        if (row >= 1 && row <= marks.Length)
            this._ExecTempJump(marks[row].hwnd, refActive)
    }

    static _OnTempMenuActivate(row, marks, refActive) {
        if (row >= 1 && row <= marks.Length)
            this._ExecTempJump(marks[row].hwnd, refActive)
    }

    static _OnTempMenuDeleteSel(lv, marks) {
        row := lv.GetNext()
        if (row >= 1 && row <= marks.Length)
            this._RemoveTempMark(marks[row].hwnd)
    }

    static _ClearTempMarks() {
        this._tempMarks := []
        this._CloseMenu()
        this._TempTip("一時マークを全て解除しました")
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
        for t in this._targets {
            key := t.key
            if (key != "") {
                isGlobal := RegExMatch(key, "^[!^+#]") || RegExMatch(key, "i)^(Wheel|LButton|RButton|MButton|XButton)")
                if isGlobal
                    HotIf()
                else
                    HotIf(this._hotifFn)
                try {
                    Hotkey(key, this._MakeJumpCallback(t.name), "On")
                    this._registeredKeys.Push({key: key, global: isGlobal})
                }
            }
        }
        HotIf()
    }

    ; INI の [Targets] をインメモリキャッシュへ読み込む（Init / 保存後に呼ぶ）
    static _LoadTargets() {
        this._targets := []
        try section := IniRead(this.IniPath, "Targets")
        catch
            return
        loop parse, section, "`n", "`r" {
            if InStr(A_LoopField, "=") {
                kv    := StrSplit(A_LoopField, "=", , 2)
                parts := StrSplit(kv[2], "|", , 4)
                this._targets.Push({
                    name:    kv[1],
                    pat:     parts.Length >= 1 ? Trim(parts[1]) : "",
                    url:     parts.Length >= 2 ? Trim(parts[2]) : "",
                    key:     parts.Length >= 3 ? Trim(parts[3]) : "",
                    listkey: parts.Length >= 4 ? Trim(parts[4]) : ""
                })
            }
        }
    }

    ; 名前でターゲットを検索（INI キー同様に大小無視）。見つからなければ 0
    static _FindTarget(name) {
        for t in this._targets
            if (t.name = name)
                return t
        return 0
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
        for t in this._targets
            allNames.Push(t.name)

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

    ; メニュー表示中に効く「リストキー」を返す（グローバルショートカットの key ではない）
    static _GetTargetKey(name) {
        t := this._FindTarget(name)
        return t ? t.listkey : ""
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

        ; メニュー選択の遅延ジャンプが保留中でも、この直接ジャンプが最新の意図なので
        ; 取り消す（保留ジャンプが後から発火してフォーカスを奪うのを防ぐ）
        this._CancelPendingJump()
        ; 新しいジャンプ開始 → 古いジャンプ由来のタイマーを世代番号で無効化
        seq := ++this._jumpSeq

        this._busy := true
        try {
            t         := this._FindTarget(name)
            windowPat := t ? t.pat : ""
            url       := t ? t.url : ""

            if (refActive == 0)
                refActive := WinActive("A")

            if (windowPat != "") {
                hwnd := this._FindNonBrowserWindow(windowPat)
                if !hwnd
                    hwnd := WinExist(windowPat)
                if hwnd {
                    this._ActivateOrToggle(hwnd, refActive, seq)
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

    ; アクティブなら最小化トグル、そうでなければアクティブ化（_Jump / 一時マーク共通）
    static _ActivateOrToggle(hwnd, refActive, seq) {
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
                ; フォアグラウンドロックで無視されることがあるため一度だけ再試行するが、
                ; ホットキースレッドをブロックしない（_busy 保持中の待機は他キーを取りこぼす）。
                ; 新しいジャンプやメニュー表示中は奪わない
                SetTimer(() => (seq == this._jumpSeq && !this._menuHwnd && !WinActive("ahk_id " . hwnd))
                    ? WinActivate("ahk_id " . hwnd) : 0, -120)
            }
        }
    }

    ; =========================================================================
    ; 一時マーク（無変換+Shift+Q）: アクティブウィンドウを HWND でセッション限り登録
    ; =========================================================================
    static ToggleTempMark() {
        hwnd := WinActive("A")
        if !hwnd
            return
        ; QuickSwitch 自身のウィンドウ（メニュー/設定/ヘルプ）は登録しない。
        ; 閉じると即ダングリングHWNDになり枠を無駄に消費するため
        if (hwnd == this._menuHwnd || hwnd == this._settingsHwnd || hwnd == this._helpHwnd) {
            this._TempTip("QuickSwitch 自身のウィンドウは登録できません")
            return
        }
        ; 既に登録済みなら解除（トグル）
        for i, m in this._tempMarks {
            if (m.hwnd == hwnd) {
                this._tempMarks.RemoveAt(i)
                this._TempTip("一時マーク解除: " . m.title)
                return
            }
        }
        this._PruneTempMarks()
        if (this._tempMarks.Length >= this.TEMP_MAX) {
            this._TempTip("一時マークは " . this.TEMP_MAX . " 個までです")
            return
        }
        title := WinGetTitle("ahk_id " . hwnd)
        ; アプリ名（プロセス名から .exe を除いて先頭を大文字化）を表示用に取得
        app := ""
        try {
            app := RegExReplace(WinGetProcessName("ahk_id " . hwnd), "i)\.exe$")
            app := StrUpper(SubStr(app, 1, 1)) . SubStr(app, 2)
        }
        if (title == "")
            title := app
        this._tempMarks.Push({hwnd: hwnd, title: title, app: app})
        this._TempTip("一時マーク登録 [" . this._tempMarks.Length . "]: " . this._TempMarkLabel(this._tempMarks[-1]))
    }

    ; 閉じられたウィンドウのマークを取り除く
    static _PruneTempMarks() {
        i := this._tempMarks.Length
        while i >= 1 {
            if !WinExist("ahk_id " . this._tempMarks[i].hwnd)
                this._tempMarks.RemoveAt(i)
            i--
        }
    }

    static _JumpTempMark(hwnd, refActive := 0) {
        if this._busy
            return
        ; キーリピート/連打対策（デバウンス機構を疑似名で共用）
        now      := A_TickCount
        key      := "temp:" . hwnd
        isRepeat := (key == this._lastJumpName && now - this._lastJumpTick < this._DEBOUNCE_JUMP)
        this._lastJumpName := key
        this._lastJumpTick := now
        if isRepeat
            return

        this._CancelPendingJump()
        seq := ++this._jumpSeq
        this._busy := true
        try {
            if (refActive == 0)
                refActive := WinActive("A")
            if !WinExist("ahk_id " . hwnd) {
                this._PruneTempMarks()
                this._TempTip("ウィンドウが閉じられたためマークを解除しました")
                return
            }
            this._ActivateOrToggle(hwnd, refActive, seq)
        } finally {
            this._busy := false
        }
    }

    ; 一時マークの表示ラベル: 「アプリ名 — タイトル」
    ; （タイトルは末尾のアプリ名が切れて分かりにくいため、先頭にアプリ名を出す）
    static _TempMarkLabel(m) {
        if (m.app == "" || InStr(m.title, m.app) == 1)
            return m.title
        return m.app . " — " . m.title
    }

    ; 自動消去付きツールチップ。単一のタイマー参照で再アームするため、
    ; 連続表示しても古いタイマーが新しい通知を消してしまうことがない
    static _Tip(msg, dur := 2000) {
        ToolTip(msg)
        if !this._tipTimerFn
            this._tipTimerFn := (*) => ToolTip()
        SetTimer(this._tipTimerFn, -Abs(dur))
    }

    static _TempTip(msg) => this._Tip(msg, 1500)

    ; WinMinimizeが効かないアプリへのフォールバック（Electron等）。
    ; seq が古ければ新しいジャンプに置き換わっているので中止。最小化処理自体は
    ; 進めるが、フォーカスを触る操作（Win+↓ / 直前ウィンドウ復元）はメニュー表示中は避ける
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
        ; 最小化完了後に直前ウィンドウへフォーカス復元（メニュー表示中は触らない）
        if !this._menuHwnd
            SetTimer(() => this._RestorePrevFocus(seq), this._DELAY_FOCUS_RESTORE)
    }

    static _ForceMinimize(hwnd, seq) {
        if (seq != this._jumpSeq || !WinExist("ahk_id " . hwnd))
            return
        if (WinGetMinMax("ahk_id " . hwnd) != -1) {
            if this._menuHwnd {
                ; メニュー表示中はフォーカスを奪わない最小化のみ試みる
                ; （効かないアプリでは残るが、メニューを閉じてしまうよりまし）
                try WinMinimize("ahk_id " . hwnd)
            } else {
                ; 再確認しても最小化されていない → Win+↓ で強制最小化
                WinActivate("ahk_id " . hwnd)
                SendInput("#{Down}")
            }
        }
        if !this._menuHwnd
            SetTimer(() => this._RestorePrevFocus(seq), this._DELAY_FOCUS_RESTORE)
    }

    static _RestorePrevFocus(seq) {
        if (seq != this._jumpSeq || this._menuHwnd)
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
        ; 既に開いていれば手前に出すだけ
        if (this._settingsHwnd && WinExist("ahk_id " . this._settingsHwnd)) {
            WinActivate("ahk_id " . this._settingsHwnd)
            return
        }

        sg := Gui("+AlwaysOnTop +Resize", "QuickSwitch 設定")
        sg.SetFont("s10", "Segoe UI")
        sg.MarginX := 15
        sg.MarginY := 12

        ; リサイズ時に伸縮させる列の基準幅（構築とリサイズで同じ値を使う）
        urlColW := 230   ; ターゲット: URL / パス列
        incColW := 540   ; プロファイル: 含むターゲット列

        tab := sg.Add("Tab3", "xm ym w720 h330", ["ターゲット", "プロファイル"])

        ; --- タブ1: ターゲット一覧 ---
        tab.UseTab(1)
        lv := sg.Add("ListView", "xm+10 ym+34 w700 h240 -Multi", ["★", "名前", "ウィンドウ検索パターン", "URL / パス", "ショートカット", "リストキー"])
        lv.ModifyCol(1, 24)
        lv.ModifyCol(2, 110)
        lv.ModifyCol(3, 170)
        lv.ModifyCol(4, urlColW)
        lv.ModifyCol(5, 85)
        lv.ModifyCol(6, 70)

        curDefault := this.DefaultTarget
        for t in this._targets
            lv.Add("", (t.name = curDefault ? "★" : ""), t.name, t.pat, t.url, t.key, t.listkey)

        btnAdd      := sg.Add("Button", "xm+10 y+8 w70", "追加")
        btnEdit     := sg.Add("Button", "x+5 w70", "編集")
        btnDel      := sg.Add("Button", "x+5 w70", "削除")
        btnUp       := sg.Add("Button", "x+5 w40", "↑")
        btnDown     := sg.Add("Button", "x+5 w40", "↓")
        btnKeyReset := sg.Add("Button", "x+10 w150", "キーを全リセット")

        ; --- タブ2: プロファイル ---
        tab.UseTab(2)
        lvP := sg.Add("ListView", "xm+10 ym+34 w700 h240 -Multi", ["プロファイル名", "含むターゲット"])
        lvP.ModifyCol(1, 150)
        lvP.ModifyCol(2, incColW)

        try {
            loop parse, IniRead(this.IniPath, "Profiles"), "`n", "`r" {
                if InStr(A_LoopField, "=") {
                    kv := StrSplit(A_LoopField, "=", , 2)
                    lvP.Add("", kv[1], kv[2])
                }
            }
        }

        btnPAdd  := sg.Add("Button", "xm+10 y+8 w70", "追加")
        btnPEdit := sg.Add("Button", "x+5 w70", "編集")
        btnPDel  := sg.Add("Button", "x+5 w70", "削除")
        tab.UseTab()

        ; --- アクティブプロファイル / デフォルト（タブの下に横並び） ---
        t1 := sg.Add("Text", "xm ym+344 Section", "アクティブプロファイル:")
        profileDDL := sg.Add("DropDownList", "xs y+4 w220")
        t2 := sg.Add("Text", "ys x+40", "デフォルト（直接ジャンプ）:")
        defaultDDL := sg.Add("DropDownList", "xp y+4 w220")
        this._RefreshProfileDDL(lvP, profileDDL, this.ActiveProfile)
        this._RefreshDefaultDDL(lv, defaultDDL, curDefault)

        btnOk     := sg.Add("Button", "xm y+16 w80 Default", "OK")
        btnCancel := sg.Add("Button", "x+10 w80", "キャンセル")
        btnHelp   := sg.Add("Button", "x+10 w80", "ヘルプ")

        btnAdd.OnEvent("Click",      (*) => this._EditDialog(lv, 0, sg.Hwnd, defaultDDL))
        btnEdit.OnEvent("Click",     (*) => this._OnEditClick(lv, sg.Hwnd, defaultDDL))
        btnDel.OnEvent("Click",      (*) => this._DeleteTargetRow(lv, defaultDDL))
        btnUp.OnEvent("Click",       (*) => this._MoveItem(lv, -1))
        btnDown.OnEvent("Click",     (*) => this._MoveItem(lv, 1))
        btnKeyReset.OnEvent("Click", (*) => this._ResetAllKeys(lv))
        lv.OnEvent("DoubleClick",    (ctrl, row) => (row ? this._EditDialog(lv, row, sg.Hwnd, defaultDDL) : ""))
        lvP.OnEvent("DoubleClick",   (ctrl, row) => (row ? this._EditProfileDialog(lvP, lv, row, sg.Hwnd, profileDDL) : ""))
        defaultDDL.OnEvent("Change", (*) => this._UpdateDefaultMarks(lv, defaultDDL))
        sg.OnEvent("ContextMenu",    (o, ctrl, item, rc, x, y) => (ctrl == lv && item) ? this._ShowTargetContextMenu(lv, item, defaultDDL, sg.Hwnd) : "")

        btnPAdd.OnEvent("Click",  (*) => this._EditProfileDialog(lvP, lv, 0, sg.Hwnd, profileDDL))
        btnPEdit.OnEvent("Click", (*) => this._OnProfileEditClick(lvP, lv, sg.Hwnd, profileDDL))
        btnPDel.OnEvent("Click",  (*) => this._DeleteProfileRow(lvP, profileDDL))

        btnOk.OnEvent("Click",     (*) => this._SaveSettings(lv, lvP, profileDDL, defaultDDL))
        btnCancel.OnEvent("Click", (*) => this._RequestCloseSettings())
        btnHelp.OnEvent("Click",   (*) => this._ShowSettingsHelp(sg.Hwnd))
        sg.OnEvent("Close",        (*) => this._RequestCloseSettings())
        sg.OnEvent("Escape",       (*) => this._RequestCloseSettings())

        this._settingsGui  := sg
        this._settingsHwnd := sg.Hwnd
        this._settingsState := {lv: lv, lvP: lvP, profileDDL: profileDDL, defaultDDL: defaultDDL,
                                baseline: this._SettingsSnapshot(lv, lvP, profileDDL, defaultDDL)}

        ; 設定画面がアクティブな間だけ Ctrl+↑/↓ で行を移動できる
        ; （ターゲットタブ表示中のみ。非表示のタブを暗黙に並べ替えないようガード）
        HotIf(this._settingsHotifFn)
        Hotkey("^Up",   (*) => (tab.Value = 1 ? this._MoveItem(lv, -1) : 0), "On")
        Hotkey("^Down", (*) => (tab.Value = 1 ? this._MoveItem(lv, 1) : 0), "On")
        HotIf()

        sg.Show("AutoSize")
        this._SetupLvTooltip(sg, lv)

        ; --- リサイズ対応（初期クライアントサイズ基準の手動アンカー） ---
        WinGetClientPos(,, &cw, &ch, "ahk_id " . sg.Hwnd)
        si := {baseW: cw, baseH: ch, lv: lv, lvP: lvP, urlColW: urlColW, incColW: incColW, stretch: [], shift: []}
        for c in [tab, lv, lvP] {
            c.GetPos(&x, &y, &w, &h)
            si.stretch.Push({c: c, x: x, y: y, w: w, h: h})
        }
        for c in [btnAdd, btnEdit, btnDel, btnUp, btnDown, btnKeyReset, btnPAdd, btnPEdit, btnPDel,
                  t1, profileDDL, t2, defaultDDL, btnOk, btnCancel, btnHelp] {
            c.GetPos(&x, &y)
            si.shift.Push({c: c, x: x, y: y})
        }
        sg.Opt("+MinSize" . cw . "x" . ch)
        sg.OnEvent("Size", (g, mm, w, h) => this._OnSettingsResize(si, mm, w, h))
    }

    static _OnSettingsResize(si, minMax, w, h) {
        if (minMax == -1)
            return
        dw := w - si.baseW
        dh := h - si.baseH
        for r in si.stretch
            r.c.Move(r.x, r.y, r.w + dw, r.h + dh)
        for r in si.shift
            r.c.Move(r.x, r.y + dh)
        ; 余った幅は内容が長い列に配分
        si.lv.ModifyCol(4, si.urlColW + dw)
        si.lvP.ModifyCol(2, si.incColW + dw)
    }

    ; 設定内容を1本の文字列に直列化（破棄確認の差分検出用）
    static _SettingsSnapshot(lv, lvP, profileDDL, defaultDDL) {
        s := ""
        loop lv.GetCount() {
            r := A_Index
            loop 6
                s .= lv.GetText(r, A_Index) . Chr(1)
            s .= Chr(2)
        }
        s .= Chr(3)
        loop lvP.GetCount()
            s .= lvP.GetText(A_Index, 1) . Chr(1) . lvP.GetText(A_Index, 2) . Chr(2)
        s .= Chr(3) . profileDDL.Text . Chr(1) . defaultDDL.Text
        return s
    }

    ; キャンセル / ✕ / Esc からの閉じ要求。未保存の変更があれば確認する
    static _RequestCloseSettings() {
        st := this._settingsState
        if st {
            dirty := false
            try dirty := this._SettingsSnapshot(st.lv, st.lvP, st.profileDDL, st.defaultDDL) != st.baseline
            if dirty {
                if (MsgBox("保存していない変更があります。破棄して閉じますか？",
                           "QuickSwitch 設定", "YesNo Default2 Owner" . this._settingsHwnd) != "Yes")
                    return
            }
        }
        this._CloseSettings()
    }

    ; 設定画面の後始末（Destroy では Close イベントが発火しないため全経路から呼ぶ）
    static _CloseSettings() {
        if !this._settingsGui
            return
        this._settingsState := 0
        if this._settingsTipFn {
            SetTimer(this._settingsTipFn, 0)
            this._settingsTipFn := ""
            ToolTip()
        }
        HotIf(this._settingsHotifFn)
        try Hotkey("^Up", "Off")
        try Hotkey("^Down", "Off")
        HotIf()
        sg := this._settingsGui
        this._settingsGui  := 0
        this._settingsHwnd := 0
        this._lvTipState.Clear()
        try sg.Destroy()
    }

    ; =========================================================================
    ; 設定 GUI ヘルパー
    ; =========================================================================
    ; ListView の指定列を先頭プレースホルダー付きで DDL に反映し、selectName を再選択
    static _RefreshDDL(listCtrl, ddl, placeholder, col, selectName) {
        names := [placeholder]
        loop listCtrl.GetCount()
            names.Push(listCtrl.GetText(A_Index, col))
        ddl.Delete()
        ddl.Add(names)
        ddl.Choose(1)
        for i, n in names {
            if (i > 1 && n = selectName) {
                ddl.Choose(i)
                break
            }
        }
    }

    static _RefreshDefaultDDL(lv, ddl, selectName) => this._RefreshDDL(lv, ddl, "（なし — 毎回メニューを表示）", 2, selectName)

    static _RefreshProfileDDL(lvP, ddl, selectName) => this._RefreshDDL(lvP, ddl, "（全て表示）", 1, selectName)

    static _UpdateDefaultMarks(lv, defaultDDL) {
        chosen := defaultDDL.Text
        loop lv.GetCount()
            lv.Modify(A_Index, "Col1", (lv.GetText(A_Index, 2) = chosen) ? "★" : "")
    }

    static _DeleteTargetRow(lv, defaultDDL) {
        row := lv.GetNext()
        if !row
            return
        lv.Delete(row)
        this._RefreshDefaultDDL(lv, defaultDDL, defaultDDL.Text)
        this._UpdateDefaultMarks(lv, defaultDDL)
    }

    static _DeleteProfileRow(lvP, profileDDL) {
        row := lvP.GetNext()
        if !row
            return
        lvP.Delete(row)
        this._RefreshProfileDDL(lvP, profileDDL, profileDDL.Text)
    }

    static _ShowTargetContextMenu(lv, row, defaultDDL, ownerHwnd) {
        lv.Modify(row, "Select Focus")
        m := Menu()
        m.Add("編集...",          (*) => this._EditDialog(lv, row, ownerHwnd, defaultDDL))
        m.Add("複製",             (*) => this._DuplicateRow(lv, row, defaultDDL))
        m.Add("デフォルトに設定", (*) => this._SetDefaultRow(lv, row, defaultDDL))
        m.Add("テストジャンプ",   (*) => this._TestRow(lv, row))
        m.Add()
        m.Add("削除",             (*) => this._DeleteTargetRow(lv, defaultDDL))
        m.Show()
    }

    static _SetDefaultRow(lv, row, defaultDDL) {
        ; 既にデフォルトなら解除（トグル）
        newDefault := (lv.GetText(row, 1) == "★") ? "" : lv.GetText(row, 2)
        this._RefreshDefaultDDL(lv, defaultDDL, newDefault)
        this._UpdateDefaultMarks(lv, defaultDDL)
    }

    static _DuplicateRow(lv, row, defaultDDL) {
        base := lv.GetText(row, 2)
        name := base . " のコピー"
        n := 2
        while this._NameExists(lv, name) {
            name := base . " のコピー" . n
            n++
        }
        ; ショートカット/リストキーは重複禁止のためコピーしない
        lv.Add("", "", name, lv.GetText(row, 3), lv.GetText(row, 4), "", "")
        lv.Modify(lv.GetCount(), "Select Focus Vis")
        this._RefreshDefaultDDL(lv, defaultDDL, defaultDDL.Text)
    }

    static _NameExists(lv, name) {
        loop lv.GetCount() {
            if (lv.GetText(A_Index, 2) = name)
                return true
        }
        return false
    }

    ; 未保存の行内容でジャンプを試す（INI には触らない）
    static _TestRow(lv, row) {
        pat := lv.GetText(row, 3)
        url := lv.GetText(row, 4)
        try {
            if (pat != "" && WinExist(pat)) {
                hwnd := this._FindNonBrowserWindow(pat)
                if !hwnd
                    hwnd := WinExist(pat)
                if (WinGetMinMax("ahk_id " . hwnd) == -1)
                    WinRestore("ahk_id " . hwnd)
                WinActivate("ahk_id " . hwnd)
            } else if (url != "")
                Run(url)
            else if (pat != "")
                Run(pat)
        } catch as e {
            this._ValidationError("テスト失敗: " . e.Message)
        }
    }

    ; 使い方の説明ウィンドウ（設定画面の「ヘルプ」ボタンから）
    static _ShowSettingsHelp(ownerHwnd) {
        if (this._helpHwnd && WinExist("ahk_id " . this._helpHwnd)) {
            WinActivate("ahk_id " . this._helpHwnd)
            return
        }
        helpText := ""
            . "■ 基本`n"
            . "・ターゲット = ジャンプ先。ウィンドウが開いていればアクティブ化、なければ URL / パスを起動します`n"
            . "・対象が既にアクティブなら最小化して元のウィンドウに戻ります（トグル動作）`n"
            . "`n■ 2種類のキー`n"
            . "・ショートカットキー: 無変換+キーで、どこからでも直接ジャンプ`n"
            . "　（Ctrl などの修飾キー付き・マウス・ホイールは無変換なしのグローバル動作）`n"
            . "・リストキー: 無変換+Shift+A のメニューが出ている間だけ効く1打キー`n"
            . "`n■ 一覧の操作`n"
            . "・ダブルクリックで編集、右クリックでメニュー（複製 / デフォルトに設定 / テストジャンプ）`n"
            . "・Ctrl+↑/↓ か ↑↓ボタンで並べ替え（そのままメニューの表示順になります）`n"
            . "・★ = デフォルト。無変換+A でメニューを出さずに直接ジャンプする対象です`n"
            . "・セルに収まらない内容はマウスを乗せると全文表示されます`n"
            . "`n■ 入力の補助（編集ダイアログ）`n"
            . "・パターンの「選択...」: ウィンドウをクリックしてタイトル / プロセス名 / クラスから選択`n"
            . "・URL / パスの「選択...」: ウィンドウをクリックして実行ファイルのパスを入力`n"
            . "　（エクスプローラーなら開いているフォルダーも選べます）`n"
            . "`n■ プロファイル`n"
            . "・メニューに表示するターゲットの組を切り替える機能。使わなければ「全て表示」のままで OK`n"
            . "`n■ 一時マーク（この画面とは無関係のセッション限り機能）`n"
            . "・無変換+Shift+Q: アクティブウィンドウを一時マークに登録/解除（INI には保存されません）`n"
            . "・無変換+Q: 一時マークだけのメニュー。1〜9 でジャンプ、`n"
            . "　Shift+数字 / Delete / 右クリック で個別解除、Ctrl+Delete で全解除。リロードでも全て消えます`n"
            . "`n※ 変更は OK を押すまで保存されません（キャンセルで破棄）"

        hg := Gui("+AlwaysOnTop" . (ownerHwnd ? " +Owner" . ownerHwnd : ""), "QuickSwitch の使い方")
        hg.SetFont("s10", "Segoe UI")
        hg.MarginX := 15
        hg.MarginY := 12
        hg.Add("Text", "w560", helpText)
        btnClose := hg.Add("Button", "xm y+12 w80 Default", "閉じる")
        btnClose.OnEvent("Click", (*) => hg.Destroy())
        hg.OnEvent("Close",       (*) => hg.Destroy())
        hg.OnEvent("Escape",      (*) => hg.Destroy())
        hg.Show("AutoSize")
        this._helpHwnd := hg.Hwnd
    }

    static _SetupLvTooltip(sg, lv) {
        this._lvTipState[lv.Hwnd] := {prevRow: -1, prevCol: -1}
        this._settingsTipFn := () => this._LvTooltipTick(lv, sg)
        SetTimer(this._settingsTipFn, 100)
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
        if !this._lvTipState.Has(lv.Hwnd)
            return
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

    static _SaveSettings(lv, lvP, profileDDL, defaultDDL) {
        newProfile := (profileDDL.Text == "（全て表示）") ? "" : profileDDL.Text
        chosen     := defaultDDL.Text
        newDefault := (chosen == "（なし — 毎回メニューを表示）") ? "" : chosen

        try IniDelete(this.IniPath, "Targets")
        loop lv.GetCount()
            IniWrite(lv.GetText(A_Index, 3) . "|" . lv.GetText(A_Index, 4) . "|" . lv.GetText(A_Index, 5) . "|" . lv.GetText(A_Index, 6),
                     this.IniPath, "Targets", lv.GetText(A_Index, 2))

        try IniDelete(this.IniPath, "Profiles")
        loop lvP.GetCount()
            IniWrite(lvP.GetText(A_Index, 2),
                     this.IniPath, "Profiles", lvP.GetText(A_Index, 1))

        IniWrite(newProfile, this.IniPath, "Settings", "ActiveProfile")
        IniWrite(newDefault, this.IniPath, "Settings", "Default")
        this.ActiveProfile := newProfile
        this.DefaultTarget := newDefault

        this._LoadTargets()
        this._RegisterHotkeys()

        this._CloseSettings()
        this._Tip("保存しました")
    }

    static _OnEditClick(lv, ownerHwnd, defaultDDL) {
        if lv.GetNext()
            this._EditDialog(lv, lv.GetNext(), ownerHwnd, defaultDDL)
        else
            this._ValidationError("編集する項目を選択してください。")
    }

    static _OnProfileEditClick(lvP, lv, ownerHwnd, profileDDL) {
        if lvP.GetNext()
            this._EditProfileDialog(lvP, lv, lvP.GetNext(), ownerHwnd, profileDDL)
        else
            this._ValidationError("編集するプロファイルを選択してください。")
    }

    static _ValidationError(msg) => this._Tip(msg, 3000)

    ; 入力値の正規化: 改行を除去して前後の空白を落とす
    ; （改行は Trim では取れず、INI が行ベースのため保存すると設定が壊れる）
    static _CleanField(s) {
        return Trim(StrReplace(StrReplace(s, "`r", ""), "`n", ""), " `t")
    }

    static _MoveItem(lv, dir) {
        row := lv.GetNext()
        if (!row)
            return
        newRow := row + dir
        if (newRow < 1 || newRow > lv.GetCount())
            return
        cols1 := [], cols2 := []
        loop 6 {
            cols1.Push(lv.GetText(row, A_Index))
            cols2.Push(lv.GetText(newRow, A_Index))
        }
        lv.Modify(row,    "", cols2*)
        lv.Modify(newRow, "", cols1*)
        lv.Modify(newRow, "Select Focus")
    }

    static _EditDialog(lv, row, ownerHwnd, defaultDDL) {
        isNew := (row == 0)
        dg    := Gui("+AlwaysOnTop" . (ownerHwnd ? " +Owner" . ownerHwnd : ""), isNew ? "ターゲット追加" : "ターゲット編集")
        dg.SetFont("s10", "Segoe UI")
        dg.MarginX := 15
        dg.MarginY := 10

        ; r1: 値に改行が紛れていても複数行 Edit 化してレイアウトが崩れないようにする
        dg.Add("Text", , "名前（メニューに表示）:")
        nameEdit := dg.Add("Edit", "w440 r1", isNew ? "" : lv.GetText(row, 2))

        dg.Add("Text", "y+8", "ウィンドウ検索パターン（タイトルバーの一部）:")
        patEdit  := dg.Add("Edit", "w370 r1", isNew ? "" : lv.GetText(row, 3))
        btnPick  := dg.Add("Button", "x+8 yp-1 w62", "選択...")

        dg.Add("Text", "xm y+8", "URL / パス（ウィンドウが見つからない場合に起動）:")
        urlEdit    := dg.Add("Edit", "w370 r1", isNew ? "" : lv.GetText(row, 4))
        btnPickUrl := dg.Add("Button", "x+8 yp-1 w62", "選択...")

        dg.Add("Text", "xm y+8", "ショートカットキー（直接ジャンプ）:")
        keyEdit     := dg.Add("Edit", "w160 r1", isNew ? "" : lv.GetText(row, 5))
        btnCapture  := dg.Add("Button", "x+8 yp-1 w90", "キー入力...")

        dg.Add("Text", "xm y+8", "リストキー（メニュー表示中のみ）:")
        listKeyEdit  := dg.Add("Edit", "w160 r1", isNew ? "" : lv.GetText(row, 6))
        btnCapture2  := dg.Add("Button", "x+8 yp-1 w90", "キー入力...")

        btnOk     := dg.Add("Button", "y+12 w80 Default", "OK")
        btnCancel := dg.Add("Button", "x+10 w80", "キャンセル")

        ; pickActive: ピック操作中は dg を破棄せず Hide 状態を維持するためのフラグ
        pickActive := {v: false}
        btnOk.OnEvent("Click",       (*) => this._SaveEntry(dg, lv, row, isNew, nameEdit, patEdit, urlEdit, keyEdit, listKeyEdit, defaultDDL))
        btnCancel.OnEvent("Click",   (*) => dg.Destroy())
        btnPick.OnEvent("Click",     (*) => (pickActive.v := true, this._PickWindow(dg, patEdit, pickActive)))
        btnPickUrl.OnEvent("Click",  (*) => (pickActive.v := true, this._PickPath(dg, urlEdit, pickActive)))
        btnCapture.OnEvent("Click",  (*) => this._CaptureKey(keyEdit, dg.Hwnd))
        btnCapture2.OnEvent("Click", (*) => this._CaptureKey(listKeyEdit, dg.Hwnd))
        dg.OnEvent("Close",          (*) => (pickActive.v ? "" : dg.Destroy()))
        dg.OnEvent("Escape",         (*) => (pickActive.v ? "" : dg.Destroy()))
        dg.Show("AutoSize")
        nameEdit.Focus()
    }

    static _SaveEntry(dg, lv, row, isNew, nameEdit, patEdit, urlEdit, keyEdit, listKeyEdit, defaultDDL) {
        name    := this._CleanField(nameEdit.Value)
        pat     := this._CleanField(patEdit.Value)
        url     := this._CleanField(urlEdit.Value)
        key     := this._CleanField(keyEdit.Value)
        listKey := this._CleanField(listKeyEdit.Value)
        if (name == "" || (pat == "" && url == ""))
            return this._ValidationError("名前と、パターンまたは URL を入力してください。")
        ; INI / プロファイル形式を壊す文字を拒否
        if RegExMatch(name, "[=|,]")
            return this._ValidationError("名前に = | , は使えません。")
        if InStr(pat . url . key . listKey, "|")
            return this._ValidationError("各項目に | は使えません（設定の区切り文字のため）。")
        try {
            ; 名前の重複（INI キーが衝突すると片方が黙って消える）
            loop lv.GetCount() {
                if (A_Index != row && lv.GetText(A_Index, 2) = name)
                    return this._ValidationError("名前「" . name . "」は既に存在します。")
            }
            ; ショートカット / リストキーの重複
            if (key != "") {
                loop lv.GetCount() {
                    if (A_Index != row && lv.GetText(A_Index, 5) == key)
                        return this._ValidationError("ショートカット「" . key . "」は「" . lv.GetText(A_Index, 2) . "」に既に割り当て済みです。")
                }
            }
            if (listKey != "") {
                loop lv.GetCount() {
                    if (A_Index != row && lv.GetText(A_Index, 6) == listKey)
                        return this._ValidationError("リストキー「" . listKey . "」は「" . lv.GetText(A_Index, 2) . "」に既に割り当て済みです。")
                }
            }
            wasDefault := !isNew && lv.GetText(row, 1) == "★"
            if isNew
                lv.Add("", "", name, pat, url, key, listKey)
            else
                lv.Modify(row, "", (wasDefault ? "★" : ""), name, pat, url, key, listKey)
            ; 改名やデフォルト行の編集を DDL に反映
            this._RefreshDefaultDDL(lv, defaultDDL, wasDefault ? name : defaultDDL.Text)
            this._UpdateDefaultMarks(lv, defaultDDL)
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

    ; ウィンドウクリック選択の共通部。クリックされた HWND を返す（0 = キャンセル）
    static _ClickPickWindow() {
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
        return winHwnd
    }

    ; ウィンドウをクリックして検索パターンを自動入力
    static _PickWindow(dg, patEdit, pickActive) {
        dg.Hide()
        winHwnd := this._ClickPickWindow()
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

    ; ウィンドウをクリックして URL / パス欄に起動パスを自動入力
    static _PickPath(dg, urlEdit, pickActive) {
        dg.Hide()
        winHwnd := this._ClickPickWindow()

        exePath := "", folder := ""
        if winHwnd {
            try exePath := WinGetProcessPath("ahk_id " . winHwnd)
            ; エクスプローラーなら開いているフォルダーも候補にする
            try {
                if (WinGetClass("ahk_id " . winHwnd) == "CabinetWClass") {
                    for w in ComObject("Shell.Application").Windows {
                        try {
                            if (w.HWND == winHwnd) {
                                folder := w.Document.Folder.Self.Path
                                break
                            }
                        }
                    }
                }
            }
        }

        if (exePath == "" && folder == "") {
            pickActive.v := false
            dg.Show()
            return
        }
        this._ShowPathPickerDialog(dg, urlEdit, exePath, folder, pickActive)
    }

    static _ShowPathPickerDialog(dg, urlEdit, exePath, folder, pickActive) {
        pk := Gui("+AlwaysOnTop", "パスを選択")
        pk.SetFont("s10", "Segoe UI")
        pk.MarginX := 15
        pk.MarginY := 12

        pk.Add("Text",, "URL / パス欄に入力する値を選択してください:")
        radios := [], values := []
        if (folder != "") {
            radios.Push(pk.Add("Radio", "xm y+10 Checked", "フォルダー:      " . folder))
            values.Push(folder)
        }
        if (exePath != "") {
            radios.Push(pk.Add("Radio", "xm y+6" . (folder == "" ? " Checked" : ""), "実行ファイル:  " . exePath))
            values.Push(exePath)
        }

        btnOk     := pk.Add("Button", "xm y+14 w80 Default", "OK")
        btnCancel := pk.Add("Button", "x+10 w80", "キャンセル")

        btnOk.OnEvent("Click",     (*) => this._OnPathPickOk(pk, dg, urlEdit, radios, values, pickActive))
        btnCancel.OnEvent("Click", (*) => (pk.Destroy(), pickActive.v := false, dg.Show()))
        pk.OnEvent("Close",        (*) => (pk.Destroy(), pickActive.v := false, dg.Show()))
        pk.OnEvent("Escape",       (*) => (pk.Destroy(), pickActive.v := false, dg.Show()))
        pk.Show("AutoSize")
    }

    static _OnPathPickOk(pk, dg, urlEdit, radios, values, pickActive) {
        val := ""
        for i, r in radios {
            if r.Value {
                val := values[i]
                break
            }
        }
        pk.Destroy()
        pickActive.v := false
        if WinExist(dg) {
            if (val != "")
                urlEdit.Value := val
            dg.Show()
        }
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
        pk.OnEvent("Escape",       (*) => (pk.Destroy(), pickActive.v := false, dg.Show()))
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
            lv.Modify(A_Index, "Col5", "", "")
        this._Tip("キーをすべてリセットしました")
    }

    ; プロファイル編集ダイアログ：現在のターゲット一覧からチェックボックスで選択
    static _EditProfileDialog(lvP, lv, row, ownerHwnd, profileDDL) {
        isNew := (row == 0)
        dg    := Gui("+AlwaysOnTop" . (ownerHwnd ? " +Owner" . ownerHwnd : ""), isNew ? "プロファイル追加" : "プロファイル編集")
        dg.SetFont("s10", "Segoe UI")
        dg.MarginX := 15
        dg.MarginY := 10

        dg.Add("Text", , "プロファイル名:")
        nameEdit := dg.Add("Edit", "w300 r1", isNew ? "" : lvP.GetText(row, 1))

        dg.Add("Text", "y+10", "含むターゲット:")

        allTargets := []
        loop lv.GetCount()
            allTargets.Push(lv.GetText(A_Index, 2))

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

        btnOk.OnEvent("Click",     (*) => this._SaveProfileEntry(dg, lvP, row, isNew, nameEdit, checkboxes, allTargets, profileDDL))
        btnCancel.OnEvent("Click", (*) => dg.Destroy())
        dg.OnEvent("Close",        (*) => dg.Destroy())
        dg.OnEvent("Escape",       (*) => dg.Destroy())
        dg.Show("AutoSize")
        nameEdit.Focus()
    }

    static _SaveProfileEntry(dg, lvP, row, isNew, nameEdit, checkboxes, allTargets, profileDDL) {
        name := this._CleanField(nameEdit.Value)
        if (name == "")
            return this._ValidationError("プロファイル名を入力してください。")
        if RegExMatch(name, "[=|]")
            return this._ValidationError("プロファイル名に = | は使えません。")
        loop lvP.GetCount() {
            if (A_Index != row && lvP.GetText(A_Index, 1) = name)
                return this._ValidationError("プロファイル「" . name . "」は既に存在します。")
        }
        selected := []
        for i, cb in checkboxes {
            if cb.Value
                selected.Push(allTargets[i])
        }
        if (selected.Length == 0)
            return this._ValidationError("少なくとも1つのターゲットを選択してください。")
        joined := ""
        for i, t in selected
            joined .= (i == 1 ? "" : ",") . t

        if isNew
            lvP.Add("", name, joined)
        else
            lvP.Modify(row, "", name, joined)
        this._RefreshProfileDDL(lvP, profileDDL, profileDDL.Text)
        dg.Destroy()
    }
}
