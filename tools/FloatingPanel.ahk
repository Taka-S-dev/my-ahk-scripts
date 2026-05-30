; ==============================================================================
; Module:       FloatingPanel.ahk
; Description:  汎用フローティング・クリックパネル（再利用ライブラリ）
;               - 常時最前面・タスクバー非表示・NOACTIVATE（クリックしても前面の
;                 別アプリからフォーカスを奪わない → Send が対象アプリに届く）
;               - フラットなボタン（ホバーで着色）・ヘッダードラッグで移動
;               - 位置を INI に保存／復元
;               任意のツールがボタン定義配列を渡すだけでパネルを持てる。
; Usage:
;     panel := FloatingPanel({
;         name:    "vsdebug",                       ; 位置保存キー（[Panel_vsdebug]）
;         title:   "VS Debug",                      ; ヘッダー文言
;         iniPath: A_ScriptDir "\Foo.ini",          ; 省略可（位置保存しない）
;         width:    166,                            ; 省略可（既定 166）
;         fontSize: 10,                             ; 省略可（既定 10。大きく=パネルも拡大）
;         btnHeight: 30,                            ; 省略可（既定ボタン高。個別 h で上書き可）
;         opacity:  255,                            ; 省略可（0-255、255=不透明）
;         buttons: [
;             {label:"⤼  Step Over", h:40, bg:"37373D", color:"FFFFFF",
;              action:() => MyTool.StepOver()},
;             {label:"▶  Continue",  color:"89D185", action:() => MyTool.Continue()}
;         ]
;         ; theme: {bg:"1E1E1E", btn:"2D2D30", btnHover:"094771", ...}  ; 省略可
;     })
;     panel.Toggle()   ; / .Show() / .Hide() / .IsVisible() / .SetOpacity(220) / .ShowSettings()
;
; パネルを右クリックするとコンテキストメニュー（設定… / 非表示 / 追加項目）が開く。
; 設定ダイアログ（透過度/文字サイズ/幅）の変更は即 INI に保存され次回も復元される。
; cfg.menuItems: [{text:"...", action:() => ...}] でメニュー項目を追加できる。
; ==============================================================================

#Requires AutoHotkey v2.0

class FloatingPanel {
    ; control/gui Hwnd -> インスタンス（OnMessage を正しいパネルへ振り分けるため）
    static _owner  := Map()
    static _hooked := false

    ; 既定テーマ（VS Dark 風）
    static DEFAULT_THEME := { bg:       "1E1E1E"
                            , header:   "808080"
                            , btn:      "2D2D30"
                            , btnHover: "094771"
                            , txt:      "CCCCCC"
                            , txtHover: "FFFFFF"
                            , border:   true }

    /**
     * cfg: { name, title, buttons[, iniPath, width, theme] }
     *   buttons: [{label, action[, color, bg, h]}]
     */
    __New(cfg) {
        this.title     := cfg.HasOwnProp("title")     ? cfg.title     : "Panel"
        this.name      := cfg.HasOwnProp("name")      ? cfg.name      : "panel"
        this.iniPath   := cfg.HasOwnProp("iniPath")   ? cfg.iniPath   : ""
        this.width     := cfg.HasOwnProp("width")     ? cfg.width     : 166
        this.fontSize  := cfg.HasOwnProp("fontSize")  ? cfg.fontSize  : 10   ; ボタン文字サイズ（実質スケール）
        this.btnHeight := cfg.HasOwnProp("btnHeight") ? cfg.btnHeight : 30   ; 既定ボタン高（個別 h で上書き可）
        this.opacity   := cfg.HasOwnProp("opacity")   ? cfg.opacity   : 255  ; 0-255（255=不透明）
        this.buttons   := cfg.buttons
        this.menuItems := cfg.HasOwnProp("menuItems") ? cfg.menuItems : []  ; 右クリックメニューの追加項目 [{text, action}]
        this.onVisible := cfg.HasOwnProp("onVisible") ? cfg.onVisible : ""  ; 表示状態変化のコールバック (visible:bool)
        this.theme     := this._MergeTheme(cfg.HasOwnProp("theme") ? cfg.theme : {})
        this.gui         := ""
        this.hdrHwnd     := 0
        this.btns        := Map()
        this.hoverHwnd   := 0
        this.settingsGui := ""
        this._loaded     := false                              ; INI 設定の初回読込済みフラグ
        this._rebuildTimer := ObjBindMethod(this, "_Rebuild")  ; サイズ変更のデバウンス用
    }

    _MergeTheme(o) {
        d := FloatingPanel.DEFAULT_THEME
        return { bg:       o.HasOwnProp("bg")       ? o.bg       : d.bg
               , header:   o.HasOwnProp("header")   ? o.header   : d.header
               , btn:      o.HasOwnProp("btn")      ? o.btn      : d.btn
               , btnHover: o.HasOwnProp("btnHover") ? o.btnHover : d.btnHover
               , txt:      o.HasOwnProp("txt")      ? o.txt      : d.txt
               , txtHover: o.HasOwnProp("txtHover") ? o.txtHover : d.txtHover
               , border:   o.HasOwnProp("border")   ? o.border   : d.border }
    }

    ; --- 公開 API ---

    IsVisible() => (this.gui != "" && DllCall("IsWindowVisible", "Ptr", this.gui.Hwnd))

    Toggle() => this.IsVisible() ? this.Hide() : this.Show()

    Show() {
        if (this.gui == "") {
            this._LoadSettings()   ; INI に保存済みのサイズ/透過度があれば反映してから構築
            this._Build()
        }
        x := this._LoadPos("X", A_ScreenWidth - 200)
        y := this._LoadPos("Y", A_ScreenHeight // 3)
        this.gui.Show("NoActivate x" . x . " y" . y)
        this._ApplyOpacity()
        this._FireVisible(true)
    }

    Hide() {
        if (this.gui != "") {
            this._SavePos()
            this.gui.Hide()
            this._FireVisible(false)
        }
    }

    _FireVisible(visible) {
        if (this.onVisible)
            this.onVisible.Call(visible)
    }

    /**
     * 透過度を実行時に変更する（0-255、255=不透明）
     */
    SetOpacity(val) {
        this.opacity := val
        this._ApplyOpacity()
    }

    _ApplyOpacity() {
        if (this.gui == "")
            return
        WinSetTransparent((this.opacity < 255) ? this.opacity : "Off", this.gui)
    }

    ; --- 設定（サイズ/透過度）の GUI とライブ反映・永続化 ---

    /**
     * 設定ダイアログを開く（ヘッダー右クリックからも開く）
     * スライダーでライブ調整 → 即 INI 保存
     */
    ShowSettings() {
        if (this.settingsGui != "") {
            try this.settingsGui.Show()
            return
        }
        this._LoadSettings()  ; パネル未表示でも保存値をスライダー初期値に反映
        sg := Gui("+AlwaysOnTop +ToolWindow", this.title . " 設定")
        sg.OnEvent("Close", (*) => this._OnSettingsClose())
        sg.SetFont("s9", "Segoe UI")
        sg.AddText("xm y+8 w70", "透過度")
        sOp := sg.AddSlider("x+10 yp-3 w190 Range80-255 ToolTip", this.opacity)
        sOp.OnEvent("Change", (*) => this._ApplySetting("opacity", sOp.Value))
        sg.AddText("xm w70", "文字サイズ")
        sFs := sg.AddSlider("x+10 yp-3 w190 Range8-18 ToolTip", this.fontSize)
        sFs.OnEvent("Change", (*) => this._ApplySetting("fontSize", sFs.Value))
        sg.AddText("xm w70", "幅")
        sW := sg.AddSlider("x+10 yp-3 w190 Range120-320 ToolTip", this.width)
        sW.OnEvent("Change", (*) => this._ApplySetting("width", sW.Value))
        sg.AddButton("xm y+12 w270", "閉じる").OnEvent("Click", (*) => this._OnSettingsClose())
        this.settingsGui := sg
        this._PositionSettings(sg)
    }

    ; 設定ダイアログをパネルの位置に重ねて出す（パネル座標基準で必ず同じモニタに出る）
    _PositionSettings(sg) {
        if (this.gui == "" || !this.IsVisible()) {
            sg.Show()  ; パネル非表示時は既定位置
            return
        }
        this.gui.GetPos(&px, &py)
        sg.Show("x" . px . " y" . py)
    }

    _OnSettingsClose() {
        if (this.settingsGui != "") {
            try this.settingsGui.Destroy()
            this.settingsGui := ""
        }
    }

    ; スライダー変更の反映: 透過度は即時、サイズ/幅はデバウンスして作り直し
    _ApplySetting(key, val) {
        this.%key% := val
        if (key = "opacity") {
            this._SaveSetting("Opacity", val)
            this._ApplyOpacity()
            return
        }
        this._SaveSetting((key = "fontSize") ? "FontSize" : "Width", val)
        SetTimer(this._rebuildTimer, -180)  ; ドラッグ確定後に1回だけ再構築
    }

    _LoadSettings() {
        if (this.iniPath = "" || this._loaded)
            return
        this._loaded := true
        sec := "Panel_" . this.name
        this.fontSize := Integer(IniRead(this.iniPath, sec, "FontSize", this.fontSize))
        this.width    := Integer(IniRead(this.iniPath, sec, "Width",    this.width))
        this.opacity  := Integer(IniRead(this.iniPath, sec, "Opacity",  this.opacity))
    }

    _SaveSetting(key, val) {
        if (this.iniPath = "")
            return
        try IniWrite(val, this.iniPath, "Panel_" . this.name, key)
    }

    ; サイズ/幅変更を反映するため、位置・表示状態を保って作り直す
    _Rebuild() {
        if (this.gui == "")
            return
        wasVisible := this.IsVisible()
        this.gui.GetPos(&x, &y)
        this._Destroy()
        this._Build()
        if (wasVisible) {
            this.gui.Show("NoActivate x" . x . " y" . y)
            this._ApplyOpacity()
        }
    }

    _Destroy() {
        for h, inst in FloatingPanel._owner.Clone()
            if (inst == this)
                FloatingPanel._owner.Delete(h)
        this.btns      := Map()
        this.hoverHwnd := 0
        try this.gui.Destroy()
        this.gui     := ""
        this.hdrHwnd := 0
    }

    ; --- 構築 ---

    _Build() {
        t   := this.theme
        opt := "-Caption +ToolWindow +AlwaysOnTop +E0x08000000" . (t.border ? " +Border" : "")
        g := Gui(opt)
        g.BackColor := t.bg
        g.MarginX := 5
        g.MarginY := 4
        ; ヘッダー（ドラッグ用。SS_NOTIFY=0x100 でクリック受領、SS_CENTERIMAGE=0x200 で縦中央）
        headerH := this.fontSize + 8
        g.SetFont("s" . (this.fontSize - 2), "Segoe UI")
        hdr := g.AddText(Format("w{1} h{2} +0x100 +0x200 Center c{3} Background{4}", this.width, headerH, t.header, t.bg), "≡  " . this.title)
        ; ボタン（Win32 標準を避け Text コントロールで自作 → 暗色フラット & 色自由）
        g.SetFont("s" . this.fontSize, "Segoe UI")
        this.btns := Map()
        for b in this.buttons {
            h   := b.HasOwnProp("h")     ? b.h     : this.btnHeight
            bg  := b.HasOwnProp("bg")    ? b.bg    : t.btn
            txt := b.HasOwnProp("color") ? b.color : t.txt
            ctrl := g.AddText(Format("xm w{1} h{2} +0x100 +0x200 Center Background{3} c{4}", this.width, h, bg, txt), b.label)
            ctrl.OnEvent("Click", this._MakeClick(b.action))
            this.btns[ctrl.Hwnd] := { ctrl: ctrl, bg: bg, txt: txt, hbg: t.btnHover, htxt: t.txtHover }
            FloatingPanel._owner[ctrl.Hwnd] := this
        }
        this.gui     := g
        this.hdrHwnd := hdr.Hwnd
        FloatingPanel._owner[hdr.Hwnd] := this
        FloatingPanel._owner[g.Hwnd]   := this
        FloatingPanel._EnsureHooks()
    }

    ; ボタン押下コールバックを別スコープで生成（ループ内クロージャの取り違え防止）
    _MakeClick(action) => (*) => action()

    ; --- 位置の保存／復元 ---

    _LoadPos(key, def) {
        if (this.iniPath = "")
            return def
        return Integer(IniRead(this.iniPath, "Panel_" . this.name, key, def))
    }

    _SavePos() {
        if (this.iniPath = "" || this.gui == "")
            return
        try {
            this.gui.GetPos(&px, &py)
            IniWrite(px, this.iniPath, "Panel_" . this.name, "X")
            IniWrite(py, this.iniPath, "Panel_" . this.name, "Y")
        }
    }

    ; --- ホバー着色 ---

    _SetBtnColors(info, bg, txt) {
        info.ctrl.Opt("Background" . bg . " c" . txt)
        DllCall("InvalidateRect", "Ptr", info.ctrl.Hwnd, "Ptr", 0, "Int", 1)
    }

    _ResetHover() {
        if (this.hoverHwnd && this.btns.Has(this.hoverHwnd)) {
            info := this.btns[this.hoverHwnd]
            this._SetBtnColors(info, info.bg, info.txt)
        }
        this.hoverHwnd := 0
    }

    _HandleMouseMove(hwnd) {
        if (!this.btns.Has(hwnd)) {
            this._ResetHover()
            return
        }
        if (this.hoverHwnd = hwnd)
            return
        this._ResetHover()
        info := this.btns[hwnd]
        this._SetBtnColors(info, info.hbg, info.htxt)
        this.hoverHwnd := hwnd
        this._TrackLeave(hwnd)
    }

    _HandleMouseLeave(hwnd) {
        if (this.btns.Has(hwnd)) {
            info := this.btns[hwnd]
            this._SetBtnColors(info, info.bg, info.txt)
            if (this.hoverHwnd = hwnd)
                this.hoverHwnd := 0
        }
    }

    ; WM_MOUSELEAVE を発生させるため TrackMouseEvent を登録
    _TrackLeave(hwnd) {
        size := (A_PtrSize = 8) ? 24 : 16
        tme  := Buffer(size, 0)
        NumPut("UInt", size, tme, 0)
        NumPut("UInt", 0x2, tme, 4)   ; TME_LEAVE
        NumPut("Ptr", hwnd, tme, 8)
        DllCall("TrackMouseEvent", "Ptr", tme)
    }

    ; --- ドラッグ移動 ---

    _HandleLButton(hwnd) {
        if (hwnd != this.hdrHwnd)
            return
        PostMessage(0xA1, 2, 0, , "ahk_id " . this.gui.Hwnd)  ; WM_NCLBUTTONDOWN, HTCAPTION
        return 0
    }

    _HandleMoveEnd(hwnd) {
        if (hwnd = this.gui.Hwnd)
            this._SavePos()
    }

    ; パネル右クリックでコンテキストメニューを表示
    _HandleRButton(hwnd) {
        this._ShowContextMenu()
    }

    _ShowContextMenu() {
        m := Menu()
        m.Add("設定…(&S)", (*) => this.ShowSettings())
        if (this.menuItems.Length) {
            m.Add()  ; 区切り線
            for it in this.menuItems
                m.Add(it.text, this._MakeClick(it.action))
        }
        m.Add()  ; 区切り線
        m.Add("非表示(&H)", (*) => this.Hide())
        m.Show()
    }

    ; --- メッセージフック（全パネル共有。Hwnd からインスタンスへ振り分け）---

    static _EnsureHooks() {
        if (FloatingPanel._hooked)
            return
        OnMessage(0x0200, (w, l, m, h) => FloatingPanel._Dispatch("_HandleMouseMove",  h))  ; WM_MOUSEMOVE
        OnMessage(0x02A3, (w, l, m, h) => FloatingPanel._Dispatch("_HandleMouseLeave", h))  ; WM_MOUSELEAVE
        OnMessage(0x0232, (w, l, m, h) => FloatingPanel._Dispatch("_HandleMoveEnd",    h))  ; WM_EXITSIZEMOVE
        OnMessage(0x0204, (w, l, m, h) => FloatingPanel._Dispatch("_HandleRButton",    h))  ; WM_RBUTTONDOWN
        OnMessage(0x0201, (w, l, m, h) => FloatingPanel._DispatchRet("_HandleLButton", h))  ; WM_LBUTTONDOWN
        FloatingPanel._hooked := true
    }

    static _Dispatch(method, hwnd) {
        if (FloatingPanel._owner.Has(hwnd))
            FloatingPanel._owner[hwnd].%method%(hwnd)
    }

    static _DispatchRet(method, hwnd) {
        if (FloatingPanel._owner.Has(hwnd))
            return FloatingPanel._owner[hwnd].%method%(hwnd)
    }
}
