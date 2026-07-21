import AppKit
import Combine
import Foundation

enum AgentProvider: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var assetName: String {
        switch self {
        case .codex: return "codex-pet"
        case .claude: return "claude-mascot"
        }
    }
}

enum AgentPhase: String, Codable, CaseIterable, Identifiable {
    case idle
    case thinking
    case question
    case complete

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idle: return "IDLE"
        case .thinking: return "THINKING"
        case .question: return "NEEDS INPUT"
        case .complete: return "COMPLETE"
        }
    }

    var statusAccentHex: UInt32 {
        switch self {
        case .idle: return 0x8A8F87
        case .thinking: return 0x6FA9D8
        case .question: return 0xE2A44F
        case .complete: return 0x9CDC7C
        }
    }
}

enum IslandTab: String, CaseIterable, Identifiable {
    case agents
    case shelf
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agents: return "Agents"
        case .shelf: return "Shelf"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .agents: return "square.stack.3d.up.fill"
        case .shelf: return "tray.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct IslandSize: Equatable {
    let width: CGFloat
    let height: CGFloat

    var cgSize: CGSize { CGSize(width: width, height: height) }
}

struct NotchPresentation: Equatable {
    let cameraWidth: CGFloat
    let barHeight: CGFloat
    let compactWidth: CGFloat
}

struct AgentSnapshot: Decodable {
    let type: String
    let provider: AgentProvider
    let state: AgentPhase
    let task: String
    let detail: String
    let elapsedSeconds: Int
    let pid: Int?
    let contextUsedTokens: Int64?
    let contextWindowTokens: Int64?
    let sessionTotalTokens: Int64?
    let rateLimitUsedPercent: Double?
    let rateLimitResetsAt: Int64?
    let rateLimitWindowMinutes: Int64?
    let usageSource: String?
    let usageExact: Bool?
    let activityLog: [String]?
    let changedFiles: [String]?
    let activeSessionCount: Int?
    let codexSessionCount: Int?
    let claudeSessionCount: Int?
    let workspacePath: String?
    let modelName: String?
    let reasoningEffort: String?
    let latestPrompt: String?
    let selectedSessionId: String?
    let detectedProcessCount: Int?
    let sessions: [AgentSessionSnapshot]?
    let pendingQuestion: PendingQuestion?
}

struct PendingQuestion: Decodable, Equatable {
    let prompt: String
    let header: String?
    let options: [PendingQuestionOption]
}

struct PendingQuestionOption: Decodable, Equatable, Identifiable {
    let label: String
    let description: String?

    var id: String { label }
}

struct AgentSessionSnapshot: Decodable, Identifiable, Equatable {
    let id: String
    let provider: AgentProvider
    let state: AgentPhase
    let task: String
    let detail: String
    let updatedSecondsAgo: Int
    let contextUsedTokens: Int64?
    let contextWindowTokens: Int64?
    let sessionTotalTokens: Int64?
    let rateLimitUsedPercent: Double?
    let rateLimitResetsAt: Int64?
    let rateLimitWindowMinutes: Int64?
    let usageSource: String?
    let usageExact: Bool?
    let activityLog: [String]?
    let changedFiles: [String]?
    let workspacePath: String?
    let modelName: String?
    let reasoningEffort: String?
    let latestPrompt: String?
    let pendingQuestion: PendingQuestion?

    var accentHex: UInt32 {
        provider == .codex ? 0x9480D8 : 0xE58A62
    }

    var projectName: String {
        guard let workspacePath else { return "Unknown project" }
        let name = URL(fileURLWithPath: workspacePath).lastPathComponent
        return name.isEmpty ? workspacePath : name
    }

    var shortID: String {
        let suffix = id.suffix(8)
        return suffix.isEmpty ? "session" : String(suffix)
    }

    var displayModelName: String? {
        guard let modelName, !modelName.isEmpty else { return nil }
        let lowercased = modelName.lowercased()
        if provider == .codex, lowercased.hasPrefix("gpt-") {
            return "GPT-" + lowercased.dropFirst(4).uppercased()
        }
        if provider == .claude, lowercased.hasPrefix("claude-") {
            return lowercased
                .dropFirst("claude-".count)
                .split(separator: "-")
                .map { component in
                    component.allSatisfy(\.isNumber)
                        ? String(component)
                        : component.prefix(1).uppercased() + String(component.dropFirst())
                }
                .joined(separator: " ")
        }
        return modelName.uppercased()
    }

    var displayReasoningEffort: String? {
        reasoningEffort?.uppercased()
    }

    var effortAccentHex: UInt32? {
        switch reasoningEffort?.lowercased() {
        case "none": return 0x8A8F87
        case "minimal": return 0x69A8A0
        case "low": return 0x6E9FCB
        case "medium": return 0xD2B15F
        case "high": return 0xE58A62
        case "xhigh": return 0xC77DCD
        case "max": return 0xED6FA7
        default: return nil
        }
    }

    var modelDetailText: String {
        [provider.displayName, displayModelName, displayReasoningEffort]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var contextPercent: Double? {
        guard let contextUsedTokens, let contextWindowTokens, contextWindowTokens > 0 else {
            return nil
        }
        return min(max(Double(contextUsedTokens) / Double(contextWindowTokens) * 100, 0), 100)
    }

    var activityAgeText: String {
        if updatedSecondsAgo < 60 { return "<1m" }
        if updatedSecondsAgo < 3_600 { return "\(updatedSecondsAgo / 60)m" }
        if updatedSecondsAgo < 86_400 { return "\(updatedSecondsAgo / 3_600)h" }
        return "\(updatedSecondsAgo / 86_400)d"
    }
}

@MainActor
final class IslandModel: ObservableObject {
    // Hover-timing settings, editable from the in-island gear panel and persisted
    // across launches. Delays are the pause before the island opens on hover-in
    // and the pause before it collapses on hover-out.
    static let hoverOpenDelayKey = "hoverOpenDelay"
    static let hoverCloseDelayKey = "hoverCloseDelay"
    static let defaultHoverOpenDelay: TimeInterval = 0
    static let defaultHoverCloseDelay: TimeInterval = 0.6
    static let openDelayPresets: [TimeInterval] = [0, 0.2, 0.4, 0.6, 1.0]
    static let closeDelayPresets: [TimeInterval] = [0.2, 0.4, 0.6, 1.0, 1.5]
    // Volume tug-of-war HUD. The pop-up is on by default (it needs no
    // permission); the peek forces the island briefly open on a volume change.
    static let volumePopupEnabledKey = "volumePopupEnabled"
    static let defaultVolumePopupEnabled = true
    static let volumePeekDuration: TimeInterval = 1.5
    // Music visualizer. Ships OFF because enabling it requests the system
    // audio-capture permission; the user must opt in from Settings.
    static let musicVisualizerEnabledKey = "musicVisualizerEnabled"
    static let defaultMusicVisualizerEnabled = false
    /// Body height reserved for the volume HUD *below* the always-overlaid compact
    /// header — covers the "VOLUME" label, the mascot/bar row, the percent readout,
    /// and ExpandedIslandView's HUD padding, with margin.
    static let volumeHUDContentHeight: CGFloat = 76
    /// Fixed content heights for the non-list tabs, kept in sync with the tab
    /// views' own frames. The Agents tab sizes to its session list instead.
    static let shelfTabContentHeight: CGFloat = 114
    static let settingsTabContentHeight: CGFloat = 152
    static let soundwaveStripHeight: CGFloat = 34

    private let defaults: UserDefaults

    let temporaryFileShelf = TemporaryFileShelf()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.hoverOpenDelayKey) != nil {
            hoverOpenDelay = defaults.double(forKey: Self.hoverOpenDelayKey)
        }
        if defaults.object(forKey: Self.hoverCloseDelayKey) != nil {
            hoverCloseDelay = defaults.double(forKey: Self.hoverCloseDelayKey)
        }
        if defaults.object(forKey: Self.volumePopupEnabledKey) != nil {
            volumePopupEnabled = defaults.bool(forKey: Self.volumePopupEnabledKey)
        }
        if defaults.object(forKey: Self.musicVisualizerEnabledKey) != nil {
            musicVisualizerEnabled = defaults.bool(forKey: Self.musicVisualizerEnabledKey)
        }
    }

    @Published var provider: AgentProvider = .codex
    @Published var phase: AgentPhase = .thinking
    @Published var task = "Refactoring checkout flow"
    @Published var detail = "Updating Checkout.swift to use the new state machine"
    @Published var elapsedSeconds = 138
    @Published var isHovered = false
    @Published var isFileDragTargeted = false
    @Published var isPinnedOpen = false
    @Published var isQuestionPeeking = false
    @Published var isVolumePeeking = false
    @Published private(set) var outputVolumeLevel: Float = 0
    @Published private(set) var volumeTugDirection: TugDirection = .none
    @Published var volumePopupEnabled: Bool = IslandModel.defaultVolumePopupEnabled {
        didSet { defaults.set(volumePopupEnabled, forKey: Self.volumePopupEnabledKey) }
    }
    @Published var musicVisualizerEnabled: Bool = IslandModel.defaultMusicVisualizerEnabled {
        didSet { defaults.set(musicVisualizerEnabled, forKey: Self.musicVisualizerEnabledKey) }
    }
    @Published private(set) var isAudioPlaying = false
    /// Deliberately not `@Published` on the model: bar values change ~30 times a
    /// second, which would invalidate every view observing `IslandModel`.
    let spectrumStore = SpectrumStore()
    @Published var selectedTab: IslandTab = .agents
    @Published var hoverOpenDelay: TimeInterval = IslandModel.defaultHoverOpenDelay {
        didSet { defaults.set(hoverOpenDelay, forKey: Self.hoverOpenDelayKey) }
    }
    @Published var hoverCloseDelay: TimeInterval = IslandModel.defaultHoverCloseDelay {
        didSet { defaults.set(hoverCloseDelay, forKey: Self.hoverCloseDelayKey) }
    }
    @Published var isVisible = true
    @Published private(set) var animationsEnabled = true
    @Published var monitoringEnabled = true
    @Published var selectedAnswer = "Guest checkout"
    @Published var filesRead = 6
    @Published var filesChanged = 2
    @Published var contextUsedTokens: Int64?
    @Published var contextWindowTokens: Int64?
    @Published var sessionTotalTokens: Int64?
    @Published var rateLimitUsedPercent: Double?
    @Published var rateLimitResetsAt: Int64?
    @Published var rateLimitWindowMinutes: Int64?
    @Published var usageSource: String?
    @Published var usageExact = false
    @Published var activityLog = [
        "Started a new task",
        "Read Checkout.swift",
        "Changed Checkout.swift",
        "Running verification"
    ]
    @Published var changedFiles = ["Checkout.swift"]
    @Published var activeSessionCount = 1
    @Published var codexSessionCount = 1
    @Published var claudeSessionCount = 0
    @Published var trackedPID: Int?
    @Published var workspacePath: String?
    @Published var modelName: String?
    @Published var reasoningEffort: String?
    @Published var latestPrompt: String?
    @Published var pendingQuestion: PendingQuestion?
    @Published var sessions: [AgentSessionSnapshot] = []
    @Published var selectedSessionID: String?
    @Published var expandedSessionID: String?
    @Published var detectedProcessCount = 0
    @Published private(set) var notchPresentation: NotchPresentation?

    let answers = [
        ("Guest checkout", "Let customers pay without creating an account"),
        ("Require account", "Ask customers to sign in before payment"),
        ("Use current behavior", "Keep the existing flow unchanged")
    ]

    var layoutDidChange: (() -> Void)?
    var visibilityDidChange: (() -> Void)?
    var phaseDidChange: ((AgentPhase, AgentPhase) -> Void)?
    var sessionDidChange: ((AgentSessionSnapshot, AgentPhase) -> Void)?
    var visualizerEnabledDidChange: ((Bool) -> Void)?

    /// How long a newly arrived question keeps the island expanded before it
    /// collapses back to the compact notch (which still shows the "Input" accent).
    static let questionPeekDuration: TimeInterval = 6
    private var questionPeekTimer: Timer?
    private var volumePeekTimer: Timer?

    var isExpanded: Bool {
        isHovered || isPinnedOpen || isFileDragTargeted || isQuestionPeeking || isVolumePeeking
    }

    /// The volume HUD takes over the expanded panel only while its transient peek
    /// is the *sole* reason the island is open; a real hover/pin/drag shows the
    /// normal content instead.
    var isShowingVolumeHUD: Bool {
        isVolumePeeking && !isHovered && !isPinnedOpen && !isFileDragTargeted
    }

    /// The now-playing equalizer shows while the visualizer is enabled and audio
    /// is actually playing.
    var isShowingSoundwave: Bool {
        musicVisualizerEnabled && isAudioPlaying
    }

    /// On a notch Mac the equalizer lives in the notch's right wing, always
    /// visible. Without a notch there is no wing, so it falls back to a strip
    /// inside the expanded dashboard.
    var isShowingSoundwaveStrip: Bool {
        isShowingSoundwave && !isNotchAttached
    }

    var liveSessionListHeight: CGFloat {
        let rowCount = CGFloat(sessions.count)
        guard rowCount > 0 else { return 0 }

        // A closed dashboard follows its rows instead of reserving a large empty
        // viewport. An open inspector gets the full private scrolling viewport so
        // its detail card remains usable without making the island grow forever.
        if expandedSessionID != nil {
            return 275
        }
        let rowsHeight = rowCount * 54
        let spacingHeight = max(rowCount - 1, 0) * 6
        return min(rowsHeight + spacingHeight, 275)
    }

    private var tabContentHeight: CGFloat {
        switch selectedTab {
        case .agents: return liveSessionListHeight
        case .shelf: return Self.shelfTabContentHeight
        case .settings: return Self.settingsTabContentHeight
        }
    }

    private var liveDashboardHeight: CGFloat {
        // Chrome around the active tab, kept in sync with LiveSessionDashboard:
        // ExpandedIslandView's 10-point top + 12-point bottom padding, a 30-point
        // tab bar, a 12-point footer, and two 8-point gaps = 80 points. Only the
        // selected tab's content is shown, so the island sizes to that tab.
        persistentHeaderSize.height + 80 + tabContentHeight
            + (isShowingSoundwaveStrip ? Self.soundwaveStripHeight : 0)
    }

    /// The volume HUD panel: wide enough to fully contain the compact header that
    /// stays overlaid on top, and tall enough for that header plus the HUD body.
    var volumeHUDSize: IslandSize {
        IslandSize(
            width: max(360, persistentHeaderSize.width),
            height: persistentHeaderSize.height + Self.volumeHUDContentHeight
        )
    }

    var preferredSize: IslandSize {
        if isShowingVolumeHUD {
            return volumeHUDSize
        }

        if let notchPresentation {
            if isExpanded {
                if monitoringEnabled, !sessions.isEmpty {
                    return IslandSize(width: 610, height: liveDashboardHeight)
                }

                switch phase {
                case .idle: return IslandSize(width: 470, height: 210)
                case .thinking: return IslandSize(width: 560, height: 350)
                case .question: return IslandSize(width: 560, height: 320)
                case .complete: return IslandSize(width: 560, height: 334)
                }
            }

            // The compact island stays at its full wing width even when idle so it
            // reads as a present pill rather than vanishing into the physical notch.
            return IslandSize(
                width: notchPresentation.compactWidth,
                height: notchPresentation.barHeight
            )
        }

        if monitoringEnabled, !sessions.isEmpty {
            return isExpanded
                ? IslandSize(width: 610, height: liveDashboardHeight)
                : IslandSize(width: 500, height: 56)
        }

        if isExpanded {
            switch phase {
            case .idle: return IslandSize(width: 470, height: 210)
            case .thinking: return IslandSize(width: 560, height: 350)
            case .complete: return IslandSize(width: 560, height: 334)
            case .question: return IslandSize(width: 560, height: 320)
            }
        }

        // A dismissed question collapses to the compact pill, which still carries
        // the question accent, instead of staying locked at full height.
        switch phase {
        case .idle: return IslandSize(width: 190, height: 38)
        case .thinking, .complete, .question: return IslandSize(width: 430, height: 56)
        }
    }

    var persistentHeaderSize: IslandSize {
        if let notchPresentation {
            return IslandSize(
                width: notchPresentation.compactWidth,
                height: notchPresentation.barHeight
            )
        }

        if monitoringEnabled, !sessions.isEmpty {
            return IslandSize(width: 500, height: 56)
        }

        switch phase {
        case .idle:
            return IslandSize(width: 190, height: 38)
        case .thinking, .question, .complete:
            return IslandSize(width: 430, height: 56)
        }
    }

    var selectedSession: AgentSessionSnapshot? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    var isNotchAttached: Bool {
        notchPresentation != nil
    }

    var aggregatePhase: AgentPhase {
        guard monitoringEnabled, !sessions.isEmpty else { return phase }
        if sessions.contains(where: { $0.state == .question }) { return .question }
        if sessions.contains(where: { $0.state == .thinking }) { return .thinking }
        if sessions.contains(where: { $0.state == .complete }) { return .complete }
        return .idle
    }

    var aggregateStatusText: String {
        switch aggregatePhase {
        case .idle: return sessions.isEmpty ? "Waiting" : "Sessions resting"
        case .thinking: return sessions.count > 1 ? "Agents working" : "Working"
        case .question: return "Needs your input"
        case .complete: return sessions.count > 1 ? "Work completed" : "Complete"
        }
    }

    var accentHex: UInt32 {
        provider == .codex ? 0x9480D8 : 0xE58A62
    }

    var sessionSummaryText: String? {
        guard activeSessionCount > 1 else { return nil }
        return "\(activeSessionCount) SESSIONS"
    }

    var providerSessionSummary: String {
        let codex = "\(codexSessionCount) Codex"
        let claude = "\(claudeSessionCount) Claude"
        return "\(codex)  ·  \(claude)  ·  following latest activity"
    }

    var elapsedText: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var contextPercent: Double? {
        guard let used = contextUsedTokens,
              let window = contextWindowTokens,
              window > 0 else { return nil }
        return min(max(Double(used) / Double(window) * 100, 0), 100)
    }

    var contextPercentText: String? {
        contextPercent.map { "\(Int($0.rounded()))% ctx" }
    }

    var rateWindowLabel: String? {
        guard let minutes = rateLimitWindowMinutes, minutes > 0 else { return nil }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080)W" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)D" }
        if minutes % 60 == 0 { return "\(minutes / 60)H" }
        return "\(minutes)M"
    }

    var resetText: String? {
        guard let timestamp = rateLimitResetsAt else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        if resetDate <= Date() { return "now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: resetDate, relativeTo: Date())
    }

    func formattedTokens(_ tokens: Int64?) -> String {
        guard let tokens else { return "—" }
        let value = Double(tokens)
        if value >= 1_000_000 {
            return String(format: value >= 10_000_000 ? "%.1fM" : "%.2fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: value >= 100_000 ? "%.0fK" : "%.1fK", value / 1_000)
        }
        return "\(tokens)"
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        // A real hover takes over from the transient auto-open so that moving the
        // cursor away collapses the island through the normal hover-close path.
        if hovered {
            endQuestionPeek()
            endVolumePeek()
        }
        layoutDidChange?()
    }

    func setFileDragTargeted(_ targeted: Bool) {
        guard isFileDragTargeted != targeted else { return }
        isFileDragTargeted = targeted
        // A starting drag takes over from a transient volume peek, so ending the drag
        // collapses through the normal path instead of resurfacing the HUD.
        if targeted { endVolumePeek() }
        layoutDidChange?()
    }

    /// Announce a newly arrived question by expanding the island, then collapse it
    /// back to the compact notch after `questionPeekDuration` unless the user hovers
    /// or pins in the meantime. The question stays visible in the notch's accent.
    func beginQuestionPeek() {
        questionPeekTimer?.invalidate()
        isQuestionPeeking = true
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.questionPeekDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.endQuestionPeek() }
        }
        questionPeekTimer = timer
        layoutDidChange?()
    }

    func endQuestionPeek() {
        questionPeekTimer?.invalidate()
        questionPeekTimer = nil
        guard isQuestionPeeking else { return }
        isQuestionPeeking = false
        layoutDidChange?()
    }

    /// A volume change pops the island open into the tug-of-war HUD, then lets it
    /// auto-collapse after `volumePeekDuration`. Ignored when the pop-up is off or
    /// the change has no up/down direction (e.g. a same-level re-notification).
    func handleVolumeChange(level: Float, delta: Float) {
        guard volumePopupEnabled else { return }
        let direction = volumeTug(delta: delta)
        guard direction != .none else { return }
        // Don't raise the transient HUD while the user is already engaged with the
        // island (hover / pin / file-drag): it would be masked now and then leak in
        // as stale content when that interaction ends within the peek window.
        guard !isHovered, !isPinnedOpen, !isFileDragTargeted else { return }
        outputVolumeLevel = min(max(level, 0), 1)
        volumeTugDirection = direction
        beginVolumePeek()
    }

    func beginVolumePeek() {
        volumePeekTimer?.invalidate()
        isVolumePeeking = true
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.volumePeekDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.endVolumePeek() }
        }
        volumePeekTimer = timer
        layoutDidChange?()
    }

    func endVolumePeek() {
        volumePeekTimer?.invalidate()
        volumePeekTimer = nil
        guard isVolumePeeking else { return }
        isVolumePeeking = false
        layoutDidChange?()
    }

    func setVolumePopupEnabled(_ value: Bool) {
        guard volumePopupEnabled != value else { return }
        volumePopupEnabled = value
        if !value { endVolumePeek() }
    }

    func setMusicVisualizerEnabled(_ value: Bool) {
        guard musicVisualizerEnabled != value else { return }
        musicVisualizerEnabled = value
        visualizerEnabledDidChange?(value)
    }

    func setPhase(_ nextPhase: AgentPhase, manual: Bool = true) {
        if manual { monitoringEnabled = false }
        let wasQuestion = phase == .question
        phase = nextPhase
        if nextPhase == .question, !wasQuestion {
            beginQuestionPeek()
        }

        switch nextPhase {
        case .idle:
            task = "No active agent sessions"
            detail = "Start Codex or Claude and the session will appear here."
        case .thinking:
            task = provider == .codex ? "Refactoring checkout flow" : "Tracing the payment failure"
            detail = provider == .codex
                ? "Updating Checkout.swift to use the new state machine"
                : "Inspecting payment.swift and following the retry path"
            activityLog = provider == .codex
                ? ["Started a new task", "Read Checkout.swift", "Changed Checkout.swift", "Running verification"]
                : ["Started a new task", "Read payment.swift", "Changed payment.swift", "Checking the retry path"]
            changedFiles = provider == .codex ? ["Checkout.swift"] : ["payment.swift"]
        case .question:
            task = "One question before I continue"
            detail = "Which checkout behavior should I use?"
        case .complete:
            task = "Changes are ready to review"
            detail = "Checkout flow refactored with predictable loading, error, and success states."
        }

        if manual, nextPhase != .idle, contextUsedTokens == nil {
            applyPreviewUsage()
        }

        layoutDidChange?()
    }

    func setProvider(_ nextProvider: AgentProvider, manual: Bool = true) {
        if manual { monitoringEnabled = false }
        provider = nextProvider
        if phase == .thinking {
            task = nextProvider == .codex ? "Refactoring checkout flow" : "Tracing the payment failure"
            detail = nextProvider == .codex
                ? "Updating Checkout.swift to use the new state machine"
                : "Inspecting payment.swift and following the retry path"
            activityLog = nextProvider == .codex
                ? ["Started a new task", "Read Checkout.swift", "Changed Checkout.swift", "Running verification"]
                : ["Started a new task", "Read payment.swift", "Changed payment.swift", "Checking the retry path"]
            changedFiles = nextProvider == .codex ? ["Checkout.swift"] : ["payment.swift"]
        }
    }

    func submitAnswer() {
        monitoringEnabled = false
        phase = .thinking
        isPinnedOpen = false
        endQuestionPeek()
        task = "Continuing with \(selectedAnswer.lowercased())"
        detail = "Applying your answer and updating the implementation"
        layoutDidChange?()
    }

    func resumeAutomaticMonitoring() {
        monitoringEnabled = true
    }

    func togglePinned() {
        isPinnedOpen.toggle()
        // Pinning is an explicit decision; drop any transient question or volume
        // auto-open so pin state alone governs expansion from here.
        if isPinnedOpen {
            endQuestionPeek()
            endVolumePeek()
        }
        layoutDidChange?()
    }

    func selectTab(_ tab: IslandTab) {
        guard selectedTab != tab else { return }
        selectedTab = tab
        // Tabs have different heights, so resize the panel to fit the new one.
        layoutDidChange?()
    }

    func setHoverOpenDelay(_ value: TimeInterval) {
        guard hoverOpenDelay != value else { return }
        hoverOpenDelay = value
    }

    func setHoverCloseDelay(_ value: TimeInterval) {
        guard hoverCloseDelay != value else { return }
        hoverCloseDelay = value
    }

    func toggleVisibility() {
        isVisible.toggle()
        visibilityDidChange?()
    }

    func setAnimationsEnabled(_ enabled: Bool) {
        guard animationsEnabled != enabled else { return }
        animationsEnabled = enabled
    }

    func setNotchPresentation(_ presentation: NotchPresentation?) {
        guard notchPresentation != presentation else { return }
        notchPresentation = presentation
    }

    func toggleSessionInspector(_ id: String) {
        guard monitoringEnabled,
              let session = sessions.first(where: { $0.id == id }) else { return }
        let shouldClose = expandedSessionID == id
        if selectedSessionID != id {
            selectedSessionID = id
            applySession(session)
        }
        expandedSessionID = shouldClose ? nil : id
        layoutDidChange?()
    }

    func apply(_ snapshot: AgentSnapshot) {
        guard monitoringEnabled, snapshot.type == "snapshot" else { return }
        let previousPhase = phase
        let previousSessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
        sessions = snapshot.sessions ?? []
        if let expandedSessionID,
           !sessions.contains(where: { $0.id == expandedSessionID }) {
            self.expandedSessionID = nil
        }
        detectedProcessCount = max(snapshot.detectedProcessCount ?? 0, 0)
        let newlyActionableSession = sessions.first {
            $0.state == .question && previousSessions[$0.id] != .question
        }

        if let newlyActionableSession {
            selectedSessionID = newlyActionableSession.id
            expandedSessionID = newlyActionableSession.id
        } else if let selectedSessionID, sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = selectedSessionID
        } else {
            selectedSessionID = snapshot.selectedSessionId ?? sessions.first?.id
        }

        if let selectedSession {
            applySession(selectedSession)
        } else {
            provider = snapshot.provider
            phase = snapshot.state
            task = snapshot.task
            detail = snapshot.detail
            elapsedSeconds = snapshot.elapsedSeconds
            contextUsedTokens = snapshot.contextUsedTokens
            contextWindowTokens = snapshot.contextWindowTokens
            sessionTotalTokens = snapshot.sessionTotalTokens
            rateLimitUsedPercent = snapshot.rateLimitUsedPercent
            rateLimitResetsAt = snapshot.rateLimitResetsAt
            rateLimitWindowMinutes = snapshot.rateLimitWindowMinutes
            usageSource = snapshot.usageSource
            usageExact = snapshot.usageExact ?? false
            workspacePath = snapshot.workspacePath
            modelName = snapshot.modelName
            reasoningEffort = snapshot.reasoningEffort
            latestPrompt = snapshot.latestPrompt
            pendingQuestion = snapshot.pendingQuestion
            activityLog = snapshot.activityLog ?? []
            changedFiles = snapshot.changedFiles ?? []
        }

        // Auto-open only on the transition into a question, never on the repeated
        // snapshots of a still-pending one — otherwise the panel re-locks forever.
        let announcedNewQuestion = newlyActionableSession != nil
            || (sessions.isEmpty && snapshot.state == .question && previousPhase != .question)
        if announcedNewQuestion {
            beginQuestionPeek()
        }

        trackedPID = snapshot.pid
        activeSessionCount = sessions.isEmpty
            ? max(snapshot.activeSessionCount ?? (snapshot.state == .idle ? 0 : 1), 0)
            : sessions.count
        codexSessionCount = sessions.isEmpty
            ? max(snapshot.codexSessionCount ?? (snapshot.provider == .codex ? activeSessionCount : 0), 0)
            : sessions.filter { $0.provider == .codex }.count
        claudeSessionCount = sessions.isEmpty
            ? max(snapshot.claudeSessionCount ?? (snapshot.provider == .claude ? activeSessionCount : 0), 0)
            : sessions.filter { $0.provider == .claude }.count
        filesChanged = changedFiles.count
        layoutDidChange?()

        for session in sessions {
            guard let oldState = previousSessions[session.id], oldState != session.state else { continue }
            sessionDidChange?(session, oldState)
        }
        if previousPhase != phase {
            phaseDidChange?(previousPhase, phase)
        }
    }

    private func applySession(_ session: AgentSessionSnapshot) {
        provider = session.provider
        phase = session.state
        task = session.task
        detail = session.detail
        elapsedSeconds = session.updatedSecondsAgo
        contextUsedTokens = session.contextUsedTokens
        contextWindowTokens = session.contextWindowTokens
        sessionTotalTokens = session.sessionTotalTokens
        rateLimitUsedPercent = session.rateLimitUsedPercent
        rateLimitResetsAt = session.rateLimitResetsAt
        rateLimitWindowMinutes = session.rateLimitWindowMinutes
        usageSource = session.usageSource
        usageExact = session.usageExact ?? false
        workspacePath = session.workspacePath
        modelName = session.modelName
        reasoningEffort = session.reasoningEffort
        latestPrompt = session.latestPrompt
        pendingQuestion = session.pendingQuestion
        activityLog = session.activityLog ?? []
        changedFiles = session.changedFiles ?? []
    }


    private func applyPreviewUsage() {
        contextUsedTokens = 86_700
        contextWindowTokens = 258_400
        sessionTotalTokens = 1_240_000
        rateLimitUsedPercent = 42
        rateLimitResetsAt = Int64(Date().addingTimeInterval(2.4 * 60 * 60).timeIntervalSince1970)
        rateLimitWindowMinutes = 300
        usageSource = "preview"
        usageExact = false
    }
}

extension IslandModel: AudioMonitoringDelegate {
    func outputVolumeDidChange(_ level: Float, delta: Float) {
        handleVolumeChange(level: level, delta: delta)
    }

    func audioPlayingDidChange(_ playing: Bool) {
        guard isAudioPlaying != playing else { return }
        isAudioPlaying = playing
    }

    func spectrumDidUpdate(_ bars: [Float]) {
        spectrumStore.update(bars)
    }
}
