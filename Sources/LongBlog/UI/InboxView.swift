import SwiftUI

struct InboxWorkspace: View {
    @ObservedObject var model: InboxModel
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sessionList.frame(minWidth: 290, idealWidth: 320, maxWidth: 350)
                if let selected = model.selected { conversation(selected).frame(minWidth: 430) }
                else { EmptyWorkspace(symbol: "bubble.left.and.bubble.right", title: model.archived ? "归档会话" : "终端留言", detail: "选择会话查看消息和联系信息。现有协议支持只读归档列表，不提供主动归档接口。", settings: !model.loaded) }
            }
            OperationStatus(model: model)
        }
    }
    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack { Text(model.archived ? "归档记录" : "进行中的会话").font(.headline); Spacer(); StatusBadge(text: "\(model.sessions.count)", color: .gray) }.padding(16)
            Divider()
            if model.sessions.isEmpty { EmptyWorkspace(symbol: "tray", title: "没有会话", detail: model.errors.isEmpty && model.loaded ? "服务返回空列表。" : "请刷新或检查留言服务连接。", settings: !model.errors.isEmpty) }
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(model.filtered) { row in sessionCell(row) }
                    if model.archived && !model.archiveCursor.isEmpty { Button("加载更多归档") { model.refresh(more: true) }.disabled(model.busy).padding() }
                }.padding(10)
            }
        }
    }
    private func sessionCell(_ row: DataRow) -> some View {
        let last = row.data["last"] as? [String: Any] ?? [:]
        return Button { model.select(row) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.flag("unread") ? "circle.fill" : "person.crop.circle").foregroundStyle(row.flag("unread") ? Color.blogPeach : .secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(row.text("title")).font(.headline); Spacer(); if row.flag("unread") { StatusBadge(text: "未读") } }
                    Text(last["text"] as? String ?? "暂无消息").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Text(dateLabel((last["createdAt"] as? NSNumber)?.doubleValue ?? row.number("createdAt"))).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).background(model.selected?.id == row.id ? Color.blogPeach.opacity(0.17) : .white.opacity(0.03), in: RoundedRectangle(cornerRadius: 11)).accessibilityLabel("会话 \(row.text("title"))")
    }
    private func conversation(_ selected: DataRow) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(selected.text("title")).font(.headline); Text(selected.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
                Button("联系信息", systemImage: "person.crop.rectangle") { model.fetchContact() }.disabled(model.busy)
                Button { model.loadMessages() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新所选会话消息").disabled(model.busy)
            }.padding(18)
            if let contact = model.contact {
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text("联系信息").font(.caption.bold()); Spacer(); Button { model.contact = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭联系信息") }
                    if contact.isEmpty { Text("访客未提供联系信息。").font(.caption).foregroundStyle(.secondary) }
                    ForEach(contact.keys.sorted(), id: \.self) { key in Text("\(key)：\(String(describing: contact[key]!))").font(.caption).textSelection(.enabled) }
                }.padding(14).background(.white.opacity(0.04))
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if model.messages.isEmpty { Text("尚无消息，或正在读取。").font(.callout).foregroundStyle(.secondary).padding(24) }
                        ForEach(model.messages) { message in MessageBubble(message: message).id(message.id) }
                    }.padding(22)
                }.onChange(of: model.messages.count) { _ in if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Divider()
            if model.archived { Label("归档会话只读", systemImage: "archivebox").font(.callout).foregroundStyle(.secondary).padding(20) }
            else {
                VStack(alignment: .leading, spacing: 10) {
                    if model.failedReply != nil { Text("上次发送失败或结果未知。相同正文重试沿用相同 messageId，避免重复回复。").font(.caption).foregroundStyle(.orange) }
                    TextEditor(text: $model.reply).font(.body).scrollContentBackground(.hidden).frame(minHeight: 65, maxHeight: 110).padding(8).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel("留言回复正文").disabled(model.busy)
                    HStack { Text("发送前将确认目标会话与正文。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("发送回复", systemImage: "paperplane") { model.send() }.buttonStyle(.borderedProminent).disabled(model.busy || model.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }.padding(18)
            }
        }
    }
}
private struct MessageBubble: View {
    let message: DataRow
    var body: some View {
        HStack {
            if !message.flag("visitor") { Spacer(minLength: 65) }
            VStack(alignment: .leading, spacing: 7) {
                Text(message.flag("visitor") ? "访客" : "站长").font(.caption.bold()).foregroundStyle(.secondary)
                Text(message.text("text")).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack { Text(dateLabel(message.number("createdAt"))).font(.system(size: 10)); if message.flag("failed") { Text("发送失败").foregroundStyle(.orange) }; if message.flag("pending") { Text("待确认") } }.foregroundStyle(.secondary)
            }.padding(14).background(message.flag("visitor") ? .white.opacity(0.06) : Color.blogPeach.opacity(0.17), in: RoundedRectangle(cornerRadius: 13))
            if message.flag("visitor") { Spacer(minLength: 65) }
        }
    }
}
