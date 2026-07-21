import Foundation
import SceneKit
import simd

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
    private struct CountryPolygon {
        let outer: Ring
        let holes: [Ring]
    }

    /// Full polygon topology used for hit resolution. Keeping interior rings
    /// matters for enclaves: Natural Earth represents Lesotho as a hole in
    /// South Africa, so dropping holes gives both countries the same tap area.
    private static let polygons: [String: [CountryPolygon]] = load()

    /// ISO_A2 → its outer rings (a country may be several polygons, e.g. islands).
    /// Rendering consumes these same boundaries; hit resolution additionally
    /// consults the interior rings retained in `polygons` above.
    static let rings: [String: [Ring]] = polygons.mapValues { $0.map(\.outer) }

    // Natural Earth 110m sets ISO_A2 = -99 for these; match CountryStore.isoFix.
    private static let isoFix = ["France": "FR", "Norway": "NO", "Kosovo": "XK"]

    private static func load() -> [String: [CountryPolygon]] {
        guard let url = Bundle.main.url(forResource: "countries", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]]
        else {
            assertionFailure("countries.geojson missing from bundle")
            return [:]
        }

        var result: [String: [CountryPolygon]] = [:]
        for feature in features {
            guard let props = feature["properties"] as? [String: Any] else { continue }
            var code = props["ISO_A2"] as? String ?? ""
            if code.count != 2 || code == "-9" {
                code = isoFix[props["ADMIN"] as? String ?? ""] ?? ""
            }
            guard code.count == 2, code.allSatisfy({ $0.isUppercase }), code != "AQ" else { continue }

            let countryPolygons = countryPolygons(of: feature["geometry"] as? [String: Any])
            guard !countryPolygons.isEmpty else { continue }
            result[code, default: []].append(contentsOf: countryPolygons)
        }
        return result
    }

    // ── Point → country lookup (globe tap resolution) ────────────────────────
    // Hit-testing SceneKit triangles is unreliable for the caps (winding after
    // sphere projection back-face-culls them out of hit results), so taps
    // resolve geographically instead: sphere hit point → lat/lng → which
    // country ring contains it.

    private struct IndexedPolygon {
        let code: String
        let minLng: Double, maxLng: Double, minLat: Double, maxLat: Double
        let outer: Ring
        let holes: [Ring]
    }

    private static let polygonIndex: [IndexedPolygon] = polygons.flatMap { code, polygons in
        polygons.compactMap { polygon -> IndexedPolygon? in
            guard polygon.outer.count > 3 else { return nil }
            var minLng = Double.greatestFiniteMagnitude, maxLng = -Double.greatestFiniteMagnitude
            var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
            for p in polygon.outer {
                minLng = min(minLng, p.x); maxLng = max(maxLng, p.x)
                minLat = min(minLat, p.y); maxLat = max(maxLat, p.y)
            }
            return IndexedPolygon(code: code, minLng: minLng, maxLng: maxLng,
                                  minLat: minLat, maxLat: maxLat,
                                  outer: polygon.outer, holes: polygon.holes)
        }
    }

    /// The country whose polygon contains (lat, lng), or nil for open ocean.
    /// There is intentionally no fuzzy fallback: selectable regions must end at
    /// the same geographic boundaries that are drawn on the globe.
    static func country(atLat lat: Double, lng: Double) -> String? {
        for entry in polygonIndex
        where lng >= entry.minLng && lng <= entry.maxLng
            && lat >= entry.minLat && lat <= entry.maxLat {
            guard contains(entry.outer, lng: lng, lat: lat) else { continue }
            if !entry.holes.contains(where: { contains($0, lng: lng, lat: lat) }) {
                return entry.code
            }
        }
        return nil
    }

    /// Rough footprint of a country's largest ring in lat-corrected deg² —
    /// drives how far the camera zooms when flying there.
    static func sizeHint(_ code: String) -> Double {
        sizeHints[code] ?? 0
    }

    private static let sizeHints: [String: Double] = {
        var result: [String: Double] = [:]
        for entry in polygonIndex {
            let mid = (entry.minLat + entry.maxLat) / 2
            let area = (entry.maxLng - entry.minLng) * (entry.maxLat - entry.minLat) * cos(mid * .pi / 180)
            result[entry.code] = max(result[entry.code] ?? 0, area)
        }
        return result
    }()

    /// Standard even-odd ray cast in lng/lat space (Natural Earth polygons are
    /// split at the dateline, so no wrap handling is needed).
    static func contains(_ ring: Ring, lng: Double, lat: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > lat) != (b.y > lat),
               lng < (b.x - a.x) * (lat - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Every polygon with its outer boundary and any interior holes.
    private static func countryPolygons(of geometry: [String: Any]?) -> [CountryPolygon] {
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
            guard let outer = poly.first, outer.count > 3 else { return nil }
            let outerRing = EarClip.cleaned(outer.map { SIMD2<Double>($0[0], $0[1]) })
            guard outerRing.count >= 3 else { return nil }
            return CountryPolygon(
                outer: outerRing,
                holes: poly.dropFirst().compactMap { ring in
                    guard ring.count > 3 else { return nil }
                    let cleaned = EarClip.cleaned(ring.map { SIMD2<Double>($0[0], $0[1]) })
                    return cleaned.count >= 3 ? cleaned : nil
                }
            )
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

    /// Nearest forward intersection between a ray and a sphere centred at the
    /// origin. Globe taps use this instead of SceneKit geometry hit-testing so
    /// raised borders, tessellated caps, and back faces cannot shift the point.
    static func frontIntersection(rayOrigin origin: SIMD3<Float>,
                                  rayDirection direction: SIMD3<Float>,
                                  radius: Float) -> SIMD3<Float>? {
        let a = simd_dot(direction, direction)
        guard a > Float.ulpOfOne else { return nil }
        let b = 2 * simd_dot(origin, direction)
        let c = simd_dot(origin, origin) - radius * radius
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return nil }

        let root = sqrt(discriminant)
        let near = (-b - root) / (2 * a)
        let far = (-b + root) / (2 * a)
        let distance: Float
        if near >= 0 {
            distance = near
        } else if far >= 0 {
            distance = far
        } else {
            return nil
        }
        return origin + direction * distance
    }

    static func latLng(at point: SIMD3<Float>) -> (lat: Double, lng: Double)? {
        let radius = simd_length(point)
        guard radius > 0 else { return nil }
        let lat = asin(max(-1, min(1, Double(point.y / radius)))) * 180 / .pi
        let lng = atan2(Double(point.x), Double(point.z)) * 180 / .pi
        return (lat, lng)
    }
}

// MARK: - Ear-clipping triangulation (2D, lng/lat space)

enum EarClip {
    /// Returns triangle index triples into `ring`. Assumes a simple (non-self-
    /// intersecting) polygon; the last vertex may repeat the first (geojson does).
    static func triangulate(_ ring: Ring) -> [Int] {
        let pts = cleaned(ring)
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
            // Never manufacture a triangle when no valid ear exists. The old
            // fallback crossed outside malformed rings (most visibly Alaska over
            // Canada). Cleaning duplicate vertices handles the Natural Earth
            // degeneracies we ship; returning no mesh is safer than drawing land
            // outside a country's border if future data is actually invalid.
            if !earFound {
                return []
            }
        }
        if indices.count == 3 {
            triangles.append(contentsOf: indices)
        }
        return triangles
    }

    /// Natural Earth occasionally repeats a closing coordinate more than once
    /// or includes two practically identical consecutive points. Both create a
    /// zero-area ear and used to activate the unsafe fallback above.
    static func cleaned(_ ring: Ring) -> Ring {
        let duplicateThresholdSquared = 1e-8 // 0.0001°, roughly 11 m at the equator
        func nearlyEqual(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
            let delta = a - b
            return delta.x * delta.x + delta.y * delta.y <= duplicateThresholdSquared
        }

        var points: Ring = []
        for point in ring {
            if let last = points.last, nearlyEqual(last, point) { continue }
            points.append(point)
        }
        while points.count > 1,
              let first = points.first,
              let last = points.last,
              nearlyEqual(first, last) {
            points.removeLast()
        }

        // Remove exact/near-exact collinear runs. Besides wasting triangles,
        // these can leave a numerically positive but visually zero-area corner
        // that blocks a later valid ear (Canada's far-north rings contain one).
        var removedPoint = true
        while removedPoint, points.count >= 3 {
            removedPoint = false
            for index in points.indices {
                let previous = points[(index + points.count - 1) % points.count]
                let current = points[index]
                let next = points[(index + 1) % points.count]
                if abs(cross(previous, current, next)) <= 1e-10 {
                    points.remove(at: index)
                    removedPoint = true
                    break
                }
            }
        }
        return points
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
    /// large one sinks past the ocean and the ocean pokes through as a hole. We
    /// recursively split every long edge (~4.6°) in lng/lat space, then project
    /// the small pieces. Interpolating on the sphere instead makes long triangle
    /// edges follow great-circle arcs that can curve outside the drawn border.
    private static let maxChord: Float = 0.08
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
            let loop = EarClip.cleaned(ring)
            let tris = EarClip.triangulate(loop)
            guard tris.count >= 3 else { continue }

            for t in stride(from: 0, to: tris.count - 2, by: 3) {
                let a = loop[tris[t]], b = loop[tris[t + 1]], c = loop[tris[t + 2]]
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

    /// Recursively split triangle a-b-c in the same lng/lat plane used by the
    /// polygon and its borders. Only the final small triangles are projected.
    private static func tessellate(_ a: SIMD2<Double>, _ b: SIMD2<Double>,
                                   _ c: SIMD2<Double>, depth: Int) -> [SCNVector3] {
        let av = spherePoint(a), bv = spherePoint(b), cv = spherePoint(c)
        if depth == 0 || max(chord(av, bv), chord(bv, cv), chord(cv, av)) <= maxChord {
            return [av, bv, cv]
        }
        let ab = (a + b) / 2
        let bc = (b + c) / 2
        let ca = (c + a) / 2
        return tessellate(a, ab, ca, depth: depth - 1)
            + tessellate(ab, b, bc, depth: depth - 1)
            + tessellate(ca, bc, c, depth: depth - 1)
            + tessellate(ab, bc, ca, depth: depth - 1)
    }

    private static func spherePoint(_ point: SIMD2<Double>) -> SCNVector3 {
        GlobeMath.vec3(lat: point.y, lng: point.x, radius: capRadius)
    }

    private static func chord(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

}
