import SwiftUI
import AppKit

struct InboxWorkspace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: InboxModel
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sessionList
                    .frame(minWidth: 280, idealWidth: 325, maxWidth: 370)
                Group {
                    if let selected = model.selected {
                        conversation(selected)
                    } else {
                        EmptyWorkspace(
                            symbol: "bubble.left.and.bubble.right",
                            title: model.archived ? "归档会话" : "终端留言",
                            detail: "从左侧选择一个访客会话查看对话记录与联系信息。支持只读归档浏览，回复发送前均会弹窗确认。",
                            settings: !model.loaded,
                            actionTitle: !model.loaded ? "读取会话列表" : nil,
                            action: !model.loaded ? { model.refresh() } : nil
                        )
                    }
                }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { OperationStatus(model: model).padding(.bottom, 16) }
            }
        }
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BlogSegmentedControl(
                    title: "会话列表",
                    options: [
                        SegmentedOption(value: false, label: "进行中"),
                        SegmentedOption(value: true, label: "归档记录")
                    ],
                    selection: Binding(get: { model.archived }, set: { model.setArchived($0) }),
                    compact: true
                )
                if model.loaded {
                    Text("\(model.sessions.count)")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.blogMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.blogSlot, in: Capsule())
                }
                Spacer()
                if model.unread > 0 && !model.archived {
                    StatusBadge(text: "\(model.unread) 未读", color: .blogPeach, pill: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            HairlineDivider()

            ZStack {
                if model.filtered.isEmpty {
                    EmptyWorkspace(
                        symbol: "tray",
                        title: model.search.isEmpty ? "暂无会话" : "没有匹配的会话",
                        detail: model.errors.isEmpty && model.loaded
                            ? (model.search.isEmpty ? "当前没有访客留言会话。" : "换个关键词试试。")
                            : "点击右上角刷新或检查终端留言服务配置。",
                        settings: !model.errors.isEmpty
                    )
                    .id("empty-\(model.archived)")
                    .transition(.opacity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 9) {
                            ForEach(model.filtered) { row in
                                sessionCell(row)
                            }
                            if model.archived && !model.archiveCursor.isEmpty {
                                Button("加载更多归档") { model.refresh(more: true) }
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
        }
    }

    private func sessionCell(_ row: DataRow) -> some View {
        let last = row.data["last"] as? [String: Any] ?? [:]
        let unread = row.flag("unread")
        let selected = model.selected?.id == row.id
        let lastTime = (last["createdAt"] as? NSNumber)?.doubleValue ?? row.number("createdAt")
        let titleText = row.text("title").isEmpty ? String(row.id.prefix(6)).uppercased() : row.text("title")

        return Button { model.select(row) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if unread {
                        Circle().fill(Color.blogPeach).frame(width: 7, height: 7)
                    }
                    Text("访客 · \(titleText)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected || unread ? Color.blogPeachSoft : Color.blogText)
                    Spacer()
                    Text(relativeTimeLabel(lastTime))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.blogMuted)
                }
                Text(last["text"] as? String ?? "暂无消息")
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected || unread ? Color.blogSecondary : Color.blogMuted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle(selected: selected, highlighted: unread))
        .accessibilityLabel("会话 访客 \(titleText)")
    }

    private func conversation(_ selected: DataRow) -> some View {
        let titleText = selected.text("title").isEmpty ? String(selected.id.prefix(6)).uppercased() : selected.text("title")
        return VStack(spacing: 0) {
            // Conversation Header (Scheme 1 chosen-inbox.png)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("访客 · \(titleText)")
                            .font(.system(size: 15, weight: .semibold))
                        if model.archived {
                            StatusBadge(text: "已归档", color: .blogMuted)
                        }
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selected.id, forType: .string)
                        model.flash("copy", "已复制会话 ID")
                    } label: {
                        HStack(spacing: 4) {
                            Text(selected.id)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.blogMuted)
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.blogMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("点击复制完整会话 ID")
                }

                Spacer()

                Button {
                    if model.contact != nil { model.contact = nil } else { model.fetchContact() }
                } label: {
                    Label("联系信息", systemImage: "person.text.rectangle")
                }
                .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                .disabled(model.busy)

                Button {
                    model.loadMessages()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                .accessibilityLabel("刷新所选会话消息")
                .disabled(model.busy)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            if let contact = model.contact {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("访客联系信息", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.blogPeachSoft)
                        Spacer()
                        Button { model.contact = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Color.blogMuted)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .accessibilityLabel("关闭联系信息")
                    }
                    if contact.isEmpty {
                        Text("访客未填写额外联系信息。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.blogMuted)
                    } else {
                        ForEach(contact.keys.sorted(), id: \.self) { key in
                            HStack(spacing: 8) {
                                Text("\(key)：").foregroundStyle(Color.blogMuted)
                                Text(String(describing: contact[key]!)).foregroundStyle(Color.blogText).textSelection(.enabled)
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Color.blogSurface)
            }

            HairlineDivider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if model.messages.isEmpty {
                            Text(model.busy ? "正在读取对话记录…" : "尚无对话消息。")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.blogMuted)
                                .padding(28)
                        }
                        ForEach(model.messages) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                    }
                    .padding(24)
                }
                .onChange(of: model.messages.count) {
                    if let last = model.messages.last {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            HairlineDivider()

            if model.archived {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox").foregroundStyle(Color.blogMuted)
                    Text("归档会话为只读记录，无法继续发送回复。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.blogMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if model.failedReply != nil {
                        Label("上次发送结果未知或失败；相同正文重试将复用原 messageId，防止重复投递。", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.blogAmber)
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("回复访客…（⌘↩ 发送，发送前弹窗确认）", text: $model.reply, axis: .vertical)
                            .lineLimit(1...5)
                            .font(.system(size: 13.5))
                            .textFieldStyle(.plain)
                            .focused($replyFocused)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(Color.blogField, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(replyFocused ? Color.blogPeach.opacity(0.6) : Color.blogStroke)
                            )
                            .disabled(model.busy)
                            .accessibilityLabel("留言回复正文")

                        Button {
                            model.send()
                        } label: {
                            HStack(spacing: 5) {
                                Text("发送")
                                Text("↩").font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(BlogPrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.busy || model.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("发送回复（⌘↩）")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: DataRow
    private var isVisitor: Bool { message.flag("visitor") }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !isVisitor { Spacer(minLength: 80) }

            VStack(alignment: isVisitor ? .leading : .trailing, spacing: 5) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.text("text"))
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(isVisitor ? Color.blogText : Color.blogPeachInk)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(
                    isVisitor ? Color.blogSurfaceHover : Color.blogPeach,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isVisitor ? Color.blogStroke : Color.clear)
                )

                HStack(spacing: 6) {
                    Text(isVisitor ? "访客" : "站长")
                    Text("·")
                    Text(relativeTimeLabel(message.number("createdAt")))
                    if message.flag("failed") {
                        Text("· 发送失败").foregroundStyle(Color.blogAmber)
                    } else if message.flag("pending") {
                        Text("· 待确认").foregroundStyle(Color.blogPeach)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.blogMuted)
                .padding(.horizontal, 4)
            }

            if isVisitor { Spacer(minLength: 80) }
        }
        .frame(maxWidth: .infinity, alignment: isVisitor ? .leading : .trailing)
    }
}
