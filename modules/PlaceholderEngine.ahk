; ==============================================================================
; Module:       PlaceholderEngine.ahk
; Description:  スニペット・ホットストリング共通のプレースホルダー置換エンジン
;
; 使えるプレースホルダー:
;   {{clip}}     クリップボードの内容
;   {{cursor}}   挿入後のカーソル位置を指定（テキストから除去され、そこにカーソルが置かれる）
;   yyyy/mm/dd   今日の日付 (例: 2025/04/29)
;   yyyy/mm      今月      (例: 2025/04)
;   yyyymm       今月      (例: 202504)
;   yy/mm/dd     今日の日付 (例: 25/04/29)
;   yy/mm        今月      (例: 25/04)
;   yymmdd       今日の日付 (例: 250429)
;   yymm         今月      (例: 2504)
;   HH:mm        現在時刻  (例: 09:30)
;
; 戻り値: {text: String, cursorOffset: Integer}
;   cursorOffset > 0 の場合、貼り付け後に Left キーをその回数送る
; ==============================================================================
#Requires AutoHotkey v2.0

class PlaceholderEngine {
    static Apply(text) {
        ; {{clip}} — 表記ゆれ ({clip}}, {{clip}, {clip}) も吸収
        text := RegExReplace(text, "\{{1,2}\s*clip\s*\}{1,2}", A_Clipboard)

        ; 長いパターンを先に置換して部分マッチを防ぐ
        text := StrReplace(text, "yyyy/mm/dd", FormatTime(, "yyyy/MM/dd"))
        text := StrReplace(text, "yyyy/mm",    FormatTime(, "yyyy/MM"))
        text := StrReplace(text, "yyyymm",     FormatTime(, "yyyyMM"))
        text := StrReplace(text, "yy/mm/dd",   FormatTime(, "yy/MM/dd"))
        text := StrReplace(text, "yy/mm",      FormatTime(, "yy/MM"))
        text := StrReplace(text, "yymmdd",     FormatTime(, "yyMMdd"))
        text := StrReplace(text, "yymm",       FormatTime(, "yyMM"))
        text := StrReplace(text, "HH:mm",      FormatTime(, "HH:mm"))

        ; {{cursor}} — 除去してカーソルオフセットを計算
        ; \r\n を 1 文字として扱う（{Left} は改行を1ポジションとして移動するため）
        cursorOffset := 0
        cursorPos := InStr(text, "{{cursor}}")
        if (cursorPos) {
            afterCursor := SubStr(text, cursorPos + StrLen("{{cursor}}"))
            cursorOffset := StrLen(StrReplace(afterCursor, "`r", ""))
            text := StrReplace(text, "{{cursor}}", "")
        }

        return {text: text, cursorOffset: cursorOffset}
    }

    ; {{N:ラベル}} パターンを検出し、ユニークなフィールド定義を返す
    ; 戻り値: [{index, label}] — index 昇順、同一 index は初出のみ
    static ParseFillIns(text) {
        seen   := Map()
        result := []
        pos    := 1
        while (pos := RegExMatch(text, "\{\{(\d+):([^}]*)\}\}", &m, pos)) {
            idx := Integer(m[1])
            if !seen.Has(idx) {
                seen[idx] := true
                result.Push({index: idx, label: m[2]})
            }
            pos += m.Len
        }
        ; index 昇順にソート（バブルソート）
        loop result.Length - 1 {
            loop result.Length - 1 {
                if (result[A_Index].index > result[A_Index + 1].index) {
                    tmp := result[A_Index]
                    result[A_Index] := result[A_Index + 1]
                    result[A_Index + 1] := tmp
                }
            }
        }
        return result
    }

    ; ParseFillIns の結果と入力値 Map(index -> value) でテキストを置換
    static ApplyFillIns(text, values) {
        for idx, val in values
            text := RegExReplace(text, "\{\{" idx ":([^}]*)\}\}", val)
        return text
    }
}
