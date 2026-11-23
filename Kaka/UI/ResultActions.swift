import StitchCore
import StitchWorkflow
import SwiftUI
import UIKit

/// Save and share for a card. Exports on demand (never on every edit), asks when the image
/// is larger than one file allows, and offers to clean up the original screenshots afterwards.
@MainActor @Observable
final class ResultActions {
    enum Intent { case save, share }

    struct SizeChoice: Identifiable {
        let id = UUID()
        let card: StitchLibrary.Card
        let intent: Intent
        let size: PixelSize
        let suggested: PixelSize?
    }

    var sizeChoice: SizeChoice?
    var cleanupCard: StitchLibrary.Card?
    private(set) var toast: Toast?
    private(set) var busyCardID: String?

    @ObservationIgnored private var toastAction: (() -> Void)?
    @ObservationIgnored private var toastExpiry: (() -> Void)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private var format: ExportFormat {
        ExportFormat(rawValue: UserDefaults.standard.string(forKey: Preferences.exportFormat) ?? "") ?? .png
    }

    private var asksToDeleteOriginals: Bool {
        UserDefaults.standard.object(forKey: Preferences.askToDeleteOriginals) as? Bool ?? true
    }

    func perform(_ intent: Intent, on card: StitchLibrary.Card, library: StitchLibrary,
                 sizing: ExportSizing = .original) async {
        let session = card.session
        guard busyCardID == nil, session.canExport || session.canSaveExport else { return }
        let format = format
        let exported = session.exportedFiles
        if exported.isEmpty || exported.contains(where: { $0.url.pathExtension != format.fileExtension }) {
            if sizing == .original, session.planExceedsExportLimits, let size = session.plan?.size {
                sizeChoice = SizeChoice(card: card, intent: intent, size: size, suggested: session.suggestedExportSize)
                return
            }
            busyCardID = card.id
            await session.export(options: ExportOptions(format: format, sizing: sizing))
            busyCardID = nil
            guard session.canSaveExport else {
                show(Toast(message: session.issues.first?.text ?? "导出失败，请重试", style: .warning))
                return
            }
        }
        switch intent {
        case .save:
            busyCardID = card.id
            await session.saveExportedFiles()
            busyCardID = nil
            if session.savedFileCount > 0 {
                didSave(card, library: library, count: session.savedFileCount)
            } else if session.issues.contains(where: { $0.code == .permissionDenied }) {
                show(Toast(message: "没有存入照片的权限，可以用分享存到文件", style: .warning))
            } else {
                show(Toast(message: session.issues.first?.text ?? "保存失败，请重试", style: .warning))
            }
        case .share:
            SharePresenter.present(session.exportedFiles.map(\.url)) { [weak self] activity, completed in
                guard completed, activity == .saveToCameraRoll else { return }
                self?.didSave(card, library: library, count: session.exportedFiles.count)
            }
        }
    }

    func choose(_ sizing: ExportSizing, for choice: SizeChoice, library: StitchLibrary) async {
        sizeChoice = nil
        await perform(choice.intent, on: choice.card, library: library, sizing: sizing)
    }

    private func didSave(_ card: StitchLibrary.Card, library: StitchLibrary, count: Int) {
        show(Toast(message: count > 1 ? "已存 \(count) 张到相册" : "已存到相册"))
        if asksToDeleteOriginals, library.canDeleteOriginals(of: card) {
            cleanupCard = card
        }
    }

    // MARK: Toasts

    /// Shows a toast; `onExpire` runs when it disappears without its action being used.
    func show(_ toast: Toast, action: (() -> Void)? = nil, onExpire: (() -> Void)? = nil) {
        toastExpiry?()
        toastTask?.cancel()
        withAnimation(.snappy) { self.toast = toast }
        toastAction = action
        toastExpiry = onExpire
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.actionTitle == nil ? 2.4 : 5))
            guard !Task.isCancelled else { return }
            self?.dismissToast()
        }
    }

    func runToastAction() {
        toastExpiry = nil
        toastAction?()
        dismissToast()
    }

    private func dismissToast() {
        toastExpiry?()
        toastExpiry = nil
        toastAction = nil
        withAnimation(.snappy) { toast = nil }
    }
}

/// Presents the system share sheet for exported files and reports how it ended.
enum SharePresenter {
    static func present(_ urls: [URL], completion: @escaping (UIActivity.ActivityType?, Bool) -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, _ in completion(activity, completed) }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 90, width: 1, height: 1)
        }
        top.present(controller, animated: true)
    }
}
