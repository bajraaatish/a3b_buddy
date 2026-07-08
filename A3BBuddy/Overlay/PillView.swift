//
//  PillView.swift
//  Whisper — Workstream B
//
//  The floating pill. Dark capsule, live waveform while recording, pulsing
//  dots while transcribing. It exists only in those two states (Wispr's lesson).
//
//  Sizing/colors below are measured pixel-for-pixel off docs/reference/whisper-pill/*.png
//  (run-length-encoded row/column scans, not eyeballed) — see git history for the analysis.
//

import SwiftUI

struct PillView<Engine: DictationEngine>: View {
    @ObservedObject var engine: Engine
    /// Hands-free lock flag + ✕/✓ actions (Contracts is frozen, so these ride
    /// alongside the engine).
    @ObservedObject var controls: RecordingControls

    // Half the pixel-measured reference spec (see git history) — still too
    // big at 1:1, so this treats the reference PNGs as an @2x capture.
    static var capsuleHeight: CGFloat { 28 }
    private static var dotCount: Int { 10 }
    private static var dotSize: CGFloat { 2 }
    private static var dotGap: CGFloat { 2 }
    private static var waveformWidth: CGFloat {
        CGFloat(dotCount) * dotSize + CGFloat(dotCount - 1) * dotGap
    }
    private static var buttonDiameter: CGFloat { 17 }

    /// The four visual states, collapsing `(engine.state, controls.isHandsFreeLocked)`
    /// into what the pill actually renders. Single source of truth shared with
    /// `RecordingPanelController` so the NSPanel frame can never drift from this view's
    /// own layout.
    enum Layout: Equatable {
        case recording(handsFree: Bool)
        case transcribing
        case hidden
    }

    static func layout(state: DictationState, isHandsFreeLocked: Bool) -> Layout {
        switch state {
        case .recording: return .recording(handsFree: isHandsFreeLocked)
        case .transcribing: return .transcribing
        case .idle, .failed: return .hidden
        }
    }

    /// Half of the measured reference sizes: 73×28 base, 102×28 hands-free
    /// (6.5 pad + 17 button + 8.5 gap + 38 dots + 8.5 gap + 17 button + 6.5 pad),
    /// 97.5×28 transcribing (19 pad + 38 dots + 8.5 gap + 15 spinner + 17 pad).
    static func size(for layout: Layout) -> CGSize {
        switch layout {
        case .recording(handsFree: false): return CGSize(width: 73, height: capsuleHeight)
        case .recording(handsFree: true): return CGSize(width: 102, height: capsuleHeight)
        case .transcribing: return CGSize(width: 97.5, height: capsuleHeight)
        case .hidden: return CGSize(width: 73, height: capsuleHeight)
        }
    }

    private var layout: Layout {
        Self.layout(state: engine.state, isHandsFreeLocked: controls.isHandsFreeLocked)
    }

    var body: some View {
        content
            .frame(width: Self.size(for: layout).width, height: Self.capsuleHeight)
            .background(.black.opacity(0.94), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.35), radius: 7, y: 2)
            .animation(.easeOut(duration: DS.Animation.fast), value: layout)
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .recording(handsFree: true):
            HStack(spacing: 8.5) {
                cancelButton
                waveform
                confirmButton
            }
            .padding(.horizontal, 6.5)
        case .recording(handsFree: false):
            waveform
                .frame(maxWidth: .infinity)
        case .transcribing:
            HStack(spacing: 8.5) {
                waveform
                PillSpinnerView()
            }
            .padding(.leading, 19)
            .padding(.trailing, 17)
        case .hidden:
            EmptyView()
        }
    }

    /// Symmetric bell profile (not a scrolling history of raw samples) — the
    /// reference "talking" image is a smooth hump peaking at the two center
    /// dots, same technique `A3BBuddyWaveformView` uses for its 5-bar cursor
    /// waveform (OverlayWindow.swift), just with 10 dots.
    private static var barProfile: [CGFloat] { [0.35, 0.5, 0.7, 0.85, 1.0, 1.0, 0.85, 0.7, 0.5, 0.35] }

    private var dotColor: Color {
        if case .transcribing = engine.state { return .white.opacity(0.28) }
        return .white.opacity(0.95)
    }

    private var waveform: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timeline in
            HStack(alignment: .center, spacing: Self.dotGap) {
                ForEach(0 ..< Self.dotCount, id: \.self) { index in
                    Capsule()
                        .fill(dotColor)
                        .frame(width: Self.dotSize, height: barHeight(for: index, date: timeline.date))
                }
            }
        }
        .frame(width: Self.waveformWidth, height: Self.capsuleHeight, alignment: .center)
    }

    /// Idle pulse formula ported from `A3BBuddyWaveformView`; the reactive
    /// term uses that same view's easing curve, tuned hotter than the
    /// source (4.8x not 2.85x gain, 0.55 not 0.76 exponent) so normal
    /// talking volume swings the bars hard instead of needing near-peak
    /// input to look alive.
    private func barHeight(for index: Int, date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate * 3.6 + Double(index) * 0.35
        let idlePulse = (sin(phase) + 1) / 2 * 0.75
        let normalizedLevel = max(Double(engine.audioLevel) - 0.008, 0)
        let easedLevel = pow(min(normalizedLevel * 4.8, 1), 0.55)
        let reactive = CGFloat(easedLevel) * 13 * Self.barProfile[index]
        return Self.dotSize + idlePulse + reactive // dotSize floor: idle dot reads as a small square, matching reference
    }

    private var cancelButton: some View {
        Button(action: controls.onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 6.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.buttonDiameter, height: Self.buttonDiameter)
                .background(.white.opacity(0.28), in: Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var confirmButton: some View {
        Button(action: controls.onConfirm) {
            Image(systemName: "checkmark")
                .font(.system(size: 6.5, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: Self.buttonDiameter, height: Self.buttonDiameter)
                .background(.white, in: Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// Spinning indicator for the `.transcribing` state. The reference is an
/// 8-spoke radial activity indicator (classic spinning-wait-cursor style) —
/// NOT `A3BBuddySpinnerView`'s single trimmed arc (OverlayWindow.swift).
/// One fixed hue at 8 fixed opacities, the whole ring rotates as a rigid
/// unit; measured lavender ~#877CA4, half-scale ~15pt diameter.
private struct PillSpinnerView: View {
    @State private var isSpinning = false
    private static let tint = Color(red: 135.0 / 255, green: 124.0 / 255, blue: 164.0 / 255)
    private static let spokeCount = 8
    private static let diameter: CGFloat = 15

    var body: some View {
        ZStack {
            ForEach(0 ..< Self.spokeCount, id: \.self) { index in
                Capsule()
                    .fill(Self.tint.opacity(opacity(for: index)))
                    .frame(width: 1.25, height: 4.5)
                    .offset(y: -Self.diameter / 2 + 2.25)
                    .rotationEffect(.degrees(Double(index) / Double(Self.spokeCount) * 360))
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .rotationEffect(.degrees(isSpinning ? 360 : 0))
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
        }
    }

    /// Brightest spoke leads, fading around the ring — reads as a chasing tail while spinning.
    private func opacity(for index: Int) -> Double {
        1.0 - (Double(index) / Double(Self.spokeCount)) * 0.85
    }
}

#Preview("Recording — silent") {
    let engine = MockDictationEngine()
    engine.startRecordingSilently()
    return PillView(engine: engine, controls: RecordingControls())
        .padding(40)
}

#Preview("Recording — talking") {
    let engine = MockDictationEngine()
    engine.startRecording()
    return PillView(engine: engine, controls: RecordingControls())
        .padding(40)
}

#Preview("Hands-free") {
    let engine = MockDictationEngine()
    engine.startRecordingSilently()
    let controls = RecordingControls()
    controls.isHandsFreeLocked = true
    return PillView(engine: engine, controls: controls)
        .padding(40)
}

#Preview("Transcribing") {
    let engine = MockDictationEngine()
    engine.setState(.transcribing)
    return PillView(engine: engine, controls: RecordingControls())
        .padding(40)
}
