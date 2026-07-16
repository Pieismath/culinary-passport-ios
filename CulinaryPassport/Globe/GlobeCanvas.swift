import SwiftUI
import SceneKit
import simd

/// Reusable SceneKit globe: ocean sphere + tinted country caps + hairline
/// borders, recolored via a closure and reporting taps. Shared by the personal
/// globe (GlobeSceneView) and the group globe (GroupGlobeView).
///
/// Interaction is map-style, NOT SceneKit's built-in arcball: the camera never
/// moves — one finger rotates the GLOBE (yaw unbounded, pitch clamped at the
/// poles, north always up, flick inertia), two fingers pinch-zoom the camera
/// distance. SceneKit's `allowsCameraControl` is deliberately unused: its
/// arcball flips upside down past a pole, which inverts drag direction and
/// made fly-to landings look rolled.
///
/// The SCNView renders transparent so the SwiftUI layer behind it owns the
/// backdrop (paper gradient, halo, progress chips).
struct GlobeCanvas: UIViewRepresentable {
    /// One-shot request to rotate the globe onto a country (new UUID per request).
    struct FocusRequest: Equatable {
        enum Style {
            case spin   // a couple of full revolutions on the way (the dice)
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
    /// Fires when the rotation ends: the country code on landing, or nil if the
    /// user grabbed the globe mid-flight and cancelled it.
    var onFocusLanded: ((String?) -> Void)? = nil
    /// Long-press on a country — the "log this cuisine right here" gesture.
    var onLongPress: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = buildScene(into: context.coordinator)
        view.backgroundColor = .clear // SwiftUI backdrop shows through
        view.isOpaque = false
        view.antialiasingMode = .multisampling2X
        view.pointOfView = context.coordinator.cameraNode

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        hold.minimumPressDuration = 0.45
        view.addGestureRecognizer(hold)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1 // two fingers belong to pinch
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

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

        // Everything that rotates lives under globeNode; the camera is fixed.
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
        // paper margin.
        cam.position = SCNVector3(0, 0, Coordinator.defaultCameraZ)
        scene.rootNode.addChildNode(cam)
        coordinator.cameraNode = cam

        return scene
    }

    final class Coordinator: NSObject {
        static let defaultCameraZ: Float = 6.9

        var countryNodes: [String: SCNNode] = [:]
        var cameraNode = SCNNode()
        var globeNode: SCNNode?
        weak var scnView: SCNView?
        var onLongPress: ((String) -> Void)?
        var lastFocusId: UUID?

        private var selected: Binding<String?>
        private var outlineNode: SCNNode?
        private var outlineCode: String?

        // ── Orientation state: north can never roll ──────────────────────────
        // orientation = Rx(pitch) · Ry(yaw). Yaw spins around the earth's axis
        // (turntable), pitch tilts toward the poles and is clamped, so the
        // globe can never flip and drags always track the finger.
        private var yaw: Float = 0
        private var pitch: Float = 0
        private let pitchLimit: Float = 1.45 // ~83°, matches map apps
        private var cameraZ: Float = Coordinator.defaultCameraZ

        private enum Drive {
            case idle
            case inertia(vYaw: Float, vPitch: Float)
            case animate(fromYaw: Float, fromPitch: Float, toYaw: Float, toPitch: Float,
                         start: CFTimeInterval, duration: CFTimeInterval,
                         code: String, haptic: UIImpactFeedbackGenerator.FeedbackStyle,
                         onLanded: ((String?) -> Void)?)
        }

        private var drive: Drive = .idle
        private var displayLink: CADisplayLink?
        private var lastTick: CFTimeInterval = 0

        init(selected: Binding<String?>) { self.selected = selected }

        deinit { displayLink?.invalidate() }

        // ── Gestures ─────────────────────────────────────────────────────────

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

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = scnView else { return }
            switch gesture.state {
            case .began:
                cancelDrive() // grabbing the globe interrupts inertia / fly
            case .changed:
                let t = gesture.translation(in: view)
                gesture.setTranslation(.zero, in: view)
                let k = radiansPerPoint(in: view)
                yaw += Float(t.x) * k
                pitch = max(-pitchLimit, min(pitchLimit, pitch + Float(t.y) * k))
                applyOrientation()
            case .ended:
                let v = gesture.velocity(in: view)
                let k = radiansPerPoint(in: view)
                let vYaw = Float(v.x) * k
                let vPitch = Float(v.y) * k
                if abs(vYaw) > 0.02 || abs(vPitch) > 0.02 {
                    drive = .inertia(vYaw: vYaw, vPitch: vPitch)
                    startTicking()
                }
            default:
                break
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .changed else { return }
            cameraZ = max(4.2, min(10.5, cameraZ / Float(gesture.scale)))
            gesture.scale = 1
            cameraNode.position.z = cameraZ
        }

        /// Content-follows-finger: one point of drag ≈ the arc it covers on the
        /// visible face, so sensitivity tracks the zoom level.
        private func radiansPerPoint(in view: SCNView) -> Float {
            let width = Float(view.bounds.width)
            guard width > 0 else { return 0.005 }
            return cameraZ / (3.45 * width)
        }

        /// Resolve a touch to a country GEOGRAPHICALLY: any hit on the globe
        /// (ocean, cap, or border line) gives a sphere point → lat/lng →
        /// ring lookup. Never depends on which node the ray-cast happened to
        /// return — cap triangles are back-face-culled out of hit results and
        /// the borders node shadows everything else, which is why the old
        /// node-name walk always came up empty.
        private func countryCode(at point: CGPoint?) -> String? {
            guard let view = scnView, let point, let globe = globeNode else { return nil }
            let hits = view.hitTest(point, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue,
                SCNHitTestOption.backFaceCulling: false,
            ])
            guard let hit = hits.first else { return nil }
            let world = simd_float3(hit.worldCoordinates.x, hit.worldCoordinates.y, hit.worldCoordinates.z)
            let local = globe.presentation.simdConvertPosition(world, from: nil)
            let radius = simd_length(local)
            guard radius > 0.5 else { return nil }
            let lat = asin(max(-1, min(1, Double(local.y) / Double(radius)))) * 180 / .pi
            let lng = atan2(Double(local.x), Double(local.z)) * 180 / .pi
            return CountryGeometry.country(atLat: lat, lng: lng)
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

        /// Rotate the globe so `code`'s centroid faces the camera, north up.
        /// Landing orientation is yaw = −lng, pitch = +lat — a direct
        /// construction with no degenerate cases (the old shortest-arc
        /// quaternion could roll the globe or go NaN near-antipodal, which is
        /// what "landed upside down" and "then it locked up" were).
        func focus(on code: String, style: FocusRequest.Style, onLanded: ((String?) -> Void)?) {
            guard let country = CountryStore.byCode[code] else {
                onLanded?(nil)
                return
            }
            cancelDrive()

            let toPitch = Float(country.centroid.lat * .pi / 180)
            var toYaw = Float(-country.centroid.lng * .pi / 180)

            // Take the short way around from the current yaw…
            let twoPi = Float.pi * 2
            var delta = (toYaw - yaw).truncatingRemainder(dividingBy: twoPi)
            if delta > .pi { delta -= twoPi }
            if delta < -.pi { delta += twoPi }
            toYaw = yaw + delta

            let duration: CFTimeInterval
            let haptic: UIImpactFeedbackGenerator.FeedbackStyle
            switch style {
            case .spin:
                toYaw -= twoPi * 2 // …plus two full revolutions for the dice
                duration = 1.9
                haptic = .medium
            case .fly:
                duration = 0.75
                haptic = .light
            }

            drive = .animate(fromYaw: yaw, fromPitch: pitch, toYaw: toYaw,
                             toPitch: min(pitchLimit, max(-pitchLimit, toPitch)),
                             start: CACurrentMediaTime(), duration: duration,
                             code: code, haptic: haptic, onLanded: onLanded)
            startTicking()
        }

        /// Interrupt whatever motion is running (user grabbed the globe).
        private func cancelDrive() {
            if case let .animate(_, _, _, _, _, _, _, _, onLanded) = drive {
                onLanded?(nil)
            }
            drive = .idle
            displayLink?.isPaused = true
        }

        // ── Display-link motor (inertia + focus animations) ──────────────────

        private func startTicking() {
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            lastTick = CACurrentMediaTime()
            displayLink?.isPaused = false
        }

        @objc private func tick() {
            let now = CACurrentMediaTime()
            let dt = Float(min(now - lastTick, 1.0 / 30.0))
            lastTick = now

            switch drive {
            case .idle:
                displayLink?.isPaused = true

            case .inertia(var vYaw, var vPitch):
                yaw += vYaw * dt
                pitch = max(-pitchLimit, min(pitchLimit, pitch + vPitch * dt))
                let decay = exp(-3.5 * dt)
                vYaw *= decay
                vPitch *= decay
                if abs(vYaw) < 0.015 && abs(vPitch) < 0.015 {
                    drive = .idle
                    displayLink?.isPaused = true
                } else {
                    drive = .inertia(vYaw: vYaw, vPitch: vPitch)
                }
                applyOrientation()

            case let .animate(fromYaw, fromPitch, toYaw, toPitch, start, duration, code, haptic, onLanded):
                let raw = Float((now - start) / duration)
                let t = min(1, max(0, raw))
                // easeInOut cubic: winds up, coasts, settles
                let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
                yaw = fromYaw + (toYaw - fromYaw) * eased
                pitch = fromPitch + (toPitch - fromPitch) * eased
                applyOrientation()
                if t >= 1 {
                    drive = .idle
                    displayLink?.isPaused = true
                    UIImpactFeedbackGenerator(style: haptic).impactOccurred()
                    onLanded?(code)
                }
            }
        }

        private func applyOrientation() {
            let qPitch = simd_quatf(angle: pitch, axis: simd_float3(1, 0, 0))
            let qYaw = simd_quatf(angle: yaw, axis: simd_float3(0, 1, 0))
            globeNode?.simdOrientation = qPitch * qYaw
        }
    }
}
