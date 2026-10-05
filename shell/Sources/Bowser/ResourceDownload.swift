import AppKit
import WebKit
import UniformTypeIdentifiers

/// Main-frame file responses and unambiguous PDF data frames identify saved resources.
struct ResourceDownload: Equatable {
    let url: URL
    let mimeType: String
    var contentType: UTType? { UTType(mimeType: mimeType) }

    /// Some document portals return an HTML wrapper containing the original PDF
    /// as a data URL. Only expose an unambiguous, single PDF resource.
    static let embeddedPDFScript = """
    (() => {
        const sources = Array.from(document.querySelectorAll('iframe,embed,object'))
            .map(e => e.getAttribute(e.tagName === 'OBJECT' ? 'data' : 'src') || '')
            .filter(s => /^data:application\\/pdf[;,]/i.test(s));
        return sources.length === 1 ? sources[0] : null;
    })()
    """

    init?(embeddedURL: String) {
        let prefix = embeddedURL.prefix(21).lowercased()
        guard prefix.hasPrefix("data:application/pdf;") || prefix.hasPrefix("data:application/pdf,"),
              let url = URL(string: embeddedURL), url.scheme == "data" else { return nil }
        self.url = url
        mimeType = "application/pdf"
    }

    init?(response: URLResponse) {
        guard Self.isDownloadable(response), let url = response.url,
              let mime = Self.normalizedMIME(response) else { return nil }
        self.url = url
        mimeType = mime
    }

    static func normalizedMIME(_ response: URLResponse) -> String? {
        response.mimeType?.lowercased().split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces)
    }

    static func isDownloadable(_ response: URLResponse) -> Bool {
        guard let mime = normalizedMIME(response), !mime.isEmpty,
              !["text/html", "application/xhtml+xml"].contains(mime) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return (200..<300).contains(status)
    }

    func accepts(_ response: URLResponse) -> Bool {
        guard Self.isDownloadable(response), let actual = Self.normalizedMIME(response) else { return false }
        if actual == mimeType { return true }
        if actual == "application/octet-stream" { return true }
        return contentType != nil && UTType(mimeType: actual) == contentType
    }

    func filename(_ suggested: String) -> String {
        let safe = NativeDownloads.safeFilename(suggested)
        let ext = (safe as NSString).pathExtension.lowercased()
        if mimeType == "application/pdf" { return ext == "pdf" ? safe : safe + ".pdf" }
        guard ext.isEmpty, let preferred = contentType?.preferredFilenameExtension else { return safe }
        return safe + "." + preferred
    }

    func validateFile(_ url: URL) throws {
        guard mimeType == "application/pdf" else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 5) == Data("%PDF-".utf8) else {
            throw NSError(domain: "BowserDownload", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The website did not return a PDF. Your session may have expired; sign in and try again."])
        }
    }
}
