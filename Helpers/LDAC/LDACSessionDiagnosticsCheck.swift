import Foundation

@main
enum LDACSessionDiagnosticsCheck {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        var completed: [URL] = []
        for index in 0..<10 {
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            let marker = directory.appendingPathComponent("completed")
            try Data().write(to: marker)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: marker.path)
            completed.append(directory)
        }
        let active = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let current = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        for directory in [active, current, unrelated] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try Data("unchanged".utf8).write(to: active.appendingPathComponent("session.log"))
        try Data().write(to: unrelated.appendingPathComponent("completed"))
        let linked = root.appendingPathComponent(UUID().uuidString)
        try manager.createSymbolicLink(at: linked, withDestinationURL: unrelated)
        try LDACNativeSession.completeDiagnostics(in: current)
        for (index, directory) in completed.enumerated() {
            precondition(manager.fileExists(atPath: directory.path) == (index >= 3))
        }
        precondition(manager.fileExists(atPath: current.appendingPathComponent("completed").path))
        precondition(manager.fileExists(atPath: unrelated.path))
        precondition(manager.fileExists(atPath: linked.path))
        let contents = try Data(contentsOf: active.appendingPathComponent("session.log"))
        precondition(contents == Data("unchanged".utf8))
        precondition(!manager.fileExists(atPath: active.appendingPathComponent("completed").path))
        print("LDAC diagnostic retention checks passed")
    }
}
