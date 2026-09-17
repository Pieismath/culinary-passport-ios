import SwiftUI
import SceneKit
import simd

/// Colors for one globe appearance. SceneKit materials don't resolve dynamic
/// UIColors, so light and dark are explicit and re-applied on change.
struct GlobeStyle: Equatable {
    let isDark: Bool

    init(_ scheme: ColorScheme) { isDark = scheme == .dark }

    var ocean: UIColor { isDark ? UIColor(rgb: 0x1B2833) : UIColor(red: 0.85, green: 0.89, blue: 0.92, alpha: 1) }
    /// Untouched land.
    var land: UIColor { isDark ? UIColor(rgb: 0x3A362E) : UIColor(rgb: 0xDDD6C7) }
    var border: UIColor {
        isDark ? UIColor(rgb: 0x9A907E, alpha: 0.9) : UIColor(red: 0.34, green: 0.29, blue: 0.21, alpha: 0.92)
    }
    var selected: UIColor { isDark ? UIColor(rgb: 0xF6F1E7) : UIColor(red: 0.24, green: 0.19, blue: 0.13, alpha: 0.95) }
    var bucket: UIColor { isDark ? UIColor(rgb: 0xE4AE55) : UIColor(rgb: 0xD9A04A) }
    var shared: UIColor { isDark ? UIColor(rgb: 0xA58BEA) : UIColor(rgb: 0x8B6FD8) }

    /// Visited tint that deepens with every memory, saturating around five.
    func visited(_ tint: UIColor, memories: Int, selected: Bool) -> UIColor {
        let depth = min(0.24, CGFloat(max(0, memories - 1)) * 0.06)
        let base = tint.composited(alpha: min(0.95, (isDark ? 0.78 : 0.68) + depth), over: ocean)
        return selected ? highlight(base) : base
    }

    func untouched(selected: Bool) -> UIColor {
        selected ? highlight(land) : land
    }

    func bucketListed(selected: Bool) -> UIColor {
        let base = bucket.composited(alpha: isDark ? 0.55 : 0.5, over: land)
        return selected ? highlight(base) : base
    }

    func highlight(_ color: UIColor) -> UIColor {
        self.selected.composited(alpha: isDark ? 0.18 : 0.16, over: color)
    }
}

/// Reusable SceneKit globe: ocean sphere, tinted country caps, ribbon borders,
/// and dots for places too small for polygons. Recolored via a closure; taps,
/// long presses and fly-to requests flow back to SwiftUI.
///
/// Interaction is map-style, NOT SceneKit's arcball: the camera never moves
/// sideways — one finger rotates the GLOBE (yaw unbounded, pitch clamped at
/// the poles, north always up, flick inertia), two fingers pinch the camera
/// distance.
struct GlobeCanvas: UIViewRepresentable {
    struct FocusRequest: Equatable {
        enum Style {
            case spin   // a couple of full revolutions on the way (the dice)
            case fly    // direct eased rotation (search / deep links)
        }

        let id: UUID
        let code: String
        var style: Style = .fly
    }

    var style: GlobeStyle
    var color: (_ code: String, _ selected: Bool) -> UIColor
    @Binding var selected: String?
    var focusOn: Binding<FocusRequest?> = .constant(nil)
    /// The country code on landing, or nil if the user grabbed the globe mid-flight.
    var onFocusLanded: ((String?) -> Void)? = nil
    var onLongPress: ((String) -> Void)? = nil
    /// Small-place dots for places that matter here (visited, bucket list)
    /// draw full size; the rest recede so Europe isn't a field of rings.
    var isEmphasized: (String) -> Bool = { _ in true }
    var interactive = true

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected) }

    func makeUIView(context: Context) -> SCNView {
        let view = GlobeSCNView()
        let coordinator = context.coordinator
        view.onLayout = { [weak coordinator] size in coordinator?.fit(to: size) }
        view.scene = buildScene(into: coordinator)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling2X
        view.pointOfView = coordinator.cameraNode
        view.preferredFramesPerSecond = 60

        if interactive {
            let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)

            let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
            tap.require(toFail: doubleTap)
            view.addGestureRecognizer(tap)

            let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleLongPress(_:)))
            hold.minimumPressDuration = 0.45
            view.addGestureRecognizer(hold)

            let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
            view.addGestureRecognizer(pinch)
        }

        coordinator.scnView = view
        coordinator.onLongPress = onLongPress
        coordinator.apply(style: style)
        recolor(coordinator)
        return view
    }

    /// A CADisplayLink retains its target; without this the coordinator —
    /// and every node it holds — outlived the view.
    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stopTicking()
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onLongPress = onLongPress
        if coordinator.appliedStyle != style { coordinator.apply(style: style) }
        recolor(coordinator)
        coordinator.showOutline(for: selected)

        if let request = focusOn.wrappedValue, request.id != coordinator.lastFocusId {
            coordinator.lastFocusId = request.id
            coordinator.focus(on: request.code, style: request.style, onLanded: onFocusLanded)
        }
    }

    private func recolor(_ coordinator: Coordinator) {
        for (code, material) in coordinator.fillMaterials {
            material.diffuse.contents = color(code, code == selected)
        }
        var emphasisChanged = false
        for code in coordinator.markerNodes.keys {
            let emphasized = isEmphasized(code) || code == selected
            if coordinator.markerEmphasis[code] != emphasized {
                coordinator.markerEmphasis[code] = emphasized
                emphasisChanged = true
            }
        }
        if emphasisChanged {
            coordinator.updateMarkerScale()
            coordinator.refreshRings()
        }
    }

    private func buildScene(into coordinator: Coordinator) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        let globe = SCNNode()
        globe.name = "globe"
        scene.rootNode.addChildNode(globe)
        coordinator.globeNode = globe

        let ocean = SCNSphere(radius: CGFloat(GlobeNodeFactory.oceanRadius))
        ocean.segmentCount = 96
        let oceanMaterial = SCNMaterial()
        oceanMaterial.lightingModel = .constant
        ocean.materials = [oceanMaterial]
        coordinator.oceanMaterial = oceanMaterial
        globe.addChildNode(SCNNode(geometry: ocean))

        for country in CountryStore.all where country.hasShape {
            if let node = GlobeNodeFactory.countryNode(code: country.code, color: .lightGray),
               let material = node.geometry?.firstMaterial {
                coordinator.fillMaterials[country.code] = material
                globe.addChildNode(node)
            }
        }

        let borders = GlobeDecor.bordersNode()
        coordinator.borderMaterials = borders.childNodes.compactMap { $0.geometry?.firstMaterial }
        globe.addChildNode(borders)

        for country in CountryStore.markers {
            let marker = GlobeDecor.markerNode(for: country)
            coordinator.markerNodes[country.code] = marker.container
            coordinator.fillMaterials[country.code] = marker.fill
            coordinator.ringMaterials[country.code] = marker.ring
            globe.addChildNode(marker.container)
        }

        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = 0.05
        let cam = SCNNode()
        cam.camera = camera
        cam.position = SCNVector3(0, 0, Coordinator.defaultCameraZ)
        scene.rootNode.addChildNode(cam)
        coordinator.cameraNode = cam
        coordinator.updateMarkerScale()

        return scene
    }

    final class Coordinator: NSObject {
        static let defaultCameraZ: Float = 6.9
        static let minCameraZ: Float = 1.6

        /// Distance that fits the whole globe (plus a paper margin) in THIS
        /// view — a full-height phone screen and a 300pt card need different
        /// distances, or the smaller canvas draws a tiny globe.
        private(set) var homeZ: Float = Coordinator.defaultCameraZ
        private var maxCameraZ: Float { homeZ * 1.5 }
        private var fittedSize: CGSize = .zero

        var fillMaterials: [String: SCNMaterial] = [:]
        var borderMaterials: [SCNMaterial] = []
        var ringMaterials: [String: SCNMaterial] = [:]
        var markerNodes: [String: SCNNode] = [:]
        var markerEmphasis: [String: Bool] = [:]
        var oceanMaterial: SCNMaterial?
        var appliedStyle: GlobeStyle?
        var cameraNode = SCNNode()
        var globeNode: SCNNode?
        weak var scnView: SCNView?
        var onLongPress: ((String) -> Void)?
        var lastFocusId: UUID?

        private var selected: Binding<String?>
        private var outlineNode: SCNNode?
        private var outlineCode: String?

        // orientation = Rx(pitch) · Ry(yaw); north can never roll.
        private var yaw: Float = 0
        private var pitch: Float = 0
        private let pitchLimit: Float = 1.45
        private var cameraZ: Float = Coordinator.defaultCameraZ

        private enum Drive {
            case idle
            case inertia(vYaw: Float, vPitch: Float)
            case animate(fromYaw: Float, fromPitch: Float, toYaw: Float, toPitch: Float,
                         fromZ: Float, toZ: Float,
                         start: CFTimeInterval, duration: CFTimeInterval,
                         code: String?, haptic: UIImpactFeedbackGenerator.FeedbackStyle?,
                         onLanded: ((String?) -> Void)?)
        }

        private var drive: Drive = .idle
        private var displayLink: CADisplayLink?
        private var lastTick: CFTimeInterval = 0

        init(selected: Binding<String?>) { self.selected = selected }

        deinit { displayLink?.invalidate() }

        // ── Framing ──────────────────────────────────────────────────────────

        func fit(to size: CGSize) {
            guard size.width > 0, size.height > 0, size != fittedSize else { return }
            fittedSize = size
            let vertical = Float(40 * Double.pi / 180)
            let aspect = Float(size.width / size.height)
            let horizontal = 2 * atan(tan(vertical / 2) * aspect)
            let limiting = min(vertical, horizontal)
            let margin: Float = 1.12
            let fitted = margin / sin(limiting / 2)
            let wasHome = abs(cameraZ - homeZ) < 0.01
            homeZ = fitted
            // Keep a user's zoom; re-frame only if they were at home.
            if wasHome, case .idle = drive {
                cameraZ = homeZ
                cameraNode.position.z = cameraZ
                updateMarkerScale()
            }
        }

        // ── Style ────────────────────────────────────────────────────────────

        func apply(style: GlobeStyle) {
            appliedStyle = style
            oceanMaterial?.diffuse.contents = style.ocean
            for material in borderMaterials { material.diffuse.contents = style.border }
            refreshRings()
            // The outline is rebuilt in the new ink on next selection change.
            if let code = outlineCode {
                outlineCode = nil
                showOutline(for: code)
            }
        }

        /// Ring ink per dot: selected → heavy ink, receded → faint.
        func refreshRings() {
            let style = appliedStyle ?? GlobeStyle(.light)
            for (code, material) in ringMaterials {
                if code == outlineCode {
                    material.diffuse.contents = style.selected
                } else if markerEmphasis[code] == false {
                    material.diffuse.contents = style.border.withAlphaComponent(0.35)
                } else {
                    material.diffuse.contents = style.border
                }
            }
        }

        // ── Gestures ─────────────────────────────────────────────────────────

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let code = countryCode(at: gesture.location(in: scnView)) else {
                selected.wrappedValue = nil
                return
            }
            UISelectionFeedbackGenerator().selectionChanged()
            selected.wrappedValue = (selected.wrappedValue == code) ? nil : code
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let spot = latLng(at: gesture.location(in: scnView)) else { return }
            cancelDrive()
            let zoomingOut = cameraZ < 2.0
            let toZ = zoomingOut ? homeZ : max(Self.minCameraZ, cameraZ * 0.5)

            var toYaw = Float(-spot.lng * .pi / 180)
            let toPitch = max(-pitchLimit, min(pitchLimit, Float(spot.lat * .pi / 180)))
            toYaw = yaw + shortestDelta(from: yaw, to: toYaw)

            drive = .animate(fromYaw: yaw, fromPitch: pitch,
                             toYaw: zoomingOut ? yaw : toYaw,
                             toPitch: zoomingOut ? pitch : toPitch,
                             fromZ: cameraZ, toZ: toZ,
                             start: CACurrentMediaTime(), duration: 0.45,
                             code: nil, haptic: nil, onLanded: nil)
            startTicking()
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
                cancelDrive()
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
            switch gesture.state {
            case .began:
                cancelDrive()
            case .changed:
                cameraZ = max(Self.minCameraZ, min(maxCameraZ, cameraZ / Float(gesture.scale)))
                gesture.scale = 1
                cameraNode.position.z = cameraZ
                updateMarkerScale()
            default:
                break
            }
        }

        private func radiansPerPoint(in view: SCNView) -> Float {
            let width = Float(view.bounds.width)
            guard width > 0 else { return 0.005 }
            return max(0.05, cameraZ - 1) / (3.0 * width)
        }

        // ── Hit resolution ───────────────────────────────────────────────────

        /// Where on the globe (lat/lng) a screen point touches, or nil
        /// off-globe — an analytic ray/sphere intersection, not mesh hits.
        private func latLng(at point: CGPoint?) -> (lat: Double, lng: Double)? {
            guard let view = scnView, let point, let globe = globeNode else { return nil }
            let nearWorld = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
            let farWorld = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
            let nearLocal = globe.presentation.simdConvertPosition(
                SIMD3<Float>(nearWorld.x, nearWorld.y, nearWorld.z), from: nil)
            let farLocal = globe.presentation.simdConvertPosition(
                SIMD3<Float>(farWorld.x, farWorld.y, farWorld.z), from: nil)
            guard let hit = GlobeMath.frontIntersection(
                rayOrigin: nearLocal, rayDirection: farLocal - nearLocal,
                radius: Float(GlobeNodeFactory.capRadius)
            ) else { return nil }
            return GlobeMath.latLng(at: hit)
        }

        private func countryCode(at point: CGPoint?) -> String? {
            guard let point else { return nil }
            let polygon = latLng(at: point).flatMap { CountryGeometry.country(atLat: $0.lat, lng: $0.lng) }
            // Dots sit on top of (or inside) big polygons — Vatican City in
            // Italy — so a tap right on a dot wins, with a tighter radius
            // when the finger is also inside a country.
            if let marker = markerCode(near: point, threshold: polygon == nil ? 18 : 10) {
                return marker
            }
            return polygon
        }

        private func markerCode(near point: CGPoint, threshold: CGFloat) -> String? {
            guard let view = scnView, let globe = globeNode else { return nil }
            let camera = SIMD3<Float>(0, 0, cameraZ)
            var best: (code: String, distance: CGFloat)?
            for (code, node) in markerNodes {
                let world = globe.presentation.simdConvertPosition(node.simdPosition, to: nil)
                let normal = simd_normalize(world)
                let toCamera = simd_normalize(camera - world)
                guard simd_dot(normal, toCamera) > 0.15 else { continue } // far side
                let projected = view.projectPoint(SCNVector3(world.x, world.y, world.z))
                let distance = hypot(CGFloat(projected.x) - point.x, CGFloat(projected.y) - point.y)
                if distance < threshold, best == nil || distance < best!.distance {
                    best = (code, distance)
                }
            }
            return best?.code
        }

        // ── Selection outline ────────────────────────────────────────────────

        func showOutline(for code: String?) {
            guard code != outlineCode else { return }
            let style = appliedStyle ?? GlobeStyle(.light)
            if let previous = outlineCode {
                markerNodes[previous]?.childNode(withName: "ring", recursively: false)?.scale = SCNVector3(1, 1, 1)
            }
            outlineNode?.removeFromParentNode()
            outlineNode = nil
            outlineCode = code
            refreshRings()
            guard let code else { return }
            if ringMaterials[code] != nil {
                markerNodes[code]?.childNode(withName: "ring", recursively: false)?.scale = SCNVector3(1.35, 1, 1.35)
            } else if let node = GlobeDecor.outlineNode(code: code, color: style.selected) {
                globeNode?.addChildNode(node)
                outlineNode = node
            }
        }

        // ── Focus (spin / fly) ───────────────────────────────────────────────

        func focus(on code: String, style: FocusRequest.Style, onLanded: ((String?) -> Void)?) {
            guard let country = CountryStore.byCode[code] else {
                announce { onLanded?(nil) }
                return
            }
            // This flight replaces the one in progress and will report its own
            // landing, so the old one stays quiet.
            cancelDrive(announcing: false)

            let toPitch = Float(country.centroid.lat * .pi / 180)
            var toYaw = yaw + shortestDelta(from: yaw, to: Float(-country.centroid.lng * .pi / 180))

            let duration: CFTimeInterval
            let haptic: UIImpactFeedbackGenerator.FeedbackStyle
            let toZ: Float
            switch style {
            case .spin:
                toYaw -= Float.pi * 4
                duration = 1.9
                haptic = .medium
                toZ = country.hasShape ? homeZ : min(homeZ, 3.2)
            case .fly:
                duration = 0.75
                haptic = .light
                toZ = min(homeZ, country.hasShape ? Self.zoom(forSize: CountryGeometry.sizeHint(code)) : 2.4)
            }

            // Land a little above center so the panel over the bottom half
            // doesn't cover it.
            let panelBias = min(0.22, 0.06 * (toZ - 1))
            drive = .animate(fromYaw: yaw, fromPitch: pitch, toYaw: toYaw,
                             toPitch: min(pitchLimit, max(-pitchLimit, toPitch - panelBias)),
                             fromZ: cameraZ, toZ: toZ,
                             start: CACurrentMediaTime(), duration: duration,
                             code: code, haptic: haptic, onLanded: onLanded)
            startTicking()
        }

        private static func zoom(forSize area: Double) -> Float {
            switch area {
            case 300...: return 6.9
            case 60..<300: return 5.4
            case 12..<60: return 4.0
            case 2.5..<12: return 2.9
            default: return 2.1
            }
        }

        private func shortestDelta(from: Float, to: Float) -> Float {
            let twoPi = Float.pi * 2
            var delta = (to - from).truncatingRemainder(dividingBy: twoPi)
            if delta > .pi { delta -= twoPi }
            if delta < -.pi { delta += twoPi }
            return delta
        }

        /// Stop any flight. `announcing` tells the caller it never landed —
        /// unless another flight is taking over.
        private func cancelDrive(announcing: Bool = true) {
            if case let .animate(_, _, _, _, _, _, _, _, _, _, onLanded) = drive, announcing {
                announce { onLanded?(nil) }
            }
            drive = .idle
            displayLink?.isPaused = true
        }

        /// Landing callbacks change SwiftUI state, and cancelDrive can run
        /// inside updateUIView (a new focus request arriving mid-flight).
        private func announce(_ body: @escaping () -> Void) {
            DispatchQueue.main.async(execute: body)
        }

        // ── Markers keep a constant on-screen size ───────────────────────────

        func updateMarkerScale() {
            let base = 0.0034 * (cameraZ - 1) + 0.0012
            for (code, node) in markerNodes {
                let s = markerEmphasis[code] == false ? base * 0.62 : base
                node.scale = SCNVector3(s, s, s)
            }
        }

        // ── Display-link motor ───────────────────────────────────────────────

        private func startTicking() {
            if displayLink == nil {
                let link = CADisplayLink(target: WeakTicker(self), selector: #selector(WeakTicker.tick))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            lastTick = CACurrentMediaTime()
            displayLink?.isPaused = false
        }

        func stopTicking() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc fileprivate func tick() {
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

            case let .animate(fromYaw, fromPitch, toYaw, toPitch, fromZ, toZ, start, duration, code, haptic, onLanded):
                let t = min(1, max(0, Float((now - start) / duration)))
                let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
                yaw = fromYaw + (toYaw - fromYaw) * eased
                pitch = fromPitch + (toPitch - fromPitch) * eased
                cameraZ = fromZ + (toZ - fromZ) * eased
                cameraNode.position.z = cameraZ
                updateMarkerScale()
                applyOrientation()
                if t >= 1 {
                    drive = .idle
                    displayLink?.isPaused = true
                    if let haptic { UIImpactFeedbackGenerator(style: haptic).impactOccurred() }
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

/// Reports size changes so the camera can frame the globe for this view.
final class GlobeSCNView: SCNView {
    var onLayout: ((CGSize) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }
}

/// Display-link target that holds its coordinator weakly.
private final class WeakTicker: NSObject {
    weak var coordinator: GlobeCanvas.Coordinator?
    init(_ coordinator: GlobeCanvas.Coordinator) { self.coordinator = coordinator }
    @objc func tick() { coordinator?.tick() }
}
