import SwiftUI

// MARK: - Card frame reporting (full-screen hover detection)

struct CardFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Finds the backing NSScrollView in the SwiftUI view hierarchy for forwarding
/// scrollWheel events from full-screen trackpad scrolling.
struct ScrollViewFinder: NSViewRepresentable {
    let onFound: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            var parent = view.superview
            while parent != nil {
                if let sv = parent as? NSScrollView { onFound(sv); break }
                parent = parent?.superview
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @ObservedObject var settings = AppSettings.shared

    var onSelect: ((WindowInfo) -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { onDismiss?() }

            thumbnailStrip
        }
    }

    // MARK: - Thumbnail Strip

    private var thumbnailStrip: some View {
        let displayIdx = viewModel.displayIndex

        return VStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: settings.thumbnailSpacing) {
                        ForEach(Array(viewModel.windows.enumerated()), id: \.element.id) { idx, window in
                            ThumbnailCard(
                                window: window,
                                isFocused: idx == displayIdx,
                                settings: settings
                            )
                            .frame(
                                width: thumbnailWidth(for: window, height: settings.thumbnailHeight),
                                height: settings.thumbnailHeight
                            )
                            .id(idx)
                            .background(GeometryReader { geo in
                                Color.clear
                                    .preference(key: CardFrameKey.self,
                                                value: [idx: geo.frame(in: .global)])
                            })
                            .onHover { hovering in
                                if hovering {
                                    viewModel.notifyScrollHover(at: idx)
                                }
                            }
                            .onTapGesture {
                                viewModel.focusedIndex = idx
                                onSelect?(window)
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .onPreferenceChange(CardFrameKey.self) { frames in
                        if frames.count != viewModel.cardFrames.count {
                            logDebug("CARD-FRAMES: updated, count=\(frames.count)")
                        }
                        viewModel.cardFrames = frames
                    }
                    .background(ScrollViewFinder { sv in
                        viewModel.scrollView = sv
                    })
                }
                .frame(maxWidth: .infinity)
                .onChange(of: viewModel.focusedIndex) { _, newIdx in
                    withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.7)) {
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
                .onChange(of: viewModel.snapToIndex) { _, newIdx in
                    guard let idx = newIdx else { return }
                    withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.7)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }

            if let idx = viewModel.hoveredIndex ?? (displayIdx < viewModel.windows.count ? displayIdx : nil),
               idx < viewModel.windows.count {
                let w = viewModel.windows[idx]
                Text(w.windowTitle.isEmpty
                     ? w.ownerName
                     : "\(w.ownerName) — \(w.windowTitle)")
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
        .padding(.horizontal, 20)
    }

    // MARK: - Thumbnail Sizing

    private func thumbnailWidth(for window: WindowInfo, height: CGFloat) -> CGFloat {
        let ratio: CGFloat
        if let thumb = window.thumbnail {
            ratio = thumb.size.width / thumb.size.height
        } else {
            ratio = 1.6
        }
        let w = height * ratio
        return min(max(w, height * 0.8), settings.thumbnailMaxWidth)
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
