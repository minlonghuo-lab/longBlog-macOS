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
    @State private var keySavedHint = ""
    @State private var action: WritingAction = .summarize
    @State private var output = ""
    @State private var error = ""
    @State private var busy = false
    @State private var completed = false
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Color.blogPeach)
                    Text("AI 写作辅助").font(.system(size: 19, weight: .bold))
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
            }

            DisclosureGroup("接口设置（API Key 仅保存到 macOS Keychain）") {
                VStack(alignment: .leading, spacing: 9) {
                    TextField("HTTPS Base URL，例如 https://api.openai.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 10) {
                        TextField("模型名称（如 gpt-4o-mini）", text: $model)
                            .textFieldStyle(.roundedBorder)
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("保存密钥") { saveKey() }
                            .buttonStyle(BlogSecondaryButtonStyle(compact: true))
                            .disabled(busy)
                    }
                    if !keySavedHint.isEmpty {
                        Text(keySavedHint).font(.system(size: 11.5)).foregroundStyle(Color.blogGreen)
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12.5, weight: .medium))

            BlogSegmentedControl(
                options: WritingAction.allCases.map { SegmentedOption(value: $0, label: $0.rawValue) },
                selection: $action
            )
            .disabled(busy)

            Text("点击“生成预览”会把本文标题、正文及摘要发送至你配置的 HTTPS 模型端点。生成内容可在下方直接审校修改，应用后仍需手动保存。")
                .font(.system(size: 12))
                .foregroundStyle(Color.blogMuted)

            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.blogAmber)
                    .textSelection(.enabled)
            }

            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在流式生成，可随时取消…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.blogSecondary)
                }
            }

            TextEditor(text: $output)
                .font(.system(size: 13.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 250)
                .background(Color.blogEditor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.blogStroke))
                .accessibilityLabel("AI 生成结果预览，可在应用前修改")

            HStack {
                if busy {
                    Button("取消生成") { cancel() }
                        .buttonStyle(BlogSecondaryButtonStyle())
                } else if !output.isEmpty {
                    Text("生成结果共 \(TextStats.words(output)) 字")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.blogMuted)
                }
                Spacer()
                Button("生成预览") { generate() }
                    .buttonStyle(BlogSecondaryButtonStyle())
                    .disabled(busy)
                Button("应用到编辑器") {
                    onApply(action.target, output)
                    dismiss()
                }
                .buttonStyle(BlogPrimaryButtonStyle())
                .disabled(busy || !completed || output.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 740, height: 620)
        .foregroundStyle(Color.blogText)
        .background(Color.blogBackground)
        .tint(.blogPeach)
        .task {
            LBUIRequest("ai.key.load", [:]) { result, _ in
                self.apiKey = result?["key"] as? String ?? ""
            }
        }
        .onDisappear { cancel() }
        .onChange(of: action) { _, _ in output = ""; error = ""; completed = false }
    }

    private func saveKey() {
        keySavedHint = ""
        LBUIRequest("ai.key.save", ["key": apiKey]) { _, err in
            if let err = err {
                self.error = err.localizedDescription
            } else {
                self.error = ""
                self.keySavedHint = apiKey.isEmpty ? "已从 Keychain 清除密钥。" : "API Key 已安全存入 Keychain。"
            }
        }
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
