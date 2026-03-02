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
    static _ParentWatchFn := ""
    static Results := []           ; 検索結果のフルパス一覧
    static JumpListView := ""      ; 一体型ウィンドウのListViewへの参照
    static _HighlightedPaths := [] ; HighlightedIds と同順のパス一覧（リスト同期用）
    static _HighlightedIdSet := Map()  ; カスタムドロー用 O(1) ルックアップ
    static _CustomDrawHandler := ""    ; WM_NOTIFY ハンドラー参照
    static _CustomDrawTvHwnd := 0      ; 対象TreeViewのHwnd
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
        ; 設定を読み込み（除外リスト、タイムアウト等）
        this._LoadSettings()
        ; モーダル・最前面の検索入力ダイアログ
        q := this._PromptQuery(navi, basePath)
        if (q = "")
            return
        ; タイプフィルター（d: = ディレクトリのみ, f: = ファイルのみ）
        typeFilter := "all"
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

        ; 非同期タスクを初期化
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
        ; タイマーループ開始
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
        ; タイムアウト、キャンセル、または十分な結果数に達した場合（TimeoutMs=0は無制限）
        if (this.CancelRequested
            || (this.TimeoutMs > 0 && A_TickCount - t["startedAt"] >= this.TimeoutMs)
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

        ; 除外ディレクトリ
        eg.Add("Text", "xm", "除外ディレクトリ（1行に1つ）:")
        editBox := eg.Add("Edit", "xm w" . this.SETTINGS_DIALOG_W . " h" . this.SETTINGS_EDIT_H . " vExcludeList", currentList)
        btnSave := eg.Add("Button", "xm w" . this.SETTINGS_BTN_W, "保存")
        btnReset := eg.Add("Button", "x+" . this.GAP_X_MED . " w" . this.SETTINGS_BTN_W, "初期値に戻す")
        btnClose := eg.Add("Button", "x+" . this.GAP_X_MED . " w" . this.SETTINGS_BTN_W, "閉じる")

        btnSave.OnEvent("Click", (*) => this._SaveSettingsFromEditor(eg, editBox, timeoutEdit))
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
    static _SaveSettingsFromEditor(eg, editBox, timeoutEdit) {
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
  d:          ディレクトリのみ（例: d: src）
  f:          ファイルのみ（例: f: *.json）

【例】
  d: test         testを含むディレクトリ
  f: *.js|*.ts    .js または .ts ファイル
  config !backup  configを含むがbackupを除外
        )"
        ToolTip(help)
        SetTimer(() => ToolTip(), -this.TOOLTIP_HELP_DURATION)
    }

    ; --- 検索入力ダイアログ（Navi付近に最前面表示） ---
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
        btnOK := g.Add("Button", "xm w" . this.BTN_W_LARGE . " Default", "OK")
        btnCancel := g.Add("Button", "x+" . this.GAP_X_MED . " w" . this.BTN_W_LARGE, "キャンセル")
        btnExclude := g.Add("Button", "x+" . this.GAP_X_MED . " w" . this.BTN_W_LARGE, "設定")
        res := ""
        btnOK.OnEvent("Click", (*) => (res := Trim(inputEdit.Value), g.Destroy()))
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
        return res
    }

    static _Finish(showResults) {
        SetTimer(, 0)
        this._HideProgress()
        this.SearchActive := false
        if (showResults) {
            t := this.Task
            this.Results := (Type(t) = "Map" && t.Has("results")) ? t["results"] : []
            nv := t["navi"]
            if (nv.GuiObj && WinExist(nv.GuiObj)) {
                tv := nv.GuiObj["FolderTree"]
                this.HighlightPathsInTree(nv, tv, t["basePath"], t["results"])
                this._EnsureJumpGui(nv)
            }
        } else {
            this.Results := []
        }
        this.Task := ""
        this.CancelRequested := false
    }

    ; プログレスUIの表示とキャンセル機能
    static _ShowProgress(navi) {
        ; マルチモニタでの座標ずれ回避のためオーナーは付けない（絶対座標で配置）
        this.ProgressGui := Gui("+AlwaysOnTop -Caption +ToolWindow +Border")
        this.ProgressGui.SetFont("s9", "Segoe UI")
        this.ProgressLabel := this.ProgressGui.Add("Text", "xm ym w" . this.LABEL_W_PROGRESS, "検索中...")
        btn := this.ProgressGui.Add("Button", "x+" . this.GAP_X_LARGE . " yp w" . this.BTN_W_SMALL, "中止")
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
        skipped := t["skippedDirs"]
        ; ASCIIプログレスバー（タイムアウトまでの進捗、0=無制限時はスピナー）
        if (this.TimeoutMs > 0)
            progressBar := this._MakeProgressBar(elapsed, this.TimeoutMs)
        else
            progressBar := this._MakeSpinner(elapsed)
        msg := progressBar . " hits:" . t["results"].Length
             . " dirs:" . t["processedDirs"]
             . (skipped > 0 ? " skip:" . skipped : "")
        this.ProgressLabel.Text := msg
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
        try this.ProgressGui.Destroy()
        this.ProgressGui := ""
        this.ProgressLabel := ""
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
                ; NaviのEsc=閉じるを再登録（検索キャンセルで上書きされたため）
                HotIfWinActive("ahk_id " nv.GuiObj.Hwnd)
                Hotkey("Esc", (*) => nv._DestroyGui(), "On")
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
        ; NM_CUSTOMDRAW ハンドラー登録 → 文字色変更
        this._EnsureCustomDraw(tv)
        tv.Redraw()
        ToolTip("ハイライト: " . shownCount . "件")
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
        HotIf()
    }

    static Jump(navi, delta) {
        if !(navi.GuiObj && WinExist(navi.GuiObj))
            return
        tv := navi.GuiObj["FolderTree"]
        total := this.HighlightedIds.Length
        if (total = 0) {
            ToolTip("ヒットなし")
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
        ToolTip(idx . " / " . total . " 件目")
        SetTimer(() => ToolTip(), -navi.TOOLTIP_SUCCESS_DURATION)
        this._UpdateJumpLabel()
        ; リストが展開中なら対応行を選択
        try {
            lv := this.JumpListView
            if (IsObject(lv) && lv.Visible) {
                path := this._HighlightedPaths[idx]
                for i, p in this.Results {
                    if (p = path) {
                        lv.Modify(0, "-Select")
                        lv.Modify(i, "Select Vis")
                        break
                    }
                }
            }
        }
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
        results := this.Results
        g := Gui("+Owner" . navi.GuiObj.Hwnd . " +Resize +AlwaysOnTop +ToolWindow -MaximizeBox -MinimizeBox", "検索ヒット")
        g.SetFont("s9", "Segoe UI")
        ; ボタン行
        prev    := g.Add("Button", "xm w" . this.BTN_W_SMALL, "前へ")
        next    := g.Add("Button", "x+" . this.GAP_X_SMALL . " w" . this.BTN_W_SMALL, "次へ")
        clr     := g.Add("Button", "x+" . this.GAP_X_SMALL . " w" . this.BTN_W_SMALL, "解除")
        listBtn := g.Add("Button", "x+" . this.GAP_X_SMALL . " w" . this.BTN_W_SMALL, "リスト▽")
        this.JumpLabel := g.Add("Text", "x+" . this.GAP_X_LARGE . " w" . this.LABEL_W_HITS, "")
        closeBtn := g.Add("Button", "x+" . this.GAP_X_SMALL . " w" . this.BTN_W_SMALL, "閉じる")
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
        for p in results {
            SplitPath(p, &fname, &fdir)
            lv.Add("", fname, fdir)
        }
        g.SetFont("s8", "Segoe UI")
        hintLbl := g.Add("Text", "xm c808080", "クリック: TreeViewで選択")
        g.SetFont("s9", "Segoe UI")
        ; 展開時の高さ・ListView位置を計測してからリストを非表示に
        g.Show("Hide AutoSize")
        g.GetPos(, , , &fullH)
        lv.GetPos(, &lvY0, , &lvH0)   ; ListView の初期 Y・高さ
        lv.Visible := false
        hintLbl.Visible := false
        ; ジャンプ処理
        _JumpTo(obj, row) {
            if (row = 0)
                return
            p := results[row]
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
        ; 右クリックメニュー
        _OnContextMenu(obj, item, isRightClick, x, y) {
            if (item = 0)
                return
            p := results[item]
            SplitPath(p, , &fd)
            m := Menu()
            m.Add("フルパスをコピー", (*) => (A_Clipboard := p))
            m.Add("フォルダをコピー", (*) => (A_Clipboard := fd))
            m.Show()
        }
        lv.OnEvent("ContextMenu", _OnContextMenu)
        NaviSearch.JumpListView := lv
        ; リスト展開トグル
        listShown := false
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
        clr.OnEvent("Click", (*) => NaviSearch.ClearHighlights(navi))
        listBtn.OnEvent("Click", _ToggleList)
        closeBtn.OnEvent("Click", (*) => NaviSearch.ClearHighlights(navi))
        g.OnEvent("Escape", (*) => NaviSearch.ClearHighlights(navi))
        g.OnEvent("Size", _OnSize)
        g.OnEvent("Close", (*) => this._RemoveJumpGuiHotkeys())
        ; 位置決め（Naviウィンドウの下部外側、左揃え）
        WinGetPos(&px, &py, &pw, &ph, "ahk_id " navi.GuiObj.Hwnd)
        x := px
        y := py + ph + this.UI_MARGIN
        g.Show("x" . x . " y" . y . " h" . compactH)
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
    }

    ; 検索ヒットウィンドウ用のホットキーを設定
    static _SetupJumpGuiHotkeys(navi, jumpGui) {
        try {
            HotIfWinActive("ahk_id " jumpGui.Hwnd)
            Hotkey("F3", ((*) => NaviSearch.Jump(navi, +1)), "On")
            Hotkey("+F3", ((*) => NaviSearch.Jump(navi, -1)), "On")
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
                HotIf()
            }
        }
    }



    static _UpdateJumpLabel() {
        try {
            jg := this.JumpGui
            if !(Type(jg) = "Gui" && jg.Hwnd && WinExist("ahk_id " jg.Hwnd))
                return
            total := this.HighlightedIds.Length
            idx := this.HighlightedIdx
            this.JumpLabel.Text := (total ? idx : 0) . " / " . total . " 件"
        }
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
    static _EnsureCustomDraw(tv) {
        this._CustomDrawTvHwnd := tv.Hwnd
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
            if (NaviSearch._HighlightedIdSet.Has(itemId)) {
                ; NMTVCUSTOMDRAW.clrText  offset (64bit:80 / 32bit:48)
                clrOff := (A_PtrSize = 8) ? 80 : 48
                NumPut("uint", NaviSearch.HIGHLIGHT_COLOR, lParam, clrOff)
                return 0  ; CDRF_DODEFAULT（変更した色で描画）
            }
        }
    }

    static ClearHighlights(navi) {
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
