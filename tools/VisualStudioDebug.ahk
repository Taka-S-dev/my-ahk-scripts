; ==============================================================================
; Module:       VisualStudioDebug.ahk
; Description:  Visual Studio デバッグ操作の高速化ホットキー集
;               - カーソル行まで実行 / ステップオーバー / ステップイン
;               - ステップアウト / 続行 / すべて中断
;               - ブレークポイント切替 / 次のステートメントに設定
;               - クリック連打用フローティングパネル（無変換+0 でトグル）
;               マウスをコード上に置いたまま、無変換リーダー + 右手ホーム
;               ポジション周辺でステップ実行を完結させることを目的とする。
;               マウス作業中はパネルの同一ボタンを連打してステップできる。
;               パネルは同梱の汎用部品 FloatingPanel.ahk を利用。
; Version:      1.2.0
; License:      MIT
;
; 単独起動（直接実行）またはMain.ahkからの #Include 両方に対応
; アクティブ判定は devenv.exe（VS のバージョン差異に強いプロセス名判定）
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Force
SetWorkingDir A_ScriptDir

#Include "FloatingPanel.ahk"

class VisualStudioDebug {
    /**
     * Visual Studio がアクティブかどうか
     * 各操作の先頭ガードで共通利用する
     */
    static IsActive() => WinActive("ahk_exe devenv.exe")

    /**
     * 任意のキー列を VS へ送る汎用ヘルパ（カスタムボタン/ホットキー用）
     * 例: VisualStudioDebug.SendKeys("+{F5}")  ; Stop Debugging
     */
    static SendKeys(keys) {
        if !this.IsActive()
            return
        Send(keys)
    }

    /**
     * カーソル行の前まで実行 (Run To Cursor)
     */
    static RunToCursor() => this.SendKeys("^{F10}")

    /**
     * ステップオーバー (Step Over)
     */
    static StepOver() => this.SendKeys("{F10}")

    /**
     * ステップイン (Step Into)
     */
    static StepInto() => this.SendKeys("{F11}")

    /**
     * ステップアウト (Step Out)
     */
    static StepOut() => this.SendKeys("+{F11}")

    /**
     * 続行 / デバッグ開始 (Continue / Start Debugging)
     */
    static Continue() => this.SendKeys("{F5}")

    /**
     * すべて中断 (Break All)
     */
    static BreakAll() => this.SendKeys("^!{Pause}")

    /**
     * ブレークポイント切替 (Toggle Breakpoint)
     */
    static ToggleBreakpoint() => this.SendKeys("{F9}")

    /**
     * 次のステートメントに設定 (Set Next Statement)
     * 実行ポインタ（黄色い矢印）をカーソル行へ移動。コードを飛ばす/巻き戻して再実行できる。
     */
    static SetNextStatement() => this.SendKeys("^+{F10}")

    /**
     * デバッグ停止 (Stop Debugging)
     */
    static StopDebugging() => this.SendKeys("+{F5}")

    /**
     * 再起動 (Restart Debugging)
     */
    static RestartDebugging() => this.SendKeys("^+{F5}")

    ; ==========================================================================
    ; クリック連打用フローティングパネル（FloatingPanel.ahk を利用）
    ; マウスに手を置いたままステップしたいとき（変数ホバー/Autos を見ながら）に、
    ; 同じ位置のボタンを連打してステップを進める用途。
    ; ==========================================================================
    static _panel    := ""
    static _IniPath  => A_ScriptDir . "\VisualStudioDebug.ini"
    static TRAY_ITEM := "デバッグパネルを表示/非表示"

    /**
     * パネルのボタン定義（▼ ここを編集。各行が独立なのでカンマ管理は不要）
     *   - 追加     : b.Push(...) の行を足す（既存行をコピペでOK）
     *   - 非表示   : 行を削除 or 先頭に ";" を付けてコメントアウト
     *   - 並べ替え : 行を上下に移動するだけ
     * フィールド: label=表示文字(必須) / action=処理(必須) /
     *            color=文字色(省略可) / bg=背景色(省略可) / h=高さ(省略時30)
     * 色の例: 白FFFFFF 灰CCCCCC 緑89D185 青4FC1FF 黄DCDCAA 赤F48771
     * action は VS へキーを送るだけなら SendKeys("...") が手軽（例: Stop=+{F5}）
     */
    static _PanelButtons() {
        b := []
        b.Push({ label: "⤼  Step Over", color: "FFFFFF", bg: "37373D", h: 40, action: () => VisualStudioDebug.StepOver() })
        b.Push({ label: "↘  Step Into", color: "CCCCCC", action: () => VisualStudioDebug.StepInto() })
        b.Push({ label: "↗  Step Out", color: "CCCCCC", action: () => VisualStudioDebug.StepOut() })
        b.Push({ label: "⤓  Run to Cursor", color: "4FC1FF", action: () => VisualStudioDebug.RunToCursor() })
        b.Push({ label: "↪  Set Next Stmt", color: "DCDCAA", action: () => VisualStudioDebug.SetNextStatement() })
        b.Push({ label: "▶  Continue", color: "89D185", action: () => VisualStudioDebug.Continue() })
        b.Push({ label: "■  Stop", color: "F48771", action: () => VisualStudioDebug.StopDebugging() })
        b.Push({ label: "↻  Restart", color: "4EC9B0", action: () => VisualStudioDebug.RestartDebugging() })
        ; --- カスタムボタンの例（先頭の ";" を外すと有効化。コピーして増やせる）---
        ; b.Push({ label: "👁  Quick Watch", color: "CCCCCC", action: () => VisualStudioDebug.SendKeys("+{F9}") })
        return b
    }

    ; パネルインスタンスを遅延生成して返す
    static _GetPanel() {
        if (this._panel == "")
            this._panel := FloatingPanel({
                name:    "vsdebug",
                title:   "VS Debug",
                iniPath: this._IniPath,
                width:    166,   ; パネル幅（大きく/小さく）
                fontSize: 10,    ; 文字サイズ（上げるとパネルも拡大）
                opacity:  255,   ; 透過度 0-255（例: 220 で少し透ける）
                onVisible: (v) => VisualStudioDebug._SyncTray(v),  ; 全経路でトレイのチェックを同期
                buttons: this._PanelButtons()
            })
        return this._panel
    }

    /**
     * フローティングパネルの表示/非表示をトグル
     * （トレイのチェック同期は onVisible コールバックが全経路で行う）
     */
    static TogglePanel() {
        this._GetPanel().Toggle()
    }

    /**
     * トレイメニューにパネル切替項目を追加する（単独起動時に呼ぶ）
     * ダブルクリックでもトグルできるようデフォルト項目に設定
     */
    static SetupTray() {
        tray := A_TrayMenu
        tray.Add()  ; 区切り線
        tray.Add(this.TRAY_ITEM, (*) => VisualStudioDebug.TogglePanel())
        tray.Default := this.TRAY_ITEM
        tray.Add("パネル設定…（透過/サイズ）", (*) => VisualStudioDebug._GetPanel().ShowSettings())
    }

    ; トレイメニューのチェック状態をパネル表示状態に同期（未登録でも安全）
    static _SyncTray(visible) {
        try visible ? A_TrayMenu.Check(this.TRAY_ITEM) : A_TrayMenu.Uncheck(this.TRAY_ITEM)
    }
}

; トレイメニューからもパネルを切り替えられるようにする（ホットキーを忘れても操作可能）
VisualStudioDebug.SetupTray()

; 単独起動時のみホットキーを登録
; 右手ホームポジション周辺（;.,/）に頻度順で配置、9=F9ニーモニック、Space=緊急中断
#HotIf WinActive("ahk_exe devenv.exe") && GetKeyState("vk1D", "P")
`;::   VisualStudioDebug.RunToCursor()      ; 最も押しやすい = カーソル行まで実行
.::    VisualStudioDebug.StepOver()         ; 次に押しやすい = ステップオーバー
,::    VisualStudioDebug.StepInto()         ; ステップイン
/::    VisualStudioDebug.StepOut()          ; ステップアウト
Enter:: VisualStudioDebug.Continue()        ; 続行 / デバッグ開始
Space:: VisualStudioDebug.BreakAll()        ; すべて中断（左親指から届く）
9::    VisualStudioDebug.ToggleBreakpoint() ; F9 のニーモニック
0::    VisualStudioDebug.TogglePanel()      ; クリック連打パネルの表示/非表示
n::    VisualStudioDebug.SetNextStatement() ; Next statement = カーソル行へ実行ポインタ移動
#HotIf

; --- オプション: マウスサイドボタン拡張 ---
; サイドボタン付きマウス導入時に有効化（無変換リーダー不要で直接操作）
/*
#HotIf WinActive("ahk_exe devenv.exe")
XButton1::    VisualStudioDebug.StepOver()       ; 手前 = ステップオーバー
XButton2::    VisualStudioDebug.StepInto()       ; 奥   = ステップイン
+XButton1::   VisualStudioDebug.StepOut()        ; Shift+手前 = ステップアウト
^XButton1::   VisualStudioDebug.RunToCursor()    ; Ctrl+手前  = カーソル行まで実行
#HotIf
*/
