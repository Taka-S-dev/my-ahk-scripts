; ==============================================================================
; Module:       WrapPalette.ahk
; Description:  選択したテキストを登録済みのパーツで囲むGUIツール
;               - トリガキーによる即実行（1文字のショートカット）
;               - 複数行パーツ対応、HTMLタグやコードスニペットも快適に編集
;               - 既存パーツからの引用、トリガー重複チェック、複数選択削除
; Version:      1.0.0
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
    static EDIT_HEIGHT := 480
    static EDIT_GROUPBOX_WIDTH := 600
    static EDIT_GROUPBOX_HEIGHT := 240
    static EDIT_INPUT_WIDTH := 220
    static EDIT_INPUT_HEIGHT := 180

    ; 確認ダイアログのサイズ
    static DIALOG_WIDTH := 500
    static DIALOG_HEIGHT := 220

    ; クリップボード待機時間（秒）
    static CLIP_WAIT_SHORT := 0.3
    static CLIP_WAIT_LONG := 0.5

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

        ; 基本情報
        EditGui.Add("Text", "xm+10 ym+15 w120", "登録名:")
        EName := EditGui.Add("Edit", "x+10 yp-3 w320 h24", targetName)
        EditGui.Add("Text", "xm+10 y+15 w120", "トリガ:")
        ETrig := EditGui.Add("Edit", "x+10 yp-3 w60 Center Limit1", dT)

        ; パーツ構成
        EditGui.Add("GroupBox",
            "xm+10 y+20 w" . WrapPalette.EDIT_GROUPBOX_WIDTH . " h" . WrapPalette.EDIT_GROUPBOX_HEIGHT,
            "パーツ構成")
        EditL := EditGui.Add("Edit",
            "xp+15 yp+40 w" . WrapPalette.EDIT_INPUT_WIDTH . " h" . WrapPalette.EDIT_INPUT_HEIGHT . " Multi vscroll",
            dL)
        EditGui.Add("Text", "x+15 yp+85 w100 Center", "+ 原文 +")
        EditR := EditGui.Add("Edit",
            "x+15 yp-85 w" . WrapPalette.EDIT_INPUT_WIDTH . " h" . WrapPalette.EDIT_INPUT_HEIGHT . " Multi vscroll",
            dR)

        ; 既存パーツから引用
        EditGui.SetFont("s9")
        EditGui.Add("Text", "xm+10 y+35 cGray", "既存パーツから引用：")
        DL_L := EditGui.Add("DropDownList", "xm+10 y+10 w290", Names)
        DR_L := EditGui.Add("DropDownList", "x+20 w290", Names)

        DL_L.OnEvent("Change", (g, *) => (EditL.Value := WrapPalette._UnescapeNewlines(IniRead(WrapPalette.IniPath, g.Text,
            "left", ""))))
        DR_L.OnEvent("Change", (g, *) => (EditR.Value := WrapPalette._UnescapeNewlines(IniRead(WrapPalette.IniPath, g.Text,
            "right", ""))))

        ; ボタン
        EditGui.Add("Button", "xm+10 y+25 w290 h40 Default", "保存して戻る").OnEvent("Click", (*) =>
            WrapPalette.SaveAndReturn(EName.Value, EditL.Value, EditR.Value, ETrig.Value, EditGui, targetName))

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
    static SaveAndReturn(N, L, R, T, G, OriginalName := "") {
        if (N == "")
            return

        ; トリガキーの重複チェック
        if (T != "") {
            Names := WrapPalette.GetNames()
            for name in Names {
                if (name != OriginalName && name != N) {
                    existingTrig := IniRead(WrapPalette.IniPath, name, "trigger", "")
                    if (existingTrig == T) {
                        G.Opt("+OwnDialogs")
                        MsgBox("トリガキー '" T "' は既に '" name "' で使用されています。`n別のトリガキーを指定してください。",
                            "エラー", "Icon!")
                        return
                    }
                }
            }
        }

        ; 保存（改行をエスケープ）
        IniWrite(WrapPalette._EscapeNewlines(L), WrapPalette.IniPath, N, "left")
        IniWrite(WrapPalette._EscapeNewlines(R), WrapPalette.IniPath, N, "right")
        IniWrite(T, WrapPalette.IniPath, N, "trigger")

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

        ; パーツ読み込み（改行をアンエスケープ）
        L := WrapPalette._UnescapeNewlines(IniRead(WrapPalette.IniPath, Name, "left", ""))
        R := WrapPalette._UnescapeNewlines(IniRead(WrapPalette.IniPath, Name, "right", ""))
        out := L . WrapPalette.CurrentText . R

        ; GUI閉じる
        if (WrapPalette.MainGui)
            WrapPalette.MainGui.Destroy()

        ; 貼り付け
        A_Clipboard := out
        ClipWait(WrapPalette.CLIP_WAIT_LONG)
        Send("^v")

        WrapPalette.ResetPosition()
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

}
