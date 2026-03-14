#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Search.ahk
; Description:  Navi用ローカル再帰検索モジュール
;               - 非同期タイマーでディレクトリ走査（GUI応答を阻害しない）
;               - TreeView上のヒットを強調し、Prev/Nextでジャンプ
;               - 親GUI終了時に検索ウィンドウを自動クローズ
; Query:        スペース=AND / | = OR / ! = NOT / *.ext = 拡張子 / d: = ディレクトリ / f: = ファイル
; Example:      "src | lib !test" → (src OR lib) AND NOT test
;               "*.js|*.ts" → .js または .ts で終わるファイル
;               "d: src" → srcを含むディレクトリのみ
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
    static LastSearchBasePath := ""  ; 再検索用に最後の検索ルートを保持
    static _ParentWatchFn := ""
    static Results := []           ; 検索結果のフルパス一覧
    static JumpListView := ""      ; 一体型ウィンドウのListViewへの参照
    static _HighlightedPaths := [] ; HighlightedIds と同順のパス一覧（リスト同期用）
    static _HighlightedIdSet := Map()  ; カスタムドロー用 O(1) ルックアップ
    static _CustomDrawHandler := ""    ; WM_NOTIFY ハンドラー参照
    static _CustomDrawTvHwnd := 0      ; 対象TreeViewのHwnd
    static _NaviRef          := ""     ; Navi インスタンス参照（#Warn 回避用）
    static HIGHLIGHT_COLOR := 0x0000A5FF ; ハイライト色(COLORREF) = オレンジ R255 G165 B0

    ; 調整可能な設定値
    static MAX_RESULTS := 1000          ; 検索結果の最大件数
    static MAX_HIGHLIGHT := 500         ; ハイライトする最大件数
    static SCAN_TIMEOUT_MS := 10000     ; スキャンタイムアウト（ミリ秒）
    static DIRS_PER_TICK := 40          ; 1タイマーティックあたりの処理ディレクトリ数

    ; 検索から除外するディレクトリ名（デフォルト値）
    static DEFAULT_EXCLUDE_DIRS := ".git,.svn,.hg,node_modules,__pycache__,.venv,venv,.env,bin,obj,.vs,.idea,.cache,dist,build,target,.next,coverage"
    static DEFAULT_TIMEOUT_SEC := 10    ; デフォルトタイムアウト（秒）、0=無制限
    static ExcludeDirs := []            ; 実行時に読み込まれる除外リスト
    static TimeoutMs := 10000           ; 実行時タイムアウト（ミリ秒）
    static IniPath := A_ScriptDir "\ui\Navi.ini"
    ; UI/タイマー定数
    static UI_MARGIN := 12              ; ダイアログ配置用の汎用マージン
    static TIMER_TICK_MS := 10          ; ディレクトリスキャンのタイマー間隔
    static PARENT_WATCH_MS := 300       ; 親GUI存在監視の間隔
    static EDIT_W := 460                ; 検索入力欄の幅
    static BTN_W_LARGE := 90            ; 大ボタンの幅
    static BTN_W_SMALL := 60            ; 小ボタンの幅
    static LABEL_W_HITS := 120          ; ヒット数ラベルの幅
    static LABEL_W_PROGRESS := 320      ; プログレスラベルの幅
    static GAP_X_SMALL := 6             ; 小さい水平方向の隙間
    static GAP_X_MED := 8               ; 中程度の水平方向の隙間
    static GAP_X_LARGE := 10            ; 大きい水平方向の隙間

    ; 設定ダイアログ用定数
    static SETTINGS_DIALOG_W := 300     ; 設定ダイアログ幅
    static SETTINGS_EDIT_H := 180       ; 除外リスト編集欄の高さ
    static SETTINGS_TIMEOUT_W := 60     ; タイムアウト入力欄の幅
    static SETTINGS_BTN_W := 80         ; 設定ダイアログのボタン幅

    ; プログレス表示用定数
    static PROGRESS_BAR_WIDTH := 12     ; ASCIIプログレスバーの文字幅
    static SPINNER_INTERVAL_MS := 100   ; スピナーアニメーション間隔
    static TOOLTIP_SAVE_DURATION := 1500 ; 設定保存時のツールチップ表示時間
    static TOOLTIP_HELP_DURATION := 8000 ; ヘルプツールチップの表示時間

    ; fd バックエンド
    static UseFd       := true  ; false にするとタイマーループにフォールバック
    static FdPath      := ""    ; _FindFd() の結果キャッシュ（"NOT_FOUND" = 見つからず）
    static _FdPid      := 0     ; 実行中の fd プロセス ID
    static _FdTmpFile  := ""    ; fd 出力を受け取る一時ファイルパス
    static _FdLinesRead := 0    ; fd 出力で処理済みの行数
    static _FdTickCb   := ""    ; fd ポーリングタイマーのコールバック参照（停止に使う）
    static FD_POLL_MS  := 50    ; fd ポーリング間隔（ミリ秒）
    static _SortCol        := 1     ; 最後にソートした列（1=名前, 2=パス）
    static _SortDesc       := false ; 降順フラグ
    static _LastTypeFilter := "all" ; 前回の検索対象フィルター（セッション間で記憶）

    ; 内部タスク構造:
    ; {
    ;   navi, basePath, tokens, stack: [走査待ちディレクトリ],
    ;   results: [], startedAt: A_TickCount,
    ;   processedDirs: 0, processedItems: 0, skippedDirs: 0
    ; }

    ; 公開API: basePath以下をローカル検索し、ツリー上のヒットを強調表示
    static RunLocal(navi, basePath) {
        if (basePath = "" || !DirExist(basePath)) {
            ToolTip("検索ベースのフォルダが無効です")
            SetTimer(() => ToolTip(), -navi.TOOLTIP_ERROR_DURATION)
            return
        }
        ; モーダル・最前面の検索入力ダイアログ
        result := this._PromptQuery(navi, basePath)
        if (result = "")
            return
        this._StartSearch(navi, basePath, result["q"], result["typeFilter"])
    }

    ; ダイアログなしで直接検索実行（フィルター欄の検索モードから呼び出し）
    static RunLocalDirect(navi, basePath, query, typeFilter := "all") {
        if (basePath = "" || !DirExist(basePath)) {
            ToolTip("検索ベースのフォルダが無効です")
            SetTimer(() => ToolTip(), -navi.TOOLTIP_ERROR_DURATION)
            return
        }
        if (query = "")
            return
        this._StartSearch(navi, basePath, query, typeFilter)
    }

    ; 共通の検索開始処理（クエリ正規化・タスク初期化・バックエンド選択）
    static _StartSearch(navi, basePath, q, typeFilter) {
        this._LoadSettings()
        this.LastSearchBasePath := basePath
        ; d:/f: プレフィックスによる typeFilter 上書き（後方互換性）
        if (SubStr(q, 1, 2) = "d:") {
            typeFilter := "dir"
            q := Trim(SubStr(q, 3))
        } else if (SubStr(q, 1, 2) = "f:") {
            typeFilter := "file"
            q := Trim(SubStr(q, 3))
        }
        incGroups := [], notAlts := []
        this._ParseQuery(q, &incGroups, &notAlts)
        if (incGroups.Length = 0)
            return
        this.CancelRequested := false
        this.SearchActive := true
        this.Task := Map(
            "navi", navi,
            "basePath", basePath,
            "tokens", Map("include", incGroups, "not", notAlts),
            "typeFilter", typeFilter,
            "stack", [basePath],
            "results", [],
            "startedAt", A_TickCount,
            "processedDirs", 0,
            "processedItems", 0,
            "skippedDirs", 0
        )
        this._ShowProgress(navi)
        this.EnsureHotkeys(navi)
        ; 検索開始前に JumpGui を開く（リアルタイム表示用）
        if (navi.GuiObj && WinExist(navi.GuiObj))
            this._EnsureJumpGui(navi)
        ; バックエンド選択: fd が利用可能かつ有効なら fd バックエンドを使用
        fdPath := ""
        if (this.UseFd)
            fdPath := this._FindFd()
        if (fdPath != "")
            this._RunWithFd(navi, basePath, q, typeFilter, incGroups, notAlts)
        else
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
        ; キャンセル時はツリー更新なしで終了
        if (this.CancelRequested) {
            this._Finish(false)
            return
        }
        ; タイムアウトまたは十分な結果数に達した場合（TimeoutMs=0は無制限）
        if ((this.TimeoutMs > 0 && A_TickCount - t["startedAt"] >= this.TimeoutMs)
            || (t["results"].Length >= this.MAX_RESULTS)) {
            this._Finish(true)
            return
        }
        ; スタックが空なら検索完了
        if (t["stack"].Length = 0) {
            this._Finish(true)
            return
        }
        dirsProcessed := 0
        while (dirsProcessed < this.DIRS_PER_TICK && t["stack"].Length > 0) {
            dir := t["stack"].Pop()
            t["processedDirs"] += 1
            typeFilter := t["typeFilter"]
            ; 非再帰的に列挙: まずファイル、次にディレクトリ
            ; ファイル（typeFilter が "dir" の場合はスキップ）
            if (typeFilter != "dir") {
                try {
                    loop files, dir . "\*", "F" {
                        t["processedItems"] += 1
                        name := StrLower(A_LoopFileName)
                        ok := this._NameMatches(name, t["tokens"]["include"], t["tokens"]["not"])
                        if (ok) {
                            t["results"].Push(A_LoopFileFullPath)
                            this._AppendToJumpList(A_LoopFileFullPath)
                            if (t["results"].Length >= this.MAX_RESULTS) {
                                this._Finish(true)
                                return
                            }
                        }
                    }
                }
            }
            ; ディレクトリを走査キューに追加し、名前でマッチング
            try {
                loop files, dir . "\*", "D" {
                    t["processedItems"] += 1
                    dirName := A_LoopFileName
                    ; 除外ディレクトリはスキップ（スタックに追加しない）
                    if (this._IsExcludedDir(dirName)) {
                        t["skippedDirs"] += 1
                        continue
                    }
                    t["stack"].Push(A_LoopFileFullPath)
                    ; ディレクトリ結果への追加（typeFilter が "file" の場合はスキップ）
                    if (typeFilter = "file")
                        continue
                    name := StrLower(dirName)
                    ok := this._NameMatches(name, t["tokens"]["include"], t["tokens"]["not"])
                    if (ok) {
                        t["results"].Push(A_LoopFileFullPath)
                        this._AppendToJumpList(A_LoopFileFullPath)
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
            ; '|' でOR分割
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
    ; ワイルドカード対応: `*.js` → `.js` で終わるファイルにマッチ
    static _NameMatches(name, incGroups, notAlts) {
        ; NOT: いずれかのNOTキーワードにマッチしたら除外
        for na in notAlts {
            if (this._PatternMatch(name, na))
                return false
        }
        ; INCLUDE: 各グループで少なくとも1つのキーワードを含む必要あり
        for group in incGroups {
            okInGroup := false
            for alt in group {
                if (this._PatternMatch(name, alt)) {
                    okInGroup := true
                    break
                }
            }
            if !okInGroup
                return false
        }
        return true
    }

    ; パターンマッチング（ワイルドカード対応）
    ; `*.js` → 末尾一致、それ以外 → 部分一致
    static _PatternMatch(name, pattern) {
        if (SubStr(pattern, 1, 1) = "*") {
            ; ワイルドカード: 末尾一致（例: *.js → .js で終わる）
            suffix := SubStr(pattern, 2)  ; "*" を除去
            suffixLen := StrLen(suffix)
            nameLen := StrLen(name)
            if (nameLen < suffixLen)
                return false
            return (SubStr(name, nameLen - suffixLen + 1) = suffix)
        } else {
            ; 通常: 部分一致
            return InStr(name, pattern)
        }
    }

    ; 除外ディレクトリかどうかを判定（大文字小文字を区別しない）
    static _IsExcludedDir(dirName) {
        lowerName := StrLower(dirName)
        for excluded in this.ExcludeDirs {
            if (lowerName = StrLower(excluded))
                return true
        }
        return false
    }

    ; fd.exe のパスを返す（見つからなければ ""）。結果はキャッシュ
    static _FindFd() {
        if (this.FdPath != "")
            return (this.FdPath = "NOT_FOUND") ? "" : this.FdPath

        ; 1) SearchPath API で PATH から検索（cmd.exe を起動しないためフラッシュなし）
        buf := Buffer(2048, 0)   ; 1024 wide chars
        len := DllCall("SearchPath",
            "ptr",  0, "str", "fd.exe", "ptr", 0,
            "uint", 1024, "ptr", buf, "ptr", 0, "uint")
        if (len > 0) {
            path := StrGet(buf)
            if (FileExist(path)) {
                this.FdPath := path
                return path
            }
        }

        ; 2) WinGet パッケージフォルダをスキャン
        wingetBase := EnvGet("LOCALAPPDATA") . "\Microsoft\WinGet\Packages"
        if DirExist(wingetBase) {
            loop files, wingetBase . "\sharkdp.fd_*\*\fd.exe", "R" {
                this.FdPath := A_LoopFileFullPath
                return A_LoopFileFullPath
            }
        }

        this.FdPath := "NOT_FOUND"
        return ""
    }

    ; fd バックエンドで検索を開始（Run + 一時ファイルで非表示・UTF-8対応）
    static _RunWithFd(navi, basePath, q, typeFilter, incGroups, notAlts) {
        fdPath  := this._FindFd()
        tmpFile := A_Temp . "\navi_fd_" . A_TickCount . ".txt"

        ; fd コマンド組み立て（一時ファイルへリダイレクト）
        fdCmd := '"' . fdPath . '" --no-ignore-vcs --color never'
        if (typeFilter = "file")
            fdCmd .= " --type f"
        else if (typeFilter = "dir")
            fdCmd .= " --type d"
        else  ; "all": fdのバージョンによってはデフォルトがファイルのみのため明示
            fdCmd .= " --type f --type d"
        for excl in this.ExcludeDirs
            fdCmd .= ' --exclude "' . excl . '"'
        ; 末尾バックスラッシュをエスケープ（C:\ → C:\\ ）
        ; C ランタイムは \" をエスケープされたクォートとして解析するため
        ; "C:\" の \" がクォートを食いつぶしパス引数が壊れる。\\ にすれば "C:\\" → C:\ になる
        safeBase := (SubStr(basePath, -1) = "\") ? basePath . "\" : basePath
        fdCmd .= ' . "' . safeBase . '"'
        ; fd.exe を直接起動（cmd.exe を介さないのでウィンドウフラッシュなし）
        ; fd は UTF-8 をネイティブ出力するため chcp 不要
        pid := this._RunNoWindowToFile(fdCmd, tmpFile)
        if (pid = 0) {
            this._FallbackToTick()
            return
        }
        this._FdPid      := pid
        this._FdTmpFile  := tmpFile
        this._FdLinesRead := 0
        this.Task := Map(
            "navi",           navi,
            "basePath",       basePath,
            "tokens",         Map("include", incGroups, "not", notAlts),
            "typeFilter",     typeFilter,
            "stack",          [],
            "results",        [],
            "startedAt",      A_TickCount,
            "processedDirs",  0,
            "processedItems", 0,
            "skippedDirs",    0,
            "isFd",           true
        )
        cb := NaviSearch._FdTick.Bind(NaviSearch)
        this._FdTickCb := cb
        SetTimer(cb, this.FD_POLL_MS)
    }

    ; fd ポーリングタイマー（プロセス終了を監視して一時ファイルを読み込む）
    static _FdTick(*) {
        if !(this.SearchActive) {
            SetTimer(, 0)
            return
        }
        t  := this.Task
        nv := t["navi"]
        if !(nv.GuiObj && WinExist(nv.GuiObj)) {
            SetTimer(, 0)
            this._KillFd()
            this._Finish(false)
            return
        }
        if (this.CancelRequested) {
            SetTimer(, 0)
            this._KillFd()
            this._Finish(false)
            return
        }
        if (this.TimeoutMs > 0 && A_TickCount - t["startedAt"] >= this.TimeoutMs) {
            SetTimer(, 0)
            this._KillFd()
            this._Finish(true)
            return
        }
        isDone := !ProcessExist(this._FdPid)
        ; 実行中・完了に関わらず新しい行を処理する
        raw := ""
        try {
            raw := FileRead(this._FdTmpFile, "UTF-8")
        }
        if (raw != "") {
            tokens    := t["tokens"]
            incGroups := tokens["include"]
            notAlts   := tokens["not"]
            results   := t["results"]
            lines     := StrSplit(raw, "`n")
            ; 実行中は最後の行をスキップ（書き込み中の可能性）
            maxLine := isDone ? lines.Length : Max(lines.Length - 1, 0)
            loop {
                lineIdx := this._FdLinesRead + 1
                if (lineIdx > maxLine)
                    break
                p := Trim(lines[lineIdx], " `r`n")
                this._FdLinesRead += 1
                if (p = "")
                    continue
                ; fdがディレクトリパスに末尾バックスラッシュを付加する場合の対処
                if (SubStr(p, -1) = "\" && StrLen(p) > 3)
                    p := SubStr(p, 1, -1)
                SplitPath(p, &fileName)
                if (this._NameMatches(StrLower(fileName), incGroups, notAlts)) {
                    results.Push(p)
                    this._AppendToJumpList(p)
                    if (results.Length >= this.MAX_RESULTS) {
                        isDone := true
                        break
                    }
                }
                t["processedItems"] += 1
            }
        }
        this._UpdateProgress()
        if (!isDone)
            return
        ; --- 完了 ---
        SetTimer(, 0)
        try FileDelete(this._FdTmpFile)
        this._FdPid     := 0
        this._FdTmpFile := ""
        this._Finish(true)
    }

    ; fd.exe を直接起動し stdout をファイルにリダイレクト（cmd.exe フラッシュなし）
    ; STARTF_USESTDHANDLES で継承可能ハンドルを渡す。戻り値: PID（失敗時 0）
    static _RunNoWindowToFile(cmd, outFile) {
        ; 出力ファイルを継承可能ハンドルで作成
        ; SECURITY_ATTRIBUTES: nLength / lpSecurityDescriptor / bInheritHandle
        saSize := (A_PtrSize = 8) ? 24 : 12
        sa := Buffer(saSize, 0)
        NumPut("uint", saSize, sa, 0)
        NumPut("uint", 1, sa, (A_PtrSize = 8) ? 16 : 8)   ; bInheritHandle = TRUE
        hFile := DllCall("CreateFile",
            "str",  outFile,
            "uint", 0x40000000,   ; GENERIC_WRITE
            "uint", 0x1,          ; FILE_SHARE_READ
            "ptr",  sa,
            "uint", 2,            ; CREATE_ALWAYS
            "uint", 0x80,         ; FILE_ATTRIBUTE_NORMAL
            "ptr",  0, "ptr")
        if (hFile = -1 || hFile = 0)
            return 0

        ; STARTUPINFO のサイズとフィールドオフセット（32/64 ビット対応）
        siSize    := (A_PtrSize = 8) ? 104 : 68
        flagsOff  := (A_PtrSize = 8) ? 60  : 44
        showOff   := (A_PtrSize = 8) ? 64  : 48
        stdInOff  := (A_PtrSize = 8) ? 80  : 56
        stdOutOff := (A_PtrSize = 8) ? 88  : 60
        stdErrOff := (A_PtrSize = 8) ? 96  : 64

        si := Buffer(siSize, 0)
        NumPut("uint",   siSize, si, 0)
        NumPut("uint",   0x101,  si, flagsOff)   ; STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES
        NumPut("ushort", 0,      si, showOff)    ; SW_HIDE
        NumPut("ptr",    0,      si, stdInOff)   ; hStdInput  = NULL
        NumPut("ptr",    hFile,  si, stdOutOff)  ; hStdOutput = outFile
        NumPut("ptr",    hFile,  si, stdErrOff)  ; hStdError  = outFile（エラーも同ファイルへ）

        pi := Buffer(A_PtrSize * 2 + 8, 0)
        ok := DllCall("CreateProcess",
            "ptr",  0,
            "str",  cmd,
            "ptr",  0, "ptr", 0,
            "int",  true,           ; bInheritHandles = TRUE
            "uint", 0x08000000,     ; CREATE_NO_WINDOW
            "ptr",  0, "ptr", 0,
            "ptr",  si, "ptr", pi)
        DllCall("CloseHandle", "ptr", hFile)   ; 親側ハンドルを閉じる
        if (!ok)
            return 0
        DllCall("CloseHandle", "ptr", NumGet(pi, 0,           "ptr"))
        DllCall("CloseHandle", "ptr", NumGet(pi, A_PtrSize,   "ptr"))
        return NumGet(pi, A_PtrSize * 2, "uint")   ; dwProcessId
    }

    ; CREATE_NO_WINDOW でプロセスを起動（ウィンドウフラッシュなし）、PID を返す
    static _RunNoWindow(cmd) {
        si := Buffer(96, 0)
        NumPut("uint", 96, si, 0)           ; cb = sizeof(STARTUPINFO)
        NumPut("uint", 0x1, si, 44)         ; dwFlags = STARTF_USESHOWWINDOW
        NumPut("ushort", 0, si, 48)         ; wShowWindow = SW_HIDE
        pi := Buffer(A_PtrSize * 2 + 8, 0)
        ok := DllCall("CreateProcess",
            "ptr",  0,
            "str",  cmd,
            "ptr",  0, "ptr", 0,
            "int",  false,
            "uint", 0x08000000,             ; CREATE_NO_WINDOW
            "ptr",  0, "ptr", 0,
            "ptr",  si, "ptr", pi)
        if (!ok)
            return 0
        DllCall("CloseHandle", "ptr", NumGet(pi, 0,           "ptr"))
        DllCall("CloseHandle", "ptr", NumGet(pi, A_PtrSize,   "ptr"))
        return NumGet(pi, A_PtrSize * 2, "uint")   ; dwProcessId
    }

    ; fd プロセスと一時ファイルを強制終了・削除
    static _KillFd() {
        try ProcessClose(this._FdPid)
        try FileDelete(this._FdTmpFile)
        this._FdPid     := 0
        this._FdTmpFile := ""
    }

    ; fd 起動失敗時にタイマーループへフォールバック
    static _FallbackToTick() {
        t := this.Task
        if (Type(t) = "Map") {
            t["stack"] := [t["basePath"]]
            t["isFd"]  := false
        }
        SetTimer(NaviSearch._Tick.Bind(NaviSearch), this.TIMER_TICK_MS)
    }

    ; JumpGui のリストに1件追加（リアルタイム表示用）
    static _AppendToJumpList(path) {
        lv := this.JumpListView
        if !IsObject(lv)
            return
        SplitPath(path, &fname, &fdir)
        lv.Add("", fname, fdir)
    }

    ; ListView をソート（col=2 のときは パス→名前 の複合キーで同フォルダ内を名前順に）
    static _SortJumpList(lv, col := 1, desc := false) {
        n := lv.GetCount()
        if (n = 0)
            return
        ; ソート前の選択アイテムのパスを保存
        selRow := lv.GetNext(0)
        selPath := ""
        if (selRow > 0) {
            selFname := lv.GetText(selRow, 1)
            selFdir  := lv.GetText(selRow, 2)
            selPath  := (selFdir != "" ? selFdir . "\" . selFname : selFname)
        }
        sep := Chr(1)   ; ASCII SOH — Windows パスには含まれない
        raw := ""
        loop n {
            fname := lv.GetText(A_Index, 1)
            fdir  := lv.GetText(A_Index, 2)
            key   := col = 2 ? StrLower(fdir . A_Tab . fname) : StrLower(fname)
            raw   .= key . sep . fname . sep . fdir . "`n"
        }
        raw := RTrim(raw, "`n")
        Sort(raw, desc ? "R" : "")
        lv.Delete()
        newSelRow := 0
        rowNum := 0
        for sortLine in StrSplit(raw, "`n") {
            if (sortLine = "")
                continue
            rowNum += 1
            p := StrSplit(sortLine, sep)
            if (p.Length >= 3) {
                lv.Add("", p[2], p[3])
                if (selPath != "" && newSelRow = 0) {
                    path := (p[3] != "" ? p[3] . "\" . p[2] : p[2])
                    if (path = selPath)
                        newSelRow := rowNum
                }
            }
        }
        ; ソート後に同じアイテムを再選択してカーソル位置を維持
        if (newSelRow > 0) {
            lv.Modify(newSelRow, "Select Vis")
            this.HighlightedIdx := newSelRow
        } else {
            this.HighlightedIdx := 0
        }
    }

    ; NTFS互換ソート（CompareStringOrdinal による ordinal 比較）
    ; AHKのSort()はロケール依存で '_'(95) を英字より前に置くため、
    ; NTFS Bツリーと同じ ordinal 比較を DllCall で実現する
    ; ツリー表示順ソート: 同一親内でフォルダ先・ファイル後、名前はNTFS ordinal順
    ; treeキー: フォルダ成分は Chr(1) 前置き（先）、ファイル末尾は Chr(2) 前置き（後）
    static _SortByNtfsOrder(lv, basePath := "") {
        n := lv.GetCount()
        if (n = 0)
            return
        base := (basePath != "" ? basePath . "\" : "")
        baseLen := StrLen(base)
        rows := []
        loop n {
            f := lv.GetText(A_Index, 1)
            d := lv.GetText(A_Index, 2)
            p := (d != "" ? d . "\" . f : f)
            isDir := DirExist(p) ? 1 : 0
            ; ベースパス以降の相対パスをパーツ分割してtreeキーを構築
            rel := (baseLen > 0 && InStr(p, base) = 1) ? SubStr(p, baseLen + 1) : p
            parts := StrSplit(rel, "\")
            key := ""
            for i, part in parts {
                if (i = parts.Length && !isDir)
                    key .= Chr(2) . part        ; ファイル末尾: \ なし（ordinal比較でフォルダより後、かつ opennt < opennt-* になる）
                else
                    key .= Chr(1) . part . "\"  ; フォルダ成分: Chr(1) でファイルより先
            }
            rows.Push({f: f, d: d, key: key})
        }
        ; 挿入ソート（AHK v2.0.19はSort()でArrayをサポートしないため手動実装）
        loop rows.Length - 1 {
            i := A_Index + 1
            cur := rows[i]
            j := i - 1
            while (j >= 1) {
                r := DllCall("CompareStringOrdinal",
                    "wstr", rows[j].key, "int", -1,
                    "wstr", cur.key, "int", -1, "int", true, "int")
                if (r <= 2)  ; CSTR_LESS_THAN(1) or CSTR_EQUAL(2)
                    break
                rows[j + 1] := rows[j]
                j--
            }
            rows[j + 1] := cur
        }
        try lv.Delete()
        for row in rows {
            try lv.Add("", row.f, row.d)
            catch
                break  ; GUIが破棄された場合は中断
        }
    }

    ; 設定をINIから読み込み（初回のみ）
    static _LoadSettings() {
        if (this.ExcludeDirs.Length > 0)
            return  ; 既に読み込み済み
        ; 除外ディレクトリ
        try {
            raw := IniRead(this.IniPath, "Search", "ExcludeDirs", this.DEFAULT_EXCLUDE_DIRS)
        } catch {
            raw := this.DEFAULT_EXCLUDE_DIRS
        }
        this.ExcludeDirs := []
        for part in StrSplit(raw, ",") {
            trimmed := Trim(part)
            if (trimmed != "")
                this.ExcludeDirs.Push(trimmed)
        }
        ; タイムアウト
        try {
            timeoutSec := Integer(IniRead(this.IniPath, "Search", "TimeoutSec", this.DEFAULT_TIMEOUT_SEC))
        } catch {
            timeoutSec := this.DEFAULT_TIMEOUT_SEC
        }
        this.TimeoutMs := (timeoutSec <= 0) ? 0 : timeoutSec * 1000
        ; UseFd 設定（デフォルト: true）
        try {
            useFdVal := IniRead(this.IniPath, "Search", "UseFd", "1")
        } catch {
            useFdVal := "1"
        }
        this.UseFd := (useFdVal != "0")
        this.FdPath := ""  ; キャッシュリセット
    }

    ; 除外リストをINIに保存
    static _SaveExcludeDirs() {
        str := ""
        for i, dir in this.ExcludeDirs {
            str .= (i > 1 ? "," : "") . dir
        }
        try IniWrite(str, this.IniPath, "Search", "ExcludeDirs")
    }

    ; 除外ディレクトリ編集ダイアログ
    static _ShowExcludeEditor(parentGui) {
        ; 現在の除外リストを改行区切りで表示
        currentList := ""
        for dir in this.ExcludeDirs
            currentList .= dir . "`n"
        currentList := RTrim(currentList, "`n")

        ; 現在のタイムアウト値（秒）
        currentTimeout := (this.TimeoutMs <= 0) ? 0 : this.TimeoutMs // 1000

        eg := Gui("+AlwaysOnTop +ToolWindow -MaximizeBox -MinimizeBox +Owner" . parentGui.Hwnd, "検索設定")
        eg.SetFont("s9", "Segoe UI")

        ; タイムアウト設定
        eg.Add("Text", "xm", "タイムアウト（秒、0=無制限）:")
        timeoutEdit := eg.Add("Edit", "x+" . this.GAP_X_MED . " yp-3 w" . this.SETTINGS_TIMEOUT_W . " vTimeout Number", currentTimeout)
        eg.Add("Text", "x+" . this.GAP_X_MED . " yp+3 c808080", "秒")

        ; fd バックエンド
        useFdCb := eg.Add("CheckBox", "xm", "fd を使用して高速検索（fd.exe が必要）")
        useFdCb.Value := this.UseFd ? 1 : 0

        ; 除外ディレクトリ
        eg.Add("Text", "xm", "除外ディレクトリ（1行に1つ）:")
        editBox := eg.Add("Edit", "xm w" . this.SETTINGS_DIALOG_W . " h" . this.SETTINGS_EDIT_H . " vExcludeList", currentList)
        btnSave := eg.Add("Button", "xm w" . this.SETTINGS_BTN_W, "保存")
        btnReset := eg.Add("Button", "x+" . this.GAP_X_MED . " w" . this.SETTINGS_BTN_W, "初期値に戻す")
        btnClose := eg.Add("Button", "x+" . this.GAP_X_MED . " w" . this.SETTINGS_BTN_W, "閉じる")

        btnSave.OnEvent("Click", (*) => this._SaveSettingsFromEditor(eg, editBox, timeoutEdit, useFdCb))
        btnReset.OnEvent("Click", (*) => (
            editBox.Value := StrReplace(this.DEFAULT_EXCLUDE_DIRS, ",", "`n"),
            timeoutEdit.Value := this.DEFAULT_TIMEOUT_SEC
        ))
        btnClose.OnEvent("Click", (*) => eg.Destroy())
        eg.OnEvent("Escape", (*) => eg.Destroy())

        ; 親の中央に配置
        parentGui.GetPos(&px, &py, &pw, &ph)
        eg.Show("Hide AutoSize")
        eg.GetPos(, , &gw, &gh)
        x := px + (pw - gw) // 2
        y := py + (ph - gh) // 2
        eg.Show("x" . x . " y" . y)
    }

    ; 設定を編集ダイアログから保存
    static _SaveSettingsFromEditor(eg, editBox, timeoutEdit, useFdCb) {
        ; 除外ディレクトリ
        raw := editBox.Value
        this.ExcludeDirs := []
        for line in StrSplit(raw, "`n") {
            trimmed := Trim(line)
            if (trimmed != "")
                this.ExcludeDirs.Push(trimmed)
        }
        this._SaveExcludeDirs()

        ; タイムアウト
        try {
            timeoutSec := Integer(timeoutEdit.Value)
        } catch {
            timeoutSec := this.DEFAULT_TIMEOUT_SEC
        }
        if (timeoutSec < 0)
            timeoutSec := 0
        this.TimeoutMs := (timeoutSec <= 0) ? 0 : timeoutSec * 1000
        try IniWrite(timeoutSec, this.IniPath, "Search", "TimeoutSec")

        ; UseFd
        this.UseFd := (useFdCb.Value = 1)
        try IniWrite(useFdCb.Value, this.IniPath, "Search", "UseFd")
        this.FdPath := ""  ; キャッシュリセット

        ToolTip("設定を保存しました")
        SetTimer(() => ToolTip(), -this.TOOLTIP_SAVE_DURATION)
    }

    ; 検索構文ヘルプを表示
    static _ShowSearchHelp() {
        help := "
        (
【検索構文】
  単語        部分一致（例: config）
  スペース    AND検索（例: config json）
  |           OR検索（例: txt|log）
  !           除外（例: !backup）
  *.ext       拡張子（例: *.js *.txt）
  d:          フォルダのみ（ラジオボタンと同等）
  f:          ファイルのみ（ラジオボタンと同等）

【例】
  test            testを含むファイル/フォルダ
  *.js|*.ts       .js または .ts ファイル
  config !backup  configを含むがbackupを除外
        )"
        ToolTip(help)
        SetTimer(() => ToolTip(), -this.TOOLTIP_HELP_DURATION)
    }

    ; --- 検索入力ダイアログ（Navi付近に最前面表示） ---
    ; 戻り値: Map("q", クエリ文字列, "typeFilter", "all"|"file"|"dir") / キャンセル時は ""
    static _PromptQuery(navi, basePath) {
        title := "Navi - ローカル検索"
        g := Gui("+AlwaysOnTop +ToolWindow -MaximizeBox -MinimizeBox", title)
        g.SetFont("s9", "Segoe UI")
        g.Add("Text", "xm", "検索語を入力")
        ; ヘルプアイコン（ホバーでツールチップ表示）
        helpText := g.Add("Text", "x+5 yp cBlue", "[?]")
        helpText.OnEvent("Click", (*) => this._ShowSearchHelp())
        g.Add("Text", "xm c808080", "Base: " . basePath)
        inputEdit := g.Add("Edit", "xm w" . this.EDIT_W . " vQ")
        ; 検索対象ラジオボタン
        g.Add("Text", "xm", "対象:")
        rbAll  := g.Add("Radio", "x+6 yp-1 Group", "すべて")
        rbFile := g.Add("Radio", "x+10 yp", "ファイルのみ")
        rbDir  := g.Add("Radio", "x+10 yp", "フォルダのみ")
        ; 前回の選択を復元
        if (this._LastTypeFilter = "file")
            rbFile.Value := 1
        else if (this._LastTypeFilter = "dir")
            rbDir.Value := 1
        else
            rbAll.Value := 1
        btnOK := g.Add("Button", "xm w" . this.BTN_W_LARGE . " Default", "OK")
        btnCancel := g.Add("Button", "x+" . this.GAP_X_MED . " w" . this.BTN_W_LARGE, "キャンセル")
        btnExclude := g.Add("Button", "x+" . this.GAP_X_MED . " w" . this.BTN_W_LARGE, "設定")
        res := ""
        selectedType := this._LastTypeFilter  ; デフォルト（キャンセル時は使わない）
        ; OK押下時: GUIが破棄される前にラジオボタンの値を読み取る
        btnOK.OnEvent("Click", (*) => (
            res := Trim(inputEdit.Value),
            selectedType := rbFile.Value ? "file" : rbDir.Value ? "dir" : "all",
            g.Destroy()
        ))
        btnCancel.OnEvent("Click", (*) => (res := "", g.Destroy()))
        btnExclude.OnEvent("Click", (*) => this._ShowExcludeEditor(g))
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
        if (res = "")
            return ""
        ; selectedType は OK ボタン押下時（GUI破棄前）に設定済み
        this._LastTypeFilter := selectedType
        return Map("q", res, "typeFilter", selectedType)
    }

    static _Finish(showResults) {
        if (this._FdTickCb != "")
            SetTimer(this._FdTickCb, 0)
        this._FdTickCb := ""
        this._KillFd()
        this._HideProgress()
        this.SearchActive := false
        if (showResults && !this.CancelRequested) {
            ; SearchActive=false にした後 Sleep(0) でメッセージキューをフラッシュする。
            ; _FdTick が <16ms で完了すると AHK は Close コールバックを割り込ませないため
            ; WM_CLOSE がキューに残っている場合がある。Sleep(0) で処理させてから再確認する。
            ; ClearHighlights は SearchActive=false を見て _Finish(false) を呼ばないため
            ; 二重呼び出しも発生しない。
            Sleep(0)
            if (this.CancelRequested) {
                this.Results := []
                this.Task := ""
                this.CancelRequested := false
                return
            }
            t := this.Task
            this.Results := (Type(t) = "Map" && t.Has("results")) ? t["results"] : []
            nv := t["navi"]
            if (nv.GuiObj && WinExist(nv.GuiObj)) {
                tv := nv.GuiObj["FolderTree"]
                this.HighlightPathsInTree(nv, tv, t["basePath"], t["results"])
                lv := this.JumpListView
                if IsObject(lv) && lv.GetCount() > 0 {
                    ; NTFS互換ソートでツリーの表示順（大文字比較）に合わせる
                    this._SortByNtfsOrder(lv, t["basePath"])
                    lv.Modify(1, "Select Vis")
                    this.HighlightedIdx := 1
                    ; ツリーもソート後の先頭行パスに合わせる
                    fname := lv.GetText(1, 1)
                    fdir  := lv.GetText(1, 2)
                    p0 := (fdir != "" ? fdir . "\" . fname : fname)
                    if (FileExist(p0)) {
                        SplitPath(p0, &fn0, &fd0)
                        idDir0 := this.EnsurePathExpanded(nv, tv, fd0)
                        if (idDir0) {
                            this.EnsureFilesShown(nv, tv, idDir0, fd0)
                            cid0 := tv.GetChild(idDir0)
                            while (cid0) {
                                if (tv.GetText(cid0) = fn0) {
                                    tv.Modify(cid0, "Select Vis")
                                    break
                                }
                                cid0 := tv.GetNext(cid0)
                            }
                        }
                    } else if (DirExist(p0)) {
                        id0 := this.EnsurePathExpanded(nv, tv, p0)
                        if (id0)
                            tv.Modify(id0, "Select Vis")
                    }
                }
                this._UpdateJumpLabel()
            }
        } else {
            this.Results := []
        }
        this.Task := ""
        this.CancelRequested := false
    }

    ; プログレスUIの表示とキャンセル機能
    static _ShowProgress(navi) {
        ; 進捗はJumpGui内のJumpLabelで表示（独立ウィンドウ廃止）
        this.LastNavi := navi
        ; Naviを無効化（検索中にアクションが実行されるのを防ぐ）
        if (navi.GuiObj && WinExist(navi.GuiObj)) {
            try navi.GuiObj.Opt("+Disabled")
            ; Esc でキャンセル
            HotIfWinActive("ahk_id " navi.GuiObj.Hwnd)
            Hotkey("Esc", ((*) => (NaviSearch.CancelRequested := true)), "On")
            HotIf()
        }
        this._UpdateProgress()
    }

    static _UpdateProgress() {
        jl := this.JumpLabel
        if !IsObject(jl)
            return
        t := this.Task
        if !(Type(t) = "Map")
            return
        elapsed := A_TickCount - t["startedAt"]
        skipped := t["skippedDirs"]
        ; ASCIIプログレスバー（タイムアウトまでの進捗、0=無制限時はスピナー）
        if (this.TimeoutMs > 0)
            indicator := this._MakeProgressBar(elapsed, this.TimeoutMs)
        else
            indicator := this._MakeSpinner(elapsed)
        try jl.Text := indicator . " " . t["results"].Length . "件"
                     . " dirs:" . t["processedDirs"]
                     . (skipped > 0 ? " skip:" . skipped : "")
    }

    ; ASCIIプログレスバー生成（タイムアウトまでの進捗を視覚化）
    static _MakeProgressBar(current, total) {
        width := this.PROGRESS_BAR_WIDTH
        ratio := Min(current / total, 1.0)
        filled := Round(ratio * width)
        empty := width - filled
        bar := "["
        loop filled
            bar .= "█"
        loop empty
            bar .= "░"
        bar .= "]"
        return bar
    }

    ; 無制限モード用スピナー（Brailleパターンによるアニメーション）
    static _MakeSpinner(elapsed) {
        static frames := ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        idx := Mod(elapsed // this.SPINNER_INTERVAL_MS, frames.Length) + 1
        return "[" . frames[idx] . "]"
    }

    static _HideProgress() {
        ; 親GUIの再有効化 & NaviのEsc（閉じる）を復活
        try {
            t := this.Task
            nv := ""
            if (Type(t) = "Map" && t.Has("navi")) {
                nv := t["navi"]
            } else if (this.LastNavi) {
                nv := this.LastNavi
            }
            if (nv && nv.GuiObj && WinExist(nv.GuiObj)) {
                nv.GuiObj.Opt("-Disabled +AlwaysOnTop")
                ; NaviのEsc=_HandleEscを再登録（検索キャンセルで上書きされたため）
                HotIfWinActive("ahk_id " nv.GuiObj.Hwnd)
                Hotkey("Esc", (*) => nv._HandleEsc(), "On")
                HotIf()
            }
        }
    }

    ; ハイライトとツリー展開
    static HighlightPathsInTree(navi, tv, basePath, paths) {
        if !tv
            return
        this.HighlightedIds := []
        this._HighlightedPaths := []
        this._HighlightedIdSet := Map()
        this.HighlightedIdx := 0

        ; 一括操作中の再描画を止めてスクロールを抑制
        SendMessage(0x000B, 0, 0, tv)  ; WM_SETREDRAW false

        shownCount := 0
        for p in paths {
            if (shownCount >= this.MAX_HIGHLIGHT)
                break
            if InStr(p, basePath) != 1
                continue
            if (DirExist(p)) {
                if (id := this.EnsurePathExpanded(navi, tv, p)) {
                    tv.Modify(id, "Expand")
                    try navi._OnItemExpand(tv, id)
                    this.HighlightedIds.Push(id), this._HighlightedPaths.Push(p), shownCount += 1
                }
            } else if (FileExist(p)) {
                SplitPath(p, &fname, &dir)
                if (idDir := this.EnsurePathExpanded(navi, tv, dir)) {
                    tv.Modify(idDir, "Expand")
                    try navi._OnItemExpand(tv, idDir)
                    this.EnsureFilesShown(navi, tv, idDir, dir)
                    cid := tv.GetChild(idDir)
                    while (cid) {
                        if (tv.GetText(cid) = fname) {
                            this.HighlightedIds.Push(cid), this._HighlightedPaths.Push(p), shownCount += 1
                            break
                        }
                        cid := tv.GetNext(cid)
                    }
                }
            }
        }
        ; IdSet 構築（カスタムドロー用 O(1) ルックアップ）
        this._HighlightedIdSet := Map()
        for id in this.HighlightedIds
            this._HighlightedIdSet[id] := true
        ; NM_CUSTOMDRAW ハンドラー登録
        this._EnsureCustomDraw(tv, navi)
        ; 最初の結果へスクロール位置を合わせてから再描画を再開（Results基準）
        this.HighlightedIdx := 0
        if (this.Results.Length > 0) {
            this.HighlightedIdx := 1
            p0 := this.Results[1]
            if (DirExist(p0)) {
                id0 := this.EnsurePathExpanded(navi, tv, p0)
                if (id0)
                    try tv.Modify(id0, "Select Vis")
            } else if (FileExist(p0)) {
                SplitPath(p0, &fn0, &fd0)
                idDir0 := this.EnsurePathExpanded(navi, tv, fd0)
                if (idDir0) {
                    this.EnsureFilesShown(navi, tv, idDir0, fd0)
                    cid0 := tv.GetChild(idDir0)
                    while (cid0) {
                        if (tv.GetText(cid0) = fn0) {
                            tv.Modify(cid0, "Select Vis")
                            break
                        }
                        cid0 := tv.GetNext(cid0)
                    }
                }
            }
        }
        ; 再描画を再開して1回だけ描画（WM_SETREDRAW true + RedrawWindow）
        SendMessage(0x000B, 1, 0, tv)
        DllCall("user32\RedrawWindow", "ptr", tv.Hwnd, "ptr", 0, "ptr", 0,
            "uint", 0x0085)  ; RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN
        ToolTip("ハイライト: " . shownCount . "件")
        SetTimer(() => ToolTip(), -navi.TOOLTIP_SUCCESS_DURATION)
    }

    static EnsurePathExpanded(navi, tv, targetPath) {
        if (!DirExist(targetPath) && !FileExist(targetPath))
            return 0
        ; 全ルートを走査して対象パスを含むルートを特定（複数ルート対応）
        currentID := tv.GetNext(0, "Full")
        while (currentID != 0) {
            rootPath := tv.GetText(currentID)
            if (InStr(targetPath, rootPath) = 1)
                break
            currentID := tv.GetNext(currentID)
        }
        if (currentID == 0)
            return 0
        rootPath := tv.GetText(currentID)
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
                return 0  ; パスが途中までしか一致しない場合は 0 を返す
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
            fid := tv.Add(A_LoopFileName, idDir, "Icon2")
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
        Hotkey("F6", ((*) => NaviSearch._FocusJumpGui()), "On")
        HotIf()
    }

    static Jump(navi, delta) {
        if !(navi.GuiObj && WinExist(navi.GuiObj))
            return
        lv := this.JumpListView
        if !IsObject(lv) || lv.GetCount() = 0 {
            ToolTip("ヒットなし")
            SetTimer(() => ToolTip(), -navi.TOOLTIP_SUCCESS_DURATION)
            return
        }
        total  := lv.GetCount()
        cur    := lv.GetNext(0)
        if (cur = 0)
            cur := (delta > 0) ? 0 : total + 1
        newRow := cur + delta
        if (newRow < 1)
            newRow := total
        else if (newRow > total)
            newRow := 1
        lv.Modify(0, "-Select")
        lv.Modify(newRow, "Select Vis")
        this.HighlightedIdx := newRow
        ; _JumpTo と同じ TreeView 遷移
        fname := lv.GetText(newRow, 1)
        fdir  := lv.GetText(newRow, 2)
        p     := (fdir != "" ? fdir . "\" . fname : fname)
        tv    := navi.GuiObj["FolderTree"]
        navigated := false
        if (DirExist(p)) {
            id := this.EnsurePathExpanded(navi, tv, p)
            if (id) {
                tv.Modify(id, "Select Vis")
                navigated := true
            }
        } else if (FileExist(p)) {
            SplitPath(p, &fn, &fd)
            idDir := this.EnsurePathExpanded(navi, tv, fd)
            if (idDir) {
                this.EnsureFilesShown(navi, tv, idDir, fd)
                found := false
                cid := tv.GetChild(idDir)
                while (cid) {
                    if (tv.GetText(cid) = fn) {
                        tv.Modify(cid, "Select Vis")
                        found := true
                        break
                    }
                    cid := tv.GetNext(cid)
                }
                if (!found) {
                    fid := tv.Add(fn, idDir, "Icon2")
                    tv.Modify(fid, "Select Vis")
                }
                navigated := true
            }
        }
        tipSuffix := navigated ? "" : "（ツリー外）"
        ToolTip(newRow . " / " . total . " 件目" . tipSuffix)
        SetTimer(() => ToolTip(), -navi.TOOLTIP_SUCCESS_DURATION)
        this._UpdateJumpLabel()
    }

    static _EnsureJumpGui(navi) {
        if !(navi.GuiObj && WinExist(navi.GuiObj))
            return
        ; 既存のJumpGuiがあれば破棄して新しい結果で再生成
        try {
            jg := this.JumpGui
            if (Type(jg) = "Gui" && jg.Hwnd && WinExist("ahk_id " jg.Hwnd)) {
                this._RemoveJumpGuiHotkeys()
                jg.Destroy()
            }
        }
        this.JumpGui := ""
        this.JumpLabel := ""
        g := Gui("+Owner" . navi.GuiObj.Hwnd . " +Resize +AlwaysOnTop +ToolWindow -MaximizeBox -MinimizeBox", "検索ヒット")
        g.SetFont("s9", "Segoe UI")
        ; ボタン行（再検索のみ Tabstop ON、他は -Tabstop でスキップ）
        prev      := g.Add("Button", "xm w" . this.BTN_W_SMALL . " -Tabstop", "前へ")
        next      := g.Add("Button", "x+" . this.GAP_X_SMALL . " w" . this.BTN_W_SMALL . " -Tabstop", "次へ")
        listBtn   := g.Add("Button", "x+" . this.GAP_X_SMALL . " w" . this.BTN_W_SMALL . " -Tabstop", "リスト△")
        reSearchBtn := g.Add("Button", "x+" . this.GAP_X_SMALL . " w" . this.BTN_W_SMALL, "再検索")
        this.JumpLabel := g.Add("Text", "x+" . this.GAP_X_LARGE . " w" . this.LABEL_W_HITS, "")
        closeBtn  := g.Add("Button", "x+" . this.GAP_X_SMALL . " w" . this.BTN_W_SMALL . " -Tabstop", "閉じる")
        ; ショートカットヒント
        g.SetFont("s7", "Segoe UI")
        g.Add("Text", "xm c808080", "Shift+F3 / F3")
        g.SetFont("s9", "Segoe UI")
        ; コンパクト時の高さを計測
        g.Show("Hide AutoSize")
        g.GetPos(, , &gw, &compactH)
        ; リスト部分（展開時に表示）
        lvW := gw - 20
        lv := g.Add("ListView", "xm w" . lvW . " r15 -Multi", ["名前", "パス"])
        lv.ModifyCol(1, 150)
        lv.ModifyCol(2, lvW - 154)
        g.SetFont("s8", "Segoe UI")
        hintLbl := g.Add("Text", "xm c808080", "クリック: TreeViewで選択")
        g.SetFont("s9", "Segoe UI")
        ; 展開時の高さ・ListView位置を計測（リストは表示状態で計測）
        g.Show("Hide AutoSize")
        g.GetPos(, , , &fullH)
        lv.GetPos(, &lvY0, , &lvH0)   ; ListView の初期 Y・高さ
        ; ジャンプ処理（ListView列から直接パスを再構築）
        _JumpTo(obj, row) {
            if (row = 0)
                return
            NaviSearch.HighlightedIdx := row  ; 次へ/前へと同期
            fname := lv.GetText(row, 1)
            fdir  := lv.GetText(row, 2)
            p := (fdir != "" ? fdir . "\" . fname : fname)
            if !(navi.GuiObj && WinExist(navi.GuiObj))
                return
            tv := navi.GuiObj["FolderTree"]
            if (DirExist(p)) {
                id := NaviSearch.EnsurePathExpanded(navi, tv, p)
                if (id)
                    tv.Modify(id, "Select Vis")
            } else if (FileExist(p)) {
                SplitPath(p, &fn, &fd)
                idDir := NaviSearch.EnsurePathExpanded(navi, tv, fd)
                if (idDir) {
                    NaviSearch.EnsureFilesShown(navi, tv, idDir, fd)
                    found := false
                    cid := tv.GetChild(idDir)
                    while (cid) {
                        if (tv.GetText(cid) = fn) {
                            tv.Modify(cid, "Select Vis")
                            found := true
                            break
                        }
                        cid := tv.GetNext(cid)
                    }
                    if (!found) {
                        fid := tv.Add(fn, idDir, "Icon2")
                        tv.Modify(fid, "Select Vis")
                    }
                }
            }
        }
        lv.OnEvent("Click", _JumpTo)
        lv.OnEvent("DoubleClick", _JumpTo)
        ; 右クリックメニュー（ListView列から直接パスを再構築）
        _OnContextMenu(obj, item, isRightClick, x, y) {
            if (item = 0 || item > lv.GetCount())
                return
            fname := lv.GetText(item, 1)
            fdir  := lv.GetText(item, 2)
            p := (fdir != "" ? fdir . "\" . fname : fname)
            m := Menu()
            m.Add("フルパスをコピー", (*) => (A_Clipboard := p))
            m.Add("フォルダをコピー", (*) => (A_Clipboard := fdir))
            m.Show()
        }
        lv.OnEvent("ContextMenu", _OnContextMenu)
        ; 列ヘッダークリックで並び替え（パス列は パス+名前 の複合キー）
        _OnColClick(ctrl, col) {
            ; 名前列（col=1）は常に昇順。パス列（col=2）のみ再クリックで降順トグル
            if (col = 1) {
                NaviSearch._SortCol  := col
                NaviSearch._SortDesc := false
            } else {
                if (NaviSearch._SortCol = col)
                    NaviSearch._SortDesc := !NaviSearch._SortDesc
                else {
                    NaviSearch._SortCol  := col
                    NaviSearch._SortDesc := false
                }
            }
            NaviSearch._SortJumpList(ctrl, col, NaviSearch._SortDesc)
        }
        lv.OnEvent("ColClick", _OnColClick)
        NaviSearch.JumpListView := lv
        ; リスト展開トグル（デフォルト: 展開表示）
        listShown := true
        _ToggleList(*) {
            if (listShown) {
                lv.Visible := false
                hintLbl.Visible := false
                listShown := false
                listBtn.Text := "リスト▽"
                g.Show("h" . compactH)
            } else {
                lv.Visible := true
                hintLbl.Visible := true
                listShown := true
                listBtn.Text := "リスト△"
                g.Show("h" . fullH)
            }
        }
        ; リサイズ時に ListView を追従させる
        _OnSize(gObj, minMax, w, h) {
            if (minMax = -1 || !listShown)
                return
            newLvW := w - 20
            newLvH := Max(lvH0 + (h - fullH), 50)
            lv.Move(, , newLvW, newLvH)
            hintLbl.Move(, lvY0 + newLvH)
            lv.ModifyCol(2, Max(newLvW - 154, 50))
        }
        ; イベント登録
        prev.OnEvent("Click", (*) => NaviSearch.Jump(navi, -1))
        next.OnEvent("Click", (*) => NaviSearch.Jump(navi, +1))
        listBtn.OnEvent("Click", _ToggleList)
        reSearchBtn.OnEvent("Click", (*) => NaviSearch.RunLocal(navi, NaviSearch.LastSearchBasePath))
        closeBtn.OnEvent("Click", (*) => NaviSearch.ClearHighlights(navi))
        g.OnEvent("Escape", (*) => NaviSearch.ClearHighlights(navi))
        g.OnEvent("Size", _OnSize)
        g.OnEvent("Close", (*) => NaviSearch.ClearHighlights(navi))
        ; 位置決め（Naviウィンドウの右側外側、上揃え）
        WinGetPos(&px, &py, &pw, &ph, "ahk_id " navi.GuiObj.Hwnd)
        x := px + pw + this.UI_MARGIN
        y := py
        g.Show("x" . x . " y" . y . " h" . fullH)
        ; 親は無効化しない（ツリー操作を阻害しない）
        this.LastNavi := navi
        this.JumpGui := g
        ; 親GUIクローズ時に自動クローズ
        try navi.GuiObj.OnEvent("Close", (*) => (NaviSearch._DestroyJumpGui()), 1)
        ; 親の存在監視タイマー
        this._StartParentWatch()
        this._UpdateJumpLabel()
        ; ホットキー登録
        this._SetupJumpGuiHotkeys(navi, g)
        ; Enter で選択行をジャンプ（再検索ボタンにフォーカスがある場合は再検索を優先）
        _OnEnter(*) {
            focused := ControlGetFocus("ahk_id " g.Hwnd)
            if (focused == reSearchBtn.Hwnd)
                NaviSearch.RunLocal(navi, NaviSearch.LastSearchBasePath)
            else if (focused == prev.Hwnd)
                NaviSearch.Jump(navi, -1)
            else if (focused == next.Hwnd)
                NaviSearch.Jump(navi, +1)
            else if (focused == listBtn.Hwnd)
                _ToggleList()
            else if (focused == closeBtn.Hwnd)
                NaviSearch.ClearHighlights(navi)
            else if (r := lv.GetNext(0))
                _JumpTo(lv, r)
        }
        HotIfWinActive("ahk_id " g.Hwnd)
        Hotkey("Enter", _OnEnter, "On")
        HotIf()
    }

    ; 検索ヒットウィンドウ用のホットキーを設定
    static _SetupJumpGuiHotkeys(navi, jumpGui) {
        try {
            HotIfWinActive("ahk_id " jumpGui.Hwnd)
            Hotkey("F3", ((*) => NaviSearch.Jump(navi, +1)), "On")
            Hotkey("+F3", ((*) => NaviSearch.Jump(navi, -1)), "On")
            Hotkey("F6", ((*) => NaviSearch._FocusNaviTree(navi)), "On")
            HotIf()
        }
    }

    ; 検索ヒットウィンドウ用のホットキーを解除
    static _RemoveJumpGuiHotkeys() {
        try {
            jg := this.JumpGui
            if (Type(jg) = "Gui" && jg.Hwnd) {
                HotIfWinActive("ahk_id " jg.Hwnd)
                Hotkey("F3", "Off")
                Hotkey("+F3", "Off")
                Hotkey("Enter", "Off")
                Hotkey("F6", "Off")
                HotIf()
            }
        }
    }



    static _UpdateJumpLabel() {
        try {
            jg := this.JumpGui
            if !(Type(jg) = "Gui" && jg.Hwnd && WinExist("ahk_id " jg.Hwnd))
                return
            lv    := this.JumpListView
            total := IsObject(lv) ? lv.GetCount() : 0
            idx   := IsObject(lv) ? lv.GetNext(0) : 0
            this.JumpLabel.Text := (total ? idx : 0) . " / " . total . " 件"
        }
    }

    static _FocusJumpGui() {
        jg := this.JumpGui
        if !(Type(jg) = "Gui" && jg.Hwnd && WinExist("ahk_id " jg.Hwnd))
            return
        WinActivate("ahk_id " jg.Hwnd)
        lv := this.JumpListView
        if IsObject(lv)
            lv.Focus()
    }

    static _FocusNaviTree(navi) {
        if !(navi.GuiObj && WinExist(navi.GuiObj))
            return
        WinActivate("ahk_id " navi.GuiObj.Hwnd)
        navi.GuiObj["FolderTree"].Focus()
    }

    static _DestroyJumpGui() {
        this._RemoveJumpGuiHotkeys()
        try this.JumpGui.Destroy()
        this.JumpGui := ""
        this.JumpLabel := ""
        this.JumpListView := ""
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
        try {
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
        } catch {
            this._StopParentWatch()
        }
    }

    ; NM_CUSTOMDRAW ハンドラーを登録（未登録なら）
    static _EnsureCustomDraw(tv, navi) {
        this._CustomDrawTvHwnd := tv.Hwnd
        this._NaviRef := navi
        if (this._CustomDrawHandler != "")
            return
        handler := (w, l, m, h) => NaviSearch._OnWMNotify(w, l, m, h)
        OnMessage(0x004E, handler)
        this._CustomDrawHandler := handler
    }

    ; WM_NOTIFY → NM_CUSTOMDRAW ハンドラー
    static _OnWMNotify(wParam, lParam, msg, hwnd) {
        ; 対象TreeView以外は無視
        if (NumGet(lParam, 0, "ptr") != NaviSearch._CustomDrawTvHwnd)
            return
        ; NMHDR.code  offset = A_PtrSize*2 (64bit:16 / 32bit:8)
        if (NumGet(lParam, A_PtrSize * 2, "int") != -12)  ; NM_CUSTOMDRAW
            return
        ; NMCUSTOMDRAW.dwDrawStage  offset (64bit:24 / 32bit:12)
        stageOff := (A_PtrSize = 8) ? 24 : 12
        stage    := NumGet(lParam, stageOff, "uint")
        if (stage = 0x1) {  ; CDDS_PREPAINT
            return NaviSearch._HighlightedIdSet.Count > 0 ? 0x20 : 0  ; CDRF_NOTIFYITEMDRAW / CDRF_DODEFAULT
        }
        if (stage = 0x10001) {  ; CDDS_ITEMPREPAINT
            ; NMCUSTOMDRAW.dwItemSpec (HTREEITEM)  offset (64bit:56 / 32bit:36)
            specOff := (A_PtrSize = 8) ? 56 : 36
            itemId  := NumGet(lParam, specOff, "ptr")
            ; フィルタマッチノードは NaviFilter の filter ハンドラーに委譲（優先度: filter > search）
            if (NaviFilter._FilterMatchIdSet.Has(itemId))
                return
            if (NaviSearch._HighlightedIdSet.Has(itemId)) {
                ; NMTVCUSTOMDRAW.clrText  offset (64bit:80 / 32bit:48)
                clrOff := (A_PtrSize = 8) ? 80 : 48
                NumPut("uint", NaviSearch.HIGHLIGHT_COLOR, lParam, clrOff)
                return 0  ; CDRF_DODEFAULT（変更した色で描画）
            }
        }
    }

    static ClearHighlights(navi) {
        this.CancelRequested := true  ; 検索中なら中止
        ; 検索中なら次のティックを待たず即座に停止（タイマー/fd を同期的に終了）
        ; こうしないと _FdTick が先に _Finish(true) を呼んでツリーを更新してしまう
        if (this.SearchActive)
            this._Finish(false)
        if !(navi.GuiObj && WinExist(navi.GuiObj))
            return
        tv := navi.GuiObj["FolderTree"]
        this.HighlightedIds := []
        this._HighlightedPaths := []
        this._HighlightedIdSet := Map()
        this.HighlightedIdx := 0
        try tv.Redraw()
        this._DestroyJumpGui()
        ToolTip("ハイライトをクリア")
        SetTimer(() => ToolTip(), -navi.TOOLTIP_SUCCESS_DURATION)
    }
}
