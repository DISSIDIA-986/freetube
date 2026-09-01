import Foundation

enum TVChannelVideoSorter {
    /// Sorts a channel's videos newest-first while preserving the server order for
    /// items whose localized relative date cannot be interpreted.
    static func newestFirst(_ videos: [TVVideo]) -> [TVVideo] {
        videos.enumerated().sorted { lhs, rhs in
            let leftAge = relativeAge(lhs.element.publishedRelative)
            let rightAge = relativeAge(rhs.element.publishedRelative)

            switch (leftAge, rightAge) {
            case let (left?, right?):
                return left == right ? lhs.offset < rhs.offset : left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Returns an approximate age in seconds. The source is intentionally
    /// localized, so support the English and Chinese labels used by the app.
    static func relativeAge(_ value: String?) -> Int? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if ["just now", "now", "刚刚", "刚才"].contains(text) { return 0 }
        if ["today", "今天"].contains(text) { return 0 }
        if ["yesterday", "昨天"].contains(text) { return 86_400 }

        let numberPattern = #"(\d+(?:\.\d+)?)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?|months?|years?|秒钟?|分钟?|小时?|天|周|个月|年)"#
        guard let match = text.range(of: numberPattern, options: .regularExpression) else { return nil }
        let token = String(text[match])
        guard let numberMatch = token.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression),
              let number = Double(token[numberMatch]) else { return nil }

        let unit = token[numberMatch.upperBound...].trimmingCharacters(in: .whitespaces)
        let seconds: Double
        switch unit {
        case "s", "sec", "secs", "second", "seconds", "秒", "秒钟": seconds = number
        case "m", "min", "mins", "minute", "minutes", "分钟": seconds = number * 60
        case "h", "hr", "hrs", "hour", "hours", "小时": seconds = number * 3_600
        case "d", "day", "days", "天": seconds = number * 86_400
        case "w", "week", "weeks", "周": seconds = number * 604_800
        case "mo", "month", "months", "个月": seconds = number * 2_629_800
        case "y", "yr", "yrs", "year", "years", "年": seconds = number * 31_557_600
        default: return nil
        }
        return min(Int.max, max(0, Int(seconds.rounded())))
    }
}
