import Foundation

public struct ScanProgress: Sendable, Equatable {
    public var filesVisited: Int
    public var mediaFound: Int
    public var currentFolder: String
}

public struct ScanResult: Sendable {
    public var recordings: [ScannedRecording]
    /// Folders still containing a Zoom `.zoom` conversion placeholder.
    public var foldersStillConverting: [String]
    public var filesVisited: Int
}

/// Recursive, cancellable scan that only keeps lightweight metadata for media files,
/// so very large folders don't use much memory.
public enum FolderScanner {
    public static func scan(roots: [URL], progress: (@Sendable (ScanProgress) -> Void)? = nil) throws -> ScanResult {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        var recordings: [ScannedRecording] = []
        var converting = Set<String>()
        var visited = 0

        func record(_ url: URL) {
            let name = url.lastPathComponent
            let kind = RecordingFileKind.classify(name)
            if kind == .conversionPlaceholder { converting.insert(url.deletingLastPathComponent().path); return }
            guard kind.isMedia else { return }
            let v = try? url.resourceValues(forKeys: Set(keys))
            recordings.append(ScannedRecording(path: url.path,
                                               fileSize: Int64(v?.fileSize ?? 0),
                                               fileCreationDate: v?.creationDate,
                                               fileModificationDate: v?.contentModificationDate))
        }

        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { visited += 1; record(root); continue }
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let obj = en.nextObject() {
                if Task.isCancelled { throw CancellationError() }
                guard let url = obj as? URL else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                visited += 1
                record(url)
                if visited % 50 == 0 {
                    progress?(ScanProgress(filesVisited: visited, mediaFound: recordings.count,
                                           currentFolder: url.deletingLastPathComponent().lastPathComponent))
                }
            }
        }
        progress?(ScanProgress(filesVisited: visited, mediaFound: recordings.count, currentFolder: ""))
        // A recording inside a folder that is still converting is not ready.
        let ready = recordings.filter { !converting.contains($0.folderPath) }
        return ScanResult(recordings: ready, foldersStillConverting: converting.sorted(), filesVisited: visited)
    }
}
