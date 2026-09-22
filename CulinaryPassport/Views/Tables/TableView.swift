import SwiftUI

/// One table: everyone seated round it, the globe on a lazy Susan in the
/// middle wearing what you've eaten between you, a spin that lands on
/// something none of you has had — and the conversation underneath.
struct TableView: View {
    let groupId: UUID

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var chat: ChatModel
    @State private var focus: GlobeCanvas.FocusRequest?
    @State private var selected: String?
    @State private var spinning = false
    @State private var landed: String?
    @State private var dropped: String?
    @State private var result: SpinResult?
    @State private var showDetails = false
    @State private var showLeaderboard = false
    /// Each member's newest cuisine, for the flag on their plate.
    @State private var newest: [UUID: String] = [:]
    @FocusState private var composing: Bool

    struct SpinResult: Identifiable {
        let code: String
        let fromSpin: Bool
        var id: String { "\(code)-\(fromSpin)" }
    }

    init(groupId: UUID) {
        self.groupId = groupId
        _chat = State(initialValue: ChatModel(groupId: groupId))
    }

    private var group: Group? { app.groups.first { $0.id == groupId } }
    private var memberIds: [UUID] { app.members(of: groupId) }
    private var cloth: Color { Color(hex: GroupPalette.stableColor(for: groupId)) }

    var body: some View {
        VStack(spacing: 0) {
            if composing {
                compactHeader
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                header
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Rectangle()
                .fill(Color.hairline)
                .frame(height: 0.5)
            if let group {
                TableConversation(group: group, chat: chat, composing: $composing,
                                  onSpin: { composing = false; spin() },
                                  onFind: { result = SpinResult(code: $0, fromSpin: false) })
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: composing)
        .background(TableclothBackdrop())
        .navigationTitle(group?.name ?? "Table")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showLeaderboard = true } label: { Image(systemName: "trophy") }
                    .accessibilityLabel("Who's eaten the most world")
                if let group {
                    Button { showDetails = true } label: { GroupAvatarView(group: group, size: 30) }
                        .accessibilityLabel("Table details")
                }
            }
        }
        .sheet(item: $result, onDismiss: { if let landed { selected = landed } }) { result in
            SpinResultSheet(code: result.code, tableId: groupId,
                            onSpinAgain: result.fromSpin ? { spinAgain() } : nil)
        }
        .sheet(isPresented: $showDetails) {
            if let group { TableDetailsView(group: group, onGone: { dismiss() }) }
        }
        .sheet(isPresented: $showLeaderboard) { LeaderboardSheet(memberIds: memberIds) }
        .task {
            _ = await app.profiles(for: memberIds)
            await app.refreshPeopleTastes(memberIds)
            await loadNewest()
        }
        .onChange(of: group == nil) { _, gone in if gone { dismiss() } }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-spin") {
                try? await Task.sleep(for: .seconds(1.5))
                spin()
            }
        }
        #endif
    }

    // ── The table ────────────────────────────────────────────────────────────

    private var seats: [TableSeat] {
        var seats = memberIds.prefix(8).map { id in
            TableSeat(id: id.uuidString, profile: app.profile(id), lastCuisine: newest[id])
        }
        while seats.count < 4 { seats.append(.empty(seats.count)) }
        return seats
    }

    private var header: some View {
        let between = app.tasted(by: memberIds)
        let everyone = app.tastedByEveryone(memberIds)
        return VStack(spacing: 6) {
            ZStack {
                RoundTable(seats: seats, cloth: cloth, seatSize: 40, onEmptySeat: { showDetails = true }) {
                    lazySusan
                }
                .frame(width: 290, height: 290)
                if let dropped {
                    SpinCoaster(code: dropped, size: 150)
                        .transition(.scale(scale: 1.8).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    legend(fill: GlobeStyle(scheme).tasted(GlobeStyle(scheme).shared, meals: 3, selected: false),
                           text: "\(everyone.count) all of you")
                    legend(fill: GlobeStyle(scheme).tastedByOthers(GlobeStyle(scheme).shared, selected: false),
                           text: "\(max(0, between.count - everyone.count)) some of you")
                    Text("\(max(0, Cuisine.codes.count - between.count)) none of you — yet")
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                }
                Spacer(minLength: 0)
                SpinButton(spinning: spinning, size: 66) { spin() }
                    .disabled(spinning)
                    .accessibilityLabel("Spin for the table")
                    .accessibilityHint("Lands on a cuisine none of you has had.")
            }
            .padding(.horizontal, Metrics.gutter + 4)
            .padding(.bottom, 8)
        }
        .padding(.top, 4)
    }

    /// The table's globe, on a turntable in the middle.
    private var lazySusan: some View {
        let counts = tasteCounts
        let members = max(1, memberIds.count)
        let landed = self.landed
        return Plate(rim: 0.1, band: cloth.opacity(0.5)) {
            GlobeCanvas(
                style: GlobeStyle(scheme),
                color: { code, isSelected in
                    let style = GlobeStyle(scheme)
                    let n = counts[code] ?? 0
                    if n == 0 { return code == landed ? style.landed(selected: isSelected) : style.untouched(selected: isSelected) }
                    if n >= members { return style.tasted(style.shared, meals: 3, selected: isSelected) }
                    return style.tastedByOthers(style.shared, selected: isSelected)
                },
                selected: $selected,
                focusOn: $focus,
                onFocusLanded: landedOn,
                isEmphasized: { (counts[$0] ?? 0) > 0 || $0 == landed },
                landingBias: 0,
                fitMargin: 1.04
            )
            .accessibilityElement()
            .accessibilityLabel("The table's globe")
            .accessibilityValue("\(counts.count) cuisines between you")
            .accessibilityAction(named: "Spin for the table") { spin() }
        }
        .frame(width: 142, height: 142)
    }

    /// How many at the table have tasted each cuisine.
    private var tasteCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for id in memberIds {
            for code in app.tasted(by: [id]) { counts[code, default: 0] += 1 }
        }
        return counts
    }

    private func legend(fill: UIColor, text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(uiColor: fill)).frame(width: 10, height: 10)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(Color.ink)
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 10) {
            AvatarStack(profiles: memberIds.compactMap { app.profile($0) }, size: 26, max: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(memberIds.count) at the table")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                Text("\(app.tasted(by: memberIds).count.counted("cuisine")) between you")
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
            }
            Spacer()
            SpinButton(spinning: spinning, size: 44) {
                composing = false
                spin()
            }
            .disabled(spinning)
            .accessibilityLabel("Spin for the table")
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 8)
    }

    // ── Spinning ─────────────────────────────────────────────────────────────

    private func spin() {
        guard !spinning, let pick = app.spinPool(for: groupId).randomElement() else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        selected = nil
        landed = nil
        withAnimation(.easeOut(duration: 0.2)) { dropped = nil }
        spinning = true
        focus = .init(id: UUID(), code: pick, style: .spin)
        app.backend.logEvent("globe_spun", props: ["table": "true"])
    }

    private func spinAgain() {
        result = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            spin()
        }
    }

    private func landedOn(_ code: String?) {
        focus = nil
        let wasSpin = spinning
        spinning = false
        guard let code else { return }
        guard wasSpin else {
            selected = code
            return
        }
        landed = code
        withAnimation(.spring(response: 0.38, dampingFraction: 0.58)) { dropped = code }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            try? await Task.sleep(for: .milliseconds(1150))
            guard landed == code, dropped == code else { return }
            result = SpinResult(code: code, fromSpin: true)
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.25)) { dropped = nil }
        }
    }

    private func loadNewest() async {
        guard let recent = try? await app.backend.recentTastes(userIds: memberIds, limit: 60) else { return }
        var latest: [UUID: String] = [:]
        for taste in recent.sorted(by: { $0.createdAt > $1.createdAt }) where latest[taste.userId] == nil {
            latest[taste.userId] = taste.countryCode
        }
        newest = latest
    }
}

/// Friendly competition: who's eaten the most of the world.
struct LeaderboardSheet: View {
    let memberIds: [UUID]

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tastes: [Taste] = []

    private struct Standing: Identifiable {
        let profile: Profile
        let stats: FoodStats
        let newThisYear: Int
        var id: UUID { profile.id }
    }

    private var standings: [Standing] {
        let year = Calendar.current.component(.year, from: Date())
        return memberIds.compactMap { id -> Standing? in
            guard let profile = app.profile(id) else { return nil }
            let theirs = id == app.myId ? app.tastes : tastes.filter { $0.userId == id }
            return Standing(profile: profile, stats: FoodStats(tastes: theirs, meals: []),
                            newThisYear: FoodStats.newCuisines(in: year, tastes: theirs).count)
        }
        .sorted { ($0.stats.cuisines, $0.stats.continents, $1.profile.name)
            > ($1.stats.cuisines, $1.stats.continents, $0.profile.name) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(standings.enumerated()), id: \.element.id) { index, standing in
                    HStack(spacing: 12) {
                        Text(medal(index))
                            .font(index < 3 ? .title2 : .headline)
                            .frame(width: 34)
                        AvatarView(profile: standing.profile, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(standing.profile.id == app.myId ? "You" : standing.profile.name)
                                .font(.headline)
                            Text("\(standing.stats.continents) of 6 continents\(standing.newThisYear > 0 ? " · \(standing.newThisYear) new this year" : "")")
                                .font(.caption)
                                .foregroundStyle(Color.inkSecondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(standing.stats.worldPercentText).font(.number(.title2)).monospacedDigit()
                            Text(standing.stats.cuisines.counted("cuisine")).font(.caption2).foregroundStyle(Color.inkSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.card)
                }
            }
            .paperListStyle()
            .navigationTitle("Most of the world")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { tastes = (try? await app.backend.tastes(userIds: memberIds)) ?? [] }
        }
        .presentationDetents([.medium, .large])
    }

    private func medal(_ index: Int) -> String {
        switch index {
        case 0: "🥇"
        case 1: "🥈"
        case 2: "🥉"
        default: "\(index + 1)"
        }
    }
}
