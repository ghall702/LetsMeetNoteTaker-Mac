import Foundation
import WhisperKit
import LessonNotesCore

/// Manages downloadable WhisperKit Core ML models stored in Application Support.
@MainActor
final class WhisperModelManager: ObservableObject {
    struct ModelEntry: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var approxSize: String
        var recommended: Bool
    }

    @Published var available: [ModelEntry] = []
    @Published var downloaded: [String: Int64] = [:]
    @Published var downloading: [String: Double] = [:]
    @Published var preparing: Set<String> = []
    @Published var lastError: String?
    @Published var isLoadingList = false
    @Published var recommendedDefault: String?

    let modelsBase: URL
    var repoFolder: URL { modelsBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true) }

    init() {
        modelsBase = AppInfo.supportDirectory.appendingPathComponent("WhisperModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsBase, withIntermediateDirectories: true)
        scanDownloaded()
        let local = WhisperKit.recommendedModels()
        recommendedDefault = local.default
        available = local.supported.map { ModelEntry(name: $0, approxSize: Self.approxSize($0), recommended: $0 == local.default) }
    }

    /// Approximate download sizes (from Whisper model sizes / compressed-variant suffixes).
    static func approxSize(_ name: String) -> String {
        if let r = name.range(of: #"_(\d+)MB"#, options: .regularExpression) {
            return "≈ " + name[r].dropFirst().replacingOccurrences(of: "MB", with: " MB")
        }
        let n = name.lowercased()
        if n.contains("tiny") { return "≈ 75 MB" }
        if n.contains("base") { return "≈ 145 MB" }
        if n.contains("small") { return "≈ 480 MB" }
        if n.contains("medium") { return "≈ 1.5 GB" }
        if n.contains("distil") { return "≈ 1.5 GB" }
        if n.contains("turbo") { return "≈ 1.6 GB" }
        if n.contains("large") { return "≈ 3 GB" }
        return "unknown size"
    }

    /// Rough working-memory need of one loaded model while transcribing (for warnings only).
    static func estimatedMemoryBytes(_ name: String) -> Int64 {
        let n = name.lowercased()
        let gb: Double
        if n.contains("tiny") { gb = 0.4 } else if n.contains("base") { gb = 0.6 } else if n.contains("small") { gb = 1.2 }
        else if n.contains("medium") { gb = 2.5 } else if n.contains("distil") { gb = 1.8 } else if n.contains("turbo") { gb = 2.2 }
        else if n.contains("large") { gb = 3.5 } else { gb = 2.0 }
        return Int64(gb * 1_073_741_824)
    }

    func refreshAvailable() async {
        isLoadingList = true
        defer { isLoadingList = false }
        let remote = await WhisperKit.recommendedRemoteModels(downloadBase: modelsBase)
        recommendedDefault = remote.default
        var names = remote.supported
        if let all = try? await WhisperKit.fetchAvailableModels(downloadBase: modelsBase), !all.isEmpty {
            names = all.filter { remote.supported.isEmpty || remote.supported.contains($0) }
            if names.isEmpty { names = all }
        }
        if !names.isEmpty {
            available = names.map { ModelEntry(name: $0, approxSize: Self.approxSize($0), recommended: $0 == remote.default) }
        }
        scanDownloaded()
    }

    func scanDownloaded() {
        var result: [String: Int64] = [:]
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: repoFolder, includingPropertiesForKeys: nil) {
            for dir in items where fm.fileExists(atPath: dir.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                result[dir.lastPathComponent] = Self.directorySize(dir)
            }
        }
        downloaded = result
    }

    var totalStorage: Int64 {
        Self.directorySize(modelsBase)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    func folder(for name: String) -> URL? {
        let u = repoFolder.appendingPathComponent(name, isDirectory: true)
        return FileManager.default.fileExists(atPath: u.appendingPathComponent("AudioEncoder.mlmodelc").path) ? u : nil
    }

    /// Downloads the model, then loads it once so the tokenizer is fetched and Core ML compiles it.
    func download(_ name: String) async {
        guard downloading[name] == nil else { return }
        lastError = nil
        downloading[name] = 0
        defer { downloading[name] = nil }
        do {
            let folder = try await WhisperKit.download(variant: name, downloadBase: modelsBase) { p in
                let fraction = p.fractionCompleted
                Task { @MainActor in self.downloading[name] = fraction }
            }
            downloading[name] = nil
            preparing.insert(name)
            defer { preparing.remove(name) }
            let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: modelsBase, verbose: false, logLevel: .none,
                                          prewarm: true, load: true, download: false)
            _ = try await WhisperKit(config)
            scanDownloaded()
        } catch {
            lastError = "Download of \(name) failed: \(error.localizedDescription)"
            scanDownloaded()
        }
    }

    func delete(_ name: String) {
        let u = repoFolder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: u)
        scanDownloaded()
    }
}

/// Runs WhisperKit transcription locally.
///
/// A single WhisperKit instance is not safe for overlapping transcriptions (it holds decoder state
/// and one progress object), so simultaneous transcriptions each borrow their own instance from a
/// small pool. Instances are created only when needed, reused between jobs, and unloaded when the
/// limit is lowered or the model changes. The Core ML model files on disk are shared.
actor WhisperTranscriber: Transcribing {
    private struct Instance { let pipe: WhisperKit; let folder: String }
    private var idle: [Instance] = []
    private var inUse = 0
    private let resolveModel: @Sendable () async -> (name: String, folder: URL, tokenizerBase: URL)?
    private let poolLimit: @Sendable () -> Int

    init(resolveModel: @escaping @Sendable () async -> (name: String, folder: URL, tokenizerBase: URL)?,
         poolLimit: @escaping @Sendable () -> Int = { 1 }) {
        self.resolveModel = resolveModel
        self.poolLimit = poolLimit
    }

    enum TranscriberError: LocalizedError {
        case noModel
        var errorDescription: String? { "No transcription model is downloaded. Download one in Settings → Transcription, then retry." }
    }

    var loadedInstances: Int { idle.count + inUse }

    func unload() async {
        for i in idle { await i.pipe.unloadModels() }
        idle = []
    }

    private func acquire(folder: URL, tokenizerBase: URL) async throws -> Instance {
        // Drop idle instances of a different model.
        var keep: [Instance] = []
        for i in idle {
            if i.folder == folder.path { keep.append(i) } else { await i.pipe.unloadModels() }
        }
        idle = keep
        inUse += 1
        if let i = idle.popLast() { return i }
        do {
            let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: tokenizerBase, verbose: false,
                                          logLevel: .none, prewarm: false, load: true, download: false)
            return Instance(pipe: try await WhisperKit(config), folder: folder.path)
        } catch {
            inUse -= 1
            throw error
        }
    }

    private func release(_ i: Instance) async {
        inUse -= 1
        // Keep only as many loaded instances as the current limit allows (frees memory when lowered).
        if idle.count + inUse < max(1, poolLimit()) { idle.append(i) } else { await i.pipe.unloadModels() }
    }

    func transcribe(audioURL: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionOutput {
        guard let model = await resolveModel() else { throw TranscriberError.noModel }
        let instance = try await acquire(folder: model.folder, tokenizerBase: model.tokenizerBase)
        do {
            let out = try await run(instance.pipe, audioURL: audioURL, language: language, modelName: model.name, progress: progress)
            await release(instance)
            return out
        } catch {
            await release(instance)
            throw error
        }
    }

    private func run(_ pipe: WhisperKit, audioURL: URL, language: String?, modelName: String,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionOutput {
        let options = DecodingOptions(verbose: false, task: .transcribe, language: language, temperature: 0,
                                      usePrefillPrompt: language != nil, detectLanguage: language == nil,
                                      skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: false,
                                      concurrentWorkerCount: 4, chunkingStrategy: .vad)
        let cancelled = CancelFlag()
        let progressObject = pipe.progress
        let poller = Task {
            while !Task.isCancelled {
                progress(min(0.99, progressObject.fractionCompleted))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { poller.cancel() }
        let results: [TranscriptionResult] = try await withTaskCancellationHandler {
            try await pipe.transcribe(audioPath: audioURL.path, decodeOptions: options) { _ in
                cancelled.isSet ? false : nil
            }
        } onCancel: {
            cancelled.set()
        }
        try Task.checkCancellation()
        var segments: [TranscriptSegment] = []
        for r in results {
            for seg in r.segments {
                segments.append(TranscriptSegment(start: Double(seg.start), end: Double(seg.end), text: seg.text))
            }
        }
        segments.sort { $0.start < $1.start }
        progress(1)
        let lang = results.first?.language ?? language ?? "en"
        return TranscriptionOutput(segments: segments, modelId: "whisperkit/\(modelName)", language: lang)
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
