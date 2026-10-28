import SwiftUI
import AppKit
import LinkPlayerCore

// MARK: - App entry point

@main
struct LinkPlayerApp: App {

    /// Single composition root for the app. All dependencies are wired here
    /// (dependency injection); nothing else creates services globally.
    /// `nonisolated(unsafe)` lets the nonisolated `@main` init assign it;
    /// the value is immutable afterwards and only touched on the main actor.
    nonisolated(unsafe) private static var sharedContainer: AppContainer?
    static var container: AppContainer {
        if let sharedContainer { return sharedContainer }
        fatalError("AppContainer accessed before app initialization")
    }

    init() {
        let created = AppContainer()
        Self.sharedContainer = created
        // Inject the concrete view models into the SwiftUI tree once, at app start.
        ContentViewInjector.container = created
    }

    var body: some Scene {
        WindowGroup("LinkPlayer") {
            ContentView()
                .environmentObject(Self.container.playerViewModel)
                .environmentObject(Self.container.historyModel)
                .environmentObject(Self.container.settingsModel)
                .environmentObject(UIRouter.shared)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 860, height: 560)
        .commands {
            LinkPlayerCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(Self.container.settingsModel)
                .environmentObject(Self.container.historyModel)
        }
    }
}

/// Keeps a reference so auxiliary scenes (Settings) can inject environment objects.
@MainActor
enum ContentViewInjector {
    static var container: AppContainer?
}

// MARK: - Composition root

/// Owns the object graph and its lifetime.
@MainActor
final class AppContainer: ObservableObject {
    let settingsModel: SettingsModel
    let historyModel: HistoryModel
    let playerViewModel: PlayerViewModel

    private let appDelegate: AppDelegate

    init() {
        // Storage lives in Application Support — never inside the repo.
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
            .appendingPathComponent("LinkPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir,
                                                 withIntermediateDirectories: true)

        let store = JSONFileStore(directory: supportDir)
        let settingsManager = SettingsManager(store: store)
        let historyManager = HistoryManager(store: store)

        settingsModel = SettingsModel(manager: settingsManager)
        historyModel = HistoryModel(manager: historyManager)

        let engine = AVPlayerEngine()
        let coordinator = PlaybackCoordinator(validator: MediaURLValidator(policy: .standard),
                                             resolver: HTTPURLResolver(),
                                             player: engine,
                                             recorder: historyManager,
                                             settings: settingsManager)
        playerViewModel = PlayerViewModel(coordinator: coordinator,
                                          engine: engine,
                                          settings: settingsManager)

        appDelegate = AppDelegate()
        NSApplication.shared.delegate = appDelegate
        appDelegate.container = self

        // Wire launch behaviors and phase observation once the graph exists.
        PlayerLaunchHook.requestOpen = { [weak self] url in
            self?.playerViewModel.open(rawText: url)
        }
        Task { await applyLaunchBehavior() }
    }

    /// Honors the persisted "On launch" setting — every option has a real effect.
    func applyLaunchBehavior() async {
        await playerViewModel.startObservingPhaseChanges()
        let behavior = await settingsModel.launchBehaviorFromStore()
        switch behavior {
        case .showEmptyPlayer:
            break
        case .reopenLastItem:
            await historyModel.reopenLast()
        case .showHistory:
            UIRouter.shared.showHistory = true
        }
    }

    func shutdown() {
        Task { await playerViewModel.terminate() }
    }
}

// MARK: - AppKit delegate (open URLs from Finder/browser, quit cleanup)

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var container: AppContainer?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        Task { @MainActor in
            container?.playerViewModel.open(rawText: first.absoluteString)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        container?.shutdown()
    }
}
