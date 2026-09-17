import SwiftUI

/// Four tabs, each with one job: explore your world, see your friends'
/// travels, plan with your groups, and your passport.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var tab: Tab = RootView.initialTab

    enum Tab: String {
        case globe, friends, groups, passport
    }

    var body: some View {
        @Bindable var app = app
        TabView(selection: $tab) {
            GlobeScreen()
                .tabItem { Label("Globe", image: "tab-globe") }
                .tag(Tab.globe)
            FriendsView()
                .tabItem { Label("Friends", image: "tab-people") }
                .tag(Tab.friends)
                .badge(app.unseenActivity > 0 ? Text("\(app.unseenActivity)") : nil)
            GroupsView()
                .tabItem { Label("Groups", image: "tab-groups") }
                .tag(Tab.groups)
            PassportView()
                .tabItem { Label("Passport", image: "tab-profile") }
                .tag(Tab.passport)
        }
        .fullScreenCover(isPresented: $app.needsOnboarding) {
            OnboardingView()
        }
        .sheet(item: $app.route) { route in
            switch route {
            case .memory(let id):
                MemoryLoaderSheet(memoryId: id)
            case .joinGroup(let code):
                JoinGroupSheet(code: code) { tab = .groups }
            case .profile(let id):
                NavigationStack {
                    ProfileView(userId: id)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { app.route = nil }
                            }
                        }
                }
            }
        }
        .task { await app.checkActivity() }
        #if DEBUG
        .sheet(item: $debugScreen) { screen in
            switch screen {
            case .editor: MemoryEditorView(mode: .new(countryCode: "PT", pickPhotosFirst: false))
            case .importPhotos: NavigationStack { PhotoImportView(onDone: { debugScreen = nil }) }
            case .checklist: NavigationStack { CountryChecklistView(onDone: { debugScreen = nil }) }
            case .wrapped: NavigationStack { WrappedView() }
            case .settings: SettingsView()
            case .memory:
                if let memory = app.memories.first(where: { !$0.photos.isEmpty && $0.notes != nil }) {
                    MemoryDetailView(memory: memory)
                }
            case .country: CountryMemoriesSheet(code: Self.debugCountry)
            case .planTrip: TripPlanEditorSheet(mode: .new(countryCode: Self.debugCountry))
            case .trip:
                if let plan = app.tripPlans.first(where: { !$0.isOver }) {
                    TripPlanDetailSheet(plan: plan)
                }
            case .stamp: StampMomentView(codes: ["PT"], number: 21, date: "2026-09-10") { debugScreen = nil }
            case .burst: StampMomentView(codes: ["DE", "NL", "CZ", "AT", "HU"]) { debugScreen = nil }
            }
        }
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-open"), i + 1 < args.count,
               let screen = DebugScreen(rawValue: args[i + 1]) {
                try? await Task.sleep(for: .seconds(1))
                debugScreen = screen
            }
        }
        #endif
    }

    #if DEBUG
    /// Headless screenshot hook: `-open editor|import|checklist|wrapped|settings|memory|stamp|burst|trip|country|plan`.
    enum DebugScreen: String, Identifiable {
        case editor, importPhotos = "import", checklist, wrapped, settings, memory, stamp, burst, trip, country, planTrip = "plan"
        var id: String { rawValue }
    }
    @State private var debugScreen: DebugScreen?

    /// `-open country -code ES`
    private static var debugCountry: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-code"), i + 1 < args.count { return args[i + 1].uppercased() }
        return "JP"
    }
    #endif

    /// Headless test hook: `-tab friends` opens on that tab.
    private static var initialTab: Tab {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let tab = Tab(rawValue: args[i + 1]) {
            return tab
        }
        #endif
        return .globe
    }
}

/// Opens a memory by id (notification taps, links).
struct MemoryLoaderSheet: View {
    let memoryId: UUID

    @Environment(AppModel.self) private var app
    @State private var memory: Memory?
    @State private var missing = false

    var body: some View {
        SwiftUI.Group {
            if let memory {
                MemoryDetailView(memory: memory)
            } else if missing {
                NavigationStack {
                    EmptyStateView(systemImage: "photo.on.rectangle.angled",
                                   title: "Memory unavailable",
                                   message: "It may have been deleted, or it isn't shared with you.")
                        .frame(maxHeight: .infinity)
                        .paperBackground()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).paperBackground()
            }
        }
        .task {
            if let local = app.memories.first(where: { $0.id == memoryId }) {
                memory = local
            } else if let fetched = try? await app.backend.memory(id: memoryId) {
                memory = fetched
            } else {
                missing = true
            }
        }
    }
}

/// "Join Europe 2027?" from an invite link.
struct JoinGroupSheet: View {
    let code: String
    var onJoined: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.brand)
                .frame(width: 80, height: 80)
                .background(Color.brandSoft, in: Circle())
            VStack(spacing: 6) {
                Text("Join a travel group?")
                    .font(.displaySmall)
                Text("You were invited with the code \(Text(code).font(.body.monospaced()).bold()). Members see each other's friends-only memories and share a globe.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(busy ? "Joining…" : "Join group") {
                Task { await join() }
            }
            .buttonStyle(.primary)
            .disabled(busy)
            Button("Not now") { dismiss() }
                .foregroundStyle(Color.inkSecondary)
        }
        .padding(28)
        .frame(maxHeight: .infinity)
        .paperBackground()
        .presentationDetents([.medium])
    }

    private func join() async {
        busy = true
        defer { busy = false }
        do {
            try await app.joinGroup(code: code)
            app.celebrate("You're in! Say hi in the group chat.")
            onJoined()
            dismiss()
        } catch {
            app.show(error)
        }
    }
}
