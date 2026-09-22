import SwiftUI

/// Three tabs, each with one job: your world and the spin, the tables you
/// eat with, and your food passport.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var tab: Tab = RootView.initialTab
    @State private var openTable: UUID?

    enum Tab: String {
        case globe, tables, me
    }

    var body: some View {
        @Bindable var app = app
        TabView(selection: $tab) {
            GlobeScreen()
                .tabItem { Label("Globe", image: "tab-globe") }
                .tag(Tab.globe)
            TablesView(open: $openTable)
                .tabItem { Label("Tables", image: "tab-groups") }
                .tag(Tab.tables)
                .badge(app.unseenActivity > 0 ? Text("\(app.unseenActivity)") : nil)
            MeView()
                .tabItem { Label("Me", image: "tab-profile") }
                .tag(Tab.me)
        }
        .fullScreenCover(isPresented: $app.needsOnboarding) {
            OnboardingView()
        }
        .sheet(item: $app.route) { route in
            switch route {
            case .meal(let id):
                MealLoaderSheet(mealId: id)
            case .joinGroup(let code):
                JoinTableSheet(code: code) { id in
                    tab = .tables
                    openTable = id
                }
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
            case .meal: MealEditorView(mode: .new(cuisine: nil, place: nil))
            case .detail:
                if let meal = app.meals.first(where: { !$0.photos.isEmpty && $0.notes != nil }) {
                    MealDetailView(meal: meal)
                }
            case .settings: SettingsView()
            case .cuisine: CuisineSheet(code: Self.debugCode)
            case .cuisines: NavigationStack { CuisineChecklistView(onDone: { debugScreen = nil }) }
            case .spin: SpinResultSheet(code: Self.debugCode, tableId: nil)
            case .tableSpin: SpinResultSheet(code: Self.debugCode, tableId: DemoData.dinnerClub)
            case .share:
                ShareCard {
                    PassportShareCard(profile: app.me, stats: app.stats,
                                      tastes: app.tastes.sorted { $0.createdAt > $1.createdAt })
                }
            case .stamp: StampMomentView(codes: ["GE"], number: 21, date: "2026-09-10", tasted: true) { debugScreen = nil }
            case .burst: StampMomentView(codes: ["TH", "VN", "KR", "ET", "PE"], tasted: true) { debugScreen = nil }
            }
        }
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-open"), i + 1 < args.count,
               let screen = DebugScreen(rawValue: args[i + 1]) {
                try? await Task.sleep(for: .seconds(1))
                debugScreen = screen
            }
            if let i = args.firstIndex(of: "-table"), i + 1 < args.count {
                try? await Task.sleep(for: .seconds(0.8))
                tab = .tables
                openTable = args[i + 1] == "club" ? DemoData.dinnerClub : UUID(uuidString: args[i + 1])
            }
        }
        #endif
    }

    #if DEBUG
    /// Headless screenshot hook: `-open meal|detail|settings|cuisine|cuisines|spin|tablespin|share|stamp|burst`.
    enum DebugScreen: String, Identifiable {
        case meal, detail, settings, cuisine, cuisines, spin, tableSpin = "tablespin", share, stamp, burst
        var id: String { rawValue }
    }
    @State private var debugScreen: DebugScreen?

    /// `-open cuisine -code ET`
    private static var debugCode: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-code"), i + 1 < args.count { return args[i + 1].uppercased() }
        return "ET"
    }
    #endif

    /// Headless test hook: `-tab tables` opens on that tab.
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

/// Opens a meal by id (notification taps, links).
struct MealLoaderSheet: View {
    let mealId: UUID

    @Environment(AppModel.self) private var app
    @State private var meal: Meal?
    @State private var missing = false

    var body: some View {
        SwiftUI.Group {
            if let meal {
                MealDetailView(meal: meal)
            } else if missing {
                NavigationStack {
                    EmptyStateView(systemImage: "fork.knife",
                                   title: "Meal unavailable",
                                   message: "It may have been deleted, or it isn't shared with you.")
                        .frame(maxHeight: .infinity)
                        .paperBackground()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).paperBackground()
            }
        }
        .task {
            if let local = app.meals.first(where: { $0.id == mealId }) {
                meal = local
            } else if let fetched = try? await app.backend.meal(id: mealId) {
                meal = fetched
            } else {
                missing = true
            }
        }
    }
}

/// "Pull up a chair?" from an invite link.
struct JoinTableSheet: View {
    let code: String
    var onJoined: (UUID) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        VStack(spacing: 18) {
            RoundTable(seats: (0..<4).map { TableSeat.empty($0) }, cloth: .brand, seatSize: 26, showsPlates: true) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.brand)
            }
            .frame(width: 140, height: 140)
            VStack(spacing: 6) {
                Text("Pull up a chair?")
                    .font(.displaySmall)
                Text("You were invited to a table with the code \(Text(code).font(.body.monospaced()).bold()). Everyone at it shares a globe, spins for dinner together, and sees each other's friends-only meals.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(busy ? "Joining…" : "Take a seat") {
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
        .presentationDetents([.medium, .large])
    }

    private func join() async {
        busy = true
        defer { busy = false }
        do {
            let id = try await app.joinGroup(code: code)
            app.celebrate("You're in! Say hi at the table.")
            dismiss()
            onJoined(id)
        } catch {
            app.show(error)
        }
    }
}
