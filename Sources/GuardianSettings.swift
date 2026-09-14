import SwiftUI

struct GuardianSettings: View {
    @ObservedObject var guardian: TaskGuardian

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("任务守护：有任务时合盖继续运行", isOn: $guardian.enabled)
                .toggleStyle(.switch).accessibilityIdentifier("guardianEnabled")
                .disabled(guardian.installing)
            Toggle("仅接通电源时守护", isOn: $guardian.onlyOnPower)
                .accessibilityIdentifier("guardianOnlyOnPower")
                .disabled(guardian.installing)
            Text(guardian.status).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled).accessibilityIdentifier("guardianStatus")
            if !guardian.connected {
                Toggle("安装时恢复正常休眠，由 Foldy 按任务管理", isOn: $guardian.normalizeOnInstall)
                    .accessibilityIdentifier("guardianNormalizeOnInstall")
                    .disabled(guardian.installing)
                Text("未勾选时会保留已有的全局禁睡设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if guardian.installing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在安装任务守护…").font(.callout)
                }.accessibilityLabel("正在安装任务守护")
            } else if !guardian.connected {
                Button("安装并授权任务守护") { guardian.install() }
                    .accessibilityIdentifier("guardianInstall")
            }
            if !guardian.runningNames.isEmpty {
                Text("正在运行 \(guardian.runningNames.count) 个任务").font(.callout)
                    .accessibilityIdentifier("guardianRunningCount")
                ForEach(Array(guardian.runningNames.prefix(3).enumerated()), id: \.offset) { _, name in
                    Text(name).font(.caption).lineLimit(2).textSelection(.enabled)
                }
            }
            HStack {
                Text("最长守护")
                Slider(value: $guardian.durationMinutes, in: 5...120, step: 5)
                    .accessibilityLabel("最长守护时间")
                    .accessibilityIdentifier("guardianDuration")
                Text("\(Int(guardian.durationMinutes)) 分钟").monospacedDigit().frame(width: 64)
            }
            if guardian.active {
                Button("停止守护并恢复休眠") { guardian.stop() }
                    .accessibilityIdentifier("guardianStop")
            }
            Text("任务结束、关闭守护或超时后恢复原来的休眠设置。")
                .font(.caption).foregroundStyle(.secondary)
            Text("首次需要 macOS 管理员授权。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
