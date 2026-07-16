import Foundation
import SceneKit
import UIKit
import simd

// Globe dressing: hairline country borders and a per-country selection
// outline. Geometry is identical for every globe instance, so everything
// heavy is built once and cached (same rationale as
// GlobeNodeFactory.meshCache — main-thread access only).
//
// Deliberately NO on-globe name labels: at phone scale they collide without
// full cartographic placement, and identification is served by tap (panel)
// while finding is served by search + fly-to.

enum GlobeDecor {
    /// Sepia ink for hairline borders — reads as "drawn on paper", per the
    /// light/clean design language (no dark or neon strokes). Untried
    /// neighbours share one parchment tone, so this line is what separates
    /// them — it needs real contrast.
    static let borderInk = UIColor(red: 0.40, green: 0.35, blue: 0.26, alpha: 0.78)
    static let selectedInk = UIColor(red: 0.24, green: 0.21, blue: 0.15, alpha: 0.95)

    private static let borderRadius = 1.0055
    private static let outlineRadius = 1.0075

    // ── Borders (all countries, one node) ────────────────────────────────────

    private static var borderMesh: (source: SCNGeometrySource, element: SCNGeometryElement)?

    /// Every country ring as line segments in a single geometry.
    static func bordersNode() -> SCNNode {
        let mesh: (source: SCNGeometrySource, element: SCNGeometryElement)
        if let borderMesh {
            mesh = borderMesh
        } else {
            var vertices: [SCNVector3] = []
            var indices: [Int32] = []
            for rings in CountryGeometry.rings.values {
                append(rings: rings, radius: borderRadius, into: &vertices, indices: &indices)
            }
            mesh = (SCNGeometrySource(vertices: vertices),
                    SCNGeometryElement(indices: indices, primitiveType: .line))
            borderMesh = mesh
        }
        let node = SCNNode(geometry: lineGeometry(mesh, color: borderInk))
        node.name = "borders"
        return node
    }

    // ── Selection outline (per country, cached) ──────────────────────────────

    private static var outlineMeshes: [String: (source: SCNGeometrySource, element: SCNGeometryElement)?] = [:]

    /// A darker, slightly-raised outline of one country, shown while selected.
    static func outlineNode(code: String) -> SCNNode? {
        let mesh: (source: SCNGeometrySource, element: SCNGeometryElement)?
        if let cached = outlineMeshes[code] {
            mesh = cached
        } else {
            var vertices: [SCNVector3] = []
            var indices: [Int32] = []
            if let rings = CountryGeometry.rings[code] {
                append(rings: rings, radius: outlineRadius, into: &vertices, indices: &indices)
            }
            mesh = vertices.isEmpty ? nil : (SCNGeometrySource(vertices: vertices),
                                             SCNGeometryElement(indices: indices, primitiveType: .line))
            outlineMeshes[code] = mesh
        }
        guard let mesh else { return nil }
        let node = SCNNode(geometry: lineGeometry(mesh, color: selectedInk))
        node.name = "outline"
        return node
    }

    private static func append(rings: [Ring], radius: Double,
                               into vertices: inout [SCNVector3], indices: inout [Int32]) {
        for ring in rings {
            var loop = ring
            if loop.count > 1, loop.first == loop.last { loop.removeLast() }
            guard loop.count >= 3 else { continue }
            let base = Int32(vertices.count)
            vertices.append(contentsOf: loop.map { GlobeMath.vec3(lat: $0.y, lng: $0.x, radius: radius) })
            let n = Int32(loop.count)
            for i in 0..<n {
                indices.append(base + i)
                indices.append(base + (i + 1) % n)
            }
        }
    }

    private static func lineGeometry(_ mesh: (source: SCNGeometrySource, element: SCNGeometryElement),
                                     color: UIColor) -> SCNGeometry {
        let geometry = SCNGeometry(sources: [mesh.source], elements: [mesh.element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        geometry.materials = [material]
        return geometry
    }
}
