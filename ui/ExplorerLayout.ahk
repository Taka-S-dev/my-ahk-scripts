; ==============================================================================
; Module:       ExplorerLayout.ahk
; Description:  Explorerを各モニター最大4枚の2x2へ一括整列
; ==============================================================================
#Requires AutoHotkey v2.0

class ExplorerLayout {
    static LastSkippedCount := 0
    static LastPlacedHwnds := []
    static LastCorrectedCount := 0
    static LastUnplacedCount := 0
    static MAX_WINDOWS := 4
    static INNER_GAP := 4
    ; Z順とフォーカスを維持したまま位置とサイズだけを変える。
    static SWP_FLAGS := 0x0004 | 0x0010 | 0x0200  ; NOZORDER | NOACTIVATE | NOOWNERZORDER
    ; 最大化解除の完了を待つ上限。応答しないExplorerで固まらないよう必ず打ち切る。
    static RESTORE_WAIT_LIMIT := 250
    static RESTORE_WAIT_STEP := 10
    ; 配置がウィンドウ側に受け入れられたかを確認するまでの待ち。
    static VERIFY_DELAY := -120
    ; DPI丸めで数ピクセルずれることがあるため、この範囲は一致とみなす。
    static RECT_TOLERANCE := 4

    static _pendingPlacements := []
    static _verifyFn := ""
    static _finalizeFn := ""
    static _onVerified := 0

    static ArrangeOnCurrentMonitors(items, onVerified := 0, targetMonitor := 0) {
        dpiContext := this._EnterPhysicalDpiContext()
        try return this._ArrangeOnCurrentMonitorsCore(items, onVerified, targetMonitor)
        finally this._LeaveDpiContext(dpiContext)
    }

    static _ArrangeOnCurrentMonitorsCore(items, onVerified := 0, targetMonitor := 0) {
        this.LastSkippedCount := 0
        this.LastCorrectedCount := 0
        this.LastUnplacedCount := 0
        groups := Map()
        for item in items {
            ; 最小化中のExplorerは現在表示されている作業ウィンドウではないため、
            ; 復元せず整列対象から除外する。
            if (item.HasOwnProp("isMinimized") && item.isMinimized)
                continue
            hwnd := item.hwnd
            if !hwnd || !WinExist("ahk_id " . hwnd)
                continue

            monitor := targetMonitor ? targetMonitor
                : DllCall("user32\MonitorFromWindow", "ptr", hwnd,
                    "uint", 2, "ptr")  ; MONITOR_DEFAULTTONEAREST
            if !monitor
                continue
            if !groups.Has(monitor)
                groups[monitor] := []
            groups[monitor].Push(item)
        }

        placements := []
        for monitor, windows in groups {
            work := this._GetMonitorWorkArea(monitor)
            if !work
                continue

            assigned := Map()
            unassigned := []
            for item in windows {
                slot := item.HasOwnProp("layoutSlot") ? item.layoutSlot : 0
                if (slot >= 1 && slot <= this.MAX_WINDOWS && !assigned.Has(slot))
                    assigned[slot] := item.hwnd
                else
                    unassigned.Push(item.hwnd)
            }

            Loop this.MAX_WINDOWS {
                slot := A_Index
                hwnd := assigned.Has(slot) ? assigned[slot]
                    : (unassigned.Length ? unassigned.RemoveAt(1) : 0)
                if hwnd
                    placements.Push({hwnd: hwnd, rect: this._GetTileRect(work, slot)})
            }
            this.LastSkippedCount += unassigned.Length
        }
        if (placements.Length == 0)
            return 0

        ; 最大化中のウィンドウだけ通常状態へ戻す。通常・Snap済みウィンドウは
        ; DeferWindowPosだけで直接配置できるため、個別の前面化やキー送信は不要。
        ;
        ; SW_RESTOREは位置とサイズの両方をrcNormalPositionから復元する。完了前に
        ; DeferWindowPosを送ると、置いた直後に復元が走って配置が丸ごと巻き戻る。
        ; ShowWindow(同期)は応答しないウィンドウで固まり得るので使わず、
        ; 非同期で投げてから「最大化が解けたか」を上限つきで待つ。
        maximized := []
        for placement in placements {
            try {
                if (WinGetMinMax("ahk_id " . placement.hwnd) == 1) {
                    DllCall("user32\ShowWindowAsync", "ptr", placement.hwnd,
                        "int", 9)  ; SW_RESTORE
                    maximized.Push(placement.hwnd)
                }
            }
        }
        this._WaitUntilRestored(maximized)
        ; Explorer側のアニメーションやSnap状態によって非同期解除が時間切れに
        ; なったものだけ、応答期限つきの同期メッセージで確実に解除する。
        forcedRestore := false
        for hwnd in maximized {
            try {
                if (WinGetMinMax("ahk_id " . hwnd) == 1) {
                    this._RestoreWithTimeout(hwnd)
                    forcedRestore := true
                }
            }
        }
        if forcedRestore
            this._WaitUntilRestored(maximized)

        ; WinGetMinMaxが0でもWindows 11のSnap状態が残ることがある。
        ; SC_RESTOREは通常状態には影響せず、Snap済みなら通常状態へ戻すため、
        ; 全対象へ送ってから一括配置する。
        for placement in placements
            this._RestoreWithTimeout(placement.hwnd)

        ; DWMの見えない外枠を補正し、見えている枠がタイル境界に一致するようにする。
        for placement in placements {
            insets := this._GetFrameInsets(placement.hwnd)
            rect := placement.rect
            placement.x := rect.left - insets.left
            placement.y := rect.top - insets.top
            placement.w := rect.w + insets.left + insets.right
            placement.h := rect.h + insets.top + insets.bottom
        }

        hdwp := DllCall("user32\BeginDeferWindowPos", "int", placements.Length, "ptr")
        if !hdwp
            return 0

        ; 全ウィンドウを1トランザクションへ登録。
        for placement in placements {
            hdwp := DllCall("user32\DeferWindowPos",
                "ptr", hdwp, "ptr", placement.hwnd, "ptr", 0,
                "int", placement.x, "int", placement.y,
                "int", placement.w, "int", placement.h,
                "uint", this.SWP_FLAGS, "ptr")
            ; Microsoftの仕様どおり、途中失敗時はEndDeferWindowPosを呼ばない。
            if !hdwp
                return 0
        }

        if !DllCall("user32\EndDeferWindowPos", "ptr", hdwp, "int")
            return 0

        ; 並べた窓（左上 → 右下の順）。呼び出し側がほかのアプリの窓より前に出すのに使う
        this.LastPlacedHwnds := []
        for placement in placements
            this.LastPlacedHwnds.Push(placement.hwnd)

        ; 配置が本当に効いたかは、ウィンドウ側が落ち着くまで分からない。
        ; メインスレッドを止めないよう、確認はタイマーで後追いする。
        this._pendingPlacements := placements
        this._onVerified := onVerified
        if !this._verifyFn
            this._verifyFn := () => this._VerifyPlacements()
        SetTimer(this._verifyFn, this.VERIFY_DELAY)
        return placements.Length
    }

    ; 最大化解除の完了を上限つきで待つ。時間切れでも必ず戻る。
    static _WaitUntilRestored(hwnds) {
        if (hwnds.Length == 0)
            return
        waited := 0
        while (waited < this.RESTORE_WAIT_LIMIT) {
            pending := false
            for hwnd in hwnds {
                try {
                    if (WinGetMinMax("ahk_id " . hwnd) == 1) {
                        pending := true
                        break
                    }
                }
            }
            if !pending
                return
            Sleep(this.RESTORE_WAIT_STEP)
            waited += this.RESTORE_WAIT_STEP
        }
    }

    ; 目標矩形と食い違うウィンドウへ「1回だけ」再適用する。
    ; 繰り返すとウィンドウ側の制約と押し合いになるため、ループはしない。
    static _VerifyPlacements() {
        dpiContext := this._EnterPhysicalDpiContext()
        notifyNow := false
        try notifyNow := this._VerifyPlacementsCore()
        finally this._LeaveDpiContext(dpiContext)
        if notifyNow
            this._NotifyVerified()
    }

    static _VerifyPlacementsCore() {
        placements := this._pendingPlacements
        this._pendingPlacements := []
        corrected := 0
        for placement in placements {
            if !this._NeedsCorrection(placement)
                continue
            try {
                if (WinGetMinMax("ahk_id " . placement.hwnd) == 1) {
                    this._RestoreWithTimeout(placement.hwnd)
                    this._WaitUntilRestored([placement.hwnd])
                } else
                    ; 最大化扱いではないSnap状態も解除する。
                    this._RestoreWithTimeout(placement.hwnd)
            }
            ; 目標は保存値ではなく今の枠幅で計算し直す。最大化中に測った枠は
            ; 復元後より太く、そのまま再適用すると数px〜10pxずれたままになる。
            target := this._TargetFor(placement)
            try DllCall("user32\SetWindowPos", "ptr", placement.hwnd, "ptr", 0,
                "int", target.x, "int", target.y,
                "int", target.w, "int", target.h,
                "uint", this.SWP_FLAGS)
            corrected += 1
        }
        this.LastCorrectedCount := corrected

        if (corrected == 0) {
            this.LastUnplacedCount := 0
            return true
        }

        ; 再適用の結果も確認する。ここで直らなければ諦めて件数を報告する。
        this._pendingPlacements := placements
        if !this._finalizeFn
            this._finalizeFn := () => this._FinalizeVerify()
        SetTimer(this._finalizeFn, this.VERIFY_DELAY)
        return false
    }

    static _FinalizeVerify() {
        dpiContext := this._EnterPhysicalDpiContext()
        try this._FinalizeVerifyCore()
        finally this._LeaveDpiContext(dpiContext)
        this._NotifyVerified()
    }

    static _FinalizeVerifyCore() {
        placements := this._pendingPlacements
        this._pendingPlacements := []
        unplaced := 0
        for placement in placements {
            if this._NeedsCorrection(placement)
                unplaced += 1
        }
        this.LastUnplacedCount := unplaced
    }

    static _NotifyVerified() {
        callback := this._onVerified
        this._onVerified := 0
        if callback {
            try callback({corrected: this.LastCorrectedCount,
                unplaced: this.LastUnplacedCount})
        }
    }

    ; SendMessageで無期限に待たず、応答しないウィンドウは250msで打ち切る。
    static _RestoreWithTimeout(hwnd) {
        result := 0
        return DllCall("user32\SendMessageTimeoutW",
            "ptr", hwnd,
            "uint", 0x0112,       ; WM_SYSCOMMAND
            "ptr", 0xF120,        ; SC_RESTORE
            "ptr", 0,
            "uint", 0x0002,       ; SMTO_ABORTIFHUNG
            "uint", this.RESTORE_WAIT_LIMIT,
            "uptr*", &result,
            "ptr") != 0
    }

    ; タイル座標に現在の枠幅を足して、今この瞬間の目標矩形を出す。
    static _TargetFor(placement) {
        insets := this._GetFrameInsets(placement.hwnd)
        rect := placement.rect
        return {
            x: rect.left - insets.left,
            y: rect.top - insets.top,
            w: rect.w + insets.left + insets.right,
            h: rect.h + insets.top + insets.bottom
        }
    }

    ; 位置とサイズの両方を見る。SW_RESTOREは両方を巻き戻すため、
    ; サイズだけを判定基準にすると取りこぼす。
    static _NeedsCorrection(placement) {
        hwnd := placement.hwnd
        if !hwnd || !WinExist("ahk_id " . hwnd)
            return false
        try {
            ; 最小化はユーザー操作を尊重して対象外。最大化のままなら配置失敗
            ; なのでtrueを返し、補正側で解除を再試行する。
            state := WinGetMinMax("ahk_id " . hwnd)
            if (state == -1)
                return false
            if (state == 1)
                return true
        } catch
            return false

        rect := Buffer(16, 0)
        if !DllCall("user32\GetWindowRect", "ptr", hwnd, "ptr", rect)
            return false
        left := NumGet(rect, 0, "int")
        top := NumGet(rect, 4, "int")
        width := NumGet(rect, 8, "int") - left
        height := NumGet(rect, 12, "int") - top

        target := this._TargetFor(placement)
        tol := this.RECT_TOLERANCE
        return Abs(left - target.x) > tol
            || Abs(top - target.y) > tol
            || Abs(width - target.w) > tol
            || Abs(height - target.h) > tol
    }

    static _GetTileRect(work, index) {
        midX := work.left + Floor(work.w / 2)
        midY := work.top + Floor(work.h / 2)
        gapBefore := Floor(this.INNER_GAP / 2)
        gapAfter := this.INNER_GAP - gapBefore

        if (Mod(index - 1, 2) == 0) {
            left := work.left
            right := midX - gapBefore
        } else {
            left := midX + gapAfter
            right := work.right
        }
        if (index <= 2) {
            top := work.top
            bottom := midY - gapBefore
        } else {
            top := midY + gapAfter
            bottom := work.bottom
        }
        return {
            left: left, top: top, right: right, bottom: bottom,
            w: right - left, h: bottom - top
        }
    }

    static _GetFrameInsets(hwnd) {
        windowRect := Buffer(16, 0)
        visibleRect := Buffer(16, 0)
        if (!DllCall("user32\GetWindowRect", "ptr", hwnd, "ptr", windowRect)
            || DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd,
                "uint", 9, "ptr", visibleRect, "uint", 16, "int") != 0)
            return {left: 0, top: 0, right: 0, bottom: 0}

        return {
            left: Max(0, NumGet(visibleRect, 0, "int") - NumGet(windowRect, 0, "int")),
            top: Max(0, NumGet(visibleRect, 4, "int") - NumGet(windowRect, 4, "int")),
            right: Max(0, NumGet(windowRect, 8, "int") - NumGet(visibleRect, 8, "int")),
            bottom: Max(0, NumGet(windowRect, 12, "int") - NumGet(visibleRect, 12, "int"))
        }
    }

    static _GetMonitorWorkArea(monitor) {
        mi := Buffer(40, 0)
        NumPut("uint", 40, mi, 0)
        if !DllCall("user32\GetMonitorInfoW", "ptr", monitor, "ptr", mi)
            return 0

        left := NumGet(mi, 20, "int")
        top := NumGet(mi, 24, "int")
        right := NumGet(mi, 28, "int")
        bottom := NumGet(mi, 32, "int")
        return {
            left: left, top: top, right: right, bottom: bottom,
            w: right - left, h: bottom - top
        }
    }

    static GetMonitorAtCursor() {
        dpiContext := this._EnterPhysicalDpiContext()
        try return this._GetMonitorAtCursorCore()
        finally this._LeaveDpiContext(dpiContext)
    }

    static _GetMonitorAtCursorCore() {
        point := Buffer(8, 0)
        if !DllCall("user32\GetCursorPos", "ptr", point)
            return 0
        return DllCall("user32\MonitorFromPoint",
            "int64", NumGet(point, 0, "int64"),
            "uint", 2, "ptr")  ; MONITOR_DEFAULTTONEAREST
    }

    ; GetMonitorInfo/GetWindowRect/SetWindowPosは呼び出し元スレッドのDPI認識に
    ; よって座標が仮想化される。一方DWM枠は常に物理pxなので、処理中だけ
    ; Per-Monitor-V2へ統一して混在を防ぐ。
    static _EnterPhysicalDpiContext() {
        try return DllCall("user32\SetThreadDpiAwarenessContext",
            "ptr", -4, "ptr")  ; DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        catch
            return 0
    }

    static _LeaveDpiContext(previousContext) {
        if !previousContext
            return
        try DllCall("user32\SetThreadDpiAwarenessContext",
            "ptr", previousContext, "ptr")
    }
}
