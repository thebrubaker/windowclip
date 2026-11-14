import AVFoundation
import Foundation
import VideoToolbox

// Which H.264 frame sizes the encoder on this machine takes, two ways per size:
//   vt      VTCompressionSession created and prepared at High/AutoLevel
//   writer  AVAssetWriter with the recorder's settings, 60 frames paced at 30 fps
//           as the recorder delivers them; "dropped" counts frames it wasn't ready for
//   encoder-grid <scratch dir> <WxH>...

let scratch = CommandLine.arguments[1]
let sizes = CommandLine.arguments.dropFirst(2).compactMap { arg -> (Int, Int)? in
    let p = arg.split(separator: "x").compactMap { Int($0) }
    return p.count == 2 ? (p[0], p[1]) : nil
}

func vtAccepts(_ w: Int, _ h: Int) -> String {
    var session: VTCompressionSession?
    let created = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
                                             encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                             outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard created == noErr, let session else { return "create \(created)" }
    defer { VTCompressionSessionInvalidate(session) }
    let level = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
    let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
    guard level == noErr && prepared == noErr else { return "level \(level) prepare \(prepared)" }
    var hw: CFTypeRef?
    VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hw)
    return (hw as? Bool) == true ? "ok hw" : "ok SOFTWARE"
}

func writerAccepts(_ w: Int, _ h: Int) -> String {
    let url = URL(fileURLWithPath: "\(scratch)/\(w)x\(h).mp4")
    try? FileManager.default.removeItem(at: url)
    defer { try? FileManager.default.removeItem(at: url) }
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return "init" }
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
    ]
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else { return "canApply false" }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
    ])
    writer.add(input)
    guard writer.startWriting() else { return "startWriting: \(writer.error?.localizedDescription ?? "?")" }
    writer.startSession(atSourceTime: .zero)
    var dropped = 0
    let start = Date()
    for i in 0..<60 {
        let due = start.addingTimeInterval(Double(i) / 30)
        if due > Date() { Thread.sleep(until: due) }
        if !input.isReadyForMoreMediaData { dropped += 1; continue }
        guard let pool = adaptor.pixelBufferPool else { return "no pool (writer \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "?"))" }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return "no buffer" }
        if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)) {
            return "append \(i): \(writer.error?.localizedDescription ?? "?")"
        }
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else { return "finish: \(writer.error?.localizedDescription ?? "?")" }
    return dropped == 0 ? "ok" : "ok, dropped \(dropped)/60"
}

for (w, h) in sizes {
    let mbs = ((w + 15) / 16) * ((h + 15) / 16)
    print(String(format: "%5dx%-5d  MBs %6d  vt %-12@  writer %@", w, h, mbs, vtAccepts(w, h), writerAccepts(w, h)))
}
