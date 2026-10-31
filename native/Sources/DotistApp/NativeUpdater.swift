import AppKit
import DotistCore
import Sparkle

@MainActor
final class NativeUpdater: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    enum State { case idle, unconfigured, checking, upToDate, available, downloaded, downloading, installing, error }
    @Published private(set) var state: State = .idle
    @Published private(set) var version = ""
    @Published private(set) var notes = ""
    @Published private(set) var message = ""
    @Published private(set) var progress: Double?
    private let model: AppModel
    private var updater: SPUUpdater?
    private var decision: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var received: UInt64 = 0
    private var expected: UInt64 = 0
    private var manualInstall = false
    private var pendingChoice: SPUUserUpdateChoice?
    private var informationURL: URL?
    private var stagedAutomaticInstall = false
    private var cancellingAutomaticInstall = false
    private var cancellationReplied = false
    private var clearingCancelledSkip = false
    private var terminationReply: ((Bool) -> Void)?

    private func trace(_ event: String) {
        guard Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa",
              Bundle.main.object(forInfoDictionaryKey: "DotistQATestUpdateFeed") as? Bool == true,
              let directory = ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"] else { return }
        let path = URL(fileURLWithPath: directory).appendingPathComponent("update-events.log")
        let line = Data("\(Date().timeIntervalSince1970) \(event) state=\(state) staged=\(stagedAutomaticInstall) decision=\(decision != nil)\n".utf8)
        guard FileManager.default.fileExists(atPath: path.path) else { try? line.write(to: path); return }
        if let file = try? FileHandle(forWritingTo: path) {
            file.seekToEndOfFile(); file.write(line); file.closeFile()
        }
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed),
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let localTest = Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa"
            && Bundle.main.object(forInfoDictionaryKey: "DotistQATestUpdateFeed") as? Bool == true
            && url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? "")
        guard url.scheme == "https" || localTest else { return }
        let instance = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater = instance
        instance.updateCheckInterval = 24 * 60 * 60
        apply(model.settings)
        do {
            try instance.start()
            if localTest && Bundle.main.object(forInfoDictionaryKey: "DotistQATestCheckOnLaunch") as? Bool == true {
                instance.checkForUpdatesInBackground()
            }
        }
        catch { state = .error; message = error.localizedDescription }
    }

    var busy: Bool { state == .checking || state == .downloading || state == .installing }
    func apply(_ settings: DotistSettings) {
        guard let updater else { return }
        if updater.automaticallyChecksForUpdates != settings.autoCheckUpdates { updater.automaticallyChecksForUpdates = settings.autoCheckUpdates }
        if updater.automaticallyDownloadsUpdates != settings.autoInstallUpdates { updater.automaticallyDownloadsUpdates = settings.autoInstallUpdates }
        if !settings.autoInstallUpdates && stagedAutomaticInstall { cancelAutomaticInstall() }
    }
    func shouldDelayTermination(_ reply: @escaping (Bool) -> Void) -> Bool {
        guard !model.settings.autoInstallUpdates && (stagedAutomaticInstall || cancellingAutomaticInstall) else { return false }
        terminationReply = reply
        cancelAutomaticInstall()
        return true
    }
    private func cancelAutomaticInstall() {
        guard !cancellingAutomaticInstall, let updater else { return }
        cancellingAutomaticInstall = true
        cancellationReplied = false
        if let decision {
            self.decision = nil
            cancellationReplied = true
            decision(.skip)
        } else if updater.canCheckForUpdates { updater.checkForUpdates() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.cancellingAutomaticInstall else { return }
            self.cancellingAutomaticInstall = false
            self.state = .error
            self.message = self.model.text("无法取消已暂存的自动更新，请重试。")
            self.terminationReply?(false); self.terminationReply = nil
        }
    }
    func check() {
        guard let updater else { state = .unconfigured; return }
        guard updater.canCheckForUpdates else { return }
        manualInstall = false
        state = .checking; message = ""; progress = nil
        updater.checkForUpdates()
    }
    func install() {
        if let informationURL { NSWorkspace.shared.open(informationURL); return }
        manualInstall = true
        guard let decision else {
            guard let updater, updater.canCheckForUpdates else { return }
            pendingChoice = .install
            updater.checkForUpdates()
            return
        }
        self.decision = nil
        decision(.install)
    }
    func skip() {
        trace("skip requested")
        var patch = DotistSettingsPatch(); patch.skippedUpdateVersion = version
        model.updateSettings(patch)
        guard let decision else {
            guard let updater, updater.canCheckForUpdates else { return }
            pendingChoice = .skip
            // Resuming a staged install omits showUserInitiatedUpdateCheck.
            // Keep the cancellation busy until Sparkle dismisses its driver.
            state = .checking
            updater.checkForUpdates()
            return
        }
        self.decision = nil
        stagedAutomaticInstall = false
        decision(.skip)
        state = .idle
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: model.settings.autoCheckUpdates, automaticUpdateDownloading: NSNumber(value: model.settings.autoInstallUpdates), sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { trace("user check"); self.cancellation = cancellation; state = .checking }
    func showUpdateFound(with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        trace("found stage=\(updateState.stage.rawValue) user=\(updateState.userInitiated) pending=\(pendingChoice != nil)")
        version = appcastItem.displayVersionString
        if clearingCancelledSkip {
            if updateState.stage == .installing {
                clearingCancelledSkip = false
                cancellationReplied = true
                reply(.skip)
            } else {
                reply(.dismiss)
            }
            return
        }
        if cancellingAutomaticInstall {
            if updateState.stage == .installing { cancellationReplied = true; reply(.skip); return }
            if updateState.stage == .downloaded { cancellationReplied = true; reply(.dismiss); return }
        }
        if !updateState.userInitiated && model.settings.skippedUpdateVersion == version { reply(.skip); return }
        if let pendingChoice {
            self.pendingChoice = nil
            if pendingChoice == .skip { stagedAutomaticInstall = false }
            reply(pendingChoice)
            return
        }
        notes = appcastItem.itemDescription ?? ""
        informationURL = appcastItem.isInformationOnlyUpdate ? appcastItem.infoURL : nil
        decision = reply
        state = updateState.stage == .notDownloaded ? .available : .downloaded
        message = ""; progress = nil
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { notes = String(data: downloadData.data, encoding: .utf8) ?? notes }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { message = error.localizedDescription }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { state = .upToDate; message = ""; acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state = .error; message = error.localizedDescription; progress = nil
        if model.settings.autoInstallUpdates {
            var patch = DotistSettingsPatch(); patch.lastUpdateError = error.localizedDescription
            model.updateSettings(patch)
        }
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { self.cancellation = cancellation; received = 0; expected = 0; progress = nil; state = .downloading }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) { received += length; if expected > 0 { progress = min(1, Double(received) / Double(expected)) } }
    func showDownloadDidStartExtractingUpdate() { progress = nil; state = .downloading }
    func showExtractionReceivedProgress(_ progress: Double) { self.progress = progress }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        progress = nil
        if manualInstall { state = .installing; reply(.install); return }
        state = .downloaded
        stagedAutomaticInstall = true
        decision = reply
        if !model.settings.autoInstallUpdates { cancelAutomaticInstall() }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { state = .installing }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        state = .upToDate
        if !model.settings.lastUpdateError.isEmpty { var patch = DotistSettingsPatch(); patch.lastUpdateError = ""; model.updateSettings(patch) }
        acknowledgement()
    }
    func dismissUpdateInstallation() { trace("dismiss"); cancellation = nil; decision = nil; progress = nil; if busy { state = .idle } }

    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        version = item.displayVersionString
        stagedAutomaticInstall = true
        state = .downloaded
        if !model.settings.autoInstallUpdates { DispatchQueue.main.async { [weak self] in self?.cancelAutomaticInstall() } }
        return false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor check: SPUUpdateCheck, error: Error?) {
        trace("finished error=\(error != nil)")
        guard cancellingAutomaticInstall else { return }
        if clearingCancelledSkip {
            clearingCancelledSkip = false; cancellingAutomaticInstall = false
            state = error == nil ? .idle : .error
            if let error { message = error.localizedDescription }
            terminationReply?(true); terminationReply = nil
            return
        }
        if cancellationReplied && error == nil {
            stagedAutomaticInstall = false; cancellationReplied = false
            // Sparkle's skip choice cancels a staged install but also suppresses
            // future automatic checks for that version. A user-initiated check
            // clears that skip; dismiss its result without installing anything.
            clearingCancelledSkip = true
            if updater.canCheckForUpdates { updater.checkForUpdates() }
            return
        }
        if !cancellationReplied && updater.canCheckForUpdates { updater.checkForUpdates() }
    }
}
