import AVFoundation
import Foundation

func partialPath(for outputPath: String, pid: pid_t) -> URL {
    let output = URL(fileURLWithPath: outputPath)
    let ext = output.pathExtension.isEmpty ? "mp4" : output.pathExtension
    return output.deletingLastPathComponent()
        .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).partial-\(pid).\(ext)")
}

func removePartialFile(at partial: URL) {
    if FileManager.default.fileExists(atPath: partial.path) {
        try? FileManager.default.removeItem(at: partial)
    }
}

func discardTake(recorder: Recorder, partial: URL, output: String) -> Never {
    if recorder.writer.status == .writing { recorder.writer.cancelWriting() }
    removePartialFile(at: partial)
    writeDiagnostic(Data("recorder: discarded the take, \(output) untouched\n".utf8))
    exit(2)
}

func finishTake(recorder: Recorder, partial: URL, output outputPath: String) async throws {
    let (started, failed) = recorder.writerLock.withLock { (recorder.sessionStarted, recorder.writerFailed) }
    if !started {
        if recorder.writer.status == .writing { recorder.writer.cancelWriting() }
        removePartialFile(at: partial)
        if failed {
            throw NSError(domain: "recorder", code: 5, userInfo: [NSLocalizedDescriptionKey: "the writer could not start; no take, \(outputPath) untouched"])
        }
        writeDiagnostic(Data("recorder: stopped before the first frame; no take, \(outputPath) untouched\n".utf8))
        exit(3)
    }
    recorder.videoInput.markAsFinished()
    recorder.audioInput?.markAsFinished()
    await recorder.writer.finishWriting()

    if recorder.writer.status != .completed {
        throw NSError(domain: "recorder", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "writer status \(recorder.writer.status.rawValue): \(recorder.writer.error?.localizedDescription ?? "?")",
        ])
    }
    let replacing = FileManager.default.fileExists(atPath: outputPath)
    guard rename(partial.path, outputPath) == 0 else {
        throw NSError(domain: "recorder", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "could not move the take into place: \(String(cString: strerror(errno)))",
        ])
    }
    writeDiagnostic(Data("recorder: wrote \(outputPath)\(replacing ? " (replaced the file already there)" : "")\n".utf8))
}
