//
//  PillView.swift
//  Whisper — Workstream B
//
//  The floating pill. Dark capsule, live waveform while recording, pulsing
//  dots while transcribing. It exists only in those two states (Wispr's lesson).
//

import SwiftUI

struct PillView<Engine: DictationEngine>: View {
    @ObservedObject var engine: Engine
    /// Hands-free lock flag + ✕/✓ actions (Contracts is frozen, so these ride
    /// alongside the engine).
    @ObservedObject var controls: RecordingControls

    /// Size while recording/transcribing without the hands-free buttons.
    static var baseSize: CGSize { CGSize(width: 220, height: 44) }
    /// Size while hands-free-locked — adds room for the ✕/✓ circles.
    static var handsFreeSize: CGSize { CGSize(width: 292, height: 44) }

    /// Single source of truth for pill/panel size, shared with
    /// `RecordingPanelController` so the NSPanel frame and this view's own
    /// layout can never drift apart.
    static func panelSize(isHandsFreeExpanded: Bool) -> CGSize {
        isHandsFreeExpanded ? handsFreeSize : baseSize
    }

    private static var barCount: Int { 26 }
    @State private var levels: [Float] = Array(repeating: 0, count: barCount)

    private var isHandsFreeExpanded: Bool {
        if case .recording = engine.state { return controls.isHandsFreeLocked }
        return false
    }

    var body: some View {
        content
            .frame(
                width: Self.panelSize(isHandsFreeExpanded: isHandsFreeExpanded).width,
                height: Self.baseSize.height
            )
            .background(.black.opacity(0.82), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
            .onChange(of: engine.audioLevel) { _, newLevel in
                levels.removeFirst()
                levels.append(newLevel)
            }
            .onChange(of: engine.state) { _, newState in
                switch newState {
                case .recording, .transcribing:
                    // Fresh, calm baseline each time we enter an active state —
                    // otherwise a few noisy trailing frames from the end of
                    // recording still show while transcribing starts.
                    levels = Array(repeating: 0, count: Self.barCount)
                default:
                    break
                }
            }
            .animation(.easeOut(duration: DS.Animation.fast), value: engine.state)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHandsFreeExpanded)
    }

    @ViewBuilder
    private var content: some View {
        switch engine.state {
        case .recording where controls.isHandsFreeLocked:
            HStack(spacing: 12) {
                cancelButton
                waveform
                confirmButton
            }
            .padding(.horizontal, 14)
        case .recording, .transcribing:
            HStack(spacing: 10) {
                waveform
                if case .transcribing = engine.state {
                    PillSpinnerView()
                }
            }
            .padding(.horizontal, 18)
        default:
            EmptyView()
        }
    }

    /// Scrolling waveform: newest level enters on the right. Idles as a
    /// gently breathing row of dots rather than a frozen line — the phase
    /// formula matches `A3BBuddyWaveformView` (OverlayWindow.swift).
    private var waveform: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timeline in
            HStack(alignment: .center, spacing: 3) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(0.92))
                        .frame(width: 2.5, height: barHeight(for: index, level: levels[index], date: timeline.date))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func barHeight(for index: Int, level: Float, date: Date) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        let reactive = clamped * 21
        let phase = date.timeIntervalSinceReferenceDate * 3.6 + Double(index) * 0.35
        let idlePulse = (sin(phase) + 1) / 2 * 1.5
        return 3 + reactive + idlePulse // 3pt floor so silence still reads as a dotted line
    }

    private var cancelButton: some View {
        Button(action: controls.onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.18), in: Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var confirmButton: some View {
        Button(action: controls.onConfirm) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(.white, in: Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// White spinning indicator for the `.transcribing` state. Local variant of
/// `A3BBuddySpinnerView` (OverlayWindow.swift, wine-coloured + private to
/// that file) — same trim/gradient/rotation, no cursor glow.
private struct PillSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [Color.white.opacity(0.0), Color.white],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
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
