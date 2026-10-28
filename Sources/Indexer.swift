import Foundation
import Darwin
import CryptoKit

let fm = FileManager.default
#if TESTING
let data = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EVERYTHING_TEST_DATA"]!)
#else
let data = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/EverythingMac")
#endif
try fm.createDirectory(at: data, withIntermediateDirectories: true)
let lock = open(data.appendingPathComponent("refresh.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
defer { flock(lock, LOCK_UN); close(lock) }
func save(_ name: String, _ object: Any) throws {
    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try bytes.write(to: data.appendingPathComponent(name), options: .atomic)
}
func read(_ name: String) -> [String: Any] {
    guard let bytes = try? Data(contentsOf: data.appendingPathComponent(name)),
          let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
    return object
}
func cstring<T>(_ value: T) -> String { SharedSources.cstring(value) }
func smbMounts() -> [(String, String)] {
    #if TESTING
    let raw = ProcessInfo.processInfo.environment["EVERYTHING_TEST_MOUNTS"] ?? "[]"
    let entries = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String]] ?? []
    return entries.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    #else
    return SharedSources.mounted().map { ($0.root, $0.id) }
    #endif
}
let started = Date()
func status(_ state: String, _ message: String, _ count: Int = 0) {
    try? save("status.json", ["state":state,"message":message,"count":count,"updated":Date().timeIntervalSince1970,"started":started.timeIntervalSince1970])
}
let oldIndex = read("index.json")
let oldSources = oldIndex["sources"] as? [[String: Any]] ?? []
let mounted = smbMounts()
let disabled = SharedSources.readDisabled(in: data)
#if TESTING
let home = ProcessInfo.processInfo.environment["EVERYTHING_TEST_HOME"]!
#else
let home = fm.homeDirectoryForCurrentUser.path
#endif
var homeFS = statfs()
let homeMount = statfs(home, &homeFS) == 0 ? cstring(homeFS.f_mntonname) : ""
var sources: [[String: Any]] = [["name":"本地", "root":home, "id":"home", "network":false]]
for (root, id) in mounted { sources.append(["name":URL(fileURLWithPath: root).lastPathComponent, "root":root, "id":id, "network":true]) }
for old in oldSources {
    guard let id = old["id"] as? String, id != "home", !sources.contains(where: { ($0["id"] as? String) == id }) else { continue }
    guard let root = old["root"] as? String, !sources.contains(where: { ($0["root"] as? String) == root }) else { continue }
    sources.append(["name":old["name"] ?? URL(fileURLWithPath:root).lastPathComponent,"root":root,"id":id,"network":true,"offline":true])
}
let cache: Set<String> = [".cache", "Caches", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".npm", ".pnpm-store"]
let excludes = ["Library", ".Trash", ".codex/plugins/cache", ".codex/tmp", ".swiftpm/cache"].map { home + "/" + $0 }
let packages: Set<String> = ["app", "framework", "bundle", "photoslibrary", "photolibrary", "musiclibrary", "pvm"]
var results = [[String:Any]]()
var warnings = [String]()
var allErrors = [[String:String]]()
func publish(_ sources: [[String:Any]]) throws {
    var paths = [String](), seen = Set<String>(), metadata = [String:Any]()
    for source in sources {
        for path in source["paths"] as? [String] ?? [] where seen.insert(path).inserted { paths.append(path) }
        for (path, value) in source["metadata"] as? [String:Any] ?? [:] { metadata[path] = value }
    }
    try save("index.json", ["sources":sources,"paths":paths,"metadata":metadata,"count":paths.count,"updated":ISO8601DateFormatter().string(from: Date())])
}
for (position, source) in sources.enumerated() {
    let sourceStarted = Date()
    let name = source["name"] as! String, root = source["root"] as! String, id = source["id"] as! String
    let network = source["network"] as? Bool == true
    let old = oldSources.first { ($0["id"] as? String) == id && ($0["root"] as? String) == root } ?? ["name":name,"root":root,"id":id,"paths":[String](),"metadata":[:]]
    status("running", "正在刷新 \(name)；已有索引仍可搜索。")
    var paths = [String](), metadata = [String:Any](), errors = [[String:String]](), pending = [root]
    var failure: String? = disabled.contains(id) ? "已停用，保留缓存" : (source["offline"] as? Bool == true ? "未连接，保留上次索引" : nil)
    var last = Date.distantPast
    while failure == nil && !pending.isEmpty {
        if Date().timeIntervalSince(sourceStarted) > 2700 { failure = "扫描超时，保留上次索引"; break }
        let dir = pending.removeLast()
        do {
            let entries = try fm.contentsOfDirectory(at: URL(fileURLWithPath:dir), includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey,.contentModificationDateKey,.fileSizeKey], options: [])
            for entry in entries {
                let path = entry.path, item = entry.lastPathComponent
                if item == ".DS_Store" || item.hasPrefix("._") { continue }
                if !network && (cache.contains(item) || excludes.contains(path)) { continue }
                do {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey,.contentModificationDateKey,.fileSizeKey])
                    let directory = values.isDirectory == true && values.isSymbolicLink != true
                    paths.append(path)
                    var meta: [String:Any] = ["directory":directory]
                    if let date = values.contentModificationDate { meta["modified"] = date.timeIntervalSince1970 }
                    if !directory, let size = values.fileSize { meta["size"] = size }
                    metadata[path] = meta
                    if directory && !(packages.contains(entry.pathExtension.lowercased())) {
                        var fs = statfs()
                        if network || (statfs(path, &fs) == 0 && cstring(fs.f_mntonname) == homeMount) { pending.append(path) }
                    }
                } catch { errors.append(["path":path,"error":error.localizedDescription]) }
            }
        } catch { errors.append(["path":dir,"error":error.localizedDescription]) }
        if Date().timeIntervalSince(last) > 1 { status("running", "正在刷新 \(name)；已有索引仍可搜索。", paths.count); last = Date() }
    }
    if network && failure == nil && !smbMounts().contains(where: { $0.0 == root && $0.1 == id }) { failure = "连接已断开或变化，保留上次索引" }
    if network && !errors.isEmpty { failure = "部分目录读取失败，保留上次索引" }
    allErrors.append(contentsOf: errors)
    var result: [String:Any]
    if let failure = failure {
        result = old; result["warning"] = failure; if !disabled.contains(id) { warnings.append("\(name)：\(failure)") }
    } else {
        if !errors.isEmpty {
            let previous = old["paths"] as? [String] ?? []
            let oldMeta = old["metadata"] as? [String:Any] ?? [:]
            for error in errors {
                let path = error["path"] ?? ""
                for p in previous where p == path || p.hasPrefix(path + "/") {
                    if !paths.contains(p) { paths.append(p) }; if let value = oldMeta[p] { metadata[p] = value }
                }
            }
            warnings.append("\(name)有 \(errors.count) 个位置无法读取")
        }
        result = ["name":name,"root":root,"id":id,"paths":paths,"metadata":metadata,"updated":ISO8601DateFormatter().string(from: Date())]
    }
    results.append(result)
    let pendingOld = sources.dropFirst(position + 1).compactMap { s in oldSources.first { ($0["id"] as? String) == (s["id"] as? String) && ($0["root"] as? String) == (s["root"] as? String) } }
    try publish(results + pendingOld)
}
try save("errors.json", allErrors)
let counts = results.filter { !disabled.contains($0["id"] as? String ?? "") }.map { "\($0["name"] ?? "") \(($0["paths"] as? [String] ?? []).count) 项" }.joined(separator:" · ")
status(warnings.isEmpty ? "ready" : "warning", counts + (warnings.isEmpty ? "" : " · " + warnings.joined(separator:"；")))
