; ==============================================================================
; Module:      Navi.ContextMenu.ahk
; Description: Windows Shell IContextMenu 操作（COM vtable 直接呼び出し）
;              - Explorer と同等の右クリックメニューを TreeView 選択アイテムに表示
;              - 危険な操作（削除・切り取り・名前の変更）を動的に除去
;              - IContextMenu2 によるサブメニュー（「送る」等）の初期化対応
; Usage:       NaviContextMenu.Show(fullPath) で呼び出し
; Note:        AHK スレッドは MTA のため「送る」等が E_FAIL になる場合があり、
;              InvokeCommand 失敗時は PowerShell -STA でフォールバックする
; Version:     1.0.0
; License:     MIT
; ==============================================================================

class NaviContextMenu {

    ; --- 設定 ---
    ; true:  削除・切り取り・名前の変更をメニューから非表示（誤操作防止）
    ; false: 表示する（有効化したい場合は false に変更）
    static HIDE_DANGEROUS_CTX_ITEMS := true

    ; --- Windows メッセージ定数 ---
    static WM_INITMENUPOPUP := 0x0117

    ; --- 右クリックメニュー用一時ステート ---
    static _ctxMenu2Ptr  := 0
    static _ctxVtable2   := 0
    static _ctxMenuHwnd  := 0
    static _ctxMenu2Cb   := ""

    ; -----------------------------------------------------------------------
    ; WM_INITMENUPOPUP ハンドラ（IContextMenu2 サブメニュー初期化用）
    ; -----------------------------------------------------------------------
    static _OnInitMenuPopup(wp, lp, msg, hw) {
        if (hw = NaviContextMenu._ctxMenuHwnd && NaviContextMenu._ctxMenu2Ptr != 0)
            DllCall(NumGet(NaviContextMenu._ctxVtable2, 6 * A_PtrSize, "ptr"),
                "ptr", NaviContextMenu._ctxMenu2Ptr, "uint", NaviContextMenu.WM_INITMENUPOPUP, "uptr", wp, "uptr", lp)
        return ""
    }

    ; -----------------------------------------------------------------------
    ; 削除・切り取り・名前の変更をメニューから除去（誤操作防止）
    ; -----------------------------------------------------------------------
    static _RemoveDangerousMenuItems(hMenu) {
        static dangerous := ["削除", "切り取り", "名前の変更", "Delete", "Cut", "Rename"]
        count := DllCall("user32\GetMenuItemCount", "ptr", hMenu, "int")
        i := count - 1
        while i >= 0 {
            buf := Buffer(1024, 0)
            DllCall("user32\GetMenuStringW", "ptr", hMenu, "uint", i, "ptr", buf, "int", 512, "uint", 0x400)
            text := RegExReplace(StrGet(buf, "UTF-16"), "\s*\(&\w\)|&", "")
            for d in dangerous {
                if (InStr(text, d) = 1) {
                    DllCall("user32\DeleteMenu", "ptr", hMenu, "uint", i, "uint", 0x400)
                    break
                }
            }
            i--
        }
    }

    ; -----------------------------------------------------------------------
    ; Windows Shell IContextMenu を呼び出して Explorer と同じ右クリックメニューを表示
    ; -----------------------------------------------------------------------
    static Show(fullPath) {
        if !(Navi.GuiObj && WinExist(Navi.GuiObj))
            return
        hwnd := Navi.GuiObj.Hwnd

        ; Shell インターフェース GUID の初期化
        IID_IShellFolder := Buffer(16)
        DllCall("ole32\CLSIDFromString", "wstr", "{000214E6-0000-0000-C000-000000000046}", "ptr", IID_IShellFolder)
        IID_IContextMenu := Buffer(16)
        DllCall("ole32\CLSIDFromString", "wstr", "{000214E4-0000-0000-C000-000000000046}", "ptr", IID_IContextMenu)

        ; パスを PIDL に変換
        pidlFull := 0, sfgao := 0
        if (DllCall("shell32\SHParseDisplayName", "wstr", fullPath, "ptr", 0,
                "ptr*", &pidlFull, "uint", 0, "uint*", &sfgao) != 0 || pidlFull = 0)
            return

        ; 親フォルダの IShellFolder と相対 PIDL を取得
        pFolder := 0, pidlRel := 0
        DllCall("shell32\SHBindToParent", "ptr", pidlFull,
            "ptr", IID_IShellFolder, "ptr*", &pFolder, "ptr*", &pidlRel)
        if pFolder = 0 {
            DllCall("ole32\CoTaskMemFree", "ptr", pidlFull)
            return
        }

        ; IContextMenu を取得（pidlFull はまだ解放しない: pidlRel が内部ポインタ）
        pCtxMenu := 0
        vtFolder := NumGet(pFolder, 0, "ptr")
        pidlArr := Buffer(A_PtrSize)
        NumPut("ptr", pidlRel, pidlArr, 0)
        DllCall(NumGet(vtFolder, 10 * A_PtrSize, "ptr"),
            "ptr", pFolder, "ptr", hwnd, "uint", 1, "ptr", pidlArr,
            "ptr", IID_IContextMenu, "uint*", 0, "ptr*", &pCtxMenu)

        if pCtxMenu = 0 {
            DllCall("ole32\CoTaskMemFree", "ptr", pidlFull)
            DllCall(NumGet(vtFolder, 2 * A_PtrSize, "ptr"), "ptr", pFolder)
            return
        }

        ; OLE初期化（「送る」等のドラッグドロップ系操作に必要）
        DllCall("ole32\OleInitialize", "ptr", 0)

        ; ポップアップメニューを作成・設定
        vtCtx := NumGet(pCtxMenu, 0, "ptr")
        hMenu := DllCall("user32\CreatePopupMenu", "ptr")
        DllCall(NumGet(vtCtx, 3 * A_PtrSize, "ptr"),
            "ptr", pCtxMenu, "ptr", hMenu, "uint", 0, "uint", 1, "uint", 0x7FFF, "uint", 0)

        ; 危険な操作（削除・切り取り・名前の変更）をメニューから除去
        if NaviContextMenu.HIDE_DANGEROUS_CTX_ITEMS
            NaviContextMenu._RemoveDangerousMenuItems(hMenu)

        ; IContextMenu2 を取得（「送る」等のサブメニュー初期化に必要）
        IID_ICtxMenu2 := Buffer(16)
        DllCall("ole32\CLSIDFromString", "wstr", "{000214F4-0000-0000-C000-000000000046}", "ptr", IID_ICtxMenu2)
        pCtxMenu2 := 0
        DllCall(NumGet(vtCtx, 0, "ptr"), "ptr", pCtxMenu, "ptr", IID_ICtxMenu2, "ptr*", &pCtxMenu2)
        if pCtxMenu2 {
            NaviContextMenu._ctxMenu2Ptr  := pCtxMenu2
            NaviContextMenu._ctxVtable2   := NumGet(pCtxMenu2, 0, "ptr")
            NaviContextMenu._ctxMenuHwnd  := hwnd
            NaviContextMenu._ctxMenu2Cb   := ObjBindMethod(NaviContextMenu, "_OnInitMenuPopup")
            OnMessage(NaviContextMenu.WM_INITMENUPOPUP, NaviContextMenu._ctxMenu2Cb)
        }

        ; AHK の低レベルフックがメニューよりキーを先取りするため、表示中は一時無効化
        HotIfWinActive("ahk_id " hwnd)
        Hotkey("Enter", "Off")
        Hotkey("Space", "Off")
        Hotkey("Esc", "Off")
        HotIf()

        ; 選択アイテムの右端をメニュー表示位置に使う
        tv := Navi.GuiObj["FolderTree"]
        selId := tv.GetSelection()
        rect := Buffer(16, 0)
        NumPut("uptr", selId, rect, 0)
        DllCall("user32\SendMessageW", "ptr", tv.Hwnd, "uint", 0x1104, "uptr", 1, "ptr", rect)
        pt := Buffer(8, 0)
        NumPut("int", NumGet(rect, 8, "Int"), pt, 0)  ; right edge of item label
        NumPut("int", NumGet(rect, 4, "Int"), pt, 4)  ; top of item
        DllCall("user32\ClientToScreen", "ptr", tv.Hwnd, "ptr", pt)
        mx := NumGet(pt, 0, "Int")
        my := NumGet(pt, 4, "Int")
        DllCall("user32\SetForegroundWindow", "ptr", hwnd)
        cmd := DllCall("user32\TrackPopupMenu", "ptr", hMenu,
            "uint", 0x0100, "int", mx, "int", my, "int", 0, "ptr", hwnd, "ptr", 0, "int")

        ; 選択項目の表示テキストを取得（DestroyMenu前に）
        menuItemText := ""
        if cmd > 0 {
            txtBuf := Buffer(1024, 0)
            DllCall("user32\GetMenuStringW", "ptr", hMenu, "uint", cmd, "ptr", txtBuf, "int", 512, "uint", 0)
            menuItemText := RegExReplace(StrGet(txtBuf, "UTF-16"), "&", "")
        }
        DllCall("user32\DestroyMenu", "ptr", hMenu)

        ; WM_INITMENUPOPUP ハンドラ解除
        if pCtxMenu2 {
            OnMessage(NaviContextMenu.WM_INITMENUPOPUP, NaviContextMenu._ctxMenu2Cb, 0)
            DllCall(NumGet(NaviContextMenu._ctxVtable2, 2 * A_PtrSize, "ptr"), "ptr", pCtxMenu2)
            NaviContextMenu._ctxMenu2Ptr := 0
            NaviContextMenu._ctxMenu2Cb  := ""
        }

        ; ホットキー復元
        HotIfWinActive("ahk_id " hwnd)
        Hotkey("Enter", "On")
        Hotkey("Space", "On")
        Hotkey("Esc", "On")
        HotIf()

        ; 選択コマンドを実行
        if cmd > 0 {
            cbSize := (A_PtrSize = 8) ? 56 : 36
            ici := Buffer(cbSize, 0)
            NumPut("uint", cbSize,     ici, 0)
            NumPut("uint", 0x00100000, ici, 4)  ; CMIC_MASK_ASYNCOK
            NumPut("ptr",  hwnd,       ici, 8)
            NumPut("ptr",  cmd - 1,    ici, 8 + A_PtrSize)
            NumPut("int",  1,          ici, 8 + 4 * A_PtrSize)
            hr := DllCall(NumGet(vtCtx, 4 * A_PtrSize, "ptr"), "ptr", pCtxMenu, "ptr", ici, "int")
            if hr != 0
                NaviContextMenu._InvokeCommandPS(fullPath, menuItemText)
        }

        DllCall(NumGet(vtCtx, 2 * A_PtrSize, "ptr"), "ptr", pCtxMenu)
        DllCall("ole32\CoTaskMemFree", "ptr", pidlFull)
        DllCall(NumGet(vtFolder, 2 * A_PtrSize, "ptr"), "ptr", pFolder)
        DllCall("ole32\OleUninitialize")
    }

    ; -----------------------------------------------------------------------
    ; IContextMenu::InvokeCommand が MTA 起因で失敗した場合の PowerShell STA フォールバック
    ; -----------------------------------------------------------------------
    static _InvokeCommandPS(fullPath, verbText) {
        safeFile := StrReplace(fullPath, "'", "''")
        safeVerb := StrReplace(verbText, "'", "''")
        psScript := ""
            . "$f = '" . safeFile . "'`n"
            . "$v = '" . safeVerb . "'`n"
            . "$s = New-Object -COM Shell.Application`n"
            . "$item = $s.NameSpace((Split-Path $f)).ParseName((Split-Path -Leaf $f))`n"
            . "foreach ($verb in $item.Verbs()) {`n"
            . "    if (($verb.Name -replace '&','') -eq $v) { try { $verb.DoIt() } catch {}; return }`n"
            . "}`n"
            . "# SendTo フォルダから直接実行`n"
            . "$st = [Environment]::GetFolderPath('SendTo')`n"
            . "$vBase = [System.IO.Path]::GetFileNameWithoutExtension($v)`n"
            . "Get-ChildItem $st | Where-Object { $_.BaseName -eq $vBase -or $_.Name -eq $v } | Select-Object -First 1 | ForEach-Object {`n"
            . "    $t = $_.FullName`n"
            . "    $ext = $_.Extension.ToLower()`n"
            . "    if ($ext -eq '.lnk') {`n"
            . "        $ws = New-Object -COM WScript.Shell`n"
            . "        $lnk = $ws.CreateShortcut($t)`n"
            . "        if ($lnk.TargetPath) { $a = '`"{0}`"' -f $f; Start-Process $lnk.TargetPath $a }`n"
            . "    } elseif ($ext -eq '.vbs') {`n"
            . "        $a = '`"{0}`" `"{1}`"' -f $t,$f; Start-Process 'wscript.exe' $a`n"
            . "    } elseif ($ext -eq '.bat' -or $ext -eq '.cmd') {`n"
            . "        $a = '`"{0}`" `"{1}`"' -f $t,$f; Start-Process 'cmd.exe' ('/c ' + $a)`n"
            . "    } else {`n"
            . "        $a = '`"{0}`"' -f $f; Start-Process $t $a`n"
            . "    }`n"
            . "}`n"
        tmpPs := A_Temp . "\NaviInvoke.ps1"
        fh := FileOpen(tmpPs, "w", "UTF-8")
        fh.Write(psScript)
        fh.Close()
        Run("powershell.exe -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"" . tmpPs . "`"", , "Hide")
    }
}
