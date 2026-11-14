import SwiftUI

enum AIWritingTarget { case body, summary, continuation }

private enum WritingAction: String, CaseIterable, Identifiable {
    case summarize = "生成摘要", polishSummary = "润色摘要", polishBody = "润色正文", continueBody = "从文末续写"
    var id: String { rawValue }
    var target: AIWritingTarget {
        switch self {
        case .summarize, .polishSummary: return .summary
        case .polishBody: return .body
        case .continueBody: return .continuation
        }
    }
}

struct AIWritingSheet: View {
    let title: String
    let bodyText: String
    let summary: String
    let onApply: (AIWritingTarget, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lb.ai.baseURL") private var baseURL = ""
    @AppStorage("lb.ai.model") private var model = ""
    @State private var apiKey = ""
    @State private var action: WritingAction = .summarize
    @State private var output = ""
    @State private var error = ""
    @State private var busy = false
    @State private var completed = false
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("AI 写作辅助", systemImage: "sparkles").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            DisclosureGroup("接口设置（API Key 仅保存到 macOS Keychain）") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("HTTPS Base URL，例如 https://example.com/v1", text: $baseURL)
                    TextField("模型名称", text: $model)
                    SecureField("API Key", text: $apiKey)
                    Button("保存 API Key") { saveKey() }.disabled(busy)
                }.padding(.top, 8)
            }
            Picker("操作", selection: $action) {
                ForEach(WritingAction.allCases) { item in Text(item.rawValue).tag(item) }
            }.pickerStyle(.segmented).disabled(busy)
            Text("点击生成将把本文标题、正文及摘要发送给你配置的 AI 服务。请确认服务商的数据政策；结果仅预览，应用后仍须自行保存，不会自动发布。")
                .font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if busy { ProgressView("正在生成，可随时取消…").controlSize(.small) }
            TextEditor(text: $output)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.25)))
                .accessibilityLabel("AI 生成结果预览，可在应用前修改")
            HStack {
                if busy { Button("取消生成") { cancel() } }
                Spacer()
                Button("生成预览") { generate() }.disabled(busy)
                Button("应用到编辑器") {
                    onApply(action.target, output)
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(busy || !completed || output.isEmpty)
            }
        }
        .padding(24).frame(width: 740, height: 620)
        .onAppear { apiKey = LBKeychain.get("ai-api-key") ?? "" }
        .onDisappear { cancel() }
        .onChange(of: action) { _, _ in output = ""; error = ""; completed = false }
    }

    private func saveKey() {
        LBKeychain.set(apiKey.isEmpty ? nil : apiKey, account: "ai-api-key")
        if (LBKeychain.get("ai-api-key") ?? "") != apiKey {
            error = "Keychain 保存失败，请检查系统授权；API Key 未写入普通设置。"
        } else { error = "" }
    }

    private func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
        busy = false
        completed = false
    }

    private func generate() {
        guard AIWritingService.endpoint(baseURL) != nil, !model.isEmpty, !apiKey.isEmpty else {
            error = AIRequestError.invalidConfiguration.localizedDescription
            return
        }
        let input: String
        switch action {
        case .summarize: input = "为以下文章写一段简明摘要。"
        case .polishSummary: input = "润色现有摘要，保持其事实与长度。"
        case .polishBody: input = "润色以下正文，保持原有事实及 Markdown 结构，不改标题和链接。"
        case .continueBody: input = "为以下文章从文末续写合理的一小段，只输出新增段落，不重复原文。"
        }
        let prompt = input + "\n\n标题：" + title + "\n\n现有摘要：" + summary + "\n\n正文：\n" + bodyText
        let baseSnapshot = baseURL, modelSnapshot = model, keySnapshot = apiKey
        let id = UUID()
        requestID = id
        output = ""; error = ""; completed = false; busy = true
        task = Task { @MainActor in
            do {
                let result = try await AIWritingService().generate(base: baseSnapshot, model: modelSnapshot, key: keySnapshot, prompt: prompt) { text in
                    guard requestID == id else { return }
                    output = text
                }
                guard requestID == id, !Task.isCancelled else { return }
                output = result; completed = true; busy = false; task = nil
            } catch {
                guard requestID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                busy = false; completed = false; task = nil
            }
        }
    }
}
