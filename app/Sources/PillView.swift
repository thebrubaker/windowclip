// PillView — the bottom-center capsule that is the ONLY chrome during a session.
// One surface, three states (countdown → recording → saved), translated from
// mockups/hotkey-ui/components/pill.tsx.

import AppKit
import SwiftUI

enum PillState: Equatable {
    /// Pre-roll. Names the target app so a wrong pick is catchable. Esc cancels.
    case countdown(remaining: Int, appName: String)
    /// Capturing. Red dot + elapsed + Stop.
    case recording(elapsed: TimeInterval)
    /// Confirmation flash, then fades. Carries the full URL, not just a name:
    /// the filename is clickable and reveals the file in Finder.
    case saved(url: URL, duration: TimeInterval)
}

func formatClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct PillView: View {
    let state: PillState
    /// Who started this session. An agent-initiated recording must be obviously
    /// not-user-initiated at a glance — that visibility is the precondition for
    /// ever letting an agent start one.
    var source: SessionSource = .human
    var showsEscapeHint = true
    /// Debug instrument: draws the row's true vertical midline over the pill so
    /// optical centering can be *measured* in a screenshot instead of eyeballed.
    var showMidline: Bool = false
    /// Debug: hold animations at their resting phase so screenshots are deterministic.
    var freezeAnimation: Bool = false
    /// Debug: force the filename's hover treatment on, so the affordance can be
    /// screenshotted without a real pointer parked on the pill.
    var forceHover: Bool = false
    var onStop: () -> Void = {}
    /// Reveal the finished file in Finder, selected and ready to drag.
    var onReveal: (URL) -> Void = { _ in }
    /// Pointer entered/left the pill body. The session uses this to hold the
    /// auto-fade open while the user is reaching for the filename.
    var onHoverChanged: (Bool) -> Void = { _ in }

    /// "Claude · " in the agent accent, or nothing at all for a human session.
    private var attribution: Text {
        guard let label = source.label else { return Text("") }
        return Text(label).foregroundColor(Theme.agentAccent)
            + Text(" · ").foregroundColor(Theme.textMuted)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.pillSpacing) {
            switch state {
            case let .countdown(remaining, appName):
                CountdownBadge(count: remaining)
                // One concatenated Text, so the attribution and the sentence
                // share a baseline and get ink-centred once.
                (
                    attribution
                        + Text("Recording \(appName)…").foregroundColor(Theme.textSecondary)
                )
                .font(Theme.labelFont)
                .opticallyCentered(Theme.labelNSFont)
                if showsEscapeHint {
                    HintRow(leading: nil, key: "esc", trailing: "cancel")
                }

            case let .recording(elapsed):
                RecordingDot(freeze: freezeAnimation)
                (
                    attribution
                        + Text(formatClock(elapsed))
                        .font(Theme.elapsedFont)
                        .foregroundColor(Theme.textPrimary)
                )
                .font(Theme.labelFont)
                .monospacedDigit()
                .opticallyCentered(Theme.labelNSFont)
                Rectangle()
                    .fill(Theme.divider)
                    .frame(width: 1, height: 14)
                    .pillRowItem()
                StopButton(action: onStop)
                if showsEscapeHint {
                    HintRow(leading: "or", key: "esc", trailing: nil)
                }

            case let .saved(url, duration):
                SavedCheck()
                SavedLabel(
                    url: url,
                    duration: duration,
                    forceHover: forceHover,
                    onReveal: onReveal
                )
            }
        }
        .padding(.horizontal, Theme.pillHPadding)
        .frame(height: Theme.pillHeight)
        .background(Capsule().fill(Theme.pillFill))
        .overlay(
            Capsule().strokeBorder(
                source.isAgent ? Theme.agentRing : Theme.pillRing,
                lineWidth: source.isAgent ? 1.5 : 1
            )
        )
        .overlay(alignment: .center) {
            if showMidline {
                Rectangle().fill(Color.green.opacity(0.9)).frame(height: 1)
            }
        }
        // Hover is tracked on the capsule, not the shadow margin — the margin is
        // click-through, so treating it as "on the pill" would hold the fade open
        // from a pointer that isn't really there.
        .onHover { onHoverChanged($0) }
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .padding(Theme.pillShadowMargin)
        .fixedSize()
    }
}

// MARK: - Parts

private struct CountdownBadge: View {
    let count: Int
    private static let size: CGFloat = 20
    private static let digitSize: CGFloat = 11

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                .frame(width: Self.size, height: Self.size)
            Text("\(count)")
                .font(.system(size: Self.digitSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .opticallyCentered(
                    NSFont.systemFont(ofSize: Self.digitSize, weight: .semibold),
                    rowHeight: Self.size
                )
        }
        .pillRowItem()
    }
}

private struct RecordingDot: View {
    let freeze: Bool
    @State private var pulsing = false
    private static let size: CGFloat = 10

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.recordRed)
                .opacity(pulsing ? 0 : 0.55)
                .scaleEffect(pulsing ? 2.2 : 1)
            Circle().fill(Theme.recordRed)
        }
        .frame(width: Self.size, height: Self.size)
        .pillRowItem()
        .onAppear {
            guard !freeze else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

private struct StopButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(hovering ? 1 : 0.85))
                    .frame(width: 9, height: 9)
                    .pillRowItem()
                Text("Stop")
                    .font(Theme.labelFont)
                    .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.85))
                    .opticallyCentered(Theme.labelNSFont)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pillRowItem()
    }
}

/// "Saved <filename> · 0:42", where the filename is a live target that reveals
/// the recording in Finder — selected, ready to drag somewhere.
///
/// The three runs share one baseline (an `.firstTextBaseline` HStack) rather than
/// being centered independently: they're one sentence, and independent centering
/// would stagger them because SF Pro and SF Mono have different cap heights. The
/// whole group is then ink-centered once, from the label font.
private struct SavedLabel: View {
    let url: URL
    let duration: TimeInterval
    let forceHover: Bool
    let onReveal: (URL) -> Void

    @State private var hovering = false

    private var isHot: Bool { hovering || forceHover }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Saved ")
                .font(Theme.labelFont)
                .foregroundStyle(Color.white.opacity(0.85))

            Text(url.lastPathComponent)
                .font(Theme.elapsedFont)
                .foregroundStyle(Color.white.opacity(isHot ? 0.95 : 0.5))
                .underline(isHot)
                // A tight text frame is a mean click target; pad it out without
                // disturbing the shared baseline.
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
                .onHover { hovering in
                    self.hovering = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .onTapGesture { onReveal(url) }
                .help("Reveal in Finder")

            Text(" · \(formatClock(duration))")
                .font(Theme.labelFont)
                .foregroundStyle(Color.white.opacity(0.40))
        }
        .alignmentGuide(VerticalAlignment.center) { d in
            d[.firstTextBaseline] - Theme.labelNSFont.capHeight / 2
        }
        .frame(height: Theme.pillHeight)
        .onDisappear {
            // The pill can vanish out from under a hovering pointer (fade, Esc,
            // a new session). Without this the pointing-hand cursor leaks.
            if hovering {
                NSCursor.pop()
                hovering = false
            }
        }
    }
}

private struct SavedCheck: View {
    private static let size: CGFloat = 17

    var body: some View {
        ZStack {
            Circle().fill(Theme.savedGreen)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
        }
        .frame(width: Self.size, height: Self.size)
        .pillRowItem()
    }
}

/// `esc` chip with optional words on either side — "esc cancel" / "or esc".
private struct HintRow: View {
    let leading: String?
    let key: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 5) {
            if let leading {
                Text(leading)
                    .font(Theme.hintFont)
                    .foregroundStyle(Theme.textMuted)
                    .opticallyCentered(Theme.hintNSFont)
            }
            KbdKey(text: key)
            if let trailing {
                Text(trailing)
                    .font(Theme.hintFont)
                    .foregroundStyle(Theme.textMuted)
                    .opticallyCentered(Theme.hintNSFont)
            }
        }
        .pillRowItem()
    }
}
