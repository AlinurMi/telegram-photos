import CoreImage.CIFilterBuiltins
import SwiftUI

/// Shows the login QR code. Another device that's logged in to Telegram scans it.
struct QrLoginView: View {
    let link: String
    let usePhone: () -> Void

    var body: some View {
        ScreenLayout(title: "Scan to log in", subtitle: "On another device: Settings → Devices → scan this code.") {
            VStack(spacing: 24) {
                QrCodeImage(text: link)
                    .frame(maxWidth: 260, maxHeight: 260)
                    .padding(20)
                    .background(.white, in: .rect(cornerRadius: 28))
                    .frame(maxWidth: .infinity)
                QuietButton(title: "Use phone number instead", action: usePhone)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct QrCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    private static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
