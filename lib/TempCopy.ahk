; ==============================================================================
; Module:       TempCopy.ahk
; Description:  一時フォルダにファイルをコピーして開くユーティリティ
;               - ショートカット(.lnk)の場合はリンク先のファイルをコピー
;               - ファイル名にタイムスタンプのプレフィックスを付与
; Version:      1.0.0
; License:      MIT
; ==============================================================================
#Requires AutoHotkey v2.0

class TempCopy {
    ; --- クラス定数 ---
    static TEMP_DIR_SUBPATH := "\temp"
    static TEMP_PREFIX := "TEMP_"
    static TOOLTIP_ERROR_DURATION := 2000
    static TOOLTIP_SUCCESS_DURATION := 1000
    static LARGE_FILE_THRESHOLD := 104857600  ; 100MB (バイト単位)

    /**
     * エクスプローラーで選択中のファイル/フォルダのパスを取得
     * クリップボード方式で確実にパスを取得
     * @returns {String} 選択中のパス（複数選択時は最初の1つ）
     */
    static GetSelectedPath() {
        ; 元のクリップボードを保存
        clipBackup := ClipboardAll()
        A_Clipboard := ""

        ; Ctrl+C でパスをコピー
        Send("^c")

        ; クリップボードにデータが来るまで待機（最大1秒）
        if !ClipWait(1) {
            ; クリップボードを復元
            A_Clipboard := clipBackup
            return ""
        }

        ; クリップボードからパスを取得
        path := A_Clipboard

        ; クリップボードを復元
        A_Clipboard := clipBackup

        return path
    }

    /**
     * 選択ファイルを一時フォルダにコピーし、既定アプリで開く
     * ファイル名に TEMP_YYYYMMDD-HHMMSS_ の接頭辞を付与
     * ショートカット(.lnk)の場合は、ショートカットの先のファイルをコピー
     * パスが空の場合は、テンポラリフォルダを開く
     *
     * @param path - ファイルまたはフォルダのパス（空の場合はテンポラリフォルダを開く）
     */
    static Open(path) {
        tempDir := A_ScriptDir . this.TEMP_DIR_SUBPATH
        try {
            if (!DirExist(tempDir))
                DirCreate(tempDir)
        } catch as e {
            ToolTip("一時フォルダ作成失敗: " . e.Message)
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }

        ; パスが空の場合、テンポラリフォルダを開く
        if (path == "") {
            Run('explorer.exe "' . tempDir . '"')
            ToolTip("Temp folder opened: " . tempDir)
            SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
            return
        }

        ; フォルダが渡された場合はファイルのみ対象であることを通知して終了
        if (DirExist(path)) {
            ToolTip("TempCopy はファイルのみ対象です")
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }

        if (!FileExist(path)) {
            ToolTip("ファイルが見つかりません")
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
            return
        }

        ; ショートカットファイルの場合は先のファイルを取得
        actualPath := path
        SplitPath(path, , , &ext)
        if (StrLower(ext) == "lnk") {
            try {
                FileGetShortcut(path, &targetPath)
                if (targetPath != "" && FileExist(targetPath)) {
                    actualPath := targetPath
                } else {
                    ToolTip("ショートカットの先が見つかりません")
                    SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
                    return
                }
            } catch as e {
                ToolTip("ショートカットの解決に失敗: " . e.Message)
                SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
                return
            }
        }

        ; ファイルサイズチェック
        try {
            fileSize := FileExist(actualPath) ? FileGetSize(actualPath) : 0
            if (fileSize > this.LARGE_FILE_THRESHOLD) {
                sizeMB := Round(fileSize / 1048576, 1)
                result := MsgBox("ファイルサイズが " . sizeMB . " MB です。`nコピーして開きますか？",
                                 "大きなファイル", "YesNo Icon? 4096")
                if (result = "No")
                    return
            }
        }

        SplitPath(actualPath, &fileName, , &fileExt)
        ts := FormatTime(, "yyyyMMdd-HHmmss") ; YYYYMMDD-HHMMSS
        dest := tempDir . "\" . this.TEMP_PREFIX . ts . "_" . fileName

        ; 実行可能ファイルのリスト（セキュリティリスクがあるため自動実行しない）
        dangerousExts := [
            "exe", "bat", "cmd", "ps1", "vbs", "scr", "msi", "com", "pif",  ; 実行ファイル
            "js", "jse", "wsf", "wsh", "hta",                               ; Windows Script Host系
            "reg", "cpl", "jar", "ahk", "url",                              ; レジストリ/コントロールパネル/スクリプト
            "application", "gadget", "inf"                                   ; その他実行可能
        ]
        isDangerous := false
        for ext in dangerousExts {
            if (StrLower(fileExt) == ext) {
                isDangerous := true
                break
            }
        }

        try {
            FileCopy(actualPath, dest, true)

            if (isDangerous) {
                ; 実行可能ファイルの場合はエクスプローラーで選択表示（自動実行しない）
                Run('explorer.exe /select,"' . dest . '"')
                ToolTip("実行可能ファイルをコピー（自動実行なし）: " . dest)
            } else {
                ; 通常ファイルは既定アプリで開く
                Run('"' . dest . '"')
                ToolTip("Temp copy opened: " . dest)
            }
            SetTimer(() => ToolTip(), -this.TOOLTIP_SUCCESS_DURATION)
        } catch as e {
            ToolTip("コピーまたは起動に失敗: " . e.Message)
            SetTimer(() => ToolTip(), -this.TOOLTIP_ERROR_DURATION)
        }
    }
}
