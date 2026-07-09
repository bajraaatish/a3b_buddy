//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    /// AppKit coordinates (bottom-left origin) — the space `NSEvent.mouseLocation`,
    /// `NSScreen.frame`, and the overlay window all live in. Capture sources hand
    /// back Core Graphics rects (`SCDisplay.frame`, `SCWindow.frame`), so they must
    /// be flipped before they land here.
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int

    /// Maps a point in the screenshot's pixel space — top-left origin, which is
    /// what Claude sees and what a `[POINT:x,y]` tag is expressed in — to the
    /// global AppKit point the buddy should fly to.
    func globalAppKitPoint(forScreenshotPixel screenshotPixel: CGPoint) -> CGPoint {
        let screenshotWidth = CGFloat(screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenshotHeightInPixels)
        guard screenshotWidth > 0, screenshotHeight > 0 else { return displayFrame.origin }

        let clampedX = max(0, min(screenshotPixel.x, screenshotWidth))
        let clampedY = max(0, min(screenshotPixel.y, screenshotHeight))

        // Screenshot pixels → display points (e.g. 1280x831 → 1512x982).
        let displayWidth = CGFloat(displayWidthInPoints)
        let displayHeight = CGFloat(displayHeightInPoints)
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

        // Top-left origin → bottom-left origin, then display-local → global.
        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: (displayHeight - displayLocalY) + displayFrame.origin.y
        )
    }
}

@MainActor
enum CompanionScreenCaptureUtility {

    static func captureScreensAsJPEG(
        mode: CompanionCaptureMode,
        privacyGate: CompanionCapturePrivacyGate = CompanionCapturePrivacyGate(),
        auditLogger: SentFrameAuditLogger = SentFrameAuditLogger()
    ) async throws -> CompanionScreenCaptureResult {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        switch privacyGate.evaluate(frontmostBundleIdentifier: frontmostBundleIdentifier) {
        case .allowed:
            break
        case .blocked(let captureBlock):
            print("CAPTURE_BLOCKED bundle_id=\(captureBlock.bundleIdentifier) rule=\(captureBlock.matchedRule)")
            return .blocked(captureBlock)
        }

        let capturedScreens: [CompanionScreenCapture]
        switch mode {
        case .activeWindow:
            capturedScreens = try await captureActiveWindowAsJPEG(
                frontmostBundleIdentifier: frontmostBundleIdentifier
            )
        case .fullScreen:
            capturedScreens = try await captureFullScreensAsJPEG()
        }

        for capturedScreen in capturedScreens {
            try auditLogger.saveSentFrame(
                imageData: capturedScreen.imageData,
                captureMode: mode,
                sourceIdentifier: capturedScreen.label
            )
        }

        print("CAPTURE_ALLOWED bundle_id=\(frontmostBundleIdentifier ?? "unknown") mode=\(mode.rawValue)")
        CompanionCaptureIndicatorNotifier.postCaptureSucceeded(mode: mode)
        return .captured(capturedScreens)
    }

    /// `SCWindow.frame` and `SCDisplay.frame` are Core Graphics rects: origin at the
    /// top-left of the primary display, y growing downward. Flip about the primary
    /// display's top edge to get the AppKit rect `CompanionScreenCapture.displayFrame`
    /// promises.
    private static func appKitFrame(fromCoreGraphicsRect coreGraphicsRect: CGRect) -> CGRect {
        // `NSScreen.screens[0]` is the origin screen, so its frame's origin is (0, 0).
        guard let primaryScreen = NSScreen.screens.first else { return coreGraphicsRect }
        return CGRect(
            x: coreGraphicsRect.origin.x,
            y: primaryScreen.frame.maxY - coreGraphicsRect.maxY,
            width: coreGraphicsRect.width,
            height: coreGraphicsRect.height
        )
    }

    private static func captureFullScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in A3BBuddyOverlayView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? appKitFrame(fromCoreGraphicsRect: CGRect(
                    x: display.frame.origin.x, y: display.frame.origin.y,
                    width: CGFloat(display.width), height: CGFloat(display.height)
                ))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    private static func captureActiveWindowAsJPEG(
        frontmostBundleIdentifier: String?
    ) async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let frontmostBundleIdentifier, !frontmostBundleIdentifier.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "No frontmost app available for capture"])
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let matchingWindows = content.windows.filter { window in
            guard window.owningApplication?.bundleIdentifier == frontmostBundleIdentifier else {
                return false
            }
            guard window.owningApplication?.bundleIdentifier != ownBundleIdentifier else {
                return false
            }
            return window.frame.width > 1 && window.frame.height > 1
        }

        guard let activeWindow = matchingWindows.first else {
            throw NSError(domain: "CompanionScreenCapture", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "No capturable active window found"])
        }

        let filter = SCContentFilter(desktopIndependentWindow: activeWindow)

        let configuration = SCStreamConfiguration()
        let maxDimension = 1280
        let windowWidth = max(Int(activeWindow.frame.width), 1)
        let windowHeight = max(Int(activeWindow.frame.height), 1)
        let aspectRatio = CGFloat(windowWidth) / CGFloat(windowHeight)
        if windowWidth >= windowHeight {
            configuration.width = maxDimension
            configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
        } else {
            configuration.height = maxDimension
            configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
        }

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "CompanionScreenCapture", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode active window capture"])
        }

        let windowTitle = activeWindow.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let windowLabelSuffix = windowTitle?.isEmpty == false ? " - \(windowTitle!)" : ""
        let windowLabel = "active window only\(windowLabelSuffix)"

        return [CompanionScreenCapture(
            imageData: jpegData,
            label: windowLabel,
            isCursorScreen: true,
            displayWidthInPoints: windowWidth,
            displayHeightInPoints: windowHeight,
            displayFrame: appKitFrame(fromCoreGraphicsRect: activeWindow.frame),
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )]
    }
}
