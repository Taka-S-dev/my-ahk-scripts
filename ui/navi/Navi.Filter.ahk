#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Filter.ahk
; Description:  Navi ツリーフィルター & fd インデックスモジュール
;               - フォルダインデックスの非同期構築（fd.exe / loop files フォールバック）
;               - TreeView フィルタリング（AND/OR キーワード、300ms デバウンス）
;               - カスタムドロー着色（フィルタマッチノード・マークノード）
; Usage:        NaviFilter.Init(naviRef) を Navi.Init() から呼び出す
; ==============================================================================

class NaviFilter {
    static _navi := ""

    ; --- fd インデックス関連 ---
    static _FdIndexPid    := 0
    static _FdIndexFile   := ""
    static _FdIndexRoot   := ""
    static _FdIndexStartMs := 0
    static _FdIndexTimedOut := false
    static _FdPollCb      := ""
    static FD_INDEX_TIMEOUT_MS := 10000  ; インデックス構築タイムアウト(ms)

    ; --- フォルダインデックス ---
    static _FolderIndex       := []
    static _IndexedRoot       := ""
    static _OnIndexReadyCb    := ""
    static _indexBuildCallback := ""

    ; --- フィルタ制御 ---
    static _FilterRunning    := false  ; 再入防止フラグ
    static _FilterPending    := ""     ; 再入中に届いた最新クエリ
    static _FilterPendingSet := false  ; "" もクリア操作として区別するフラグ
    static _FilterCancelled  := false  ; ルート切り替え時に強制中止するフラグ
    static _treeFilterCallback := ""   ; デバウンス用コールバック参照

    ; --- ディレクトリ変更監視（FindFirstChangeNotification）---
    static _WatchHandle     := 0       ; 監視ハンドル
    static _WatchPollCb     := ""      ; 500ms ポーリングタイマー参照
    static _WatchInvCb      := ""      ; デバウンス無効化タイマー参照
    static WATCH_POLL_MS    := 500     ; ポーリング間隔(ms)
    static WATCH_DEBOUNCE_MS := 1000   ; 変更検知後のデバウンス時間(ms)

    ; --- カスタムドロー ---
    static _FilterMatchIdSet := Map()  ; マッチノードID集合
    static _FilterTvHwnd     := 0      ; カスタムドロー対象 TreeView の Hwnd
    static _FilterDrawHandler := ""    ; WM_NOTIFY ハンドラー参照
    static FILTER_MATCH_COLOR := 0x00CC5500  ; フィルタマッチ着色色 BGR: RGB(0,85,204)=青

    static Init(naviRef) {
        this._navi := naviRef
    }

    ; UNC パス（\\server\share）かどうかを返す
    static _IsNetworkPath(path) => (SubStr(path, 1, 2) == "\\")

    ; ==============================================================================
    ; フォルダインデックス構築
    ; ==============================================================================

    ; フォールバック: 同期 loop files でインデックスを構築する
    static _BuildFolderIndex(rootPath) {
        this._FolderIndex := []
        this._IndexedRoot := ""
        try {
            loop files, rootPath . "\*", "DR" {
                if (SubStr(A_LoopFileName, 1, 1) == "." || InStr(A_LoopFileAttrib, "H"))
                    continue
                this._FolderIndex.Push(A_LoopFilePath)
            }
        }
        this._IndexedRoot := rootPath
    }

    /**
     * fd.exe でフォルダ一覧を非同期列挙開始する
     * 戻り値: 成功=true、失敗=false（呼び出し元が _BuildFolderIndex にフォールバックする）
     */
    static _StartFolderIndexFd(rootPath, fdPath) {
        if (this._FdIndexPid != 0) {
            try ProcessClose(this._FdIndexPid)
            try FileDelete(this._FdIndexFile)
            this._FdIndexPid := 0
        }
        if (this._FdPollCb != "")
            SetTimer(this._FdPollCb, 0)
        nv := this._navi
        tmpFile  := A_Temp . "\navi_fidx_" . A_TickCount . ".txt"
        ; 末尾 \ をエスケープ（C ランタイムの \" 解析対策）
        safeRoot := (SubStr(rootPath, -1) = "\") ? rootPath . "\" : rootPath
        maxDepth := Integer(IniRead(nv.IniPath, "Search", "FilterMaxDepth", "8"))
        depthOpt := (maxDepth > 0) ? " --max-depth " . maxDepth : ""
        cmd := '"' . fdPath . '" --type d' . depthOpt . ' --no-ignore-vcs --color never --absolute-path . "' . safeRoot . '"'
        pid := NaviSearch._RunNoWindowToFile(cmd, tmpFile)
        if (pid = 0)
            return false
        this._FdIndexPid    := pid
        this._FdIndexFile   := tmpFile
        this._FdIndexRoot   := rootPath
        this._FdIndexStartMs := A_TickCount
        cb := () => this._PollFdIndex()
        this._FdPollCb := cb
        SetTimer(cb, 200)  ; 200ms ごとに完了チェック
        return true
    }

    /**
     * fd インデックス構築完了をポーリングするタイマーコールバック
     * 完了後に結果を読み込み、保留コールバックがあれば実行する
     */
    static _PollFdIndex() {
        nv := this._navi
        if (this._FdIndexPid = 0 || ProcessExist(this._FdIndexPid)) {
            ; タイムアウトチェック: 超過なら強制終了して部分結果を利用
            if (this._FdIndexPid != 0 && (A_TickCount - this._FdIndexStartMs) > this.FD_INDEX_TIMEOUT_MS) {
                try ProcessClose(this._FdIndexPid)
                this._FdIndexPid    := 0
                this._FdIndexTimedOut := true
            } else {
                ; 実行中: ステータスバーにアニメーションドットを表示
                try {
                    if (nv.GuiObj && WinExist(nv.GuiObj)) {
                        static dots  := [" .", " ..", " ..."]
                        static frame := 0
                        frame := Mod(frame, 3) + 1
                        nv.GuiObj._sbRef.SetText(" インデックス構築中" . dots[frame])
                    }
                }
                return
            }
        }
        ; 完了（正常 or タイムアウト）: タイマーを停止
        SetTimer(this._FdPollCb, 0)
        this._FdPollCb  := ""
        this._FdIndexPid := 0
        ; 結果を読み込んでインデックスを構築（fd は UTF-8 出力のため明示指定）
        this._FolderIndex := []
        try {
            raw := FileRead(this._FdIndexFile, "UTF-8")
            for line in StrSplit(raw, "`n", "`r") {
                p := Trim(line)
                if (p = "")
                    continue
                if (SubStr(p, -1) = "\" && StrLen(p) > 3)
                    p := SubStr(p, 1, -1)
                SplitPath(p, &fname)
                if (SubStr(fname, 1, 1) != ".")
                    this._FolderIndex.Push(p)
            }
        }
        try FileDelete(this._FdIndexFile)
        this._FdIndexFile := ""
        timedOut := this._FdIndexTimedOut
        this._FdIndexTimedOut := false
        this._IndexedRoot  := this._FdIndexRoot
        this._FdIndexRoot  := ""
        this._StartDirWatch(this._IndexedRoot)
        ; ステータスバーを通常表示に戻す（タイムアウト時は警告表示）
        if (timedOut) {
            try {
                if (nv.GuiObj && WinExist(nv.GuiObj))
                    nv.GuiObj._sbRef.SetText(" ⚠ インデックス構築タイムアウト（部分結果: " . this._FolderIndex.Length . " 件）")
            }
        } else {
            nv._UpdateStatusBar()
        }
        ; 保留コールバックがあれば実行（フィルタ再適用など）
        if (this._OnIndexReadyCb != "") {
            cb := this._OnIndexReadyCb
            this._OnIndexReadyCb := ""
            SetTimer(cb, -1)
        }
    }

    /**
     * fd プロセスと関連状態をすべてリセットする
     * ルート切り替え時や GUI 破棄時に呼ぶ
     */
    static CancelFdIndex() {
        if (this._FdIndexPid != 0) {
            try ProcessClose(this._FdIndexPid)
            try FileDelete(this._FdIndexFile)
            this._FdIndexPid  := 0
            this._FdIndexFile := ""
            this._FdIndexRoot := ""
        }
        if (this._FdPollCb != "")
            SetTimer(this._FdPollCb, 0)
        this._FdPollCb       := ""
        this._FdIndexTimedOut := false
        this._OnIndexReadyCb  := ""
    }

    /**
     * rootPath のフォルダインデックスを確保する
     * - 準備済み → true（インデックス利用可能）
     * - fd 非同期構築中/開始 → onReady を完了後コールバックに登録して false
     * - fd が使えない場合 → 同期構築して true
     */
    static _EnsureIndex(rootPath, onReady) {
        if (this._IndexedRoot == rootPath)
            return true
        if (this._FdIndexPid != 0 && this._FdIndexRoot == rootPath) {
            this._OnIndexReadyCb := onReady
            return false
        }
        ; ネットワークパスは fd を使用しない（サーバー負荷対策）
        useFd  := !this._IsNetworkPath(rootPath)
               && (IniRead(NaviSearch.IniPath, "Search", "UseFdForFilter", "1") != "0")
        fdPath := useFd ? NaviSearch._FindFd() : ""
        if (fdPath != "" && this._StartFolderIndexFd(rootPath, fdPath)) {
            this._OnIndexReadyCb := onReady
            return false
        }
        ; フォールバック: 同期 loop files
        this._BuildFolderIndex(rootPath)
        this._StartDirWatch(rootPath)
        return true
    }

    /**
     * フォルダインデックスを先読み構築する（_RefreshTree の 800ms タイマーから呼ばれる）
     */
    static PrefetchFolderIndex(rootPath) {
        ; ネットワークパスは自動インデックス構築をスキップ（サーバー負荷対策）
        if (this._IsNetworkPath(rootPath))
            return
        if (this._IndexedRoot == rootPath || (this._FdIndexPid != 0 && this._FdIndexRoot == rootPath))
            return
        this._EnsureIndex(rootPath, () => "")
    }

    /**
     * ルート変更時にフィルタ関連状態をすべてリセットする（_RefreshTree から呼ばれる）
     */
    static ResetForNewRoot() {
        this.CancelFdIndex()
        this._StopDirWatch()
        this._FilterCancelled  := true
        this._FilterRunning    := false
        this._FilterPendingSet := false
        this._FilterPending    := ""
        this._IndexedRoot      := ""
        this._FolderIndex      := []
    }

    /**
     * デバウンスタイマーとインデックス先読みタイマーを停止する（_DestroyGui から呼ばれる）
     */
    static CancelDebounce() {
        if (this._treeFilterCallback != "") {
            SetTimer(this._treeFilterCallback, 0)
            this._treeFilterCallback := ""
        }
        if (this._indexBuildCallback != "") {
            SetTimer(this._indexBuildCallback, 0)
            this._indexBuildCallback := ""
        }
        this._StopDirWatch()
    }

    ; ==============================================================================
    ; ディレクトリ変更監視（FindFirstChangeNotification + SetTimer ポーリング）
    ; ネットワークパス非対応のため _IsNetworkPath チェックで除外する
    ; ==============================================================================

    /**
     * rootPath の監視を開始する（インデックス構築完了後に呼ぶ）
     * FILE_NOTIFY_CHANGE_DIR_NAME(0x2) のみ監視してフォルダ作成/削除/改名を検知する
     */
    static _StartDirWatch(rootPath) {
        this._StopDirWatch()
        if (this._IsNetworkPath(rootPath))
            return
        h := DllCall("FindFirstChangeNotificationW", "Str", rootPath, "Int", 1, "UInt", 0x2, "Ptr")
        if (!h || h = -1)
            return
        this._WatchHandle := h
        cb := () => this._PollDirWatch()
        this._WatchPollCb := cb
        SetTimer(cb, this.WATCH_POLL_MS)
    }

    ; ポーリングタイマー: 変更を検知したらデバウンスタイマーをセット
    static _PollDirWatch() {
        if (this._WatchHandle = 0)
            return
        if (DllCall("WaitForSingleObject", "Ptr", this._WatchHandle, "UInt", 0) != 0)
            return
        DllCall("FindNextChangeNotification", "Ptr", this._WatchHandle)
        ; 連続変更をまとめるデバウンス（既存タイマーはリセット）
        if (this._WatchInvCb != "")
            SetTimer(this._WatchInvCb, 0)
        cb := () => this._InvalidateIndex()
        this._WatchInvCb := cb
        SetTimer(cb, -this.WATCH_DEBOUNCE_MS)
    }

    ; インデックスを無効化し、フィルタ入力中なら自動再適用する
    static _InvalidateIndex() {
        this._WatchInvCb  := ""
        this._IndexedRoot := ""
        this._FolderIndex := []
        nv := this._navi
        try {
            if (nv.GuiObj && WinExist(nv.GuiObj)) {
                query := nv.GuiObj["TreeFilter"].Value
                if (Trim(query) != "")
                    SetTimer(() => this.ApplyTreeFilter(query), -1)
            }
        }
    }

    ; 監視を停止してハンドルを解放する
    static _StopDirWatch() {
        if (this._WatchPollCb != "")
            SetTimer(this._WatchPollCb, 0)
        if (this._WatchInvCb != "")
            SetTimer(this._WatchInvCb, 0)
        this._WatchPollCb := ""
        this._WatchInvCb  := ""
        if (this._WatchHandle != 0) {
            DllCall("FindCloseChangeNotification", "Ptr", this._WatchHandle)
            this._WatchHandle := 0
        }
    }

    ; ==============================================================================
    ; ツリーフィルタリング
    ; ==============================================================================

    /**
     * ツリーフィルター入力変更: 300ms デバウンスで ApplyTreeFilter を呼ぶ
     */
    static OnTreeFilterChange() {
        nv := this._navi
        if (nv._SearchMode)
            return
        if (this._treeFilterCallback != "")
            SetTimer(this._treeFilterCallback, 0)
        query := nv.GuiObj["TreeFilter"].Value
        cb := () => this.ApplyTreeFilter(query)
        this._treeFilterCallback := cb
        SetTimer(cb, -300)  ; 300ms デバウンス
    }

    /**
     * ツリーフィルター適用: query が空なら通常ツリーに戻す、あれば再帰検索してツリー再構築
     * 再入防止: _FilterRunning フラグで二重実行を防ぎ、最新クエリを _FilterPending に保留して処理する
     */
    static ApplyTreeFilter(query) {
        nv := this._navi
        this._treeFilterCallback := ""
        this._FilterCancelled    := false
        ; 再入防止: 実行中なら最新クエリを保留して即リターン
        if (this._FilterRunning) {
            this._FilterPending    := query
            this._FilterPendingSet := true
            return
        }
        this._FilterRunning    := true
        this._FilterPendingSet := false
        this._FilterPending    := ""
        try {
            if !(nv.GuiObj && WinExist(nv.GuiObj))
                return
            tv       := nv.GuiObj["FolderTree"]
            rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
            if (rootPath == "")
                return
            if (Trim(query) == "") {
                this._FilterMatchIdSet := Map()
                ; フィルタクリア時は fd 完了後の再適用を防ぐためコールバックをリセット
                this._OnIndexReadyCb := ""
                nv._RefreshTree(tv, rootPath, false)
                return
            }
            ; スペース区切り=AND、"|"区切り=OR でターム分割
            terms := []
            for t in StrSplit(query, " ") {
                if (Trim(t) != "")
                    terms.Push(StrSplit(Trim(t), "|"))  ; 各要素は OR 候補の配列
            }
            ; キャッシュが古ければ再構築
            if (this._IndexedRoot != rootPath) {
                ; fd 完了後コールバック: フィルタを再スケジュール
                onReady := () => SetTimer(() => this.ApplyTreeFilter(query), -1)
                if !this._EnsureIndex(rootPath, onReady) {
                    ; fd 非同期待ち: 完了後に _OnIndexReadyCb が再実行する
                    this._FilterPendingSet := false
                    return
                }
            }
            ; キャッシュからメモリ内検索（最後のタームはフォルダ名に、それ以前はパス全体にマッチ）
            ; 例: "myapp src" → パスに "myapp" を含み、かつフォルダ名に "src" を含む
            lastTermIdx := terms.Length
            results := []
            for fullPath in this._FolderIndex {
                SplitPath(fullPath, &fname)
                matched := true
                for tIdx, orGroup in terms {
                    target      := (tIdx = lastTermIdx) ? fname : fullPath
                    groupMatched := false
                    for alt in orGroup {
                        if (alt != "" && InStr(target, alt, false)) {
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
            nv.FilesShown          := Map()
            this._FilterMatchIdSet := Map()
            NaviMark._MarkFilterActive := false
            NaviSearch._HighlightedIdSet := Map()
            if (results.Length == 0) {
                tv.Add("(一致なし)", 0)
                return
            }
            ; 結果件数が多すぎると tv.Add ループが GUI を長時間ブロックするためキャップする
            static filterResultCap := 300
            tooMany := results.Length > filterResultCap
            if (tooMany)
                results.Length := filterResultCap
            rootBase := RTrim(rootPath, "\")
            rootID   := tv.Add(rootPath, 0, "Expand Icon1")
            if (tooMany)
                tv.Add("… 上位 " . filterResultCap . " 件を表示（キーワードを追加して絞り込んでください）", rootID)
            addedPaths := Map()
            addedPaths[StrLower(rootBase)] := rootID
            firstMatch := true
            for idx, fullPath in results {
                if (this._FilterCancelled)
                    return
                rel   := SubStr(fullPath, StrLen(rootBase) + 2)
                parts := StrSplit(rel, "\")
                parentID    := rootID
                currentPath := rootBase
                for i, part in parts {
                    currentPath .= "\" . part
                    key     := StrLower(currentPath)
                    isMatch := (i == parts.Length)
                    if addedPaths.Has(key) {
                        existingID := addedPaths[key]
                        ; 既存ノードが今回の結果ではマッチノードになる場合は着色対象に追加
                        if (isMatch && !this._FilterMatchIdSet.Has(existingID))
                            this._FilterMatchIdSet[existingID] := true
                        ; このノードに実の子が追加される: プレースホルダーのみなら削除
                        firstChild := tv.GetChild(existingID)
                        if (firstChild != 0 && tv.GetText(firstChild) == "...loading..." && tv.GetNext(firstChild) == 0)
                            tv.Delete(firstChild)
                        parentID := existingID
                    } else {
                        opts := isMatch ? "Bold" : ""
                        if (isMatch && firstMatch) {
                            opts      .= " Select"
                            firstMatch := false
                        }
                        nodeID := tv.Add(part, parentID, opts . " Icon1")
                        if (isMatch) {
                            this._FilterMatchIdSet[nodeID] := true
                            tv.Add("...loading...", nodeID)  ; ノード作成直後に追加して展開ボタンを即表示
                        }
                        addedPaths[key] := nodeID
                        parentID        := nodeID
                    }
                }
                ; 50件ごとに GUI イベントを処理してUIの応答性を保つ
                if (Mod(idx, 50) = 0)
                    Sleep(0)
            }
            ; 子を持つノードを展開（"...loading..." プレースホルダーのみのノードは展開しない）
            for _, nodeID in addedPaths {
                if (nodeID == rootID)
                    continue
                child := tv.GetChild(nodeID)
                if (child != 0 && tv.GetText(child) != "...loading...")
                    tv.Modify(nodeID, "Expand")
            }
            this.EnsureFilterDraw(tv)
            ; ファイル表示モードがONならフィルタ結果の各フォルダにもファイルを表示
            if (nv.GuiObj["AutoFilesCheck"].Value) {
                fileMax := 200
                try fileMax := Integer(IniRead(nv.IniPath, "Settings", "FileMax", "200"))
                rootKey     := StrLower(rootBase)
                folderCount := 0
                for folderKey, nodeID in addedPaths {
                    if (this._FilterCancelled)
                        return
                    if (folderKey == rootKey)
                        continue
                    shown := []
                    count := 0
                    try {
                        loop files, folderKey . "\*", "F" {
                            if InStr(A_LoopFileAttrib, "H")
                                continue
                            shown.Push(tv.Add(A_LoopFileName, nodeID, nv._GetFileIconStr(A_LoopFileName)))
                            if (++count >= fileMax)
                                break
                        }
                    }
                    if (shown.Length > 0)
                        nv.FilesShown[nodeID] := shown
                    ; 20フォルダごとに GUI イベントを処理
                    if (++folderCount >= 20) {
                        folderCount := 0
                        Sleep(0)
                    }
                }
            }
            ; フィルタ結果の上にマーク色を復元
            NaviMark._RebuildMarkedIdSet(tv)
        } catch Any {
            ; GUI 破棄など想定内の例外は無視して finally でクリーンアップ
        } finally {
            this._FilterRunning := false
            ; 保留クエリがあれば次のイベントループで処理（"" もクリア操作として正しく処理）
            if (this._FilterPendingSet) {
                pending := this._FilterPending
                this._FilterPending    := ""
                this._FilterPendingSet := false
                SetTimer(() => this.ApplyTreeFilter(pending), -1)
            }
        }
    }

    ; ==============================================================================
    ; カスタムドロー（フィルタマッチ着色）
    ; ==============================================================================

    ; フィルタマッチ着色カスタムドロー登録（初回のみ）
    static EnsureFilterDraw(tv) {
        this._FilterTvHwnd := tv.Hwnd
        if (this._FilterDrawHandler != "")
            return
        handler := (w, l, m, h) => NaviFilter._OnFilterNotify(w, l, m, h)
        OnMessage(NaviFilter._navi.WM_NOTIFY, handler)
        this._FilterDrawHandler := handler
    }

    ; WM_NOTIFY → NM_CUSTOMDRAW ハンドラー（フィルタマッチノードの着色）
    ; NaviSearch の検索ハイライトハンドラーと共存: マッチ無しは "" を返し次のハンドラーへ委譲
    static _OnFilterNotify(wParam, lParam, msg, hwnd) {
        if (NumGet(lParam, 0, "ptr") != NaviFilter._FilterTvHwnd)
            return
        if (NumGet(lParam, A_PtrSize * 2, "int") != -12)  ; NM_CUSTOMDRAW
            return
        stageOff := (A_PtrSize = 8) ? 24 : 12
        stage    := NumGet(lParam, stageOff, "uint")
        if (stage = 0x1) {  ; CDDS_PREPAINT
            return (NaviFilter._FilterMatchIdSet.Count > 0 || NaviMark._MarkedIdSet.Count > 0) ? 0x20 : ""
        }
        if (stage = 0x10001) {  ; CDDS_ITEMPREPAINT
            specOff := (A_PtrSize = 8) ? 56 : 36
            itemId  := NumGet(lParam, specOff, "ptr")
            clrOff  := (A_PtrSize = 8) ? 80 : 48
            ; マーク色はフィルタマッチ色より優先
            if (NaviMark._MarkedIdSet.Has(itemId)) {
                NumPut("uint", NaviMark.MARK_COLOR, lParam, clrOff)
                return 0
            }
            if (NaviFilter._FilterMatchIdSet.Has(itemId)) {
                NumPut("uint", NaviFilter.FILTER_MATCH_COLOR, lParam, clrOff)
                return 0
            }
        }
    }

    /**
     * フィルタマッチノード間を F3 / Shift+F3 でジャンプ
     * dir: +1=次, -1=前
     */
    static JumpToMatch(tv, dir) {
        if (this._FilterMatchIdSet.Count == 0)
            return
        ; ツリー順にマッチノードを収集
        matches := []
        id := tv.GetNext(0, "Full")
        while (id != 0) {
            if (this._FilterMatchIdSet.Has(id))
                matches.Push(id)
            id := tv.GetNext(id, "Full")
        }
        if (matches.Length == 0)
            return
        ; 現在の選択位置を探す（フィルタ入力中は先頭からスタート）
        selID  := this._navi._TreeFilterFocused ? 0 : tv.GetSelection()
        curIdx := 0
        for i, mid in matches {
            if (mid == selID) {
                curIdx := i
                break
            }
        }
        ; 循環ジャンプ
        if (dir > 0)
            nextIdx := (curIdx == 0 || curIdx >= matches.Length) ? 1 : curIdx + 1
        else
            nextIdx := (curIdx <= 1) ? matches.Length : curIdx - 1
        tv.Modify(matches[nextIdx], "Select Vis")
        tv.Focus()
    }
}
