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

    private static var barCount: Int { 26 }
    @State private var levels: [Float] = Array(repeating: 0, count: 26)

    var body: some View {
        HStack(spacing: 10) {
            switch engine.state {
            case .recording:
                recordingDot
                waveform
            case .transcribing:
                transcribingDots
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .frame(width: 220, height: 44)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        .onChange(of: engine.audioLevel) { _, newLevel in
            levels.removeFirst()
            levels.append(newLevel)
        }
        .onChange(of: engine.state) { _, newState in
            if case .recording = newState {
                levels = Array(repeating: 0, count: Self.barCount)
            }
        }
        .animation(.easeOut(duration: 0.12), value: engine.state)
    }

    private var recordingDot: some View {
        Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
    }

    /// Scrolling waveform: newest level enters on the right.
    private var waveform: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.92))
                    .frame(width: 2.5, height: barHeight(levels[index]))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func barHeight(_ level: Float) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        return 3 + clamped * 21 // 3pt floor so silence still reads as a dotted line
    }

    private var transcribingDots: some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
            Text("Transcribing")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

#Preview("Recording") {
    let engine = MockDictationEngine()
    engine.startRecording()
    return PillView(engine: engine)
        .padding(40)
}

#Preview("Transcribing") {
    let engine = MockDictationEngine()
    engine.setState(.transcribing)
    return PillView(engine: engine)
        .padding(40)
}
