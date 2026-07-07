import SwiftUI
import SceneKit

/// SceneKit globe — MVP step 2. Placeholder sphere for now; the real build:
///  - Natural Earth 110m polygons (copy public/data/countries.geojson from the web repo)
///  - extruded country shapes tinted by try-status (port capColor logic from GlobeView.tsx)
///  - tap = country panel, long-press = queue, spin gesture with damping + haptics
struct GlobeSceneView: View {
    var body: some View {
        SceneView(
            scene: Self.makeScene(),
            options: [.allowsCameraControl, .autoenablesDefaultLighting]
        )
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            Text("Globe scaffold — port country polygons from the web app")
                .font(.caption)
                .padding(8)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 24)
        }
    }

    private static func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1) // paper
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 64
        sphere.firstMaterial?.diffuse.contents = UIColor(red: 0.85, green: 0.89, blue: 0.92, alpha: 1) // porcelain ocean
        sphere.firstMaterial?.specular.contents = UIColor.white
        let node = SCNNode(geometry: sphere)
        node.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 60)))
        scene.rootNode.addChildNode(node)
        return scene
    }
}
