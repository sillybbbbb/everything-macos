import Foundation
import Darwin
import CryptoKit

struct SharedLocation {
    let id: String
    let name: String
    let root: String
    let connected: Bool
}

enum SharedSources {
    static func cstring<T>(_ value: T) -> String {
        var v = value
        return withUnsafePointer(to: &v) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
    }
    static func mounted() -> [SharedLocation] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts = mounts else { return [] }
        return (0..<Int(count)).compactMap { i in
            let mount = mounts[i]
            guard cstring(mount.f_fstypename) == "smbfs" else { return nil }
            let root = cstring(mount.f_mntonname)
            let digest = SHA256.hash(data: Data(cstring(mount.f_mntfromname).utf8)).map { String(format: "%02x", $0) }.joined()
            return SharedLocation(id: digest, name: URL(fileURLWithPath: root).lastPathComponent, root: root, connected: true)
        }
    }
    static func readDisabled(in data: URL) -> Set<String> {
        guard let bytes = try? Data(contentsOf: data.appendingPathComponent("shared-selection.json")),
              let ids = try? JSONDecoder().decode([String].self, from: bytes) else { return [] }
        return Set(ids)
    }
    static func saveDisabled(_ ids: Set<String>, in data: URL) throws {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try JSONEncoder().encode(ids.sorted()).write(to: data.appendingPathComponent("shared-selection.json"), options: .atomic)
    }
    static func known(in data: URL) -> [SharedLocation] {
        var result = mounted()
        if let bytes = try? Data(contentsOf: data.appendingPathComponent("index.json")),
           let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let sources = object["sources"] as? [[String: Any]] {
            for source in sources {
                guard let id = source["id"] as? String, id != "home", let root = source["root"] as? String,
                      !result.contains(where: { $0.id == id || $0.root == root }) else { continue }
                result.append(SharedLocation(id: id, name: source["name"] as? String ?? URL(fileURLWithPath: root).lastPathComponent, root: root, connected: false))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
