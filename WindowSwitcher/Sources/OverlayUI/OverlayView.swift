import SwiftUI

struct OverlayView: View {
    @ObservedObject var settings = AppSettings.shared

    let windows: [WindowInfo]
    @Binding var focusedIndex: Int

    var onSelect: ((WindowInfo) -> Void)?
    var onDismiss: (() -> Void)?

    @State private var hoveredIndex: Int? = nil

    var body: some View {
        ZStack {
            // Full-screen dimming background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { onDismiss?() }

            // Centered thumbnail strip
            thumbnailStrip
        }
        .onAppear { focusedIndex = windows.count / 2 }
    }

    // MARK: - Thumbnail Strip

    private var thumbnailStrip: some View {
        VStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: settings.thumbnailSpacing) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { idx, window in
                            ThumbnailCard(
                                window: window,
                                isFocused: idx == (hoveredIndex ?? focusedIndex),
                                settings: settings
                            )
                            .id(idx)
                            .onTapGesture { onSelect?(window) }
                            .onHover { hovering in
                                hoveredIndex = hovering ? idx : nil
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                }
                .frame(maxWidth: .infinity)
                .onChange(of: focusedIndex) { _, newIdx in
                    withAnimation(.easeOut(duration: settings.animationDuration)) {
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
            }

            // Window title hint
            if let idx = hoveredIndex ?? (focusedIndex < windows.count ? focusedIndex : nil),
               idx < windows.count {
                Text(windows[idx].windowTitle.isEmpty
                     ? windows[idx].ownerName
                     : "\(windows[idx].ownerName) — \(windows[idx].windowTitle)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 8)
            }
        }
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: settings.thumbnailSpacing + 24)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: settings.thumbnailSpacing + 24)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        .padding(.horizontal, 60)
    }
}

// MARK: - Single Thumbnail Card

struct ThumbnailCard: View {
    let window: WindowInfo
    let isFocused: Bool
    let settings: AppSettings

    var body: some View {
        Group {
            if let thumb = window.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholderView
            }
        }
        .frame(height: settings.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: settings.thumbnailCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: settings.thumbnailCornerRadius)
                .stroke(
                    isFocused ? Color.white.opacity(0.5) : Color.white.opacity(0.15),
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .shadow(
            color: .black.opacity(isFocused ? 0.4 : 0.15),
            radius: isFocused ? 12 : 4,
            y: isFocused ? 6 : 2
        )
        .scaleEffect(isFocused ? settings.focusScale : 1.0)
        .opacity(isFocused ? 1.0 : Constants.defaultNonFocusOpacity)
        .zIndex(isFocused ? 10 : 1)
        .animation(
            .easeOut(duration: settings.animationDuration),
            value: isFocused
        )
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: settings.thumbnailCornerRadius)
            .fill(Color.gray.opacity(0.3))
            .frame(width: settings.thumbnailHeight * 1.6) // 16:10-ish aspect
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "macwindow")
                        .font(.title)
                        .foregroundColor(.white.opacity(0.5))
                    Text(window.ownerName)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            )
    }
}
