; ==============================================================================
; Module:       PlaceholderEngine.ahk
; Description:  スニペット・ホットストリング共通のプレースホルダー置換エンジン
;
; 使えるプレースホルダー:
;   {{clip}}     クリップボードの内容
;   yyyy/mm/dd   今日の日付 (例: 2025/04/29)
;   yyyy/mm      今月      (例: 2025/04)
;   yyyymm       今月      (例: 202504)
;   yy/mm/dd     今日の日付 (例: 25/04/29)
;   yy/mm        今月      (例: 25/04)
;   yymmdd       今日の日付 (例: 250429)
;   yymm         今月      (例: 2504)
;   HH:mm        現在時刻  (例: 09:30)
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

        return text
    }
}
