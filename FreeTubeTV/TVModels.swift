import Foundation

struct TVVideo: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let channel: String
    let thumbnailURL: URL?
    let duration: String
}

struct TVPlaybackSource: Sendable {
    let videoURL: URL
    let audioURL: URL?
}

enum TVRegionProfile: String, CaseIterable, Identifiable, Sendable {
    case chinaChinese = "zh-CN"
    case northAmerica = "en-US"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chinaChinese: return "中国 / 中文"
        case .northAmerica: return "北美 / English"
        }
    }

    var discoveryQuery: String {
        switch self {
        case .chinaChinese: return "中文 热门 视频"
        case .northAmerica: return "US trending videos"
        }
    }
}

enum TVCatalogError: LocalizedError, Equatable {
    case emptyQuery
    case noPlayableStream
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .emptyQuery: return "Enter a search term."
        case .noPlayableStream: return "This video has no playable stream."
        case .requestFailed: return "Unable to load YouTube right now. Check your network and try again."
        }
    }
}
