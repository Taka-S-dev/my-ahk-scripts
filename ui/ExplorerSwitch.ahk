; ==============================================================================
; Module:       ExplorerSwitch.ahk
; Description:  開いている Windows Explorer をパスで検索して切り替える
;               見た目と F1 の一覧は Navi と共通（NaviTheme・NaviHelp。Main.ahk で Navi.ahk を先に読み込む）
;
; Usage Example (Main.ahk):
;   #Include "ui\ExplorerSwitch.ahk"
;   ExplorerSwitch.Init()
;   #HotIf GetKeyState(MOD_KEY, "P")
;   e:: ExplorerSwitch.Toggle()
;   #HotIf
; ==============================================================================
#Requires AutoHotkey v2.0

class ExplorerSwitch {
    static IniPath := A_ScriptDir "\ui\ExplorerSwitch.ini"
    static GuiObj := 0
    static Items := []
    static FilteredItems := []
    static PinnedHwnds := Map()
    ; hwnd -> 1..9。番号を付けた窓（Ctrl+P）。起動している間だけ覚える
    static FavoriteNumbers := Map()
    static LayoutSlots := Map()
    ; ルールパス -> ラベル。パス自身と配下に適用し、INIで永続化する。
    static PathLabels := Map()
    static _labelEditor := 0
    static ImageListId := 0
    static IconIndexes := Map()
    static _hotifFn := ""
    static _refreshTimerFn := ""
    static _cacheTimerFn := ""
    static _focusWatchTimerFn := ""
    static _notifyFn := ""
    static _focusWatchBorn := 0
    static _focusEverActive := false
    static _suspendAutoCloseUntil := 0
    static _ignoreFocusLossUntilReactivated := false
    static _initialized := false
    static _lastMouseShowTick := 0
    static _refreshBusy := false
    static _lastUseTick := 0
    static _skipHwnd := 0             ; 開く前にいた窓（最初の選択で飛ばす）
    static _numberedHwnd := 0         ; 数字 1 文字の検索で先頭に出した、その番号を付けた窓
    static _preselectPending := false ; 開いた直後の「1 つ前の窓を選ぶ」を、最新の並びで取り直すまで続ける
    static _holdKey := ""             ; 押したまま開いたキー（離したら見張りをやめる）
    static _holdCycled := false       ; 押したまま E で選び直したか（離したら切り替える）
    static _holdWatchFn := ""
    static HOLD_WATCH_INTERVAL := 30
    static _lastTypeTick := 0
    static _resultsHwnd := 0
    static _notifyHooked := false
    ; hwnd -> {title, path, displayName, isFileSystem}。COM呼び出しを省くための一時キャッシュ。
    static _pathCache := Map()
    static _fullQueryCountdown := 0
    ; 表示中の行並びを固定するための hwnd -> 表示順。
    static _orderLock := Map()
    static _orderLockNext := 0

    ; いずれも初回の既定値。GUIで変更後はINIの保存値を使用する。
    static CloseOnFocusLoss := true
    ; trueならExplorer切替後もSwitcherを表示したままにする。
    static KeepOpenAfterActivate := false
    ; 通常のAlt+Tab対象アプリも一覧へ加える。
    static IncludeApps := false
    ; 検索欄が空のときに番号の数字を打ったら、Enter を待たずにその窓へ切り替える。既定は OFF
    ; （ON だと、番号のある数字で始まる名前は 1 文字目から探せない。2024 を探すなら 024 から打つ）
    static NumberJumpsImmediately := false
    ; 中クリックでSwitcherを開く。既定はOFF（ONの間は他アプリの中クリックより優先される）。
    static MiddleClickOpens := false
    static GUI_W := 796      ; 一覧の幅
    static ARRANGE_W := 72   ; 整列のボタン
    static GEAR_W := 32      ; ⚙ のボタン
    static HINTS_W := 320    ; ステータスバー右の操作の案内
    ; F1 の一覧（NaviHelp と同じ形: 列ごとに見出しと [キー, 説明] の行）
    static HELP_SECTIONS := [
        [{ title: "基本", rows: [
            ["Enter", "切り替える（最初は 1 つ前の窓）"],
            ["押したまま E", "次の窓へ（離すと切り替え）"],
            ["Shift+Enter", "最小化 / 元に戻す"],
            ["↑↓ / Ctrl+J/K", "選ぶ"],
            ["Ctrl+Space", "行のメニュー"],
            ["Ctrl+F", "検索欄へ"],
            ["F5", "一覧を取り直す"],
            ["Esc", "検索を消す / 閉じる"]] },
         { title: "マウス", rows: [
            ["ダブルクリック", "切り替える"],
            ["名前の右のボタン", "最小化 / 元に戻す"],
            ["右クリック", "行のメニュー（番号・最小化・配置も）"]] }],
        [{ title: "番号", rows: [
            ["Ctrl+P", "空いている番号を付ける / 外す"],
            ["1〜9 → Enter", "その番号を付けた窓へ（一覧の先頭に出る。⚙ で Enter 不要にもできる）"],
            ["Alt+1〜9", "その番号を付けた窓へすぐ切り替え"],
            ["Ctrl+Shift+1〜9", "その番号を付ける（使用中なら入れ替え）"],
            ["Ctrl+Shift+P", "番号を全部外す"]] },
         { title: "整理", rows: [
            ["Ctrl+C", "パスをコピー"],
            ["F2", "パスに名前を付ける"],
            ["Ctrl+Del", "同じパスのほかの窓を閉じる"],
            ["Ctrl+M", "全部最小化"]] }],
        [{ title: "整列", rows: [
            ["Ctrl+G", "マウスの画面に 2×2（決めた窓だけ / 最近の 4 枚）"],
            ["Ctrl+1〜4", "この窓の位置を決める"],
            ["Ctrl+0", "位置の指定を外す"]] },
         { title: "設定", rows: [
            ["⚙", "閉じ方・中クリックなど"],
            ["F1", "この一覧"]] }]
    ]
    static REFRESH_INTERVAL := 1000
    static CACHE_REFRESH_INTERVAL := 3000
    ; 最後にSwitcherを使ってからこの時間が経つと裏の一覧更新を止める。
    static CACHE_IDLE_TIMEOUT := 60000
    ; この回数に1回はパスキャッシュを使わずCOMから取り直す。
    static FULL_QUERY_EVERY := 10
    ; 入力直後はこの時間だけ定期更新を見送り、打鍵の引っかかりを避ける。
    static TYPING_QUIET_PERIOD := 300
    static SHOW_REFRESH_DELAY := -40
    static FOCUS_WATCH_INTERVAL := 100
    static ACTIVATE_DELAY := -60
    static REFOCUS_DELAY := -150
    static EM_SETCUEBANNER := 0x1501
    static LVM_ENSUREVISIBLE := 0x1013
    static LVM_GETTOPINDEX := 0x1027
    static LVM_GETCOUNTPERPAGE := 0x1028
    static WM_NOTIFY := 0x004E
    static NM_CUSTOMDRAW := -12
    ; ネットワーク上のフォルダの行の文字（RGB）。最小化している窓は NaviTheme.TEXT_SUBTLE で薄くする
    static NETWORK_TEXT := "0066CC"
    static NAME_COL_W := 294  ; 名前の列の幅（残りはパス / タイトル）
    static _rowViews := []    ; 一覧の各行に描く中身（_RowView）
    static _arrangePreview := Map()  ; 整列で並ぶ窓 → 位置（1〜4）。一覧の印に使う
    static SLOT_ICONS := ["", "◤", "◥", "◣", "◢"]  ; 位置なし・左上・右上・左下・右下
    static _hotRow := 0       ; マウスが乗っている行（最小化のボタンを出す）
    static _hotOnButton := false  ; マウスがその行のボタンの上か
    static _hotTimerFn := ""
    static _iconFontHandle := 0   ; 行のボタンの絵柄（アイコンフォント）
    static _tipFor := 0       ; ツールチップを出しているボタン
    static _tipTimerFn := ""
    static BUTTON_TIPS := Map(
        "ArrangeButton", "マウスのある画面に 2×2 で並べて前に出す（Ctrl+G）`n"
            . "・位置を決めた窓（Ctrl+1〜4 か右クリックの「配置」）があれば、その窓だけを決めた位置に`n"
            . "・なければ、最近使ったエクスプローラーを 4 枚まで（最小化している窓はそのまま）`n"
            . "並ぶ窓と位置は、一覧の名前の後ろの ◤◥◣◢（濃い印は決めた位置、薄い印は最近使った順で入る位置）",
        "SettingsButton", "設定（閉じ方・中クリックで開く など）")
    static DRIVE_REMOTE := 4
    static SIID_DRIVENET := 9
    static SHGSI_ICON_SMALL := 0x101  ; SHGSI_ICON | SHGSI_SMALLICON

    static Init() {
        if this._initialized
            return

        this.CloseOnFocusLoss := this._ReadSetting("CloseOnFocusLoss", this.CloseOnFocusLoss)
        this.KeepOpenAfterActivate := this._ReadSetting("KeepOpenAfterActivate",
            this.KeepOpenAfterActivate)
        this.IncludeApps := this._ReadSetting("IncludeApps", this.IncludeApps)
        this.NumberJumpsImmediately := this._ReadSetting("NumberJumpsImmediately", this.NumberJumpsImmediately)
        this.MiddleClickOpens := this._ReadSetting("MiddleClickOpens", this.MiddleClickOpens)
        this._LoadPathLabels()

        ; 中クリックは設定がONの間だけ効かせる。OFFなら条件が偽になり、中クリックは
        ; そのまま他アプリへ届く（QuickSwitchなど他の中クリック割り当ても動く）。
        HotIf((*) => this.MiddleClickOpens)
        Hotkey("MButton", (*) => this.ShowFromMouse(), "On")
        HotIf()

        this._hotifFn := (*) => this.GuiObj
            && this._GuiExists()
            && WinActive("ahk_id " . this.GuiObj.Hwnd)
        this._refreshTimerFn := () => this._RefreshWhileVisible()
        this._cacheTimerFn := () => this._RefreshCacheWhileHidden()
        this._focusWatchTimerFn := () => this._FocusWatchTick()
        this._holdWatchFn := () => this._HoldWatchTick()
        ; ボタンにマウスを乗せたら、何が起きるかを出す（整列は動きが見えにくいので、押す前に分かるように）
        this._tipTimerFn := () => this._HideButtonTipWhenLeft()
        OnMessage(0x0200, (wParam, lParam, msg, hwnd) => this._OnMouseMove(hwnd, lParam))  ; WM_MOUSEMOVE
        this._hotTimerFn := () => this._ClearHotRowWhenLeft()
        ; WM_NOTIFYはプロセス内の全GUIから飛んでくるので、常時フックすると
        ; Switcherを開いていない間もMain.ahkの他モジュールに負担がかかる。
        ; 実際に描画が必要な「表示中」だけ登録する。
        this._notifyFn := (wParam, lParam, msg, hwnd) => this._OnNotify(wParam, lParam, msg, hwnd)

        HotIf(this._hotifFn)
        Hotkey("Escape", (*) => this.HandleEscape(), "On")
        Hotkey("Enter", (*) => this.ActivateSelected(), "On")
        Hotkey("+Enter", (*) => this.ToggleSelectedVisibility(), "On")
        Hotkey("F2", (*) => this.EditSelectedPathLabel(), "On")
        Hotkey("F5", (*) => this.ForceRefresh(), "On")
        Hotkey("F1", (*) => this.ShowHelp(), "On")
        Hotkey("^f", (*) => this.FocusSearch(), "On")
        Hotkey("^c", (*) => this.CopySelectedPath(), "On")
        Hotkey("^p", (*) => this.TogglePin(), "On")
        Hotkey("^+p", (*) => this.ClearAllFavorites(), "On")
        Hotkey("^m", (*) => this.MinimizeAll(), "On")
        Hotkey("^g", (*) => this.ArrangeOnCurrentMonitors(), "On")
        Hotkey("^0", (*) => this.AssignSelectedLayoutSlot(0), "On")
        Hotkey("^1", (*) => this.AssignSelectedLayoutSlot(1), "On")
        Hotkey("^2", (*) => this.AssignSelectedLayoutSlot(2), "On")
        Hotkey("^3", (*) => this.AssignSelectedLayoutSlot(3), "On")
        Hotkey("^4", (*) => this.AssignSelectedLayoutSlot(4), "On")
        Hotkey("^Delete", (*) => this.CloseDuplicates(), "On")
        Hotkey("Up", (*) => this._MoveSelection(-1), "On")
        Hotkey("Down", (*) => this._MoveSelection(1), "On")
        ; Navi と同じキー: Ctrl+J/K で上下、Ctrl+Space で選んだ行のメニュー
        Hotkey("^j", (*) => this._MoveSelection(1), "On")
        Hotkey("^k", (*) => this._MoveSelection(-1), "On")
        Hotkey("^Space", (*) => this.ShowSelectedRowMenu(), "On")
        ; 番号を付けた窓へは Alt+数字で切り替える。数字だけで切り替えると、数字で始まるパス（2024... など）を
        ; 検索しようとした 1 文字目で別の窓へ飛んでしまうため、数字は検索の文字としてそのまま入れる
        Loop 9 {
            favoriteNumber := A_Index
            favoriteHandler := ObjBindMethod(this, "HandleFavoriteDigit", favoriteNumber)
            assignFavoriteHandler := ObjBindMethod(this,
                "AssignSelectedFavoriteNumber", favoriteNumber)
            Hotkey("!" . favoriteNumber, favoriteHandler, "On")
            Hotkey("!Numpad" . favoriteNumber, favoriteHandler, "On")
            Hotkey("^+" . favoriteNumber, assignFavoriteHandler, "On")
            Hotkey("^+Numpad" . favoriteNumber, assignFavoriteHandler, "On")
        }
        HotIf()

        ; GUIを初めて開く前に一覧を用意しておく。以後の定期更新は実際にSwitcherを
        ; 使った前後だけ回す（常時のCOM列挙はネットワークパスで待たされ得るため）。
        this._lastUseTick := A_TickCount
        SetTimer(this._cacheTimerFn, -50)
        this._initialized := true
    }

    static _ReadSetting(key, defaultValue) {
        try
            return IniRead(this.IniPath, "Settings", key, defaultValue ? "1" : "0") == "1"
        catch
            return defaultValue
    }

    static _WriteSetting(key, value) {
        try IniWrite(value ? "1" : "0", this.IniPath, "Settings", key)
    }

    /**
     * 開く / 閉じる（無変換+E）。holdKey は押したまま開いたキー（無変換なら MOD_KEY、代わりのキーなら "RAlt"）
     * Alt+Tab と同じく、holdKey を押したまま E をもう一度押すたびに次の窓へ進み、離したらその窓へ切り替える
     * 1 回押してすぐ離したときは一覧が開いたままになり、検索できる（最初は 1 つ前の窓が選ばれている）
     * 開いたまま別の窓を触っていたときは、閉じずに手前へ戻す
     */
    static Toggle(holdKey := "") {
        if (this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd)) {
            if WinActive("ahk_id " . this.GuiObj.Hwnd) {
                if (holdKey != "" && this._holdKey == holdKey) {
                    this._MoveSelection(1)
                    this._holdCycled := true
                    return
                }
                this.Hide()
                return
            }
            this._FocusShown()
        } else
            this.Show()
        if (holdKey != "" && GetKeyState(holdKey, "P")) {
            this._holdKey := holdKey
            this._holdCycled := false
            SetTimer(this._holdWatchFn, this.HOLD_WATCH_INTERVAL)
        }
    }

    ; 押したまま開いたキーが離されたら見張りをやめる。押したまま E で選び直していれば、その窓へ切り替える
    static _HoldWatchTick() {
        if (this._holdKey != "" && GetKeyState(this._holdKey, "P")
            && this._GuiExists() && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd))
            return
        SetTimer(this._holdWatchFn, 0)
        cycled := this._holdCycled
        this._holdKey := "", this._holdCycled := false
        if (cycled && this._GuiExists() && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd))
            this.ActivateSelected()
    }

    static ShowFromMouse() {
        ; マウスボタンのチャタリングや連続入力を捨て、最初の1回だけを
        ; 表示／非表示トグルとして扱う。
        if (this._lastMouseShowTick
            && A_TickCount - this._lastMouseShowTick < 250)
            return
        this._lastMouseShowTick := A_TickCount

        if (this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd)) {
            if WinActive("ahk_id " . this.GuiObj.Hwnd)
                this.Hide()
            else
                this._FocusShown()
            return
        }
        this.Show(true)
    }

    ; 開いたまま別の窓を触っていたときは、作り直さずに手前へ戻し、検索欄にカーソルを置く
    ; （位置・検索の文字・選択はそのまま。文字は全選択して、打てば置き換わるように）
    ; 別の画面に置いたままだと見失うので、そのときだけマウスのある画面へ移す
    static _FocusShown() {
        hwnd := this.GuiObj.Hwnd
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mouseX, &mouseY)
        mouseMonitor := DllCall("user32\MonitorFromPoint", "int64", (mouseY << 32) | (mouseX & 0xFFFFFFFF), "uint", 2, "ptr")
        if (mouseMonitor != DllCall("user32\MonitorFromWindow", "ptr", hwnd, "uint", 2, "ptr")) {
            rect := Buffer(16, 0)
            DllCall("user32\GetWindowRect", "ptr", hwnd, "ptr", rect)
            position := this._GetCursorMonitorCenter(NumGet(rect, 8, "int") - NumGet(rect, 0, "int")
                , NumGet(rect, 12, "int") - NumGet(rect, 4, "int"))
            DllCall("user32\SetWindowPos", "ptr", hwnd, "ptr", 0, "int", position.x, "int", position.y
                , "int", 0, "int", 0, "uint", 0x15)  ; SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
        }
        this._lastUseTick := A_TickCount
        WinActivate("ahk_id " . hwnd)
        search := this.GuiObj["Search"]
        search.Focus()
        DllCall("user32\SendMessageW", "ptr", search.Hwnd, "uint", 0xB1, "ptr", 0, "ptr", -1)  ; EM_SETSEL（全選択）
    }

    static Show(showNearMouse := false) {
        if !this._initialized
            this.Init()
        if !this._GuiExists()
            this._CreateGui()
        this._lastUseTick := A_TickCount
        this._StopCacheTimer()
        this._StartNotifyHook()
        ; 開くたびに最新のZ順で並びを取り直し、以後は閉じるまで固定する。
        this._orderLock.Clear()
        this._orderLockNext := 0

        ; 開く前にいた窓。最初の選択ではこれを飛ばし、1 つ前の窓を選ぶ（Alt+Tab と同じ）
        if !WinActive("ahk_id " . this.GuiObj.Hwnd)
            this._skipHwnd := WinExist("A")
        this._preselectPending := true
        ; 前回の絞り込みを持ち越して空一覧に見えることを防ぐ。
        this.GuiObj["Search"].Value := ""
        ; キャッシュから先に描画して、COM列挙を待たずにウィンドウを表示する。
        this.ApplyFilter("")
        ; マウスのある画面に出す。中クリックで開いたときはマウスのそば、キーボードで開いたときはその画面の
        ; 中央より少し上（前回の位置に出すと、別の画面で作業しているときに離れた画面に出て探すことになる）
        this.GuiObj.Show("AutoSize Hide")
        rect := Buffer(16, 0)
        DllCall("user32\GetWindowRect", "ptr", this.GuiObj.Hwnd, "ptr", rect)
        guiWidth := NumGet(rect, 8, "int") - NumGet(rect, 0, "int")
        guiHeight := NumGet(rect, 12, "int") - NumGet(rect, 4, "int")
        position := showNearMouse ? this._GetMousePopupPosition(guiWidth, guiHeight)
            : this._GetCursorMonitorCenter(guiWidth, guiHeight)
        this.GuiObj.Show("AutoSize x" . position.x . " y" . position.y)
        WinActivate("ahk_id " . this.GuiObj.Hwnd)
        this.GuiObj["Search"].Focus()
        this._StartRefreshTimer()
        this._StartFocusWatch()
        ; GUIの初回描画後に最新状態へ追従する。
        SetTimer(() => this.Refresh(), this.SHOW_REFRESH_DELAY)
    }

    ; マウスのある画面の作業領域で、横は中央、縦は上から 3 分の 1 の位置（呼び出して使う窓の定位置）
    static _GetCursorMonitorCenter(guiWidth, guiHeight) {
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mouseX, &mouseY)
        monitor := DllCall("user32\MonitorFromPoint", "int64", (mouseY << 32) | (mouseX & 0xFFFFFFFF), "uint", 2, "ptr")
        mi := Buffer(40, 0)
        NumPut("uint", 40, mi, 0)
        if (!monitor || !DllCall("user32\GetMonitorInfoW", "ptr", monitor, "ptr", mi))
            return this._GetMousePopupPosition(guiWidth, guiHeight)
        left := NumGet(mi, 20, "int"), top := NumGet(mi, 24, "int")
        right := NumGet(mi, 28, "int"), bottom := NumGet(mi, 32, "int")
        return {
            x: left + Max(0, (right - left - guiWidth) // 2),
            y: top + Max(0, (bottom - top - guiHeight) // 3)
        }
    }

    static _GetMousePopupPosition(guiWidth, guiHeight) {
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mouseX, &mouseY)
        point := (mouseY << 32) | (mouseX & 0xFFFFFFFF)
        monitor := DllCall("user32\MonitorFromPoint", "int64", point,
            "uint", 2, "ptr")

        mi := Buffer(40, 0)
        NumPut("uint", 40, mi, 0)
        if (!monitor || !DllCall("user32\GetMonitorInfoW", "ptr", monitor, "ptr", mi))
            return {x: mouseX + 18, y: mouseY + 18}

        left := NumGet(mi, 20, "int")
        top := NumGet(mi, 24, "int")
        right := NumGet(mi, 28, "int")
        bottom := NumGet(mi, 32, "int")
        gap := 18

        ; 基本は右下。収まらなければポインターの反対側へ開く。
        x := mouseX + gap
        if (x + guiWidth > right)
            x := mouseX - guiWidth - gap
        y := mouseY + gap
        if (y + guiHeight > bottom)
            y := mouseY - guiHeight - gap

        return {
            x: Max(left, Min(x, right - guiWidth)),
            y: Max(top, Min(y, bottom - guiHeight))
        }
    }

    static Hide() {
        this._HideButtonTip()
        this._SetHotRow(0, false)
        this._StopRefreshTimer()
        this._StopFocusWatch()
        this._StopNotifyHook()
        if this._GuiExists()
            this.GuiObj.Hide()
        ; 続けて開き直される可能性が高い間だけ、裏で一覧を温め直す。
        this._lastUseTick := A_TickCount
        this._StartCacheTimer()
    }

    static _GuiExists() {
        return this.GuiObj && this.GuiObj.Hwnd
            && DllCall("user32\IsWindow", "ptr", this.GuiObj.Hwnd)
    }

    static Refresh() {
        ; 列挙中に定期タイマーやホットキーが割り込んで多重実行されると、
        ; Itemsと実際の行が食い違い、行番号での操作が別ウィンドウへ届き得る。
        if (!this._GuiExists() || this._refreshBusy)
            return

        this._refreshBusy := true
        try
            this._RefreshCore()
        finally
            this._refreshBusy := false
    }

    ; F5用。キャッシュを無視して必ずCOMから取り直す。
    static ForceRefresh() {
        this._fullQueryCountdown := 0
        this.Refresh()
    }

    static _RefreshCore() {
        selectedHwnd := this._GetSelectedHwnd()
        lv := this.GuiObj["Results"]
        topIndex := SendMessage(this.LVM_GETTOPINDEX, 0, 0, lv)
        result := this._EnumerateVisibleItems()
        if !result.ok {
            this._SetStatus("Explorer一覧を取得できませんでした。F5で再試行できます")
            return
        }
        newItems := result.items
        query := this.GuiObj["Search"].Value
        expectedRowCount := this._CountMatches(newItems, query)

        ; 定期更新ごとの全行再作成はスクロール位置を先頭へ戻してしまう。
        ; 表示内容に実質的な変更がなく、GUIの実際の行数も正しい場合だけ触れない。
        ; GUIが作り直された場合はItemsが同じでも空なので必ず再構築する。
        if (this._ItemsEquivalent(this.Items, newItems) && lv.GetCount() == expectedRowCount) {
            this._preselectPending := false
            return
        }

        this.Items := newItems
        ; 開いた直後は古い一覧から描いているので、最新の並びで取り直したら「1 つ前の窓」を選び直す
        ; （利用者が選択を動かしたり打ったりしたあとは、その選択を保つ）
        this.ApplyFilter(query, this._preselectPending ? 0 : selectedHwnd, topIndex)
        this._preselectPending := false
    }

    static ApplyFilter(query, preferredHwnd := 0, preferredTopIndex := -1) {
        if !this._GuiExists()
            return

        query := Trim(query)
        tokens := this._TokenizeQuery(query)
        filtered := []
        ; 数字 1 文字だけなら、その番号を付けた窓を先頭に出す（1 → Enter で切り替えられる。Alt+数字より指が楽）
        ; 名前やパスにその数字を含む窓も、普通の検索と同じくその下に並ぶ
        numberedHwnd := RegExMatch(query, "^[1-9]$") ? this._GetFavoriteHwnd(Integer(query)) : 0
        for item in this.Items {
            if (item.hwnd == numberedHwnd)
                filtered.InsertAt(1, item)
            else if this._ItemMatchesTokens(item, tokens)
                filtered.Push(item)
        }
        this.FilteredItems := filtered
        this._numberedHwnd := numberedHwnd

        lv := this.GuiObj["Results"]
        lv.Opt("-Redraw")
        lv.Delete()
        ; 行の文字は NM_CUSTOMDRAW で自前で描く（一致した文字に色を付け、パスは頭を省いて名前を残すため）
        ; 一覧のセルは空にして、描く中身は _rowViews に持つ
        this._rowViews := []
        this._hotRow := 0, this._hotOnButton := false  ; 行が作り直されるので、次にマウスが動いたときに付け直す
        ; 整列で並ぶ窓と位置を、名前の後ろに印で出す（押す前に、どの窓がどこへ行くか分かるように）
        this._arrangePreview := this._ArrangePlan(this.Items)
        selectRow := 0
        for row, item in filtered {
            iconIndex := this._GetItemIconIndex(item)
            lv.Add(iconIndex > 0 ? "Icon" . iconIndex : "", "", "")
            this._rowViews.Push(this._RowView(item, tokens))
            if (preferredHwnd && item.hwnd == preferredHwnd)
                selectRow := row
        }
        lv.Opt("+Redraw")
        ; 選ぶ窓の指定がなく、検索もしていなければ、最後に使った順で開く前にいた窓の次（= 1 つ前の窓）を選ぶ
        ; （Alt+Tab と同じ。番号を付けた窓は先頭に並ぶので、並び順ではなく使った順で探す）
        if (selectRow == 0 && query == "" && filtered.Length >= 2) {
            for i, it in filtered
                if (it.hwnd != this._skipHwnd && (!selectRow || it.rank < filtered[selectRow].rank))
                    selectRow := i
        }

        if (filtered.Length > 0) {
            if (selectRow == 0)
                selectRow := 1
            lv.Modify(selectRow, "Select Focus Vis")
            if (preferredTopIndex >= 0)
                this._RestoreListScroll(lv, preferredTopIndex)
        }
        this._UpdateStatus()
    }

    /**
     * 1 行に描く中身。name: 名前の列（番号・名前・重複・配置・最小化）、detail: パスかタイトル
     * 一致した文字の位置（1 始まり）を Map で持つ。パスは ~ で短くし、親と名前に分けて持つ（_DrawPath 用）
     */
    static _RowView(item, tokens) {
        favoriteNumber := this._GetFavoriteNumber(item.hwnd)
        head := (favoriteNumber ? "[" . favoriteNumber . "] " : "") . (item.label != "" ? item.label . "  " : "")
        nameHl := Map()
        if (favoriteNumber && item.hwnd == this._numberedHwnd)
            nameHl[2] := true  ; 番号で先頭に出したことが分かるように、[n] の数字に色を付ける
        if (item.label != "")
            this._AddMatches(nameHl, item.label, tokens, StrLen(head) - StrLen(item.label) - 2)
        this._AddMatches(nameHl, item.displayName, tokens, StrLen(head))
        color := item.isMinimized ? NaviTheme.TEXT_SUBTLE : item.isNetwork ? this.NETWORK_TEXT : NaviTheme.TEXT
        ; 名前の後ろの印。整列の位置は、自分で決めた位置（Ctrl+1〜4）なら名前と同じ濃さ、
        ; 最近使った順で自動で入る位置なら薄くする（指定を外しても印が残るのは、自動で入るからだと分かるように）
        tails := []
        if (item.duplicateCount > 1)
            tails.Push({ s: "  ×" . item.duplicateCount, color: color })
        if this._arrangePreview.Has(item.hwnd) {
            slot := this._arrangePreview[item.hwnd]
            chosen := this.LayoutSlots.Has(item.hwnd) && this.LayoutSlots[item.hwnd] == slot
            tails.Push({ s: "  " . this.SLOT_ICONS[slot + 1], color: chosen ? color : NaviTheme.TEXT_SUBTLE })
        }
        if item.isMinimized
            tails.Push({ s: "  （最小化）", color: color })
        view := { name: head . item.displayName, nameHl: nameHl, tails: tails, dir: "", leaf: "", text: "", hl: Map(),
            color: color }
        if (item.kind == "explorer" && item.isFileSystem && !item.isMinimized) {
            shown := this._ShortPath(item.path)
            hl := Map()
            this._AddMatches(hl, shown, tokens, 0)
            SplitPath(shown, &leaf, &dir)
            if (leaf == "") {
                view.text := shown, view.hl := hl
            } else {
                ; 一致の位置を親（dir）と名前（leaf）に振り分ける。間の \ は数えない
                view.dir := dir, view.leaf := leaf, view.pathHl := { dir: Map(), name: Map() }
                for pos in hl {
                    if (pos <= StrLen(dir))
                        view.pathHl.dir[pos] := true
                    else if (pos > StrLen(dir) + 1)
                        view.pathHl.name[pos - StrLen(dir) - 1] := true
                }
            }
        } else {
            view.text := (item.kind == "explorer") ? this._ShortPath(item.path) : item.title
            this._AddMatches(view.hl, view.text, tokens, 0)
        }
        return view
    }

    ; text の中で tokens のどれかに一致した文字の位置（1 始まり + offset）を hl に足す
    static _AddMatches(hl, text, tokens, offset) {
        for token in tokens {
            pos := 1
            while (pos := InStr(text, token, false, pos)) {
                loop StrLen(token)
                    hl[offset + pos + A_Index - 1] := true
                pos += StrLen(token)
            }
        }
    }

    ; ホームフォルダを ~ にして短く見せる（どの行でも同じ C:\Users\<名前> の部分が場所を取るため）
    static _ShortPath(path) {
        home := EnvGet("USERPROFILE")
        if (home != "" && SubStr(path, 1, StrLen(home)) = home
            && (StrLen(path) == StrLen(home) || SubStr(path, StrLen(home) + 1, 1) == "\"))
            return "~" . SubStr(path, StrLen(home) + 1)
        return path
    }

    static ActivateSelected() {
        if this._IsImeComposing() {
            ; Enterホットキーが元のキー入力を消費するため、変換中は検索欄へ
            ; Enterを送り直してIME確定だけを行う。次のEnterで切り替える。
            Send("{Enter}")
            return
        }

        this._ActivateItem(this._GetSelectedItem())
    }

    static _ActivateItem(item) {
        if !item
            return
        if !this._IsItemWindowValid(item) {
            this.Refresh()
            return
        }

        hwnd := item.hwnd
        if this.KeepOpenAfterActivate
            SetTimer(() => this._ActivateKeepingSwitcher(hwnd), this.ACTIVATE_DELAY)
        else {
            this.Hide()
            SetTimer(() => this._ActivateHwnd(hwnd), this.ACTIVATE_DELAY)
        }
    }

    static CopySelectedPath() {
        item := this._GetSelectedItem()
        if !item
            return
        if (item.kind != "explorer" || !item.isFileSystem) {
            this._SetStatus("この行にはコピーできるフォルダーパスがありません")
            return
        }
        A_Clipboard := item.path
        this._SetStatus("コピーしました: " . item.path)
    }

    static FocusSearch() {
        if !this._GuiExists()
            return
        try this.GuiObj["Search"].Focus()
    }

    static EditSelectedPathLabel() {
        item := this._GetSelectedItem()
        if !item
            return
        if (item.kind != "explorer" || !item.isFileSystem) {
            this._SetStatus("名前を付けられるのはフォルダーパスを持つ行だけです")
            return
        }
        this._ShowLabelEditor(item.path)
    }

    static _ShowLabelEditor(path) {
        this._CloseLabelEditor(false)
        ; 既存ルールの配下なら、新しい重複ルールを作らずそのルール自体を編集する。
        rulePath := this._FindRuleForPath(path)
        editPath := rulePath != "" ? rulePath : path
        editLabel := rulePath != "" ? this.PathLabels[rulePath] : ""

        ; エディター表示中は外側クリック判定と一覧の作り直しを止める。
        this._suspendAutoCloseUntil := A_TickCount + 600000
        this._StopRefreshTimer()

        ed := Gui("+AlwaysOnTop -MaximizeBox -MinimizeBox +Owner" . this.GuiObj.Hwnd,
            "パスに名前を付ける")
        NaviTheme.SetFont(ed, "body")
        ed.MarginX := 12
        ed.MarginY := 10
        ed.Add("Text", "xm", "対象パス（親階層まで削ると、その配下すべてに適用）")
        ed.Add("Edit", "xm w560 vLabelPath", editPath)
        ed.Add("Text", "xm y+8", "名前（空で保存すると削除）")
        ed.Add("Edit", "xm w280 vLabelName", editLabel)
        saveButton := ed.Add("Button", "xm y+12 w110 Default", "保存")
        deleteButton := ed.Add("Button", "x+8 yp w110", "削除")
        cancelButton := ed.Add("Button", "x+8 yp w110", "キャンセル")
        ; 削除は既存ルールを開いている時だけ意味を持つ。
        if (rulePath == "")
            deleteButton.Enabled := false
        saveButton.OnEvent("Click", (*) => this._SaveLabelFromEditor())
        deleteButton.OnEvent("Click", (*) => this._DeleteLabelFromEditor())
        cancelButton.OnEvent("Click", (*) => this._CloseLabelEditor())
        ed.OnEvent("Close", (*) => this._CloseLabelEditor())
        ed.OnEvent("Escape", (*) => this._CloseLabelEditor())
        this._labelEditor := ed
        ; 既定のShowは画面中央に出るため、マウス脇で開いたSwitcherから離れた
        ; 位置に表示されてしまう。サイズ確定後にSwitcherの中央へ重ねる。
        ; エディターはSwitcherより小さいので、この位置なら必ず画面内に収まる。
        ed.Show("AutoSize Hide")
        edRect := Buffer(16, 0)
        DllCall("user32\GetWindowRect", "ptr", ed.Hwnd, "ptr", edRect)
        edWidth := NumGet(edRect, 8, "int") - NumGet(edRect, 0, "int")
        edHeight := NumGet(edRect, 12, "int") - NumGet(edRect, 4, "int")
        ownerRect := Buffer(16, 0)
        DllCall("user32\GetWindowRect", "ptr", this.GuiObj.Hwnd, "ptr", ownerRect)
        ownerLeft := NumGet(ownerRect, 0, "int")
        ownerTop := NumGet(ownerRect, 4, "int")
        ownerWidth := NumGet(ownerRect, 8, "int") - ownerLeft
        ownerHeight := NumGet(ownerRect, 12, "int") - ownerTop
        ed.Show("x" . (ownerLeft + (ownerWidth - edWidth) // 2)
            . " y" . (ownerTop + (ownerHeight - edHeight) // 2))
        ed["LabelName"].Focus()
    }

    static _SaveLabelFromEditor() {
        ed := this._labelEditor
        if !ed
            return
        rulePath := this._NormalizePath(Trim(ed["LabelPath"].Value))
        label := Trim(ed["LabelName"].Value)
        if (rulePath == "")
            return

        ; 大文字小文字違いの同一パスを二重登録しない。
        storedKey := ""
        for existingPath in this.PathLabels {
            if (StrCompare(existingPath, rulePath, false) == 0) {
                storedKey := existingPath
                break
            }
        }

        message := ""
        if (label == "") {
            if (storedKey != "") {
                this.PathLabels.Delete(storedKey)
                try IniDelete(this.IniPath, "PathLabels", storedKey)
                message := "名前を削除しました: " . rulePath
            }
        } else {
            if (storedKey != "" && storedKey != rulePath) {
                this.PathLabels.Delete(storedKey)
                try IniDelete(this.IniPath, "PathLabels", storedKey)
            }
            this.PathLabels[rulePath] := label
            try IniWrite(label, this.IniPath, "PathLabels", rulePath)
            message := "「" . label . "」を設定しました: " . rulePath
        }

        this._CloseLabelEditor()
        this.Refresh()
        if (message != "")
            this._SetStatus(message)
    }

    ; パス欄に表示中のルールを削除する。名前を空にした保存と同じ経路に載せ、
    ; 削除処理を一本化する。
    static _DeleteLabelFromEditor() {
        ed := this._labelEditor
        if !ed
            return
        ed["LabelName"].Value := ""
        this._SaveLabelFromEditor()
    }

    static _CloseLabelEditor(refocus := true) {
        ed := this._labelEditor
        this._labelEditor := 0
        if ed
            try ed.Destroy()
        if !refocus
            return
        this._suspendAutoCloseUntil := A_TickCount + 200
        if (this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd)) {
            this._StartRefreshTimer()
            this.FocusSearch()
        }
    }

    static _LoadPathLabels() {
        this.PathLabels := Map()
        try section := IniRead(this.IniPath, "PathLabels")
        catch
            return
        for line in StrSplit(section, "`n", "`r") {
            separatorPos := InStr(line, "=")
            if !separatorPos
                continue
            rulePath := this._NormalizePath(Trim(SubStr(line, 1, separatorPos - 1)))
            label := Trim(SubStr(line, separatorPos + 1))
            if (rulePath != "" && label != "")
                this.PathLabels[rulePath] := label
        }
    }

    ; pathに適用されるルールのパスを返す。複数マッチ時は最長一致を優先し、
    ; 深い階層のルールが浅いルールを上書きできるようにする。
    static _FindRuleForPath(path) {
        bestRule := ""
        bestLength := 0
        lowerPath := StrLower(path)
        for rulePath in this.PathLabels {
            lowerRule := StrLower(rulePath)
            ; パス境界で比較し、"...\folder" が "...\folder2" に誤マッチしない。
            prefix := SubStr(lowerRule, -1) == "\" ? lowerRule : lowerRule . "\"
            if ((lowerPath == lowerRule || InStr(lowerPath, prefix) == 1)
                && StrLen(lowerRule) > bestLength) {
                bestRule := rulePath
                bestLength := StrLen(lowerRule)
            }
        }
        return bestRule
    }

    static _GetPathLabel(path) {
        if (this.PathLabels.Count == 0)
            return ""
        rulePath := this._FindRuleForPath(path)
        return rulePath != "" ? this.PathLabels[rulePath] : ""
    }

    static HandleEscape() {
        if !this._GuiExists()
            return

        search := this.GuiObj["Search"]
        if (search.Value != "") {
            search.Value := ""
            this.ApplyFilter("")
            this.FocusSearch()
            return
        }
        this.Hide()
    }

    static SetCloseOnFocusLoss(enabled) {
        this.CloseOnFocusLoss := enabled ? true : false
        this._WriteSetting("CloseOnFocusLoss", this.CloseOnFocusLoss)

        if !(this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd))
            return
        if this.CloseOnFocusLoss
            this._StartFocusWatch()
        else
            this._StopFocusWatch()
        this.FocusSearch()
    }

    static SetKeepOpenAfterActivate(enabled) {
        this.KeepOpenAfterActivate := enabled ? true : false
        this._WriteSetting("KeepOpenAfterActivate", this.KeepOpenAfterActivate)
        this.FocusSearch()
    }

    static SetNumberJumpsImmediately(enabled) {
        this.NumberJumpsImmediately := enabled ? true : false
        this._WriteSetting("NumberJumpsImmediately", this.NumberJumpsImmediately)
        this.FocusSearch()
    }

    static SetMiddleClickOpens(enabled) {
        this.MiddleClickOpens := enabled ? true : false
        this._WriteSetting("MiddleClickOpens", this.MiddleClickOpens)
        this.FocusSearch()
    }

    static SetIncludeApps(enabled) {
        this.IncludeApps := enabled ? true : false
        this._WriteSetting("IncludeApps", this.IncludeApps)
        this.Refresh()
        this.FocusSearch()
    }

    static TogglePin() {
        item := this._GetSelectedItem()
        if !item
            return

        if this.PinnedHwnds.Has(item.hwnd) {
            this.AssignHwndFavoriteNumber(item.hwnd, 0)
            return
        }
        favoriteNumber := this._FindAvailableFavoriteNumber()
        if !favoriteNumber {
            this._SetStatus("番号は 9 まで使っています（Ctrl+Shift+数字 で付け替えられます）")
            return
        }
        this.AssignHwndFavoriteNumber(item.hwnd, favoriteNumber)
    }

    /**
     * 窓に番号を付ける（0 なら外す）。番号は好きなものを選べる
     * その番号をほかの窓が使っていれば、こちらの元の番号と入れ替える。こちらに番号がなければ、
     * ほかの窓には空いている番号を付け直す（空きがなければ外れる）。番号が黙って消えないように、どうなったかを出す
     */
    static AssignHwndFavoriteNumber(hwnd, favoriteNumber) {
        item := this._FindItemByHwnd(hwnd, this.Items)
        name := item ? item.displayName : ""
        oldNumber := this._GetFavoriteNumber(hwnd)
        if (favoriteNumber == oldNumber) {
            this._SetStatus(favoriteNumber ? "番号は既に " . favoriteNumber . " です" : "番号は付いていません")
            return
        }
        if (favoriteNumber == 0) {
            this.PinnedHwnds.Delete(hwnd)
            this.FavoriteNumbers.Delete(hwnd)
            message := "番号 " . oldNumber . " を外しました: " . name
        } else {
            otherHwnd := this._GetFavoriteHwnd(favoriteNumber)
            this.PinnedHwnds[hwnd] := true
            this.FavoriteNumbers[hwnd] := favoriteNumber
            message := "番号 " . favoriteNumber . " を付けました: " . name
            if otherHwnd {
                otherNumber := oldNumber ? oldNumber : this._FindAvailableFavoriteNumber()
                if otherNumber {
                    this.FavoriteNumbers[otherHwnd] := otherNumber
                    message .= "（元の " . favoriteNumber . " は " . otherNumber . " に）"
                } else {
                    this.PinnedHwnds.Delete(otherHwnd)
                    this.FavoriteNumbers.Delete(otherHwnd)
                    message .= "（元の " . favoriteNumber . " の窓は番号を外しました）"
                }
            }
        }
        ; 番号を付けた窓は先頭に並ぶので並びが変わる。操作した窓の選択はそのまま
        this.Refresh()
        this._SetStatus(message)
        this._SelectHwnd(hwnd)
        this.FocusSearch()
    }

    ; Alt+数字:その番号を付けた窓へ切り替える（検索欄に何か打っていても効く）
    static HandleFavoriteDigit(favoriteNumber, *) {
        if !this._GuiExists()
            return
        hwnd := this._GetFavoriteHwnd(favoriteNumber)
        if !hwnd {
            this._SetStatus("番号 " . favoriteNumber . " の窓はありません（Ctrl+P で番号を付ける）")
            return
        }

        item := this._FindItemByHwnd(hwnd, this.Items)
        if (!item || !this._IsItemWindowValid(item)) {
            this.PinnedHwnds.Delete(hwnd)
            this.FavoriteNumbers.Delete(hwnd)
            this.Refresh()
            this._SetStatus("番号 " . favoriteNumber . " の窓は閉じられています")
            return
        }
        this._ActivateItem(item)
    }

    static _FindAvailableFavoriteNumber() {
        Loop 9 {
            if !this._GetFavoriteHwnd(A_Index)
                return A_Index
        }
        return 0
    }

    static _GetFavoriteNumber(hwnd) {
        return this.FavoriteNumbers.Has(hwnd) ? this.FavoriteNumbers[hwnd] : 0
    }

    static _GetFavoriteHwnd(favoriteNumber) {
        for hwnd, assignedNumber in this.FavoriteNumbers {
            if (assignedNumber == favoriteNumber)
                return hwnd
        }
        return 0
    }

    static ClearAllFavorites() {
        count := this.PinnedHwnds.Count
        if (count == 0) {
            this._SetStatus("番号を付けた窓はありません")
            return
        }

        selectedHwnd := this._GetSelectedHwnd()
        lv := this.GuiObj["Results"]
        topIndex := SendMessage(this.LVM_GETTOPINDEX, 0, 0, lv)
        this.PinnedHwnds.Clear()
        this.FavoriteNumbers.Clear()
        for item in this.Items
            item.isPinned := false
        this.ApplyFilter(this.GuiObj["Search"].Value, selectedHwnd, topIndex)
        this._SetStatus("番号を " . count . " 件外しました")
        this.FocusSearch()
    }

    ; Ctrl+Shift+数字: 選んでいる窓にその番号を付ける（番号がなくても付く）
    static AssignSelectedFavoriteNumber(favoriteNumber, *) {
        if (item := this._GetSelectedItem())
            this.AssignHwndFavoriteNumber(item.hwnd, favoriteNumber)
    }

    static MinimizeAll() {
        if !this._GuiExists()
            return
        ; フィルター表示だけでなく、実行時点で列挙できる全Explorerを対象にする。
        switcherHwnd := this.GuiObj.Hwnd
        ; WinMinimizeが発生させる一時的なフォーカス移動を外側クリックと誤認しない。
        this._suspendAutoCloseUntil := A_TickCount + 600
        result := this._EnumerateExplorerWindows()
        if !result.ok {
            this._SetStatus("Explorer一覧を取得できないため最小化を中止しました")
            return
        }
        currentItems := result.items
        minimizedCount := 0
        for item in currentItems {
            if !this._IsExplorerWindow(item.hwnd)
                continue
            try {
                if (WinGetMinMax("ahk_id " . item.hwnd) != -1)
                    WinMinimize("ahk_id " . item.hwnd)
                item.isMinimized := true
                minimizedCount += 1
            }
        }

        selectedHwnd := this._GetSelectedHwnd()
        if this.IncludeApps {
            for existingItem in this.Items {
                if (existingItem.kind == "app"
                    && DllCall("user32\IsWindow", "ptr", existingItem.hwnd))
                    currentItems.Push(existingItem)
            }
            this._SortItems(currentItems)
        }
        this.Items := currentItems
        this.ApplyFilter(this.GuiObj["Search"].Value, selectedHwnd)
        this._SetStatus(minimizedCount . "個のExplorerを最小化状態にしました")

        ; WinMinimize後にOSが別ウィンドウへフォーカスを渡す場合があるため、
        ; 直後と最小化アニメーション完了後の2段階でSwitcherへ戻す。
        this._RefocusSwitcherSoon(switcherHwnd)
    }

    static ToggleRowVisibility(row) {
        if (row < 1 || row > this.FilteredItems.Length)
            return
        item := this.FilteredItems[row]
        if !this._IsItemWindowValid(item) {
            this._SetStatus("対象のウィンドウは既に閉じられています")
            this.Refresh()
            return
        }

        switcherHwnd := this.GuiObj.Hwnd
        if (WinGetMinMax("ahk_id " . item.hwnd) == -1) {
            this._suspendAutoCloseUntil := A_TickCount + 600
            try WinRestore("ahk_id " . item.hwnd)
            item.isMinimized := false
            this._RedrawRow(row, item)
            this._SetStatus("「" . item.displayName . "」を復元しました")
            this._RefocusSwitcherSoon(switcherHwnd)
            return
        }

        this._suspendAutoCloseUntil := A_TickCount + 600
        try WinMinimize("ahk_id " . item.hwnd)
        item.isMinimized := true
        this._RedrawRow(row, item)
        this._SetStatus("「" . item.displayName . "」を最小化しました")
        this._RefocusSwitcherSoon(switcherHwnd)
    }

    static _ToggleHwndVisibility(hwnd) {
        for row, item in this.FilteredItems
            if (item.hwnd == hwnd)
                return this.ToggleRowVisibility(row)
    }

    ; 1 行だけ描き直す（最小化・復元のあと。行の文字は _rowViews から描く）
    static _RedrawRow(row, item) {
        if (row < 1 || row > this._rowViews.Length)
            return
        this._rowViews[row] := this._RowView(item, this._TokenizeQuery(this.GuiObj["Search"].Value))
        lv := this.GuiObj["Results"]
        DllCall("user32\SendMessageW", "ptr", lv.Hwnd, "uint", 0x1015, "ptr", row - 1, "ptr", row - 1)  ; LVM_REDRAWITEMS
        DllCall("user32\UpdateWindow", "ptr", lv.Hwnd)
    }

    static ToggleSelectedVisibility() {
        if this._IsImeComposing() {
            ; 日本語変換中はウィンドウ操作にせず、まず変換を確定する。
            Send("{Enter}")
            return
        }
        if !this._GuiExists()
            return
        row := this.GuiObj["Results"].GetNext()
        if (row >= 1 && row <= this.FilteredItems.Length)
            this.ToggleRowVisibility(row)
    }

    static AssignSelectedLayoutSlot(slot) {
        if !this._GuiExists()
            return
        row := this.GuiObj["Results"].GetNext()
        if (row < 1 || row > this.FilteredItems.Length)
            return
        if (this.FilteredItems[row].kind != "explorer") {
            this._SetStatus("配置指定はExplorerだけが対象です")
            return
        }
        this.AssignRowLayoutSlot(row, slot)
    }

    ; ポップアップメニューを外側クリックと誤認してSwitcherを閉じないよう抑制し、
    ; 表示中は一覧も作り直さない。メニューからラベルエディターが開かれた場合は
    ; 再開するとエディター表示中に自動クローズが復活するため、エディター側の
    ; 閉じ処理に委ねる。
    static _ShowGuardedMenu(menu, x?, y?) {
        this._suspendAutoCloseUntil := A_TickCount + 60000
        this._StopRefreshTimer()
        menu.Show(x?, y?)
        if this._labelEditor
            return
        this._StartRefreshTimer()
        this._suspendAutoCloseUntil := A_TickCount + 200
        this.FocusSearch()
    }

    /** Ctrl+Space: 選んでいる行のメニューを、その行の位置に開く（右クリックと同じメニュー） */
    static ShowSelectedRowMenu() {
        if !this._GuiExists()
            return
        lv := this.GuiObj["Results"]
        row := lv.GetNext()
        if (row < 1)
            return
        ; 行の左下（名前の列の始まり）に出す。LVM_GETITEMRECT は一覧の中の物理ピクセルなので、画面の座標にして渡す
        rect := Buffer(16, 0)
        NumPut("int", 2, rect, 0)  ; LVIR_LABEL
        DllCall("user32\SendMessageW", "ptr", lv.Hwnd, "uint", 0x100E, "ptr", row - 1, "ptr", rect)  ; LVM_GETITEMRECT
        pt := Buffer(8, 0)
        NumPut("int", NumGet(rect, 0, "int"), pt, 0), NumPut("int", NumGet(rect, 12, "int"), pt, 4)
        DllCall("user32\ClientToScreen", "ptr", lv.Hwnd, "ptr", pt)
        CoordMode("Menu", "Screen")
        this._ShowRowContextMenu(row, NumGet(pt, 0, "int"), NumGet(pt, 4, "int"))
    }

    static _ShowRowContextMenu(row, x, y) {
        if (row < 1 || row > this.FilteredItems.Length) {
            this.FocusSearch()
            return
        }
        this.GuiObj["Results"].Modify(row, "Select Focus")
        item := this.FilteredItems[row]
        hasFolderPath := item.kind == "explorer" && item.isFileSystem

        ; 最小化と配置もここから選ぶ。メニューを閉じるまでに一覧が作り直されて行番号がずれることがあるので、
        ; 行ではなく窓（hwnd）を捕まえておく
        hwnd := item.hwnd
        slotMenu := Menu()
        current := this.LayoutSlots.Has(hwnd) ? this.LayoutSlots[hwnd] : 0
        for i, label in ["指定なし`tCtrl+0", "◤ 左上`tCtrl+1", "◥ 右上`tCtrl+2", "◣ 左下`tCtrl+3", "◢ 右下`tCtrl+4"] {
            slotMenu.Add(label, ((s, *) => this.AssignHwndLayoutSlot(hwnd, s)).Bind(i - 1))
            if (i - 1 == current)
                slotMenu.Check(label)
        }
        slotMenu.Add()
        slotMenu.Add("すべての配置を解除", (*) => this.ClearAllLayoutSlots())

        ; 番号は好きなものを選べる。ほかの窓が使っている番号には、その窓の名前を添える（入れ替わると分かるように）
        numberMenu := Menu()
        currentNumber := this._GetFavoriteNumber(hwnd)
        Loop 9 {
            otherHwnd := this._GetFavoriteHwnd(A_Index)
            other := (otherHwnd && otherHwnd != hwnd) ? this._FindItemByHwnd(otherHwnd, this.Items) : ""
            label := A_Index . (other ? "　" . StrReplace(other.displayName, "&", "&&") : "") . "`tCtrl+Shift+" . A_Index
            numberMenu.Add(label, ((n, *) => this.AssignHwndFavoriteNumber(hwnd, n)).Bind(A_Index))
            if (A_Index == currentNumber)
                numberMenu.Check(label)
        }
        numberMenu.Add()
        numberMenu.Add("外す", (*) => this.AssignHwndFavoriteNumber(hwnd, 0))
        if !currentNumber
            numberMenu.Disable("外す")
        numberMenu.Add("すべて外す`tCtrl+Shift+P", (*) => this.ClearAllFavorites())

        rowMenu := Menu()
        rowMenu.Add("パスに名前を付ける...`tF2", (*) => this.EditSelectedPathLabel())
        rowMenu.Add("パスをコピー`tCtrl+C", (*) => this.CopySelectedPath())
        rowMenu.Add("番号", numberMenu)
        rowMenu.Add()
        rowMenu.Add("重複を閉じる`tCtrl+Del", (*) => this.CloseDuplicates())
        rowMenu.Add()
        rowMenu.Add((item.isMinimized ? "元に戻す" : "最小化") . "`tShift+Enter", (*) => this._ToggleHwndVisibility(hwnd))
        rowMenu.Add("配置", slotMenu)
        if !hasFolderPath {
            ; 仮想フォルダーとアプリ行では、パスを前提とする操作を選べなくする。
            rowMenu.Disable("1&")
            rowMenu.Disable("2&")
            rowMenu.Disable("5&")
        }
        if (item.kind != "explorer")
            rowMenu.Disable("8&")  ; 配置はエクスプローラーの窓だけ
        this._ShowGuardedMenu(rowMenu, x, y)
    }

    static AssignRowLayoutSlot(row, slot) {
        if (row < 1 || row > this.FilteredItems.Length)
            return
        this.AssignHwndLayoutSlot(this.FilteredItems[row].hwnd, slot)
    }

    static AssignHwndLayoutSlot(hwnd, slot) {
        if (!hwnd || slot < 0 || slot > 4)
            return
        item := this._FindItemByHwnd(hwnd)
        if (!item || item.kind != "explorer")
            return
        oldSlot := this.LayoutSlots.Has(hwnd) ? this.LayoutSlots[hwnd] : 0
        if (slot == oldSlot) {
            this.FocusSearch()
            return
        }

        targetMonitor := DllCall("user32\MonitorFromWindow", "ptr", hwnd,
            "uint", 2, "ptr")
        swapHwnd := 0
        if (slot > 0) {
            for otherHwnd, otherSlot in this.LayoutSlots {
                if (otherHwnd == hwnd || otherSlot != slot || !WinExist("ahk_id " . otherHwnd))
                    continue
                otherMonitor := DllCall("user32\MonitorFromWindow", "ptr", otherHwnd,
                    "uint", 2, "ptr")
                if (otherMonitor == targetMonitor) {
                    swapHwnd := otherHwnd
                    break
                }
            }
        }

        if this.LayoutSlots.Has(hwnd)
            this.LayoutSlots.Delete(hwnd)
        if swapHwnd {
            if (oldSlot > 0)
                this.LayoutSlots[swapHwnd] := oldSlot
            else
                this.LayoutSlots.Delete(swapHwnd)
        }
        if (slot > 0)
            this.LayoutSlots[hwnd] := slot

        selectedHwnd := hwnd
        this.ApplyFilter(this.GuiObj["Search"].Value, selectedHwnd)
        message := slot > 0
            ? "「" . item.displayName . "」を配置 " . this._GetLayoutSlotIcon(hwnd) . " に指定しました"
            : "「" . item.displayName . "」の配置指定を解除しました"
        this._SetStatus(message)
        this.FocusSearch()
    }

    static _FindItemByHwnd(hwnd, items := 0) {
        if !items
            items := this.FilteredItems
        for item in items {
            if (item.hwnd == hwnd)
                return item
        }
        return 0
    }

    static _GetLayoutSlotIcon(hwnd) {
        slot := this.LayoutSlots.Has(hwnd) ? this.LayoutSlots[hwnd] : 0
        return slot >= 0 && slot <= 4 ? this.SLOT_ICONS[slot + 1] : ""
    }

    static _GetItemIconIndex(item) {
        if !this.ImageListId
            return 0
        isNetworkExplorer := item.kind == "explorer" && item.isNetwork
        key := item.kind == "explorer"
            ? (isNetworkExplorer ? "explorer-net" : "explorer")
            : "app|" . StrLower(item.path)
        if this.IconIndexes.Has(key)
            return this.IconIndexes[key]

        iconIndex := 0
        if isNetworkExplorer {
            iconIndex := this._AddStockIcon(this.SIID_DRIVENET)
            ; shell32の10番はレガシー固定のネットワークドライブアイコン。
            if (iconIndex == 0)
                try iconIndex := IL_Add(this.ImageListId,
                    A_WinDir . "\System32\shell32.dll", 10)
        } else {
            iconFile := item.kind == "explorer" ? A_WinDir . "\explorer.exe" : item.path
            if (iconFile != "" && FileExist(iconFile))
                try iconIndex := IL_Add(this.ImageListId, iconFile)
        }
        if (iconIndex == 0) {
            fallbackKey := "fallback"
            if this.IconIndexes.Has(fallbackKey)
                iconIndex := this.IconIndexes[fallbackKey]
            else {
                try iconIndex := IL_Add(this.ImageListId, A_WinDir . "\System32\shell32.dll", 1)
                this.IconIndexes[fallbackKey] := iconIndex
            }
        }
        this.IconIndexes[key] := iconIndex
        return iconIndex
    }

    ; OS標準のストックアイコンをImageListへ追加し、1始まりのインデックスを返す。
    ; 失敗時は0。取得したHICONはImageList側へコピーされるため破棄してよい。
    static _AddStockIcon(stockIconId) {
        ; SHSTOCKICONINFO: cbSize, hIcon, iSysImageIndex, iIcon, szPath[260]
        info := Buffer(A_PtrSize == 8 ? 544 : 536, 0)
        NumPut("uint", info.Size, info, 0)
        hr := DllCall("shell32\SHGetStockIconInfo", "uint", stockIconId,
            "uint", this.SHGSI_ICON_SMALL, "ptr", info, "uint")
        if (hr != 0)
            return 0
        hIcon := NumGet(info, A_PtrSize == 8 ? 8 : 4, "ptr")
        if !hIcon
            return 0
        iconIndex := DllCall("comctl32\ImageList_ReplaceIcon",
            "ptr", this.ImageListId, "int", -1, "ptr", hIcon, "int") + 1
        DllCall("user32\DestroyIcon", "ptr", hIcon)
        return iconIndex > 0 ? iconIndex : 0
    }


    static ClearAllLayoutSlots() {
        if (this.LayoutSlots.Count == 0) {
            this._SetStatus("解除する配置指定はありません")
            this.FocusSearch()
            return
        }

        selectedHwnd := this._GetSelectedHwnd()
        lv := this.GuiObj["Results"]
        topIndex := SendMessage(this.LVM_GETTOPINDEX, 0, 0, lv)
        this.LayoutSlots.Clear()
        this.ApplyFilter(this.GuiObj["Search"].Value, selectedHwnd, topIndex)
        this._SetStatus("すべての配置指定を解除しました")
        this.FocusSearch()
    }

    static ArrangeOnCurrentMonitors() {
        if !this._GuiExists()
            return
        switcherHwnd := this.GuiObj.Hwnd
        this._suspendAutoCloseUntil := A_TickCount + 800
        result := this._EnumerateExplorerWindows()
        if !result.ok {
            this._SetStatus("Explorer一覧を取得できないため整列を中止しました")
            return
        }

        ; 並べる窓と位置は _ArrangePlan で決める（一覧に出す位置の印と同じ決め方）
        plan := this._ArrangePlan(result.items)
        chosenOnly := false
        currentItems := []
        for item in result.items {
            if !plan.Has(item.hwnd)
                continue
            chosenOnly := chosenOnly || this.LayoutSlots.Has(item.hwnd)
            ; 位置を決めた窓は、最小化していても戻してから並べる（最小化のままでは置けない）
            if item.isMinimized {
                try WinRestore("ahk_id " . item.hwnd)
                loop 25 {
                    if (WinGetMinMax("ahk_id " . item.hwnd) != -1)
                        break
                    Sleep(10)
                }
            }
            currentItems.Push({ hwnd: item.hwnd, layoutSlot: plan[item.hwnd], isMinimized: false })
        }

        targetMonitor := ExplorerLayout.GetMonitorAtCursor()
        arrangedCount := ExplorerLayout.ArrangeOnCurrentMonitors(currentItems,
            (result) => this._OnArrangeVerified(result), targetMonitor)
        if (arrangedCount > 0) {
            ; 並べた窓をほかのアプリの窓より前に出す。並べても最大化した窓などの後ろに隠れたままだと、
            ; 何も起きなかったように見える。SetWindowPos(HWND_TOP) はほかのアプリの窓には効かないので、
            ; 1 枚ずつ前面にしてから Switcher に戻す（左上が一番前になるよう、後ろから順に）
            this._suspendAutoCloseUntil := A_TickCount + 1500
            placed := ExplorerLayout.LastPlacedHwnds
            loop placed.Length
                try WinActivate("ahk_id " . placed[placed.Length - A_Index + 1])
            try WinActivate("ahk_id " . switcherHwnd)
            this._SetStatus(chosenOnly
                ? "位置を決めた " . arrangedCount . " 枚を、マウスのある画面に並べました"
                : "最近使った " . arrangedCount . " 枚を、マウスのある画面に 2×2 で並べました")
        } else
            this._SetStatus("並べるエクスプローラーがありません")

        this._RefocusSwitcherSoon(switcherHwnd)
    }

    /**
     * 整列で並べる窓と位置（hwnd → 1〜4: 左上・右上・左下・右下）。一覧の印（◤ など）と整列の両方がこれを使う
     * - 位置を決めた窓（Ctrl+1〜4）が 1 枚でもあれば、その窓だけを決めた位置に並べる（最小化していても戻して並べる）。
     *   決めたのは「この窓を並べたい」という意思なので、空いた位置にほかの窓を足さない
     * - 1 枚もなければ、最小化していないエクスプローラーを最近使った順に 4 枚まで、左上から入れる
     */
    static _ArrangePlan(items) {
        plan := Map(), used := Map()
        for item in items {
            if (item.kind != "explorer" || !this.LayoutSlots.Has(item.hwnd))
                continue
            slot := this.LayoutSlots[item.hwnd]
            if (slot >= 1 && slot <= 4 && !used.Has(slot))
                plan[item.hwnd] := slot, used[slot] := true
        }
        if (plan.Count > 0)
            return plan

        candidates := []
        for item in items
            if (item.kind == "explorer" && !item.isMinimized)
                candidates.Push(item)
        ; 最近使った順（rank が小さいほど最近）。番号を付けた窓が先に並ぶ一覧の順とは別
        loop candidates.Length - 1 {
            i := A_Index + 1, current := candidates[i], j := i - 1
            while (j >= 1 && candidates[j].rank > current.rank) {
                candidates[j + 1] := candidates[j]
                j--
            }
            candidates[j + 1] := current
        }
        for i, item in candidates {
            if (i > 4)
                break
            plan[item.hwnd] := i
        }
        return plan
    }

    ; 整列の反映確認が終わった時点で呼ばれる。問題があった時だけ上書きする。
    static _OnArrangeVerified(result) {
        if !this._GuiExists()
            return
        if (result.unplaced > 0)
            this._SetStatus(result.unplaced . "個は指定位置に配置できませんでした")
        else if (result.corrected > 0)
            this._SetStatus(result.corrected . "個を再配置で補正しました")
    }

    static CloseDuplicates() {
        selected := this._GetSelectedItem()
        if !selected
            return
        if (selected.kind != "explorer") {
            this._SetStatus("重複終了はExplorerだけが対象です")
            return
        }
        if !selected.isFileSystem {
            this._SetStatus("ホームなどの仮想フォルダーは重複終了の対象外です")
            return
        }

        ; 一覧取得後に別パスへ移動したウィンドウを誤って閉じないよう、
        ; 実行時点のExplorer状態を再取得して選択HWNDの現在パスを基準にする。
        result := this._EnumerateExplorerWindows()
        if !result.ok {
            this._SetStatus("Explorer一覧を取得できないため重複終了を中止しました")
            return
        }
        currentItems := result.items
        keepItem := 0
        for item in currentItems {
            if (item.hwnd == selected.hwnd) {
                keepItem := item
                break
            }
        }
        if !keepItem {
            this.Items := currentItems
            this.ApplyFilter(this.GuiObj["Search"].Value)
            return
        }

        targets := []
        for item in currentItems {
            if (item.hwnd != keepItem.hwnd && StrCompare(item.path, keepItem.path, false) == 0)
                targets.Push(item.hwnd)
        }
        if (targets.Length == 0) {
            this._SetStatus("同じパスの重複Explorerはありません: " . keepItem.path)
            return
        }

        closedCount := 0
        for hwnd in targets {
            if this._IsExplorerWindow(hwnd) {
                try {
                    WinClose("ahk_id " . hwnd)
                    closedCount += 1
                }
            }
        }
        this._SetStatus(closedCount . "個の重複Explorerを閉じました: " . keepItem.path)
        SetTimer(() => this.Refresh(), -250)
    }

    ; 見た目は Navi と同じテーマ（NaviTheme）を使う。画面は「検索欄・整列・⚙」の行と一覧、
    ; ステータスバーだけにし、設定は ⚙ のメニュー、ショートカットの一覧は F1 にまとめる
    static _CreateGui() {
        ; タスクバーと Alt+Tab に出さないため、AHK の窓の持ち物（+Owner）にする。+ToolWindow でも出なくなるが、
        ; タイトルバーにアクセントカラーを付ける設定だと × が赤いまま枠からはみ出して描かれるので使わない
        guiObj := Gui("+AlwaysOnTop +Owner -MaximizeBox -MinimizeBox", "Explorer Switcher")
        guiObj.BackColor := NaviTheme.BG
        guiObj.MarginX := NaviTheme.SP_M
        guiObj.MarginY := NaviTheme.SP_M
        width := this.GUI_W, gap := NaviTheme.SP_S

        NaviTheme.SetFont(guiObj, "body")
        search := guiObj.Add("Edit", "xm ym w" . (width - this.ARRANGE_W - this.GEAR_W - 2 * gap) . " vSearch")
        try DllCall("user32\SendMessageW", "ptr", search.Hwnd, "uint", this.EM_SETCUEBANNER,
            "ptr", 1, "wstr", "名前・パスで検索（空白で区切ると AND）", "ptr")
        search.GetPos(, &sy, , &sh)
        arrange := guiObj.Add("Button", "x+" . gap . " y" . sy . " w" . this.ARRANGE_W . " h" . sh
            . " vArrangeButton", "整列")
        gear := guiObj.Add("Button", "x+" . gap . " y" . sy . " w" . this.GEAR_W . " h" . sh
            . " vSettingsButton")
        NaviTheme.SetIcon(gear, NaviTheme.ICON_SETTINGS)
        NaviTheme.SetFont(guiObj, "body")

        ; 格子は引かず、選択・ホバーはエクスプローラーと同じテーマに任せる（0x10000 = LVS_EX_DOUBLEBUFFER）
        ; 列は名前とパス（タイトル）の 2 つ。最小化・配置・重複は名前の後ろに、その窓にだけ出す
        lv := guiObj.Add("ListView", "xm y" . (sy + sh + gap) . " w" . width
            . " r12 NoSort -Multi +LV0x10000 vResults", ["名前", "パス / タイトル"])
        try DllCall("uxtheme\SetWindowTheme", "ptr", lv.Hwnd, "wstr", "Explorer", "ptr", 0)
        this.ImageListId := IL_Create(16, 16, false)
        this.IconIndexes := Map()
        lv.SetImageList(this.ImageListId)
        lv.ModifyCol(1, this.NAME_COL_W)
        lv.ModifyCol(2, width - this.NAME_COL_W - 21)  ; 21 = 縦のスクロールバーの分
        ; 描画ごとのWM_NOTIFY判定で毎回コントロールを引かないよう控えておく。
        this._resultsHwnd := lv.Hwnd

        ; ステータスバー: 左に件数とメッセージ、右に主な操作だけ（全部は F1）
        lv.GetPos(, &ly, , &lh)
        NaviTheme.SetFont(guiObj, "caption", NaviTheme.TEXT_MUTED)
        guiObj.Add("Text", "xm y" . (ly + lh + gap) . " w" . (width - this.HINTS_W) . " h18 +0x8000 vStatus", "0 件")
        NaviTheme.SetFont(guiObj, "caption", NaviTheme.TEXT_SUBTLE)
        guiObj.Add("Text", "x+0 yp w" . this.HINTS_W . " h18 +0x2 vHints",
            "Enter 切替  ·  右クリック メニュー  ·  F1 ヘルプ")
        NaviTheme.SetFont(guiObj, "body")

        this.GuiObj := guiObj
        search.OnEvent("Change", (ctrl, *) => this._OnSearchChanged(ctrl.Value))
        arrange.OnEvent("Click", (*) => this.ArrangeOnCurrentMonitors())
        gear.OnEvent("Click", (*) => this._ShowSettingsMenu())
        lv.OnEvent("Click", (ctrl, row) => this._HandleListClick(ctrl, row))
        lv.OnEvent("DoubleClick", (ctrl, row) => this._HandleListDoubleClick(ctrl, row))
        lv.OnEvent("ContextMenu",
            (ctrl, row, rightClick, x, y) => this._ShowRowContextMenu(row, x, y))
        guiObj.OnEvent("Close", (*) => this.Hide())
        guiObj.OnEvent("Escape", (*) => this.HandleEscape())
    }

    /**
     * ⚙ のメニュー: 一度決めたら触らない設定をまとめる（チェックが今の状態）
     * ⚙ の真下に右端をそろえて出す。位置は画面の物理ピクセルで渡す（GetPos は DPI 換算の単位）
     */
    static _ShowSettingsMenu() {
        if !this._GuiExists()
            return
        m := Menu()
        actions := []  ; メニューの並び順（区切り線は 0）
        for spec in [
            ["外側をクリックしたら閉じる", this.CloseOnFocusLoss, () => this.SetCloseOnFocusLoss(!this.CloseOnFocusLoss)],
            ["切り替えたあとも開いたままにする", this.KeepOpenAfterActivate,
                () => this.SetKeepOpenAfterActivate(!this.KeepOpenAfterActivate)],
            ["エクスプローラー以外のウィンドウも一覧に出す", this.IncludeApps, () => this.SetIncludeApps(!this.IncludeApps)],
            ["番号を付けた窓へ数字キーだけで切り替える（Enter 不要）", this.NumberJumpsImmediately,
                () => this.SetNumberJumpsImmediately(!this.NumberJumpsImmediately)],
            ["中クリックで開く", this.MiddleClickOpens, () => this.SetMiddleClickOpens(!this.MiddleClickOpens)]] {
            m.Add(spec[1], (*) => 0)
            actions.Push(spec[3])
            if spec[2]
                m.Check(spec[1])
        }
        m.Add(), actions.Push(0)
        m.Add("ショートカット一覧`tF1", (*) => 0), actions.Push(() => this.ShowHelp())
        rect := Buffer(16, 0)
        DllCall("user32\GetWindowRect", "ptr", this.GuiObj["SettingsButton"].Hwnd, "ptr", rect)
        ; メニューを出すとSwitcherからフォーカスが外れるので、その間は外側クリックで閉じない（_ShowGuardedMenu と同じ）
        this._suspendAutoCloseUntil := A_TickCount + 60000
        this._StopRefreshTimer()
        ; Menu.Show は右端そろえができないので TrackPopupMenuEx を使う
        ; 選んだ項目は返してもらい、Switcher に戻してから実行する。AHK に実行させると、Switcher に戻すより先に
        ; 走ることがあり、開いたショートカット一覧がフォーカスを取られてすぐ閉じる
        DllCall("user32\SetForegroundWindow", "ptr", A_ScriptHwnd)
        cmd := DllCall("user32\TrackPopupMenuEx", "ptr", m.Handle, "uint", 0x188  ; TPM_RIGHTALIGN | TPM_NONOTIFY | TPM_RETURNCMD
            , "int", NumGet(rect, 8, "int"), "int", NumGet(rect, 12, "int"), "ptr", A_ScriptHwnd, "ptr", 0, "uint")
        DllCall("user32\PostMessageW", "ptr", A_ScriptHwnd, "uint", 0, "ptr", 0, "ptr", 0)  ; WM_NULL
        this._StartRefreshTimer()
        this._suspendAutoCloseUntil := A_TickCount + 200
        try WinActivate("ahk_id " . this.GuiObj.Hwnd)
        this.FocusSearch()
        if cmd
            for i, action in actions
                if (action && DllCall("user32\GetMenuItemID", "ptr", m.Handle, "int", i - 1, "uint") == cmd) {
                    action()
                    break
                }
    }

    static _OnMouseMove(hwnd, lParam := 0) {
        if !this._GuiExists()
            return
        ; 一覧の上: マウスが乗っている行に、最小化（元に戻す）のボタンを出す
        if (hwnd == this._resultsHwnd) {
            x := lParam & 0xFFFF, y := (lParam >> 16) & 0xFFFF
            row := this._RowAtPoint(x, y)
            this._SetHotRow(row, row && this._PointInRowButton(row, x, y))
        } else if this._hotRow {
            this._SetHotRow(0, false)
        }
        if (hwnd == this._tipFor)
            return
        for name, text in this.BUTTON_TIPS {
            if (hwnd == this.GuiObj[name].Hwnd) {
                this._tipFor := hwnd
                ToolTip(text, , , 5)
                SetTimer(this._tipTimerFn, 200)
                return
            }
        }
        this._HideButtonTip()
    }

    ; マウスがボタンから外れたら消す（窓の外へ出たときは WM_MOUSEMOVE が来ないので、タイマーで見る）
    static _HideButtonTipWhenLeft() {
        MouseGetPos(, , , &under, 2)
        if (under != this._tipFor)
            this._HideButtonTip()
    }

    static _HideButtonTip() {
        if !this._tipFor
            return
        ToolTip(, , , 5)
        this._tipFor := 0
        SetTimer(this._tipTimerFn, 0)
    }

    /** ショートカットの一覧（F1）。Navi の F1 と同じ表に出す */
    static ShowHelp() {
        if !this._GuiExists()
            return
        ; 一覧は別の窓なので、開いている間はフォーカスが外れても閉じない（Switcher に戻ると元に戻る）
        this._ignoreFocusLossUntilReactivated := true
        NaviHelp.Show(this.GuiObj, this.HELP_SECTIONS, "Explorer Switcher のショートカット")
    }

    static _OnSearchChanged(query) {
        this._lastTypeTick := A_TickCount
        this._preselectPending := false
        ; 検索欄が空のところに番号の数字を 1 つ打ったら、すぐその窓へ（設定が ON のとき。番号のない数字は検索の文字）
        if (this.NumberJumpsImmediately && RegExMatch(query, "^[1-9]$") && this._GetFavoriteHwnd(Integer(query))) {
            this.GuiObj["Search"].Value := ""
            this.ApplyFilter("")
            this.HandleFavoriteDigit(Integer(query))
            return
        }
        this.ApplyFilter(query)
    }

    ; ==============================================================================
    ; 行の最小化ボタン（マウスを乗せた行だけ、名前の列の右端に出す。VS Code の開いているエディターの × と同じ）
    ; ==============================================================================

    ; 一覧の中の位置（物理ピクセル）にある行（1 始まり。なければ 0）
    static _RowAtPoint(x, y) {
        info := Buffer(24, 0)
        NumPut("int", x, info, 0), NumPut("int", y, info, 4)
        index := DllCall("user32\SendMessageW", "ptr", this._resultsHwnd, "uint", 0x1012, "ptr", 0, "ptr", info, "int")  ; LVM_HITTEST
        return (index >= 0 && index < this.FilteredItems.Length) ? index + 1 : 0
    }

    ; 行のボタンの範囲（名前の列の右端の正方形）。窓の右端だと、名前を見てからボタンまで手が遠いので、
    ; 名前のすぐ右（2 つの列の境目）に出す
    static _RowButtonRect(row) {
        rect := Buffer(16, 0)
        NumPut("int", 1, rect, 4), NumPut("int", 0, rect, 0)  ; top = 列 2（パス）, left = LVIR_BOUNDS
        if !DllCall("user32\SendMessageW", "ptr", this._resultsHwnd, "uint", 0x1038, "ptr", row - 1, "ptr", rect)  ; LVM_GETSUBITEMRECT
            return 0
        ; 行の内側に収める（行の高さいっぱいだと、選択行の枠からはみ出して見える）
        inset := Round(3 * A_ScreenDPI / 96)
        top := NumGet(rect, 4, "int") + inset, bottom := NumGet(rect, 12, "int") - inset
        right := NumGet(rect, 0, "int") - inset * 2  ; パスの列の左端 = 名前の列の右端
        size := bottom - top
        return { left: right - size, top: top, right: right, bottom: bottom }
    }

    static _PointInRowButton(row, x, y) {
        b := this._RowButtonRect(row)
        return b && x >= b.left && x < b.right && y >= b.top && y < b.bottom
    }

    ; マウスが乗っている行と、ボタンの上かを覚え、変わった行だけ描き直す
    static _SetHotRow(row, onButton) {
        if (row == this._hotRow && onButton == this._hotOnButton)
            return
        old := this._hotRow
        this._hotRow := row, this._hotOnButton := onButton
        for r in [old, row]
            if (r >= 1)
                DllCall("user32\SendMessageW", "ptr", this._resultsHwnd, "uint", 0x1015, "ptr", r - 1, "ptr", r - 1)  ; LVM_REDRAWITEMS
        ; 一覧の外へ出たときは WM_MOUSEMOVE が来ないので、タイマーで見て消す
        SetTimer(this._hotTimerFn, row ? 100 : 0)
    }

    static _ClearHotRowWhenLeft() {
        MouseGetPos(, , , &under, 2)
        if (!this._GuiExists() || under != this._resultsHwnd)
            this._SetHotRow(0, false)
    }

    ; クリックがその行のボタンの上か（マウスの位置で見る）
    static _ClickedRowButton(row) {
        if !row
            return false
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        pt := Buffer(8, 0)
        NumPut("int", mx, pt, 0), NumPut("int", my, pt, 4)
        DllCall("user32\ScreenToClient", "ptr", this._resultsHwnd, "ptr", pt)
        return this._PointInRowButton(row, NumGet(pt, 0, "int"), NumGet(pt, 4, "int"))
    }

    ; 行のボタンを描く（最小化していれば「元に戻す」の絵柄）。乗せている間は下地を付けて押せると分かるように
    static _DrawRowButton(hdc, row) {
        b := this._RowButtonRect(row)
        if !b
            return
        rect := Buffer(16, 0)
        NumPut("int", b.left, rect, 0), NumPut("int", b.top, rect, 4), NumPut("int", b.right, rect, 8), NumPut("int", b.bottom, rect, 12)
        if this._hotOnButton {
            ; 角を丸めた下地（Windows 11 のボタンと同じ）。枠線は引かない
            brush := DllCall("gdi32\CreateSolidBrush", "uint", NaviTheme.BGR(NaviTheme.HOVER), "ptr")
            oldBrush := DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", brush, "ptr")
            oldPen := DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", DllCall("gdi32\GetStockObject", "int", 8, "ptr"), "ptr")  ; NULL_PEN
            radius := Round(4 * A_ScreenDPI / 96)
            DllCall("gdi32\RoundRect", "ptr", hdc, "int", b.left, "int", b.top, "int", b.right + 1, "int", b.bottom + 1
                , "int", radius, "int", radius)
            DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldPen)
            DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldBrush)
            DllCall("gdi32\DeleteObject", "ptr", brush)
        }
        if !this._iconFontHandle
            this._iconFontHandle := DllCall("gdi32\CreateFontW", "int", -Round(10 * A_ScreenDPI / 72), "int", 0, "int", 0, "int", 0
                , "int", 400, "uint", 0, "uint", 0, "uint", 0, "uint", 1, "uint", 0, "uint", 0, "uint", 5, "uint", 0
                , "str", NaviTheme.IconFont(), "ptr")
        old := DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", this._iconFontHandle, "ptr")
        DllCall("gdi32\SetTextColor", "ptr", hdc, "uint", NaviTheme.BGR(this._hotOnButton ? NaviTheme.TEXT : NaviTheme.TEXT_MUTED))
        glyph := this.FilteredItems[row].isMinimized ? Chr(0xE923) : Chr(0xE921)  ; ChromeRestore / ChromeMinimize
        DllCall("user32\DrawTextW", "ptr", hdc, "wstr", glyph, "int", -1, "ptr", rect, "uint", 0x1 | 0x4 | 0x20 | 0x800)  ; CENTER | VCENTER | SINGLELINE | NOPREFIX
        DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", old)
    }

    static _HandleListClick(lv, row) {
        if this._ClickedRowButton(row) {
            this.ToggleRowVisibility(row)
            return
        }
        this.FocusSearch()
    }

    static _HandleListDoubleClick(lv, row) {
        if this._ClickedRowButton(row)  ; ボタンのダブルクリックでは切り替えない
            return
        if row
            this.ActivateSelected()
    }

    static _StartNotifyHook() {
        if this._notifyHooked
            return
        OnMessage(this.WM_NOTIFY, this._notifyFn)
        this._notifyHooked := true
    }

    static _StopNotifyHook() {
        if !this._notifyHooked
            return
        OnMessage(this.WM_NOTIFY, this._notifyFn, 0)
        this._notifyHooked := false
    }

    /**
     * 一覧の描画（NM_CUSTOMDRAW）。背景・選択色・アイコンは既定で描かせ、文字は列ごとの後処理で自前で描く
     * 検索欄で打っている間の選択行は、Navi と同じ薄い青にする（テーマのままだとほぼ見えない灰色）
     */
    static _OnNotify(wParam, lParam, msg, hwnd) {
        ; 描画ごとに呼ばれる高頻度パス。まず自分のListView宛てかだけを見て、
        ; 他GUIからの通知は最小コストで抜ける。
        if !lParam
            return
        if (NumGet(lParam, 0, "ptr") != this._resultsHwnd)
            return
        if (NumGet(lParam, A_PtrSize * 2, "int") != this.NM_CUSTOMDRAW)
            return
        x64 := (A_PtrSize == 8)
        stage := NumGet(lParam, x64 ? 24 : 12, "uint")
        if (stage == 0x1)           ; CDDS_PREPAINT
            return 0x20             ; CDRF_NOTIFYITEMDRAW
        if (stage == 0x10001) {     ; CDDS_ITEMPREPAINT: 列ごとの通知を頼む
            NaviTheme.PaintSoftSelection(lParam, this._resultsHwnd)
            return 0x22             ; CDRF_NOTIFYSUBITEMDRAW | CDRF_NEWFONT
        }
        if (stage == 0x30001) {     ; CDDS_SUBITEM | CDDS_ITEMPREPAINT
            NaviTheme.PaintSoftSelection(lParam, this._resultsHwnd)
            return 0x12             ; CDRF_NOTIFYPOSTPAINT | CDRF_NEWFONT
        }
        if (stage == 0x30002)       ; CDDS_SUBITEM | CDDS_ITEMPOSTPAINT
            this._DrawCell(lParam)
        return 0
    }

    /**
     * 1 つのセルの文字を描く（位置は既定の描き方と同じ: 名前の列はラベルの枠の左端から SM_CXEDGE、
     * パスの列はセルの左端から 6px）。一致した文字は ACCENT、パスは親を薄く、名前を濃く描き、
     * 入りきらないときは親の頭を … にして名前を残す（NaviDirList と同じ描き方を使う）
     */
    static _DrawCell(l) {
        x64 := (A_PtrSize == 8)
        row := NumGet(l, x64 ? 56 : 36, "uptr") + 1
        subItem := NumGet(l, x64 ? 88 : 56, "int")
        if (row < 1 || row > this._rowViews.Length)
            return
        view := this._rowViews[row]
        lv := this._resultsHwnd
        rect := Buffer(16, 0)
        if (subItem == 0) {
            NumPut("int", 2, rect, 0)  ; LVIR_LABEL
            if !DllCall("user32\SendMessageW", "ptr", lv, "uint", 0x100E, "ptr", row - 1, "ptr", rect)  ; LVM_GETITEMRECT
                return
            pad := SysGet(45)  ; SM_CXEDGE
        } else {
            NumPut("int", subItem, rect, 4), NumPut("int", 2, rect, 0)  ; top = 列, left = LVIR_LABEL
            if !DllCall("user32\SendMessageW", "ptr", lv, "uint", 0x1038, "ptr", row - 1, "ptr", rect)  ; LVM_GETSUBITEMRECT
                return
            pad := Round(6 * A_ScreenDPI / 96)
        }
        hdc := NumGet(l, x64 ? 32 : 16, "ptr")
        left := NumGet(rect, 0, "int") + pad, right := NumGet(rect, 8, "int") - pad
        top := NumGet(rect, 4, "int"), bottom := NumGet(rect, 12, "int")
        oldFont := DllCall("gdi32\SelectObject", "ptr", hdc,
            "ptr", DllCall("user32\SendMessageW", "ptr", lv, "uint", 0x0031, "ptr", 0, "ptr", 0, "ptr"), "ptr")  ; WM_GETFONT
        DllCall("gdi32\SetBkMode", "ptr", hdc, "int", 1)  ; TRANSPARENT
        if (subItem == 0 && row == this._hotRow) {
            ; マウスが乗っている行は、名前の列の右端にボタンを描き、名前はその手前まで
            this._DrawRowButton(hdc, row)
            b := this._RowButtonRect(row)
            if b
                right := Min(right, b.left - pad)
        }
        if (subItem == 0) {
            x := NaviDirList._DrawRuns(hdc, left, right, top, bottom, view.name, view.color, view.nameHl)
            for t in view.tails
                x := NaviDirList._DrawRuns(hdc, x, right, top, bottom, t.s, t.color, Map())
        } else if (view.dir != "")
            NaviDirList._DrawPath(hdc, left, right, top, bottom, view.dir, view.leaf, view.pathHl)
        else
            NaviDirList._DrawRuns(hdc, left, right, top, bottom, view.text,
                view.color == NaviTheme.TEXT ? NaviTheme.TEXT_MUTED : view.color, view.hl)
        DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldFont)
    }

    ; 列挙結果は {ok, items} で返す。COM列挙は時間がかかることがあり、その最中に
    ; タイマーやホットキーが割り込むため、成否をstaticフラグで持つと取り違える。
    static _EnumerateVisibleItems() {
        result := this._EnumerateExplorerWindows()
        if !result.ok
            return result

        items := result.items
        if this.IncludeApps
            this._AppendApplicationWindows(items)
        this._PruneWindowState(items)
        for item in items
            item.isPinned := this.PinnedHwnds.Has(item.hwnd)
        this._ApplyOrderLock(items)
        this._SortItems(items)
        return {ok: true, items: items}
    }

    ; rankはZ順そのものなので、最小化・復元・切替のたびに全ウィンドウの値が動く。
    ; そのまま並べ替えると、クリックした直後に行が入れ替わって「触っていない行の
    ; 状態が変わった」ように見え、次のクリックも別の行に当たる。
    ; 表示中は開いた時点の並びを固定し、新しいウィンドウは末尾に足す。
    static _ApplyOrderLock(items) {
        if !(this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd)) {
            this._orderLock.Clear()
            this._orderLockNext := 0
            return
        }

        unknown := []
        for item in items {
            if !this._orderLock.Has(item.hwnd)
                unknown.Push(item)
        }
        if unknown.Length {
            ; 初回（開いた直後）はここで全件が確定するため、現在のZ順を尊重する。
            this._SortItems(unknown)
            for item in unknown {
                this._orderLockNext += 1
                this._orderLock[item.hwnd] := this._orderLockNext
            }
        }
        for item in items
            item.rank := this._orderLock[item.hwnd]
    }

    static _EnumerateExplorerWindows() {
        items := []
        seenHwnds := Map()
        zRanks := Map()

        try {
            for rank, hwnd in WinGetList()
                zRanks[hwnd] := rank
        }

        try shellWindows := ComObject("Shell.Application").Windows
        catch
            return {ok: false, items: items}

        ; LocationNameとDocument.Folder.Self.Pathはexplorer.exeへのプロセス跨ぎ呼び出しで、
        ; 実測ではこの列挙の約8割を占める。Explorerのタイトルは現在のフォルダー名を
        ; 反映するため、タイトルが変わらない限り前回の結果を使い回す。
        ; ただし同名の別フォルダーへ移動するとタイトルが変わらないので、
        ; FULL_QUERY_EVERY回に1回はキャッシュを捨ててCOMから取り直す。
        useCache := this._fullQueryCountdown > 0
        this._fullQueryCountdown := useCache
            ? this._fullQueryCountdown - 1
            : this.FULL_QUERY_EVERY

        for window in shellWindows {
            try {
                hwnd := window.HWND + 0
                if (!this._IsExplorerWindow(hwnd) || seenHwnds.Has(hwnd))
                    continue

                seenHwnds[hwnd] := true
                title := WinGetTitle("ahk_id " . hwnd)
                cached := useCache && this._pathCache.Has(hwnd) ? this._pathCache[hwnd] : 0
                if (cached && cached.title == title) {
                    path := cached.path
                    displayName := cached.displayName
                    isFileSystem := cached.isFileSystem
                    isNetwork := cached.isNetwork
                } else {
                    try locationName := Trim(window.LocationName)
                    catch
                        locationName := ""
                    try path := window.Document.Folder.Self.Path
                    catch
                        path := ""

                    isFileSystem := this._IsFileSystemPath(path)
                    if isFileSystem {
                        path := this._NormalizePath(path)
                        SplitPath(path, &displayName)
                        if (displayName == "")
                            displayName := path
                    } else {
                        ; ホーム、PC、ごみ箱なども実在するExplorerウィンドウとして残す。
                        ; これらは通常パスを持たないため、COMの表示名を検索・詳細表示に使う。
                        displayName := locationName != "" ? locationName : this._ExplorerNameFromTitle(title)
                        if (displayName == "")
                            displayName := "Explorer"
                        path := locationName != "" ? locationName : displayName
                    }
                    isNetwork := isFileSystem && this._IsNetworkPath(path)
                    this._pathCache[hwnd] := {title: title, path: path,
                        displayName: displayName, isFileSystem: isFileSystem,
                        isNetwork: isNetwork}
                }

                rank := zRanks.Has(hwnd) ? zRanks[hwnd] : 100000 + items.Length
                items.Push({
                    hwnd: hwnd,
                    kind: "explorer",
                    title: title,
                    path: path,
                    ; ルール変更を即反映させるため、キャッシュに入れず毎回引き直す。
                    label: isFileSystem ? this._GetPathLabel(path) : "",
                    displayName: displayName,
                    isFileSystem: isFileSystem,
                    isNetwork: isNetwork,
                    isMinimized: WinGetMinMax("ahk_id " . hwnd) == -1,
                    isPinned: false,
                    duplicateCount: 1,
                    rank: rank
                })
            }
        }

        pathCounts := Map()
        for item in items {
            if !item.isFileSystem
                continue
            key := StrLower(item.path)
            pathCounts[key] := pathCounts.Has(key) ? pathCounts[key] + 1 : 1
        }
        for item in items {
            if item.isFileSystem
                item.duplicateCount := pathCounts[StrLower(item.path)]
        }

        for item in items
            item.isPinned := this.PinnedHwnds.Has(item.hwnd)

        ; 閉じたExplorer分のキャッシュを溜め込まない。
        this._PruneStaleKeys(this._pathCache, seenHwnds)

        this._SortItems(items)
        return {ok: true, items: items}
    }

    static _AppendApplicationWindows(items) {
        seenHwnds := Map()
        for item in items
            seenHwnds[item.hwnd] := true

        for rank, hwnd in WinGetList() {
            try {
                if (seenHwnds.Has(hwnd)
                    || (this._GuiExists() && hwnd == this.GuiObj.Hwnd)
                    || !DllCall("user32\IsWindowVisible", "ptr", hwnd))
                    continue

                title := Trim(WinGetTitle("ahk_id " . hwnd))
                if (title == "")
                    continue
                cls := WinGetClass("ahk_id " . hwnd)
                if (cls == "Shell_TrayWnd" || cls == "Progman" || cls == "WorkerW")
                    continue

                exStyle := WinGetExStyle("ahk_id " . hwnd)
                isAppWindow := (exStyle & 0x00040000) != 0
                if ((exStyle & 0x00000080) && !isAppWindow)
                    continue
                if (exStyle & 0x08000000)
                    continue
                owner := DllCall("user32\GetWindow", "ptr", hwnd, "uint", 4, "ptr")
                if (owner && !isAppWindow)
                    continue

                cloaked := Buffer(4, 0)
                if (DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd,
                    "uint", 14, "ptr", cloaked, "uint", 4, "int") == 0
                    && NumGet(cloaked, 0, "uint") != 0)
                    continue

                processName := WinGetProcessName("ahk_id " . hwnd)
                if (StrCompare(processName, "explorer.exe", false) == 0)
                    continue
                try exePath := WinGetProcessPath("ahk_id " . hwnd)
                catch
                    exePath := ""
                displayName := this._AppName(processName, exePath, title)

                items.Push({
                    hwnd: hwnd,
                    kind: "app",
                    title: title,
                    path: exePath,
                    label: "",
                    displayName: displayName,
                    isFileSystem: false,
                    isNetwork: false,
                    isMinimized: WinGetMinMax("ahk_id " . hwnd) == -1,
                    isPinned: false,
                    duplicateCount: 1,
                    rank: rank
                })
                seenHwnds[hwnd] := true
            } catch {
                continue
            }
        }
    }

    /**
     * アプリの行の名前。実行ファイル名（chrome、ApplicationFrameHost）では分かりにくいので、
     * ファイルの説明（Google Chrome など）を使う。ストアアプリは ApplicationFrameHost が窓を持つので、タイトル（設定 など）
     */
    static _AppName(processName, exePath, title) {
        static cache := Map()
        if (StrCompare(processName, "ApplicationFrameHost.exe", false) == 0 && title != "")
            return title
        if (exePath != "") {
            if !cache.Has(exePath)
                cache[exePath] := this._FileDescription(exePath)
            if (cache[exePath] != "")
                return cache[exePath]
        }
        name := RegExReplace(processName, "i)\.exe$")
        return (name != "") ? name : title
    }

    ; 実行ファイルのバージョン情報にある「ファイルの説明」（なければ ""）
    static _FileDescription(path) {
        try {
            size := DllCall("version\GetFileVersionInfoSizeW", "str", path, "ptr", 0, "uint")
            if !size
                return ""
            info := Buffer(size, 0)
            if !DllCall("version\GetFileVersionInfoW", "str", path, "uint", 0, "uint", size, "ptr", info)
                return ""
            if !DllCall("version\VerQueryValueW", "ptr", info, "str", "\VarFileInfo\Translation",
                "ptr*", &trans := 0, "uint*", &transLen := 0) || transLen < 4
                return ""
            lang := Format("{:04X}{:04X}", NumGet(trans, 0, "ushort"), NumGet(trans, 2, "ushort"))
            if !DllCall("version\VerQueryValueW", "ptr", info, "str", "\StringFileInfo\" . lang . "\FileDescription",
                "ptr*", &text := 0, "uint*", &textLen := 0) || !textLen
                return ""
            return Trim(StrGet(text, "UTF-16"))
        }
        return ""
    }

    static _SortItems(items) {
        ; AutoHotkey v2標準配列に依存しない、小規模リスト向けの安定挿入ソート。
        loop items.Length - 1 {
            i := A_Index + 1
            current := items[i]
            j := i - 1
            while (j >= 1 && this._ComesAfter(items[j], current)) {
                items[j + 1] := items[j]
                j -= 1
            }
            items[j + 1] := current
        }
    }

    static _ItemsEquivalent(leftItems, rightItems) {
        if (leftItems.Length != rightItems.Length)
            return false

        leftByHwnd := Map()
        for item in leftItems
            leftByHwnd[item.hwnd] := item

        for right in rightItems {
            if !leftByHwnd.Has(right.hwnd)
                return false
            left := leftByHwnd[right.hwnd]
            ; rankも比較する。開いた直後はキャッシュ由来の古いZ順とorder lockの
            ; 新しい順位が食い違うため、ここで「変化あり」となり並び直しが
            ; 描画に反映される。表示中はlockがrankを固定するので毎秒は動かない。
            if (left.kind != right.kind
                || left.rank != right.rank
                || StrCompare(left.path, right.path, false) != 0
                || left.label != right.label
                || left.displayName != right.displayName
                || left.title != right.title
                || left.isPinned != right.isPinned
                || left.isMinimized != right.isMinimized
                || left.duplicateCount != right.duplicateCount)
                return false
        }
        return true
    }

    static _CountMatches(items, query) {
        tokens := this._TokenizeQuery(query)
        count := 0
        for item in items {
            if this._ItemMatchesTokens(item, tokens)
                count += 1
        }
        return count
    }

    static _TokenizeQuery(query) {
        normalized := Trim(StrReplace(query, "　", " "))
        if (normalized == "")
            return []

        tokens := []
        for token in StrSplit(normalized, " ") {
            if (token != "")
                tokens.Push(token)
        }
        return tokens
    }

    static _ItemMatchesTokens(item, tokens) {
        for token in tokens {
            if !(InStr(item.displayName, token, false)
                || (item.label != "" && InStr(item.label, token, false))
                || InStr(item.path, token, false)
                || InStr(item.title, token, false))
                return false
        }
        return true
    }

    static _RestoreListScroll(lv, topIndex) {
        count := lv.GetCount()
        if (count == 0)
            return

        topIndex := Min(Max(topIndex, 0), count - 1)
        perPage := SendMessage(this.LVM_GETCOUNTPERPAGE, 0, 0, lv)
        if (perPage <= 0)
            perPage := 1

        ; 先に旧ビューポートの末尾を可視化してから先頭を可視化すると、
        ; topIndexが可能な範囲で再びリスト上端に配置される。
        bottomIndex := Min(count - 1, topIndex + perPage - 1)
        SendMessage(this.LVM_ENSUREVISIBLE, bottomIndex, 0, lv)
        SendMessage(this.LVM_ENSUREVISIBLE, topIndex, 0, lv)
    }

    static _ComesAfter(left, right) {
        if (left.isPinned != right.isPinned)
            return !left.isPinned && right.isPinned
        if (left.rank != right.rank)
            return left.rank > right.rank
        return StrCompare(left.displayName, right.displayName, false) > 0
    }

    ; HWNDはOSが再利用するため、閉じたウィンドウ由来の指定を残すと無関係な
    ; ウィンドウが番号や配置指定を引き継いでしまう。列挙のたびに掃除する。
    static _PruneWindowState(items) {
        existingHwnds := Map()
        for item in items
            existingHwnds[item.hwnd] := true

        this._PruneStaleKeys(this.PinnedHwnds, existingHwnds)
        this._PruneStaleKeys(this.FavoriteNumbers, existingHwnds)
        this._PruneStaleKeys(this.LayoutSlots, existingHwnds)
    }

    static _PruneStaleKeys(target, existingHwnds) {
        staleHwnds := []
        for hwnd in target {
            if !existingHwnds.Has(hwnd)
                staleHwnds.Push(hwnd)
        }
        for hwnd in staleHwnds
            target.Delete(hwnd)
    }

    static _NormalizePath(path) {
        while (StrLen(path) > 3 && SubStr(path, -1) == "\")
            path := SubStr(path, 1, -1)
        return path
    }

    static _ExplorerNameFromTitle(title) {
        ; OSの表示言語に依存する末尾は決め打ちせず、一般的なExplorerの区切りだけ除く。
        name := RegExReplace(Trim(title), "i)\s+-\s+(エクスプローラー|File Explorer)$")
        return Trim(name)
    }

    static _IsFileSystemPath(path) {
        if (path == "")
            return false
        ; DirExistは切断中のネットワークパスで待たされるため、Explorerが返した
        ; ドライブパスまたはUNC/拡張パスであることだけを軽量に確認する。
        return RegExMatch(path, "i)^[A-Z]:\\") || SubStr(path, 1, 2) == "\\"
    }

    static _IsNetworkPath(path) {
        if (SubStr(path, 1, 2) == "\\")
            return true
        ; GetDriveTypeはマウント情報の参照だけで、切断中のネットワークドライブ
        ; でもブロックしないため、列挙のたびに直接呼んでよい。
        if RegExMatch(path, "i)^[A-Z]:\\")
            return DllCall("kernel32\GetDriveTypeW", "wstr", SubStr(path, 1, 3),
                "uint") == this.DRIVE_REMOTE
        return false
    }

    static _IsExplorerWindow(hwnd) {
        if !hwnd || !WinExist("ahk_id " . hwnd)
            return false
        try cls := WinGetClass("ahk_id " . hwnd)
        catch
            return false
        return cls == "CabinetWClass" || cls == "ExploreWClass"
    }

    static _IsItemWindowValid(item) {
        if !item || !item.hwnd || !DllCall("user32\IsWindow", "ptr", item.hwnd)
            return false
        return item.kind == "explorer" ? this._IsExplorerWindow(item.hwnd) : true
    }

    static _ActivateHwnd(hwnd) {
        if !hwnd || !DllCall("user32\IsWindow", "ptr", hwnd)
            return
        try {
            if WinGetMinMax("ahk_id " . hwnd) == -1
                WinRestore("ahk_id " . hwnd)
            WinActivate("ahk_id " . hwnd)
        }
    }

    static _ActivateKeepingSwitcher(hwnd) {
        ; このWinActivateによるフォーカス喪失では自動で閉じない。Switcherが再び
        ; アクティブになった時点で通常のフォーカス監視へ戻す。
        this._ignoreFocusLossUntilReactivated := true
        this._ActivateHwnd(hwnd)
    }

    ; WinMinimize等の直後はOSが別ウィンドウへフォーカスを渡す場合があるため、
    ; 即時とアニメーション完了後の2段階でSwitcherへ戻す。
    static _RefocusSwitcherSoon(hwnd) {
        this._RefocusSwitcher(hwnd)
        SetTimer(() => this._RefocusSwitcher(hwnd), this.REFOCUS_DELAY)
    }

    static _RefocusSwitcher(hwnd) {
        if !(this._GuiExists() && this.GuiObj.Hwnd == hwnd)
            return
        if !DllCall("user32\IsWindowVisible", "ptr", hwnd)
            return
        try {
            WinActivate("ahk_id " . hwnd)
            this.GuiObj["Search"].Focus()
        }
    }

    static _MoveSelection(delta) {
        if (this.FilteredItems.Length == 0)
            return
        this._preselectPending := false
        lv := this.GuiObj["Results"]
        row := lv.GetNext()
        if (row == 0)
            row := delta > 0 ? 1 : this.FilteredItems.Length
        else {
            lv.Modify(row, "-Select -Focus")
            row += delta
            if (row < 1)
                row := this.FilteredItems.Length
            else if (row > this.FilteredItems.Length)
                row := 1
        }
        lv.Modify(row, "Select Focus Vis")
    }

    static _GetSelectedItem() {
        if !this._GuiExists()
            return 0
        row := this.GuiObj["Results"].GetNext()
        if (row < 1 || row > this.FilteredItems.Length)
            return 0
        return this.FilteredItems[row]
    }

    static _GetSelectedHwnd() {
        item := this._GetSelectedItem()
        return item ? item.hwnd : 0
    }

    static _SelectHwnd(hwnd) {
        if !hwnd || !this._GuiExists()
            return
        lv := this.GuiObj["Results"]
        for row, item in this.FilteredItems {
            if (item.hwnd == hwnd) {
                currentRow := lv.GetNext()
                if currentRow
                    lv.Modify(currentRow, "-Select -Focus")
                lv.Modify(row, "Select Focus Vis")
                return
            }
        }
    }

    static _IsImeComposing() {
        if !this._GuiExists()
            return false
        editHwnd := this.GuiObj["Search"].Hwnd
        hIMC := DllCall("imm32\ImmGetContext", "ptr", editHwnd, "ptr")
        if !hIMC
            return false
        composing := DllCall("imm32\ImmGetCompositionStringW", "ptr", hIMC,
            "uint", 0x0008, "ptr", 0, "ptr", 0) > 0
        DllCall("imm32\ImmReleaseContext", "ptr", editHwnd, "ptr", hIMC)
        return composing
    }

    static _UpdateStatus() {
        this._SetStatus()
    }

    static _SetStatus(message := "") {
        if !this._GuiExists()
            return
        countText := this.FilteredItems.Length . " / " . this.Items.Length . " 件"
        this.GuiObj["Status"].Text := countText . (message != "" ? "    " . message : "")
    }

    static _StartRefreshTimer() {
        this._StopRefreshTimer()
        SetTimer(this._refreshTimerFn, this.REFRESH_INTERVAL)
    }

    static _StopRefreshTimer() {
        if this._refreshTimerFn
            SetTimer(this._refreshTimerFn, 0)
    }

    static _RefreshWhileVisible() {
        if !this._GuiExists() {
            this._StopRefreshTimer()
            return
        }
        if !DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd) {
            this._StopRefreshTimer()
            return
        }
        ; 打鍵の直後は絞り込み描画と重ねない。次のtickで拾えばよい。
        if (A_TickCount - this._lastTypeTick < this.TYPING_QUIET_PERIOD)
            return
        this.Refresh()
    }

    static _StartCacheTimer() {
        SetTimer(this._cacheTimerFn, this.CACHE_REFRESH_INTERVAL)
    }

    static _StopCacheTimer() {
        if this._cacheTimerFn
            SetTimer(this._cacheTimerFn, 0)
    }

    static _RefreshCacheWhileHidden() {
        if (this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd))
            return
        ; しばらく使われていなければ止める。次にShowした時点で改めて取り直す。
        if (A_TickCount - this._lastUseTick > this.CACHE_IDLE_TIMEOUT) {
            this._StopCacheTimer()
            return
        }
        if this._refreshBusy
            return

        this._refreshBusy := true
        try {
            result := this._EnumerateVisibleItems()
            if result.ok
                this.Items := result.items
        } finally {
            this._refreshBusy := false
        }
    }

    static _StartFocusWatch() {
        this._StopFocusWatch()
        if !this.CloseOnFocusLoss
            return
        this._focusWatchBorn := A_TickCount
        this._focusEverActive := WinActive("ahk_id " . this.GuiObj.Hwnd) != 0
        SetTimer(this._focusWatchTimerFn, this.FOCUS_WATCH_INTERVAL)
    }

    static _StopFocusWatch() {
        if this._focusWatchTimerFn
            SetTimer(this._focusWatchTimerFn, 0)
        this._focusEverActive := false
    }

    static _FocusWatchTick() {
        if !this.CloseOnFocusLoss {
            this._StopFocusWatch()
            return
        }
        if !(this._GuiExists()
            && DllCall("user32\IsWindowVisible", "ptr", this.GuiObj.Hwnd)) {
            this._StopFocusWatch()
            return
        }
        if WinActive("ahk_id " . this.GuiObj.Hwnd) {
            this._focusEverActive := true
            this._ignoreFocusLossUntilReactivated := false
            return
        }
        if this._ignoreFocusLossUntilReactivated
            return
        if (A_TickCount < this._suspendAutoCloseUntil)
            return

        ; 表示直後にまだ一度もフォーカスを得ていない場合だけ、OSの初期フォーカス
        ; 競合として短時間リトライする。一度アクティブになった後の喪失は外側クリック。
        if (!this._focusEverActive && A_TickCount - this._focusWatchBorn < 500) {
            try WinActivate("ahk_id " . this.GuiObj.Hwnd)
            return
        }
        this.Hide()
    }
}
