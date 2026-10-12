#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Fd.ahk
; Description:  fd（sharkdp/fd）と fzf（junegunn/fzf）を探して、窓を出さずに走らせる
;               - fd: ツリーの絞り込み・一覧の索引づくり（NaviFilter・NaviDirList）が使う
;                 なければ AutoHotkey でたどる（NaviFilter.WalkTree）。遅くなる理由は SlowWalkReason
;               - fzf: 件数の多い一覧の絞り込み（NaviDirList）が使う。なければ AutoHotkey で絞り込む
; ==============================================================================

class NaviFd {
    static IniPath := A_ScriptDir "\ui\navi\Navi.ini"
    static FdPath  := ""    ; _FindFd() の結果キャッシュ（"NOT_FOUND" = 見つからず）
    static FzfPath := ""    ; FindFzf() の結果キャッシュ（"NOT_FOUND" = 見つからず）
    static _indexFiles := Map()  ; 種類（dirs / files）→ 集め終わった一覧の fd の出力ファイル（fzf に渡す）
    static _staleFiles := []     ; 消せなかった古い出力ファイル（fzf が読んでいる途中など。次に消す）

    /**
     * fd.exe のパスを返す（見つからなければ ""）。結果はキャッシュ（設定を変えたら ResetFd で捨てる）
     * 探す順: 設定で指定したパス（[Search] FdPath）→ 自動（_AutoFd）
     * 指定したパスに fd.exe がなければ、自動で探した方を使う（設定の誤りで遅くならないように）
     */
    static _FindFd() {
        if (this.FdPath != "")
            return (this.FdPath = "NOT_FOUND") ? "" : this.FdPath
        path := this.ConfiguredFd()
        if (path == "" || !FileExist(path))
            path := this._AutoFd()
        this.FdPath := (path != "") ? path : "NOT_FOUND"
        return path
    }

    ; 設定で指定した fd.exe のパス（空欄なら ""）
    static ConfiguredFd() => Trim(IniRead(this.IniPath, "Search", "FdPath", ""), " `t`"")

    ; 設定を変えたときに、覚えている fd と fzf の場所を捨てる
    static ResetFd() {
        this.FdPath := ""
        this.FzfPath := ""
    }

    /**
     * fzf.exe のパスを返す（見つからなければ ""）。設定で使わないことにしていれば（[Search] UseFzfForList=0）""
     * 探す順は fd と同じ: 設定で指定したパス（[Search] FzfPath）→ 自動（bin\fzf.exe → PATH → winget）
     */
    static FindFzf() {
        if (IniRead(this.IniPath, "Search", "UseFzfForList", "1") == "0")
            return ""
        if (this.FzfPath == "") {
            path := this.ConfiguredFzf()
            if (path == "" || !FileExist(path))
                path := this._AutoFzf()
            this.FzfPath := (path != "") ? path : "NOT_FOUND"
        }
        return (this.FzfPath = "NOT_FOUND") ? "" : this.FzfPath
    }

    ; 設定で指定した fzf.exe のパス（空欄なら ""）
    static ConfiguredFzf() => Trim(IniRead(this.IniPath, "Search", "FzfPath", ""), " `t`"")

    static _AutoFd() => this._AutoTool("fd.exe", "sharkdp.fd_*")
    static _AutoFzf() => this._AutoTool("fzf.exe", "junegunn.fzf_*")

    /**
     * 集め終わった一覧の fd の出力ファイルを残す（kind: "dirs" / "files"）。fzf にそのまま渡す
     * （同じ内容を AutoHotkey で書き直すと、23 万件で 2 秒以上かかる）。前のファイルは消す
     */
    static KeepIndexFile(kind, path) {
        static cleanupOnExit := false
        this.DropIndexFile(kind)
        if (path == "")
            return
        this._indexFiles[kind] := path
        if !cleanupOnExit {  ; スクリプトを終えるときに、残したファイルを %TEMP% に置いていかない
            cleanupOnExit := true
            OnExit((*) => (this.DropIndexFile("dirs"), this.DropIndexFile("files"), 0))
        }
    }

    static IndexFile(kind) => this._indexFiles.Has(kind) ? this._indexFiles[kind] : ""

    ; 残したファイルを、消さずに預かりから外して返す（Navi を閉じても一覧を残すとき）
    static TakeIndexFile(kind) {
        path := this.IndexFile(kind)
        if this._indexFiles.Has(kind)
            this._indexFiles.Delete(kind)
        return path
    }

    ; 残したファイルを消す（一覧を捨てたとき）。fzf が読んでいて消せなければ、次の機会に消す
    static DropIndexFile(kind) {
        if (path := this.TakeIndexFile(kind))
            this._staleFiles.Push(path)
        keep := []
        for p in this._staleFiles {
            try FileDelete(p)
            if FileExist(p)
                keep.Push(p)
        }
        this._staleFiles := keep
    }

    /**
     * 自動で exe を探す（キャッシュしない）
     * 1) スクリプトの隣の bin\<exe>（置くだけで使える。持ち運び・winget が使えない PC 向け。git では無視）
     * 2) PATH  3) winget の入れ先（wingetPackage はパッケージのフォルダ名）
     */
    static _AutoTool(exe, wingetPackage) {
        bundled := A_ScriptDir . "\bin\" . exe
        if FileExist(bundled)
            return bundled

        ; SearchPath API で PATH から検索（cmd.exe を起動しないためフラッシュなし）
        buf := Buffer(2048, 0)   ; 1024 wide chars
        len := DllCall("SearchPath",
            "ptr",  0, "str", exe, "ptr", 0,
            "uint", 1024, "ptr", buf, "ptr", 0, "uint")
        if (len > 0) {
            path := StrGet(buf)
            if FileExist(path)
                return path
        }

        ; WinGet パッケージフォルダをスキャン
        wingetBase := EnvGet("LOCALAPPDATA") . "\Microsoft\WinGet\Packages"
        if DirExist(wingetBase) {
            loop files, wingetBase . "\" . wingetPackage . "\" . exe, "R"
                return A_LoopFileFullPath
        }
        return ""
    }

    /**
     * 一覧・絞り込みのために rootPath の下を集めるとき、遅い方（AutoHotkey でたどる）になる理由
     * fd で速く集められるなら ""。ネットワーク上はわざと fd を使わない（別に確認を出す）ので ""
     */
    static SlowWalkReason(rootPath) {
        if NaviFilter.IsOnNetwork(rootPath)
            return ""
        if (IniRead(this.IniPath, "Search", "UseFdForFilter", "1") == "0")
            return "高速化がオフのため"
        return (this._FindFd() == "") ? "fd がないため" : ""
    }

    ; fd.exe などを直接起動し stdout をファイルにリダイレクト（cmd.exe フラッシュなし）
    ; inFile を渡すと stdin をそのファイルにする（fzf に絞り込む一覧を渡す）
    ; STARTF_USESTDHANDLES で継承可能ハンドルを渡す。戻り値: PID（失敗時 0）
    static _RunNoWindowToFile(cmd, outFile, inFile := "") {
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
        hIn := 0
        if (inFile != "") {
            hIn := DllCall("CreateFile",
                "str",  inFile,
                "uint", 0x80000000,   ; GENERIC_READ
                "uint", 0x1,          ; FILE_SHARE_READ
                "ptr",  sa,
                "uint", 3,            ; OPEN_EXISTING
                "uint", 0x80,         ; FILE_ATTRIBUTE_NORMAL
                "ptr",  0, "ptr")
            if (hIn = -1 || hIn = 0) {
                DllCall("CloseHandle", "ptr", hFile)
                return 0
            }
        }

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
        NumPut("ptr",    hIn,    si, stdInOff)   ; hStdInput  = inFile（なければ NULL）
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
        if hIn
            DllCall("CloseHandle", "ptr", hIn)
        if (!ok)
            return 0
        DllCall("CloseHandle", "ptr", NumGet(pi, 0,           "ptr"))
        DllCall("CloseHandle", "ptr", NumGet(pi, A_PtrSize,   "ptr"))
        return NumGet(pi, A_PtrSize * 2, "uint")   ; dwProcessId
    }

    /**
     * fd が書き出している途中のファイルから、前回読んだ所（pos。バイト位置）より後の行を返し、pos を進める
     * fd は見つけた順に書き出すので、終わるのを待たずに途中までの結果を使える
     * 書きかけの最後の行は次に回す（UTF-8 の文字の途中で切らないよう、改行のバイトで区切る）。toEnd なら最後まで読む
     */
    static ReadNewLines(path, &pos, toEnd := false) {
        lines := []
        try f := FileOpen(path, "r")
        catch
            return lines
        size := f.Length
        if (size > pos) {
            f.Pos := pos
            buf := Buffer(size - pos)
            got := f.RawRead(buf)
            cut := got
            if !toEnd {
                while (cut > 0 && NumGet(buf, cut - 1, "uchar") != 10)
                    cut--
            }
            if (cut > 0) {
                pos += cut
                for line in StrSplit(StrGet(buf, cut, "UTF-8"), "`n", "`r") {
                    if (line != "")
                        lines.Push(line)
                }
            }
        }
        f.Close()
        return lines
    }
}
