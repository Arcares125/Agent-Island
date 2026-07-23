import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum IslandPalette {
    static let surface = Color.black
    static let raised = Color(hex: 0x151815)
    static let line = Color.white.opacity(0.09)
    static let text = Color(hex: 0xF1F3ED)
    static let secondary = Color(hex: 0x858A81)
}

private struct IslandSurfaceShape: Shape {
    let isNotchAttached: Bool

    func path(in rect: CGRect) -> Path {
        guard isNotchAttached else {
            return RoundedRectangle(cornerRadius: 22, style: .continuous).path(in: rect)
        }

        let radius = min(22, min(rect.width / 2, rect.height))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        ZStack(alignment: .top) {
            if model.isExpanded {
                ExpandedBodyReveal(model: model)
                    .padding(.top, model.persistentHeaderSize.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IslandPalette.surface)
        .clipShape(IslandSurfaceShape(isNotchAttached: model.isNotchAttached))
        .overlay {
            IslandSurfaceShape(isNotchAttached: model.isNotchAttached)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
                .opacity(model.isNotchAttached && !model.isExpanded ? 0 : 1)
        }
        .shadow(
            color: .black.opacity(model.isNotchAttached && !model.isExpanded ? 0.16 : 0.34),
            radius: model.isNotchAttached && !model.isExpanded ? 8 : 24,
            y: model.isNotchAttached && !model.isExpanded ? 3 : 10
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.provider.displayName), \(model.aggregatePhase.label.lowercased())")
    }
}

private struct ExpandedBodyReveal: View {
    @ObservedObject var model: IslandModel
    @State private var isVisible = false

    var body: some View {
        ExpandedIslandView(model: model)
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : -5)
            .onAppear {
                withAnimation(.easeOut(duration: 0.20).delay(0.05)) {
                    isVisible = true
                }
            }
    }
}

struct IslandHeaderView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        CompactIslandView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(IslandPalette.line)
                    .frame(height: 1)
                    .opacity(model.isExpanded && !model.isNotchAttached ? 1 : 0)
            }
            .animation(nil, value: model.isExpanded)
    }
}

struct CompactIslandView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        Group {
            if model.isNotchAttached {
                NotchCompactIslandView(model: model)
            } else if model.monitoringEnabled, !model.sessions.isEmpty {
                LiveCompactSessionView(model: model)
            } else {
                legacyCompactView
            }
        }
    }

    private var legacyCompactView: some View {
        HStack(spacing: model.phase == .idle ? 7 : 11) {
            MascotView(
                provider: model.provider,
                phase: model.phase,
                size: model.phase == .idle ? 26 : 42,
                isActive: model.animationsEnabled,
                showsExpression: true
            )

            if model.phase == .idle {
                Text(
                    model.activeSessionCount > 0
                        ? "\(model.provider.displayName) idle · \(model.activeSessionCount) open"
                        : "Hover to view sessions"
                )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IslandPalette.text.opacity(0.86))
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(model.provider.displayName.uppercased())
                            .foregroundStyle(IslandPalette.secondary)
                        Text("•  \(model.phase.label)")
                            .foregroundStyle(Color(hex: model.phase.statusAccentHex))
                    }
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(0.7)

                    Text(model.task)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IslandPalette.text)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let sessionSummary = model.sessionSummaryText {
                    Text(sessionSummary)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(IslandPalette.text.opacity(0.78))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(IslandPalette.raised)
                        .clipShape(Capsule())
                }

                if let contextPercentText = model.contextPercentText {
                    Text(contextPercentText)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(hex: model.accentHex).opacity(0.86))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(IslandPalette.raised)
                        .clipShape(Capsule())
                }

                Text(model.elapsedText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(IslandPalette.secondary)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IslandPalette.secondary)
                    .padding(.leading, 2)
                    .rotationEffect(.degrees(model.isExpanded ? 180 : 0))
            }
        }
        .padding(.horizontal, model.phase == .idle ? 7 : 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NotchCompactIslandView: View {
    @ObservedObject var model: IslandModel

    private var recentSessions: [AgentSessionSnapshot] {
        Array(
            model.sessions
                .sorted {
                    if $0.updatedSecondsAgo != $1.updatedSecondsAgo {
                        return $0.updatedSecondsAgo < $1.updatedSecondsAgo
                    }
                    return $0.id < $1.id
                }
                .prefix(3)
        )
    }

    private var primarySession: AgentSessionSnapshot? {
        recentSessions.first
    }

    private var displayedPhase: AgentPhase {
        primarySession?.state ?? model.aggregatePhase
    }

    private var statusText: String {
        switch displayedPhase {
        case .idle: return "Idle"
        case .thinking: return "Working"
        case .question: return "Input"
        case .complete: return "Done"
        }
    }

    var body: some View {
        if let presentation = model.notchPresentation {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    NotchRecentAgentCluster(
                        sessions: recentSessions,
                        fallbackProvider: model.provider,
                        fallbackPhase: displayedPhase,
                        isActive: model.animationsEnabled
                    )

                    Text(statusText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(hex: displayedPhase.statusAccentHex))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(height: presentation.barHeight, alignment: .center)
                        .offset(y: 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                Color.clear
                    .frame(width: presentation.cameraWidth)

                CompactCalendarControl(
                    model: model,
                    sessionCount: model.sessions.isEmpty
                        ? model.activeSessionCount
                        : model.sessions.count,
                    phase: displayedPhase
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

private struct CompactCalendarControl: View {
    @ObservedObject var model: IslandModel
    let sessionCount: Int
    let phase: AgentPhase

    var body: some View {
        Group {
            if sessionCount > 0 {
                // Five seconds is long enough to read either face and wakes the
                // tiny wing only twelve times per minute—not once per second.
                TimelineView(.periodic(from: .now, by: IslandCalendar.compactFaceDuration)) { timeline in
                    calendarButton(
                        date: timeline.date,
                        showsSession: IslandCalendar.compactWingShowsSession(
                            at: timeline.date,
                            sessionCount: sessionCount,
                            calendarPresented: model.isCalendarPresented
                        ),
                        showsSoundwave: false
                    )
                }
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    calendarButton(
                        date: timeline.date,
                        showsSession: false,
                        showsSoundwave: model.isShowingSoundwave
                    )
                }
            }
        }
    }

    private func calendarButton(
        date: Date,
        showsSession: Bool,
        showsSoundwave: Bool
    ) -> some View {
        Button {
            model.toggleCalendar()
        } label: {
            HStack(spacing: 4) {
                if showsSoundwave {
                    SoundwaveView(
                        store: model.spectrumStore,
                        isActive: model.animationsEnabled && model.isShowingSoundwave,
                        barWidth: 1.4,
                        spacing: 1.1,
                        maxBarHeight: 10
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                if showsSession {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: phase.statusAccentHex))
                            .frame(width: 4, height: 4)
                        Text("\(sessionCount) \(sessionCount == 1 ? "SESSION" : "SESSIONS")")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(IslandPalette.text.opacity(0.86))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                model.isCalendarPresented
                                    ? Color(hex: 0xB7A7EE)
                                    : IslandPalette.text.opacity(0.88)
                            )
                            .frame(width: 13, height: 17)

                        VStack(alignment: .leading, spacing: -1) {
                            Text(IslandCalendar.compactDate(date))
                                .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(IslandPalette.secondary)
                            Text(IslandCalendar.compactTime(date))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(IslandPalette.text.opacity(0.9))
                                .monospacedDigit()
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                model.isCalendarPresented
                    ? Color(hex: 0x9480D8).opacity(0.15)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.22), value: showsSession)
        }
        .buttonStyle(.plain)
        .help(model.isCalendarPresented ? "Close calendar" : "Open calendar")
        .accessibilityLabel(
            "\(IslandCalendar.longDate(date)), "
                + "\(IslandCalendar.compactTime(date)); "
                + (model.isCalendarPresented ? "close calendar" : "open calendar")
        )
    }
}

private struct NotchRecentAgentCluster: View {
    let sessions: [AgentSessionSnapshot]
    let fallbackProvider: AgentProvider
    let fallbackPhase: AgentPhase
    let isActive: Bool

    var body: some View {
        if sessions.isEmpty {
            // No agent detected: show both mascots resting side by side so the
            // idle notch reads as "nothing running" rather than one lone agent.
            HStack(alignment: .bottom, spacing: -3) {
                MascotView(
                    provider: .codex,
                    phase: .idle,
                    size: 18,
                    isActive: isActive,
                    showsExpression: true
                )
                .frame(width: 18, height: 22, alignment: .bottom)
                .zIndex(1)

                MascotView(
                    provider: .claude,
                    phase: .idle,
                    size: 16,
                    isActive: isActive,
                    showsExpression: true
                )
                .frame(width: 16, height: 22, alignment: .bottom)
            }
        } else {
            HStack(alignment: .bottom, spacing: -5) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    Group {
                        if index == 0 {
                            MascotView(
                                provider: session.provider,
                                phase: session.state,
                                size: 20,
                                isActive: isActive,
                                showsExpression: false
                            )
                        } else {
                            Image(nsImage: MascotImageStore.image(
                                provider: session.provider,
                                fallbackSize: index == 1 ? 14 : 12
                            ))
                            .resizable()
                            .scaledToFit()
                            .frame(
                                width: index == 1 ? 14 : 12,
                                height: index == 1 ? 14 : 12
                            )
                        }
                    }
                    .frame(
                        width: index == 0 ? 20 : (index == 1 ? 14 : 12),
                        height: 22,
                        alignment: .bottom
                    )
                    .zIndex(Double(sessions.count - index))
                }
            }
        }
    }
}

private struct LiveCompactSessionView: View {
    @ObservedObject var model: IslandModel

    private var primarySession: AgentSessionSnapshot {
        model.sessions[0]
    }

    var body: some View {
        HStack(spacing: 9) {
            SessionMascotCluster(
                sessions: model.sessions,
                phase: model.aggregatePhase,
                isActive: model.animationsEnabled
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.aggregateStatusText.uppercased())
                        .foregroundStyle(Color(hex: model.aggregatePhase.statusAccentHex))
                    Text("·  \(primarySession.projectName.uppercased())")
                        .foregroundStyle(IslandPalette.secondary)
                        .lineLimit(1)
                }
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.55)

                Text(primarySession.task)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandPalette.text)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }

            Spacer(minLength: 5)

            Text("\(model.sessions.count) \(model.sessions.count == 1 ? "SESSION" : "SESSIONS")")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(IslandPalette.text.opacity(0.78))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(IslandPalette.raised)
                .clipShape(Capsule())
                .contentTransition(.numericText())

            if let percent = primarySession.contextPercent {
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(hex: primarySession.accentHex).opacity(0.9))
                    .frame(width: 29, alignment: .trailing)
                    .contentTransition(.numericText())
            }

            Text(primarySession.activityAgeText)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(IslandPalette.secondary)
                .frame(width: 24, alignment: .trailing)

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(IslandPalette.secondary)
                .rotationEffect(.degrees(model.isExpanded ? 180 : 0))
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: primarySession.task)
    }
}

private struct SessionMascotCluster: View {
    let sessions: [AgentSessionSnapshot]
    let phase: AgentPhase
    let isActive: Bool

    var body: some View {
        let visibleSessions = Array(sessions.prefix(3))
        ZStack(alignment: .leading) {
            ForEach(visibleSessions.indices.reversed(), id: \.self) { index in
                let session = visibleSessions[index]
                Group {
                    if index == 0 {
                        MascotView(
                            provider: session.provider,
                            phase: phase,
                            size: 36,
                            isActive: isActive,
                            showsExpression: true
                        )
                    } else {
                        Image(nsImage: MascotImageStore.image(provider: session.provider, fallbackSize: 20))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .padding(2)
                            .background(IslandPalette.raised)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(IslandPalette.surface, lineWidth: 1.5))
                            .offset(x: CGFloat(index) * 12 + 17, y: CGFloat(index) * 2 + 8)
                    }
                }
                .zIndex(Double(4 - index))
            }
        }
        .frame(
            width: sessions.count > 2 ? 64 : (sessions.count > 1 ? 52 : 38),
            height: 40,
            alignment: .leading
        )
    }
}

struct ExpandedIslandView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        Group {
            if model.isShowingCalendar {
                CalendarPanelView(model: model)
            } else if model.isShowingVolumeHUD {
                VolumeHUDView(
                    level: model.outputVolumeLevel,
                    direction: model.volumeTugDirection,
                    isActive: model.animationsEnabled
                )
            } else if model.monitoringEnabled, !model.sessions.isEmpty {
                LiveSessionDashboard(model: model)
            } else {
                VStack(spacing: 0) {
                    if model.phase != .question && model.phase != .idle {
                        UsageSummaryView(model: model)
                    }

                    switch model.phase {
                    case .idle:
                        IdleDetailView(model: model)
                    case .thinking:
                        ThinkingDetailView(model: model)
                    case .question:
                        QuestionDetailView(model: model)
                    case .complete:
                        CompleteDetailView(model: model)
                    }
                }
            }
        }
        .padding(.horizontal, model.isShowingCalendar ? 16 : (model.isShowingVolumeHUD ? 18 : (model.monitoringEnabled && !model.sessions.isEmpty ? 12 : (model.phase == .question ? 16 : 18))))
        .padding(.top, model.isShowingCalendar ? 10 : (model.isShowingVolumeHUD ? 12 : (model.monitoringEnabled && !model.sessions.isEmpty ? 10 : (model.phase == .question || model.phase == .idle ? 14 : 0))))
        .padding(.bottom, model.isShowingCalendar ? 12 : (model.isShowingVolumeHUD ? 12 : (model.monitoringEnabled && !model.sessions.isEmpty ? 12 : (model.phase == .question ? 16 : 18))))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct LiveSessionDashboard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 8) {
            IslandTabBar(model: model)

            Group {
                switch model.selectedTab {
                case .agents:
                    AgentsTab(model: model)
                case .shelf:
                    TemporaryFileShelfView(
                        store: model.temporaryFileShelf,
                        isAppKitDropTargeted: model.isFileDragTargeted
                    )
                    .frame(height: IslandModel.shelfTabContentHeight)
                case .settings:
                    HoverSettingsPanel(model: model)
                        .frame(height: IslandModel.settingsTabContentHeight)
                }
            }

            if model.isShowingSoundwaveStrip {
                SoundwaveView(store: model.spectrumStore, isActive: model.animationsEnabled)
                    .frame(height: IslandModel.soundwaveStripHeight)
                    .transition(.opacity)
            }

            Text("BUILT BY XIEZY")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(IslandPalette.secondary.opacity(0.72))
                .tracking(0.55)
                .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12, alignment: .center)
        }
    }
}

private struct IslandTabBar: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(IslandTab.allCases) { tab in
                let isSelected = model.selectedTab == tab
                Button {
                    model.selectTab(tab)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(tabLabel(tab))
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(isSelected ? IslandPalette.surface : IslandPalette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(isSelected ? Color(hex: model.accentHex) : IslandPalette.raised)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSelected ? Color.clear : IslandPalette.line)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.label)
            }
        }
        .frame(height: 30)
    }

    private func tabLabel(_ tab: IslandTab) -> String {
        // Session count is model-published, so it stays reactive here; the shelf is
        // its own observable and shows its count on the shelf itself.
        tab == .agents ? "\(tab.label) \(model.sessions.count)" : tab.label
    }
}

private struct AgentsTab: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 6) {
                ForEach(model.sessions) { session in
                    SessionCard(
                        model: model,
                        session: session,
                        isExpanded: model.expandedSessionID == session.id,
                        isActive: model.animationsEnabled && model.selectedSessionID == session.id
                    )
                }
            }
            .padding(.trailing, 3)
            .animation(
                .spring(response: 0.36, dampingFraction: 0.86),
                value: model.sessions.map(\.id)
            )
            .animation(
                .spring(response: 0.32, dampingFraction: 0.86),
                value: model.expandedSessionID
            )
        }
        .scrollIndicators(.visible)
        .frame(height: model.liveSessionListHeight)
    }
}

private struct HoverSettingsPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        // Scrolls because the panel's height is fixed: without this, adding a
        // setting silently clips the one below it off the bottom, and a control
        // nobody can reach is indistinguishable from a broken one.
        ScrollView(.vertical) {
            settingsContent
        }
        .scrollIndicators(.visible)
        .frame(
            maxWidth: .infinity,
            minHeight: IslandModel.settingsTabContentHeight,
            maxHeight: IslandModel.settingsTabContentHeight,
            alignment: .top
        )
        .background(IslandPalette.raised)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(IslandPalette.line)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HOVER TIMING")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(IslandPalette.secondary)

            delayRow(
                label: "OPEN",
                presets: IslandModel.openDelayPresets,
                selected: model.hoverOpenDelay,
                action: model.setHoverOpenDelay
            )
            delayRow(
                label: "CLOSE",
                presets: IslandModel.closeDelayPresets,
                selected: model.hoverCloseDelay,
                action: model.setHoverCloseDelay
            )

            Text("MEDIA")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(IslandPalette.secondary)
                .padding(.top, 2)

            Toggle(isOn: Binding(
                get: { model.volumePopupEnabled },
                set: { model.setVolumePopupEnabled($0) }
            )) {
                Text("VOLUME POP-UP")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(IslandPalette.text.opacity(0.82))
            }
            .toggleStyle(.switch)
            .tint(Color(hex: model.accentHex))
            .controlSize(.mini)

            Toggle(isOn: Binding(
                get: { model.musicVisualizerEnabled },
                set: { model.setMusicVisualizerEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("MUSIC VISUALIZER")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(IslandPalette.text.opacity(0.82))
                    Text("needs audio access")
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(IslandPalette.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Color(hex: model.accentHex))
            .controlSize(.mini)

            Toggle(isOn: Binding(
                get: { model.answerHookEnabled },
                set: { model.setAnswerHookEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("ANSWER FROM ISLAND")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(IslandPalette.text.opacity(0.82))
                    Text(model.answerHookError ?? "adds a hook to Claude & Codex")
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(
                            model.answerHookError == nil
                                ? IslandPalette.secondary
                                : Color(hex: 0xE2A44F))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Color(hex: model.accentHex))
            .controlSize(.mini)
            .help("Lets you answer an agent's question by clicking it here instead of switching to the terminal")

            Toggle(isOn: Binding(
                get: { model.suppressSystemVolumeHUD },
                set: { model.setSuppressSystemVolumeHUD($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HIDE SYSTEM VOLUME HUD")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(IslandPalette.text.opacity(0.82))
                    Text(model.volumeHUDError ?? "needs accessibility")
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(
                            model.volumeHUDError == nil
                                ? IslandPalette.secondary
                                : Color(hex: 0xE2A44F))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Color(hex: model.accentHex))
            .controlSize(.mini)
            .help("Stops macOS drawing its own volume overlay on top of the island's")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func delayRow(
        label: String,
        presets: [TimeInterval],
        selected: TimeInterval,
        action: @escaping (TimeInterval) -> Void
    ) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(IslandPalette.secondary)
                .frame(width: 34, alignment: .leading)

            ForEach(presets, id: \.self) { value in
                let isSelected = abs(value - selected) < 0.001
                Button {
                    action(value)
                } label: {
                    Text(presetLabel(value))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(
                            isSelected ? IslandPalette.surface : IslandPalette.text.opacity(0.82)
                        )
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background(isSelected ? Color(hex: model.accentHex) : IslandPalette.surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isSelected ? Color.clear : IslandPalette.line)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func presetLabel(_ value: TimeInterval) -> String {
        value == 0 ? "0s" : String(format: "%.1fs", value)
    }
}

private struct TemporaryFileShelfView: View {
    @ObservedObject var store: TemporaryFileShelf
    let isAppKitDropTargeted: Bool
    @State private var isSwiftUIDropTargeted = false
    @State private var dropPulse = false

    private let shelfAccent = Color(hex: 0xB8A6F2)
    private var isDropTargeted: Bool {
        isAppKitDropTargeted || isSwiftUIDropTargeted
    }

    var body: some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(isDropTargeted ? shelfAccent.opacity(0.72) : IslandPalette.line)
                .frame(height: 1)

            HStack(spacing: 8) {
                Label("TEMP FILE SHELF", systemImage: "tray.and.arrow.down.fill")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isDropTargeted ? shelfAccent : IslandPalette.text.opacity(0.9))

                Text(store.statusMessage)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(IslandPalette.secondary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("\(store.items.count)/\(TemporaryFileShelf.maximumItemCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(shelfAccent)
                    .contentTransition(.numericText())
            }
            .frame(height: 13)

            if store.items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                    Text("DROP FILES HERE")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                    Text("UP TO 9 · 1 GB EACH · AUTO-DELETED IN 1 HOUR")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(IslandPalette.secondary.opacity(0.75))
                }
                .foregroundStyle(isDropTargeted ? shelfAccent : IslandPalette.secondary.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    isDropTargeted
                        ? shelfAccent.opacity(0.11)
                        : IslandPalette.raised.opacity(0.54)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isDropTargeted ? shelfAccent.opacity(0.72) : IslandPalette.line,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(store.items) { item in
                            TemporaryFileShelfCard(store: store, item: item)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, isDropTargeted ? 3 : 0)
        .padding(.vertical, isDropTargeted ? 2 : 0)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(shelfAccent.opacity(isDropTargeted ? (dropPulse ? 0.13 : 0.075) : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    shelfAccent.opacity(isDropTargeted ? (dropPulse ? 0.92 : 0.58) : 0),
                    lineWidth: isDropTargeted ? 1.5 : 0
                )
        }
        .scaleEffect(isDropTargeted ? (dropPulse ? 1.012 : 0.998) : 1)
        .shadow(
            color: shelfAccent.opacity(isDropTargeted ? (dropPulse ? 0.38 : 0.18) : 0),
            radius: isDropTargeted ? (dropPulse ? 11 : 5) : 0
        )
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isDropTargeted)
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isSwiftUIDropTargeted
        ) { providers in
            store.accept(providers)
        }
        .onChange(of: isDropTargeted) { _, targeted in
            if targeted {
                dropPulse = false
                withAnimation(.easeInOut(duration: 0.58).repeatForever(autoreverses: true)) {
                    dropPulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    dropPulse = false
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: store.items.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Temporary file shelf, \(store.items.count) of 9 items")
    }
}

/// One dropped file as a tile: its real Finder icon (so a PDF looks like a PDF),
/// the file name, and a type · size line.
private struct TemporaryFileShelfCard: View {
    @ObservedObject var store: TemporaryFileShelf
    let item: TemporaryFileShelfItem
    @State private var fileIcon: NSImage
    @State private var isHovered = false

    static let width: CGFloat = 90
    static let height: CGFloat = 80
    private static let iconSize: CGFloat = 30
    private static let cornerRadius: CGFloat = 10
    private let shelfAccent = Color(hex: 0xB8A6F2)

    init(store: TemporaryFileShelf, item: TemporaryFileShelfItem) {
        _store = ObservedObject(wrappedValue: store)
        self.item = item
        _fileIcon = State(initialValue: NSWorkspace.shared.icon(forFile: item.url.path))
    }

    var body: some View {
        Button {
            store.copyToPasteboard(item)
        } label: {
            VStack(spacing: 3) {
                Image(nsImage: fileIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.iconSize, height: Self.iconSize)

                Text(item.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(IslandPalette.text.opacity(0.92))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                Text("\(shelfTypeLabel(for: item.url)) · \(shelfSizeLabel(item.byteCount))")
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isHovered ? shelfAccent : IslandPalette.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .frame(width: Self.width, height: Self.height, alignment: .top)
            .background(IslandPalette.raised.opacity(isHovered ? 1 : 0.84))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(isHovered ? shelfAccent.opacity(0.68) : IslandPalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Click to copy, or drag into another app")
        .overlay(alignment: .topTrailing) { removeButton }
        .scaleEffect(isHovered ? 1.03 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: isHovered)
        .onHover { isHovered = $0 }
        .onDrag {
            NSItemProvider(contentsOf: item.url)
                ?? NSItemProvider(object: item.url as NSURL)
        }
    }

    private var removeButton: some View {
        Button {
            store.remove(item)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(IslandPalette.text.opacity(0.9))
                .frame(width: 16, height: 16)
                .background(Circle().fill(IslandPalette.surface.opacity(0.92)))
                .overlay(Circle().stroke(IslandPalette.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Remove temporary copy")
        .padding(3)
        .opacity(isHovered ? 1 : 0.35)
    }
}

private struct SessionCard: View {
    @ObservedObject var model: IslandModel
    let session: AgentSessionSnapshot
    let isExpanded: Bool
    let isActive: Bool

    private var accent: Color { Color(hex: session.accentHex) }

    var body: some View {
        VStack(spacing: 0) {
            SessionListRow(
                session: session,
                isSelected: isExpanded,
                isActive: isActive
            ) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    model.toggleSessionInspector(session.id)
                }
            }

            if isExpanded {
                Rectangle()
                    .fill(accent.opacity(0.24))
                    .frame(height: 1)

                SessionInlineInspector(model: model, session: session)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        )
                    )
            }
        }
        .background(
            isExpanded
                ? accent.opacity(0.075)
                : IslandPalette.raised.opacity(0.62)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isExpanded ? accent.opacity(0.38) : IslandPalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SessionListRow: View {
    let session: AgentSessionSnapshot
    let isSelected: Bool
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var accent: Color { Color(hex: session.accentHex) }
    private var statusColor: Color { Color(hex: session.state.statusAccentHex) }
    private var effortColor: Color {
        Color(hex: session.effortAccentHex ?? session.accentHex)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MascotView(
                    provider: session.provider,
                    phase: session.state,
                    size: 30,
                    isActive: isActive,
                    showsExpression: true
                )
                .frame(width: 34)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.projectName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IslandPalette.text)
                            .lineLimit(1)

                        Text(session.provider.displayName.uppercased())
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(accent.opacity(0.11))
                            .clipShape(Capsule())

                        if let modelName = session.displayModelName {
                            Text(modelName)
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(accent.opacity(0.88))
                                .lineLimit(1)
                        }

                        if let effort = session.displayReasoningEffort {
                            Text(effort)
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundStyle(effortColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(effortColor.opacity(0.14))
                                .clipShape(Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(effortColor.opacity(0.28), lineWidth: 0.75)
                                }
                        }

                        Text("#\(session.shortID.uppercased())")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(IslandPalette.secondary.opacity(0.76))
                    }

                    Text(session.task)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? IslandPalette.text.opacity(0.76) : IslandPalette.secondary)
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 7) {
                        if let percent = session.contextPercent {
                            Text("\(Int(percent.rounded()))% ctx")
                                .foregroundStyle(accent.opacity(0.9))
                                .contentTransition(.numericText())
                        }
                        Text(session.activityAgeText)
                            .foregroundStyle(IslandPalette.secondary)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))

                    Text(session.state.label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? accent : IslandPalette.secondary.opacity(0.6))
                    .rotationEffect(.degrees(isSelected ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                isSelected
                    ? accent.opacity(0.055)
                    : (isHovering ? Color.white.opacity(0.055) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .accessibilityLabel("\(session.modelDetailText) session in \(session.projectName), \(session.state.label.lowercased())")
    }
}

private struct PendingQuestionCard: View {
    let question: PendingQuestion
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)
                Text(question.header ?? "Agent's question")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(accent)
                Spacer(minLength: 8)
                Text("ANSWER IN TERMINAL")
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(IslandPalette.secondary.opacity(0.7))
            }

            Text(question.prompt)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IslandPalette.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(IslandPalette.surface)
                            .frame(width: 16, height: 16)
                            .background(accent)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(IslandPalette.text.opacity(0.9))
                                .lineLimit(1)
                            if let description = option.description {
                                Text(description)
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(IslandPalette.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(IslandPalette.surface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(accent.opacity(0.28), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct SessionInlineInspector: View {
    @ObservedObject var model: IslandModel
    let session: AgentSessionSnapshot

    private var accent: Color { Color(hex: session.accentHex) }
    private var statusColor: Color { Color(hex: session.state.statusAccentHex) }
    private var recentActivity: [String] {
        let entries = session.activityLog ?? []
        return Array((entries.isEmpty ? [session.detail] : entries).suffix(3))
    }
    private var recentFiles: [String] {
        Array((session.changedFiles ?? []).suffix(3))
    }
    private var stateSymbol: String {
        switch session.state {
        case .idle: return "pause.circle.fill"
        case .thinking: return "terminal.fill"
        case .question: return "questionmark.circle.fill"
        case .complete: return "checkmark.circle.fill"
        }
    }
    private var stateTitle: String {
        session.state == .complete ? "DONE" : session.state.label
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("YOU")
                    .font(.system(size: 8.5, weight: .black, design: .monospaced))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.14))
                    .clipShape(Capsule())

                Text(session.latestPrompt ?? "No user prompt is available for this session.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(
                        session.latestPrompt == nil
                            ? IslandPalette.secondary.opacity(0.78)
                            : IslandPalette.text.opacity(0.86)
                    )
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(stateTitle)
                    .font(.system(size: 8.5, weight: .black, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.12))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .top)
            .background(IslandPalette.surface.opacity(0.78))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(accent.opacity(0.15), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            // A live ask wins over the transcript-scraped echo of the same
            // question: only one of them can actually be answered.
            if let ask = model.pendingAsk, ask.matches(session) {
                AnswerableQuestionCard(model: model, ask: ask, accent: accent)
            } else if let question = session.pendingQuestion,
                      !model.isAlreadyAnswered(question) {
                PendingQuestionCard(question: question, accent: accent)
            }

            VStack(spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: stateSymbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(statusColor)
                    Text(session.task)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(IslandPalette.text.opacity(0.9))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("SAFE ACTIVITY")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(IslandPalette.secondary.opacity(0.68))
                        .tracking(0.45)
                }
                .frame(height: 18)

                ForEach(Array(recentActivity.enumerated()), id: \.offset) { index, activity in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(index == recentActivity.count - 1 ? statusColor : accent.opacity(0.55))
                            .frame(width: 4, height: 4)
                        Text(activity)
                            .font(.system(size: 10, weight: index == recentActivity.count - 1 ? .medium : .regular, design: .monospaced))
                            .foregroundStyle(index == recentActivity.count - 1 ? IslandPalette.text.opacity(0.84) : IslandPalette.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .frame(height: 18)
                }

                HStack(spacing: 5) {
                    Text("CHANGED")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(IslandPalette.secondary.opacity(0.7))
                    if recentFiles.isEmpty {
                        Text("No files reported")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(IslandPalette.secondary.opacity(0.68))
                    } else {
                        ForEach(recentFiles, id: \.self) { file in
                            Text(file)
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(IslandPalette.text.opacity(0.76))
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(accent.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                    Spacer()
                }
                .frame(height: 20)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(IslandPalette.surface.opacity(0.58))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(IslandPalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("CONTEXT")
                        Spacer()
                        Text(session.contextPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    }
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)

                    SegmentedUsageMeter(
                        percent: session.contextPercent,
                        accent: accent,
                        segmentCount: 10
                    )
                    .frame(height: 5)
                }
                .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(IslandPalette.line)
                    .frame(width: 1, height: 25)

                metricValue(title: "TOKENS", value: model.formattedTokens(session.sessionTotalTokens), width: 62)
                metricValue(title: "FILES", value: "\((session.changedFiles ?? []).count)", width: 38)
                metricValue(title: "UPDATED", value: session.activityAgeText, width: 48)
            }
            .frame(height: 28)
        }
        .padding(10)
        .background(accent.opacity(0.035))
    }

    private func metricValue(title: String, value: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .foregroundStyle(IslandPalette.secondary.opacity(0.72))
            Text(value)
                .foregroundStyle(IslandPalette.text.opacity(0.86))
        }
        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
        .frame(width: width, alignment: .leading)
    }
}

private struct UsageSummaryView: View {
    @ObservedObject var model: IslandModel

    private var meterColor: Color {
        usageColor(for: model.contextPercent)
    }

    private var rateMeterColor: Color {
        usageColor(for: model.rateLimitUsedPercent)
    }

    private func usageColor(for percent: Double?) -> Color {
        guard let percent else { return Color(hex: model.accentHex) }
        if percent >= 85 { return Color(hex: 0xE56B5D) }
        if percent >= 70 { return Color(hex: 0xE8A443) }
        return Color(hex: model.accentHex)
    }

    private var sourceLabel: String {
        switch model.usageSource {
        case "codex-session-log": return "LIVE"
        case "claude-status-line": return "LIVE"
        case "claude-transcript": return "LATEST TURN"
        case "preview": return "PREVIEW"
        default: return "WAITING"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("CONTEXT")
                    .foregroundStyle(IslandPalette.secondary)

                if let used = model.contextUsedTokens {
                    Text(model.formattedTokens(used))
                        .foregroundStyle(IslandPalette.text.opacity(0.9))
                    if let window = model.contextWindowTokens {
                        Text("/ \(model.formattedTokens(window))")
                            .foregroundStyle(IslandPalette.secondary)
                    }
                } else {
                    Text("Usage appears after the first agent response")
                        .foregroundStyle(IslandPalette.secondary.opacity(0.78))
                }

                Spacer()

                Text(sourceLabel)
                    .foregroundStyle(IslandPalette.secondary.opacity(0.72))
            }
            .font(.system(size: 8, weight: .semibold, design: .monospaced))

            HStack(spacing: 9) {
                SegmentedUsageMeter(
                    percent: model.contextPercent,
                    accent: meterColor,
                    segmentCount: 14
                )

                Text(model.contextPercent.map { "\(Int($0.rounded()))% USED" } ?? "—% USED")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.contextPercent == nil ? IslandPalette.secondary : meterColor)
                    .frame(width: 58, alignment: .trailing)
            }
            .frame(height: 7)

            HStack(spacing: 8) {
                Text("SESSION TOKENS")
                    .foregroundStyle(IslandPalette.secondary)
                Text(model.formattedTokens(model.sessionTotalTokens))
                    .foregroundStyle(IslandPalette.text.opacity(0.82))

                Spacer()

                if let usedPercent = model.rateLimitUsedPercent {
                    SegmentedUsageMeter(
                        percent: usedPercent,
                        accent: rateMeterColor,
                        segmentCount: 8
                    )
                    .frame(width: 76, height: 5)

                    Text("\(Int(usedPercent.rounded()))% \(model.rateWindowLabel ?? "LIMIT") USED")
                        .foregroundStyle(rateMeterColor.opacity(0.9))
                }
                if let resetText = model.resetText {
                    Text("·  RESETS \(resetText.uppercased())")
                        .foregroundStyle(Color(hex: model.accentHex).opacity(0.9))
                }
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(IslandPalette.line).frame(height: 1) }
    }
}

private struct SegmentedUsageMeter: View {
    let percent: Double?
    let accent: Color
    let segmentCount: Int

    private var clampedPercent: Double {
        min(max(percent ?? 0, 0), 100)
    }

    private func progress(for index: Int) -> Double {
        min(max((clampedPercent / 100 * Double(segmentCount)) - Double(index), 0), 1)
    }

    private func color(for index: Int) -> Color {
        let progress = progress(for: index)
        guard progress > 0 else { return Color.white.opacity(0.065) }

        // Used segments begin bright and gently dim across the row. A partially
        // used segment fades proportionally, while unused boxes remain quiet.
        let position = Double(index) / Double(max(segmentCount - 1, 1))
        let brightness = 0.96 - (position * 0.34)
        return accent.opacity(brightness * (0.45 + progress * 0.55))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                    .fill(color(for: index))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage")
        .accessibilityValue(percent.map { "\(Int($0.rounded())) percent used" } ?? "Unavailable")
    }
}

private struct ThinkingDetailView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CURRENT STEP")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Color(hex: model.accentHex))
                    Text(model.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(IslandPalette.text.opacity(0.84))
                        .lineLimit(2)
                }
                Spacer()

                if model.activeSessionCount > 1 {
                    Text(model.providerSessionSummary.uppercased())
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(IslandPalette.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)

            ActivityLogView(model: model)

            HStack(spacing: 18) {
                StatLabel(value: "\(model.activityLog.count)", label: "logged steps")
                StatLabel(value: "\(model.filesChanged)", label: "files changed")
                Spacer()
                Text("PRIVATE · LOCAL ONLY")
                    .foregroundStyle(IslandPalette.secondary.opacity(0.72))
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .padding(.vertical, 11)
            .overlay(alignment: .top) { Rectangle().fill(IslandPalette.line).frame(height: 1) }

            ZStack {
                Text("BUILT BY XIEZY")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(IslandPalette.secondary.opacity(0.72))

                HStack {
                    IslandButton(title: "Stop", icon: "stop.fill", role: .secondary) {
                        model.setPhase(.idle)
                    }
                    Spacer()
                }
            }
        }
    }
}

private struct ActivityLogView: View {
    @ObservedObject var model: IslandModel

    private var entries: [String] {
        model.activityLog.isEmpty ? [model.detail] : model.activityLog
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("ACTIVITY LOG")
                    .foregroundStyle(Color(hex: model.accentHex))
                Spacer()
                Text("SCROLL · LAST \(entries.count)")
                    .foregroundStyle(IslandPalette.secondary.opacity(0.72))
            }
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .tracking(0.65)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            ActivityLogRow(
                                text: entry,
                                isLatest: index == entries.count - 1,
                                accent: Color(hex: model.accentHex)
                            )
                            .id(index)
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(height: 72)
                .onAppear {
                    proxy.scrollTo(entries.count - 1, anchor: .bottom)
                }
                .onChange(of: model.activityLog) { _, updated in
                    guard !updated.isEmpty else { return }
                    proxy.scrollTo(updated.count - 1, anchor: .bottom)
                }
            }
            .padding(.vertical, 4)
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .background(IslandPalette.raised.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(IslandPalette.line, lineWidth: 1)
            }
        }
        .padding(.bottom, 9)
    }
}

private struct ActivityLogRow: View {
    let text: String
    let isLatest: Bool
    let accent: Color

    private var icon: String {
        let normalized = text.lowercased()
        if normalized.hasPrefix("changed") { return "doc.badge.ellipsis" }
        if normalized.hasPrefix("read") { return "doc.text.magnifyingglass" }
        if normalized.hasPrefix("completed") { return "checkmark.circle" }
        if normalized.hasPrefix("started") { return "play.circle" }
        if normalized.contains("command") { return "terminal" }
        return "circle.fill"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: icon == "circle.fill" ? 4 : 8, weight: .semibold))
                .foregroundStyle(isLatest ? accent : IslandPalette.secondary)
                .frame(width: 12)

            Text(text)
                .font(.system(size: 9, weight: isLatest ? .medium : .regular, design: .monospaced))
                .foregroundStyle(isLatest ? IslandPalette.text.opacity(0.9) : IslandPalette.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .frame(height: 22)
        .overlay(alignment: .bottom) {
            Rectangle().fill(IslandPalette.line.opacity(0.55)).frame(height: 1)
        }
    }
}

private struct IdleDetailView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if model.isShowingIdleSettings {
                IdleSettingsView(model: model)
            } else {
                restingScene
            }

            // The gear stands in for the whole tab bar here: with nothing running
            // there is no dashboard to tab through, only the scene and settings.
            Button(action: model.toggleIdleSettings) {
                Image(systemName: model.isShowingIdleSettings ? "xmark" : "gearshape.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IslandPalette.secondary)
                    .frame(width: 24, height: 24)
                    .background(IslandPalette.raised)
                    .clipShape(Circle())
                    .overlay { Circle().stroke(IslandPalette.line) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.isShowingIdleSettings ? "Close settings" : "Settings")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var restingScene: some View {
        VStack(spacing: 8) {
            IdlePlaygroundView(isActive: model.animationsEnabled)

            Text(model.activeSessionCount > 0 ? "Sessions resting" : "No agents running")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandPalette.text)

            Text(
                model.activeSessionCount > 0
                    ? "\(model.activeSessionCount) open · waiting for new transcript activity."
                    : "Start Codex or Claude and it appears here automatically."
            )
            .font(.system(size: 10))
            .foregroundStyle(IslandPalette.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The two resting mascots acting out the idle loop — dozing, listening to music,
/// then playing together — so a no-session island reads as alive.
private struct IdlePlaygroundView: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { isActive && !reduceMotion }

    var body: some View {
        Group {
            if animates {
                // Capped well below display refresh: the sprites move in slow,
                // readable steps, not a per-frame smear, and pause when hidden.
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { context in
                    IdleSceneStage(
                        scene: IdleChoreography.scene(
                            at: context.date.timeIntervalSinceReferenceDate),
                        animates: true
                    )
                }
            } else {
                // Reduce-motion or animations-off: a single still resting frame.
                IdleSceneStage(scene: IdleScene(activity: .sleeping, progress: 0), animates: false)
            }
        }
    }
}

/// One frame of the idle loop: both mascots posed for the current scene, with a
/// small caption naming what they are up to.
private struct IdleSceneStage: View {
    let scene: IdleScene
    let animates: Bool

    private static let mascotSize: CGFloat = 52
    private static let baseOffset: CGFloat = 30

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                mascot(.codex, side: -1).offset(x: -Self.baseOffset)
                mascot(.claude, side: 1).offset(x: Self.baseOffset)
            }
            .frame(height: Self.mascotSize + 14, alignment: .bottom)

            Text(scene.activity.caption.uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(IslandPalette.secondary.opacity(0.82))
                .animation(.easeInOut(duration: 0.45), value: scene.activity)
        }
    }

    private func mascot(_ provider: AgentProvider, side: CGFloat) -> some View {
        let motion = IdleChoreography.motion(for: scene, side: side)
        // Claude's sprite reads larger than Codex's at the same box, matching the
        // proportions the live views already use.
        let providerScale: CGFloat = provider == .claude ? 0.82 : 1

        return ZStack(alignment: .topTrailing) {
            Image(nsImage: MascotImageStore.image(provider: provider, fallbackSize: Self.mascotSize))
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: Self.mascotSize, height: Self.mascotSize)
                .scaleEffect(x: providerScale, y: providerScale * motion.scaleY, anchor: .bottom)
                .offset(x: motion.dx, y: motion.dy)
                .rotationEffect(.degrees(motion.rotation), anchor: .bottom)

            badge(side: side)
        }
        .frame(width: Self.mascotSize, height: Self.mascotSize, alignment: .bottom)
    }

    @ViewBuilder
    private func badge(side: CGFloat) -> some View {
        if let rows = badgeGlyph(side: side) {
            PixelGlyph(
                rows: rows,
                color: badgeColor,
                cell: pixelCellSize(mascotSize: Self.mascotSize, rowCount: rows.count, fraction: 0.34)
            )
            .offset(x: 5, y: -6 - badgeDrift)
            .opacity(badgeOpacity)
        }
    }

    /// Which mark floats over which mascot. Sleep and play mark a single mascot to
    /// stay uncluttered; music marks both, since they are both listening.
    private func badgeGlyph(side: CGFloat) -> [String]? {
        switch scene.activity {
        case .sleeping: return side < 0 ? PixelGlyphs.sleep : nil
        case .music: return PixelGlyphs.note
        case .playing: return side > 0 ? PixelGlyphs.spark : nil
        }
    }

    private var badgeColor: Color {
        switch scene.activity {
        case .sleeping: return Color(hex: 0xB9C2CC)
        case .music: return Color(hex: 0xB8A6F2)
        case .playing: return Color(hex: 0xF2C879)
        }
    }

    /// A Zzz that drifts upward as it fades sells sleep; the others sit still.
    private var badgeDrift: CGFloat {
        guard animates, scene.activity == .sleeping else { return 0 }
        return CGFloat(scene.progress) * 5
    }

    /// Fade each mark in and out at the edges of its scene so nothing pops.
    private var badgeOpacity: Double {
        guard animates else { return 1 }
        let progress = scene.progress
        let fadeIn = min(progress / 0.15, 1)
        let fadeOut = min((1 - progress) / 0.15, 1)
        return max(0, min(fadeIn, fadeOut))
    }
}

/// The idle panel's settings, reached from the corner gear instead of a tab.
private struct IdleSettingsView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SETTINGS")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(IslandPalette.secondary)

            HoverSettingsPanel(model: model)
                .frame(height: IslandModel.settingsTabContentHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuestionDetailView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Which checkout behavior should I use?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IslandPalette.text)
                Spacer()
                Text("CHOOSE ONE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color(hex: model.accentHex))
            }
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(IslandPalette.line).frame(height: 1) }

            VStack(spacing: 6) {
                ForEach(model.answers, id: \.0) { answer in
                    AnswerRow(
                        title: answer.0,
                        detail: answer.1,
                        isSelected: model.selectedAnswer == answer.0,
                        accent: Color(hex: model.accentHex)
                    ) {
                        model.selectedAnswer = answer.0
                    }
                }
            }
            .padding(.vertical, 10)

            HStack {
                Text("↑↓ to move  ·  ↵ to select")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(IslandPalette.secondary.opacity(0.72))
                Spacer()
                Button(action: model.submitAnswer) {
                    HStack(spacing: 25) {
                        Text("Continue")
                        Text("↵").opacity(0.55)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(IslandPalette.surface)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(Color(hex: model.accentHex))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(IslandPalette.line).frame(height: 1) }
        }
    }
}

private struct CompleteDetailView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("FINISHED IN \(model.elapsedText)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(Color(hex: model.accentHex))
                    Text(model.task)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IslandPalette.text)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 66)

            Text(model.detail)
                .font(.system(size: 10))
                .foregroundStyle(IslandPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 11)

            HStack(spacing: 18) {
                StatLabel(value: "\(model.filesChanged)", label: "files changed")
                StatLabel(value: "\(model.activityLog.count)", label: "logged steps")
                Spacer()
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .padding(.vertical, 11)
            .overlay(alignment: .top) { Rectangle().fill(IslandPalette.line).frame(height: 1) }

            ZStack {
                Text("BUILT BY XIEZY")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(IslandPalette.secondary.opacity(0.72))

                HStack {
                    IslandButton(title: "Dismiss", role: .secondary) { model.setPhase(.idle) }
                    Spacer()
                }
            }
        }
    }
}

private struct AnswerRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Circle()
                    .stroke(isSelected ? accent : Color.white.opacity(0.22), lineWidth: 1)
                    .background(Circle().fill(isSelected ? accent : .clear).padding(4))
                    .frame(width: 15, height: 15)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? IslandPalette.text : IslandPalette.text.opacity(0.72))
                    Text(detail)
                        .font(.system(size: 8))
                        .foregroundStyle(IslandPalette.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isSelected ? Color.white.opacity(0.065) : Color.white.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.5) : IslandPalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct StatLabel: View {
    let value: String
    let label: String
    var color: Color = IslandPalette.text.opacity(0.78)

    var body: some View {
        HStack(spacing: 4) {
            Text(value).foregroundStyle(color)
            Text(label).foregroundStyle(IslandPalette.secondary)
        }
    }
}

private enum IslandButtonRole {
    case primary
    case secondary
}

private struct IslandButton: View {
    let title: String
    var icon: String? = nil
    let role: IslandButtonRole
    var accent: Color = Color(hex: 0x9480D8)
    var isEnabled = true
    var expands = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if let icon, role == .secondary { Image(systemName: icon) }
                Text(title)
                if expands { Spacer(); Image(systemName: icon ?? "arrow.up.right") }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(role == .primary ? IslandPalette.surface : IslandPalette.secondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: expands ? .infinity : 90, minHeight: 33)
            .background(role == .primary ? accent : IslandPalette.raised)
            .overlay {
                if role == .secondary {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(IslandPalette.line)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private enum MascotImageStore {
    static let cache = NSCache<NSString, NSImage>()

    static func image(provider: AgentProvider, fallbackSize: CGFloat) -> NSImage {
        let key = "\(provider.assetName)@\(provider.pixelCells)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let url = Bundle.module.url(forResource: provider.assetName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(size: NSSize(width: fallbackSize, height: fallbackSize))
        }

        let sprite = pixelated(image, cells: provider.pixelCells) ?? image
        cache.setObject(sprite, forKey: key)
        return sprite
    }

    /// Reduce artwork to a small grid so it can be blown back up as hard squares.
    ///
    /// Averaging down and then drawing back up with interpolation disabled is
    /// what produces real pixel art. Nearest-neighbour in *both* directions just
    /// drops detail and leaves ragged edges instead of clean cells.
    private static func pixelated(_ image: NSImage, cells: Int) -> NSImage? {
        let source = image.size
        guard source.width > 0, source.height > 0, cells > 0 else { return nil }

        // Fit inside the grid rather than filling it, so a tall sprite is not
        // squashed into a square.
        let scale = min(CGFloat(cells) / source.width, CGFloat(cells) / source.height)
        let fitted = NSSize(
            width: max(1, (source.width * scale).rounded()),
            height: max(1, (source.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(fitted.width), pixelsHigh: Int(fitted.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: fitted))

        let reduced = NSImage(size: fitted)
        reduced.addRepresentation(rep)
        return reduced
    }
}

struct MascotView: View {
    let provider: AgentProvider
    let phase: AgentPhase
    let size: CGFloat
    let isActive: Bool
    let showsExpression: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pose = 0

    private var accent: Color {
        Color(hex: provider == .codex ? 0x9480D8 : 0xE58A62)
    }

    private var image: NSImage {
        MascotImageStore.image(provider: provider, fallbackSize: size)
    }

    private var transform: (offset: CGSize, rotation: Double, scaleX: CGFloat, scaleY: CGFloat) {
        let providerScale: CGFloat = provider == .claude ? 0.76 : 1

        switch phase {
        case .idle:
            return pose == 0
                ? (CGSize(width: 0, height: 1), 0, providerScale, 0.98)
                : (CGSize(width: 0, height: -1), 0, providerScale, 1.02)
        case .thinking:
            switch pose {
            case 1: return (CGSize(width: -2, height: 2), -5, providerScale, 1)
            case 2: return (CGSize(width: 2, height: -1), 4, providerScale, 1)
            case 3: return (CGSize(width: 0, height: -2), 0, providerScale, 1.02)
            default: return (CGSize(width: 0, height: 1), 0, providerScale, 1)
            }
        case .question:
            switch pose {
            case 1: return (CGSize(width: -2, height: -1), -4, providerScale, 1)
            case 2: return (CGSize(width: 1, height: -1), 2, providerScale, 1)
            default: return (.zero, 0, providerScale, 1)
            }
        case .complete:
            switch pose {
            case 1: return (CGSize(width: 0, height: 4), -7, providerScale * 0.84, 0.86)
            case 2: return (CGSize(width: 0, height: -4), 4, providerScale * 1.04, 1.06)
            default: return (.zero, 0, providerScale, 1)
            }
        }
    }

    var body: some View {
        ZStack {
            Image(nsImage: image)
                // Nearest-neighbour, or the sprite's cells smear into each other
                // at the sizes the island actually draws them.
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .offset(transform.offset)
                .rotationEffect(.degrees(transform.rotation))
                .scaleEffect(x: transform.scaleX, y: transform.scaleY, anchor: .bottom)

            if showsExpression {
                expressionOverlay
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(provider.rawValue)-\(phase.rawValue)-\(isActive)") {
            guard isActive, !reduceMotion else { return }
            await animateCharacter()
        }
    }

    /// Badges are sprites too, not font glyphs in capsules: a smooth rounded
    /// bubble beside a pixel mascot reads as two art styles pasted together.
    @ViewBuilder
    private var expressionOverlay: some View {
        switch phase {
        case .idle:
            badge(PixelGlyphs.sleep, color: Color(hex: 0xD5D8D0), fraction: 0.34)
        case .thinking:
            if pose == 1 || pose == 2 {
                badge(PixelGlyphs.ellipsis, color: accent, fraction: 0.12)
                    .transition(.opacity)
            } else if pose == 3 {
                badge(PixelGlyphs.question, color: accent, fraction: 0.34)
                    .transition(.opacity)
            }
        case .question:
            // The one that matters: the mascot is waiting on the user, so this
            // bobs rather than sitting still.
            badge(PixelGlyphs.question, color: Color(hex: 0xF3E4D2), fraction: 0.46)
                .offset(y: pose == 1 ? -1 : 0)
        case .complete:
            badge(PixelGlyphs.check, color: accent, fraction: 0.3)
        }
    }

    private func badge(_ rows: [String], color: Color, fraction: CGFloat) -> some View {
        PixelGlyph(
            rows: rows,
            color: color,
            cell: pixelCellSize(mascotSize: size, rowCount: rows.count, fraction: fraction)
        )
        .offset(x: size * 0.44, y: -size * 0.40)
    }

    @MainActor
    private func animateCharacter() async {
        pose = 0
        while !Task.isCancelled {
            switch phase {
            case .idle:
                // A short, occasional breath reads as alive without continuously
                // asking Core Animation to redraw a menu-bar-resident window.
                await holdPose(0, for: 5.5)
                await setPose(1, hold: 0.8)
                await setPose(0, hold: 5.5)
            case .thinking:
                // Think in a recognizable gesture, then rest. This avoids a
                // generic perpetual bob and keeps the compact island inexpensive.
                await holdPose(0, for: 4.8)
                await setPose(1, hold: 0.9)
                await setPose(2, hold: 0.75)
                await setPose(3, hold: 0.55)
                await setPose(0, hold: 4.8)
            case .question:
                await holdPose(0, for: 4.0)
                await setPose(1, hold: 0.5)
                await setPose(2, hold: 0.32)
                await setPose(0, hold: 4.0)
            case .complete:
                await setPose(1, hold: 0.18)
                await setPose(2, hold: 0.28)
                await setPose(0, hold: 0.5)
                return
            }
        }
    }

    @MainActor
    private func holdPose(_ heldPose: Int, for seconds: Double) async {
        pose = heldPose
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    private func setPose(_ nextPose: Int, hold: Double) async {
        withAnimation(.easeInOut(duration: min(hold * 0.28, 0.32))) {
            pose = nextPose
        }
        try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
    }
}
