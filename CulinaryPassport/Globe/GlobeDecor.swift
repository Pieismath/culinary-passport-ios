import Foundation
import SceneKit
import UIKit
import simd

// Globe dressing: country borders and the selection outline. Geometry is
// identical for every globe instance, so everything heavy is built once and
// cached (same rationale as GlobeNodeFactory.meshCache — main-thread only).
//
// Deliberately NO on-globe name labels: at phone scale they collide without
// full cartographic placement, and identification is served by tap (panel)
// while finding is served by search + fly-to.
//
// Borders are drawn as RIBBONS (real quads with width), not 1px lines: once
// two neighbouring countries are both filled in, a hairline is not enough to
// tell them apart. A crisp 1px line rides on top of the ribbon so borders
// stay sharp when zoomed far out.

enum GlobeDecor {
    /// Sepia ink for borders — reads as "drawn on paper", per the light/clean
    /// design language. Opaque enough to separate two filled-in neighbours.
    static let borderInk = UIColor(red: 0.34, green: 0.29, blue: 0.21, alpha: 0.92)
    /// Selection reads as "a heavier version of the same ink" — a near-black
    /// rope around the country was too harsh.
    static let selectedInk = UIColor(red: 0.28, green: 0.23, blue: 0.16, alpha: 0.95)

    private static let borderRadius = 1.0055
    private static let outlineRadius = 1.0075

    /// Ribbon half-width in degrees. ~0.6pt at the default camera distance
    /// (≈2px on a 3× screen) and thicker as you zoom in, like a real map.
    private static let borderHalfWidth = 0.10
    private static let outlineHalfWidth = 0.125

    /// Straight-line political borders (the US–Canada 49th parallel, the
    /// Sahara's ruler-drawn edges) carry only a handful of vertices, and a
    /// long straight 3D chord between distant points cuts THROUGH the sphere —
    /// the middle of the line sinks under the ocean/fill and vanishes. Keep
    /// every rendered segment short so the polyline hugs the surface.
    private static let maxSegmentDegrees = 2.0

    // ── Borders (all countries, one node) ────────────────────────────────────

    private static var borderMesh: Mesh?

    /// Every country ring as ribbons + a hairline, in a single node. Colors
    /// are applied by the canvas (they change with light/dark).
    static func bordersNode() -> SCNNode {
        let mesh: Mesh
        if let borderMesh {
            mesh = borderMesh
        } else {
            var builder = MeshBuilder()
            for rings in CountryGeometry.rings.values {
                builder.add(rings: rings, radius: borderRadius, halfWidth: borderHalfWidth)
            }
            mesh = builder.build()
            borderMesh = mesh
        }
        let node = SCNNode()
        node.name = "borders"
        node.addChildNode(SCNNode(geometry: mesh.geometry(color: borderInk)))
        node.addChildNode(SCNNode(geometry: mesh.hairlineGeometry(color: borderInk)))
        return node
    }

    // ── Selection outline (per country, cached) ──────────────────────────────

    private static var outlineMeshes: [String: Mesh?] = [:]

    /// A darker, wider, slightly-raised outline of one country while selected.
    static func outlineNode(code: String, color: UIColor) -> SCNNode? {
        let mesh: Mesh?
        if let cached = outlineMeshes[code] {
            mesh = cached
        } else {
            var builder = MeshBuilder()
            if let rings = CountryGeometry.rings[code] {
                builder.add(rings: rings, radius: outlineRadius, halfWidth: outlineHalfWidth)
            }
            mesh = builder.isEmpty ? nil : builder.build()
            outlineMeshes[code] = mesh
        }
        guard let mesh else { return nil }
        let node = SCNNode(geometry: mesh.geometry(color: color))
        node.name = "outline"
        return node
    }

    // ── Dots for places too small for polygons ───────────────────────────────

    struct Marker {
        let container: SCNNode
        let fill: SCNMaterial
        let ring: SCNMaterial
    }

    private static let markerFill: SCNCylinder = {
        let disc = SCNCylinder(radius: 1, height: 0.25)
        disc.radialSegmentCount = 28
        return disc
    }()

    private static let markerRing: SCNCylinder = {
        let disc = SCNCylinder(radius: 1.4, height: 0.12)
        disc.radialSegmentCount = 28
        return disc
    }()

    /// A small disc lying on the surface (a ring of border ink under a fill).
    /// The container is scaled by the canvas so dots keep a steady on-screen
    /// size at every zoom.
    static func markerNode(for country: Country) -> Marker {
        let position = GlobeMath.vec3(lat: country.centroid.lat, lng: country.centroid.lng, radius: 1.006)
        let container = SCNNode()
        container.name = "marker-\(country.code)"
        container.position = position
        let normal = simd_normalize(SIMD3<Float>(position.x, position.y, position.z))
        container.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normal)

        let ringMaterial = constantMaterial(borderInk)
        let ringGeometry = markerRing.copy() as! SCNCylinder
        ringGeometry.materials = [ringMaterial]
        let ring = SCNNode(geometry: ringGeometry)
        ring.name = "ring"
        container.addChildNode(ring)

        let fillMaterial = constantMaterial(.lightGray)
        let fillGeometry = markerFill.copy() as! SCNCylinder
        fillGeometry.materials = [fillMaterial]
        let fill = SCNNode(geometry: fillGeometry)
        fill.position = SCNVector3(0, 0.12, 0)
        container.addChildNode(fill)

        return Marker(container: container, fill: fillMaterial, ring: ringMaterial)
    }

    private static func constantMaterial(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        return material
    }

    // ── Ribbon construction ──────────────────────────────────────────────────

    struct Mesh {
        let vertices: [SCNVector3]
        let triangleIndices: [Int32]
        let lineVertices: [SCNVector3]
        let lineIndices: [Int32]

        func geometry(color: UIColor) -> SCNGeometry {
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: vertices)],
                elements: [SCNGeometryElement(indices: triangleIndices, primitiveType: .triangles)]
            )
            geometry.materials = [Self.material(color)]
            return geometry
        }

        func hairlineGeometry(color: UIColor) -> SCNGeometry {
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: lineVertices)],
                elements: [SCNGeometryElement(indices: lineIndices, primitiveType: .line)]
            )
            geometry.materials = [Self.material(color)]
            return geometry
        }

        private static func material(_ color: UIColor) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.lightingModel = .constant
            material.isDoubleSided = true
            return material
        }
    }

    /// One undirected edge, rounded to ~10 cm so shared boundaries match.
    private struct EdgeKey: Hashable {
        let low: SIMD2<Int64>, high: SIMD2<Int64>

        init(_ p: SIMD2<Double>, _ q: SIMD2<Double>) {
            let a = SIMD2<Int64>(Int64((p.x * 1e6).rounded()), Int64((p.y * 1e6).rounded()))
            let b = SIMD2<Int64>(Int64((q.x * 1e6).rounded()), Int64((q.y * 1e6).rounded()))
            if (a.x, a.y) <= (b.x, b.y) { low = a; high = b } else { low = b; high = a }
        }
    }

    private struct MeshBuilder {
        var vertices: [SCNVector3] = []
        var triangleIndices: [Int32] = []
        var lineVertices: [SCNVector3] = []
        var lineIndices: [Int32] = []

        var isEmpty: Bool { vertices.isEmpty }

        mutating func add(rings: [Ring], radius: Double, halfWidth: Double) {
            let joins = sharedEdges(of: rings)
            for ring in rings {
                var loop = ring
                if loop.count > 1, loop.first == loop.last { loop.removeLast() }
                guard loop.count >= 3 else { continue }

                // Draw each run of real border between cuts. Densify in
                // lng/lat space — the same straight-in-lng/lat path the fills
                // follow, so line and fill edges stay coincident.
                var run: Ring = []
                for i in 0..<loop.count {
                    let a = loop[i]
                    let b = loop[(i + 1) % loop.count]
                    if isCut(a, b) || joins.contains(EdgeKey(a, b)) {
                        addPath(run, radius: radius, halfWidth: halfWidth)
                        run = []
                        continue
                    }
                    if run.isEmpty { run.append(a) }
                    let d = b - a
                    let steps = Int(max(abs(d.x), abs(d.y)) / maxSegmentDegrees)
                    if steps > 0 {
                        for s in 1...steps {
                            run.append(a + d * (Double(s) / Double(steps + 1)))
                        }
                    }
                    run.append(b)
                }
                addPath(run, radius: radius, halfWidth: halfWidth)
            }
        }

        /// A hairline plus a ribbon along one open run of border.
        private mutating func addPath(_ points: Ring, radius: Double, halfWidth: Double) {
            guard points.count >= 2 else { return }
            let lineBase = Int32(lineVertices.count)
            lineVertices.append(contentsOf: points.map {
                GlobeMath.vec3(lat: $0.y, lng: $0.x, radius: radius)
            })
            for i in 0..<Int32(points.count - 1) {
                lineIndices.append(lineBase + i)
                lineIndices.append(lineBase + i + 1)
            }
            // Ribbon: one quad per segment, plus a diamond at each vertex so
            // corners join without notches.
            for i in 0..<(points.count - 1) {
                addQuad(from: points[i], to: points[i + 1], radius: radius, halfWidth: halfWidth)
                addJoin(at: points[i], radius: radius, halfWidth: halfWidth)
            }
            addJoin(at: points[points.count - 1], radius: radius, halfWidth: halfWidth)
        }

        /// Natural Earth cuts Russia, Fiji and Antarctica at ±180° and closes
        /// Antarctica across the South Pole. Those cuts aren't borders.
        private func isCut(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
            (abs(abs(a.x) - 180) < 1e-6 && abs(abs(b.x) - 180) < 1e-6) || (a.y <= -89.9 && b.y <= -89.9)
        }

        /// Edges two rings of the same country share — the line where
        /// Somaliland meets Somalia, or Northern Cyprus meets Cyprus. Drawing
        /// them would put a border through the middle of one stamp.
        private func sharedEdges(of rings: [Ring]) -> Set<EdgeKey> {
            guard rings.count > 1 else { return [] }
            var seen: Set<EdgeKey> = [], shared: Set<EdgeKey> = []
            for ring in rings where ring.count >= 2 {
                for i in 0..<ring.count {
                    let key = EdgeKey(ring[i], ring[(i + 1) % ring.count])
                    if !seen.insert(key).inserted { shared.insert(key) }
                }
            }
            return shared
        }

        /// Perpendicular offset has to be computed in a locally-metric space:
        /// a degree of longitude is cos(lat) as wide as a degree of latitude,
        /// so a naive lng/lat normal makes borders balloon near the poles.
        private mutating func addQuad(from a: SIMD2<Double>, to b: SIMD2<Double>,
                                      radius: Double, halfWidth: Double) {
            let midLat = (a.y + b.y) / 2
            let k = max(0.08, cos(midLat * .pi / 180))
            let d = SIMD2<Double>((b.x - a.x) * k, b.y - a.y)
            let length = (d.x * d.x + d.y * d.y).squareRoot()
            guard length > 1e-9 else { return }
            let perp = SIMD2<Double>(-d.y / length, d.x / length) * halfWidth
            let offset = SIMD2<Double>(perp.x / k, perp.y)

            let base = Int32(vertices.count)
            for p in [a + offset, a - offset, b + offset, b - offset] {
                vertices.append(GlobeMath.vec3(lat: p.y, lng: p.x, radius: radius))
            }
            triangleIndices.append(contentsOf: [base, base + 1, base + 2,
                                                base + 1, base + 3, base + 2])
        }

        private mutating func addJoin(at p: SIMD2<Double>, radius: Double, halfWidth: Double) {
            let k = max(0.08, cos(p.y * .pi / 180))
            let dx = halfWidth / k
            let dy = halfWidth
            let base = Int32(vertices.count)
            for q in [SIMD2(p.x - dx, p.y), SIMD2(p.x, p.y - dy),
                      SIMD2(p.x + dx, p.y), SIMD2(p.x, p.y + dy)] {
                vertices.append(GlobeMath.vec3(lat: q.y, lng: q.x, radius: radius))
            }
            triangleIndices.append(contentsOf: [base, base + 1, base + 2,
                                                base, base + 2, base + 3])
        }

        func build() -> Mesh {
            Mesh(vertices: vertices, triangleIndices: triangleIndices,
                 lineVertices: lineVertices, lineIndices: lineIndices)
        }
    }
}
