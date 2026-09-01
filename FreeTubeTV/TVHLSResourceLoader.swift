import AVFoundation
import Foundation

/// Proxies YouTube HLS manifests and segments with one consistent User-Agent. YouTube's CDN can
/// reject AVPlayer's default segment requests when the manifest was signed for another client.
final class TVHLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    nonisolated static let scheme = "freetubehls"

    private let userAgent: String
    private let session: URLSession

    init(userAgent: String = "Mozilla/5.0 (AppleTV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15") {
        self.userAgent = userAgent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        super.init()
    }

    nonisolated static func rewrite(_ url: URL) -> URL? {
        let absolute = url.absoluteString
        if absolute.hasPrefix("https://") {
            return URL(string: "\(scheme)+https://" + absolute.dropFirst("https://".count))
        }
        if absolute.hasPrefix("http://") {
            return URL(string: "\(scheme)+http://" + absolute.dropFirst("http://".count))
        }
        return nil
    }

    private nonisolated static func restore(_ url: URL) -> URL? {
        let absolute = url.absoluteString
        let httpsPrefix = "\(scheme)+https://"
        let httpPrefix = "\(scheme)+http://"
        if absolute.hasPrefix(httpsPrefix) {
            return URL(string: "https://" + absolute.dropFirst(httpsPrefix.count))
        }
        if absolute.hasPrefix(httpPrefix) {
            return URL(string: "http://" + absolute.dropFirst(httpPrefix.count))
        }
        return nil
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard
            let requestedURL = loadingRequest.request.url,
            requestedURL.scheme?.hasPrefix(Self.scheme) == true,
            let realURL = Self.restore(requestedURL)
        else { return false }

        Task { await load(loadingRequest, from: realURL) }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {}

    private func load(_ loadingRequest: AVAssetResourceLoadingRequest, from url: URL) async {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let dataRequest = loadingRequest.dataRequest {
            let offset = dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            } else {
                let length = max(dataRequest.requestedLength, 1)
                request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return
            }
            let isPlaylist = url.path.hasSuffix(".m3u8") || (http.mimeType ?? "").contains("mpegurl")
            let output = isPlaylist ? rewriteManifest(data) : data
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = http.mimeType ?? (isPlaylist ? "application/x-mpegURL" : "video/mp4")
                info.isByteRangeAccessSupported = !isPlaylist
                info.contentLength = Int64(output.count)
            }
            loadingRequest.dataRequest?.respond(with: output)
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }

    private func rewriteManifest(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let rewritten = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let value = String(line)
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"), let url = URL(string: trimmed) {
                return Self.rewrite(url)?.absoluteString ?? value
            }
            guard trimmed.hasPrefix("#"), trimmed.contains("URI=\"") else { return value }
            return rewriteURIAttributes(in: value)
        }.joined(separator: "\n")
        return rewritten.data(using: .utf8) ?? data
    }

    private func rewriteURIAttributes(in line: String) -> String {
        var result = ""
        var remainder = Substring(line)
        while let marker = remainder.range(of: "URI=\"") {
            result += remainder[..<marker.upperBound]
            remainder = remainder[marker.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else {
                result += remainder
                return result
            }
            let rawURL = String(remainder[..<end])
            result += (URL(string: rawURL).flatMap(Self.rewrite)?.absoluteString ?? rawURL)
            remainder = remainder[end...]
        }
        result += remainder
        return result
    }
}
