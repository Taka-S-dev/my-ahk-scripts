#Requires AutoHotkey v2.0
; ==============================================================================
; Module:       Navi.Tab.ahk
; Description:  Navi タブ管理モジュール
;               - タブ状態の保存・復元・切り替え
;               - タブバー GUI の構築と表示/非表示切り替え
;               - タブ内ルート履歴（戻る/進む）
;               - INI へのタブ状態永続化
; Usage:        NaviTab.Init(naviRef) を Navi.Init() から呼び出す
; ==============================================================================

class NaviTab {
    static _navi := ""

    ; --- タブ定数 ---
    static TAB_MAX    := 5   ; タブ最大数
    static TAB_WIDTH  := 85  ; タブ1枠の幅px（作成時の仮の幅。表示時は名前の長さに合わせる）
    static TAB_MIN_W  := 64  ; タブ幅の下限px
    static TAB_MAX_W  := 170 ; タブ幅の上限px（超える名前は末尾を … で省略）
    static TAB_PAD_X  := 14  ; タブ名の左右の余白px（タブ幅の計算用）
    static TAB_TEXT_INSET := 10  ; 名前の部品をタブの内側へ寄せる幅px（長い名前が … で切れても両端に余白が残る）
    static TAB_HEIGHT := 26  ; タブ1枠の高さpx
    static PLUS_WIDTH := 26  ; + ボタンの幅px
    static TAB_HISTORY_MAX := 20  ; タブ内ルート履歴の最大保持件数
    static TAB_INDICATOR_H     := 2         ; アクセントラインの高さpx
    ; 色は NaviTheme を使う。VSCode・ブラウザと同じく、タブの帯を SURFACE にし、
    ; アクティブタブだけ本体と同じ BG でつなげる

    ; --- タブ状態 ---
    static _Tabs       := []  ; タブ配列（各要素: {root, filter, marks, markFilter, path, history, future}）
    static _CurrentTab := 1   ; アクティブタブ番号（1-based）
    static _TabCount   := 1   ; 現在開いているタブ数

    ; --- タブバー GUI コントロール参照 ---
    static _TabBtnCtrls    := []  ; タブの名前の部品（背景の内側に余白を取って重ねる）
    static _TabBgCtrls     := []  ; タブの背景の部品（タブの幅いっぱい。色とクリックを受け持つ）
    static _TabIndicators  := []  ; タブ毎の上端アクセントライン（アクティブタブのみ表示）
    static _TabDividers    := []  ; タブ間の縦線（TAB_MAX-1 個）
    static _TabPlusBtn     := ""  ; 新規タブ追加 + ボタン
    static _TabPlusHoverBg := ""  ; +ボタンのホバー時背景（ホバー時のみ表示）
    static _TabSepCtrl     := ""  ; タブ下の余白（レイアウトの基準。表示はしない）
    static _TabStripCtrl   := ""  ; タブの帯の背景
    static _tabBarVisible := true  ; タブバー表示状態（1 枚のときも常に表示する）
    static _tabBarShift   := 0     ; タブバー非表示時にコントロールを上げるpx（Show()で実測値に確定）
    static _HoverTimerActive := false  ; ホバーツールチップ用タイマー状態
    static _CheckTabHoverBound := ""   ; ホバーチェックタイマー用 Bound 関数（SetTimer 解除用）
    static _PlusIsHover := false       ; +ボタンの現在のホバー状態
    static _HoveredTab := 0            ; 現在ホバー中のタブ番号（0 = なし）

    static Init(naviRef) {
        this._navi := naviRef
    }

    ; ==============================================================================
    ; GUI 構築
    ; ==============================================================================

    /**
     * タブバーコントロールを guiObj に追加し、タブバー先頭の Y 座標を返す
     * Show() から呼ぶ。戻り値は _tabBarShift 計算に使用する。
     */
    static BuildTabBar(guiObj) {
        nv := this._navi
        this._TabBtnCtrls   := []
        this._TabBgCtrls    := []
        this._TabIndicators := []
        this._TabDividers   := []
        NaviTheme.SetFont(guiObj, "body")
        indColor := "Background" . NaviTheme.ACCENT
        ; タブの帯（最初に作って z-order を一番下にする）。上端からタブの下端まで全幅で敷く
        stripH := guiObj.MarginY + this.TAB_INDICATOR_H + this.TAB_HEIGHT
        strip := guiObj.Add("Text", "x0 y0 w" . (nv.GUI_WIDTH + 2 * guiObj.MarginX) . " h" . stripH
            . " Background" . NaviTheme.SURFACE, "")
        this._TabStripCtrl := strip
        ; VSCode風: アクティブタブの上端にアクセントラインを表示
        Loop this.TAB_MAX {
            n    := A_Index
            w    := this.TAB_WIDTH
            xOpt := (n = 1) ? "xm ym w" . w . " h" . this.TAB_INDICATOR_H . " " . indColor
                            : "x+1 yp w" . w . " h" . this.TAB_INDICATOR_H . " " . indColor
            ind := guiObj.Add("Text", xOpt, "")
            this._TabIndicators.Push(ind)
            ind.Visible := false
        }
        ; タブ（アクセントラインの下に配置）。背景（タブの幅いっぱい）の上に、左右へ余白を取った名前を重ねる
        ; 名前は 0x4301 = SS_ENDELLIPSIS | SS_CENTERIMAGE（縦中央）| SS_NOTIFY | SS_CENTER
        ; 位置と幅は UpdateTabBar で名前の長さに合わせて決め直す
        this._TabIndicators[1].GetPos(&tabX, &indY)
        tabY := indY + this.TAB_INDICATOR_H
        inset := this.TAB_TEXT_INSET
        bg   := " Background" . NaviTheme.SURFACE
        Loop this.TAB_MAX {
            n := A_Index
            w := this.TAB_WIDTH
            x := tabX + (n - 1) * (w + 1)
            back := guiObj.Add("Text", "x" . x . " y" . tabY . " w" . w . " h" . this.TAB_HEIGHT . " +0x100" . bg, "")
            lbl  := guiObj.Add("Text", "x" . (x + inset) . " y" . tabY . " w" . (w - 2 * inset) . " h" . this.TAB_HEIGHT
                . " +0x4301" . bg, this._GetTabLabel(n))
            this._TabBgCtrls.Push(back)
            this._TabBtnCtrls.Push(lbl)
            back.OnEvent("Click", this.MakeTabHandler(n))
            lbl.OnEvent("Click", this.MakeTabHandler(n))
            if (n > this._TabCount) {
                back.Visible := false
                lbl.Visible := false
            }
        }
        ; + ボタンのホバー背景（先に作成して z-order を下に。ホバー時のみ表示）
        plusBg := guiObj.Add("Text", "x+4 yp w" . this.PLUS_WIDTH . " h" . this.TAB_HEIGHT . " Background" . NaviTheme.HOVER, "")
        plusBg.Visible := false
        this._TabPlusHoverBg := plusBg
        ; + ボタン（新規タブ追加）
        guiObj.SetFont("s11 c" . NaviTheme.TEXT_MUTED)
        plus := guiObj.Add("Text", "xp yp w" . this.PLUS_WIDTH . " h" . this.TAB_HEIGHT . " +0x301 BackgroundTrans", "+")
        NaviTheme.SetFont(guiObj, "body")
        plus.OnEvent("Click", (*) => this.NewTab())
        this._TabPlusBtn := plus
        ; タブ間の区切り線（TAB_MAX-1 個）。タブ同士の 1px の隙間に置き、位置と表示は UpdateTabBar で決める
        Loop (this.TAB_MAX - 1) {
            div := guiObj.Add("Text", "x0 y0 w1 h1 Background" . NaviTheme.DIVIDER, "")
            div.Visible := false
            this._TabDividers.Push(div)
        }
        ; タブ下の余白（アクティブタブが本体の白とつながるので線は引かない）
        ; 後に続くヘッダー行はこの下に並ぶので、直前の部品ではなくタブの下端を基準に置く
        totalW := nv.GUI_WIDTH + 2 * guiObj.MarginX
        this._TabBgCtrls[1].GetPos(, &labelY, , &labelH)
        sep := guiObj.Add("Text", "x0 y" . (labelY + labelH) . " w" . totalW . " h2", "")
        this._TabSepCtrl := sep
        ; タブバー先頭の Y 座標を返す（_tabBarShift 計算用、インジケーターが一番上）
        tabBarTopY := 0
        this._TabIndicators[1].GetPos(, &tabBarTopY)
        return tabBarTopY
    }

    /**
     * タブ関連ホットキーを登録する（Show() の HotIf ブロック内から呼ぶ）
     */
    static RegisterHotkeys() {
        Loop this.TAB_MAX {
            Hotkey("^" . A_Index, this.MakeTabHandler(A_Index), "On")
        }
        Hotkey("^t",    (*) => this.NewTab(),         "On")
        Hotkey("^w",    (*) => this.CloseTab(),        "On")
        Hotkey("^Tab",  (*) => this.SwitchToTab(Mod(this._CurrentTab, this._TabCount) + 1), "On")
        Hotkey("^+Tab", (*) => this.SwitchToTab(Mod(this._CurrentTab - 2 + this._TabCount, this._TabCount) + 1), "On")
        Hotkey("!Left",  (*) => this.TabNavBack(),    "On")
        Hotkey("!Right", (*) => this.TabNavForward(), "On")
        Hotkey("^+h",    (*) => this.ClearTabHistory(), "On")
        ; 中クリックでタブを閉じる（ブラウザと同じ挙動）
        Hotkey("~MButton", (*) => this._OnMiddleClick(), "On")
        ; タブ上のホバーでフルパスをツールチップ表示
        this._CheckTabHoverBound := this._CheckTabHover.Bind(this)
        SetTimer(this._CheckTabHoverBound, 250)
        this._HoverTimerActive := true
    }

    /**
     * マウスの下の部品がどのタブか（背景・名前のどちらでも）。タブでなければ 0
     */
    static _TabIndexFromHwnd(hwnd) {
        if (!hwnd)
            return 0
        loop Min(this._TabCount, this._TabBtnCtrls.Length) {
            if (this._TabBtnCtrls[A_Index].Hwnd == hwnd || this._TabBgCtrls[A_Index].Hwnd == hwnd)
                return A_Index
        }
        return 0
    }

    /**
     * WM_SETCURSOR ハンドラー: タブラベル・+ボタン上でハンドカーソルを表示
     * OnMessage 経由で呼び出される
     */
    static _OnSetCursor(wParam, lParam, msg, hwnd) {
        if (this._TabPlusBtn && wParam == this._TabPlusBtn.Hwnd) {
            DllCall("user32\SetCursor", "ptr", DllCall("user32\LoadCursorW", "ptr", 0, "ptr", 32649, "ptr"))  ; IDC_HAND
            return true
        }
        if (this._TabIndexFromHwnd(wParam)) {
            DllCall("user32\SetCursor", "ptr", DllCall("user32\LoadCursorW", "ptr", 0, "ptr", 32649, "ptr"))
            return true
        }
    }

    /**
     * 中クリック処理: タブラベル上ならそのタブを閉じる
     */
    static _OnMiddleClick() {
        MouseGetPos(, , , &ctrlHwnd, 2)
        if (n := this._TabIndexFromHwnd(ctrlHwnd)) {
            if (this._CurrentTab != n)
                this.SwitchToTab(n)
            this.CloseTab()
        }
    }

    /**
     * 右クリック処理: タブラベル上なら閉じるメニューを表示。タブ上でなければ false を返してパススルー
     */
    static HandleRightClick() {
        MouseGetPos(, , , &ctrlHwnd, 2)
        if !(n := this._TabIndexFromHwnd(ctrlHwnd))
            return false
        this._ShowTabContextMenu(n)
        return true
    }

    /**
     * タブ右クリックメニュー: 閉じる / 他のタブを閉じる
     */
    static _ShowTabContextMenu(n) {
        m := Menu()
        m.Add("閉じる", ((idx, *) => (this.SwitchToTab(idx), this.CloseTab())).Bind(n))
        if (this._TabCount > 2) {
            m.Add("他のタブを閉じる", ((idx, *) => this._CloseOtherTabs(idx)).Bind(n))
        }
        if (this._TabCount <= 1)
            m.Disable("閉じる")
        m.Show()
    }

    /**
     * 指定タブ以外を全て閉じる（インデックスがシフトしないよう右側から先に閉じる）
     */
    static _CloseOtherTabs(keepN) {
        while (this._TabCount > 1) {
            if (this._TabCount > keepN) {
                ; keepN より右側のタブを末尾から閉じる（keepN のインデックスは変わらない）
                this.SwitchToTab(this._TabCount)
                this.CloseTab()
            } else {
                ; 右側を閉じ終わったので左側を閉じる（keepN は 1 つ前にずれる）
                this.SwitchToTab(1)
                this.CloseTab()
                keepN--
            }
        }
    }

    /**
     * 250ms ごとにタブと +ボタンのホバー状態をチェック
     * - タブホバー → フルパスのツールチップ表示
     * - +ボタンホバー → 文字色を強調
     */
    static _CheckTabHover() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj) && WinActive("ahk_id " nv.GuiObj.Hwnd)) {
            ToolTip(, , , 2)
            this._SetPlusHover(false)
            return
        }
        MouseGetPos(, , , &ctrlHwnd, 2)
        ; + ボタンホバー判定
        if (this._TabPlusBtn && ctrlHwnd == this._TabPlusBtn.Hwnd) {
            this._SetPlusHover(true)
            ToolTip("新しいタブ", , , 2)
            return
        }
        this._SetPlusHover(false)
        ; タブホバー判定
        if (n := this._TabIndexFromHwnd(ctrlHwnd)) {
            this._SetTabHover(n)
            root := (n == this._CurrentTab) ? nv.lastRoot
                : (n <= this._Tabs.Length && this._Tabs[n] != "") ? this._Tabs[n].root : ""
            if (root == "") {
                ToolTip("(新規タブ)", , , 2)
                return
            }
            fullPath := nv._FolderMap.Has(root) ? nv._FolderMap[root] : ""
            tip := (fullPath != "" && fullPath != root) ? root . "`n" . fullPath : root
            ToolTip(tip, , , 2)
            return
        }
        this._SetTabHover(0)
        ToolTip(, , , 2)
    }

    /**
     * タブのホバー切替: 非アクティブタブの文字色を中間色に変える
     */
    static _SetTabHover(n) {
        if (this._HoveredTab == n)
            return
        ; 前回ホバー中だったタブを本来の見た目に戻す
        if (this._HoveredTab > 0 && this._HoveredTab <= this._TabBtnCtrls.Length)
            this._PaintTab(this._HoveredTab)
        this._HoveredTab := n
        ; アクティブタブはホバー対象外（既に白で目立っている）
        if (n > 0 && n != this._CurrentTab && n <= this._TabBtnCtrls.Length)
            this._PaintTab(n, true)
    }

    /**
     * タブ n の文字色・背景色を状態に合わせて塗り直す
     * アクティブ=本体と同じ白 / ホバー=少し濃い灰色 / それ以外=帯と同じ灰色
     */
    static _PaintTab(n, hover := false) {
        if (n == this._CurrentTab)
            text := NaviTheme.TEXT, back := NaviTheme.BG
        else if (hover)
            text := NaviTheme.TEXT, back := NaviTheme.HOVER
        else
            text := NaviTheme.TEXT_MUTED, back := NaviTheme.SURFACE
        for ctrl in [this._TabBgCtrls[n], this._TabBtnCtrls[n]] {
            ctrl.Opt("+c" . text . " +Background" . back)
            DllCall("InvalidateRect", "ptr", ctrl.Hwnd, "ptr", 0, "int", true)
        }
    }

    /**
     * タブ名の表示幅（px）を GUI のフォントで測る。DPI スケーリング前の値に直して返す
     */
    static _MeasureText(ctrl, text) {
        hdc := DllCall("GetDC", "ptr", ctrl.Hwnd, "ptr")
        hFont := SendMessage(0x0031, 0, 0, ctrl)  ; WM_GETFONT
        old := DllCall("SelectObject", "ptr", hdc, "ptr", hFont, "ptr")
        size := Buffer(8, 0)
        DllCall("GetTextExtentPoint32W", "ptr", hdc, "wstr", text, "int", StrLen(text), "ptr", size)
        DllCall("SelectObject", "ptr", hdc, "ptr", old)
        DllCall("ReleaseDC", "ptr", ctrl.Hwnd, "ptr", hdc)
        return Round(NumGet(size, 0, "int") * 96 / A_ScreenDPI)
    }

    /**
     * +ボタンのホバー切替（背景ハイライトの表示/非表示と文字色変更）
     */
    static _SetPlusHover(hover) {
        if (!this._TabPlusBtn)
            return
        if (this._PlusIsHover == hover)
            return
        this._PlusIsHover := hover
        ; ホバー背景を表示/非表示
        if (this._TabPlusHoverBg)
            this._TabPlusHoverBg.Visible := hover && this._TabPlusBtn.Visible
        ; 文字色も変更（ホバー時は黒で強調）
        color := hover ? NaviTheme.TEXT : NaviTheme.TEXT_MUTED
        this._TabPlusBtn.Opt("+c" . color)
        DllCall("InvalidateRect", "ptr", this._TabPlusBtn.Hwnd, "ptr", 0, "int", true)
    }

    /**
     * GUI 破棄時にコントロール参照をリセット（タブ状態は保持して次回起動時に再利用）
     */
    static Cleanup() {
        this._TabBtnCtrls    := []
        this._TabBgCtrls     := []
        this._TabIndicators  := []
        this._TabDividers    := []
        this._TabPlusBtn     := ""
        this._TabPlusHoverBg := ""
        this._TabSepCtrl     := ""
        this._TabStripCtrl   := ""
        this._HoveredTab     := 0
        if (this._HoverTimerActive) {
            SetTimer(this._CheckTabHoverBound, 0)
            this._HoverTimerActive := false
            ToolTip(, , , 2)
        }
    }

    ; ==============================================================================
    ; タブバー表示更新
    ; ==============================================================================

    /**
     * タブバーのラベル・インジケーター・縦線・+ ボタンの位置と表示を更新
     * タブが 1 枚のときも表示する（枚数で画面の上端が動かず、＋ で増やせることが常に見える）
     */
    static UpdateTabBar() {
        nv := this._navi
        widths := this._TabWidths()
        margin := nv.GuiObj.MarginX
        x := margin
        Loop this.TAB_MAX {
            n := A_Index
            if (n > this._TabBtnCtrls.Length)
                break
            ctrl := this._TabBtnCtrls[n]
            if (n > this._TabCount) {
                ctrl.Visible := false
                this._TabBgCtrls[n].Visible := false
                continue
            }
            ctrl.Visible := true
            this._TabBgCtrls[n].Visible := true
            DllCall("user32\SendMessageW", "ptr", ctrl.Hwnd,
                "uint", nv.WM_SETTEXT, "ptr", 0, "wstr", this._GetTabLabel(n))
            ; 名前の長さに合わせた幅で左から詰めて並べる（背景とアクセントラインはタブの幅、名前は内側）
            this._TabBgCtrls[n].Move(x, , widths[n])
            ctrl.Move(x + this.TAB_TEXT_INSET, , Max(1, widths[n] - 2 * this.TAB_TEXT_INSET))
            this._TabIndicators[n].Move(x, , widths[n])
            x += widths[n] + 1
            this._PaintTab(n, n == this._HoveredTab)
        }
        ; アクティブタブのアクセントラインのみ表示
        showInd := (this._TabCount >= 1)
        for n, ind in this._TabIndicators
            ind.Visible := showInd && (n == this._CurrentTab) && (n <= this._TabCount)
        ; + ボタンを最後のタブの右側に配置（タブ数が TAB_MAX のときは非表示）
        if (this._TabPlusBtn) {
            canAdd := (this._TabCount < this.TAB_MAX)
            this._TabPlusBtn.Visible := canAdd
            if (canAdd) {
                plusX := x + 3
                this._TabPlusBtn.Move(plusX)
                if (this._TabPlusHoverBg)
                    this._TabPlusHoverBg.Move(plusX)
            }
            ; + ボタンが非表示ならホバー背景も必ず消す
            if (!canAdd && this._TabPlusHoverBg)
                this._TabPlusHoverBg.Visible := false
        }
        this.SetTabBarVisible(true)
        this._LayoutDividers()  ; タブバーの表示状態が決まってから置く
        this._RedrawTabBar()
    }

    /**
     * タブの帯を下から順に描き直す
     * タブの幅が変わって並べ直すと、元の場所に前の文字の一部が残ることがあるため
     * （帯とタブは重なった兄弟の部品なので、帯 → 背景 → 名前 → 線 の順に描かせる）
     */
    static _RedrawTabBar() {
        flags := 0x1 | 0x4 | 0x100  ; RDW_INVALIDATE | RDW_ERASE | RDW_UPDATENOW
        ctrls := [this._TabStripCtrl]
        for c in this._TabBgCtrls
            ctrls.Push(c)
        for c in this._TabBtnCtrls
            ctrls.Push(c)
        for c in this._TabIndicators
            ctrls.Push(c)
        for c in this._TabDividers
            ctrls.Push(c)
        ctrls.Push(this._TabPlusHoverBg, this._TabPlusBtn)
        for c in ctrls {
            if (c && c.Visible)
                DllCall("user32\RedrawWindow", "ptr", c.Hwnd, "ptr", 0, "ptr", 0, "uint", flags)
        }
    }

    /**
     * タブの間の区切り線を置く（Chrome・Fork と同じく、タブの高さより上下を少し詰める）
     * アクティブタブは白い面が区切りになるので、その両隣の線は出さない
     */
    static _LayoutDividers() {
        show := this._tabBarVisible
        for n, div in this._TabDividers {
            visible := show && (n < this._TabCount) && (n != this._CurrentTab) && (n + 1 != this._CurrentTab)
            if (visible) {
                ; タブ n の右端（= タブ n と n+1 の間の 1px の隙間）。GetPos と Move は同じ DPI 換算の単位
                this._TabBgCtrls[n].GetPos(&tx, &ty, &tw, &th)
                inset := Round(th * 0.25)
                div.Move(tx + tw, ty + inset, 1, th - 2 * inset)
            }
            div.Visible := visible
            if (visible)
                DllCall("InvalidateRect", "ptr", div.Hwnd, "ptr", 0, "int", true)
        }
    }

    /**
     * 開いているタブそれぞれの幅（名前の長さ + 余白。TAB_MIN_W〜TAB_MAX_W）
     * 全部が窓に入らないときは、入るように同じ割合で縮める
     */
    static _TabWidths() {
        nv := this._navi
        widths := []
        total := 0
        Loop this._TabCount {
            ctrl := this._TabBtnCtrls[A_Index]
            w := this._MeasureText(ctrl, this._GetTabLabel(A_Index)) + 2 * this.TAB_PAD_X
            w := Min(Max(w, this.TAB_MIN_W), this.TAB_MAX_W)
            widths.Push(w)
            total += w + 1
        }
        nv.GuiObj.GetClientPos(, , &cw)  ; GetClientPos は Move と同じ DPI 換算の単位で返す
        if (cw <= 0)  ; 表示前は幅が 0 なので、表示するときの幅で計算する
            cw := (nv._savedW > 0) ? nv._savedW : nv.GUI_WIDTH + 2 * nv.GuiObj.MarginX
        avail := cw - 2 * nv.GuiObj.MarginX - this.PLUS_WIDTH - 4
        if (total > avail && total > 0) {
            ratio := avail / total
            for i, w in widths
                widths[i] := Max(Floor(w * ratio), 40)
        }
        return widths
    }

    /**
     * タブバーの表示/非表示を切り替え、他コントロールを上下にシフトする
     */
    static SetTabBarVisible(show) {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (show == this._tabBarVisible)
            return
        this._tabBarVisible := show
        shift := show ? this._tabBarShift : -this._tabBarShift

        ; タブラベル・インジケーター・+ボタン・区切り線の表示切り替え（_TabCount を超えるものは非表示維持）
        for n, ctrl in this._TabBtnCtrls {
            ctrl.Visible := show && (n <= this._TabCount)
            this._TabBgCtrls[n].Visible := ctrl.Visible
        }
        for n, ind in this._TabIndicators
            ind.Visible := show && (n == this._CurrentTab) && (n <= this._TabCount)
        if (this._TabPlusBtn)
            this._TabPlusBtn.Visible := show && (this._TabCount < this.TAB_MAX)
        if (this._TabStripCtrl)
            this._TabStripCtrl.Visible := show

        ; タブバー下のコントロールを全て上下にシフト
        ctrls := [
            nv.GuiObj["ProfileBtn"], nv.GuiObj["ProfileSep"],
            nv.GuiObj["RootBtn"],
            nv.GuiObj._btnSettingsCtrl,
            nv.GuiObj["PinCheck"], nv.GuiObj["AutoFilesCheck"],
            nv.GuiObj["Breadcrumb"], nv.GuiObj["FilterToggle"],
            nv.GuiObj["SearchTypeBtn"], nv.GuiObj["TreeFilter"],
            nv.GuiObj["FolderTree"], nv.GuiObj["DirList"],
            nv.GuiObj["QuickPath"]
        ]
        for ctrl in ctrls {
            ctrl.GetPos(, &cy)
            ctrl.Move(, cy + shift)
        }
        nv._tvY += shift
        this._LayoutDividers()
    }

    ; ==============================================================================
    ; タブ状態の読み書き
    ; ==============================================================================

    /**
     * GUIから現在の表示状態を読み取って返す
     */
    static _GetLiveState() {
        nv := this._navi
        marks := Map()
        for k, v in NaviMark._MarkedPaths
            marks[k] := v
        selPath := ""
        try selPath := nv._GetSelectedPath()
        return {
            root:       nv.lastRoot,
            filter:     nv.GuiObj["TreeFilter"].Value,
            marks:      marks,
            markFilter: NaviMark._MarkFilterActive,
            path:       selPath
        }
    }

    /**
     * 現在のタブに表示状態を保存
     */
    static SaveCurrentTab() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        s := this._GetLiveState()
        while (this._Tabs.Length < this._CurrentTab)
            this._Tabs.Push({ root: "", filter: "", marks: Map(), markFilter: false, path: "", history: [], future: [] })
        tab := this._Tabs[this._CurrentTab]
        tab.root := s.root, tab.filter := s.filter, tab.marks := s.marks
        tab.markFilter := s.markFilter, tab.path := s.path
    }

    /**
     * 現在のルート操作前に呼ぶ: 現在の状態をタブ内履歴に積む（Alt+← で戻れる）
     */
    static PushTabHistory() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        while (this._Tabs.Length < this._CurrentTab)
            this._Tabs.Push({ root: "", filter: "", marks: Map(), markFilter: false, path: "", history: [], future: [] })
        tab := this._Tabs[this._CurrentTab]
        s := this._GetLiveState()
        tab.history.Push({ root: s.root, filter: s.filter, marks: s.marks, markFilter: s.markFilter, path: s.path })
        if (tab.history.Length > this.TAB_HISTORY_MAX)
            tab.history.RemoveAt(1)
        tab.future := []
    }

    /**
     * 状態オブジェクトを TreeView に適用する共通ヘルパー
     */
    static _ApplyTabState(state, tv) {
        nv := this._navi
        if (state.root != "" && nv._FolderMap.Has(state.root) && state.root != nv.lastRoot) {
            nv.lastRoot := state.root
            nv.GuiObj["RootBtn"].Text := nv._TruncRootLabel(state.root)
        }
        rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
        nv.GuiObj["TreeFilter"].Value := state.filter
        if (state.markFilter && rootPath != "") {
            NaviMark._MarkedPaths    := state.marks
            NaviMark._MarkFilterActive := true
            NaviMark._ApplyMarkFilter(tv, rootPath)
        } else if (state.filter != "" && rootPath != "") {
            NaviMark._MarkFilterActive := false
            NaviMark._MarkedPaths    := state.marks
            NaviFilter.ApplyTreeFilter(state.filter)
        } else if (rootPath != "") {
            NaviMark._MarkFilterActive := false
            nv._RefreshTree(tv, rootPath, false)
            NaviMark._MarkedPaths := state.marks
            NaviMark._RebuildMarkedIdSet(tv)
            NaviFilter.EnsureFilterDraw(tv)
            DllCall("user32\InvalidateRect", "ptr", tv.Hwnd, "ptr", 0, "int", 1)
        }
        if (state.path != "" && rootPath != "") {
            nv._FocusPath(tv, state.path)
            ; フィルタ非同期完了後にも復元できるよう目標パスを保存
            nv._RestoreTargetPath := state.path
        }
        ; 3 列の表示中は、切り替えたタブのルートを 3 列で開き直す
        ; （上の ApplyTreeFilter は 3 列の中央の列に効いてしまうので、開き直して絞り込みも消す）
        if (NaviBrowse.Active && rootPath != "")
            NaviBrowse.Open(rootPath)
    }

    /**
     * 現在のタブ状態を TreeView に復元する（Show() 初期化用）
     */
    static RestoreCurrentTab(tv) {
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return false
        tab := this._Tabs[this._CurrentTab]
        nv  := this._navi
        if (tab.root == "" || !nv._FolderMap.Has(tab.root))
            return false
        this._ApplyTabState(tab, tv)
        return true
    }

    ; ==============================================================================
    ; タブ操作
    ; ==============================================================================

    /**
     * タブNのクリック・ホットキー用クロージャを生成（ループ変数キャプチャ対策）
     */
    static MakeTabHandler(n) {
        return (*) => this.SwitchToTab(n)
    }

    /**
     * タブNのラベルを返す（背景ハイライトがアクティブを示すため、ラベルはルート名のみ）
     */
    static _GetTabLabel(n) {
        if (n > this._TabCount)
            return ""
        root := (n == this._CurrentTab) ? this._navi.lastRoot
            : (n <= this._Tabs.Length && this._Tabs[n] != "") ? this._Tabs[n].root : ""
        ; 省略はしない。幅に入りきらない分はラベルの SS_ENDELLIPSIS が … にする
        return (root == "") ? "New" : this._navi.RootLabel(root)
    }

    /**
     * タブNに切り替える（現在の状態を保存してから復元）
     */
    static SwitchToTab(n) {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (n < 1 || n > this._TabCount)
            return
        this.SaveCurrentTab()
        this._CurrentTab := n
        tv  := nv.GuiObj["FolderTree"]
        tab := (n <= this._Tabs.Length) ? this._Tabs[n] : ""
        if (tab == "" || tab.root == "") {
            nv.GuiObj["TreeFilter"].Value := ""
            NaviMark._MarkFilterActive := false
            rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
            if (rootPath != "")
                nv._RefreshTree(tv, rootPath, false)
            NaviMark._MarkedPaths := Map()
            NaviMark._MarkedIdSet := Map()
        } else {
            this._ApplyTabState(tab, tv)
        }
        this.UpdateTabBar()
        nv._UpdateStatusBar()
        nv.GuiObj["TreeFilter"].Focus()
    }

    /**
     * 新しいタブを開く（Ctrl+T）: 現在のルートで初期化、フィルター・マークはクリア
     */
    static NewTab() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this._TabCount >= this.TAB_MAX)
            return
        this.SaveCurrentTab()
        this._TabCount++
        while (this._Tabs.Length < this._TabCount)
            this._Tabs.Push({ root: "", filter: "", marks: Map(), markFilter: false, path: "", history: [], future: [] })
        this._Tabs[this._TabCount] := {
            root: nv.lastRoot, filter: "", marks: Map(),
            markFilter: false, path: "", history: [], future: []
        }
        this._CurrentTab := this._TabCount
        tv := nv.GuiObj["FolderTree"]
        nv.GuiObj["TreeFilter"].Value := ""
        NaviMark._MarkFilterActive := false
        NaviMark._MarkedPaths := Map()
        NaviMark._MarkedIdSet := Map()
        rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
        if (rootPath != "")
            nv._RefreshTree(tv, rootPath, false)
        this.UpdateTabBar()
        nv._UpdateStatusBar()
    }

    /**
     * 現在のタブを閉じる（Ctrl+W）: タブが1枚のときは何もしない
     */
    static CloseTab() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this._TabCount <= 1)
            return
        this._Tabs.RemoveAt(this._CurrentTab)
        this._TabCount--
        if (this._CurrentTab > this._TabCount)
            this._CurrentTab := this._TabCount
        tv  := nv.GuiObj["FolderTree"]
        tab := (this._CurrentTab <= this._Tabs.Length) ? this._Tabs[this._CurrentTab] : ""
        if (tab == "" || tab.root == "") {
            nv.GuiObj["TreeFilter"].Value := ""
            NaviMark._MarkFilterActive := false
            NaviMark._MarkedPaths := Map()
            NaviMark._MarkedIdSet := Map()
            rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
            if (rootPath != "")
                nv._RefreshTree(tv, rootPath, false)
        } else {
            this._ApplyTabState(tab, tv)
        }
        this.UpdateTabBar()
        nv._UpdateStatusBar()
    }

    /**
     * タブ内履歴を戻る（Alt+←）
     */
    static TabNavBack() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return
        tab := this._Tabs[this._CurrentTab]
        if (tab.history.Length == 0)
            return
        s := this._GetLiveState()
        tab.future.Push({ root: s.root, filter: s.filter, marks: s.marks, markFilter: s.markFilter, path: s.path })
        prev := tab.history.Pop()
        tab.root := prev.root, tab.filter := prev.filter, tab.marks := prev.marks
        tab.markFilter := prev.markFilter, tab.path := prev.path
        this._ApplyTabState(tab, nv.GuiObj["FolderTree"])
        this.UpdateTabBar()
        nv._UpdateStatusBar()
    }

    /**
     * タブ内履歴を進む（Alt+→）
     */
    static TabNavForward() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return
        tab := this._Tabs[this._CurrentTab]
        if (tab.future.Length == 0)
            return
        s := this._GetLiveState()
        tab.history.Push({ root: s.root, filter: s.filter, marks: s.marks, markFilter: s.markFilter, path: s.path })
        next := tab.future.Pop()
        tab.root := next.root, tab.filter := next.filter, tab.marks := next.marks
        tab.markFilter := next.markFilter, tab.path := next.path
        this._ApplyTabState(tab, nv.GuiObj["FolderTree"])
        this.UpdateTabBar()
        nv._UpdateStatusBar()
    }

    /**
     * 現在のタブの履歴（戻る・進む）をクリア（Ctrl+Shift+H）
     */
    static ClearTabHistory() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        if (this._CurrentTab > this._Tabs.Length || this._Tabs[this._CurrentTab] == "")
            return
        tab := this._Tabs[this._CurrentTab]
        tab.history := []
        tab.future  := []
        ToolTip("タブ履歴をクリアしました"), SetTimer(() => ToolTip(), -nv.TOOLTIP_SUCCESS_DURATION)
    }

    ; ==============================================================================
    ; INI 永続化
    ; ==============================================================================

    /**
     * プロファイルパスから INI セクション名を生成（例: "Tabs_work"）
     * プロファイル未設定時は "Tabs" を返す
     */
    static _ProfileTabSection(profilePath := "") {
        nv := this._navi
        if (profilePath == "")
            profilePath := IniRead(nv.IniPath, "Settings", "LastProfile", "")
        if (profilePath == "")
            return "Tabs"
        name := RegExReplace(profilePath, ".*\\")   ; basename
        name := RegExReplace(name, "\.txt$", "")    ; 拡張子除去
        name := RegExReplace(name, "[^\w]", "_")    ; 使用不可文字を _
        return "Tabs_" . name
    }

    /**
     * 全タブ状態を Navi.ini のプロファイル別セクションに保存
     */
    static SaveTabsToIni() {
        nv  := this._navi
        sec := this._ProfileTabSection()
        try IniDelete(nv.IniPath, sec)
        IniWrite(this._TabCount,   nv.IniPath, sec, "Count")
        IniWrite(this._CurrentTab, nv.IniPath, sec, "Current")
        Loop this._TabCount {
            n   := A_Index
            tab := (n <= this._Tabs.Length) ? this._Tabs[n] : ""
            if (tab == "")
                continue
            IniWrite(tab.root,                     nv.IniPath, sec, "Tab" . n . "Root")
            IniWrite(tab.filter,                   nv.IniPath, sec, "Tab" . n . "Filter")
            IniWrite(tab.path,                     nv.IniPath, sec, "Tab" . n . "Path")
            IniWrite(tab.markFilter ? "1" : "0",   nv.IniPath, sec, "Tab" . n . "MarkFilter")
            markStr := ""
            for k, v in tab.marks
                markStr .= (markStr == "" ? "" : "|") . v
            IniWrite(markStr, nv.IniPath, sec, "Tab" . n . "Marks")
        }
    }

    /**
     * Navi.ini のプロファイル別セクションからタブ状態を復元
     * Show() の _LoadFolders 直後に呼ぶこと（タブバー生成前に _TabCount を確定させるため）
     */
    static LoadTabsFromIni() {
        nv  := this._navi
        sec := this._ProfileTabSection()
        ; プロファイル別セクションになければ旧来の [Tabs] にフォールバック
        if (IniRead(nv.IniPath, sec, "Count", "") == "")
            sec := "Tabs"
        count   := Max(1, Min(Integer(IniRead(nv.IniPath, sec, "Count",   "1")), this.TAB_MAX))
        current := Max(1, Min(Integer(IniRead(nv.IniPath, sec, "Current", "1")), count))
        this._TabCount   := count
        this._CurrentTab := current
        this._Tabs       := []

        Loop count {
            n    := A_Index
            root := IniRead(nv.IniPath, sec, "Tab" . n . "Root",       "")
            filt := IniRead(nv.IniPath, sec, "Tab" . n . "Filter",     "")
            pth  := IniRead(nv.IniPath, sec, "Tab" . n . "Path",       "")
            mf   := IniRead(nv.IniPath, sec, "Tab" . n . "MarkFilter", "0")
            mStr := IniRead(nv.IniPath, sec, "Tab" . n . "Marks",      "")

            marks := Map()
            if (mStr != "")
                for p in StrSplit(mStr, "|")
                    if (p != "")
                        marks[StrLower(p)] := p

            this._Tabs.Push({
                root: root, filter: filt, path: pth,
                markFilter: (mf == "1"), marks: marks,
                history: [], future: []
            })
        }
    }
}
