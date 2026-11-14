import AppKit

extension Recorder {
    func prepare(target: CaptureTarget, output: URL, background: URL?) throws {
        Recorder.targets.append(target.recorderArgument)
        try prepare(windowID: 0, output: output, background: background)
    }
}
