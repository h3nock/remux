import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system camera, for taking one photo to attach.
struct GhosttyAttachmentCameraPicker: UIViewControllerRepresentable {
    /// False where there is no camera to open, as in the simulator; the composer then leaves Camera out.
    static let isCameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera) || debugPhoto != nil

    /// In a debug build, REMUX_DEBUG_CAMERA_PHOTO (a picture's path) stands in for a camera where there is none: Camera
    /// shows as it does on a phone, and taking a photo gives that picture.
    static let debugPhoto: UIImage? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["REMUX_DEBUG_CAMERA_PHOTO"].flatMap(UIImage.init(contentsOfFile:))
        #else
        nil
        #endif
    }()

    /// Called once with the photo, or with `nil` when the camera was closed without one.
    let onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
