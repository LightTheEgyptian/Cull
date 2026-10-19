import SwiftUI
import AppKit

enum Mark: String, Codable { case none, keep, reject }

enum Flag: String, Comparable, CaseIterable {
    case blurry, eyesClosed, bestInBurst, strong
    static func < (a: Flag, b: Flag) -> Bool { a.order < b.order }
    var order: Int { switch self { case .blurry: return 0; case .eyesClosed: return 1; case .bestInBurst: return 2; case .strong: return 3 } }
    var title: String {
        switch self {
        case .blurry: return "Out of focus"
        case .eyesClosed: return "Eyes may be closed"
        case .bestInBurst: return "Best in burst"
        case .strong: return "Strong shot"
        }
    }
    var symbol: String {
        switch self {
        case .blurry: return "camera.metering.unknown"
        case .eyesClosed: return "eye.slash"
        case .bestInBurst: return "star.circle"
        case .strong: return "sparkles"
        }
    }
    var color: Color { isProblem ? .orange : .yellow }
    var isProblem: Bool { self == .blurry || self == .eyesClosed }
}

enum Filter: String, CaseIterable, Identifiable, Hashable {
    case all, toReview, keepers, rejects, starred, flagged
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"; case .toReview: return "To Review"; case .keepers: return "Keepers"
        case .rejects: return "Rejects"; case .starred: return "Starred"; case .flagged: return "Flagged"
        }
    }
    func matches(_ p: Photo) -> Bool {
        switch self {
        case .all: return true
        case .toReview: return p.mark == .none
        case .keepers: return p.mark == .keep
        case .rejects: return p.mark == .reject
        case .starred: return p.stars > 0
        case .flagged: return p.flags.contains(where: \.isProblem)
        }
    }
}

struct Photo: Identifiable, Hashable {
    let id: String            // file name without extension, shared by RAW + JPEG pairs
    let display: URL          // the file we show
    var files: [URL]          // every file that moves with it (RAW, JPEG, XMP…)
    var mark: Mark = .none
    var stars = 0
    var flags: Set<Flag> = []
    var sharpness: Double?
    var eyesClosed = false
    var aesthetic: Double?
    var faceBox: CGRect?
    var captureDate: Date?
    var burst: Int?           // photos taken within 2 seconds of each other share a burst number
    var analyzed = false
    var raw: URL? { files.first { Store.rawExts.contains($0.pathExtension.lowercased()) } }
    var hasRaw: Bool { raw != nil }
}

struct Pulse: Equatable { let symbol: String; let tint: Color; let id = UUID() }

struct Toast: Equatable {
    enum Action: Equatable { case none, undoMove, reveal(URL) }
    let text: String
    let action: Action
    let id = UUID()
}

final class ExportSettings: ObservableObject {
    enum Which: String, CaseIterable { case keepers, shown, starred }
    @Published var size: Int { didSet { UserDefaults.standard.set(size, forKey: "export.size") } }
    @Published var watermark: Bool { didSet { UserDefaults.standard.set(watermark, forKey: "export.watermark") } }
    @Published var text: String { didSet { UserDefaults.standard.set(text, forKey: "export.text") } }
    @Published var which: Which = .keepers
    init() {
        let d = UserDefaults.standard
        size = d.object(forKey: "export.size") as? Int ?? 3000
        watermark = d.object(forKey: "export.watermark") as? Bool ?? false
        text = d.string(forKey: "export.text") ?? "Núr Photography"
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp",
                                         "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw"]
    static let rawExts: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw"]

    @Published var folder: URL?
    @Published var photos: [Photo] = []
    @Published var currentID: String?
    @Published private(set) var filter: Filter = .all
    @Published var direction: CGFloat = 1
    @Published var zoomed = false
    @Published var faceZoom = false
    @Published var showInfo = false
    @Published var comparing = false
    @Published var autoAdvance = true
    @Published var writeXMP: Bool { didSet { UserDefaults.standard.set(writeXMP, forKey: "writeXMP") } }
    @Published var analyzing = false
    @Published var analyzedCount = 0
    @Published var pulse: Pulse?
    @Published var toast: Toast?
    @Published var showExport = false
    @Published var showShortcuts = false
    @Published var exporting = false
    @Published var exportedCount = 0
    @Published var exportTotal = 0
    let exportSettings = ExportSettings()

    private var undoSnapshot: (photos: [Photo], moves: [(from: URL, to: URL)])?
    private var undoStack: [[(id: String, mark: Mark, stars: Int)]] = []
    private var analysisTask: Task<Void, Never>?
    var canUndoMove: Bool { undoSnapshot != nil }
    var canUndo: Bool { !undoStack.isEmpty }

    init() {
        writeXMP = UserDefaults.standard.object(forKey: "writeXMP") as? Bool ?? true
    }

    var spring: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1)
    }

    // MARK: derived

    var visible: [Photo] { photos.filter(filter.matches) }
    var current: Photo? { photos.first { $0.id == currentID } }
    func count(_ f: Filter) -> Int { photos.filter(f.matches).count }
    var flaggedUnmarked: Int { photos.filter { $0.mark == .none && $0.flags.contains(where: \.isProblem) }.count }
    var moveCount: Int { photos.filter { $0.mark != .none }.count }

    func burstMembers(of p: Photo) -> [Photo] {
        guard let b = p.burst else { return [p] }
        return photos.filter { $0.burst == b }
    }

    /// The photos shown side by side in Compare: the current burst, or the current photo and the next few.
    var compareSet: [Photo] {
        guard let c = current else { return [] }
        let burst = burstMembers(of: c)
        if burst.count > 1 { return Array(burst.prefix(9)) }
        let ids = visible.map(\.id)
        guard let i = ids.firstIndex(of: c.id) else { return [c] }
        return ids[i..<min(i + 4, ids.count)].compactMap { id in photos.first { $0.id == id } }
    }

    // MARK: opening

    func openPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Cull This Folder"
        p.message = "Choose a folder of photos from a shoot."
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in Store.shared.open(url) }
        }
        return true
    }

    func open(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        let pick = isDir.boolValue ? nil : url.deletingPathExtension().lastPathComponent

        analysisTask?.cancel()
        folder = dir
        photos = Self.scan(dir)
        let saved = loadSaved()
        for i in photos.indices {
            if let s = saved[photos[i].id] { photos[i].mark = s.mark; photos[i].stars = s.stars }
        }
        filter = .all
        undoSnapshot = nil
        undoStack = []
        zoomed = false; faceZoom = false; comparing = false
        currentID = pick.flatMap { id in photos.first { $0.id == id }?.id } ?? photos.first?.id
        NSDocumentController.shared.noteNewRecentDocumentURL(dir)
        loadDates()
        analyze()
        preload()
        if photos.isEmpty { showToast("No photos in “\(dir.lastPathComponent)”. Cull reads JPEG, HEIC, PNG, TIFF and RAW files.") }
    }

    static func scan(_ dir: URL) -> [Photo] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        var groups: [String: [URL]] = [:]
        for u in urls { groups[u.deletingPathExtension().lastPathComponent, default: []].append(u) }
        var out: [Photo] = []
        for (base, files) in groups {
            let images = files.filter { imageExts.contains($0.pathExtension.lowercased()) }
            guard !images.isEmpty else { continue }
            let display = images.first { !rawExts.contains($0.pathExtension.lowercased()) } ?? images[0]
            out.append(Photo(id: base, display: display, files: files))
        }
        return out.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// Reads capture times, then groups shots taken within 2 seconds of each other into bursts.
    private func loadDates() {
        let items = photos.map { ($0.id, $0.display) }
        Task {
            let dates = await Task.detached(priority: .utility) {
                items.map { ($0.0, Metadata.captureDate($0.1)) }
            }.value
            var byID: [String: Date] = [:]
            for (id, d) in dates { if let d { byID[id] = d } }
            var burst = 0
            var lastDate: Date?
            var runStart = 0
            for i in photos.indices {
                photos[i].captureDate = byID[photos[i].id]
                let d = photos[i].captureDate
                if let d, let l = lastDate, abs(d.timeIntervalSince(l)) <= 2.0 {
                    if photos[runStart].burst == nil { burst += 1; photos[runStart].burst = burst }
                    photos[i].burst = photos[runStart].burst
                } else {
                    runStart = i
                }
                lastDate = d
            }
            recomputeFlags()
        }
    }

    // MARK: browsing

    func setFilter(_ f: Filter) {
        withAnimation(spring) {
            filter = f
            let ids = visible.map(\.id)
            if let c = currentID, ids.contains(c) { return }
            currentID = ids.first
        }
        preload()
    }

    func select(_ id: String) {
        let ids = visible.map(\.id)
        if let a = ids.firstIndex(of: currentID ?? ""), let b = ids.firstIndex(of: id) { direction = b >= a ? 1 : -1 }
        withAnimation(spring) { currentID = id }
        preload()
    }

    func canStep(_ delta: Int) -> Bool {
        let ids = comparing ? compareSet.map(\.id) : visible.map(\.id)
        guard let i = ids.firstIndex(of: currentID ?? "") else { return false }
        return i + delta >= 0 && i + delta < ids.count
    }

    func step(_ delta: Int) {
        let ids = comparing ? compareSet.map(\.id) : visible.map(\.id)
        guard !ids.isEmpty else { return }
        let i = ids.firstIndex(of: currentID ?? "") ?? 0
        let j = min(max(i + delta, 0), ids.count - 1)
        guard j != i else { return }
        direction = delta > 0 ? 1 : -1
        zoomed = false
        withAnimation(spring) { currentID = ids[j] }
        preload()
    }

    func toggleZoom() { if current != nil { faceZoom = false; zoomed.toggle() } }

    func toggleFaceZoom() {
        guard let c = current else { return }
        if c.faceBox == nil {
            showToast(c.analyzed ? "No faces found in this photo." : "Still checking this photo. Try again in a moment.")
            return
        }
        zoomed = false
        withAnimation(spring) { faceZoom.toggle() }
    }

    func toggleInfo() { withAnimation(spring) { showInfo.toggle() } }

    func toggleCompare() {
        guard current != nil else { return }
        withAnimation(spring) { comparing.toggle(); zoomed = false; faceZoom = false }
    }

    private func preload() {
        let ids = visible.map(\.id)
        guard let c = currentID, let i = ids.firstIndex(of: c) else { return }
        for d in [1, -1, 2] {
            let j = i + d
            guard j >= 0, j < ids.count, let p = photos.first(where: { $0.id == ids[j] }) else { continue }
            Task { _ = await ImageCache.load(p.display, max: 2400, in: ImageCache.large) }
        }
    }

    // MARK: marking, stars and undo

    private func remember(_ ids: [String]) {
        let entry = ids.compactMap { id in photos.first { $0.id == id }.map { (id: id, mark: $0.mark, stars: $0.stars) } }
        undoStack.append(entry)
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        withAnimation(spring) {
            for e in last {
                guard let i = photos.firstIndex(where: { $0.id == e.id }) else { continue }
                photos[i].mark = e.mark
                photos[i].stars = e.stars
                syncXMP(i)
            }
            if let first = last.first, photos.contains(where: { $0.id == first.id }) { currentID = first.id }
        }
        flash("arrow.uturn.backward", .gray)
        saveAll()
    }

    func mark(_ m: Mark) {
        guard let id = currentID, let i = photos.firstIndex(where: { $0.id == id }) else { return }
        remember([id])
        let before = (comparing ? compareSet : visible).map(\.id)
        let pos = before.firstIndex(of: id) ?? 0
        let newMark: Mark = photos[i].mark == m ? .none : m
        withAnimation(spring) { photos[i].mark = newMark }
        flash(newMark == .keep ? "checkmark" : newMark == .reject ? "xmark" : "arrow.uturn.backward",
              newMark == .keep ? .green : newMark == .reject ? .red : .gray)
        syncXMP(i)
        saveAll()
        guard autoAdvance, newMark != .none, !comparing else { return }
        let after = visible.map(\.id)
        var next: String?
        if after.contains(id) { next = pos + 1 < after.count ? after[pos + 1] : nil }
        else if !after.isEmpty { next = after[min(pos, after.count - 1)] }
        else { withAnimation(spring) { currentID = nil }; return }
        if let n = next {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.currentID == id else { return }
                self.direction = 1
                self.zoomed = false
                withAnimation(self.spring) { self.currentID = n }
                self.preload()
            }
        }
    }

    func clearMark() {
        guard let id = currentID, let i = photos.firstIndex(where: { $0.id == id }),
              photos[i].mark != .none || photos[i].stars != 0 else { return }
        remember([id])
        withAnimation(spring) { photos[i].mark = .none; photos[i].stars = 0 }
        flash("arrow.uturn.backward", .gray)
        syncXMP(i)
        saveAll()
    }

    func rate(_ stars: Int) {
        guard let id = currentID, let i = photos.firstIndex(where: { $0.id == id }) else { return }
        remember([id])
        let value = photos[i].stars == stars ? 0 : stars
        withAnimation(spring) {
            photos[i].stars = value
            if value > 0 && photos[i].mark == .reject { photos[i].mark = .none }
        }
        flash(value == 0 ? "star.slash" : "\(value).circle.fill", .yellow)
        syncXMP(i)
        saveAll()
    }

    /// Keeps the best shot of the current burst and rejects the rest.
    func keepBestOfBurst() {
        guard let c = current else { return }
        let members = burstMembers(of: c)
        guard members.count > 1 else { showToast("This photo isn't part of a burst."); return }
        guard let best = members.first(where: { $0.flags.contains(.bestInBurst) }) ?? members.max(by: { score($0) < score($1) }) else { return }
        remember(members.map(\.id))
        withAnimation(spring) {
            for m in members {
                guard let i = photos.firstIndex(where: { $0.id == m.id }) else { continue }
                photos[i].mark = m.id == best.id ? .keep : .reject
                syncXMP(i)
            }
            currentID = best.id
        }
        flash("star.circle.fill", .yellow)
        saveAll()
        showToast("Kept \(best.id) and rejected the other \(members.count - 1) in this burst. ⌘Z to undo.")
    }

    private func flash(_ symbol: String, _ tint: Color) {
        let p = Pulse(symbol: symbol, tint: tint)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) { pulse = p }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.pulse == p else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.pulse = nil }
        }
    }

    func rejectFlagged() {
        let ids = photos.filter { $0.mark == .none && $0.flags.contains(where: \.isProblem) }.map(\.id)
        guard !ids.isEmpty else { showToast("No flagged photos to reject."); return }
        remember(ids)
        withAnimation(spring) {
            for i in photos.indices where ids.contains(photos[i].id) {
                photos[i].mark = .reject
                syncXMP(i)
            }
        }
        saveAll()
        showToast("Marked \(ids.count) flagged photo\(ids.count == 1 ? "" : "s") as rejects. ⌘Z to undo.")
    }

    /// Lightroom reads ratings from XMP sidecars next to RAW files; a reject is rating -1.
    private func syncXMP(_ i: Int) {
        guard writeXMP, let raw = photos[i].raw else { return }
        let rating = photos[i].mark == .reject ? -1 : photos[i].stars
        let hasSidecar = photos[i].files.contains { $0.pathExtension.lowercased() == "xmp" }
        if rating == 0 && !hasSidecar { return }
        if let url = XMP.write(rating: rating, beside: raw), !photos[i].files.contains(url) {
            photos[i].files.append(url)
        }
    }

    // MARK: moving files

    func apply() {
        guard let folder else { return }
        let keep = photos.filter { $0.mark == .keep }, rej = photos.filter { $0.mark == .reject }
        guard !keep.isEmpty || !rej.isEmpty else { showToast("Mark some photos first: P keeps, X rejects."); return }
        let snapshot = photos
        let fm = FileManager.default
        var moves: [(from: URL, to: URL)] = []
        var failed = 0
        for (group, name) in [(keep, "Keepers"), (rej, "Rejected")] where !group.isEmpty {
            let dir = folder.appendingPathComponent(name)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for p in group {
                for f in p.files {
                    var dst = dir.appendingPathComponent(f.lastPathComponent)
                    var n = 2
                    while fm.fileExists(atPath: dst.path) {
                        dst = dir.appendingPathComponent("\(f.deletingPathExtension().lastPathComponent) \(n).\(f.pathExtension)")
                        n += 1
                    }
                    do { try fm.moveItem(at: f, to: dst); moves.append((f, dst)) } catch { failed += 1 }
                }
            }
        }
        undoSnapshot = (snapshot, moves)
        undoStack = []
        let moved = Set(keep.map(\.id) + rej.map(\.id))
        withAnimation(spring) {
            photos.removeAll { moved.contains($0.id) }
            comparing = false
            if let c = currentID, moved.contains(c) { currentID = visible.first?.id }
        }
        saveAll(extra: snapshot.filter { moved.contains($0.id) })
        var text = "Moved \(keep.count) to Keepers and \(rej.count) to Rejected"
        if failed > 0 { text += " · \(failed) file\(failed == 1 ? "" : "s") couldn't be moved" }
        showToast(text, action: .undoMove)
    }

    func undoMove() {
        guard let snap = undoSnapshot else { return }
        let fm = FileManager.default
        for m in snap.moves.reversed() { try? fm.moveItem(at: m.to, to: m.from) }
        if let folder {
            for name in ["Keepers", "Rejected"] {
                let d = folder.appendingPathComponent(name)
                if (try? fm.contentsOfDirectory(atPath: d.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
                    try? fm.removeItem(at: d)
                }
            }
        }
        undoSnapshot = nil
        withAnimation(spring) {
            photos = snap.photos
            if currentID == nil { currentID = visible.first?.id }
        }
        saveAll()
        showToast("Put everything back.")
    }

    // MARK: export

    var exportCandidates: [Photo] {
        switch exportSettings.which {
        case .keepers: return photos.filter { $0.mark == .keep }
        case .shown: return visible
        case .starred: return photos.filter { $0.stars > 0 }
        }
    }

    func export() {
        guard let folder else { return }
        let items = exportCandidates.map(\.display)
        guard !items.isEmpty else { showToast("Nothing to export yet."); return }
        let s = exportSettings
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let dir = folder.appendingPathComponent("Export \(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = s.size, mark = s.watermark ? s.text : nil
        showExport = false
        exporting = true
        exportedCount = 0
        exportTotal = items.count
        Task {
            var ok = 0
            var start = 0
            while start < items.count {
                let chunk = Array(items[start..<min(start + 3, items.count)])
                start += 3
                let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
                    for u in chunk { group.addTask(priority: .userInitiated) { Exporter.export(u, into: dir, maxPixel: size, watermark: mark) } }
                    var out: [Bool] = []
                    for await r in group { out.append(r) }
                    return out
                }
                ok += results.filter { $0 }.count
                exportedCount += chunk.count
            }
            exporting = false
            let failed = items.count - ok
            showToast("Exported \(ok) photo\(ok == 1 ? "" : "s")\(failed > 0 ? " · \(failed) failed" : "")", action: .reveal(dir))
        }
    }

    // MARK: saved marks (a small hidden file in the folder, so you can stop and come back)

    private struct Saved: Codable { var m: String?; var s: Int? }
    private var sidecar: URL? { folder?.appendingPathComponent(".cull.json") }

    private func loadSaved() -> [String: (mark: Mark, stars: Int)] {
        guard let url = sidecar, let d = try? Data(contentsOf: url) else { return [:] }
        if let new = try? JSONDecoder().decode([String: Saved].self, from: d) {
            return new.mapValues { (Mark(rawValue: $0.m ?? "") ?? .none, $0.s ?? 0) }
        }
        if let old = try? JSONDecoder().decode([String: String].self, from: d) {
            return old.mapValues { (Mark(rawValue: $0) ?? .none, 0) }
        }
        return [:]
    }

    private func saveAll(extra: [Photo] = []) {
        guard let url = sidecar else { return }
        var d: [String: Saved] = [:]
        for p in extra + photos where p.mark != .none || p.stars > 0 {
            d[p.id] = Saved(m: p.mark == .none ? nil : p.mark.rawValue, s: p.stars > 0 ? p.stars : nil)
        }
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: url) }
    }

    // MARK: toast

    func showToast(_ text: String, action: Toast.Action = .none) {
        let t = Toast(text: text, action: action)
        withAnimation(spring) { toast = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == .none ? 4.5 : 8)) { [weak self] in
            guard let self, self.toast == t else { return }
            withAnimation(self.spring) { self.toast = nil }
        }
    }

    // MARK: analysis

    func analyze() {
        analysisTask?.cancel()
        let items = photos.filter { !$0.analyzed }.map { ($0.id, $0.display) }
        analyzedCount = photos.count - items.count
        guard !items.isEmpty else { analyzing = false; return }
        analyzing = true
        analysisTask = Task { [weak self] in
            var start = 0
            while start < items.count {
                if Task.isCancelled { return }
                let chunk = Array(items[start..<min(start + 4, items.count)])
                start += 4
                let results = await withTaskGroup(of: (String, Analyzer.Result?).self) { group -> [(String, Analyzer.Result?)] in
                    for (id, url) in chunk { group.addTask(priority: .utility) { (id, Analyzer.analyze(url)) } }
                    var out: [(String, Analyzer.Result?)] = []
                    for await r in group { out.append(r) }
                    return out
                }
                guard let self, !Task.isCancelled else { return }
                for (id, r) in results {
                    guard let i = self.photos.firstIndex(where: { $0.id == id }) else { continue }
                    self.photos[i].analyzed = true
                    if let r {
                        self.photos[i].sharpness = r.sharpness
                        self.photos[i].eyesClosed = r.eyesClosed
                        self.photos[i].aesthetic = r.aesthetic
                        self.photos[i].faceBox = r.faceBox
                    }
                    self.analyzedCount += 1
                }
                if start % 16 == 0 || start >= items.count { self.recomputeFlags() }
            }
            self?.recomputeFlags()
            self?.analyzing = false
        }
    }

    private var sharpRef: Double {
        let sharp = photos.compactMap(\.sharpness).sorted()
        return sharp.isEmpty ? 1 : max(sharp[Int(Double(sharp.count - 1) * 0.7)], 1)
    }

    /// Higher is better: sharp, well composed, eyes open.
    private func score(_ p: Photo) -> Double {
        let s = min((p.sharpness ?? 0) / sharpRef, 1.5)
        return s + (p.aesthetic ?? 0) - (p.eyesClosed ? 1 : 0)
    }

    /// Focus is judged against the rest of the shoot, so a dim indoor set isn't all marked blurry.
    private func recomputeFlags() {
        let count = photos.compactMap(\.sharpness).count
        let ref = sharpRef
        let aes = photos.compactMap(\.aesthetic).sorted()
        let topCut = aes.count >= 5 ? aes[Int(Double(aes.count - 1) * 0.85)] : .infinity
        var bestByBurst: [Int: (String, Double)] = [:]
        for p in photos where p.analyzed {
            guard let b = p.burst else { continue }
            let sc = score(p)
            if bestByBurst[b] == nil || sc > bestByBurst[b]!.1 { bestByBurst[b] = (p.id, sc) }
        }
        withAnimation(spring) {
            for i in photos.indices {
                var f = Set<Flag>()
                if let s = photos[i].sharpness, s < 10 || (count >= 4 && s < ref * 0.22) { f.insert(.blurry) }
                if photos[i].eyesClosed { f.insert(.eyesClosed) }
                if let b = photos[i].burst, bestByBurst[b]?.0 == photos[i].id, f.isEmpty { f.insert(.bestInBurst) }
                if f.isEmpty, let a = photos[i].aesthetic, a >= topCut, a > 0 { f.insert(.strong) }
                if photos[i].flags != f { photos[i].flags = f }
            }
        }
    }
}
