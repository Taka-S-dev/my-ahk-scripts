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

    ; --- ディレクトリ変更監視（ReadDirectoryChangesW + Overlapped I/O）---
    static _DirHandle     := 0    ; CreateFile ハンドル
    static _DirEvent      := 0    ; OVERLAPPED 用イベントハンドル
    static _DirOvBuf      := ""   ; OVERLAPPED 構造体バッファ（操作中は解放不可）
    static _DirNotifyBuf  := ""   ; ReadDirectoryChangesW 通知バッファ（同上）
    static _WatchPollCb   := ""   ; 500ms ポーリングタイマー参照
    static _WatchInvCb    := ""   ; デバウンス無効化タイマー参照
    static WATCH_POLL_MS    := 500
    static WATCH_DEBOUNCE_MS := 1000

    ; --- カスタムドロー ---
    static _FilterMatchIdSet := Map()  ; マッチノードID集合
    static _netDenied := Map()         ; ツリーの絞り込みで「読まない」と答えたネットワーク上のルート（小文字のパス）
    static MessageNodeId := 0         ; 「(一致なし)」など案内の行のノード（フォルダではない）

    static Init(naviRef) {
        this._navi := naviRef
    }

    ; ネットワーク上のフォルダか（UNC パス \\server\share か、ネットワークドライブに割り当てたドライブ文字）
    ; 配下を再帰的に読む処理（先読み・fd・変更監視）は、サーバー負荷を避けるためこれが真なら止める
    static IsOnNetwork(path) {
        if (SubStr(path, 1, 2) == "\\")
            return true
        if !RegExMatch(path, "^[A-Za-z]:")
            return false
        try {
            return DriveGetType(SubStr(path, 1, 2) . "\") == "Network"
        } catch {
            return false  ; 存在しないドライブ
        }
    }

    ; ==============================================================================
    ; フォルダインデックス構築
    ; ==============================================================================

    ; フォールバック（fd がない・ネットワーク上）: 同期でたどってインデックスを構築する
    static _BuildFolderIndex(rootPath) {
        this._FolderIndex := []
        this._IndexedRoot := ""
        this._FolderIndex := this.WalkTree(rootPath, "D")
        this._IndexedRoot := rootPath
    }

    /**
     * fd を使わずに rootPath の下をたどり、フォルダ（kind = "D"）かファイル（"F"）のフルパスを返す
     * fd の既定と同じ範囲にそろえる（fd があるかどうかで一覧の中身が変わらないように）:
     * - . で始まるもの・隠し属性のものは、フォルダなら中身ごと除く（.git や AppData の中身を集めない）
     * - シンボリックリンク・ジャンクションのフォルダは出さず、先にもたどらない（fd の --type d と同じ。
     *   同じ場所を二重に数えたり、ぐるぐる回ったりしない）
     * cap > 0 ならその件数で打ち切る
     */
    static WalkTree(rootPath, kind, cap := 0) {
        out := []
        ; 組み込みの再帰（R）でたどる（フォルダごとに loop を回すより速い）。フォルダは中身より先に来るので、
        ; 除いたフォルダ・中に入らないフォルダを覚えておき、その下にあるものは親を見て飛ばす
        skipUnder := Map()  ; この下は集めないフォルダのパス
        skipUnder.CaseSense := false
        try {
            loop files, RTrim(rootPath, "\") . "\*", "FDR" {
                isDir := InStr(A_LoopFileAttrib, "D")
                if skipUnder.Has(A_LoopFileDir) {
                    if isDir
                        skipUnder[A_LoopFilePath] := true
                    continue
                }
                if (SubStr(A_LoopFileName, 1, 1) == "." || InStr(A_LoopFileAttrib, "H")) {
                    if isDir
                        skipUnder[A_LoopFilePath] := true
                    continue
                }
                if isDir {
                    if InStr(A_LoopFileAttrib, "L") {  ; L = リパースポイント（リンク）。fd の --type d と同じく、出さず中にも入らない
                        skipUnder[A_LoopFilePath] := true
                        continue
                    }
                    if (kind == "D")
                        out.Push(A_LoopFilePath)
                } else if (kind == "F") {
                    out.Push(A_LoopFilePath)
                }
                if (cap > 0 && out.Length >= cap)
                    return out
            }
        }
        return out
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
        ; 深さは制限せずに集める（一覧は全部から探す。ツリーの絞り込みの深さは ApplyTreeFilter で絞る）
        ; 集めすぎは FD_INDEX_TIMEOUT_MS の打ち切りで防ぐ
        cmd := '"' . fdPath . '" --type d --no-ignore-vcs --color never --absolute-path . "' . safeRoot . '"'
        pid := NaviFd._RunNoWindowToFile(cmd, tmpFile)
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
        useFd  := !this.IsOnNetwork(rootPath)
               && (IniRead(NaviFd.IniPath, "Search", "UseFdForFilter", "1") != "0")
        fdPath := useFd ? NaviFd._FindFd() : ""
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
        if (this.IsOnNetwork(rootPath))
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
    }

    ; ==============================================================================
    ; ディレクトリ変更監視（FindFirstChangeNotification + SetTimer ポーリング）
    ; ネットワークパス非対応のため IsOnNetwork で除外する
    ; ==============================================================================

    /**
     * rootPath の監視を開始する（インデックス構築完了後に呼ぶ）
     * CreateFile + ReadDirectoryChangesW + Overlapped I/O で
     * FILE_NOTIFY_CHANGE_DIR_NAME のみ監視する
     */
    static _StartDirWatch(rootPath) {
        this._StopDirWatch()
        if (this.IsOnNetwork(rootPath))
            return
        ; ディレクトリハンドルを開く（FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED）
        hDir := DllCall("CreateFileW"
            , "Str",  rootPath
            , "UInt", 0x00000001    ; FILE_LIST_DIRECTORY
            , "UInt", 0x00000007    ; FILE_SHARE_READ | WRITE | DELETE
            , "Ptr",  0
            , "UInt", 3             ; OPEN_EXISTING
            , "UInt", 0x42000000    ; FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED
            , "Ptr",  0, "Ptr")
        if (!hDir || hDir = -1)
            return
        ; 自動リセットイベント（WaitForSingleObject が検知と同時にリセット）
        hEvent := DllCall("CreateEventW", "Ptr", 0, "Int", 0, "Int", 0, "Ptr", 0, "Ptr")
        if (!hEvent) {
            DllCall("CloseHandle", "Ptr", hDir)
            return
        }
        ; OVERLAPPED 構造体（hEvent オフセット: 64bit=24, 32bit=16）
        ovBuf     := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
        NumPut("Ptr", hEvent, ovBuf, A_PtrSize = 8 ? 24 : 16)
        notifyBuf := Buffer(4096, 0)
        ; 非同期 ReadDirectoryChangesW を発行
        ok := DllCall("ReadDirectoryChangesW"
            , "Ptr",  hDir
            , "Ptr",  notifyBuf
            , "UInt", notifyBuf.Size
            , "Int",  1             ; bWatchSubtree
            , "UInt", 0x00000002    ; FILE_NOTIFY_CHANGE_DIR_NAME
            , "UInt*", 0
            , "Ptr",  ovBuf
            , "Ptr",  0, "Int")
        if (!ok) {
            DllCall("CloseHandle", "Ptr", hEvent)
            DllCall("CloseHandle", "Ptr", hDir)
            return
        }
        this._DirHandle    := hDir
        this._DirEvent     := hEvent
        this._DirOvBuf     := ovBuf
        this._DirNotifyBuf := notifyBuf
        cb := () => this._PollDirWatch()
        this._WatchPollCb := cb
        SetTimer(cb, this.WATCH_POLL_MS)
    }

    ; ポーリングタイマー: イベント検知→再発行→デバウンス
    static _PollDirWatch() {
        if (this._DirHandle = 0)
            return
        ; 自動リセットイベントをノンブロッキングで確認
        if (DllCall("WaitForSingleObject", "Ptr", this._DirEvent, "UInt", 0) != 0)
            return
        ; 変更を検知: 次の変更に備えて ReadDirectoryChangesW を再発行
        DllCall("ReadDirectoryChangesW"
            , "Ptr",  this._DirHandle
            , "Ptr",  this._DirNotifyBuf
            , "UInt", this._DirNotifyBuf.Size
            , "Int",  1
            , "UInt", 0x00000002
            , "UInt*", 0
            , "Ptr",  this._DirOvBuf
            , "Ptr",  0, "Int")
        ; 変更検知と同時にインデックスを即時無効化（フィルター入力が古いインデックスを使わないよう）
        this._IndexedRoot := ""
        this._FolderIndex := []
        ; デバウンス: フィルター自動再適用のタイミング制御のみ
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

    ; 監視を停止してハンドルをすべて解放する
    static _StopDirWatch() {
        if (this._WatchPollCb != "")
            SetTimer(this._WatchPollCb, 0)
        if (this._WatchInvCb != "")
            SetTimer(this._WatchInvCb, 0)
        this._WatchPollCb := ""
        this._WatchInvCb  := ""
        if (this._DirHandle != 0) {
            DllCall("CancelIo", "Ptr", this._DirHandle)
            DllCall("CloseHandle", "Ptr", this._DirHandle)
            this._DirHandle := 0
        }
        if (this._DirEvent != 0) {
            DllCall("CloseHandle", "Ptr", this._DirEvent)
            this._DirEvent := 0
        }
        this._DirOvBuf    := ""
        this._DirNotifyBuf := ""
    }

    ; ==============================================================================
    ; ツリーフィルタリング
    ; ==============================================================================

    /**
     * ツリーフィルター入力変更: 300ms デバウンスで ApplyTreeFilter を呼ぶ
     */
    static OnTreeFilterChange() {
        nv := this._navi
        if (this._treeFilterCallback != "")
            SetTimer(this._treeFilterCallback, 0)
        query := nv.GuiObj["TreeFilter"].Value
        cb := () => this.ApplyTreeFilter(query)
        this._treeFilterCallback := cb
        ; ツリー再構築は重いので 300ms 待つ。リストは軽いので打鍵に追従させる
        SetTimer(cb, (NaviDirList.Active || NaviBrowse.Active) ? -NaviDirList.DEBOUNCE_MS : -300)
    }

    /**
     * ツリーフィルター適用: query が空なら通常ツリーに戻す、あれば再帰検索してツリー再構築
     * 再入防止: _FilterRunning フラグで二重実行を防ぎ、最新クエリを _FilterPending に保留して処理する
     */
    static ApplyTreeFilter(query) {
        nv := this._navi
        this._treeFilterCallback := ""
        ; 3 列表示中は中央の列を絞り込む
        if (NaviBrowse.Active) {
            NaviBrowse.ApplyFilter(query)
            return
        }
        ; リスト表示中はツリーではなくリストを絞り込む
        if (NaviDirList.Active) {
            NaviDirList.Apply(query)
            return
        }
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
            ; 先頭の ' は一覧（あいまい一致）で「続けて並んだものだけ」の印。ツリーはもともと続けて並んだものだけに
            ; 一致するので、外して同じ意味にする（同じ入力欄で、表示によって書き方の意味が変わらないように）
            terms := []
            for t in StrSplit(query, " ") {
                alts := []
                for alt in StrSplit(Trim(t), "|") {
                    alt := LTrim(alt, "'")
                    if (alt != "")
                        alts.Push(alt)
                }
                if (alts.Length > 0)
                    terms.Push(alts)  ; 各要素は OR 候補の配列
            }
            if (terms.Length == 0) {  ; ' だけなど、探す文字がない
                this._ShowTreeMessage(tv, "(一致なし)")
                return
            }
            ; 絞り込む対象（入力欄の左のボタン）: フォルダ / ファイル / 両方
            kind := nv._FilterKind
            wantDirs := (kind != "file"), wantFiles := (kind != "dir")
            ; ネットワーク上のルートは、配下を全部読みに行く前に確かめる（一覧と同じ。サーバーの負荷対策）
            needDirs := wantDirs && this._IndexedRoot != rootPath
            needFiles := wantFiles && NaviDirList._FileIndexedRoot != rootPath
                && !(NaviDirList._FilePid != 0 && NaviDirList._FileRoot == rootPath)
            if ((needDirs || needFiles) && !this._ConfirmNetwork(tv, rootPath
                , (needDirs && needFiles) ? "フォルダとファイル" : needDirs ? "フォルダ" : "ファイル"))
                return
            ; キャッシュが古ければ再構築
            if (wantDirs && this._IndexedRoot != rootPath) {
                ; fd 完了後コールバック: フィルタを再スケジュール
                onReady := () => SetTimer(() => this.ApplyTreeFilter(query), -1)
                if !this._EnsureIndex(rootPath, onReady) {
                    ; fd 非同期待ち: 完了後に _OnIndexReadyCb が再実行する
                    this._FilterPendingSet := false
                    return
                }
            }
            ; ファイルの索引は一覧（NaviDirList）と共用。集め終わったら ReapplyTree でここをやり直す
            if (wantFiles && NaviDirList._FileIndexedRoot != rootPath) {
                if !NaviDirList._EnsureFileIndex(rootPath) {
                    this._ShowTreeMessage(tv, "ファイルを集めています…")
                    return
                }
            }
            ; キャッシュからメモリ内検索（最後のタームは名前に、それ以前はパス全体にマッチ）
            ; 例: "myapp src" → パスに "myapp" を含み、かつ名前に "src" を含む
            ; ツリーの絞り込みは設定の深さまで（ルート直下が 1。0 は無制限）。索引は一覧と共用なので深さはここで絞る
            maxDepth := Integer(IniRead(nv.IniPath, "Search", "FilterMaxDepth", "8"))
            rootLen := StrLen(RTrim(rootPath, "\"))
            results := []  ; [{ path, isFile }]。フォルダを先に並べる（ツリーでもフォルダがファイルより上に来るように）
            for spec in [[wantDirs, this._FolderIndex, false], [wantFiles, NaviDirList._FileIndex, true]] {
                if !spec[1]
                    continue
                for fullPath in spec[2] {
                    ; 深さはフォルダだけに効かせる（ファイルは深い所にあるものほど探したいので、全部から探す）
                    if (maxDepth > 0 && !spec[3]) {
                        StrReplace(SubStr(fullPath, rootLen + 2), "\", , , &depth)
                        if (depth + 1 > maxDepth)
                            continue
                    }
                    if this._TermsMatch(fullPath, terms)
                        results.Push({ path: fullPath, isFile: spec[3] })
                }
            }
            ; ツリー再構築
            tv.Delete()
            nv.FilesShown          := Map()
            this._FilterMatchIdSet := Map()
            NaviMark._MarkFilterActive := false
            if (results.Length == 0) {
                this._ShowTreeMessage(tv, "(一致なし)")
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
                tv.Add("… 上位 " . filterResultCap . " 件を表示（キーワードを足すか、一覧 Ctrl+E で探してください）", rootID)
            addedPaths := Map()
            addedPaths[StrLower(rootBase)] := rootID
            firstMatchID := 0
            fileMatchIds := Map()  ; 一致したファイルのノード（中身を読みに行かない）
            for idx, res in results {
                if (this._FilterCancelled)
                    return
                fullPath := res.path
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
                        ; 先頭マッチに Select を付け、ノードIDを記録（末尾で可視化に使用）
                        if (isMatch && firstMatchID == 0)
                            opts .= " Select"
                        isFileNode := isMatch && res.isFile
                        nodeID := tv.Add(part, parentID, opts . " " . (isFileNode ? nv._GetFileIconStr(part) : "Icon1"))
                        if (isMatch && firstMatchID == 0)
                            firstMatchID := nodeID
                        if (isFileNode) {
                            this._FilterMatchIdSet[nodeID] := true
                            fileMatchIds[nodeID] := true
                            ; 親フォルダに「ファイルを表示済み」として登録し、展開したときに同じファイルを重ねて足さない
                            if !nv.FilesShown.Has(parentID)
                                nv.FilesShown[parentID] := []
                            nv.FilesShown[parentID].Push(nodeID)
                        } else if (isMatch) {
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
            ; マッチしたフォルダの実子フォルダを自動表示（フィルタにマッチしない兄弟も含めて表示）
            matchLoopCount := 0
            for matchID, _ in this._FilterMatchIdSet {
                if (this._FilterCancelled)
                    return
                if fileMatchIds.Has(matchID)
                    continue
                ; "...loading..." プレースホルダーを削除してから実子をロード
                placeholder := tv.GetChild(matchID)
                if (placeholder != 0 && tv.GetText(placeholder) == "...loading...")
                    tv.Delete(placeholder)
                nv._LoadFilterSub(tv, matchID)
                if (Mod(++matchLoopCount, 20) == 0)
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
            ; （ファイルも絞り込んでいるときは、一致したファイルだけを見せたいので足さない）
            if (nv.GuiObj["AutoFilesCheck"].Value && !wantFiles) {
                fileMax := 200
                try fileMax := Integer(IniRead(nv.IniPath, "Settings", "FileMax", "200"))
                rootKey     := StrLower(rootBase)
                folderCount := 0
                for folderKey, nodeID in addedPaths {
                    if (this._FilterCancelled)
                        return
                    ; 一致したフォルダは _LoadFilterSub の時点でファイルを表示済みなので、重ねて足さない
                    if (folderKey == rootKey || nv.FilesShown.Has(nodeID))
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
            ; 実子ロード・展開・ファイル表示で下方向にスクロールし先頭マッチが
            ; 上端で見切れるのを防ぐため、最後に先頭マッチを完全可視化する
            if (firstMatchID != 0)
                tv.Modify(firstMatchID, "Vis")
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

    /**
     * fullPath が terms（スペース区切り = AND、| 区切り = OR）に一致するか
     * 最後のタームは名前に、それ以前はパス全体に、続けて含まれるかで見る（ツリーはあいまい一致にしない。
     * 関係の薄いフォルダまで大量に開いて見づらくなるため。あいまい一致は一覧 Ctrl+E の役目）
     */
    static _TermsMatch(fullPath, terms) {
        ; 名前に含まれるならパスにも含まれるので、まずパス全体で振り落とす（20 万件を毎回 SplitPath すると遅い）
        for orGroup in terms {
            groupMatched := false
            for alt in orGroup {
                if (alt != "" && InStr(fullPath, alt, false)) {
                    groupMatched := true
                    break
                }
            }
            if !groupMatched
                return false
        }
        ; 残ったものだけ、最後のタームが名前に含まれるかを見る
        SplitPath(fullPath, &name)
        for alt in terms[terms.Length] {
            if (alt != "" && InStr(name, alt, false))
                return true
        }
        return false
    }

    /**
     * ツリーの絞り込みで、ネットワーク上のルートの配下（what）を読んでよいか確かめる
     * 打つたびに絞り込み直すので、「いいえ」は Navi を閉じるまで覚え、そのルートでは聞き直さずに絞り込まない
     */
    static _ConfirmNetwork(tv, rootPath, what) {
        key := StrLower(rootPath)
        if (NaviDirList._netAllowed.Has(key) || !this.IsOnNetwork(rootPath))  ; 一覧で「はい」と答えていれば読む
            return true
        if this._netDenied.Has(key) {
            this._ShowTreeMessage(tv, "ネットワーク上のフォルダなので絞り込みません（Navi を開き直すと、もう一度確かめます）")
            return false
        }
        this._ShowTreeMessage(tv, "ネットワーク上のフォルダです")
        ans := NaviDirList.AskNetwork(rootPath, what)
        if (ans == 0) {
            this._netDenied[key] := true
            this._ShowTreeMessage(tv, "ネットワーク上のフォルダなので絞り込みません（Navi を開き直すと、もう一度確かめます）")
        }
        return (ans == 1)
    }

    ; ツリーを空にして、案内の行を 1 つだけ出す（アイコンなし。パスの行には出さない: MessageNodeId）
    static _ShowTreeMessage(tv, msg) {
        tv.Delete()
        this._navi.FilesShown := Map()
        this._FilterMatchIdSet := Map()
        this.MessageNodeId := tv.Add(msg, 0, "Icon9999")  ; 画像リストにない番号でアイコンを出さない（TreeView は Icon0 だと 1 番目の絵になる）
    }

    /** ファイルの索引ができたとき: ツリーでファイルを絞り込んでいる最中なら、その文字でやり直す */
    static ReapplyTree() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj)) || NaviDirList.Active || NaviBrowse.Active || nv._FilterKind == "dir"
            return
        query := nv.GuiObj["TreeFilter"].Value
        if (Trim(query) != "")
            this.ApplyTreeFilter(query)
    }

    ; ==============================================================================
    ; カスタムドロー（フィルタマッチ着色）
    ; ==============================================================================

    ; 着色は NaviTreeDraw がまとめて行う（一致したノードは _FilterMatchIdSet を参照）
    static EnsureFilterDraw(tv) {
        NaviTreeDraw.Attach(tv)
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
