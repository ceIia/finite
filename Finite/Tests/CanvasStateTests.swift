import XCTest
@testable import Finite

final class CanvasStateTests: XCTestCase {

    // MARK: - Encoding / Decoding

    func testRoundtripEncoding() throws {
        let state = CanvasState(
            nodes: [
                CanvasState.NodeState(x: 10, y: 20, width: 300, height: 200, title: "zsh", workingDirectory: "/tmp"),
                CanvasState.NodeState(x: 400, y: 50, width: 500, height: 400, title: "vim", workingDirectory: nil),
            ],
            offsetX: -100,
            offsetY: 50,
            scale: 1.5,
            windowX: 100,
            windowY: 200,
            windowWidth: 1200,
            windowHeight: 800
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CanvasState.self, from: data)

        XCTAssertEqual(decoded.nodes.count, 2)
        XCTAssertEqual(decoded.nodes[0].title, "zsh")
        XCTAssertEqual(decoded.nodes[0].workingDirectory, "/tmp")
        XCTAssertEqual(decoded.nodes[1].title, "vim")
        XCTAssertNil(decoded.nodes[1].workingDirectory)
        XCTAssertEqual(decoded.offsetX, -100)
        XCTAssertEqual(decoded.offsetY, 50)
        XCTAssertEqual(decoded.scale, 1.5)
        XCTAssertEqual(decoded.windowX, 100)
        XCTAssertEqual(decoded.windowY, 200)
        XCTAssertEqual(decoded.windowWidth, 1200)
        XCTAssertEqual(decoded.windowHeight, 800)
    }

    func testDecodingWithoutWindowFrame() throws {
        let json = """
        {
            "nodes": [],
            "offsetX": 0,
            "offsetY": 0,
            "scale": 1.0
        }
        """
        let data = json.data(using: .utf8)!
        let state = try JSONDecoder().decode(CanvasState.self, from: data)

        XCTAssertTrue(state.nodes.isEmpty)
        XCTAssertNil(state.windowX)
        XCTAssertNil(state.windowY)
        XCTAssertNil(state.windowWidth)
        XCTAssertNil(state.windowHeight)
    }

    func testDecodingWithExtraFields() throws {
        // Ensure forward compatibility — extra fields shouldn't break decoding
        let json = """
        {
            "nodes": [],
            "offsetX": 0,
            "offsetY": 0,
            "scale": 1.0,
            "unknownField": "ignored"
        }
        """
        let data = json.data(using: .utf8)!
        // This may throw if the decoder is strict, which is fine — just documents behavior
        let state = try? JSONDecoder().decode(CanvasState.self, from: data)
        // Codable by default ignores unknown keys, so this should succeed
        XCTAssertNotNil(state)
    }
}
