import Foundation
import SceneKit
import UIKit
import simd

// Globe dressing: hairline country borders, a per-country selection outline,
// and zoom-gated name labels. Geometry is identical for every globe instance,
// so everything heavy is built once and cached (same rationale as
// GlobeNodeFactory.meshCache — main-thread access only).

enum GlobeDecor {
    /// Sepia ink for hairline borders — reads as "drawn on paper", per the
    /// light/clean design language (no dark or neon strokes). Untried
    /// neighbours share one parchment tone, so this line is what separates
    /// them — it needs real contrast.
    static let borderInk = UIColor(red: 0.40, green: 0.35, blue: 0.26, alpha: 0.78)
    static let selectedInk = UIColor(red: 0.24, green: 0.21, blue: 0.15, alpha: 0.95)
    static let labelInk = UIColor(red: 0.29, green: 0.26, blue: 0.20, alpha: 1)

    private static let borderRadius = 1.0055
    private static let outlineRadius = 1.0075
    private static let labelRadius = 1.03

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

    // ── Name labels ──────────────────────────────────────────────────────────

    /// Bigger countries keep their labels at far zoom; smaller ones appear as
    /// the camera moves in (distance thresholds in world units — the default
    /// camera orbit is ~3.2).
    enum LabelTier {
        case large, medium, small

        var showsBelowDistance: Float {
            switch self {
            case .large: 99          // always visible
            case .medium: 4.8        // default camera orbit is ~6.9
            case .small: 3.4
            }
        }
    }

    struct Label {
        let node: SCNNode
        let tier: LabelTier
    }

    /// Base uniform scale for label nodes at the default camera distance.
    static let labelBaseScale: Float = 0.0042

    private static var labelTemplates: [(code: String, tier: LabelTier, template: SCNNode)]?

    /// Fresh label nodes (cloned from cached templates) for one scene.
    /// Billboarded, centered on the country's biggest landmass, hidden until
    /// the coordinator's per-frame pass decides visibility.
    static func labelNodes() -> [Label] {
        let templates: [(code: String, tier: LabelTier, template: SCNNode)]
        if let labelTemplates {
            templates = labelTemplates
        } else {
            templates = buildTemplates()
            labelTemplates = templates
        }
        return templates.map { entry in
            let clone = entry.template.clone()
            clone.isHidden = true
            return Label(node: clone, tier: entry.tier)
        }
    }

    private static func buildTemplates() -> [(code: String, tier: LabelTier, template: SCNNode)] {
        var result: [(String, LabelTier, SCNNode)] = []
        for country in CountryStore.all {
            guard let rings = CountryGeometry.rings[country.code],
                  let anchor = largestRingInfo(rings) else { continue }

            let text = SCNText(string: country.name, extrusionDepth: 0)
            text.font = .systemFont(ofSize: 6.5, weight: .semibold)
            text.flatness = 0.5
            let material = SCNMaterial()
            material.diffuse.contents = labelInk
            material.lightingModel = .constant
            material.readsFromDepthBuffer = false // never half-sunk into the sphere
            text.materials = [material]

            let node = SCNNode(geometry: text)
            // Center the text block on its anchor point.
            let (minB, maxB) = node.boundingBox
            node.pivot = SCNMatrix4MakeTranslation((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, 0)
            node.position = GlobeMath.vec3(lat: anchor.lat, lng: anchor.lng, radius: labelRadius)
            node.constraints = [SCNBillboardConstraint()]
            let s = labelBaseScale
            node.scale = SCNVector3(s, s, s)
            node.renderingOrder = 10 // after caps/borders so depth-free text draws on top
            node.name = "label-\(country.code)"

            result.append((country.code, tier(forArea: anchor.area), node))
        }
        return result
    }

    private static func tier(forArea area: Double) -> LabelTier {
        if area >= 120 { return .large }
        if area >= 18 { return .medium }
        return .small
    }

    /// Centroid + rough area (deg², latitude-corrected) of the country's
    /// LARGEST ring — averaging all rings would drop island nations' labels
    /// into the sea between their islands.
    private static func largestRingInfo(_ rings: [Ring]) -> (lat: Double, lng: Double, area: Double)? {
        var best: (lat: Double, lng: Double, area: Double)?
        for ring in rings {
            guard ring.count > 3 else { continue }
            var minLng = Double.greatestFiniteMagnitude, maxLng = -Double.greatestFiniteMagnitude
            var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
            var sum = SIMD2<Double>.zero
            for p in ring {
                minLng = min(minLng, p.x); maxLng = max(maxLng, p.x)
                minLat = min(minLat, p.y); maxLat = max(maxLat, p.y)
                sum += p
            }
            let mid = (minLat + maxLat) / 2
            let area = (maxLng - minLng) * (maxLat - minLat) * cos(mid * .pi / 180)
            if area > (best?.area ?? -1) {
                let c = sum / Double(ring.count)
                best = (c.y, c.x, area)
            }
        }
        return best
    }
}
