import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

/// The loose mouth crop the iPhone sends: a square centred on the mouth, `Constants.mouthCropScale`
/// mouth widths across, rotated so the eye line is level and the mouth sits below the eyes.
/// The exact alignment each lip-reading model wants happens later in Python, from the landmarks.
public struct MouthCrop: Sendable, Equatable {
    /// Mouth centre in image pixels: the mean of the two corners and the two lip centres.
    public var centre: SIMD2<Float>
    /// Unit vector of the crop's x axis in image pixels (along the eye line).
    public var xAxis: SIMD2<Float>
    /// Unit vector of the crop's y axis in image pixels (eyes towards mouth).
    public var yAxis: SIMD2<Float>
    /// Side of the square in image pixels.
    public var side: Float
    public var size: Int

    /// Nil when the landmarks are degenerate (a zero-width mouth or both eyes in one place).
    /// - Parameter landmarks: `CropLandmark` slots in image pixels.
    public init?(landmarks: [SIMD2<Float>], size: Int = Constants.mouthCropSize, scale: Float = Constants.mouthCropScale) {
        guard landmarks.count == CropLandmark.allCases.count else { return nil }
        func point(_ slot: CropLandmark) -> SIMD2<Float> { landmarks[slot.rawValue] }
        let low = point(.mouthCornerLowX)
        let high = point(.mouthCornerHighX)
        let width = simd_distance(low, high)
        let eyeLow = (point(.eyeOuterLowX) + point(.eyeInnerLowX)) / 2
        let eyeHigh = (point(.eyeInnerHighX) + point(.eyeOuterHighX)) / 2
        let eyeLine = eyeHigh - eyeLow
        guard width > 1, simd_length(eyeLine) > 1 else { return nil }

        centre = (low + high + point(.upperLipCentre) + point(.lowerLipCentre)) / 4
        var x = simd_normalize(eyeLine)
        var y = SIMD2(-x.y, x.x)
        // Keep the face upright whatever way round the camera image is: the mouth is below the eyes.
        if simd_dot(y, centre - (eyeLow + eyeHigh) / 2) < 0 {
            x = -x
            y = -y
        }
        xAxis = x
        yAxis = y
        side = scale * width
        self.size = size
    }

    /// Crop pixels per image pixel.
    public var scale: Float { Float(size) / side }

    /// Maps an image point into crop pixels. Points outside the crop come back outside `0 ..< size`.
    public func cropPoint(_ image: SIMD2<Float>) -> SIMD2<Float> {
        let offset = image - centre
        let half = Float(size) / 2
        return SIMD2(simd_dot(offset, xAxis) * scale + half, simd_dot(offset, yAxis) * scale + half)
    }

    /// Maps a crop point back into the image.
    public func imagePoint(_ crop: SIMD2<Float>) -> SIMD2<Float> {
        let half = Float(size) / 2
        return centre + (crop.x - half) / scale * xAxis + (crop.y - half) / scale * yAxis
    }

    /// Cuts the crop out of an 8-bit grayscale image (the camera's luma plane), resampling with vImage.
    /// Pixels outside the image repeat its edge.
    public func extract(from base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: size * size)
        // vImage wants the forward transform, image → crop. For a crop point q: q = M (p − centre) + half.
        let half = Float(size) / 2
        let (a, b) = (xAxis.x * scale, yAxis.x * scale)
        let (c, d) = (xAxis.y * scale, yAxis.y * scale)
        let tx = half - (a * centre.x + c * centre.y)
        let ty = half - (b * centre.x + d * centre.y)
        // vImage measures y up from the bottom row of both buffers, so flip y on each side:
        // Q = D M D P + D (M (0, H) + t) + (0, S) with D = diag(1, −1).
        let (imageHeight, cropSide) = (Float(height), Float(size))
        var transform = vImage_AffineTransform(
            a: a, b: -b, c: -c, d: d,
            tx: c * imageHeight + tx,
            ty: cropSide - d * imageHeight - ty
        )
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: bytesPerRow)
        output.withUnsafeMutableBytes { bytes in
            var destination = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(size),
                                            width: vImagePixelCount(size), rowBytes: size)
            _ = vImageAffineWarp_Planar8(&source, &destination, nil, &transform, 0,
                                        vImage_Flags(kvImageEdgeExtend | kvImageHighQualityResampling))
        }
        return output
    }
}

/// Simple statistics over a grayscale crop.
public enum MouthPixels {
    /// Mean pixel value, 0 … 255.
    public static func meanLuma(_ pixels: [UInt8]) -> Float {
        guard !pixels.isEmpty else { return 0 }
        var floats = [Float](repeating: 0, count: pixels.count)
        vDSP.convertElements(of: pixels, to: &floats)
        return vDSP.mean(floats)
    }

    /// How open the mouth looks: the darkness of the middle of the crop, where the mouth opening sits.
    /// Used by the video sync check. Only changes over time matter, not the absolute value.
    public static func openness(_ pixels: [UInt8], size: Int = Constants.mouthCropSize) -> Double {
        guard pixels.count == size * size, size >= 6 else { return 0 }
        let rows = (size * 42 / 100) ..< (size * 58 / 100)
        let columns = (size / 3) ..< (2 * size / 3)
        var sum = 0
        for row in rows {
            for column in columns { sum += Int(pixels[row * size + column]) }
        }
        return 255 - Double(sum) / Double(rows.count * columns.count)
    }
}

/// Grayscale JPEG coding for mouth crops.
public enum MouthJPEG {
    public enum CodingError: Error, Equatable {
        case encodeFailed
        case decodeFailed
        case wrongSize(width: Int, height: Int)
    }

    public static func encode(_ pixels: [UInt8], size: Int = Constants.mouthCropSize,
                              quality: Double = Constants.mouthJPEGQuality) throws(CodingError) -> Data {
        guard pixels.count == size * size,
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw .encodeFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw .encodeFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .encodeFailed }
        return data as Data
    }

    /// Decodes to `size × size` 8-bit gray pixels.
    public static func decode(_ jpeg: Data, size: Int = Constants.mouthCropSize) throws(CodingError) -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw .decodeFailed }
        guard image.width == size, image.height == size else { throw .wrongSize(width: image.width, height: image.height) }
        var pixels = [UInt8](repeating: 0, count: size * size)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { throw .decodeFailed }
        return pixels
    }
}
