import XCTest
@testable import CulinaryPassport

final class CountryGeometryTests: XCTestCase {
    func testChinaMongoliaSharedBorderResolvesOnTheTouchedSide() {
        // Two points only 0.01° apart on opposite sides of the exact shared
        // Natural Earth segment from (104.964994, 41.59741) to
        // (106.129316, 42.134328).
        XCTAssertEqual(CountryGeometry.country(atLat: 41.861329, lng: 105.549249), "CN")
        XCTAssertEqual(CountryGeometry.country(atLat: 41.870409, lng: 105.545061), "MN")
    }

    func testOpenOceanNearCoastDoesNotSnapToCountry() {
        // This is less than 0.4° off Portugal's west coast. The previous
        // 1.2° near-miss halo incorrectly returned Portugal here.
        XCTAssertNil(CountryGeometry.country(atLat: 39.0, lng: -9.8))
    }

    func testInteriorPolygonHoleBelongsToEnclave() {
        // Lesotho is an interior ring in South Africa's polygon. Discarding
        // holes made both countries claim this point.
        XCTAssertEqual(CountryGeometry.country(atLat: -29.6, lng: 28.2), "LS")
        XCTAssertEqual(CountryGeometry.country(atLat: -30.5, lng: 25.0), "ZA")
    }

    func testAnalyticRayUsesFrontGlobeSurface() throws {
        let hit = try XCTUnwrap(GlobeMath.frontIntersection(
            rayOrigin: SIMD3<Float>(0, 0, 5),
            rayDirection: SIMD3<Float>(0, 0, -1),
            radius: 1
        ))
        XCTAssertEqual(hit.x, 0, accuracy: 0.0001)
        XCTAssertEqual(hit.y, 0, accuracy: 0.0001)
        XCTAssertEqual(hit.z, 1, accuracy: 0.0001)

        let coordinate = try XCTUnwrap(GlobeMath.latLng(at: hit))
        XCTAssertEqual(coordinate.lat, 0, accuracy: 0.0001)
        XCTAssertEqual(coordinate.lng, 0, accuracy: 0.0001)
    }

    func testAnalyticRayRejectsTouchesOutsideGlobe() {
        XCTAssertNil(GlobeMath.frontIntersection(
            rayOrigin: SIMD3<Float>(0, 0, 5),
            rayDirection: SIMD3<Float>(2, 0, -1),
            radius: 1
        ))
    }

    func testSomalilandAndNorthernCyprusAreDrawnAsPartOfTheirCountry() {
        // Both are ISO_A2 = -99 in the 110m data and used to vanish: no fill,
        // no tap target, a hole of ocean in the Horn of Africa.
        XCTAssertEqual(CountryGeometry.country(atLat: 9.56, lng: 44.07), "SO")   // Hargeisa
        XCTAssertEqual(CountryGeometry.country(atLat: 35.34, lng: 33.32), "CY")  // Kyrenia
        XCTAssertEqual(CountryGeometry.rings["SO"]?.count, 2)
        XCTAssertEqual(CountryGeometry.rings["CY"]?.count, 2)
    }

    func testEnclaveIsCutOutOfTheFillAroundIt() throws {
        let polygon = try XCTUnwrap(CountryGeometry.ringsWithHoles("ZA").first { !$0.holes.isEmpty })
        let loop = EarClip.cleaned(EarClip.merge(outer: polygon.outer, holes: polygon.holes))
        let triangles = EarClip.triangulate(loop)
        XCTAssertEqual(triangles.count, (loop.count - 2) * 3, "bridged polygon must triangulate completely")

        for town in [SIMD2<Double>(27.48, -29.31), SIMD2<Double>(28.2, -29.6)] {  // Maseru, Thaba-Tseka
            for index in stride(from: 0, to: triangles.count, by: 3) {
                let a = loop[triangles[index]], b = loop[triangles[index + 1]], c = loop[triangles[index + 2]]
                XCTAssertFalse(inTriangle(town, a, b, c),
                               "South Africa's fill covers Lesotho at \(town)")
            }
        }
    }

    func testHoleBridgingKeepsTrianglesInsideTheCountry() {
        for (code, polygons) in ["ZA"].compactMap({ ($0, CountryGeometry.ringsWithHoles($0)) }) {
            for polygon in polygons where !polygon.holes.isEmpty {
                let loop = EarClip.cleaned(EarClip.merge(outer: polygon.outer, holes: polygon.holes))
                let triangles = EarClip.triangulate(loop)
                for index in stride(from: 0, to: triangles.count, by: 3) {
                    let a = loop[triangles[index]], b = loop[triangles[index + 1]], c = loop[triangles[index + 2]]
                    for sample in [(a * 0.6) + (b * 0.2) + (c * 0.2),
                                   (a * 0.2) + (b * 0.6) + (c * 0.2),
                                   (a * 0.2) + (b * 0.2) + (c * 0.6)] {
                        XCTAssertTrue(CountryGeometry.contains(polygon.outer, lng: sample.x, lat: sample.y),
                                      "\(code) filled outside its border at \(sample)")
                        for hole in polygon.holes {
                            XCTAssertFalse(CountryGeometry.contains(hole, lng: sample.x, lat: sample.y),
                                           "\(code) filled over an enclave at \(sample)")
                        }
                    }
                }
            }
        }
    }

    private func inTriangle(_ p: SIMD2<Double>, _ a: SIMD2<Double>,
                            _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
        func side(_ x: SIMD2<Double>, _ y: SIMD2<Double>, _ z: SIMD2<Double>) -> Double {
            (y.x - x.x) * (z.y - x.y) - (y.y - x.y) * (z.x - x.x)
        }
        let d1 = side(a, b, p), d2 = side(b, c, p), d3 = side(c, a, p)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }

    func testEveryCountryRingTriangulatesCompletelyWithoutLeaking() {
        var checkedRings = 0
        for (code, rings) in CountryGeometry.rings {
            for ring in rings {
                let points = EarClip.cleaned(ring)
                let triangles = EarClip.triangulate(points)
                XCTAssertGreaterThanOrEqual(points.count, 3, "\(code) has a degenerate ring")
                XCTAssertEqual(
                    triangles.count,
                    (points.count - 2) * 3,
                    "\(code) did not produce a complete triangulation"
                )

                for index in stride(from: 0, to: triangles.count, by: 3) {
                    let a = points[triangles[index]]
                    let b = points[triangles[index + 1]]
                    let c = points[triangles[index + 2]]
                    // Interior barycentric samples catch a diagonal that exits a
                    // concave polygon without treating boundary edges as leaks.
                    let samples = [
                        (a * 0.6) + (b * 0.2) + (c * 0.2),
                        (a * 0.2) + (b * 0.6) + (c * 0.2),
                        (a * 0.2) + (b * 0.2) + (c * 0.6),
                    ]
                    for sample in samples {
                        XCTAssertTrue(
                            CountryGeometry.contains(ring, lng: sample.x, lat: sample.y),
                            "\(code) generated a triangle outside its own border at \(sample)"
                        )
                    }
                }
                checkedRings += 1
            }
        }
        XCTAssertGreaterThan(checkedRings, 250)
    }
}
