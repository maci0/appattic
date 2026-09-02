import Foundation

func defaultCrossOverBottlesDir() -> String? {
    if PlatformOverride.isLinux { return nil }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return (home as NSString).appendingPathComponent("Library/Application Support/CrossOver/Bottles")
}

func isCrossOverHelperPath(_ path: String) -> Bool {
    path.lowercased().contains("/applications/crossover/")
}

func isCrossOverPath(_ path: String) -> Bool {
    let p = path.lowercased()
    return p.contains("/crossover/bottles/") || isCrossOverHelperPath(path)
}

func listCrossOverBottleDirs(bottlesDir: String? = nil) -> [String] {
    guard let root = bottlesDir ?? defaultCrossOverBottlesDir() else { return [] }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
    var out: [String] = []
    for name in names where !name.hasPrefix(".") {
        let dir = (root as NSString).appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
        let conf = (dir as NSString).appendingPathComponent("cxbottle.conf")
        if FileManager.default.fileExists(atPath: conf) {
            out.append(dir)
        }
    }
    return out.sorted {
        URL(fileURLWithPath: $0).lastPathComponent.lowercased() < URL(fileURLWithPath: $1).lastPathComponent.lowercased()
    }
}

func findCrossOverBottles(bottlesDir: String? = nil) -> [AppRecord] {
    listCrossOverBottleDirs(bottlesDir: bottlesDir).map { dir in
        let name = URL(fileURLWithPath: dir).lastPathComponent
        var app = AppRecord(
            path: dir,
            displayName: name,
            bundleId: "crossover.\(norm(name))",
            sourceDir: "crossover",
            sizeBytes: 0,
            sizeMeasured: false
        )
        app.extra["crossover_bottle"] = "1"
        app.extra["crossover_name"] = name
        return app
    }
}

func crossoverSteamLibraryRoots(bottlesDir: String? = nil) -> [String] {
    var out: [String] = []
    for bottle in listCrossOverBottleDirs(bottlesDir: bottlesDir) {
        let driveC = (bottle as NSString).appendingPathComponent("drive_c")
        for rel in ["Program Files (x86)/Steam", "Program Files/Steam"] {
            let steam = (driveC as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: steam, isDirectory: &isDir), isDir.boolValue {
                out.append(steam)
            }
        }
    }
    return out
}

func crossoverBottleStamp(bottlesDir: String? = nil) -> String {
    let names = listCrossOverBottleDirs(bottlesDir: bottlesDir).map { URL(fileURLWithPath: $0).lastPathComponent }
    guard !names.isEmpty else { return "" }
    return "cx:\(stampJoin(names))"
}

func appendCrossOverBottles(_ apps: inout [AppRecord], seen: inout Set<String>, bottlesDir: String? = nil) {
    apps.removeAll { existing in
        let helper = isCrossOverHelperPath(existing.path)
            || (existing.bundleId?.lowercased().hasPrefix("com.codeweavers.crossoverhelper") ?? false)
        if helper { seen.remove(existing.path) }
        return helper
    }
    for app in findCrossOverBottles(bottlesDir: bottlesDir) {
        if seen.insert(app.path).inserted {
            apps.append(app)
        }
    }
}

func crossoverBottleBinary() -> String {
    let mac = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxbottle"
    if FileManager.default.isExecutableFile(atPath: mac) { return mac }
    return whichCommand("cxbottle") ?? "cxbottle"
}

func crossoverDeleteCommand(bottleName: String) -> String {
    let bin = shellQuote(crossoverBottleBinary())
    let name = shellQuote(bottleName)
    return "\(bin) --bottle \(name) --uninstall || true\n\(bin) --bottle \(name) --delete --force"
}
