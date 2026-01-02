; ==============================================================================
; Module:       FolderToggle.ahk
; Description:  ファイラー（エクスプローラー/Tablacus等）の表示・非表示切り替え
;               - アクティブ時は最小化、非アクティブ時は表示・アクティブ化
;               - 最小化時に直前のウィンドウへフォーカスを自動復元する機能を搭載
;               - 標準エクスプローラーおよび Tablacus Explorer に対応
;               - 初回起動時に実行ファイルのパスを自動設定・INI保存する機能
; Version:      1.0.0
; License:      MIT
;
; Usage Example (Main.ahk):
;   #Include FolderToggle.ahk
;   FolderToggle.Init("config.ini")
;   vk1D & e:: FolderToggle.Execute() ; 無変換 + e で起動
; ==============================================================================
#Requires AutoHotkey v2.0

class FolderToggle {
    ; ============ 設定 =====================
    static FILE_SELECT_OPT := 3      ; ファイル・フォルダ存在チェック有効化
    static WINDOW_MINIMIZED := -1     ; WinGetMinMaxの最小化判定値
    static WAIT_TIMEOUT_SEC := 3      ; ウィンドウ表示待ちのタイムアウト
    static SLEEP_FOCUS_BUFFER := 10     ; フォーカス制御の待機時間
    static SLEEP_ANIMATION := 100    ; 最小化アニメーションの完了待ち
    static SLEEP_RETRY_ACT := 50     ; アクティブ化再試行の待機時間
    ; ========================================

    static TargetWin := ""
    static PrevHwnd := 0
    static ExplorerPath := ""
    static IniPath := ""

    static Init(iniPath, section := "Common") {
        this.IniPath := iniPath
        this.ExplorerPath := this._LoadConfig(section)

        SplitPath(this.ExplorerPath, &exeName)

        if (exeName = "explorer.exe") {
            this.TargetWin := "ahk_class CabinetWClass"
        } else {
            ; Tablacusの場合、ahk_exeよりもクラス名の方が安定
            this.TargetWin := "ahk_class TablacusExplorer"
        }
    }

    static _LoadConfig(section) {
        path := IniRead(this.IniPath, section, "ExplorerPath", "")
        if (path == "" || !FileExist(path)) {
            msg := "エクスプローラーのパスが未設定です。`n`n[Yes]: 外部ファイラーを選択`n[No]: 標準エクスプローラー"
            if (MsgBox(msg, "初期設定", "YesNo") == "Yes") {
                selected := FileSelect(this.FILE_SELECT_OPT, , "exeを選択", "*.exe")
                path := (selected != "") ? selected : ExitApp()
            } else {
                path := "explorer.exe"
            }
            IniWrite(path, this.IniPath, section, "ExplorerPath")
        }
        return path
    }

    static Execute() {
        targetHwnd := WinExist(this.TargetWin)

        ; 1. ターゲットがアクティブな場合は最小化
        if (targetHwnd && WinActive("ahk_id " targetHwnd)) {
            WinMinimize("ahk_id " targetHwnd)
            this._RestoreFocus()
            return
        }

        ; 2. ターゲットが非アクティブな場合、現在のウィンドウを記録
        activeID := WinActive("A")
        if (activeID && activeID != targetHwnd) {
            this.PrevHwnd := activeID
        }

        if (targetHwnd) {
            ; 最小化状態を判定して復元
            if (WinGetMinMax("ahk_id " targetHwnd) = this.WINDOW_MINIMIZED)
                WinRestore("ahk_id " targetHwnd)

            WinActivate("ahk_id " targetHwnd)
            Sleep(this.SLEEP_FOCUS_BUFFER)
        } else {
            try {
                Run(this.ExplorerPath)
                if (WinWait(this.TargetWin, , this.WAIT_TIMEOUT_SEC))
                    WinActivate(this.TargetWin)
            } catch Error as e {
                MsgBox("起動失敗: " e.Message)
            }
        }
    }

    static _RestoreFocus() {
        Sleep(this.SLEEP_ANIMATION)

        if (this.PrevHwnd && WinExist("ahk_id " this.PrevHwnd)) {
            WinActivate("ahk_id " this.PrevHwnd)

            if (!WinActive("ahk_id " this.PrevHwnd)) {
                Sleep(this.SLEEP_RETRY_ACT)
                WinActivate("ahk_id " this.PrevHwnd)
            }
        } else {
            WinActivate("ahk_class Shell_TrayWnd")
        }
    }
}
