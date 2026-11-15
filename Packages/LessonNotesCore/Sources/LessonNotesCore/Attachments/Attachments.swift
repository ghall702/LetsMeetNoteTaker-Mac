import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// What a lesson file is, so OpenAI can treat it correctly. Never sent to the website.
public enum AttachmentRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case slides, studentWork, exemplar, other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .slides: return "Slides"
        case .studentWork: return "Student work"
        case .exemplar: return "My work (exemplar)"
        case .other: return "Other material"
        }
    }
    public var systemImage: String {
        switch self {
        case .slides: return "rectangle.on.rectangle"
        case .studentWork: return "person.crop.square"
        case .exemplar: return "star.square"
        case .other: return "doc"
        }
    }
    /// How the file is described to OpenAI.
    public var openAIDescription: String {
        switch self {
        case .slides: return "the tutor's lesson slides used during this lesson"
        case .studentWork: return "work produced by the pupil (student-produced, may contain the pupil's own errors)"
        case .exemplar: return "exemplar modelling material written by the tutor (a model of what good work looks like)"
        case .other: return "lesson material provided by the tutor"
        }
    }
}

/// A file attached to a lesson. The bytes are copied into the app's own storage, so the
/// upload (and any retry) always sends exactly the same file.
public struct LessonAttachment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var filename: String
    public var byteCount: Int
    public var sha256: String
    public var role: AttachmentRole
    /// When false the file is only uploaded for the pupil; OpenAI never sees it.
    public var includeInContext: Bool
    /// Whether the file is uploaded to LetsMeet for the pupil to download.
    public var shareWithPupil: Bool
    public var addedAt: Date

    public init(id: UUID = UUID(), filename: String, byteCount: Int, sha256: String, role: AttachmentRole = .other,
                includeInContext: Bool = true, shareWithPupil: Bool = true, addedAt: Date = Date()) {
        self.id = id
        self.includeInContext = includeInContext
        self.shareWithPupil = shareWithPupil
        self.filename = filename
        self.byteCount = byteCount
        self.sha256 = sha256
        self.role = role
        self.addedAt = addedAt
    }

    enum CodingKeys: String, CodingKey { case id, filename, byteCount, sha256, role, includeInContext, shareWithPupil, contextOnly, addedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(String.self, forKey: .filename)
        byteCount = try c.decode(Int.self, forKey: .byteCount)
        sha256 = try c.decode(String.self, forKey: .sha256)
        role = (try? c.decodeIfPresent(AttachmentRole.self, forKey: .role)) ?? .other
        includeInContext = try c.decodeIfPresent(Bool.self, forKey: .includeInContext) ?? true
        if let share = try c.decodeIfPresent(Bool.self, forKey: .shareWithPupil) { shareWithPupil = share }
        else { shareWithPupil = !(try c.decodeIfPresent(Bool.self, forKey: .contextOnly) ?? false) }
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(timeIntervalSince1970: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(filename, forKey: .filename)
        try c.encode(byteCount, forKey: .byteCount)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(role, forKey: .role)
        try c.encode(includeInContext, forKey: .includeInContext)
        try c.encode(shareWithPupil, forKey: .shareWithPupil)
        try c.encode(addedAt, forKey: .addedAt)
    }

    public var fileExtension: String { (filename as NSString).pathExtension.lowercased() }
    public var contentType: String { AttachmentRules.contentType(forExtension: fileExtension) }
}

/// Website rules for `file_uploads` (Lesson Notes API).
public enum AttachmentRules {
    public static let maxFiles = 5
    public static let maxFileBytes = 20_000_000
    public static let maxRequestBytes = 106_100_000
    public static let maxFilenameLength = 200

    public static let allowedExtensions: [String] = ["pdf", "docx", "doc", "txt", "csv", "pptx", "ppt", "xlsx", "xls", "png", "jpg", "jpeg", "webp"]

    public static func contentType(forExtension e: String) -> String {
        switch e.lowercased() {
        case "pdf": return "application/pdf"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "doc": return "application/msword"
        case "txt": return "text/plain"
        case "csv": return "text/csv"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "xls": return "application/vnd.ms-excel"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    public enum Problem: Error, Equatable, LocalizedError {
        case unsupportedType(String)
        case empty(String)
        case tooLarge(String, Int)
        case tooMany
        case badFilename(String)
        case requestTooLarge(Int)
        public var errorDescription: String? {
            switch self {
            case .unsupportedType(let n):
                return "“\(n)” can't be attached. Allowed: PDF, Word, PowerPoint, Excel, text, CSV and images (PNG, JPG, WebP). Audio and video are never uploaded."
            case .empty(let n): return "“\(n)” is empty."
            case .tooLarge(let n, let b): return "“\(n)” is \(b.formatted()) bytes; each file must be 20 MB (20,000,000 bytes) or smaller."
            case .tooMany: return "A lesson note can have at most \(AttachmentRules.maxFiles) files."
            case .badFilename(let n): return "“\(n)” has a name the website can't accept (1–200 characters, no slashes)."
            case .requestTooLarge(let b): return "The note and its files total \(b.formatted()) bytes, above the website's 106.1 MB limit. Remove a file."
            }
        }
    }

    public static func isValidFilename(_ n: String) -> Bool {
        guard (1...maxFilenameLength).contains(n.count) else { return false }
        return !n.unicodeScalars.contains { $0 == "/" || $0 == "\\" || CharacterSet.controlCharacters.contains($0) }
    }

    /// Makes a filename acceptable (slashes/control characters replaced, shortened keeping the extension).
    public static func sanitisedFilename(_ raw: String) -> String {
        var s = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            ($0 == "/" || $0 == "\\" || CharacterSet.controlCharacters.contains($0)) ? "-" : $0
        })).trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = "file" }
        if s.count > maxFilenameLength {
            let ext = (s as NSString).pathExtension
            let keep = maxFilenameLength - (ext.isEmpty ? 0 : ext.count + 1)
            s = String((s as NSString).deletingPathExtension.prefix(keep)) + (ext.isEmpty ? "" : "." + ext)
        }
        return s
    }

    /// PDFs are named "macOS Preview <name>.pdf" (George's convention); other types keep their name.
    public static let pdfPrefix = "macOS Preview "

    /// The name a newly added file is stored and uploaded under.
    public static func storedFilename(_ raw: String, pdfPreviewPrefix: Bool = true) -> String {
        var name = sanitisedFilename(raw)
        if pdfPreviewPrefix && (name as NSString).pathExtension.lowercased() == "pdf" && !name.hasPrefix(pdfPrefix) {
            name = sanitisedFilename(pdfPrefix + name)
        }
        return name
    }

    /// Checks one file before it is added.
    public static func check(filename: String, byteCount: Int) -> Problem? {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return .unsupportedType(filename) }
        guard isValidFilename(filename) else { return .badFilename(filename) }
        guard byteCount > 0 else { return .empty(filename) }
        guard byteCount <= maxFileBytes else { return .tooLarge(filename, byteCount) }
        return nil
    }

    /// Checks the whole set (count, each file, and the multipart request size).
    public static func check(_ files: [LessonAttachment], noteJSONBytes: Int) -> Problem? {
        if files.count > maxFiles { return .tooMany }
        for f in files { if let p = check(filename: f.filename, byteCount: f.byteCount) { return p } }
        let total = MultipartBody.estimatedSize(noteJSONBytes: noteJSONBytes, files: files.map { ($0.filename, $0.contentType, $0.byteCount) })
        if total > maxRequestBytes { return .requestTooLarge(total) }
        return nil
    }
}

/// A file as LetsMeet reports it (`files` in note responses).
public struct RemoteFile: Codable, Sendable, Equatable, Hashable {
    public var filename: String
    public var size: Int?
    public init(filename: String, size: Int?) { self.filename = filename; self.size = size }
}

/// A file part for a multipart `POST /notes`.
public struct UploadFile: Sendable, Equatable {
    public var filename: String
    public var contentType: String
    public var data: Data
    public init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

/// `multipart/form-data` with exactly one `note` JSON part and 0–5 `file_uploads` parts.
public enum MultipartBody {
    public static func makeBoundary() -> String { "LessonNotes-" + UUID().uuidString }

    static func header(_ s: String) -> Data { Data(s.utf8) }
    static func quoted(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    public static func build(noteJSON: Data, files: [UploadFile], boundary: String) -> Data {
        var body = Data()
        body.append(header("--\(boundary)\r\nContent-Disposition: form-data; name=\"note\"\r\nContent-Type: application/json; charset=utf-8\r\n\r\n"))
        body.append(noteJSON)
        body.append(header("\r\n"))
        for f in files {
            body.append(header("--\(boundary)\r\nContent-Disposition: form-data; name=\"file_uploads\"; filename=\"\(quoted(f.filename))\"\r\nContent-Type: \(f.contentType)\r\n\r\n"))
            body.append(f.data)
            body.append(header("\r\n"))
        }
        body.append(header("--\(boundary)--\r\n"))
        return body
    }

    /// Size of `build` without reading the files (boundary length matches `makeBoundary`).
    public static func estimatedSize(noteJSONBytes: Int, files: [(String, String, Int)]) -> Int {
        let b = makeBoundary()
        var n = header("--\(b)\r\nContent-Disposition: form-data; name=\"note\"\r\nContent-Type: application/json; charset=utf-8\r\n\r\n").count + noteJSONBytes + 2
        for (name, type, size) in files {
            n += header("--\(b)\r\nContent-Disposition: form-data; name=\"file_uploads\"; filename=\"\(quoted(name))\"\r\nContent-Type: \(type)\r\n\r\n").count + size + 2
        }
        return n + header("--\(b)--\r\n").count
    }
}

// MARK: - Context for OpenAI

/// A lesson file prepared for OpenAI: extracted text, or the image/PDF itself.
public struct ContextMaterial: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String, truncated: Bool)
        case image(mimeType: String, base64: String)
        case pdf(base64: String)
        /// The file could not be read (e.g. old .ppt/.xls); only its name and type are given.
        case unreadable
    }
    public var filename: String
    public var role: AttachmentRole
    public var content: Content
    public init(filename: String, role: AttachmentRole, content: Content) {
        self.filename = filename
        self.role = role
        self.content = content
    }

    public var label: String { "“\(filename)” — \(role.openAIDescription)" }
}

/// Reads lesson files for OpenAI. Plain text, CSV and Office Open XML (.docx/.pptx/.xlsx)
/// are read here as text; the app adds old Word .doc. PDFs and images are sent to OpenAI as
/// the file itself (PDF via `input_file`, images via `input_image`).
public struct MaterialLoader: Sendable {
    /// Characters of extracted text per file sent as context (the full file is still uploaded).
    public static let maxTextCharacters = 60_000
    public var legacyDocumentText: (@Sendable (URL) -> String?)?
    public var inflate: (@Sendable (Data, Int) -> Data?)?

    public init(legacyDocumentText: (@Sendable (URL) -> String?)? = nil,
                inflate: (@Sendable (Data, Int) -> Data?)? = ZipReader.defaultInflate) {
        self.legacyDocumentText = legacyDocumentText
        self.inflate = inflate
    }

    public func load(_ a: LessonAttachment, at url: URL) -> ContextMaterial {
        ContextMaterial(filename: a.filename, role: a.role, content: content(a, url))
    }

    func content(_ a: LessonAttachment, _ url: URL) -> ContextMaterial.Content {
        func text(_ s: String?) -> ContextMaterial.Content {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return .unreadable }
            if s.count > Self.maxTextCharacters { return .text(String(s.prefix(Self.maxTextCharacters)), truncated: true) }
            return .text(s, truncated: false)
        }
        switch a.fileExtension {
        case "txt", "csv":
            guard let d = try? Data(contentsOf: url) else { return .unreadable }
            return text(String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1))
        case "docx", "pptx", "xlsx":
            guard let d = try? Data(contentsOf: url) else { return .unreadable }
            return text(OfficeText.extract(d, kind: a.fileExtension, inflate: inflate))
        case "doc":
            return text(legacyDocumentText?(url))
        case "pdf":
            // PDFs go to OpenAI as the PDF itself, so it sees each page's text AND images
            // (diagrams, handwriting, scanned work), not just extracted text.
            guard let d = try? Data(contentsOf: url) else { return .unreadable }
            return .pdf(base64: d.base64EncodedString())
        case "png", "jpg", "jpeg", "webp":
            guard let d = try? Data(contentsOf: url) else { return .unreadable }
            return .image(mimeType: a.contentType, base64: d.base64EncodedString())
        default:
            return .unreadable
        }
    }
}

// MARK: - Office Open XML text

/// Minimal ZIP reader (central directory; stored and deflated entries).
public enum ZipReader {
    public static let defaultInflate: (@Sendable (Data, Int) -> Data?)? = {
        #if canImport(Compression)
        return { data, size in RawInflate.inflate(data, expectedSize: size) }
        #else
        return nil
        #endif
    }()

    public struct Entry { public var name: String; public var method: Int; public var compressedSize: Int; public var size: Int; public var localOffset: Int }

    static func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    static func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }

    public static func entries(_ d: Data) -> [Entry]? {
        guard d.count >= 22 else { return nil }
        var eocd = -1
        var i = d.count - 22
        let floor = max(0, d.count - 22 - 65_535)
        while i >= floor {
            if u32(d, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(d, eocd + 10)
        var p = u32(d, eocd + 16)
        var out: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x02014b50 else { return nil }
            let method = u16(d, p + 10), csize = u32(d, p + 20), size = u32(d, p + 24)
            let nlen = u16(d, p + 28), elen = u16(d, p + 30), clen = u16(d, p + 32), local = u32(d, p + 42)
            guard p + 46 + nlen <= d.count else { return nil }
            let name = String(decoding: d.subdata(in: (d.startIndex + p + 46)..<(d.startIndex + p + 46 + nlen)), as: UTF8.self)
            out.append(Entry(name: name, method: method, compressedSize: csize, size: size, localOffset: local))
            p += 46 + nlen + elen + clen
        }
        return out
    }

    public static func read(_ e: Entry, from d: Data, inflate: (@Sendable (Data, Int) -> Data?)?) -> Data? {
        let p = e.localOffset
        guard p + 30 <= d.count, u32(d, p) == 0x04034b50 else { return nil }
        let start = p + 30 + u16(d, p + 26) + u16(d, p + 28)
        guard start + e.compressedSize <= d.count else { return nil }
        let raw = d.subdata(in: (d.startIndex + start)..<(d.startIndex + start + e.compressedSize))
        switch e.method {
        case 0: return raw
        case 8: return inflate?(raw, e.size)
        default: return nil
        }
    }
}

#if canImport(Compression)
import Compression
enum RawInflate {
    static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0, expectedSize < 200_000_000 else { return expectedSize == 0 ? Data() : nil }
        var out = Data(count: expectedSize)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n == expectedSize ? out : nil
    }
}
#endif

/// Text from .docx (paragraphs), .pptx (per slide) and .xlsx (shared strings + inline cells).
public enum OfficeText {
    public static func extract(_ d: Data, kind: String, inflate: (@Sendable (Data, Int) -> Data?)?) -> String? {
        guard let entries = ZipReader.entries(d) else { return nil }
        func file(_ name: String) -> Data? { entries.first { $0.name == name }.flatMap { ZipReader.read($0, from: d, inflate: inflate) } }
        switch kind {
        case "docx":
            return file("word/document.xml").map { XMLText.collect($0, textTags: ["w:t"], breakTags: ["w:p"], tabTags: ["w:tab"]) }
        case "pptx":
            let slides = entries.map(\.name).filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { number($0) < number($1) }
            let parts = slides.enumerated().compactMap { i, n -> String? in
                guard let x = file(n) else { return nil }
                let t = XMLText.collect(x, textTags: ["a:t"], breakTags: ["a:p"], tabTags: [])
                return "Slide \(i + 1):\n" + t
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        case "xlsx":
            var out: [String] = []
            if let s = file("xl/sharedStrings.xml") { out.append(XMLText.collect(s, textTags: ["t"], breakTags: ["si"], tabTags: [])) }
            for n in entries.map(\.name).filter({ $0.hasPrefix("xl/worksheets/sheet") }).sorted(by: { number($0) < number($1) }) {
                if let x = file(n) {
                    let t = XMLText.collect(x, textTags: ["t", "v"], breakTags: ["row"], tabTags: [], cellSeparator: "c")
                    if !t.isEmpty { out.append(t) }
                }
            }
            return out.isEmpty ? nil : out.joined(separator: "\n")
        default: return nil
        }
    }

    static func number(_ name: String) -> Int {
        Int(name.filter(\.isNumber)) ?? 0
    }
}

final class XMLText: NSObject, XMLParserDelegate {
    private var out = ""
    private var capture = false
    private let textTags: Set<String>, breakTags: Set<String>, tabTags: Set<String>
    private let cellSeparator: String?

    init(textTags: Set<String>, breakTags: Set<String>, tabTags: Set<String>, cellSeparator: String?) {
        self.textTags = textTags; self.breakTags = breakTags; self.tabTags = tabTags; self.cellSeparator = cellSeparator
    }

    static func collect(_ data: Data, textTags: Set<String>, breakTags: Set<String>, tabTags: Set<String>, cellSeparator: String? = nil) -> String {
        let h = XMLText(textTags: textTags, breakTags: breakTags, tabTags: tabTags, cellSeparator: cellSeparator)
        let p = XMLParser(data: data)
        p.delegate = h
        p.parse()
        return h.out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName q: String?, attributes: [String: String] = [:]) {
        if textTags.contains(name) { capture = true }
        if tabTags.contains(name) { out += "\t" }
        if name == cellSeparator, !out.isEmpty, !out.hasSuffix("\n") { out += "\t" }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName q: String?) {
        if textTags.contains(name) { capture = false }
        if breakTags.contains(name) { out += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if capture { out += s } }
}
