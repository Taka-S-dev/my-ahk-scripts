#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Search.ahk
; Description:  Navi用ローカル再帰検索モジュール
;               - 非同期タイマーでディレクトリ走査（GUI応答を阻害しない）
;               - TreeView上のヒットを強調し、Prev/Nextでジャンプ
;               - 親GUI終了時に検索ウィンドウを自動クローズ
; Query:        スペース=AND / | = OR / ! = NOT
; Example:      "src | lib !test" → (src OR lib) AND NOT test
; Usage:        Navi 内のアクション "&F: Search (Local)" から呼び出し
; Version:      1.0.0
; License:      MIT
; ==============================================================================

class NaviSearch {
    static HighlightedIds := []
    static HighlightedIdx := 0
    static HotkeyHwnd := 0
    static SearchActive := false
    static CancelRequested := false
    static Task := ""
    static ProgressGui := ""
    static ProgressLabel := ""
    static JumpGui := ""
    static JumpLabel := ""
    static LastNavi := ""
    static _ParentWatchFn := ""

    ; Tunables
    static MAX_RESULTS := 1000
    static MAX_HIGHLIGHT := 500
    static SCAN_TIMEOUT_MS := 10000
    static DIRS_PER_TICK := 40
    ; UI/Timer constants
    static UI_MARGIN := 12              ; General pixel margin for dialogs/anchors
    static TIMER_TICK_MS := 10          ; Directory scan timer interval
    static PARENT_WATCH_MS := 300       ; Parent-GUI existence watch interval
    static EDIT_W := 460                ; Query edit width
    static BTN_W_LARGE := 90            ; Large button width
    static BTN_W_SMALL := 60            ; Small button width
    static LABEL_W_HITS := 120          ; Hit status label width
    static LABEL_W_PROGRESS := 260      ; Progress label width
    static GAP_X_SMALL := 6             ; Small horizontal gap
    static GAP_X_MED := 8               ; Medium horizontal gap
    static GAP_X_LARGE := 10            ; Large horizontal gap

    ; Internal task shape:
    ; {
    ;   navi, basePath, tokens, stack: [dirs],
    ;   results: [], startedAt: A_TickCount,
    ;   processedDirs: 0, processedItems: 0
    ; }

    ; Public API: Run local search under basePath, highlight matches in tree
    static RunLocal(navi, basePath) {
        if (basePath = "" || !DirExist(basePath)) {
            ToolTip("検索ベースのフォルダが無効です")
            SetTimer(() => ToolTip(), -navi.TOOLTIP_ERROR_DURATION)
            return
        }
        ; モーダル・最前面の検索入力ダイアログ
        q := this._PromptQuery(navi, basePath)
        if (q = "")
            return
        incGroups := [], notAlts := []
        this._ParseQuery(q, &incGroups, &notAlts)
        if (incGroups.Length = 0)
            return

        ; Initialize async task
        this.CancelRequested := false
        this.SearchActive := true
        this.Task := Map(
            "navi", navi,
            "basePath", basePath,
            "tokens", Map("include", incGroups, "not", notAlts),
            "stack", [basePath],
            "results", [],
            "startedAt", A_TickCount,
            "processedDirs", 0,
            "processedItems", 0
        )
        this._ShowProgress(navi)
        this.EnsureHotkeys(navi)
        ; Start timer loop
        SetTimer(NaviSearch._Tick.Bind(NaviSearch), this.TIMER_TICK_MS)
    }

    ; タイマーループ: ディレクトリを分割して逐次処理
    static _Tick(*) {
        if !(this.SearchActive) {
            SetTimer(, 0)
            return
        }
        t := this.Task
        nv := t["navi"]
        if !(nv.GuiObj && WinExist(nv.GuiObj)) {
            this._Finish(false)
            return
        }
        ; Timeout or cancel or enough results
        if (this.CancelRequested
            || (A_TickCount - t["startedAt"] >= this.SCAN_TIMEOUT_MS)
            || (t["results"].Length >= this.MAX_RESULTS)) {
            this._Finish(true)
            return
        }
        dirsProcessed := 0
        while (dirsProcessed < this.DIRS_PER_TICK && t["stack"].Length > 0) {
            dir := t["stack"].Pop()
            t["processedDirs"] += 1
            ; Enumerate non-recursive: files then dirs
            ; Files
            try {
                loop files, dir . "\*", "F" {
                    t["processedItems"] += 1
                    name := StrLower(A_LoopFileName)
                    ok := this._NameMatches(name, t["tokens"]["include"], t["tokens"]["not"])
                    if (ok) {
                        t["results"].Push(A_LoopFileFullPath)
                        if (t["results"].Length >= this.MAX_RESULTS) {
                            this._Finish(true)
                            return
                        }
                    }
                }
            }
            ; Dirs (enqueue for later) and match by own name
            try {
                loop files, dir . "\*", "D" {
                    t["processedItems"] += 1
                    t["stack"].Push(A_LoopFileFullPath)
                    name := StrLower(A_LoopFileName)
                    ok := this._NameMatches(name, t["tokens"]["include"], t["tokens"]["not"])
                    if (ok) {
                        t["results"].Push(A_LoopFileFullPath)
                        if (t["results"].Length >= this.MAX_RESULTS) {
                            this._Finish(true)
                            return
                        }
                    }
                }
            }
            dirsProcessed += 1
        }
        this._UpdateProgress()
    }

    ; クエリ文字列を AND/OR/NOT の構造に分解
    static _ParseQuery(q, &incGroups, &notAlts) {
        incGroups := []
        notAlts := []
        for raw in StrSplit(q, " ") {
            t := Trim(raw)
            if (t = "")
                continue
            isNot := (SubStr(t, 1, 1) = "!")
            if (isNot) {
                t := SubStr(t, 2)
                if (t = "")
                    continue
            }
            ; Split OR by '|'
            alts := []
            for part in StrSplit(t, "|") {
                p := Trim(part)
                if (p != "")
                    alts.Push(StrLower(p))
            }
            if (alts.Length = 0)
                continue
            if (isNot) {
                for a in alts
                    notAlts.Push(a)
            } else {
                incGroups.Push(alts)
            }
        }
    }

    ; 小文字化した名前に対し、包含(AND/OR)と除外(NOT)で判定
    static _NameMatches(name, incGroups, notAlts) {
        ; NOT: reject if any NOT alternative matches
        for na in notAlts {
            if InStr(name, na)
                return false
        }
        ; INCLUDE: every group must have at least one alt contained
        for group in incGroups {
            okInGroup := false
            for alt in group {
                if InStr(name, alt) {
                    okInGroup := true
                    break
                }
            }
            if !okInGroup
                return false
        }
        return true
    }

    ; --- 検索入力ダイアログ（Navi付近に最前面表示） ---
    static _PromptQuery(navi, basePath) {
        title := "Navi - Local Search"
        g := Gui("+AlwaysOnTop +ToolWindow -MaximizeBox -MinimizeBox", title)
        g.SetFont("s9", "Segoe UI")
        g.Add("Text", "xm", "検索語（スペース=AND, | = OR, ! = NOT）")
        g.Add("Text", "xm c808080", "Base: " . basePath)
        inputEdit := g.Add("Edit", "xm w" . this.EDIT_W . " vQ")
        btnOK := g.Add("Button", "xm w" . this.BTN_W_LARGE . " Default", "OK")
        btnCancel := g.Add("Button", "x+" . this.GAP_X_MED . " w" . this.BTN_W_LARGE, "キャンセル")
        res := ""
        btnOK.OnEvent("Click", (*) => (res := Trim(inputEdit.Value), g.Destroy()))
        btnCancel.OnEvent("Click", (*) => (res := "", g.Destroy()))
        g.OnEvent("Escape", (*) => (res := "", g.Destroy()))
        ; 位置決め：TreeViewの上辺中央 or 親中央
        if (navi.GuiObj && WinExist(navi.GuiObj)) {
            try navi.GuiObj.Opt("+Disabled")
            tv := navi.GuiObj["FolderTree"]
            rect := Buffer(16, 0)
            x := 0, y := 0
            g.Show("Hide AutoSize")
            g.GetPos(, , &gw, &gh)
            if (tv) {
                try {
                    DllCall("GetWindowRect", "ptr", tv.Hwnd, "ptr", rect.Ptr)
                    left := NumGet(rect, 0, "Int"), top := NumGet(rect, 4, "Int"), right := NumGet(rect, 8, "Int")
                    tvW := right - left
                    pad := this.UI_MARGIN
                    x := left + (tvW - gw) // 2
                    y := top + pad
                }
            }
            if (x = 0 && y = 0) {
                navi.GuiObj.GetPos(&px, &py, &pw, &ph)
                x := px + (pw - gw) // 2
                y := py + (ph - gh) // 2
            }
            g.Show("x" . x . " y" . y)
        } else {
            g.Show()
        }
        inputEdit.Focus()
        WinWaitClose("ahk_id " g.Hwnd)
        ; 親GUI再有効化
        try {
            if (navi.GuiObj && WinExist(navi.GuiObj))
                navi.GuiObj.Opt("-Disabled +AlwaysOnTop")
        }
        return res
    }

    static _Finish(showResults) {
        SetTimer(, 0)
        this._HideProgress()
        this.SearchActive := false
        if (showResults) {
            t := this.Task
            nv := t["navi"]
            if (nv.GuiObj && WinExist(nv.GuiObj)) {
                tv := nv.GuiObj["FolderTree"]
                this.HighlightPathsInTree(nv, tv, t["basePath"], t["results"])
                this._EnsureJumpGui(nv)
            }
        }
        this.Task := ""
        this.CancelRequested := false
    }

    ; Progress UI and cancel
    static _ShowProgress(navi) {
        ; マルチモニタでの座標ずれ回避のためオーナーは付けない（絶対座標で配置）
        this.ProgressGui := Gui("+AlwaysOnTop -Caption +ToolWindow +Border")
        this.ProgressGui.SetFont("s9", "Segoe UI")
        this.ProgressLabel := this.ProgressGui.Add("Text", "xm ym w" . this.LABEL_W_PROGRESS, "Searching...")
        btn := this.ProgressGui.Add("Button", "x+" . this.GAP_X_LARGE . " yp w" . this.BTN_W_SMALL, "Cancel")
        btn.OnEvent("Click", (*) => (NaviSearch.CancelRequested := true))
        ; 位置決め（Naviの「ルートディレクトリ管理」と同じロジックで親GUI中央に配置）
        if (navi.GuiObj && WinExist(navi.GuiObj)) {
            navi.GuiObj.GetPos(&px, &py, &pw, &ph)
            ; いったん隠してレイアウト確定→正確なサイズ取得
            this.ProgressGui.Show("Hide AutoSize")
            this.ProgressGui.GetPos(, , &gw, &gh)
            x := px + (pw - gw) // 2
            y := py + (ph - gh) // 2
            this.ProgressGui.Show("x" . x . " y" . y)
            ; 親を無効化して簡易モーダル化
            try navi.GuiObj.Opt("+Disabled")
            this.LastNavi := navi
        } else {
            this.ProgressGui.Show("Hide AutoSize")
            this.ProgressGui.GetPos(, , &gw, &gh)
            this.ProgressGui.Show()
        }
        ; Naviアクティブ時は Esc でキャンセル
        if (navi.GuiObj && WinExist(navi.GuiObj)) {
            HotIfWinActive("ahk_id " navi.GuiObj.Hwnd)
            Hotkey("Esc", ((*) => (NaviSearch.CancelRequested := true)), "On")
            HotIf()
        }
        this._UpdateProgress()
    }

    static _UpdateProgress() {
        if !this.ProgressGui
            return
        t := this.Task
        elapsed := A_TickCount - t["startedAt"]
        msg := "Searching... results: " . t["results"].Length .
               "  scanned dirs: " . t["processedDirs"] .
               "  items: " . t["processedItems"] .
               "  (" . Format("{:0.1f}", elapsed/1000) . "s)"
        this.ProgressLabel.Text := msg
    }

    static _HideProgress() {
        try this.ProgressGui.Destroy()
        this.ProgressGui := ""
        this.ProgressLabel := ""
        ; 親GUIの再有効化
        try {
            t := this.Task
            if (Type(t) = "Map" && t.Has("navi")) {
                nv := t["navi"]
                if (nv && nv.GuiObj && WinExist(nv.GuiObj))
                    nv.GuiObj.Opt("-Disabled +AlwaysOnTop")
            } else if (this.LastNavi && this.LastNavi.GuiObj && WinExist(this.LastNavi.GuiObj)) {
                this.LastNavi.GuiObj.Opt("-Disabled +AlwaysOnTop")
            }
        }
        ; ホットキー解除は次回 EnsureHotkeys で上書きされるため省略
    }

    ; ハイライトとツリー展開
    static HighlightPathsInTree(navi, tv, basePath, paths) {
        if !tv
            return
        try {
            for id in this.HighlightedIds {
                try tv.Modify(id, "-Bold")
            }
        }
        this.HighlightedIds := []
        this.HighlightedIdx := 0

        shownCount := 0
        for p in paths {
            if (shownCount >= this.MAX_HIGHLIGHT)
                break
            if InStr(p, basePath) != 1
                continue
            if (DirExist(p)) {
                if (id := this.EnsurePathExpanded(navi, tv, p)) {
                    try tv.Modify(id, "Bold")
                    this.HighlightedIds.Push(id), shownCount += 1
                }
            } else if (FileExist(p)) {
                SplitPath(p, &fname, &dir)
                if (idDir := this.EnsurePathExpanded(navi, tv, dir)) {
                    this.EnsureFilesShown(navi, tv, idDir, dir)
                    cid := tv.GetChild(idDir)
                    while (cid) {
                        if (tv.GetText(cid) = fname) {
                            try tv.Modify(cid, "Bold")
                            this.HighlightedIds.Push(cid), shownCount += 1
                            break
                        }
                        cid := tv.GetNext(cid)
                    }
                }
            }
        }
        ToolTip("Highlighted: " . shownCount)
        SetTimer(() => ToolTip(), -navi.TOOLTIP_SUCCESS_DURATION)
        ; 最初のヒットへジャンプ
        if (shownCount > 0) {
            this.HighlightedIdx := 1
            try tv.Modify(this.HighlightedIds[1], "Select Vis")
        }
    }

    static EnsurePathExpanded(navi, tv, targetPath) {
        if (!DirExist(targetPath) && !FileExist(targetPath))
            return 0
        currentID := tv.GetNext(0, "Full")
        if (currentID == 0)
            return 0
        rootPath := tv.GetText(currentID)
        if (!InStr(targetPath, rootPath))
            return 0
        relPath := LTrim(StrReplace(targetPath, rootPath, ""), "\")
        parts := StrSplit(relPath, "\")
        for part in parts {
            if (part = "")
                continue
            tv.Modify(currentID, "Expand")
            ; 子ノードは Navi のロードロジックを使用
            try navi._OnItemExpand(tv, currentID)
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
        return currentID
    }

    static EnsureFilesShown(navi, tv, idDir, dirPath) {
        if (navi.FilesShown.Has(idDir))
            return
        shown := []
        fileMax := 200
        try fileMax := Integer(IniRead(navi.IniPath, "Settings", "FileMax", "200"))
        count := 0
        loop files, dirPath . "\*", "F" {
            if InStr(A_LoopFileAttrib, "H")
                continue
            fid := tv.Add(A_LoopFileName, idDir)
            shown.Push(fid)
            count += 1
            if (count >= fileMax)
                break
        }
        navi.FilesShown[idDir] := shown
    }

    ; ------- ホットキーとジャンプ -------
    static EnsureHotkeys(navi) {
        if !(navi.GuiObj && WinExist(navi.GuiObj))
            return
        hwnd := navi.GuiObj.Hwnd
        if (this.HotkeyHwnd = hwnd)
            return
        this.HotkeyHwnd := hwnd
        HotIfWinActive("ahk_id " hwnd)
        Hotkey("F3", ((*) => NaviSearch.Jump(navi, +1)), "On")
        Hotkey("+F3", ((*) => NaviSearch.Jump(navi, -1)), "On")
        HotIf()
    }

    static Jump(navi, delta) {
        if !(navi.GuiObj && WinExist(navi.GuiObj))
            return
        tv := navi.GuiObj["FolderTree"]
        total := this.HighlightedIds.Length
        if (total = 0) {
            ToolTip("No hits")
            SetTimer(() => ToolTip(), -navi.TOOLTIP_SUCCESS_DURATION)
            return
        }
        idx := this.HighlightedIdx
        if (idx = 0)
            idx := 1
        idx += delta
        if (idx < 1)
            idx := total
        else if (idx > total)
            idx := 1
        this.HighlightedIdx := idx
        id := this.HighlightedIds[idx]
        try tv.Modify(id, "Select Vis")
        ToolTip("Hit " . idx . " / " . total)
        SetTimer(() => ToolTip(), -navi.TOOLTIP_SUCCESS_DURATION)
        this._UpdateJumpLabel()
    }

    static _EnsureJumpGui(navi) {
        if !(navi.GuiObj && WinExist(navi.GuiObj))
            return
        jg := this.JumpGui
        if (Type(jg) = "Gui" && jg.Hwnd && WinExist("ahk_id " jg.Hwnd)) {
            this._UpdateJumpLabel()
            return
        }
        ; マルチモニタでの座標ずれ回避のためオーナーは付けない
        g := Gui("+AlwaysOnTop +ToolWindow -MaximizeBox -MinimizeBox", "Search Hits")
        g.SetFont("s9", "Segoe UI")
        prev := g.Add("Button", "xm w" . this.BTN_W_SMALL, "Prev")
        next := g.Add("Button", "x+" . this.GAP_X_SMALL . " w" . this.BTN_W_SMALL, "Next")
        clr  := g.Add("Button", "x+" . this.GAP_X_SMALL . " w" . this.BTN_W_SMALL, "Clear")
        this.JumpLabel := g.Add("Text", "x+" . this.GAP_X_LARGE . " w" . this.LABEL_W_HITS, "")
        closeBtn := g.Add("Button", "x+" . this.GAP_X_SMALL . " w" . this.BTN_W_SMALL, "Close")
        prev.OnEvent("Click", (*) => NaviSearch.Jump(navi, -1))
        next.OnEvent("Click", (*) => NaviSearch.Jump(navi, +1))
        clr.OnEvent("Click", (*) => NaviSearch.ClearHighlights(navi))
        closeBtn.OnEvent("Click", (*) => (NaviSearch._DestroyJumpGui()))
        ; ツリーに被らない位置に配置（右→左→上→下の優先順）
        g.Show("Hide AutoSize")
        g.GetPos(, , &gw, &gh)
        tv := navi.GuiObj["FolderTree"]
        x := 0, y := 0
        if (tv) {
            rect := Buffer(16, 0)
            try DllCall("GetWindowRect", "ptr", tv.Hwnd, "ptr", rect.Ptr)
            left   := NumGet(rect, 0, "Int")
            top    := NumGet(rect, 4, "Int")
            right  := NumGet(rect, 8, "Int")
            bottom := NumGet(rect, 12, "Int")
            margin := this.UI_MARGIN
            ; 1) 右側
            x := right + margin, y := top
            if (x + gw > A_ScreenWidth) {
                ; 2) 左側
                x := left - gw - margin, y := top
            }
            if (x < 0) {
                ; 3) 上側
                x := left, y := top - gh - margin
            }
            if (y < 0) {
                ; 4) 下側
                x := left, y := bottom + margin
            }
        } else {
            ; フォールバック: 親の右上付近
            navi.GuiObj.GetPos(&px, &py, &pw, &ph)
            x := px + pw - gw - 16
            y := py + 16
        }
        g.Show("x" . x . " y" . y)
        ; 親は無効化しない（ツリー操作を阻害しない）
        this.LastNavi := navi
        this.JumpGui := g
        ; 親GUIクローズ時に検索ウィンドウも自動クローズ
        try navi.GuiObj.OnEvent("Close", (*) => (NaviSearch._DestroyJumpGui()), 1)
        ; 親の存在監視タイマー（包括的なクローズ）
        this._StartParentWatch()
        this._UpdateJumpLabel()
    }



    static _UpdateJumpLabel() {
        jg := this.JumpGui
        if !(Type(jg) = "Gui" && jg.Hwnd && WinExist("ahk_id " jg.Hwnd))
            return
        total := this.HighlightedIds.Length
        idx := this.HighlightedIdx
        this.JumpLabel.Text := "Hit " . (total ? idx : 0) . " / " . total
    }

    static _DestroyJumpGui() {
        try this.JumpGui.Destroy()
        this.JumpGui := ""
        this.JumpLabel := ""
        this._StopParentWatch()
        ; 親GUIの再有効化
        try {
            if (this.LastNavi && this.LastNavi.GuiObj && WinExist(this.LastNavi.GuiObj))
                this.LastNavi.GuiObj.Opt("-Disabled +AlwaysOnTop")
        }
    }

    ; ---------- 親GUI監視（自動クローズ） ----------
    static _StartParentWatch() {
        ; 既存タイマー停止
        if (Type(this._ParentWatchFn) = "Func")
            SetTimer(this._ParentWatchFn, 0)
        fn := NaviSearch._ParentWatchTick.Bind(NaviSearch)
        this._ParentWatchFn := fn
        SetTimer(fn, this.PARENT_WATCH_MS) ; 親の生存監視
    }

    static _StopParentWatch() {
        if (Type(this._ParentWatchFn) = "Func") {
            SetTimer(this._ParentWatchFn, 0)
            this._ParentWatchFn := ""
        }
    }

    static _ParentWatchTick(*) {
        ; JumpGuiが既に存在しない場合は監視停止
        jg := this.JumpGui
        if !(Type(jg) = "Gui" && jg.Hwnd && WinExist("ahk_id " jg.Hwnd)) {
            this._StopParentWatch()
            return
        }
        ; 親が消えていたらクローズ
        if !(this.LastNavi && this.LastNavi.GuiObj && WinExist("ahk_id " this.LastNavi.GuiObj.Hwnd)) {
            this._DestroyJumpGui()
            this._StopParentWatch()
        }
    }

    static ClearHighlights(navi) {
        if !(navi.GuiObj && WinExist(navi.GuiObj))
            return
        tv := navi.GuiObj["FolderTree"]
        try {
            for id in this.HighlightedIds {
                try tv.Modify(id, "-Bold")
            }
        }
        this.HighlightedIds := []
        this.HighlightedIdx := 0
        this._DestroyJumpGui()
        ToolTip("Highlights cleared")
        SetTimer(() => ToolTip(), -navi.TOOLTIP_SUCCESS_DURATION)
    }
}
