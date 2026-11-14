import CoreGraphics
import Foundation

// 1920x1080 final output. Hardcoded for now — backgrounds and presets land later.
let OUTPUT_W = 1920
let OUTPUT_H = 1080
let WINDOW_BITRATE = 12_000_000

let DISPLAY_MAX_SIDE = 4096
let DISPLAY_FALLBACK_W = 3840
let DISPLAY_FALLBACK_H = 2160
let DISPLAY_MAX_BITRATE = 40_000_000

/// The display's own size, shrunk to fit 4096 a side; if this machine's hardware
/// H.264 encoder won't take that, the 3840x2160 box instead. Hardware limits
/// differ by machine (the m3 encodes 4096x4096 in hardware, stella's Intel
/// encoder stops short of 2304x4096) and past them VideoToolbox silently falls
/// back to a software encoder that drops frames at 30 fps.
func displayOutputSize(pixelWidth: Int, pixelHeight: Int, hardwareAccepts: (Int, Int) -> Bool) -> (width: Int, height: Int) {
    func fit(_ maxW: Int, _ maxH: Int) -> (width: Int, height: Int) {
        let scale = min(1.0, Double(maxW) / Double(pixelWidth), Double(maxH) / Double(pixelHeight))
        func even(_ v: Double) -> Int { max(2, Int(v / 2) * 2) }
        return (even(Double(pixelWidth) * scale), even(Double(pixelHeight) * scale))
    }
    let native = fit(DISPLAY_MAX_SIDE, DISPLAY_MAX_SIDE)
    return hardwareAccepts(native.width, native.height) ? native : fit(DISPLAY_FALLBACK_W, DISPLAY_FALLBACK_H)
}

func displayBitrate(width: Int, height: Int) -> Int {
    let perPixel = Double(WINDOW_BITRATE) / Double(OUTPUT_W * OUTPUT_H)
    return min(DISPLAY_MAX_BITRATE, Int(perPixel * Double(width * height)))
}

/// Computes the (scale, translation) to aspect-fit a srcW x srcH source into
/// an inner rect of [padX, padY] padding inside an outputW x outputH canvas.
/// Returns the affine transform to apply to the source CIImage.
func fitTransform(srcW: Int, srcH: Int, outputW: Int, outputH: Int, padRatio: CGFloat) -> CGAffineTransform {
    let padX = CGFloat(outputW) * padRatio
    let padY = CGFloat(outputH) * padRatio
    let innerW = CGFloat(outputW) - 2 * padX
    let innerH = CGFloat(outputH) - 2 * padY
    let srcAspect = CGFloat(srcW) / CGFloat(srcH)
    let innerAspect = innerW / innerH

    let dispW: CGFloat, dispH: CGFloat
    if srcAspect > innerAspect {
        dispW = innerW
        dispH = innerW / srcAspect
    } else {
        dispH = innerH
        dispW = innerH * srcAspect
    }
    let scale = dispW / CGFloat(srcW)
    let tx = (CGFloat(outputW) - dispW) / 2
    let ty = (CGFloat(outputH) - dispH) / 2
    return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
}
