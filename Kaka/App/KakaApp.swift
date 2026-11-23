import StitchWorkflow
import SwiftUI

@main
struct KakaApp: App {
    @AppStorage(Preferences.appLanguage) private var language: AppLanguage = .system
    @State private var library: StitchLibrary
    @State private var actions = ResultActions()
    @State private var needsForegroundRefresh = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if KAKA_BENCHMARK
        LaunchMeasurement.shared.appStarted()
        #endif
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kaka-Library")
        // Unlinking many previews can outlast the first match. Retire last launch's work
        // atomically and reclaim its files away from the startup path.
        let retired = directory.deletingLastPathComponent().appendingPathComponent("Kaka-Retired-" + UUID().uuidString)
        try? FileManager.default.moveItem(at: directory, to: retired)
        Task.detached(priority: .background) {
            let files = FileManager.default
            let temporary = directory.deletingLastPathComponent()
            let entries = (try? files.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.lastPathComponent.hasPrefix("Kaka-Retired-") {
                try? files.removeItem(at: entry)
            }
        }
        let library = Self.makeLibrary(in: directory)
        _library = State(initialValue: library)
        Task { await library.refresh(prepareFirst: true) }
    }

    private static func makeLibrary(in directory: URL) -> StitchLibrary {
        #if DEBUG || KAKA_BENCHMARK
        let mixed = ProcessInfo.processInfo.arguments.contains("-demo-mixed")
        if mixed || ProcessInfo.processInfo.arguments.contains("-demo") {
            return StitchLibrary(photoLibrary: DemoPhotoLibrary(mixedOnly: mixed),
                                 hiddenStore: MemoryHiddenScreenshots(), workingDirectory: directory)
        }
        #endif
        return StitchLibrary(photoLibrary: PhotoLibraryService(), hiddenStore: UserDefaultsHiddenScreenshots(),
                             workingDirectory: directory)
    }

    var body: some Scene {
        let selectedLocale = language.locale
        WindowGroup {
            HomeView()
                .environment(library)
                .environment(actions)
                .transformEnvironment(\.locale) { locale in
                    if let selectedLocale { locale = selectedLocale }
                }
                .tint(Theme.accent)
                .onChange(of: scenePhase) { old, phase in
                    if old == .active { needsForegroundRefresh = true }
                    if phase == .active && needsForegroundRefresh {
                        needsForegroundRefresh = false
                        Task { await library.refresh(prepareFirst: library.cards.isEmpty) }
                    }
                }
        }
    }
}
