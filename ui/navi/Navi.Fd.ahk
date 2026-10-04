#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Fd.ahk
; Description:  fd（sharkdp/fd）を探して、窓を出さずに走らせる
;               - ツリーの絞り込み・一覧の索引づくり（NaviFilter・NaviDirList）が使う
;               - fd がなければ AutoHotkey でたどる（NaviFilter.WalkTree）。遅くなる理由は SlowWalkReason
; ==============================================================================

class NaviFd {
    static IniPath := A_ScriptDir "\ui\navi\Navi.ini"
    static FdPath  := ""    ; _FindFd() の結果キャッシュ（"NOT_FOUND" = 見つからず）

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

    ; 設定を変えたときに、覚えている fd の場所を捨てる
    static ResetFd() {
        this.FdPath := ""
    }

    /**
     * 自動で fd.exe を探す（キャッシュしない）
     * 1) スクリプトの隣の bin\fd.exe（置くだけで使える。持ち運び・winget が使えない PC 向け。git では無視）
     * 2) PATH  3) winget の入れ先
     */
    static _AutoFd() {
        bundled := A_ScriptDir . "\bin\fd.exe"
        if FileExist(bundled)
            return bundled

        ; SearchPath API で PATH から検索（cmd.exe を起動しないためフラッシュなし）
        buf := Buffer(2048, 0)   ; 1024 wide chars
        len := DllCall("SearchPath",
            "ptr",  0, "str", "fd.exe", "ptr", 0,
            "uint", 1024, "ptr", buf, "ptr", 0, "uint")
        if (len > 0) {
            path := StrGet(buf)
            if FileExist(path)
                return path
        }

        ; WinGet パッケージフォルダをスキャン
        wingetBase := EnvGet("LOCALAPPDATA") . "\Microsoft\WinGet\Packages"
        if DirExist(wingetBase) {
            loop files, wingetBase . "\sharkdp.fd_*\*\fd.exe", "R"
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
}
