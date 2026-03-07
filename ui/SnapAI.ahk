; ==============================================================================
; Module:       SnapAI.ahk
; Description:  OpenAI 互換 API を利用した AI テキスト処理ツール
;               - 選択テキストをホットキーで LLM API に送信
;               - 翻訳・要約・説明など保存プロンプトによる処理
;               - テキスト未選択時は手入力モードで自由入力にも対応
;               - 処理中はプログレス GUI を表示、キャンセル・タイムアウト対応
; Version:      1.0.0
; License:      MIT
;
; Usage Example (Main.ahk):
;   #Include "ui\SnapAI.ahk"
;   SnapAI.Init()
;   #HotIf GetKeyState("vk1D", "P")   ; 無変換キーを押しながら
;   t:: SnapAI.Show()
;   #HotIf
;
; ==============================================================================
#Requires AutoHotkey v2.0

class SnapAI {
    static GuiObj := ""
    static EditObj := ""
    static IniPath := A_AppData "\SnapAI\SnapAI.ini"
    static ApiKey := ""
    static ApiEndpoint := ""
    static _pendingText := ""
    static _whr := ""
    static _pollFn := ""
    static GUI_WIDTH := 500
    static GUI_HEIGHT := 350
    static IniVersion := 2      ; INIスキーマのバージョン。設定項目追加時にインクリメント
    static AutoCopy := false
    static _startTime := 0
    static _progressGui := ""
    static _progressBar := ""
    static TIMEOUT_MS       := 30000  ; APIタイムアウト（ミリ秒）
    static POLL_INTERVAL_MS := 200    ; レスポンスポーリング間隔（ミリ秒）
    static MAX_INPUT_CHARS  := 8000   ; 送信テキストの最大文字数

    static Init() {
        DirCreate(A_AppData "\SnapAI")
        if !FileExist(this.IniPath) {
            IniWrite("YOUR_API_KEY_HERE",                                   this.IniPath, "Settings", "ApiKey")
            IniWrite("https://api.openai.com/v1/chat/completions",          this.IniPath, "Settings", "ApiEndpoint")
            IniWrite("gpt-4o-mini",                                         this.IniPath, "Settings", "Model")
            IniWrite("0.5",                                                 this.IniPath, "Settings", "Temperature")
            IniWrite("2000",                                                this.IniPath, "Settings", "MaxTokens")
            IniWrite(this.IniVersion,                                       this.IniPath, "Settings", "Version")
            IniWrite("0",                                                   this.IniPath, "Settings", "AutoCopy")
            IniWrite("プロの翻訳者として、入力テキストを自然な英語に翻訳してください。翻訳文のみを返し、説明・注釈は不要です。",                                      this.IniPath, "Prompts", "1.翻訳（日→英）")
            IniWrite("プロの翻訳者として、入力テキストを自然な日本語に翻訳してください。翻訳文のみを返し、説明・注釈は不要です。",                                      this.IniPath, "Prompts", "2.翻訳（英→日）")
            IniWrite("以下のテキストを日本語で3〜5つの箇条書きに要約してください。各ポイントは1〜2文で簡潔にまとめ、要約のみを返してください。",                          this.IniPath, "Prompts", "3.要約")
            IniWrite("プロの校正者として、入力テキストの誤字・脱字・文法エラーを修正してください。修正後のテキストのみを返し、変更点の説明は不要です。",                    this.IniPath, "Prompts", "4.校正")
        } else {
            ; ==============================================================
            ; マイグレーション: 旧バージョンのINIに不足しているキーを補う
            ; 既存の値は上書きしない。Version キーが存在しない = v0 扱い。
            ; ==============================================================
            storedVer := Integer(IniRead(this.IniPath, "Settings", "Version", "0"))
            if (storedVer < this.IniVersion) {
                if (storedVer < 1) {
                    ; v1: ApiEndpoint を追加
                    if (IniRead(this.IniPath, "Settings", "ApiEndpoint", "") == "")
                        IniWrite("https://api.openai.com/v1/chat/completions", this.IniPath, "Settings", "ApiEndpoint")
                }
                if (storedVer < 2) {
                    ; v2: AutoCopy を追加
                    if (IniRead(this.IniPath, "Settings", "AutoCopy", "") == "")
                        IniWrite("0", this.IniPath, "Settings", "AutoCopy")
                }
                IniWrite(this.IniVersion, this.IniPath, "Settings", "Version")
            }
            ; 将来のバージョン追加時はここに if (storedVer < N) { ... } を続ける
        }
        this.ApiKey      := IniRead(this.IniPath, "Settings", "ApiKey",      "")
        this.ApiEndpoint := IniRead(this.IniPath, "Settings", "ApiEndpoint", "https://api.openai.com/v1/chat/completions")
        this.AutoCopy    := IniRead(this.IniPath, "Settings", "AutoCopy",    "0") == "1"
    }

    static _IsLocalEndpoint() {
        return InStr(this.ApiEndpoint, "localhost") || InStr(this.ApiEndpoint, "127.0.0.1")
    }

    static Show() {
        needsApiKey := !this._IsLocalEndpoint()
        if (needsApiKey && (this.ApiKey == "" || this.ApiKey == "YOUR_API_KEY_HERE")) {
            this._ShowSettings()
            return
        }

        ; メニュー表示前にテキスト取得（Electron等はメニュー表示で選択が消えるため）
        this._pendingText := this._GetSelectedText()

        mMenu := Menu()

        ; テキストなしの場合は手入力オプションを先頭に追加
        if (this._pendingText == "") {
            mMenu.Add("テキストを入力...", (*) => this._ShowTextInput())
            mMenu.Add()
        }

        try {
            promptSection := IniRead(this.IniPath, "Prompts")
            loop parse, promptSection, "`n", "`r" {
                if InStr(A_LoopField, "=") {
                    modeName := StrSplit(A_LoopField, "=")[1]
                    mMenu.Add(modeName, (ItemName, *) => this._Process(ItemName))
                }
            }
        } catch {
            mMenu.Add("1.翻訳", (ItemName, *) => this._Process("1.翻訳"))
        }

        mMenu.Add()
        mMenu.Add("設定...", (*) => this._ShowSettings())

        ; テキストなしの場合はプロンプト項目をグレーアウト
        if (this._pendingText == "") {
            try {
                loop parse, IniRead(this.IniPath, "Prompts"), "`n", "`r" {
                    if InStr(A_LoopField, "=")
                        mMenu.Disable(StrSplit(A_LoopField, "=")[1])
                }
            }
        }

        mMenu.Show()
    }

    static _ShowTextInput() {
        dg := Gui("+AlwaysOnTop", "SnapAI - テキスト入力")
        dg.SetFont("s10", "Segoe UI")
        dg.MarginX := 15
        dg.MarginY := 12

        dg.Add("Text", , "テキスト:")
        textEdit := dg.Add("Edit", "w420 h100 Multi")

        dg.Add("Text", "y+10", "保存プロンプト:")
        promptNames := []
        try {
            loop parse, IniRead(this.IniPath, "Prompts"), "`n", "`r" {
                if InStr(A_LoopField, "=")
                    promptNames.Push(StrSplit(A_LoopField, "=")[1])
            }
        }
        if (promptNames.Length == 0)
            promptNames.Push("1.翻訳")
        modeList := dg.Add("ListBox", "y+5 w420 r" . Min(promptNames.Length, 5), promptNames)

        dg.Add("Text", "y+10", "プロンプト:")
        promptEdit := dg.Add("Edit", "y+5 w420 h80 Multi",
            "以下の内容についてわかりやすく説明してください。")
        modeList.OnEvent("Change", (*) => this._FillPromptFromList(modeList, promptEdit))

        btnOk     := dg.Add("Button", "y+12 w140 Default", "OK  (Ctrl+Enter)")
        btnCancel := dg.Add("Button", "x+10 w80", "キャンセル")

        btnOk.OnEvent("Click",     (*) => this._ProcessManualInput(dg, textEdit, modeList, promptEdit))
        btnCancel.OnEvent("Click", (*) => dg.Destroy())
        dg.OnEvent("Close",        (*) => dg.Destroy())

        ; Ctrl+Enter で送信、Esc で閉じる
        HotIfWinActive("ahk_id " dg.Hwnd)
        Hotkey("^Enter", (*) => this._ProcessManualInput(dg, textEdit, modeList, promptEdit), "On")
        Hotkey("Escape", (*) => dg.Destroy(), "On")
        HotIf()

        dg.Show("AutoSize")
        textEdit.Focus()
    }

    static _FillPromptFromList(modeList, promptEdit) {
        ; 既にプロンプトが入力済みの場合は上書きしない
        if (modeList.Value > 0 && Trim(promptEdit.Value) == "")
            try promptEdit.Value := IniRead(this.IniPath, "Prompts", modeList.Text, "")
    }

    static _ProcessManualInput(dg, textEdit, modeList, promptEdit) {
        text        := Trim(textEdit.Value)
        customPrompt := Trim(promptEdit.Value)
        listSelected := modeList.Value > 0
        if (text == "") {
            ToolTip("テキストを入力してください。")
            SetTimer(() => ToolTip(), -2000)
            textEdit.Focus()
            return
        }
        if (!listSelected && customPrompt == "") {
            ToolTip("処理を選択するかプロンプトを入力してください。")
            SetTimer(() => ToolTip(), -2000)
            return
        }
        modeName := listSelected ? modeList.Text : "カスタム"
        dg.Destroy()
        this._pendingText := text
        ; customPrompt が空の場合は _Process 内で INI から取得
        this._Process(modeName, customPrompt)
    }

    static _Process(modeName, customPrompt := "") {
        targetText := this._pendingText
        this._pendingText := ""
        if (targetText == "")
            return

        if (this.GuiObj) {
            this.GuiObj.Destroy()
            this.GuiObj := ""
        }

        this._ShowProgressGui(modeName)
        try {
            prompt := customPrompt != "" ? customPrompt : IniRead(this.IniPath, "Prompts", modeName)
            this._StartRequest(modeName, targetText, prompt)
        } catch as e {
            this._CancelRequest()
            this._ShowError(e.Message)
        }
    }

    ; 非同期HTTPリクエストを開始し、ポーリングタイマーをセット
    static _StartRequest(modeName, text, prompt) {
        if (StrLen(text) > this.MAX_INPUT_CHARS) {
            text := SubStr(text, 1, this.MAX_INPUT_CHARS) . "..."
            ToolTip("テキストが長すぎるため先頭 " . this.MAX_INPUT_CHARS . " 文字のみ送信します", , , 3)
            SetTimer(() => ToolTip(, , , 3), -3000)
        }

        model       := IniRead(this.IniPath, "Settings", "Model",       "gpt-4o-mini")
        temperature := IniRead(this.IniPath, "Settings", "Temperature", "0.5")
        maxTokens   := IniRead(this.IniPath, "Settings", "MaxTokens",   "2000")

        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("POST", this.ApiEndpoint, true)  ; true = 非同期

        this._SetRequestHeaders(whr)
        body := this._BuildRequestBody(prompt, text, model, temperature, maxTokens)

        ; 既存リクエストのタイマーをキャンセル
        if (this._pollFn != "") {
            SetTimer(this._pollFn, 0)
            this._pollFn := ""
            this._whr := ""
        }

        try {
            whr.Send(body)
        } catch as e {
            throw Error("送信エラー: " . e.Message)
        }

        this._startTime := A_TickCount
        this._whr := whr
        this._pollFn := () => this._PollResponse(modeName)
        SetTimer(this._pollFn, this.POLL_INTERVAL_MS)
    }

    ; レスポンス完了をポーリングして処理（POLL_INTERVAL_MS ごとに呼ばれる）
    static _PollResponse(modeName) {
        whr := this._whr
        if (!whr)
            return

        ; タイムアウトチェック
        elapsed := A_TickCount - this._startTime
        if (elapsed >= this.TIMEOUT_MS) {
            this._CancelRequest()
            this._ShowError("タイムアウト: " . (this.TIMEOUT_MS // 1000) . "秒以内にAPIから応答がありませんでした。")
            return
        }

        ; プログレスバー更新
        if (this._progressBar != "")
            try this._progressBar.Value := elapsed * 100 // this.TIMEOUT_MS

        ; WaitForResponse(0) = タイムアウト即時。false = まだ待機中
        try {
            if (!whr.WaitForResponse(0))
                return
        } catch {
            return
        }

        ; ポーリング停止・進捗GUI閉じる
        pollFn := this._pollFn
        this._pollFn := ""
        this._whr := ""
        this._startTime := 0
        SetTimer(pollFn, 0)
        if (this._progressGui != "") {
            try this._progressGui.Destroy()
            this._progressGui := ""
            this._progressBar := ""
        }

        try {
            this._ShowResult(modeName, this._ParseResponse(whr))
        } catch as e {
            this._ShowError(e.Message)
        }
    }

    ; ===========================================================================
    ; リクエストヘッダー設定（OpenAI互換フォーマット）
    ; 異なるAPIフォーマットに対応する場合はこのメソッドを変更してください。
    ;
    ; 入力: whr … WinHttp.WinHttpRequest.5.1 COM オブジェクト（Open済み）
    ; ===========================================================================
    static _SetRequestHeaders(whr) {
        whr.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
        whr.SetRequestHeader("Authorization", "Bearer " . this.ApiKey)
    }

    ; ===========================================================================
    ; リクエストボディ構築（OpenAI互換フォーマット）
    ; 異なるAPIフォーマットに対応する場合はこのメソッドを変更してください。
    ;
    ; 出力: JSON 文字列
    ; ===========================================================================
    static _BuildRequestBody(prompt, text, model, temperature, maxTokens) {
        return '{"model":"' . model . '","messages":[{"role":"system","content":"' . this._JSONEscape(prompt) .
            '"},{"role":"user","content":"' . this._JSONEscape(text) . '"}],"temperature":' . temperature . ',"max_tokens":' . maxTokens . '}'
    }

    ; ===========================================================================
    ; レスポンス解析（OpenAI互換フォーマット）
    ; 異なるAPIフォーマットに対応する場合はこのメソッドを変更してください。
    ;
    ; 入力: whr … WinHttp.WinHttpRequest.5.1 COM オブジェクト（完了済み）
    ; 出力: AI の回答テキスト（String）
    ; エラー時は Error をスローしてください。
    ; ===========================================================================
    static _ParseResponse(whr) {
        if (whr.Status != 200) {
            responseText := ""
            try {
                responseText := whr.ResponseText
            }
            throw Error("API Error " . whr.Status . "`n" . SubStr(responseText, 1, 500))
        }

        ; WinHTTP は ResponseBody で UTF-8 バイト列を返すため手動デコード
        rawData := whr.ResponseBody
        pData := NumGet(ComObjValue(rawData), 8 + A_PtrSize, "Ptr")
        response := StrGet(pData, rawData.MaxIndex() + 1, "UTF-8")

        if InStr(response, '"error"') {
            if RegExMatch(response, '"message":\s*"([^"]+)"', &errMatch)
                throw Error("API エラー: " . errMatch[1])
            throw Error("API エラー（詳細不明）")
        }

        if RegExMatch(response, '"content":\s*"([^"\\]*(?:\\.[^"\\]*)*)"', &match) {
            res := match[1]
            res := StrReplace(res, "\n", "`n")
            res := StrReplace(res, '\"', '"')
            res := StrReplace(res, "\/", "/")
            res := StrReplace(res, '\\', '\')
            return res
        }

        throw Error("レスポンス解析失敗`n" . SubStr(response, 1, 300))
    }

    static _GetSelectedText() {
        originalClip := ClipboardAll()
        A_Clipboard := ""
        ToolTip("取得中...")
        Send("^c")
        if (!ClipWait(1.5)) {
            ToolTip()
            A_Clipboard := originalClip
            return ""
        }
        ToolTip()
        targetText := A_Clipboard
        A_Clipboard := originalClip

        targetText := Trim(targetText)
        if (targetText == "")
            return ""
        if (StrLen(targetText) < 2)
            return ""

        return this._CleanText(targetText)
    }

    static _ShowResult(modeName, resultText) {
        if (this.AutoCopy) {
            A_Clipboard := resultText
            ToolTip("クリップボードにコピーしました", , , 3)
            SetTimer(() => ToolTip(, , , 3), -2000)
        }
        this.GuiObj := Gui("+AlwaysOnTop +Resize", "AI Result: " . modeName)
        this.GuiObj.SetFont("s11", "Segoe UI")
        this.EditObj := this.GuiObj.Add("Edit", "Multi ReadOnly w" . this.GUI_WIDTH . " h" . this.GUI_HEIGHT,
            resultText)
        btnCopy := this.GuiObj.Add("Button", "w80", "コピー")
        btnCopy.OnEvent("Click", (*) => this._CopyResult())

        ; ウィンドウリサイズ時にEditとボタンを追従させる
        editObj := this.EditObj
        this.GuiObj.OnEvent("Size", (g, minmax, w, h) => (
            minmax != -1
                ? (editObj.Move(, , w - 20, h - 50), btnCopy.Move(, h - 33))
                : 0
        ))

        CoordMode "Mouse", "Screen"
        MouseGetPos(&mX, &mY)
        this.GuiObj.Show("x" . mX + 15 . " y" . mY + 15)

        this.GuiObj.OnEvent("Close", (*) => (this.GuiObj := ""))

        ; Esc で閉じる（ウィンドウがアクティブな間のみ有効）
        HotIfWinActive("ahk_id " this.GuiObj.Hwnd)
        Hotkey("Esc", (*) => this.GuiObj.Destroy(), "On")
        HotIf()
    }

    static _CopyResult() {
        A_Clipboard := this.EditObj.Value
        ToolTip("コピーしました")
        SetTimer(() => ToolTip(), -2000)
    }

    static _CleanText(text) {
        text := RegExReplace(text, "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", "")  ; 制御文字除去（改行・タブは保持）
        text := RegExReplace(text, " {2,}", " ")                              ; 連続空白を1つに
        text := RegExReplace(text, "(\r?\n){3,}", "`n`n")                    ; 連続改行を2つまでに
        return Trim(text)
    }

    static _ShowSettings() {
        sg := Gui("+AlwaysOnTop", "SnapAI 設定")
        sg.SetFont("s10", "Segoe UI")
        sg.MarginX := 15
        sg.MarginY := 10

        tabs := sg.Add("Tab3", "w500 h360", ["基本設定", "プロンプト"])

        ; === 基本設定タブ ===
        tabs.UseTab(1)
        sg.Add("Text", "xm+10 y+15 w100", "API Key:")
        apiEdit := sg.Add("Edit", "x+5 w355", this.ApiKey)

        sg.Add("Text", "xm+10 y+12 w100", "エンドポイント:")
        endpointEdit := sg.Add("Edit", "x+5 w355", this.ApiEndpoint)

        sg.Add("Text", "xm+10 y+12 w100", "モデル:")
        currentModel := IniRead(this.IniPath, "Settings", "Model", "gpt-4o-mini")
        modelOptions := ["gpt-4o-mini", "gpt-4o", "gpt-4-turbo", "gpt-3.5-turbo"]
        found := false
        for m in modelOptions
            if (m == currentModel) {
                found := true
                break
            }
        if (!found)
            modelOptions.InsertAt(1, currentModel)
        modelEdit := sg.Add("ComboBox", "x+5 w200", modelOptions)
        modelEdit.Text := currentModel

        sg.Add("Text", "xm+10 y+12 w100", "Temperature:")
        tempEdit := sg.Add("Edit", "x+5 w60", IniRead(this.IniPath, "Settings", "Temperature", "0.5"))

        sg.Add("Text", "xm+10 y+12 w100", "Max Tokens:")
        tokensEdit := sg.Add("Edit", "x+5 w80", IniRead(this.IniPath, "Settings", "MaxTokens", "2000"))
        btnHelp := sg.Add("Button", "x+10 w30", "?")
        btnHelp.OnEvent("Click", (*) => this._ShowSettingsHelp())

        sg.Add("Text", "xm+10 y+12 w100", "")
        autoCopyCheck := sg.Add("CheckBox", "x+5", "結果を自動的にクリップボードにコピー")
        autoCopyCheck.Value := (IniRead(this.IniPath, "Settings", "AutoCopy", "0") == "1") ? 1 : 0

        ; === プロンプトタブ ===
        tabs.UseTab(2)
        lv := sg.Add("ListView", "xm+10 y+10 w460 h250 -Multi", ["名前", "プロンプト"])
        lv.ModifyCol(1, 130)
        lv.ModifyCol(2, 324)

        try {
            promptSection := IniRead(this.IniPath, "Prompts")
            loop parse, promptSection, "`n", "`r" {
                if InStr(A_LoopField, "=") {
                    parts := StrSplit(A_LoopField, "=", , 2)
                    lv.Add("", parts[1], parts[2])
                }
            }
        }

        btnAdd  := sg.Add("Button", "xm+10 y+8 w70", "追加")
        btnEdit := sg.Add("Button", "x+5 w70", "編集")
        btnDel  := sg.Add("Button", "x+5 w70", "削除")
        btnUp   := sg.Add("Button", "x+5 w40", "↑")
        btnDown := sg.Add("Button", "x+5 w40", "↓")

        ; === OK / Cancel（タブの外） ===
        tabs.UseTab()
        btnOk     := sg.Add("Button", "xm+365 y+15 w60 Default", "OK")
        btnCancel := sg.Add("Button", "x+10 w60", "キャンセル")

        btnAdd.OnEvent("Click",   (*) => this._EditPromptDialog(lv, 0))
        btnEdit.OnEvent("Click",  (*) => this._OnPromptEditClick(lv))
        btnDel.OnEvent("Click",   (*) => (lv.GetNext() ? lv.Delete(lv.GetNext()) : ""))
        btnUp.OnEvent("Click",    (*) => this._MoveListItem(lv, -1))
        btnDown.OnEvent("Click",  (*) => this._MoveListItem(lv, 1))
        btnOk.OnEvent("Click",    (*) => this._SaveSettings(sg, lv, apiEdit, endpointEdit, modelEdit, tempEdit, tokensEdit, autoCopyCheck))
        btnCancel.OnEvent("Click", (*) => sg.Destroy())
        sg.OnEvent("Close", (*) => sg.Destroy())

        sg.Show("AutoSize")
    }

    static _SaveSettings(sg, lv, apiEdit, endpointEdit, modelEdit, tempEdit, tokensEdit, autoCopyCheck) {
        apiKey   := Trim(apiEdit.Value)
        endpoint := Trim(endpointEdit.Value)
        if (!InStr(endpoint, "localhost") && !InStr(endpoint, "127.0.0.1")
            && (apiKey == "" || apiKey == "YOUR_API_KEY_HERE")) {
            ToolTip("API Key を入力してください。")
            SetTimer(() => ToolTip(), -3000)
            apiEdit.Focus()
            return
        }

        ; コントロール値を事前にキャプチャ
        model    := Trim(modelEdit.Text)
        temp     := Trim(tempEdit.Value)
        tokens   := Trim(tokensEdit.Value)
        autoCopy := autoCopyCheck.Value ? "1" : "0"
        prompts  := []
        loop lv.GetCount()
            prompts.Push([lv.GetText(A_Index, 1), lv.GetText(A_Index, 2)])

        ; 即座に非表示にしてレスポンスを示す
        sg.Hide()
        ToolTip("設定を保存しています...", , , 4)

        ; INI 保存
        IniWrite(apiKey,   this.IniPath, "Settings", "ApiKey")
        IniWrite(endpoint, this.IniPath, "Settings", "ApiEndpoint")
        IniWrite(model,    this.IniPath, "Settings", "Model")
        IniWrite(temp,     this.IniPath, "Settings", "Temperature")
        IniWrite(tokens,   this.IniPath, "Settings", "MaxTokens")
        IniWrite(autoCopy, this.IniPath, "Settings", "AutoCopy")
        try IniDelete(this.IniPath, "Prompts")
        for p in prompts
            IniWrite(p[2], this.IniPath, "Prompts", p[1])

        sg.Destroy()
        this.ApiKey      := apiKey
        this.ApiEndpoint := endpoint
        this.AutoCopy    := autoCopy == "1"

        ToolTip("保存しました", , , 4)
        SetTimer(() => ToolTip(, , , 4), -2000)
    }

    static _ShowError(msg) {
        eg := Gui("+AlwaysOnTop", "SnapAI エラー")
        eg.SetFont("s10", "Segoe UI")
        eg.MarginX := 15
        eg.MarginY := 12
        eg.Add("Text", "w400", msg)
        btnClose := eg.Add("Button", "y+12 w80 Default", "OK")
        btnClose.OnEvent("Click", (*) => eg.Destroy())
        eg.OnEvent("Close", (*) => eg.Destroy())
        eg.Show("AutoSize")
    }

    static _ShowProgressGui(modeName) {
        if (this._progressGui != "")
            try this._progressGui.Destroy()
        pg := Gui("+AlwaysOnTop +ToolWindow", "SnapAI")
        pg.SetFont("s10", "Segoe UI")
        pg.MarginX := 12
        pg.MarginY := 10
        pg.Add("Text", "w220", "AI Thinking... (" . modeName . ")")
        bar := pg.Add("Progress", "w220 h12 y+8 Range0-100", 0)
        btnCancel := pg.Add("Button", "w80 y+8", "キャンセル")
        btnCancel.OnEvent("Click", (*) => this._CancelRequest())
        pg.OnEvent("Close", (*) => this._CancelRequest())
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mX, &mY)
        pg.Show("x" . (mX + 15) . " y" . (mY + 15) . " AutoSize")
        this._progressGui := pg
        this._progressBar := bar
    }

    static _CancelRequest() {
        if (this._pollFn != "") {
            SetTimer(this._pollFn, 0)
            this._pollFn := ""
        }
        this._whr := ""
        this._startTime := 0
        if (this._progressGui != "") {
            try this._progressGui.Destroy()
            this._progressGui := ""
            this._progressBar := ""
        }
    }

    static _OnPromptEditClick(lv) {
        if lv.GetNext()
            this._EditPromptDialog(lv, lv.GetNext())
        else {
            ToolTip("編集する項目を選択してください。")
            SetTimer(() => ToolTip(), -2000)
        }
    }

    static _MoveListItem(lv, dir) {
        row := lv.GetNext()
        if (!row)
            return
        newRow := row + dir
        if (newRow < 1 || newRow > lv.GetCount())
            return
        name1    := lv.GetText(row, 1)
        content1 := lv.GetText(row, 2)
        name2    := lv.GetText(newRow, 1)
        content2 := lv.GetText(newRow, 2)
        lv.Modify(row,    "", name2, content2)
        lv.Modify(newRow, "", name1, content1)
        lv.Modify(newRow, "Select Focus")
    }

    static _ShowSettingsHelp() {
        hg := Gui("+AlwaysOnTop", "設定の説明")
        hg.SetFont("s10", "Segoe UI")
        hg.MarginX := 15
        hg.MarginY := 12
        hg.Add("Edit", "w440 h280 ReadOnly Multi -E0x200",
            "【API Key】`n"
            . "OpenAI のシークレットキー（sk-... で始まる文字列）。`n"
            . "https://platform.openai.com/api-keys で取得できます。`n`n"
            . "【エンドポイント】`n"
            . "APIのURL。OpenAI互換サービスに変更可能です。`n"
            . "  Groq       https://api.groq.com/openai/v1/chat/completions`n"
            . "  OpenRouter https://openrouter.ai/api/v1/chat/completions`n"
            . "  Ollama     http://localhost:11434/v1/chat/completions`n`n"
            . "【モデル】`n"
            . "使用する GPT モデル。速度・精度・コストのバランスが異なります。`n"
            . "  gpt-4o-mini   高速・安価（日常用途に推奨）`n"
            . "  gpt-4o        高精度・やや高コスト`n"
            . "  gpt-4-turbo   長文処理に強い`n"
            . "  gpt-3.5-turbo 旧世代（現在は gpt-4o-mini が上位互換）`n`n"
            . "【Temperature】  0.0 〜 2.0`n"
            . "回答のランダム性。低いほど一貫した回答、高いほど多様な回答。`n"
            . "翻訳・校正には 0.3〜0.5 が適切。`n`n"
            . "【Max Tokens】`n"
            . "1回の応答の最大長。1トークン ≈ 日本語1〜2文字。`n"
            . "超えると途中で切れます。通常は 2000 で十分です。`n`n"
            . "【自動コピー】`n"
            . "ONにすると、結果表示と同時にクリップボードへコピーします。`n"
            . "コピーボタンを押す手間が省けます。")
        btnClose := hg.Add("Button", "y+12 w80 Default", "閉じる")
        btnClose.OnEvent("Click", (*) => hg.Destroy())
        hg.OnEvent("Close", (*) => hg.Destroy())
        hg.Show("AutoSize")
        btnClose.Focus()
    }

    static _EditPromptDialog(lv, row) {
        isNew := (row == 0)
        dg := Gui("+AlwaysOnTop", isNew ? "プロンプト追加" : "プロンプト編集")
        dg.SetFont("s10", "Segoe UI")
        dg.MarginX := 15
        dg.MarginY := 10

        dg.Add("Text", , "名前（メニューに表示されます）:")
        nameEdit := dg.Add("Edit", "w420", isNew ? "" : lv.GetText(row, 1))
        dg.Add("Text", "y+10", "プロンプト:")
        contentEdit := dg.Add("Edit", "w420 h120 Multi", isNew ? "" : lv.GetText(row, 2))
        btnOk     := dg.Add("Button", "y+10 w80 Default", "OK")
        btnCancel := dg.Add("Button", "x+10 w80", "キャンセル")

        btnOk.OnEvent("Click",    (*) => this._SavePrompt(dg, lv, row, isNew, nameEdit, contentEdit))
        btnCancel.OnEvent("Click", (*) => dg.Destroy())
        dg.OnEvent("Close", (*) => dg.Destroy())

        dg.Show("AutoSize")
    }

    static _SavePrompt(dg, lv, row, isNew, nameEdit, contentEdit) {
        name    := Trim(nameEdit.Value)
        content := Trim(contentEdit.Value)
        if (name == "" || content == "") {
            ToolTip("名前とプロンプトを入力してください。")
            SetTimer(() => ToolTip(), -3000)
            nameEdit.Focus()
            return
        }
        if isNew
            lv.Add("", name, content)
        else
            lv.Modify(row, "", name, content)
        dg.Destroy()
    }

    static _JSONEscape(str) {
        str := StrReplace(str, "\", "\\")    ; バックスラッシュは最初にエスケープ
        str := StrReplace(str, '"', '\"')
        str := StrReplace(str, "`r`n", "\n")
        str := StrReplace(str, "`n", "\n")
        str := StrReplace(str, "`r", "\n")
        str := StrReplace(str, "`t", "  ")
        str := RegExReplace(str, "[\x00-\x09\x0B\x0C\x0E-\x1F]", "")
        return str
    }
}
