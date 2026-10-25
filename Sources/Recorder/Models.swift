import CryptoKit
import Foundation

/// The Whisper models the app can download. Sizes and SHA-256 come from huggingface.co/ggerganov/whisper.cpp.
enum WhisperModel: String, CaseIterable, Identifiable {
    case largeV3 = "ggml-large-v3.bin"
    case turbo = "ggml-large-v3-turbo-q5_0.bin"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largeV3: "Best accuracy"
        case .turbo: "Faster, smaller"
        }
    }

    /// The technical name, written into transcripts.
    var name: String {
        switch self {
        case .largeV3: "Whisper large-v3"
        case .turbo: "Whisper large-v3 turbo"
        }
    }

    var bytes: Int64 {
        switch self {
        case .largeV3: 3_095_033_483
        case .turbo: 574_041_195
        }
    }

    var sha256: String {
        switch self {
        case .largeV3: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
        case .turbo: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        }
    }

    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)")! }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// What the model needs while it runs, shown next to the choice.
    var memoryText: String {
        switch self {
        case .largeV3: "Uses about 5 GB of memory while it runs."
        case .turbo: "Uses about 1.5 GB of memory. Less accurate on Turkish."
        }
    }
}

/// Downloads, verifies and removes models in `~/Library/Application Support/Recorder/Models`.
@MainActor @Observable
final class ModelStore {
    enum State: Equatable {
        case missing
        case downloading(Double)
        case verifying
        case installed
    }

    private(set) var states: [WhisperModel: State] = [:]
    private(set) var message: String?

    let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Recorder/Models")
    private var downloads: [WhisperModel: (task: URLSessionDownloadTask, session: URLSession)] = [:]
    private var resumeData: [WhisperModel: Data] = [:]

    init() {
        for model in WhisperModel.allCases {
            // A download cut off while it was checked (the app quit) leaves gigabytes nobody resumes.
            try? FileManager.default.removeItem(at: folder.appending(path: model.rawValue + ".partial"))
            states[model] = isInstalled(model) ? .installed : .missing
        }
    }

    func state(_ model: WhisperModel) -> State { states[model] ?? .missing }

    /// `--model <file>` on the command line replaces the downloaded file (a test aid).
    func url(_ model: WhisperModel) -> URL {
        if let i = CommandLine.arguments.firstIndex(of: "--model"), i + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        return stored(model)
    }

    /// Where a downloaded model lives. Downloads and Remove only ever touch this path, never the `--model` override.
    private func stored(_ model: WhisperModel) -> URL { folder.appending(path: model.rawValue) }

    func isInstalled(_ model: WhisperModel) -> Bool {
        let size = (try? url(model).resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
        return size.map { Int64($0) == model.bytes || CommandLine.arguments.contains("--model") } ?? false
    }

    func download(_ model: WhisperModel) {
        guard state(model) == .missing else { return }
        message = nil
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        guard free > model.bytes + 1 << 30 else {
            message = "Not enough free disk space: \(model.sizeText) plus 1 GB are needed."
            return
        }
        states[model] = .downloading(0)
        let delegate = DownloadDelegate(
            partial: folder.appending(path: model.rawValue + ".partial"),
            expected: model.bytes,
            progress: { [weak self] value in Task { @MainActor in self?.setProgress(model, value) } },
            finished: { [weak self] result in Task { @MainActor in self?.downloadEnded(model, result) } }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = resumeData.removeValue(forKey: model).map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: model.url)
        downloads[model] = (task, session)
        task.resume()
    }

    func cancelDownload(_ model: WhisperModel) {
        guard let download = downloads.removeValue(forKey: model) else { return }
        // The resume data lets the next Download continue where this one stopped.
        // At once, so a Download right after it starts again instead of seeing the old one still running.
        if case .downloading = state(model) { states[model] = .missing }
        download.task.cancel { [weak self] data in
            Task { @MainActor in if let data { self?.resumeData[model] = data } }
        }
        download.session.finishTasksAndInvalidate()
    }

    func remove(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: stored(model))
        states[model] = .missing
    }

    private func setProgress(_ model: WhisperModel, _ value: Double) {
        if case .downloading = state(model) { states[model] = .downloading(value) }
    }

    private func downloadEnded(_ model: WhisperModel, _ result: Result<URL, any Error>) {
        downloads.removeValue(forKey: model)?.session.finishTasksAndInvalidate()
        switch result {
        case .failure(let error):
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resumeData[model] = data }
            states[model] = .missing
            message = "Download stopped: \(error.localizedDescription) Press Download to continue."
        case .success(let partial):
            states[model] = .verifying
            let target = stored(model)
            let expected = model.sha256
            Task.detached {
                let outcome = Result { try Self.install(partial: partial, as: target, sha256: expected) }
                await MainActor.run {
                    switch outcome {
                    case .success: self.states[model] = .installed
                    case .failure(let error):
                        self.states[model] = .missing
                        self.message = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Moves a finished download into place only when its SHA-256 matches; a damaged file is deleted.
    nonisolated static func install(partial: URL, as target: URL, sha256 expected: String) throws {
        let hash: String
        do { hash = try sha256(of: partial) } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        guard hash == expected else {
            try? FileManager.default.removeItem(at: partial)
            throw RecorderError("The download is damaged and was deleted. Press Download to try again.")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
    }

    /// Hashes in 1 MB reads, so a 3 GB model never sits in memory.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let partial: URL
    let expected: Int64
    let progress: @Sendable (Double) -> Void
    let finished: @Sendable (Result<URL, any Error>) -> Void
    private var reported = false

    init(partial: URL, expected: Int64, progress: @escaping @Sendable (Double) -> Void, finished: @escaping @Sendable (Result<URL, any Error>) -> Void) {
        self.partial = partial
        self.expected = expected
        self.progress = progress
        self.finished = finished
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(min(1, Double(totalBytesWritten) / Double(max(expected, 1))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so the file is moved right here.
        reported = true
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return finished(.failure(RecorderError("The download failed (error \(http.statusCode)).")))
        }
        do {
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
            finished(.success(partial))
        } catch {
            finished(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error, !reported, (error as NSError).code != NSURLErrorCancelled { finished(.failure(error)) }
    }
}
