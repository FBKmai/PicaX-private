import SwiftUI

struct ReaderImageCompareRequest: Identifiable {
    let id = UUID()
    let urlString: String
    let enhancement: ReaderImageEnhancement
}

/// Traditional display filters remain compatible with existing reader settings.
/// AI is deliberately a separate, explicitly started current-page experiment.
struct ReaderImageEnhancementPanel: View {
    let targetPixelWidth: Int?
    let canCompare: Bool
    let onCompare: () -> Void
    let onClose: () -> Void

    @AppStorage(ReaderSettingsKey.imageEnhancementMode) private var enhancementMode = ImageEnhancementMode.off.rawValue
    @AppStorage(ReaderSettingsKey.imageEnhancementStrength) private var enhancementStrength = 0.0
    @AppStorage(ReaderSettingsKey.imageEnhancementScale) private var enhancementScale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("画质增强", systemImage: "wand.and.stars")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .accessibilityLabel("关闭画质增强面板")
            }

            HStack {
                Text("传统插值 / 锐化")
                Spacer()
                Picker("传统插值 / 锐化", selection: $enhancementMode) {
                    ForEach(ImageEnhancementMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.white)
            }

            if selectedMode != .off {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("强度")
                        Spacer()
                        Text("\(Int(enhancementStrength))%")
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Slider(value: $enhancementStrength, in: 0...100, step: 5)
                }
                if selectedMode.usesUpscale {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("目标分辨率")
                            Spacer()
                            Text(outputWidthLabel)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Picker("目标分辨率", selection: $enhancementScale) {
                            ForEach(ReaderImageEnhancement.scalePresets, id: \.self) { preset in
                                Text(ReaderImageEnhancement.scaleLabel(for: preset)).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }

            Button(action: onCompare) {
                Label("原图对比 / 本页 AI 试处理", systemImage: "rectangle.split.2x1")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCompare)

            Text("传统模式不是 AI。AI 需在对比页手动选择黑白或彩色模型并开始，不随翻页自动运行，也不叠加这里的锐化。")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(16)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
        .foregroundStyle(.white)
        .onChange(of: enhancementMode) { newValue in
            // Compatibility only: AI never reads or inherits this strength.
            guard newValue != ImageEnhancementMode.off.rawValue, enhancementStrength <= 0 else { return }
            enhancementStrength = 60
        }
    }

    private var selectedMode: ImageEnhancementMode {
        ImageEnhancementMode(rawValue: enhancementMode) ?? .off
    }

    private var outputWidthLabel: String {
        let scale = ReaderImageEnhancement.scaleLabel(for: enhancementScale)
        guard let targetPixelWidth, targetPixelWidth > 0 else {
            return "屏幕物理像素宽 × \(scale)"
        }
        return "约 \(Int((Double(targetPixelWidth) * enhancementScale).rounded())) px 宽"
    }
}

extension View {
    /// iPhone/iPad use a full-screen comparison; macOS uses a sheet.
    @ViewBuilder
    func readerImageComparePresentation(
        request: Binding<ReaderImageCompareRequest?>,
        targetPixelWidth: @escaping (CGFloat) -> Int?
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: request) { item in
            GeometryReader { geometry in
                ReaderImageCompareView(
                    request: item,
                    targetPixelWidth: targetPixelWidth(geometry.size.width),
                    onClose: { request.wrappedValue = nil }
                )
            }
            .background(Color.black.ignoresSafeArea())
        }
        #else
        sheet(item: request) { item in
            GeometryReader { geometry in
                ReaderImageCompareView(
                    request: item,
                    targetPixelWidth: targetPixelWidth(geometry.size.width),
                    onClose: { request.wrappedValue = nil }
                )
            }
            .frame(minWidth: 560, minHeight: 640)
        }
        #endif
    }
}
