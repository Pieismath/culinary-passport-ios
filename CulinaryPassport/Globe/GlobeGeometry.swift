import Foundation
import SceneKit

// MVP step 2 — the real globe. Ports the polygon/coloring intent of the web
// GlobeView.tsx (globe.gl) onto SceneKit: Natural Earth 110m country rings are
// projected onto a unit sphere and filled as tinted caps.
//
// The web app leans on globe.gl for polygon tessellation; SceneKit has none, so
// we triangulate each country's outer rings ourselves (ear clipping in lng/lat
// space, then project every vertex to the sphere). 110m geometry is coarse
// enough that lng/lat-space triangulation looks clean at globe scale.

// MARK: - Ring geometry loaded from the bundled geojson

/// One outer ring: a closed loop of (lng, lat) in degrees.
typealias Ring = [SIMD2<Double>]

enum CountryGeometry {
    /// ISO_A2 → its outer rings (a country may be several polygons, e.g. islands).
    static let rings: [String: [Ring]] = load()

    // Natural Earth 110m sets ISO_A2 = -99 for these; match CountryStore.isoFix.
    private static let isoFix = ["France": "FR", "Norway": "NO", "Kosovo": "XK"]

    private static func load() -> [String: [Ring]] {
        guard let url = Bundle.main.url(forResource: "countries", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]]
        else {
            assertionFailure("countries.geojson missing from bundle")
            return [:]
        }

        var result: [String: [Ring]] = [:]
        for feature in features {
            guard let props = feature["properties"] as? [String: Any] else { continue }
            var code = props["ISO_A2"] as? String ?? ""
            if code.count != 2 || code == "-9" {
                code = isoFix[props["ADMIN"] as? String ?? ""] ?? ""
            }
            guard code.count == 2, code.allSatisfy({ $0.isUppercase }), code != "AQ" else { continue }

            let outerRings = outerRings(of: feature["geometry"] as? [String: Any])
            guard !outerRings.isEmpty else { continue }
            result[code, default: []].append(contentsOf: outerRings)
        }
        return result
    }

    /// Outer ring (index 0) of each polygon; holes are dropped — invisible at this scale.
    private static func outerRings(of geometry: [String: Any]?) -> [Ring] {
        guard let geometry else { return [] }
        let polys: [[[[Double]]]]
        if geometry["type"] as? String == "Polygon", let c = geometry["coordinates"] as? [[[Double]]] {
            polys = [c]
        } else if let c = geometry["coordinates"] as? [[[[Double]]]] {
            polys = c
        } else {
            return []
        }
        return polys.compactMap { poly in
            guard let ring = poly.first, ring.count > 3 else { return nil }
            return ring.map { SIMD2<Double>($0[0], $0[1]) }
        }
    }
}

// MARK: - Sphere math

enum GlobeMath {
    /// lat/lng in degrees → point on a sphere of the given radius. Y is up;
    /// (0°,0°) faces +Z so the default camera looks at the prime meridian.
    static func vec3(lat: Double, lng: Double, radius: Double) -> SCNVector3 {
        let phi = lat * .pi / 180
        let lambda = lng * .pi / 180
        return SCNVector3(
            Float(radius * cos(phi) * sin(lambda)),
            Float(radius * sin(phi)),
            Float(radius * cos(phi) * cos(lambda))
        )
    }
}

// MARK: - Ear-clipping triangulation (2D, lng/lat space)

enum EarClip {
    /// Returns triangle index triples into `ring`. Assumes a simple (non-self-
    /// intersecting) polygon; the last vertex may repeat the first (geojson does).
    static func triangulate(_ ring: Ring) -> [Int] {
        var pts = ring
        // geojson closes rings by repeating the first point — drop the duplicate.
        if pts.count > 1, pts.first == pts.last { pts.removeLast() }
        let n = pts.count
        guard n >= 3 else { return [] }

        var indices = Array(0..<n)
        // Ear clipping needs CCW winding; reverse if the signed area is negative.
        if signedArea(pts) < 0 { indices.reverse() }

        var triangles: [Int] = []
        var guardCounter = 0
        let maxIterations = n * n

        while indices.count > 3 {
            guardCounter += 1
            if guardCounter > maxIterations { break } // degenerate polygon safety net

            var earFound = false
            let count = indices.count
            for i in 0..<count {
                let prev = indices[(i + count - 1) % count]
                let curr = indices[i]
                let next = indices[(i + 1) % count]

                let a = pts[prev], b = pts[curr], c = pts[next]
                guard cross(a, b, c) > 0 else { continue } // reflex vertex, not an ear

                // No other vertex may lie inside triangle a-b-c.
                var contains = false
                for j in indices where j != prev && j != curr && j != next {
                    if pointInTriangle(pts[j], a, b, c) { contains = true; break }
                }
                if contains { continue }

                triangles.append(contentsOf: [prev, curr, next])
                indices.remove(at: i)
                earFound = true
                break
            }
            // Natural Earth rings occasionally have collinear runs or slight self-
            // intersections where no clean ear exists. Rather than bail (which
            // leaves a country half-filled), force progress by clipping the most
            // convex corner. Costs a tiny sliver, never a hole.
            if !earFound {
                var bestIdx = 0
                var bestConvexity = -Double.greatestFiniteMagnitude
                let count = indices.count
                for i in 0..<count {
                    let a = pts[indices[(i + count - 1) % count]]
                    let b = pts[indices[i]]
                    let c = pts[indices[(i + 1) % count]]
                    let convexity = cross(a, b, c)
                    if convexity > bestConvexity { bestConvexity = convexity; bestIdx = i }
                }
                let prev = indices[(bestIdx + count - 1) % count]
                let curr = indices[bestIdx]
                let next = indices[(bestIdx + 1) % count]
                triangles.append(contentsOf: [prev, curr, next])
                indices.remove(at: bestIdx)
            }
        }
        if indices.count == 3 {
            triangles.append(contentsOf: indices)
        }
        return triangles
    }

    private static func signedArea(_ p: Ring) -> Double {
        var area = 0.0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    /// z-component of (b-a)×(c-a); > 0 means a→b→c turns left (convex for CCW).
    private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func pointInTriangle(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
        let d1 = cross(a, b, p)
        let d2 = cross(b, c, p)
        let d3 = cross(c, a, p)
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        let hasPos = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNeg && hasPos) // all same sign → inside
    }
}

// MARK: - Node builder

enum GlobeNodeFactory {
    /// Country caps sit just above the ocean sphere so they don't z-fight.
    static let oceanRadius: Double = 1.0
    static let capRadius: Double = 1.004

    /// A flat ear-clipped triangle chord dips below the sphere at its center; a
    /// large one sinks past the ocean and the ocean poked through as a hole. So
    /// we recursively split any triangle whose edge chord exceeds this (~4.6°),
    /// projecting midpoints back onto the sphere so the fill hugs the surface.
    private static let maxChord: Float = 0.08
    /// Ear clipping on the occasional self-intersecting Natural Earth ring emits a
    /// giant spanning triangle (grey sliver across the globe). Drop those.
    private static let dropChord: Float = 1.2
    private static let maxDepth = 6

    /// The tessellated mesh for a country (immutable, colorless). Reused across
    /// every globe instance so the ear-clip + subdivision runs once per country.
    private typealias Mesh = (source: SCNGeometrySource, element: SCNGeometryElement)

    /// Country geometry is identical for every user/globe, but ear-clipping +
    /// depth-6 subdivision of all 174 countries is expensive, so we build each
    /// mesh once and cache it. Keyed entries can be nil for countries with no
    /// usable geometry so we don't retry them. (Access is main-thread only —
    /// buildScene runs in makeUIView — so a plain static dictionary is safe.)
    private static var meshCache: [String: Mesh?] = [:]

    /// A single SCNNode holding all of a country's filled polygon caps, tinted.
    /// Returns nil if the country has no usable geometry. The heavy mesh is cached
    /// (see `meshCache`); only a lightweight SCNGeometry + material is built per
    /// call, so re-entering a globe view is cheap.
    static func countryNode(code: String, color: UIColor) -> SCNNode? {
        let mesh: Mesh?
        if let cached = meshCache[code] {
            mesh = cached                      // may be nil: known-empty country
        } else {
            mesh = buildMesh(code: code)
            meshCache[code] = mesh
        }
        guard let mesh else { return nil }

        let geometry = SCNGeometry(sources: [mesh.source], elements: [mesh.element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.isDoubleSided = true          // rings may wind either way after projection
        material.lightingModel = .constant     // flat, map-like fill (no shading falloff)
        material.writesToDepthBuffer = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = code                       // hit-testing reads this back
        return node
    }

    /// Ear-clip + subdivide a country's rings into a reusable SCNGeometry mesh.
    /// nil if the country has no usable geometry.
    private static func buildMesh(code: String) -> Mesh? {
        guard let rings = CountryGeometry.rings[code], !rings.isEmpty else { return nil }

        var vertices: [SCNVector3] = []
        var indices: [Int32] = []

        for ring in rings {
            let tris = EarClip.triangulate(ring)
            guard tris.count >= 3 else { continue }
            var loop = ring
            if loop.count > 1, loop.first == loop.last { loop.removeLast() }
            let sphere = loop.map { GlobeMath.vec3(lat: $0.y, lng: $0.x, radius: capRadius) }

            for t in stride(from: 0, to: tris.count - 2, by: 3) {
                let a = sphere[tris[t]], b = sphere[tris[t + 1]], c = sphere[tris[t + 2]]
                if max(chord(a, b), chord(b, c), chord(c, a)) > dropChord { continue }
                let pieces = tessellate(a, b, c, depth: maxDepth)
                let base = Int32(vertices.count)
                vertices.append(contentsOf: pieces)
                indices.append(contentsOf: (0..<Int32(pieces.count)).map { base + $0 })
            }
        }
        guard !vertices.isEmpty, !indices.isEmpty else { return nil }

        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return (source, element)
    }

    /// Recursively split triangle a-b-c into 4 until every edge is short enough to
    /// hug the sphere, projecting each midpoint back onto the cap radius.
    private static func tessellate(_ a: SCNVector3, _ b: SCNVector3, _ c: SCNVector3, depth: Int) -> [SCNVector3] {
        if depth == 0 || max(chord(a, b), chord(b, c), chord(c, a)) <= maxChord {
            return [a, b, c]
        }
        let ab = onSphere(mid(a, b)), bc = onSphere(mid(b, c)), ca = onSphere(mid(c, a))
        return tessellate(a, ab, ca, depth: depth - 1)
            + tessellate(ab, b, bc, depth: depth - 1)
            + tessellate(ca, bc, c, depth: depth - 1)
            + tessellate(ab, bc, ca, depth: depth - 1)
    }

    private static func chord(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    private static func mid(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
    }

    /// Push a point out to the cap radius (used on interpolated midpoints).
    private static func onSphere(_ p: SCNVector3) -> SCNVector3 {
        let len = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
        guard len > 0 else { return p }
        let r = Float(capRadius) / len
        return SCNVector3(p.x * r, p.y * r, p.z * r)
    }
}
