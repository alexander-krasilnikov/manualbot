import PhotosUI
import SwiftUI
import UIKit

/// The two ways to add a photo to a question: take one, or choose one from the library.
struct PhotoAttachButtons: View {
    let chat: ChatViewModel
    var samplePhoto: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showCameraDenied = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if chat.photosAvailable { controls }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if let stub = chat.stubPhoto {
                Button("Attach photo", systemImage: "photo") { chat.attach(photo: stub) }
                    .labelStyle(.iconOnly).accessibilityIdentifier("attachPhotoButton")
            } else {
                PhotosPicker(selection: $pickerItem, matching: .images) { Image(systemName: "photo") }
                    .accessibilityLabel("Choose a photo").accessibilityIdentifier("attachPhotoButton")
                if chat.cameraAvailable {
                    Button("Take a photo", systemImage: "camera") { openCamera() }
                        .labelStyle(.iconOnly).accessibilityIdentifier("cameraButton")
                }
                if let samplePhoto {
                    Button("Use the sample nameplate photo", systemImage: "photo.badge.checkmark") { chat.attach(photo: samplePhoto) }
                        .labelStyle(.iconOnly).accessibilityIdentifier("samplePhotoButton")
                }
            }
        }
        .font(.title2)
        .disabled(chat.availability != .ready || chat.isGenerating)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { chat.attach(photo: data) }
                pickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                showCamera = false
                if let data { chat.attach(photo: data) }
            }
            .ignoresSafeArea()
        }
        .alert("Camera access is off", isPresented: $showCameraDenied) {
            Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("To photograph a nameplate, allow camera access for ManualBot in Settings. You can still choose a photo from your library.")
        }
    }

    private func openCamera() {
        if chat.cameraDenied { showCameraDenied = true } else { showCamera = true }
    }
}

/// The photo waiting to be sent, with a way to take it back.
struct AttachedPhotoChip: View {
    let data: Data
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("Photo attached").font(.subheadline).foregroundStyle(.secondary)
            Button("Remove photo", systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly).foregroundStyle(.secondary).accessibilityIdentifier("removePhotoButton")
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachedPhoto")
    }
}

/// The system camera. It returns JPEG data (with its orientation recorded in the file).
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Data?) -> Void
        init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
