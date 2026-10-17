import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct LoginView: View {
  @Bindable var model: LoginViewModel

  var body: some View {
    VStack(spacing: 16) {
      Text("Sign in to \(model.pluginName)").font(.title2)
      if model.isDone {
        Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      } else if case .prompt(let kind, let message, let qr) = model.prompt {
        Text(message).multilineTextAlignment(.center)
        if kind == .qr, let qr, let image = QRCode.image(qr) {
          image.interpolation(.none).resizable().frame(width: 220, height: 220)
        } else if kind == .text || kind == .password {
          HStack {
            if kind == .password {
              SecureField("", text: $model.input).onSubmit { model.submit() }
            } else {
              TextField("", text: $model.input).onSubmit { model.submit() }
            }
            Button("Continue") { model.submit() }.disabled(model.input.isEmpty)
          }
        }
      } else if model.failure == nil {
        ProgressView()
      }
      if let failure = model.failure {
        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      }
      Button(model.isDone ? "Done" : "Cancel") { model.close() }
        .keyboardShortcut(model.isDone ? .defaultAction : .cancelAction)
    }
    .padding(24)
    .frame(minWidth: 360)
    .task { model.start() }
  }
}

enum QRCode {
  static func image(_ text: String) -> Image? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
      let cgImage = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return Image(decorative: cgImage, scale: 1)
  }
}
