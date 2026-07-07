//
//  OnboardingView.swift
//  Whisper — Workstream B
//
//  Three steps: microphone → accessibility → try it. Permission actions are
//  injected; integration wires the real prompts.
//

import SwiftUI

struct OnboardingView: View {
    var requestMic: () async -> Bool = { true }
    var promptAccessibility: () -> Void = {}
    var isAccessibilityTrusted: () -> Bool = { false }
    var onDone: () -> Void = {}

    @State private var step = 0
    @State private var micGranted = false
    @State private var axTrusted = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 8)

            Image(systemName: stepIcon)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(height: 56)
                .symbolEffect(.bounce, value: step)

            VStack(spacing: 8) {
                Text(stepTitle)
                    .font(.title2.weight(.semibold))
                Text(stepBody)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }

            stepAction

            Spacer()

            HStack(spacing: 6) {
                ForEach(0 ..< 3, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 20)
        }
        .padding(28)
        .frame(width: 460, height: 380)
        .onAppear { axTrusted = isAccessibilityTrusted() }
    }

    private var stepIcon: String {
        ["mic.fill", "accessibility", "sparkles"][step]
    }

    private var stepTitle: String {
        [
            "Whisper hears you",
            "Whisper types for you",
            "Try it",
        ][step]
    }

    private var stepBody: String {
        [
            "Your voice is transcribed entirely on this Mac. Nothing is uploaded, ever. Whisper needs the microphone to listen while you hold the hotkey.",
            "To place text at your cursor, macOS requires Accessibility permission. Turn on Whisper in the list, then come back.",
            "Open any app, click a text field, hold the hotkey and speak — release, and your words appear.",
        ][step]
    }

    @ViewBuilder
    private var stepAction: some View {
        switch step {
        case 0:
            Button(micGranted ? "Microphone allowed ✓" : "Allow Microphone") {
                Task {
                    micGranted = await requestMic()
                    if micGranted { advance() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(micGranted)
            skipButton

        case 1:
            VStack(spacing: 10) {
                Button(axTrusted ? "Accessibility enabled ✓" : "Open Accessibility Settings") {
                    promptAccessibility()
                }
                .buttonStyle(.borderedProminent)
                .disabled(axTrusted)
                Button("I've enabled it — continue") { advance() }
                    .buttonStyle(.bordered)
            }

        default:
            VStack(spacing: 12) {
                Text("⌃ Control")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                Text("Hold to talk · double-tap to lock hands-free")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Start dictating") { onDone() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var skipButton: some View {
        Button("Skip for now") { advance() }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func advance() {
        withAnimation(.snappy) { step = min(step + 1, 2) }
    }
}

#Preview {
    OnboardingView()
}
