import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import SwiftUI

/// Loads a JPEG/PNG/HEIC from disk and scales/center-crops it to the output
/// canvas dimensions. Returns nil if the file is missing or undecodable.
func loadBackgroundImage(path: String, width: Int, height: Int) -> CIImage? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        writeDiagnostic(Data("recorder: failed to load bg image \(path)\n".utf8))
        return nil
    }
    let srcCI = CIImage(cgImage: cg)
    let srcW = CGFloat(cg.width)
    let srcH = CGFloat(cg.height)
    let outW = CGFloat(width)
    let outH = CGFloat(height)

    // Scale-to-fill: scale by the LARGER of the two ratios so the smaller
    // dimension of the source covers the canvas. Then center-crop the excess.
    let scale = max(outW / srcW, outH / srcH)
    let scaled = srcCI.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let scaledW = srcW * scale
    let scaledH = srcH * scale
    // Center the scaled image, then crop to canvas. CIImage origin is bottom-left.
    let tx = (outW - scaledW) / 2
    let ty = (outH - scaledH) / 2
    let positioned = scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
    return positioned.cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
}

/// Builds the styled background CIImage that frames every windowclip recording.
///
/// Uses SwiftUI's `MeshGradient` (Sequoia+) for a tasteful warm-tone field
/// that recedes behind the recorded window. A 3x3 mesh gives enough control
/// to get richness without busy-ness: warm peach top, amber midline,
/// deep mocha bottom, with subtle hue variation midfield.
///
/// Rendered once at recorder init and cached as a CIImage. Per-frame
/// composition just references this image — no recomputation in the hot path.
@MainActor
func makeMeshGradientBackground(width: Int, height: Int) -> CIImage {
    // Warm "Tahoe sunset" palette. Points are normalized [0..1] in the grid.
    // Colors flow from peach top-left → amber midline → deep warm mocha
    // bottom-right, with subtle terracotta and rust nodes interpolating.
    let view = MeshGradient(
        width: 3,
        height: 3,
        points: [
            [0.00, 0.00], [0.50, 0.00], [1.00, 0.00],
            [0.00, 0.50], [0.55, 0.45], [1.00, 0.50],
            [0.00, 1.00], [0.50, 1.00], [1.00, 1.00],
        ],
        colors: [
            Color(red: 0.99, green: 0.80, blue: 0.62),  // top-left:    soft peach
            Color(red: 0.96, green: 0.65, blue: 0.40),  // top-center:  warm amber
            Color(red: 0.85, green: 0.45, blue: 0.32),  // top-right:   terracotta
            Color(red: 0.78, green: 0.42, blue: 0.32),  // mid-left:    warm rust
            Color(red: 0.55, green: 0.28, blue: 0.25),  // center:      deep terracotta
            Color(red: 0.45, green: 0.22, blue: 0.22),  // mid-right:   warm umber
            Color(red: 0.32, green: 0.16, blue: 0.18),  // bot-left:    deep warm
            Color(red: 0.22, green: 0.11, blue: 0.13),  // bot-center:  mocha
            Color(red: 0.12, green: 0.07, blue: 0.09),  // bot-right:   near-black
        ]
    )
    .frame(width: CGFloat(width), height: CGFloat(height))

    let renderer = ImageRenderer(content: view)
    renderer.scale = 1.0  // canvas is already at output resolution
    guard let cgImage = renderer.cgImage else {
        // Fallback: solid warm color if SwiftUI rendering somehow fails.
        writeDiagnostic(Data("recorder: MeshGradient render failed, falling back to flat color\n".utf8))
        return CIImage(color: CIColor(red: 0.55, green: 0.28, blue: 0.25))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return CIImage(cgImage: cgImage)
}

/// Builds a soft drop shadow from the window's alpha mask. Steps:
/// 1. Keep only the alpha channel as a gray image
/// 2. Tint to black with target shadow opacity
/// 3. Blur for softness
/// 4. Offset down/right
func makeShadow(for window: CIImage, blur: Double, offsetX: Double, offsetY: Double, opacity: Double) -> CIImage {
    // CIMaskToAlpha turns a grayscale into an alpha-only image. To get just the
    // window's alpha as a tinted shape, multiply the original by a solid black,
    // then blur, then move.
    let blackTint = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(opacity)))
        .cropped(to: window.extent)
    // sourceIn: shadow = blackTint where window has alpha > 0
    let masked = blackTint.applyingFilter("CISourceInCompositing", parameters: [
        kCIInputBackgroundImageKey: window,
    ])
    let blurred = masked.applyingFilter("CIGaussianBlur", parameters: [
        kCIInputRadiusKey: blur,
    ])
    return blurred.transformed(by: CGAffineTransform(translationX: CGFloat(offsetX), y: CGFloat(-offsetY)))
}

/// Composites a window-shaped CIImage (with alpha) onto a styled background.
/// Renders into reusable CVPixelBuffers from a pool — minimizes per-frame allocs.
final class Composer {
    enum Layout {
        case styled
        case solidProbe
        case passthrough
    }

    let ciContext: CIContext
    let outputSize: CGSize
    let pixelBufferPool: CVPixelBufferPool
    let background: CIImage
    let layout: Layout
    let padRatio: CGFloat = 0.08
    // Tasteful "macOS window on desktop" shadow — visible but not heavy.
    let shadowBlur: Double = 55
    let shadowOffsetX: Double = 0
    let shadowOffsetY: Double = 35
    let shadowOpacity: Double = 0.7

    init(outputW: Int, outputH: Int, layout: Layout, background: CIImage) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "composer", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Metal device"])
        }
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
        ])
        self.outputSize = CGSize(width: outputW, height: outputH)
        self.layout = layout

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputW,
            kCVPixelBufferHeightKey as String: outputH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        guard let pool = pool else {
            throw NSError(domain: "composer", code: 2, userInfo: [NSLocalizedDescriptionKey: "pool creation failed"])
        }
        self.pixelBufferPool = pool

        self.background = background
    }

    func compose(_ source: CMSampleBuffer) -> CMSampleBuffer? {
        guard let srcBuffer = CMSampleBufferGetImageBuffer(source) else { return nil }
        let srcW = CVPixelBufferGetWidth(srcBuffer)
        let srcH = CVPixelBufferGetHeight(srcBuffer)
        let sourceCI = CIImage(cvPixelBuffer: srcBuffer)

        let composed: CIImage
        switch layout {
        case .solidProbe:
            let probeBg = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: srcW, height: srcH))
            composed = sourceCI.composited(over: probeBg)
        case .passthrough:
            let transform = fitTransform(srcW: srcW, srcH: srcH, outputW: Int(outputSize.width), outputH: Int(outputSize.height), padRatio: 0)
            composed = sourceCI.transformed(by: transform).composited(over: background)
        case .styled:
            // Scale + position the window inside the canvas with padding.
            let transform = fitTransform(srcW: srcW, srcH: srcH, outputW: Int(outputSize.width), outputH: Int(outputSize.height), padRatio: padRatio)
            let positionedWindow = sourceCI.transformed(by: transform)
            // Build drop shadow from the positioned (and thus scaled) window.
            let shadow = makeShadow(for: positionedWindow, blur: shadowBlur, offsetX: shadowOffsetX, offsetY: shadowOffsetY, opacity: shadowOpacity)
            // Layer order: bg → shadow → window
            let shadowOverBg = shadow.composited(over: background)
            composed = positionedWindow.composited(over: shadowOverBg)
        }

        var outBuf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &outBuf)
        guard let outBuf = outBuf else { return nil }
        ciContext.render(composed, to: outBuf)

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: outBuf,
                                                     formatDescriptionOut: &formatDesc)
        guard let formatDesc = formatDesc else { return nil }

        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(source, at: 0, timingInfoOut: &timing)

        var newBuf: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: outBuf,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: formatDesc,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &newBuf)
        return newBuf
    }
}
