import SwiftUI
import SceneKit
import simd

/// Reusable SceneKit globe: ocean sphere + tinted country caps + hairline
/// borders, recolored via a closure and reporting taps. Shared by the personal
/// globe (GlobeSceneView) and the group globe (GroupGlobeView) so the
/// geometry/build lives in one place.
///
/// The SCNView renders transparent so the SwiftUI layer behind it owns the
/// backdrop (paper gradient, halo, progress chips).
struct GlobeCanvas: UIViewRepresentable {
    /// One-shot request to rotate the globe onto a country (new UUID per request).
    struct FocusRequest: Equatable {
        enum Style {
            case spin   // dramatic wind-up first (the dice)
            case fly    // direct eased rotation (search / deep links)
        }

        let id: UUID
        let code: String
        var style: Style = .spin
    }

    /// Cap color for a country code, given whether it's the current selection.
    var color: (_ code: String, _ selected: Bool) -> UIColor
    @Binding var selected: String?
    /// Set to a fresh FocusRequest to rotate there; cleared by the caller in onFocusLanded.
    var focusOn: Binding<FocusRequest?> = .constant(nil)
    /// Fires after the globe settles on the requested country (haptic already played).
    var onFocusLanded: ((String) -> Void)? = nil
    /// Long-press on a country — the "log this cuisine right here" gesture.
    var onLongPress: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = buildScene(into: context.coordinator)
        view.backgroundColor = .clear // SwiftUI backdrop shows through
        view.isOpaque = false
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling2X
        view.pointOfView = context.coordinator.cameraNode

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        hold.minimumPressDuration = 0.45
        view.addGestureRecognizer(hold)

        context.coordinator.scnView = view
        context.coordinator.onLongPress = onLongPress
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onLongPress = onLongPress

        for (code, node) in coordinator.countryNodes {
            node.geometry?.firstMaterial?.diffuse.contents = color(code, code == selected)
        }
        coordinator.showOutline(for: selected)

        if let request = focusOn.wrappedValue, request.id != coordinator.lastFocusId {
            coordinator.lastFocusId = request.id
            coordinator.focus(on: request.code, style: request.style, onLanded: onFocusLanded)
        }
    }

    private func buildScene(into coordinator: Coordinator) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        // Everything that should rotate as one unit lives under globeNode
        // (focus animations rotate this, not the camera).
        let globe = SCNNode()
        globe.name = "globe"
        scene.rootNode.addChildNode(globe)
        coordinator.globeNode = globe

        let ocean = SCNSphere(radius: CGFloat(GlobeNodeFactory.oceanRadius))
        ocean.segmentCount = 96
        ocean.firstMaterial?.diffuse.contents = GlobeViewModel.ocean
        ocean.firstMaterial?.lightingModel = .constant
        globe.addChildNode(SCNNode(geometry: ocean))

        for country in CountryStore.all {
            if let node = GlobeNodeFactory.countryNode(code: country.code, color: color(country.code, false)) {
                coordinator.countryNodes[country.code] = node
                globe.addChildNode(node)
            }
        }

        globe.addChildNode(GlobeDecor.bordersNode())

        let camera = SCNCamera()
        camera.fieldOfView = 40
        let cam = SCNNode()
        cam.camera = camera
        // Portrait phones: the vertical FOV maps to a ~19° horizontal FOV, so
        // the whole globe needs ~6.9 units of distance to fit the width with a
        // paper margin (3.2 filled the screen edge-to-edge).
        cam.position = SCNVector3(0, 0, 6.9)
        scene.rootNode.addChildNode(cam)
        coordinator.cameraNode = cam

        return scene
    }

    final class Coordinator: NSObject {
        var countryNodes: [String: SCNNode] = [:]
        var cameraNode = SCNNode()
        var globeNode: SCNNode?
        weak var scnView: SCNView?
        var onLongPress: ((String) -> Void)?
        var lastFocusId: UUID?

        private var selected: Binding<String?>
        private var outlineNode: SCNNode?
        private var outlineCode: String?
        private var focusing = false

        init(selected: Binding<String?>) { self.selected = selected }

        // ── Tap / long-press ─────────────────────────────────────────────────

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let code = countryCode(at: gesture.location(in: scnView)) else {
                selected.wrappedValue = nil
                return
            }
            selected.wrappedValue = (selected.wrappedValue == code) ? nil : code
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let code = countryCode(at: gesture.location(in: scnView)) else { return }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            selected.wrappedValue = code
            onLongPress?(code)
        }

        private func countryCode(at point: CGPoint?) -> String? {
            guard let view = scnView, let point else { return nil }
            let hits = view.hitTest(point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let n = node {
                    if let code = n.name, code.count == 2 { return code }
                    node = n.parent
                }
            }
            return nil
        }

        // ── Selection outline ────────────────────────────────────────────────

        func showOutline(for code: String?) {
            guard code != outlineCode else { return }
            outlineNode?.removeFromParentNode()
            outlineNode = nil
            outlineCode = code
            if let code, let node = GlobeDecor.outlineNode(code: code) {
                globeNode?.addChildNode(node)
                outlineNode = node
            }
        }

        // ── Focus (spin / fly) ───────────────────────────────────────────────

        /// .spin: a fast eased wind-up, then an exact settle onto the country.
        /// .fly: the settle alone — used when the user picked the destination
        /// (search), where drama would just be latency.
        func focus(on code: String, style: FocusRequest.Style, onLanded: ((String) -> Void)?) {
            guard !focusing,
                  let view = scnView,
                  let globe = globeNode,
                  let country = CountryStore.byCode[code] else { return }
            focusing = true
            view.allowsCameraControl = false

            let target = GlobeMath.vec3(lat: country.centroid.lat, lng: country.centroid.lng, radius: 1)
            let targetLocal = simd_normalize(simd_float3(target.x, target.y, target.z))

            switch style {
            case .spin:
                let windUp = SCNAction.rotateBy(x: 0, y: -.pi * 4, z: 0, duration: 1.15)
                windUp.timingMode = .easeIn
                globe.runAction(windUp) { [weak self] in
                    DispatchQueue.main.async {
                        self?.settle(on: targetLocal, code: code, duration: 0.9,
                                     haptic: .medium, onLanded: onLanded)
                    }
                }
            case .fly:
                settle(on: targetLocal, code: code, duration: 0.75, haptic: .light, onLanded: onLanded)
            }
        }

        private func settle(on targetLocal: simd_float3, code: String, duration: CFTimeInterval,
                            haptic: UIImpactFeedbackGenerator.FeedbackStyle,
                            onLanded: ((String) -> Void)?) {
            guard let view = scnView, let globe = globeNode, let pov = view.pointOfView else {
                focusing = false
                return
            }
            let camDir = simd_normalize(pov.presentation.simdWorldPosition)
            let q0 = globe.simdOrientation
            let currentDir = simd_normalize(simd_act(q0, targetLocal))
            let correction = simd_quatf(from: currentDir, to: camDir)

            SCNTransaction.begin()
            SCNTransaction.animationDuration = duration
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            SCNTransaction.completionBlock = { [weak self] in
                DispatchQueue.main.async {
                    self?.focusing = false
                    view.allowsCameraControl = true
                    UIImpactFeedbackGenerator(style: haptic).impactOccurred()
                    onLanded?(code)
                }
            }
            globe.simdOrientation = simd_normalize(correction * q0)
            SCNTransaction.commit()
        }
    }
}
