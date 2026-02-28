; ==============================================================================
; Module:       WrapPalette.ahk
; Description:  選択したテキストを登録済みのパーツで囲むGUIツール
;               - トリガキーによる即実行（1文字のショートカット）
;               - 複数行パーツ対応、HTMLタグやコードスニペットも快適に編集
;               - 行頭・行末の付加（引用符 > など）をパーツごとに設定可能
;               - 既存パーツからの引用、トリガー重複チェック、複数選択削除
; Version:      1.1.0
; License:      MIT
;
; Usage Example:
;   #Include ui\WrapPalette.ahk
;   vk1D & m:: WrapPalette.Execute() ; 無変換 + r で起動
; =======================================================================
#Requires AutoHotkey v2.0
class WrapPalette {
    ; ========================================
    ; 定数定義
    ; ========================================
    static IniPath := A_ScriptDir "\ui\WrapPalette.ini"
    static GuiTitle := "Wrap Palette - 一覧"

    ; リスト画面のサイズ
    static LIST_WIDTH := 310
    static LIST_HEIGHT := 350
    static LIST_LV_WIDTH := 280
    static LIST_LV_HEIGHT := 250

    ; 編集画面のサイズ
    static EDIT_WIDTH := 630
    static EDIT_HEIGHT := 600
    static EDIT_GROUPBOX_WIDTH := 600
    static EDIT_GROUPBOX_HEIGHT := 265
    static EDIT_INPUT_WIDTH := 220
    static EDIT_INPUT_HEIGHT := 180
    static PREVIEW_GB_HEIGHT := 90

    ; 確認ダイアログのサイズ
    static DIALOG_WIDTH := 500
    static DIALOG_HEIGHT := 220

    ; クリップボード待機時間（秒）
    static CLIP_WAIT_SHORT := 0.3
    static CLIP_WAIT_LONG := 0.5

    ; 編集画面のヘルプ（? クリックで一括表示）
    static TIP_NAME := "パーツの識別名。一覧に表示され、INIのセクション名になります。"
    static TIP_TRIGGER := "一覧でこのキーを押すと、このパーツを即実行します。1文字のみ。"
    static TIP_LINE_PREFIX := "各行の先頭に付ける文字。例: > で引用、| で表の列。空でも可。"
    static TIP_LINE_SUFFIX := "各行の末尾に付ける文字。空でも可。"
    static TIP_PARTS := "選択テキストの前（左）と後（右）に挿入する文字。複数行可。行頭・行末の付加のあと、左＋本文＋右で結合されます。"
    static TIP_QUOTE := "既存パーツの左・右を読み込んで編集の土台にします。"

    ; ========================================
    ; 状態管理
    ; ========================================
    static CurrentText := ""
    static LastX := ""
    static LastY := ""
    static IsCommitted := false
    static MainGui := ""

    ; ========================================
    ; メイン実行
    ; ========================================
    /**
     * WrapPaletteを起動してテキストを取得
     */
    static Execute() {
        ; シングルトンチェック：既にGUIが開いている場合はアクティブにして終了
        if (WrapPalette.MainGui && WinExist("ahk_id " . WrapPalette.MainGui.Hwnd)) {
            WinActivate("ahk_id " . WrapPalette.MainGui.Hwnd)
            return
        }

        ; 修飾キーの待機
        KeyWait("Ctrl")
        KeyWait("Shift")
        KeyWait("Alt")
        Sleep(30)

        ; 初期化
        WrapPalette.CurrentText := ""
        WrapPalette.IsCommitted := false
        A_Clipboard := ""

        ; テキストを取得
        Send("^x")
        if ClipWait(WrapPalette.CLIP_WAIT_SHORT) {
            WrapPalette.CurrentText := A_Clipboard
        }

        WrapPalette.ShowSelector()
    }

    ; ========================================
    ; 一覧選択画面
    ; ========================================
    /**
     * パーツ一覧を表示
     */
    static ShowSelector() {
        WrapPalette.IsCommitted := false

        Names := WrapPalette.GetNames()
        WrapPalette.MainGui := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", WrapPalette.GuiTitle)
        SelGui := WrapPalette.MainGui

        ; タイトル
        SelGui.SetFont("s10", "Segoe UI")
        SelGui.Add("Text", "xm w" . WrapPalette.LIST_LV_WIDTH, "パーツ選択（トリガ即実行可）:")

        ; ListView
        LV := SelGui.Add("ListView",
            "xm w" . WrapPalette.LIST_LV_WIDTH . " h" . WrapPalette.LIST_LV_HEIGHT . " r10 Grid",
            ["トリガ", "登録名"])
        LV.ModifyCol(1, 60)
        LV.ModifyCol(2, 218)

        ; データ追加
        for name in Names {
            trig := IniRead(WrapPalette.IniPath, name, "trigger", "")
            LV.Add(, trig, name)
        }

        ; ホットキー設定
        HotIfWinActive(WrapPalette.GuiTitle)
        for name in Names {
            trig := IniRead(WrapPalette.IniPath, name, "trigger", "")
            if (trig != "") {
                Hotkey(trig, ((n) => (*) => WrapPalette.ApplyWrap(n))(name), "On")
            }
        }
        HotIf()

        ; ボタン配置
        SelGui.Add("Button", "xm w65 Default -Tabstop", "決定").OnEvent("Click", (*) => (
            (row := LV.GetNext()) ? WrapPalette.ApplyWrap(LV.GetText(row, 2)) : 0
        ))

        SelGui.Add("Button", "x+8 w65 -Tabstop", "追加").OnEvent("Click", (*) => (
            SelGui.GetPos(&px, &py),
            WrapPalette.LastX := px,
            WrapPalette.LastY := py,
            SelGui.Destroy(),
            WrapPalette.ShowEditor("")
        ))

        SelGui.Add("Button", "x+8 w65 -Tabstop", "編集").OnEvent("Click", (*) => (
            WrapPalette.EditItem(LV, SelGui)
        ))

        SelGui.Add("Button", "x+8 w65 -Tabstop", "削除").OnEvent("Click", (*) => (
            WrapPalette.DeleteSelected(LV, SelGui)
        ))

        ; イベント
        SelGui.OnEvent("Close", (*) => WrapPalette.Cancel())
        SelGui.OnEvent("Escape", (*) => WrapPalette.Cancel())

        ; 表示
        WrapPalette.ShowAtPosition(SelGui, LV)
    }

    ; ========================================
    ; 編集項目を開く
    ; ========================================
    /**
     * 選択された項目の編集画面を開く
     */
    static EditItem(LV, SelGui) {
        row := LV.GetNext()
        target := (row != 0) ? LV.GetText(row, 2) : ""
        SelGui.GetPos(&px, &py)
        WrapPalette.LastX := px
        WrapPalette.LastY := py
        SelGui.Destroy()
        WrapPalette.ShowEditor(target)
    }

    ; ========================================
    ; 編集画面
    ; ========================================
    /**
     * パーツの編集画面を表示
     * @param targetName 編集対象の登録名（空の場合は新規作成）
     */
    static ShowEditor(targetName := "") {
        WrapPalette.IsCommitted := false
        Names := WrapPalette.GetNames()
        EditGui := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "Wrap Editor - 登録")
        EditGui.SetFont("s10", "Segoe UI")

        ; 既存データの読み込み（改行をアンエスケープ）
        dL := (targetName != "") ? WrapPalette._UnescapeNewlines(IniRead(WrapPalette.IniPath, targetName, "left", "")) :
            ""
        dR := (targetName != "") ? WrapPalette._UnescapeNewlines(IniRead(WrapPalette.IniPath, targetName, "right", "")) :
            ""
        dT := (targetName != "") ? IniRead(WrapPalette.IniPath, targetName, "trigger", "") : ""
        dPrefix := (targetName != "") ? IniRead(WrapPalette.IniPath, targetName, "linePrefix", "") : ""
        dSuffix := (targetName != "") ? IniRead(WrapPalette.IniPath, targetName, "lineSuffix", "") : ""

        ; 登録名
        EditGui.Add("Text", "xm+10 ym+15 w80", "登録名:")
        EName := EditGui.Add("Edit", "x+5 yp-3 w430 h24", targetName)
        EditGui.Add("Button", "x+8 yp w24 h24", "?").OnEvent("Click", (*) => WrapPalette._ShowHelp(EditGui))

        ; トリガ
        EditGui.Add("Text", "xm+10 y+12 w80", "トリガ:")
        ETrig := EditGui.Add("Edit", "x+5 yp-3 w60 Center Limit1", dT)

        ; パーツ構成 GroupBox（行頭付加・行末付加を内包）
        EditGui.Add("GroupBox",
            "xm+10 y+20 w" . WrapPalette.EDIT_GROUPBOX_WIDTH . " h" . WrapPalette.EDIT_GROUPBOX_HEIGHT,
            "パーツ構成")

        ; 行頭付加・行末付加（GroupBox 内、左右Editの上）
        EditGui.Add("Text", "xp+15 yp+30 w80", "行頭付加:")
        EPrefix := EditGui.Add("Edit", "x+5 yp-3 w160", dPrefix)
        EditGui.Add("Text", "x+15 yp+3 w80", "行末付加:")
        ESuffix := EditGui.Add("Edit", "x+5 yp-3 w160", dSuffix)

        ; 左右パーツ
        EditL := EditGui.Add("Edit",
            "xm+25 y+15 w" . WrapPalette.EDIT_INPUT_WIDTH . " h" . WrapPalette.EDIT_INPUT_HEIGHT . " Multi vscroll",
            dL)
        EditGui.Add("Text", "x+15 yp+85 w100 Center", "+ 原文 +")
        EditR := EditGui.Add("Edit",
            "x+15 yp-85 w" . WrapPalette.EDIT_INPUT_WIDTH . " h" . WrapPalette.EDIT_INPUT_HEIGHT . " Multi vscroll",
            dR)

        ; プレビュー GroupBox
        EditGui.Add("GroupBox",
            "xm+10 y+25 w" . WrapPalette.EDIT_GROUPBOX_WIDTH . " h" . WrapPalette.PREVIEW_GB_HEIGHT, "プレビュー")
        Preview := EditGui.Add("Edit", "xp+10 yp+22 w580 h60 Multi ReadOnly", "")

        ; 変更時にプレビューを自動更新
        UpdatePreview := (*) => Preview.Value := WrapPalette._TransformText(
            WrapPalette.CurrentText != "" ? WrapPalette.CurrentText : "サンプルテキスト`r`n2行目`r`n3行目",
            EditL.Value, EditR.Value, EPrefix.Value, ESuffix.Value)
        EditL.OnEvent("Change", UpdatePreview)
        EditR.OnEvent("Change", UpdatePreview)
        EPrefix.OnEvent("Change", UpdatePreview)
        ESuffix.OnEvent("Change", UpdatePreview)
        UpdatePreview()

        ; 既存パーツから引用
        EditGui.SetFont("s9")
        EditGui.Add("Text", "xm+10 y+20 cGray", "既存パーツから引用：")
        DL_L := EditGui.Add("DropDownList", "xm+10 y+10 w290", Names)
        DR_L := EditGui.Add("DropDownList", "x+20 w290", Names)

        DL_L.OnEvent("Change", (g, *) => (EditL.Value := WrapPalette._UnescapeNewlines(IniRead(WrapPalette.IniPath, g.Text,
            "left", ""))))
        DR_L.OnEvent("Change", (g, *) => (EditR.Value := WrapPalette._UnescapeNewlines(IniRead(WrapPalette.IniPath, g.Text,
            "right", ""))))

        ; ボタン
        EditGui.Add("Button", "xm+10 y+25 w290 h40 Default", "保存して戻る").OnEvent("Click", (*) =>
            WrapPalette.SaveAndReturn(EName.Value, EditL.Value, EditR.Value, ETrig.Value, EPrefix.Value, ESuffix.Value, EditGui, targetName))

        BtnBack := EditGui.Add("Button", "x+20 w290 h40", "戻る")
        OnBack := (*) => WrapPalette.BackToSelector(EditGui)
        BtnBack.OnEvent("Click", OnBack)
        EditGui.OnEvent("Escape", OnBack)
        EditGui.OnEvent("Close", OnBack)

        ; 表示
        targetPos := (WrapPalette.LastX != "" && WrapPalette.LastY != "") ?
            "x" . WrapPalette.LastX . " y" . WrapPalette.LastY : ""
        EditGui.Show(targetPos " w" . WrapPalette.EDIT_WIDTH . " h" . WrapPalette.EDIT_HEIGHT)
    }

    ; ========================================
    ; 保存して戻る
    ; ========================================
    /**
     * パーツを保存してセレクタに戻る
     * トリガの重複チェックを実施
     */
    static SaveAndReturn(N, L, R, T, Prefix, Suffix, G, OriginalName := "") {
        if (N == "")
            return

        ; 登録名の特殊文字チェック
        if (InStr(N, ";") || InStr(N, "=") || InStr(N, "[") || InStr(N, "]")) {
            G.Opt("+OwnDialogs")
            errorMsg := "登録名に以下の文字は使用できません：`n`n  セミコロン(;) イコール(=) 角括弧([]) `n`n別の名前を指定してください。"
            MsgBox(errorMsg, "エラー", "Icon!")
            return
        }

        ; トリガキーの重複チェック
        if (T != "") {
            Names := WrapPalette.GetNames()
            for name in Names {
                if (name != OriginalName && name != N) {
                    existingTrig := IniRead(WrapPalette.IniPath, name, "trigger", "")
                    if (existingTrig == T) {
                        G.Opt("+OwnDialogs")
                        errorMsg := "トリガキー '" . T . "' は既に '" . name . "' で使用されています。`n別のトリガキーを指定してください。"
                        MsgBox(errorMsg, "エラー", "Icon!")
                        return
                    }
                }
            }
        }

        ; 保存（改行をエスケープ）
        IniWrite(WrapPalette._EscapeNewlines(L), WrapPalette.IniPath, N, "left")
        IniWrite(WrapPalette._EscapeNewlines(R), WrapPalette.IniPath, N, "right")
        IniWrite(T, WrapPalette.IniPath, N, "trigger")
        IniWrite(Prefix, WrapPalette.IniPath, N, "linePrefix")
        IniWrite(Suffix, WrapPalette.IniPath, N, "lineSuffix")

        G.GetPos(&sx, &sy)
        WrapPalette.LastX := sx
        WrapPalette.LastY := sy
        G.Destroy()
        WrapPalette.ShowSelector()
    }

    ; ========================================
    ; セレクタに戻る
    ; ========================================
    /**
     * 編集画面からセレクタに戻る
     */
    static BackToSelector(EditGui) {
        EditGui.GetPos(&ex, &ey)
        WrapPalette.LastX := ex
        WrapPalette.LastY := ey
        EditGui.Destroy()
        WrapPalette.ShowSelector()
    }

    ; ========================================
    ; 囲み適用
    ; ========================================
    /**
     * 選択したパーツで原文を囲んで貼り付け
     */
    static ApplyWrap(Name, *) {
        if (WrapPalette.IsCommitted)
            return
        WrapPalette.IsCommitted := true

        ; 設定の読み込み
        L := WrapPalette._UnescapeNewlines(IniRead(WrapPalette.IniPath, Name, "left", ""))
        R := WrapPalette._UnescapeNewlines(IniRead(WrapPalette.IniPath, Name, "right", ""))
        prefix := IniRead(WrapPalette.IniPath, Name, "linePrefix", "")
        suffix := IniRead(WrapPalette.IniPath, Name, "lineSuffix", "")

        ; 加工エンジンの呼び出し
        out := WrapPalette._TransformText(WrapPalette.CurrentText, L, R, prefix, suffix)

        ; GUI閉じる
        if (WrapPalette.MainGui)
            WrapPalette.MainGui.Destroy()

        ; 貼り付け
        A_Clipboard := out
        ClipWait(WrapPalette.CLIP_WAIT_LONG)
        Send("^v")

        WrapPalette.ResetPosition()
        WrapPalette.MainGui := ""
    }

    ; ========================================
    ; キャンセル（原文復元）
    ; ========================================
    /**
     * キャンセルしてGUIを閉じる
     * 原文がある場合は復元
     */
    static Cancel() {
        if (WrapPalette.IsCommitted)
            return
        WrapPalette.IsCommitted := true

        if (WrapPalette.MainGui)
            WrapPalette.MainGui.Destroy()

        ; 原文がある場合のみ復元
        if (WrapPalette.CurrentText != "") {
            A_Clipboard := WrapPalette.CurrentText
            ClipWait(WrapPalette.CLIP_WAIT_LONG)
            Send("^v")
        }

        WrapPalette.ResetPosition()
        WrapPalette.MainGui := ""
    }

    ; ========================================
    ; 削除処理
    ; ========================================
    /**
     * 選択されたパーツを削除
     * 複数選択対応
     */
    static DeleteSelected(LV, SelGui) {
        ; 選択された行を収集
        selected := []
        row := 0
        while (row := LV.GetNext(row)) {
            selected.Push(LV.GetText(row, 2))
        }

        if (selected.Length == 0)
            return

        ; 確認メッセージを構築
        if (selected.Length == 1) {
            msg := selected[1] . " を削除しますか？"
        } else {
            msg := selected.Length . "件の項目を削除しますか？`n`n"
            for name in selected {
                msg .= "• " . name . "`n"
            }
        }

        ; モーダルダイアログで確認
        if (WrapPalette.ShowConfirmDialog(SelGui, "削除の確認", msg) == "Yes") {
            for name in selected {
                IniDelete(WrapPalette.IniPath, name)
            }

            SelGui.GetPos(&px, &py)
            WrapPalette.LastX := px
            WrapPalette.LastY := py
            SelGui.Destroy()
            WrapPalette.ShowSelector()
        }
    }

    ; ========================================
    ; 確認ダイアログ
    ; ========================================
    /**
     * モーダル確認ダイアログを表示
     * @return "Yes" または "No"
     */
    static ShowConfirmDialog(ParentGui, Title, Message) {
        ParentGui.GetPos(&px, &py, &pw, &ph)

        dlgX := px + (pw - WrapPalette.DIALOG_WIDTH) // 2
        dlgY := py + (ph - WrapPalette.DIALOG_HEIGHT) // 2

        result := ""
        DlgGui := Gui("+Owner" ParentGui.Hwnd " +AlwaysOnTop -MinimizeBox -MaximizeBox", Title)
        DlgGui.SetFont("s10", "Segoe UI")

        DlgGui.Add("Text", "xm+20 ym+20 w460", Message)

        BtnYes := DlgGui.Add("Button", "xm+140 y+30 w100 h35 Default", "はい")
        BtnNo := DlgGui.Add("Button", "x+20 w100 h35", "いいえ")

        BtnYes.OnEvent("Click", (*) => (result := "Yes", DlgGui.Destroy()))
        BtnNo.OnEvent("Click", (*) => (result := "No", DlgGui.Destroy()))
        DlgGui.OnEvent("Close", (*) => (result := "No", DlgGui.Destroy()))
        DlgGui.OnEvent("Escape", (*) => (result := "No", DlgGui.Destroy()))

        ParentGui.Opt("+Disabled")
        DlgGui.Show("x" dlgX " y" dlgY " w" . WrapPalette.DIALOG_WIDTH . " h" . WrapPalette.DIALOG_HEIGHT)
        WinWaitClose("ahk_id " DlgGui.Hwnd)
        ParentGui.Opt("-Disabled")

        return result
    }

    ; ========================================
    ; 表示位置の決定と表示
    ; ========================================
    /**
     * セレクタの表示位置を決定して表示
     * カーソル位置に基づいて配置
     */
    static ShowAtPosition(SelGui, LV) {
        if (WrapPalette.LastX != "" && WrapPalette.LastY != "") {
            targetPos := "x" . WrapPalette.LastX . " y" . WrapPalette.LastY
        } else {
            CoordMode("Caret", "Screen")
            CoordMode("Mouse", "Screen")

            if CaretGetPos(&cx, &cy) {
                tx := cx + 5
                mNum := WrapPalette._GetMonitorFromPos(cx, cy)
                MonitorGetWorkArea(mNum, &mL, &mT, &mR, &mB)
                ty := (cy + 25 + WrapPalette.LIST_HEIGHT > mB) ?
                    cy - WrapPalette.LIST_HEIGHT - 10 : cy + 25
            } else {
                MouseGetPos(&mx, &my)
                tx := mx + 15
                ty := my + 15
            }

            WrapPalette._EnsureInScreen(&tx, &ty, WrapPalette.LIST_WIDTH, WrapPalette.LIST_HEIGHT)
            WrapPalette.LastX := tx
            WrapPalette.LastY := ty
            targetPos := "x" . tx . " y" . ty
        }

        ; 1行目を選択状態にしてフォーカス
        if (LV.GetCount() > 0) {
            LV.Modify(1, "Select Focus")
        }
        LV.Focus()
        SelGui.Show(targetPos)
    }

    ; ========================================
    ; 座標リセット
    ; ========================================
    /**
     * 記憶している表示位置をリセット
     */
    static ResetPosition() {
        WrapPalette.LastX := ""
        WrapPalette.LastY := ""
    }

    ; ========================================
    ; INIから登録名を取得
    ; ========================================
    /**
     * INIファイルから全ての登録名を取得
     * @return 登録名の配列
     */
    static GetNames() {
        if !FileExist(WrapPalette.IniPath)
            return []
        s := IniRead(WrapPalette.IniPath)
        return (s == "") ? [] : StrSplit(s, "`n")
    }

    ; ========================================
    ; モニター検出
    ; ========================================
    /**
     * 指定座標が含まれるモニターを取得
     */
    static _GetMonitorFromPos(x, y) {
        loop MonitorGetCount() {
            MonitorGet(A_Index, &L, &T, &R, &B)
            if (x >= L && x <= R && y >= T && y <= B)
                return A_Index
        }
        return MonitorGetPrimary()
    }

    ; ========================================
    ; 画面内に収まるように調整
    ; ========================================
    /**
     * 座標がモニター内に収まるように調整
     */
    static _EnsureInScreen(&x, &y, w, h) {
        loop MonitorGetCount() {
            MonitorGetWorkArea(A_Index, &left, &top, &right, &bottom)
            if (x >= left && x <= right && y >= top && y <= bottom) {
                if (x + w > right)
                    x := right - w - 10
                if (y + h > bottom)
                    y := bottom - h - 10
                if (y < top)
                    y := top + 10
                return
            }
        }
    }
    ; ========================================
    ; ========================================
    ; 改行のエスケープ/アンエスケープ
    ; ========================================
    /**
     * 改行をINIファイル保存用にエスケープ
     * @param text エスケープするテキスト
     * @return エスケープされたテキスト
     */
    static _EscapeNewlines(text) {
        ; `r`n (CRLF) と `n (LF) の両方を |\n| に変換
        text := StrReplace(text, "`r`n", "|\n|")
        text := StrReplace(text, "`n", "|\n|")
        return text
    }

    /**
     * エスケープされた改行を元に戻す
     * @param text アンエスケープするテキスト
     * @return 元のテキスト
     */
    static _UnescapeNewlines(text) {
        ; |\n| を `r`n (CRLF) に変換
        return StrReplace(text, "|\n|", "`r`n")
    }

    ; ========================================
    ; ヘルプ（? クリックで一括表示・最前面）
    ; ========================================
    /**
     * 各項目の説明をまとめて最前面のGuiで表示
     */
    static _ShowHelp(ownerGui) {
        text := "【登録名】`n" . WrapPalette.TIP_NAME
            . "`n`n【トリガ】`n" . WrapPalette.TIP_TRIGGER
            . "`n`n【行頭】`n" . WrapPalette.TIP_LINE_PREFIX
            . "`n`n【行末】`n" . WrapPalette.TIP_LINE_SUFFIX
            . "`n`n【パーツ構成】`n" . WrapPalette.TIP_PARTS
            . "`n`n【既存パーツから引用】`n" . WrapPalette.TIP_QUOTE
        HelpGui := Gui("+Owner" . ownerGui.Hwnd . " +AlwaysOnTop -MinimizeBox", "ヘルプ")
        HelpGui.SetFont("s10", "Segoe UI")
        HelpGui.Add("Text", "xm+15 ym+15 w450 Wrap", text)
        HelpGui.Add("Button", "xm+15 y+20 w80 Default", "OK").OnEvent("Click", (*) => HelpGui.Destroy())
        HelpGui.OnEvent("Close", (*) => HelpGui.Destroy())
        HelpGui.OnEvent("Escape", (*) => HelpGui.Destroy())
        HelpGui.Show()
        WinActivate("ahk_id " . HelpGui.Hwnd)
    }

    ; ========================================
    ; 加工エンジン
    ; ========================================
    /**
     * 原文に行頭・行末の付加を行い、左右パーツで囲んだ結果を返す
     * @param text 元テキスト
     * @param L 左パーツ
     * @param R 右パーツ
     * @param prefix 行頭に付ける文字（空の場合は付加しない）
     * @param suffix 行末に付ける文字（空の場合は付加しない）
     * @return 加工後のテキスト（L + body + R）
     */
    static _TransformText(text, L, R, prefix, suffix) {
        ; 行頭・行末の付加（引用符など）
        if (prefix != "" || suffix != "") {
            if (text == "")
                body := text
            else {
                lines := StrSplit(text, "`n", "`r")
                body := ""
                for i, line in lines {
                    if (i > 1)
                        body .= "`r`n"
                    body .= prefix . line . suffix
                }
            }
        } else
            body := text
        return L . body . R
    }

}
