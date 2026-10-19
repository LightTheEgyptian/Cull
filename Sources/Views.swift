import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Small state holders. (Plain @State is a compiler macro in newer SDKs that the
// Command Line Tools can't expand, so views keep their local state in these.)
final class DropState: ObservableObject { @Published var hover = false }
final class LoadedImages: ObservableObject {
    @Published var image: NSImage?
    @Published var full: NSImage?
    @Published var info: [String] = []
}
final class DragModel: ObservableObject { @Published var dx: CGFloat = 0 }

struct ContentView: View {
    @EnvironmentObject var store: Store
    @StateObject private var drop = DropState()

    var body: some View {
        ZStack {
            Color(white: 0.075).ignoresSafeArea()
            if store.folder == nil {
                EmptyStateView(hover: drop.hover)
            } else {
                VStack(spacing: 0) {
                    TopBar()
                    ViewerView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !store.comparing { Filmstrip().transition(.move(edge: .bottom).combined(with: .opacity)) }
                    KeyHints()
                }
            }
            if let t = store.toast {
                ToastView(toast: t)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 136)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(edges: .top)
        .onDrop(of: [.fileURL], isTargeted: $drop.hover) { store.handleDrop($0) }
        .sheet(isPresented: $store.showExport) { ExportSheet(settings: store.exportSettings).environmentObject(store) }
        .sheet(isPresented: $store.showShortcuts) { ShortcutsSheet().environmentObject(store) }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @EnvironmentObject var store: Store
    let hover: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.stack")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Drop a folder from a shoot")
                    .font(.system(size: 24, weight: .semibold))
                    .kerning(-0.4)
                Text("JPEG, HEIC and RAW. Cull checks focus and eyes on your Mac, then you keep or reject with one key.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Button("Choose Folder…") { store.openPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("Made by Nur Elmasri · Free and open source")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(56)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .foregroundStyle(hover ? Color.accentColor : Color.white.opacity(0.16))
        )
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: hover)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.folder?.lastPathComponent ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(store.count(.keepers)) keepers · \(store.count(.rejects)) rejects · \(store.count(.toReview)) to review")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 150, alignment: .leading)

            Spacer(minLength: 8)

            Picker("Show", selection: Binding(get: { store.filter }, set: { store.setFilter($0) })) {
                ForEach(Filter.allCases) { f in
                    Text("\(f.title) \(store.count(f))").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)

            Spacer(minLength: 8)

            if store.analyzing {
                Progress(text: "Checking \(store.analyzedCount) of \(store.photos.count)")
            }
            if store.exporting {
                Progress(text: "Exporting \(store.exportedCount) of \(store.exportTotal)")
            }
            if store.flaggedUnmarked > 0 {
                Button("Reject \(store.flaggedUnmarked) Flagged") { store.rejectFlagged() }
            }
            Button { store.showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export client-ready JPEGs")
                .disabled(store.exporting)
            Button {
                store.apply()
            } label: {
                Text(store.moveCount == 0 ? "Move" : "Move \(store.moveCount)").monospacedDigit()
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.moveCount == 0)
            .help("Keepers go into a Keepers folder and rejects into a Rejected folder, next to your photos. You can undo it.")
        }
        .padding(.leading, 86)
        .padding(.trailing, 16)
        .frame(height: 54)
        .background(.bar)
        .animation(store.spring, value: store.analyzing)
        .animation(store.spring, value: store.exporting)
    }
}

struct Progress: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }
}

// MARK: - Viewer

struct ViewerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var drag = DragModel()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if store.comparing {
                    CompareView().transition(.opacity)
                } else if let p = store.current {
                    PhotoView(photo: p, zoomed: store.zoomed, faceZoom: store.faceZoom, showInfo: store.showInfo)
                        .id(p.id)
                        .offset(x: drag.dx)
                        .transition(transition)
                        .gesture(swipe(width: geo.size.width),
                                 including: (store.zoomed || store.faceZoom) ? .subviews : .all)
                } else if !store.photos.isEmpty {
                    DoneView().transition(.opacity)
                }
                if let pulse = store.pulse {
                    PulseView(pulse: pulse)
                        .id(pulse.id)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .clipped()
    }

    // the next photo arrives from the side you're heading towards
    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        let d = store.direction
        return .asymmetric(insertion: .offset(x: 60 * d).combined(with: .opacity),
                           removal: .offset(x: -60 * d).combined(with: .opacity))
    }

    /// Drag the photo sideways: it follows the pointer 1:1, resists at the ends,
    /// and a flick is judged by where it would have landed, not where you let go.
    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                let t = v.translation.width
                let blocked = (t < 0 && !store.canStep(1)) || (t > 0 && !store.canStep(-1))
                drag.dx = blocked ? rubberband(t, width) : t
            }
            .onEnded { v in
                let projected = v.predictedEndTranslation.width
                let threshold = width * 0.22
                if projected < -threshold && store.canStep(1) {
                    drag.dx = 0
                    store.step(1)
                } else if projected > threshold && store.canStep(-1) {
                    drag.dx = 0
                    store.step(-1)
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { drag.dx = 0 }
                }
            }
    }

    private func rubberband(_ x: CGFloat, _ dim: CGFloat) -> CGFloat {
        let c: CGFloat = 0.55
        return (x * dim * c) / (dim + c * abs(x)) * 0.5
    }
}

struct PhotoView: View {
    let photo: Photo
    let zoomed: Bool
    let faceZoom: Bool
    let showInfo: Bool
    @StateObject private var images = LoadedImages()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if zoomed, let full = images.full {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: full)
                            .resizable()
                            .frame(width: full.size.width / 2, height: full.size.height / 2)
                    }
                    .defaultScrollAnchor(.center)
                } else if faceZoom, let box = photo.faceBox, let img = images.full ?? images.image {
                    FaceCrop(image: img, box: box)
                        .transition(.opacity)
                } else if let image = images.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .opacity(photo.mark == .reject ? 0.4 : 1)
            .saturation(photo.mark == .reject ? 0.4 : 1)

            HStack(spacing: 6) {
                if photo.mark != .none { MarkBadge(mark: photo.mark).transition(.scale(scale: 0.8).combined(with: .opacity)) }
                if photo.stars > 0 { StarsChip(stars: photo.stars).transition(.scale(scale: 0.8).combined(with: .opacity)) }
                if photo.hasRaw { Chip(text: "RAW", symbol: nil, color: .secondary) }
                if photo.burst != nil { Chip(text: "Burst", symbol: "square.stack.3d.down.right", color: .secondary) }
                if zoomed { Chip(text: "100%", symbol: "plus.magnifyingglass", color: .secondary) }
                if faceZoom { Chip(text: "Faces", symbol: "person.crop.square", color: .secondary) }
            }
            .padding(10)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(photo.flags.sorted(), id: \.self) { f in
                    Chip(text: f.title, symbol: f.symbol, color: f.color)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Spacer(minLength: 12)
                if showInfo && !images.info.isEmpty {
                    Text(images.info.joined(separator: "   "))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .task(id: photo.id) {
            // show whatever we already have instantly, then sharpen
            if let t = ImageCache.cached(photo.display, max: 2400, in: ImageCache.large) { images.image = t }
            else {
                if let t = ImageCache.cached(photo.display, max: 240, in: ImageCache.thumbs) { images.image = t }
                if let big = await ImageCache.load(photo.display, max: 2400, in: ImageCache.large) { images.image = big }
            }
            let url = photo.display
            images.info = await Task.detached(priority: .utility) { Metadata.summary(url) }.value
        }
        .task(id: zoomed || faceZoom) {
            guard zoomed || faceZoom, images.full == nil else { return }
            images.full = await ImageCache.load(photo.display, max: 0, in: ImageCache.large)
        }
    }
}

/// Frames the biggest face so you can check eyes and focus at a glance.
struct FaceCrop: View {
    let image: NSImage
    let box: CGRect

    var body: some View {
        GeometryReader { geo in
            let iw = image.size.width, ih = image.size.height
            let fw = box.width * iw * 2.2, fh = box.height * ih * 2.2
            let scale = min(geo.size.width / max(fw, 1), geo.size.height / max(fh, 1))
            let cx = box.midX * iw, cy = (1 - box.midY) * ih
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: iw * scale, height: ih * scale)
                .offset(x: geo.size.width / 2 - cx * scale, y: geo.size.height / 2 - cy * scale)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
        }
    }
}

struct Chip: View {
    let text: String
    let symbol: String?
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            Text(text).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct StarsChip: View {
    let stars: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < stars ? "star.fill" : "star")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(i < stars ? Color.yellow : Color.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct MarkBadge: View {
    let mark: Mark
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: mark == .keep ? "checkmark" : "xmark").font(.system(size: 10.5, weight: .bold))
            Text(mark == .keep ? "Keeper" : "Rejected").font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(mark == .keep ? Color.green : Color.red))
    }
}

/// The big symbol that confirms a key press, right where you're looking.
struct PulseView: View {
    let pulse: Pulse
    var body: some View {
        Image(systemName: pulse.symbol)
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 96, height: 96)
            .background(Circle().fill(pulse.tint.opacity(0.92)))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }
}

struct DoneView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.green)
            Text(store.filter == .toReview ? "Everything's reviewed" : "Nothing here")
                .font(.system(size: 20, weight: .semibold))
                .kerning(-0.3)
            Text("\(store.count(.keepers)) keepers and \(store.count(.rejects)) rejects are ready to move.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack {
                Button("Show All") { store.setFilter(.all) }
                Button("Export…") { store.showExport = true }
                Button("Move \(store.moveCount)") { store.apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.moveCount == 0)
            }
        }
    }
}

// MARK: - Compare

struct CompareView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let set = store.compareSet
        let cols = set.count <= 2 ? 2 : set.count <= 4 ? 2 : 3
        VStack(spacing: 10) {
            HStack {
                Text(set.first?.burst != nil ? "Burst of \(set.count)" : "Comparing \(set.count) photos")
                    .font(.system(size: 13, weight: .semibold))
                Text("Click a photo, then P to keep or X to reject. B keeps the best and rejects the rest.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { store.toggleCompare() }.keyboardShortcut(.cancelAction)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols), spacing: 10) {
                ForEach(set) { p in
                    CompareTile(photo: p, selected: p.id == store.currentID)
                        .onTapGesture { withAnimation(store.spring) { store.currentID = p.id } }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct CompareTile: View {
    let photo: Photo
    let selected: Bool
    @StateObject private var images = LoadedImages()

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04))
            if let img = images.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(photo.mark == .reject ? 0.4 : 1)
            }
            HStack(spacing: 5) {
                if photo.mark != .none { MarkBadge(mark: photo.mark) }
                if photo.stars > 0 { StarsChip(stars: photo.stars) }
                ForEach(photo.flags.sorted(), id: \.self) { f in
                    Image(systemName: f.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(f.color)
                        .padding(6).background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(8)
        }
        .aspectRatio(1.5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 3))
        .scaleEffect(selected ? 1 : 0.985)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: selected)
        .task(id: photo.id) {
            if let t = ImageCache.cached(photo.display, max: 2400, in: ImageCache.large) { images.image = t; return }
            images.image = await ImageCache.load(photo.display, max: 1200, in: ImageCache.large)
        }
    }
}

// MARK: - Filmstrip

struct Filmstrip: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(store.visible) { p in
                        Thumb(photo: p, selected: p.id == store.currentID)
                            .id(p.id)
                            .onTapGesture { store.select(p.id) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .onChange(of: store.currentID) { _, id in
                guard let id else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 1)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear { if let id = store.currentID { proxy.scrollTo(id, anchor: .center) } }
        }
        .frame(height: 104)
        .background(Color.black.opacity(0.32))
    }
}

struct Thumb: View {
    let photo: Photo
    let selected: Bool
    @StateObject private var images = LoadedImages()

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06))
                if let image = images.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 98, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(photo.mark == .reject ? 0.32 : 1)
            .overlay(alignment: .bottomTrailing) {
                if photo.mark != .none {
                    Image(systemName: photo.mark == .keep ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, photo.mark == .keep ? Color.green : Color.red)
                        .font(.system(size: 14))
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if photo.stars > 0 {
                    Text(String(repeating: "★", count: photo.stars))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if photo.mark == .none && photo.flags.contains(where: \.isProblem) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7).padding(5)
                } else if photo.flags.contains(.bestInBurst) {
                    Image(systemName: "star.circle.fill").font(.system(size: 11)).foregroundStyle(.yellow).padding(3)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: selected ? 2 : 0)
            )
            // bursts share a thin bar underneath, so you can see where a sequence starts and ends
            Capsule()
                .fill(photo.burst == nil ? Color.clear : Color.white.opacity(0.3))
                .frame(width: 104, height: 3)
        }
        .scaleEffect(selected ? 1.07 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: selected)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: photo.mark)
        .task(id: photo.id) {
            images.image = await ImageCache.load(photo.display, max: 240, in: ImageCache.thumbs)
        }
    }
}

// MARK: - Footer, toast and sheets

struct KeyHints: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 16) {
            hint("← →", "browse")
            hint("P", "keep")
            hint("X", "reject")
            hint("1–5", "stars")
            hint("B", "best of burst")
            hint("C", "compare")
            hint("F", "faces")
            hint("Z", "zoom")
            hint("I", "info")
            Button { store.showShortcuts = true } label: {
                Text("All shortcuts").font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.32))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
            Text(label).font(.system(size: 10.5))
        }
        .foregroundStyle(.secondary)
    }
}

struct ToastView: View {
    @EnvironmentObject var store: Store
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            switch toast.action {
            case .undoMove:
                Button("Undo") { store.undoMove() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            case .reveal(let url):
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: 600)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
    }
}

struct ExportSheet: View {
    @EnvironmentObject var store: Store
    @ObservedObject var settings: ExportSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export for clients").font(.system(size: 17, weight: .semibold))
                Text("Saves JPEGs into a new Export folder next to your photos. Your originals aren't changed, and location data is removed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                Picker("Photos", selection: $settings.which) {
                    Text("Keepers (\(store.count(.keepers)))").tag(ExportSettings.Which.keepers)
                    Text("Starred (\(store.count(.starred)))").tag(ExportSettings.Which.starred)
                    Text("What's shown now (\(store.visible.count))").tag(ExportSettings.Which.shown)
                }
                Picker("Size", selection: $settings.size) {
                    Text("Full size").tag(0)
                    Text("Large · 3000 px").tag(3000)
                    Text("Web · 2048 px").tag(2048)
                }
                Toggle("Add a watermark", isOn: $settings.watermark)
                if settings.watermark {
                    TextField("Watermark text", text: $settings.text)
                }
            }
            .formStyle(.grouped)
            .frame(height: settings.watermark ? 220 : 180)
            .animation(.spring(response: 0.3, dampingFraction: 1), value: settings.watermark)
            HStack {
                Spacer()
                Button("Cancel") { store.showExport = false }.keyboardShortcut(.cancelAction)
                Button("Export \(store.exportCandidates.count)") { store.export() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.exportCandidates.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

struct ShortcutsSheet: View {
    @EnvironmentObject var store: Store
    private let rows: [(String, String)] = [
        ("← →", "Previous / next photo (or drag the photo)"),
        ("P", "Keep"), ("X", "Reject"), ("U", "Clear mark and stars"),
        ("1 – 5", "Star rating (press again to remove)"),
        ("B", "Keep the best of this burst, reject the rest"),
        ("C", "Compare the burst side by side"),
        ("F", "Zoom to faces to check eyes"),
        ("Z", "Zoom to 100% to check focus"),
        ("I", "Show camera settings"),
        ("⌘Z", "Undo the last mark"),
        ("⌘1 – ⌘6", "All, To Review, Keepers, Rejects, Starred, Flagged"),
        ("⇧⌘R", "Reject all flagged photos"),
        ("⇧⌘E", "Export for clients"),
        ("⇧⌘M", "Move keepers and rejects into folders"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard shortcuts").font(.system(size: 17, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        Text(r.0)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                        Text(r.1).font(.system(size: 12.5))
                    }
                }
            }
            HStack { Spacer(); Button("Done") { store.showShortcuts = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 440)
    }
}
