#Requires AutoHotkey v2.0
; ==============================================================================
; Module:      Navi.Mark.ahk
; Description: Navi マーク / マークフィルター機能モジュール
;              - ノードのマーク・マーク解除（Alt+M）
;              - マーク済みノードのみ表示するマークフィルタービュー（Ctrl+M）
;              - 全マーククリア（Alt+Shift+M）
;              - カスタムドロー用マークノード ID セット管理
; Usage:       NaviMark.Init(naviRef) を Navi.Init() から呼び出す
; ==============================================================================

class NaviMark {
    static _navi := ""

    ; --- 状態 ---
    static _MarkedPaths    := Map()   ; マーク済みパス集合（小文字キー→元パス）
    static _MarkedIdSet    := Map()   ; マークノードID集合（カスタムドロー用）
    static _MarkFilterActive := false ; マークフィルタービュー中フラグ
    static _LastTreeRootPath := ""    ; 前回の _RefreshTree ルートパス（マーク初期化判定用）

    ; --- 定数 ---
    static MARK_COLOR := 0x0000AA00  ; マーク着色色 BGR: 緑

    static Init(naviRef) {
        this._navi := naviRef
    }

    ; ==============================================================================
    ; 状態リセット
    ; ==============================================================================

    /** マーク状態を全てリセットする（_DestroyGui / ReloadProfileInPlace から呼ぶ） */
    static Reset() {
        this._MarkedPaths      := Map()
        this._MarkedIdSet      := Map()
        this._MarkFilterActive := false
        this._LastTreeRootPath := ""
    }

    ; ==============================================================================
    ; マーク操作
    ; ==============================================================================

    /** 選択ノードのマーク状態をトグルする（Alt+M） */
    static _ToggleMark() {
        nv := this._navi
        if !(nv.GuiObj && WinExist(nv.GuiObj))
            return
        tv := nv.GuiObj["FolderTree"]
        selId := tv.GetSelection()
        if (!selId)
            return
        path := nv._GetTVFullPath(tv, selId)
        if (path == "")
            return
        key := StrLower(path)
        if (this._MarkedPaths.Has(key))
            this._MarkedPaths.Delete(key)
        else
            this._MarkedPaths[key] := path
        this._RebuildMarkedIdSet(tv)
        NaviFilter.EnsureFilterDraw(tv)
        DllCall("user32\InvalidateRect", "ptr", tv.Hwnd, "ptr", 0, "int", 1)
    }

    /** 全マークを解除し、マークフィルタービュー中であれば通常ビューへ戻す（Alt+Shift+M） */
    static _ClearAllMarks() {
        nv := this._navi
        if (this._MarkedPaths.Count == 0 || !(nv.GuiObj && WinExist(nv.GuiObj)))
            return
        this._MarkedPaths := Map()
        tv := nv.GuiObj["FolderTree"]
        rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
        if (this._MarkFilterActive && rootPath != "") {
            ; マークフィルタービューを終了して元のビューへ戻す
            this._MarkFilterActive := false
            query := Trim(nv.GuiObj["TreeFilter"].Value)
            if (query != "")
                NaviFilter.ApplyTreeFilter(query)
            else
                nv._RefreshTree(tv, rootPath, false)
        } else {
            this._MarkedIdSet := Map()
            DllCall("user32\InvalidateRect", "ptr", tv.Hwnd, "ptr", 0, "int", 1)
        }
        nv._UpdateStatusBar()
    }

    /** マークフィルタービューのオン/オフをトグルする（Ctrl+M） */
    static _ToggleMarkFilter() {
        nv := this._navi
        if (this._MarkedPaths.Count == 0 || !(nv.GuiObj && WinExist(nv.GuiObj)))
            return
        tv := nv.GuiObj["FolderTree"]
        rootPath := nv._FolderMap.Has(nv.lastRoot) ? nv._FolderMap[nv.lastRoot] : ""
        if (rootPath == "")
            return
        if (this._MarkFilterActive) {
            this._MarkFilterActive := false
            query := Trim(nv.GuiObj["TreeFilter"].Value)
            if (query != "") {
                ; フォルダフィルタービューへ戻す（ApplyTreeFilter 内でマーク色も復元）
                NaviFilter.ApplyTreeFilter(query)
            } else {
                ; 全体ツリーへ戻してマーク色を復元（_RefreshTree 内でマーク ID も再構築される）
                nv._RefreshTree(tv, rootPath, false)
                NaviFilter.EnsureFilterDraw(tv)
                DllCall("user32\InvalidateRect", "ptr", tv.Hwnd, "ptr", 0, "int", 1)
            }
            nv._UpdateStatusBar()
        } else {
            this._MarkFilterActive := true
            this._ApplyMarkFilter(tv, rootPath)
        }
    }

    ; ==============================================================================
    ; マークフィルタービュー構築
    ; ==============================================================================

    /**
     * マーク済みパスのみをツリーに表示するフィルタービューを構築する
     * マークノードは太字、中間親ノードは通常表示で展開される。
     */
    static _ApplyMarkFilter(tv, rootPath) {
        nv := this._navi
        tv.Delete()
        nv.FilesShown := Map()
        NaviFilter._FilterMatchIdSet := Map()
        this._MarkedIdSet := Map()
        NaviSearch._HighlightedIdSet := Map()

        rootBase := RTrim(rootPath, "\")
        rootID := tv.Add(rootPath, 0, "Expand Icon1")
        addedPaths := Map()
        addedPaths[StrLower(rootBase)] := rootID

        firstMark := true
        for key, markedPath in this._MarkedPaths {
            rel := SubStr(markedPath, StrLen(rootBase) + 2)
            parts := StrSplit(rel, "\")
            parentID := rootID
            currentPath := rootBase
            for i, part in parts {
                currentPath .= "\" . part
                pathKey := StrLower(currentPath)
                isMatch := (i == parts.Length)
                if addedPaths.Has(pathKey) {
                    existingID := addedPaths[pathKey]
                    if (isMatch)
                        this._MarkedIdSet[existingID] := true
                    parentID := existingID
                } else {
                    opts := isMatch ? "Bold" : ""
                    if (isMatch && firstMark) {
                        opts .= " Select"
                        firstMark := false
                    }
                    isDir := DirExist(currentPath) != ""
                    iconStr := isDir ? "Icon1" : nv._GetFileIconStr(part)
                    nodeID := tv.Add(part, parentID, opts . " " . iconStr)
                    if (isMatch)
                        this._MarkedIdSet[nodeID] := true
                    addedPaths[pathKey] := nodeID
                    parentID := nodeID
                    ; マークフォルダの子を読み込み手動展開できるようにする
                    if (isMatch && isDir) {
                        nv._LoadSub(tv, currentPath, nodeID)
                        nv._ShowFilesIfEnabled(tv, nodeID, currentPath)
                    }
                }
            }
        }

        ; 中間親ノードのみ展開（マークノード自体は折り畳み状態を維持）
        for pathKey, nodeID in addedPaths {
            if (nodeID != rootID && !this._MarkedIdSet.Has(nodeID) && tv.GetChild(nodeID) != 0)
                tv.Modify(nodeID, "Expand")
        }

        NaviFilter.EnsureFilterDraw(tv)
        nv._UpdateStatusBar()
    }

    ; ==============================================================================
    ; マークノード ID 管理
    ; ==============================================================================

    /**
     * TreeView の全ノードを走査してマーク済みノードの ID セットを再構築する
     * ツリー再構築後（_RefreshTree / _ApplyTabState）に呼ぶ。
     */
    static _RebuildMarkedIdSet(tv) {
        nv := this._navi
        this._MarkedIdSet := Map()
        if (this._MarkedPaths.Count == 0)
            return
        nodeId := tv.GetNext(0, "Full")  ; "Full" = ツリー全体をDFS順に走査
        while (nodeId) {
            path := nv._GetTVFullPath(tv, nodeId)
            if (this._MarkedPaths.Has(StrLower(path)))
                this._MarkedIdSet[nodeId] := true
            nodeId := tv.GetNext(nodeId, "Full")
        }
    }
}
