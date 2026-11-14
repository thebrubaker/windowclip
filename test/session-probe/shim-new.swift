import Foundation

func configureLogging(_ scratch: String) { Log.directory = URL(fileURLWithPath: "\(scratch)/logs") }

func dumpLog() {
    Log.flush()
    let text = (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? ""
    print("      log (\(Log.fileURL.lastPathComponent)):")
    for line in text.split(separator: "\n") where !line.contains("→ countdown") && !line.contains("→ recording") {
        print("        " + line.split(separator: " ", maxSplits: 1).last!)
    }
}
