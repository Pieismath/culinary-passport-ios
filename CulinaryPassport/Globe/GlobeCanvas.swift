import SwiftUI
import SceneKit

/// Reusable SceneKit globe: ocean sphere + tinted country caps, recolored via a
/// closure and reporting taps. Shared by the personal globe (GlobeSceneView) and
/// the group globe (GroupGlobeView) so the geometry/build lives in one place.
struct GlobeCanvas: UIViewRepresentable {
    /// Cap color for a country code, given whether it's the current selection.
    var color: (_ code: String, _ selected: Bool) -> UIColor
    @Binding var selected: String?

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected) }

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
        for (code, node) in context.coordinator.countryNodes {
            node.geometry?.firstMaterial?.diffuse.contents = color(code, code == selected)
        }
    }

    private func buildScene(into coordinator: Coordinator) -> SCNScene {
        let scene = SCNScene()

        let ocean = SCNSphere(radius: CGFloat(GlobeNodeFactory.oceanRadius))
        ocean.segmentCount = 96
        ocean.firstMaterial?.diffuse.contents = UIColor(red: 0.85, green: 0.89, blue: 0.92, alpha: 1)
        ocean.firstMaterial?.lightingModel = .constant
        scene.rootNode.addChildNode(SCNNode(geometry: ocean))

        for country in CountryStore.all {
            if let node = GlobeNodeFactory.countryNode(code: country.code, color: color(country.code, false)) {
                coordinator.countryNodes[country.code] = node
                scene.rootNode.addChildNode(node)
            }
        }

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
        private var selected: Binding<String?>

        init(selected: Binding<String?>) { self.selected = selected }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = scnView else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let n = node {
                    if let code = n.name, code.count == 2 {
                        selected.wrappedValue = (selected.wrappedValue == code) ? nil : code
                        return
                    }
                    node = n.parent
                }
            }
            selected.wrappedValue = nil
        }
    }
}
