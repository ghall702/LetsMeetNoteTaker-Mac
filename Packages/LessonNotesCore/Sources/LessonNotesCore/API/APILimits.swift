import Foundation

/// Size limits enforced by the Let's Meet API. All values are UTF-8 **byte** counts.
/// If the website raises its limits, update these two constants.
public enum APILimits {
    /// Maximum `transcript` field size: 5,000,000 bytes.
    public static let maxTranscriptBytes = 5_000_000
    /// Maximum total JSON request body for `POST /notes`: 6,000,000 bytes.
    public static let maxRequestBodyBytes = 6_000_000

    public static func utf8Bytes(_ s: String) -> Int { s.utf8.count }

    public enum SizeProblem: Equatable, Sendable {
        case transcriptTooLarge(bytes: Int)
        case bodyTooLarge(bytes: Int)

        public var message: String {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = Locale(identifier: "en_GB")
            func n(_ v: Int) -> String { f.string(from: NSNumber(value: v)) ?? String(v) }
            switch self {
            case .transcriptTooLarge(let b):
                return "The full transcript is \(n(b)) bytes, which is larger than the website limit of \(n(maxTranscriptBytes)) bytes. "
                    + "The transcript and notes are kept safely on this Mac and nothing was uploaded. "
                    + "This lesson can be submitted once the website accepts larger transcripts (or by processing the recordings separately)."
            case .bodyTooLarge(let b):
                return "The upload (full transcript plus notes) is \(n(b)) bytes, which is larger than the website limit of \(n(maxRequestBodyBytes)) bytes. "
                    + "The transcript and notes are kept safely on this Mac and nothing was uploaded. "
                    + "This lesson can be submitted once the website accepts larger uploads (or by processing the recordings separately)."
            }
        }
    }

    /// Checks the exact bytes that would be sent.
    public static func check(transcript: String?, encodedBody: Data) -> SizeProblem? {
        if let t = transcript, utf8Bytes(t) > maxTranscriptBytes { return .transcriptTooLarge(bytes: utf8Bytes(t)) }
        if encodedBody.count > maxRequestBodyBytes { return .bodyTooLarge(bytes: encodedBody.count) }
        return nil
    }
}
