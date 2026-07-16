import SwiftUI
import SceneKit
import simd

/// Reusable SceneKit globe: ocean sphere + tinted country caps + hairline
/// borders + zoom-gated name labels, recolored via a closure and reporting
/// taps. Shared by the personal globe (GlobeSceneView) and the group globe
/// (GroupGlobeView) so the geometry/build lives in one place.
///
/// The SCNView renders transparent so the SwiftUI layer behind it owns the
/// backdrop (paper gradient, halo, progress chips).
struct GlobeCanvas: UIViewRepresentable {
    /// One-shot request to spin the globe and land on a country (new UUID per spin).
    struct SpinRequest: Equatable {
        let id: UUID
        let code: String
    }

    /// Cap color for a country code, given whether it's the current selection.
    var color: (_ code: String, _ selected: Bool) -> UIColor
    @Binding var selected: String?
    /// Set to a fresh SpinRequest to spin-and-land; cleared by the caller in onSpinLanded.
    var spinTo: Binding<SpinRequest?> = .constant(nil)
    /// Fires after the spin settles on its country (haptic already played).
    var onSpinLanded: ((String) -> Void)? = nil
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
        view.delegate = context.coordinator // label visibility per frame

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

        if let request = spinTo.wrappedValue, request.id != coordinator.lastSpinId {
            coordinator.lastSpinId = request.id
            coordinator.spin(to: request.code, onLanded: onSpinLanded)
        }
    }

    private func buildScene(into coordinator: Coordinator) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        // Everything that should rotate as one unit lives under globeNode
        // (the spin animation rotates this, not the camera).
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

        // Labels are a few hundred ms of SCNText tessellation on first build —
        // assemble off-main, attach on main so the tab opens instantly.
        DispatchQueue.global(qos: .userInitiated).async {
            let labels = GlobeDecor.labelNodes()
            DispatchQueue.main.async {
                guard let globeNode = coordinator.globeNode else { return }
                labels.forEach { globeNode.addChildNode($0.node) }
                coordinator.labels = labels
            }
        }

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

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var countryNodes: [String: SCNNode] = [:]
        var labels: [GlobeDecor.Label] = []
        var cameraNode = SCNNode()
        var globeNode: SCNNode?
        weak var scnView: SCNView?
        var onLongPress: ((String) -> Void)?
        var lastSpinId: UUID?

        private var selected: Binding<String?>
        private var outlineNode: SCNNode?
        private var outlineCode: String?
        private var spinning = false

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

        // ── Spin-to-country ──────────────────────────────────────────────────

        /// Two beats: a fast eased wind-up spin, then an exact settle that
        /// brings the country's centroid to face the camera.
        func spin(to code: String, onLanded: ((String) -> Void)?) {
            guard !spinning,
                  let view = scnView,
                  let globe = globeNode,
                  let country = CountryStore.byCode[code] else { return }
            spinning = true
            view.allowsCameraControl = false

            let target = GlobeMath.vec3(lat: country.centroid.lat, lng: country.centroid.lng, radius: 1)
            let targetLocal = simd_normalize(simd_float3(target.x, target.y, target.z))

            let windUp = SCNAction.rotateBy(x: 0, y: -.pi * 4, z: 0, duration: 1.15)
            windUp.timingMode = .easeIn
            globe.runAction(windUp) { [weak self] in
                DispatchQueue.main.async {
                    self?.settle(on: targetLocal, code: code, onLanded: onLanded)
                }
            }
        }

        private func settle(on targetLocal: simd_float3, code: String, onLanded: ((String) -> Void)?) {
            guard let view = scnView, let globe = globeNode, let pov = view.pointOfView else {
                spinning = false
                return
            }
            let camDir = simd_normalize(pov.presentation.simdWorldPosition)
            let q0 = globe.simdOrientation
            let currentDir = simd_normalize(simd_act(q0, targetLocal))
            let correction = simd_quatf(from: currentDir, to: camDir)

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.9
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            SCNTransaction.completionBlock = { [weak self] in
                DispatchQueue.main.async {
                    self?.spinning = false
                    view.allowsCameraControl = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onLanded?(code)
                }
            }
            globe.simdOrientation = simd_normalize(correction * q0)
            SCNTransaction.commit()
        }

        // ── Label visibility (per rendered frame) ────────────────────────────

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard !labels.isEmpty, let pov = scnView?.pointOfView else { return }
            let camPos = pov.presentation.simdWorldPosition
            let distance = simd_length(camPos)
            guard distance > 0.001 else { return }
            let camDir = camPos / distance
            let scale = GlobeDecor.labelBaseScale * max(0.45, distance / 3.2)

            for label in labels {
                let worldDir = simd_normalize(label.node.presentation.simdWorldPosition)
                // Labels ignore the depth buffer (no half-sunk glyphs), so the
                // far-side cull here is what keeps them off the back of the globe.
                let facing = simd_dot(worldDir, camDir)
                let visible = facing > 0.35 && distance < label.tier.showsBelowDistance
                if label.node.isHidden == visible { label.node.isHidden = !visible }
                if visible, abs(label.node.scale.x - scale) > 0.0002 {
                    label.node.scale = SCNVector3(scale, scale, scale)
                }
            }
        }
    }
}
