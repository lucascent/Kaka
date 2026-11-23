#if DEBUG || KAKA_BENCHMARK
import CoreGraphics
import Foundation
import ImageIO
import StitchCore
import StitchWorkflow

/// Development-only library that presents the bundled synthetic fixtures as recent screenshots.
/// Launch with `-demo` to try the home screen without touching the real photo library.
actor DemoPhotoLibrary: PhotoLibraryProviding {
    private struct Item: Sendable {
        let asset: ScreenshotAsset
        let url: URL
    }

    private var items: [Item] = []

    init(now: Date = Date(), mixedOnly: Bool = false) {
        // (scene, minutes ago, screenshot numbers in the order they were "taken")
        let mixed = [("chat", 2.4, [1]), ("list", 2.2, [1]), ("article", 2.0, [1, 2])]
        let sets: [(String, Double, [Int])] = mixed + (mixedOnly ? [] : [
            ("chat", 22, [1, 2, 3]),
            ("list", 50, [3, 2, 1]),
            ("chat", 180, [1, 3]),
            ("article", 26 * 60, [1, 2, 3])
        ])
        var items: [Item] = []
        for (setIndex, (scene, minutes, numbers)) in sets.enumerated() {
            for (position, number) in numbers.enumerated() {
                guard let url = Bundle.main.url(forResource: String(format: "screenshot_%02d", number),
                                                withExtension: "png", subdirectory: "Fixtures/\(scene)") else { continue }
                let date = now.addingTimeInterval(-minutes * 60 + Double(position) * 6)
                let asset = ScreenshotAsset(id: "demo-\(setIndex)-\(scene)-\(number)",
                                            size: PixelSize(width: 780, height: 1688), createdAt: date)
                items.append(Item(asset: asset, url: url))
            }
        }
        self.items = items
    }

    func permissions() -> PhotoPermissions { PhotoPermissions(read: .authorized, add: .authorized) }
    func requestScreenshotAccess() -> PhotoPermissions { permissions() }
    func requestSaveAccess() -> PhotoPermissions { permissions() }

    func recentScreenshots(since: Date, limit: Int) -> [ScreenshotAsset] {
        items.map(\.asset)
            .filter { ($0.createdAt ?? .distantPast) >= since }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    func importAssets(_ assets: [ScreenshotAsset], to directory: URL, progress: ProgressHandler?) throws -> [ScreenshotInput] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try assets.enumerated().map { index, asset in
            guard let item = items.first(where: { $0.asset.id == asset.id }) else { throw StitchFailure(.importUnavailable) }
            let target = directory.appendingPathComponent(UUID().uuidString + ".png")
            try FileManager.default.copyItem(at: item.url, to: target)
            progress?(ProcessingProgress(stage: .importing, completed: index + 1, total: assets.count))
            return ScreenshotInput(fileURL: target, size: try ImageFiles.metadata(target), createdAt: asset.createdAt)
        }
    }

    func thumbnail(for asset: ScreenshotAsset, maxDimension: Int) -> CGImage? {
        guard let item = items.first(where: { $0.asset.id == asset.id }),
              let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func save(_ files: [ExportedFile]) {}

    func deleteAssets(_ identifiers: [String]) -> Bool {
        items.removeAll { identifiers.contains($0.asset.id) }
        return true
    }
}
#endif

#if KAKA_BENCHMARK
import Darwin
import UIKit

/// Release performance builds opt in with -measure-launch. Timestamp the first two display
/// refreshes after the first decoded result tile appears, relative to the OS process start.
@MainActor final class LaunchMeasurement: NSObject {
    static let shared = LaunchMeasurement()
    private var frames = 0
    private var started: TimeInterval?

    func appStarted() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-measure-launch") else { return }
        #if targetEnvironment(simulator)
        // A normal SpringBoard launch avoids the overhead of an attached console.
        if let flag = arguments.firstIndex(of: "-measure-sim-log"), arguments.indices.contains(flag + 1),
           let trial = UUID(uuidString: arguments[flag + 1]) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(trial.uuidString + ".log")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
            if fd >= 0 { _ = dup2(fd, STDOUT_FILENO); close(fd) }
        }
        #endif
        var info = kinfo_proc()
        var size = MemoryLayout.size(ofValue: info)
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return }
        let value = info.kp_proc.p_un.__p_starttime
        started = Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        if let started {
            let ms = (Date().timeIntervalSince1970 - started) * 1000
            FileHandle.standardOutput.write(Data(String(format: "KAKA_STAGE Process to app init %.2f\n", ms).utf8))
        }
    }

    func firstTile(_ url: URL?) {
        guard started != nil, frames == 0, let name = url?.lastPathComponent,
              name.hasPrefix("preview-"), name.hasSuffix("-1.jpg") else { return }
        frames = 1
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
    }

    @objc private func frame(_ link: CADisplayLink) {
        frames += 1
        guard frames == 3, let started else { return }
        link.invalidate()
        let milliseconds = (Date().timeIntervalSince1970 - started) * 1000
        FileHandle.standardOutput.write(Data(String(format: "KAKA_FIRST_TILE_MS %.1f\n", milliseconds).utf8))
    }
}
#endif
