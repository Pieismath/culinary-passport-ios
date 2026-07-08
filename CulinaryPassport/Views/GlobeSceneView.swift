import SwiftUI
import SceneKit

/// MVP step 2 — the globe. Real Natural Earth country polygons projected onto a
/// SceneKit sphere, tinted by try-status (port of the web GlobeView.tsx). Tap a
/// country for its panel; drag to spin, pinch to zoom (SceneKit camera control).
struct GlobeSceneView: View {
    @StateObject private var vm = GlobeViewModel()
    @State private var selectedCode: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            GlobeScene(vm: vm, selectedCode: $selectedCode)
                .ignoresSafeArea()

            if vm.loading {
                ProgressView().padding(.bottom, 40)
            }

            if let code = selectedCode, let country = CountryStore.byCode[code] {
                CountryPanel(
                    country: country,
                    tasters: vm.tasterNames(for: code),
                    entries: vm.entriesByCountry[code] ?? [],
                    onClose: { selectedCode = nil }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedCode)
        .task { await vm.load() }
        .overlay(alignment: .top) {
            if let error = vm.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(8).background(.thinMaterial, in: Capsule())
            }
        }
    }
}

// MARK: - SceneKit bridge

private struct GlobeScene: UIViewRepresentable {
    @ObservedObject var vm: GlobeViewModel
    @Binding var selectedCode: String?

    func makeCoordinator() -> Coordinator { Coordinator(selectedCode: $selectedCode) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = buildScene(into: context.coordinator)
        view.backgroundColor = UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1) // paper
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling2X
        view.pointOfView = context.coordinator.cameraNode

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.scnView = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        // Recolor whenever status loads or the selection changes.
        for (code, node) in context.coordinator.countryNodes {
            node.geometry?.firstMaterial?.diffuse.contents = vm.color(for: code, selected: code == selectedCode)
        }
    }

    private func buildScene(into coordinator: Coordinator) -> SCNScene {
        let scene = SCNScene()

        // Ocean sphere.
        let ocean = SCNSphere(radius: CGFloat(GlobeNodeFactory.oceanRadius))
        ocean.segmentCount = 96
        ocean.firstMaterial?.diffuse.contents = UIColor(red: 0.85, green: 0.89, blue: 0.92, alpha: 1)
        ocean.firstMaterial?.lightingModel = .constant
        scene.rootNode.addChildNode(SCNNode(geometry: ocean))

        // Country caps.
        for country in CountryStore.all {
            let color = vm.color(for: country.code, selected: false)
            if let node = GlobeNodeFactory.countryNode(code: country.code, color: color) {
                coordinator.countryNodes[country.code] = node
                scene.rootNode.addChildNode(node)
            }
        }

        // Camera.
        let camera = SCNCamera()
        camera.fieldOfView = 40
        let cam = SCNNode()
        cam.camera = camera
        cam.position = SCNVector3(0, 0, 3.2)
        scene.rootNode.addChildNode(cam)
        coordinator.cameraNode = cam

        return scene
    }

    final class Coordinator: NSObject {
        var countryNodes: [String: SCNNode] = [:]
        var cameraNode = SCNNode()
        weak var scnView: SCNView?
        private var selectedCode: Binding<String?>

        init(selectedCode: Binding<String?>) { self.selectedCode = selectedCode }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = scnView else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
            // Walk up to the first node carrying a country code.
            for hit in hits {
                var node: SCNNode? = hit.node
                while let n = node {
                    if let code = n.name, code.count == 2 {
                        selectedCode.wrappedValue = (selectedCode.wrappedValue == code) ? nil : code
                        return
                    }
                    node = n.parent
                }
            }
            selectedCode.wrappedValue = nil // tapped the ocean
        }
    }
}

// MARK: - Detail panel

private struct CountryPanel: View {
    let country: Country
    let tasters: [String]
    let entries: [Entry]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(country.flagEmoji).font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(country.cuisineName).font(.headline)
                    Text(country.subregion.isEmpty ? country.continent : country.subregion)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }

            if tasters.isEmpty {
                Label("Not tried yet", systemImage: "circle.dashed")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Label(tasters.joined(separator: " & "), systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                if !entries.isEmpty {
                    Divider()
                    ForEach(entries.prefix(3)) { entry in
                        HStack {
                            Text(entry.restaurantName).font(.subheadline)
                            Spacer()
                            Text(String(repeating: "★", count: entry.rating))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if entries.count > 3 {
                        Text("+\(entries.count - 3) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 12, y: 4)
    }
}
