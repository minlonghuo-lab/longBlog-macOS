import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVKit
import AVFoundation
import Quartz
import PDFKit
import ImageIO

struct MemosWorkspace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: MemosModel
    @ObservedObject private var app = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                timelineColumn
                    .frame(minWidth: 270, idealWidth: 320, maxWidth: 375)
                Group {
                    if model.editing {
                        MemoEditorView(model: model)
                    } else {
                        EmptyWorkspace(
                            symbol: "text.bubble",
                            title: "记录此刻",
                            detail: "从左侧选择一条说说编辑，或点击右上角“写说说”（⌘⇧N）。\n支持 Markdown 语法、可见性控制与图片附件拖入。",
                            actionTitle: "写一条说说  ⌘⇧N",
                            action: { app.newMemo() }
                        )
                    }
                }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.blogBackground)
                .overlay(alignment: .bottom) { OperationStatus(model: model).padding(.bottom, 16) }
            }
        }
        .sheet(item: $model.previewAttachment) { attachment in
            MemoAttachmentPreview(attachment: attachment)
        }
    }

    private var timelineColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BlogSegmentedControl(
                    title: "说说列表",
                    options: [
                        SegmentedOption(value: false, label: "时间线"),
                        SegmentedOption(value: true, label: "已归档")
                    ],
                    selection: Binding(get: { model.archived }, set: { model.setArchived($0) }),
                    compact: true
                )
                if model.loaded {
                    Text("\(model.items.count)\(model.more ? "+" : "")")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.blogMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.blogSlot, in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            HairlineDivider()

            ZStack {
                if model.filtered.isEmpty {
                    EmptyWorkspace(
                        symbol: "quote.bubble",
                        title: model.search.isEmpty ? "暂无说说" : "没有匹配的说说",
                        detail: model.search.isEmpty
                            ? "连接并验证 legacy Memos 账户后即可浏览与发布说说。"
                            : "换个搜索词试试。",
                        settings: !model.errors.isEmpty
                    )
                    .id("empty-\(model.archived)")
                    .transition(.opacity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 9) {
                            ForEach(model.filtered) { row in
                                memoCell(row)
                            }
                            if model.more {
                                Button("加载更多") { model.load(more: true) }
                                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                                    .disabled(model.busy)
                                    .padding(.vertical, 8)
                            }
                        }
                        .padding(14)
                    }
                    .id("list-\(model.archived)")
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.archived)

            HairlineDivider()

            HStack(spacing: 8) {
                Image(systemName: model.username.isEmpty ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
                    .foregroundStyle(model.username.isEmpty ? Color.blogMuted : Color.blogPeach)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.username.isEmpty ? "尚未验证账户" : "@\(model.username)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.blogSecondary)
                        .lineLimit(1)
                    if model.cacheTotal > 0 {
                        Text(model.cacheRunning
                             ? "正在本地缓存附件 \(model.cacheCompleted)/\(model.cacheTotal)…"
                             : "本地附件 \(model.cacheCompleted)/\(model.cacheTotal)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Color.blogMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button("验证 / 刷新") { model.refresh() }
                    .buttonStyle(.plain)
                    .pointingHandCursor(!model.busy)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.blogPeach)
                    .disabled(model.busy)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func memoCell(_ row: DataRow) -> some View {
        let selected = model.selectedID == row.id
        let resources = row.data["resourceList"] as? [[String: Any]] ?? []
        let hasImage = resources.contains { MemoMediaKind.detect($0) == .image }
        let vis = row.text("visibility")

        return Button { model.select(row) } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Warm peach timestamp matching chosen-memos.png
                HStack(spacing: 6) {
                    Text(shortDateTimeLabel(row.number("displayTs"), milliseconds: false))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.blogPeach)
                    Spacer()
                    if model.selectedID == row.id && model.isDirty {
                        Circle().fill(Color.blogPeach).frame(width: 6.5, height: 6.5)
                    }
                }

                if !row.text("content").isEmpty {
                    Text(row.text("content"))
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundStyle(Color.blogText)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Compact solid thumbnail strip for attachments (max 3 previews)
                if !resources.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(resources.prefix(3).enumerated()), id: \.offset) { _, res in
                            MemoTimelineThumb(model: model, resource: res)
                        }
                        if resources.count > 3 {
                            Text("+\(resources.count - 3)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.blogSecondary)
                                .frame(width: 44, height: 44)
                                .background(Color.blogSlot, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.blogStroke))
                        }
                    }
                }

                HStack(spacing: 6) {
                    if row.flag("pinned") {
                        StatusBadge(text: "置顶", color: .blogPeach)
                    }
                    StatusBadge(
                        text: visibilityName(vis),
                        color: vis == "PUBLIC" ? .blogTeal : (vis == "PROTECTED" ? .blogAmber : .blogMuted)
                    )
                    if hasImage {
                        StatusBadge(text: resources.count > 1 ? "媒体 \(resources.count)" : "图片", color: .blogMuted, symbol: "photo")
                    } else if !resources.isEmpty {
                        StatusBadge(text: "附件 \(resources.count)", color: .blogMuted, symbol: "paperclip")
                    }
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle(selected: selected))
        .accessibilityLabel("说说：\(String(row.text("content").prefix(60)))")
        .accessibilityValue([row.flag("pinned") ? "置顶" : nil, visibilityName(vis), selected && model.isDirty ? "未保存" : nil].compactMap { $0 }.joined(separator: "，"))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button("编辑说说") { model.select(row) }
            if !row.text("content").isEmpty {
                Button("拷贝正文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.text("content"), forType: .string)
                    model.flash("copy", "已复制说说正文")
                }
            }
            Divider()
            if model.archived {
                Button("恢复说说…") { model.update(["rowStatus": "NORMAL"], title: "恢复说说", target: row.data) }
                Divider()
                Button("永久删除…", role: .destructive) {
                    model.deleteArchived(row.data)
                }
            } else {
                let pinned = row.flag("pinned")
                Button(pinned ? "取消置顶…" : "置顶说说…") {
                    model.update(["pinned": !pinned], title: pinned ? "取消置顶" : "置顶说说", target: row.data)
                }
                Button("归档说说…") {
                    model.update(["rowStatus": "ARCHIVED"], title: "归档说说", target: row.data)
                }
            }
        }
    }
}

private func visibilityName(_ value: String) -> String {
    switch value {
    case "PUBLIC": return "公开"
    case "PROTECTED": return "登录可见"
    default: return "仅自己"
    }
}

// MARK: - Media Kind & Thumbnail Cache

private enum MemoMediaKind {
    case image, video, audio, pdf, file

    static func detect(_ resource: [String: Any]) -> MemoMediaKind {
        let mime = (resource["type"] as? String ?? "").lowercased()
        let name = ((resource["filename"] as? String) ?? (resource["name"] as? String) ?? "").lowercased()
        return detect(mime: mime, ext: (name as NSString).pathExtension)
    }

    static func detect(mime: String, ext: String) -> MemoMediaKind {
        let type = UTType(filenameExtension: ext)
        if mime.hasPrefix("image/") || type?.conforms(to: .image) == true { return .image }
        if mime.hasPrefix("video/") || type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { return .video }
        if mime.hasPrefix("audio/") || type?.conforms(to: .audio) == true { return .audio }
        if mime == "application/pdf" || ext == "pdf" || type?.conforms(to: .pdf) == true { return .pdf }
        return .file
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .file: return "doc.fill"
        }
    }

    var label: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .pdf: return "PDF"
        case .file: return "文件"
        }
    }
}

private final class MemoThumbnailStore {
    static let shared = MemoThumbnailStore()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.longblog.mac.memo-thumbs", qos: .userInitiated)

    private init() {
        cache.countLimit = 240
    }

    func cached(url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: "\(url.path)#\(maxPixel)" as NSString)
    }

    func load(url: URL, kind: MemoMediaKind, maxPixel: Int, completion: @escaping (NSImage?) -> Void) {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) {
            completion(hit)
            return
        }
        queue.async { [weak self] in
            let image: NSImage?
            switch kind {
            case .image:
                image = Self.decodeImage(url: url, maxPixel: maxPixel)
            case .video:
                image = Self.decodeVideoFrame(url: url, maxPixel: maxPixel)
            case .pdf:
                image = Self.decodePDFPage(url: url, maxPixel: maxPixel)
            case .audio, .file:
                image = nil
            }
            if let image {
                self?.cache.setObject(image, forKey: key)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private static func decodeImage(url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func decodeVideoFrame(url: URL, maxPixel: Int) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func decodePDFPage(url: URL, maxPixel: Int) -> NSImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        return page.thumbnail(of: NSSize(width: maxPixel, height: maxPixel), for: .mediaBox)
    }
}

private func formatByteSize(_ raw: Any?) -> String? {
    guard let bytes = (raw as? NSNumber)?.int64Value, bytes > 0 else { return nil }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - Solid Timeline Mini Thumbnail

private struct MemoTimelineThumb: View {
    @ObservedObject var model: MemosModel
    let resource: [String: Any]
    @State private var thumbnail: NSImage?

    private var key: String { model.resourceKey(resource) }
    private var kind: MemoMediaKind { MemoMediaKind.detect(resource) }
    private var localURL: URL? { model.localResourceURLs[key] }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blogEditor)

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipped()
                if kind == .video {
                    Circle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        )
                }
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.blogPeach.opacity(0.85))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.blogStroke))
        .onAppear {
            model.resolveCachedURL(for: resource, downloadIfMissing: true)
            refreshThumb()
        }
        .onChange(of: localURL) { _, _ in refreshThumb() }
        .onChange(of: model.cacheVersion) { _, _ in
            model.resolveCachedURL(for: resource, downloadIfMissing: false)
            refreshThumb()
        }
    }

    private func refreshThumb() {
        guard let url = localURL, kind == .image || kind == .video || kind == .pdf else { return }
        if let hit = MemoThumbnailStore.shared.cached(url: url, maxPixel: 120) {
            thumbnail = hit
            return
        }
        MemoThumbnailStore.shared.load(url: url, kind: kind, maxPixel: 120) { image in
            if self.localURL == url { self.thumbnail = image }
        }
    }
}

// MARK: - Detail Attachment Card (Solid Surface + Preview Thumbnail)

private struct MemoAttachmentCard: View {
    @ObservedObject var model: MemosModel
    let resource: [String: Any]
    let canRemove: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private var key: String { model.resourceKey(resource) }
    private var kind: MemoMediaKind { MemoMediaKind.detect(resource) }
    private var localURL: URL? { model.localResourceURLs[key] }
    private var loading: Bool { model.loadingResourceKeys.contains(key) }
    private var filename: String { (resource["filename"] as? String) ?? (resource["name"] as? String) ?? "附件" }
    private var sizeLabel: String? { formatByteSize(resource["size"]) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    // Solid visual preview well
                    ZStack {
                        Color.blogEditor

                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: kind == .pdf ? .fit : .fill)
                                .frame(width: 136, height: 82)
                                .clipped()
                            if kind == .video {
                                Circle()
                                    .fill(Color.black.opacity(0.60))
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white)
                                            .offset(x: 1)
                                    )
                            }
                        } else if let localURL, kind == .file {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: localURL.path))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 38, height: 38)
                        } else {
                            VStack(spacing: 4) {
                                if loading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: kind.symbol)
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(Color.blogPeach)
                                }
                                Text(loading ? "缓存中…" : kind.label)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Color.blogMuted)
                            }
                        }
                    }
                    .frame(width: 136, height: 82)
                    .clipped()

                    // Solid warm caption strip
                    VStack(alignment: .leading, spacing: 2) {
                        Text(filename)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.blogText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 4) {
                            Text(kind.label)
                            if let sizeLabel {
                                Text("· \(sizeLabel)")
                            }
                            Spacer(minLength: 0)
                            if localURL != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Color.blogGreen.opacity(0.85))
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color.blogMuted)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(width: 136, alignment: .leading)
                    .background(hovering ? Color.blogSurfaceHover : Color.blogSurface)
                }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(hovering ? Color.blogPeach.opacity(0.5) : Color.blogStroke)
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("点击预览或播放：\(filename)")

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .padding(5)
                .accessibilityLabel("移除附件关联，不删除服务端文件")
            }
        }
        .onHover { hovering = $0 }
        .onAppear {
            model.resolveCachedURL(for: resource, downloadIfMissing: true)
            refreshThumb()
        }
        .onChange(of: localURL) { _, _ in refreshThumb() }
        .onChange(of: model.cacheVersion) { _, _ in
            model.resolveCachedURL(for: resource, downloadIfMissing: false)
            refreshThumb()
        }
    }

    private func refreshThumb() {
        guard let url = localURL, kind == .image || kind == .video || kind == .pdf else { return }
        if let hit = MemoThumbnailStore.shared.cached(url: url, maxPixel: 280) {
            thumbnail = hit
            return
        }
        MemoThumbnailStore.shared.load(url: url, kind: kind, maxPixel: 280) { image in
            if self.localURL == url { self.thumbnail = image }
        }
    }
}

// MARK: - Memo Editor

private struct MemoEditorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: MemosModel
    @State private var preview = false
    @State private var importing = false
    @StateObject private var controller = MarkdownEditorController()

    private var isArchived: Bool { model.original?["rowStatus"] as? String == "ARCHIVED" }
    private var isPinned: Bool { (model.original?["pinned"] as? NSNumber)?.boolValue ?? false }
    private var displayTime: String {
        if let ts = (model.original?["displayTs"] as? NSNumber)?.doubleValue, ts > 0 {
            return shortDateTimeLabel(ts, milliseconds: false)
        }
        return "新建草稿"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header matching chosen-memos.png
            HStack(alignment: .center, spacing: 10) {
                Text(model.original == nil ? "写一条说说" : "编辑说说")
                    .font(.system(size: 17, weight: .semibold))
                if let id = model.selectedID {
                    Text("#\(id)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.blogMuted)
                }
                if model.isDirty {
                    StatusBadge(text: "未保存", color: .blogAmber, dot: true)
                }
                if isArchived {
                    StatusBadge(text: "已归档 · 只读", color: .blogMuted, symbol: "archivebox")
                }
                Spacer()
                Text(displayTime)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.blogMuted)
                BlogSegmentedControl(
                    title: "编辑模式",
                    options: [
                        SegmentedOption(value: false, label: "编辑"),
                        SegmentedOption(value: true, label: "预览")
                    ],
                    selection: $preview,
                    compact: true
                )
            }

            // Rounded solid editor/preview container matching chosen-memos.png
            ZStack {
                if preview {
                    ReaderView(markdown: model.content)
                        .background(Color(nsColor: .lb(light: .rgb(246, 239, 230), dark: .rgb(37, 30, 26))))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.blogStroke))
                        .transaction { $0.animation = nil }
                        .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            MarkdownToolbar(controller: controller, compact: true, attach: isArchived ? nil : { importing = true })
                            Spacer()
                            Text("\(TextStats.words(model.content)) 字")
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(Color.blogMuted)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blogSurface.opacity(0.5))

                        HairlineDivider()

                        MarkdownTextEditor(
                            text: $model.content,
                            documentID: model.selectedID ?? "new-memo",
                            controller: controller,
                            editable: !(isArchived || model.busy),
                            onImportFiles: isArchived ? nil : { model.importFiles($0) }
                        )
                        .clipped()
                        .transaction { $0.animation = nil }
                    }
                    .background(Color.blogEditor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.blogStroke))
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: preview)

            if !model.resources.isEmpty {
                attachmentsGallery
            }

            // Visibility + Attachment Drop Prompt Row
            if !isArchived {
                HStack(spacing: 12) {
                    Text("可见性")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.blogMuted)
                    BlogSegmentedControl(
                        title: "可见性",
                        options: [
                            SegmentedOption(value: "PUBLIC", label: "公开"),
                            SegmentedOption(value: "PROTECTED", label: "登录可见"),
                            SegmentedOption(value: "PRIVATE", label: "仅自己")
                        ],
                        selection: $model.visibility,
                        compact: true
                    )
                    .disabled(model.busy)

                    Spacer()

                    Button {
                        importing = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "paperclip")
                            Text("拖入图片、音频或视频，或点击添加附件…")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.blogMuted)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor(!model.busy)
                    .disabled(model.busy)
                }
            }

            // Bottom Action Row
            HStack(spacing: 10) {
                BlogGlassGroup(spacing: 10) {
                    Button {
                        model.save()
                    } label: {
                        HStack(spacing: 6) {
                            Text("保存")
                            ShortcutCap(text: "⌘S", onPrimary: true)
                        }
                    }
                    .buttonStyle(BlogPrimaryButtonStyle())
                    .disabled(isArchived || model.busy || (!model.isDirty && model.original != nil))

                    if model.original != nil {
                        Button(isPinned ? "取消置顶…" : "置顶…") {
                            model.update(["pinned": !isPinned], title: isPinned ? "取消置顶" : "置顶说说")
                        }
                        .buttonStyle(BlogSecondaryButtonStyle())
                        .disabled(model.busy)

                        Button(isArchived ? "恢复说说…" : "归档…") {
                            model.update(["rowStatus": isArchived ? "NORMAL" : "ARCHIVED"], title: isArchived ? "恢复说说" : "归档说说")
                        }
                        .buttonStyle(BlogSecondaryButtonStyle())
                        .disabled(model.busy)

                        if isArchived {
                            Button("永久删除…") {
                                model.deleteArchived()
                            }
                            .buttonStyle(BlogSecondaryButtonStyle(destructive: true))
                            .disabled(model.busy)
                        }
                    }
                }

                Spacer()

                if model.isDirty {
                    Button("放弃修改…") {
                        model.discardThen { model.assign(model.original) }
                    }
                    .buttonStyle(BlogSecondaryButtonStyle())
                    .disabled(model.busy)
                }
            }
        }
        .padding(24)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importFiles(urls)
            case .failure(let error): model.errors["upload"] = error.localizedDescription
            }
        }
    }

    private var attachmentsGallery: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.blogPeach)
                Text("本地附件（\(model.resources.count)）· 点击预览或播放")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.blogMuted)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(model.resources.enumerated()), id: \.offset) { index, resource in
                        MemoAttachmentCard(
                            model: model,
                            resource: resource,
                            canRemove: !isArchived,
                            onOpen: { model.openResource(resource, in: model.resources) },
                            onRemove: { model.resources.remove(at: index) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Unified Preview Modal (Warm Theme + Liquid Glass Control Bar)

struct MemoPreviewItem: Identifiable, Equatable {
    let key: String
    let url: URL
    let name: String
    let mime: String
    var id: String { key }
}

struct MemoPreviewAttachment: Identifiable {
    let id = UUID()
    let item: MemoPreviewItem
    let gallery: [MemoPreviewItem]
}

private struct MemoAttachmentPreview: View {
    let attachment: MemoPreviewAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @State private var player: AVPlayer?
    @State private var zoom: CGFloat = 1.0
    @State private var loadedImage: NSImage?

    private var items: [MemoPreviewItem] {
        attachment.gallery.isEmpty ? [attachment.item] : attachment.gallery
    }

    private var active: MemoPreviewItem {
        items.indices.contains(currentIndex) ? items[currentIndex] : attachment.item
    }

    private var kind: MemoMediaKind {
        MemoMediaKind.detect(mime: active.mime, ext: active.url.pathExtension.lowercased())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Unified top bar with Liquid Glass action controls
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.blogPeach)

                VStack(alignment: .leading, spacing: 1) {
                    Text(active.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.blogText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if items.count > 1 {
                        Text("\(kind.label) · 第 \(currentIndex + 1) / \(items.count) 项")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Color.blogMuted)
                    } else {
                        Text("\(kind.label) · 本地已缓存")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.blogMuted)
                    }
                }

                Spacer(minLength: 12)

                BlogGlassGroup(spacing: 8) {
                    if items.count > 1 {
                        Button {
                            step(-1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .accessibilityLabel("上一项附件")
                        .help("上一项  ←")

                        Button {
                            step(1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .accessibilityLabel("下一项附件")
                        .help("下一项  →")
                    }

                    if kind == .image {
                        Button {
                            zoom = max(0.5, zoom - 0.25)
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                        .keyboardShortcut("-", modifiers: .command)
                        .accessibilityLabel("缩小图片")
                        .help("缩小  ⌘-")

                        Button("\(Int(zoom * 100))%") {
                            zoom = 1.0
                        }
                        .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                        .keyboardShortcut("0", modifiers: .command)
                        .accessibilityLabel("重置缩放比例")
                        .help("重置缩放  ⌘0")

                        Button {
                            zoom = min(3.0, zoom + 0.25)
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                        .keyboardShortcut("+", modifiers: .command)
                        .accessibilityLabel("放大图片")
                        .help("放大  ⌘+")
                    }

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([active.url])
                    } label: {
                        Label("显示位置", systemImage: "folder")
                    }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                    .help("在 Finder 中显示本地缓存文件")

                    Button("关闭") { dismiss() }
                        .buttonStyle(BlogPrimaryButtonStyle(compact: true))
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.blogBackground)

            HairlineDivider()

            // Solid unified preview stage
            ZStack {
                Color.blogEditor

                switch kind {
                case .image:
                    if let loadedImage {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: loadedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(
                                    maxWidth: max(560, 720 * zoom),
                                    maxHeight: max(380, 520 * zoom)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .padding(20)
                        }
                    } else {
                        ProgressView()
                    }

                case .video:
                    VideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(16)

                case .audio:
                    VStack(spacing: 18) {
                        ZStack {
                            Circle()
                                .fill(Color.blogTintPeach)
                                .frame(width: 84, height: 84)
                            Image(systemName: "waveform")
                                .font(.system(size: 32, weight: .medium))
                                .foregroundStyle(Color.blogPeach)
                        }
                        Text(active.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.blogText)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        VideoPlayer(player: player)
                            .frame(maxWidth: 480, maxHeight: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(32)

                case .pdf, .file:
                    MemoQuickLook(url: active.url)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, idealWidth: 820, minHeight: 500, idealHeight: 580)
        .background(Color.blogBackground)
        .foregroundStyle(Color.blogText)
        .onAppear {
            if let idx = items.firstIndex(of: attachment.item) {
                currentIndex = idx
            }
            loadActive()
        }
        .onChange(of: currentIndex) { _, _ in
            zoom = 1.0
            loadActive()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        currentIndex = (currentIndex + delta + items.count) % items.count
    }

    private func loadActive() {
        player?.pause()
        player = nil
        loadedImage = nil
        switch kind {
        case .image:
            loadedImage = NSImage(contentsOf: active.url)
        case .video, .audio:
            let p = AVPlayer(url: active.url)
            player = p
            p.play()
        case .pdf, .file:
            break
        }
    }
}

private struct MemoQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
        }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.previewItem = nil }
}
