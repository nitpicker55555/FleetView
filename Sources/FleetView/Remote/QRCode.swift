import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Renders a URL to a crisp QR code so a phone can scan straight into the web terminal.
enum QRCode {
    static func image(for string: String, size: CGFloat = 200) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}
