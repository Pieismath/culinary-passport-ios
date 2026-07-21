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
