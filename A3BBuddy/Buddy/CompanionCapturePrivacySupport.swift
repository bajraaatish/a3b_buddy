//
//  CompanionCapturePrivacySupport.swift
//  leanring-buddy
//
//  Privacy gate, exclusion-list storage, capture audit logging, and the
//  capture indicator notification used by the companion screenshot pipeline.
//

import AppKit
import Foundation

enum CompanionCaptureMode: String, Codable, CaseIterable {
    case activeWindow
    case fullScreen
}

struct CompanionCaptureBlock {
    let bundleIdentifier: String
    let matchedRule: String
}

enum CompanionCapturePrivacyDecision {
    case allowed
    case blocked(CompanionCaptureBlock)
}

enum CompanionScreenCaptureResult {
    case captured([CompanionScreenCapture])
    case blocked(CompanionCaptureBlock)
}

struct CompanionCaptureExclusionConfiguration: Codable {
    var schemaVersion: Int
    var blockedBundleIdentifiers: [String]
    var blockedBundleIdentifierPrefixes: [String]
}

final class CompanionCaptureExclusionList {
    private let configurationURL: URL
    private let fileManager: FileManager

    init(
        configurationURL: URL = CompanionCaptureExclusionList.defaultConfigurationURL(),
        fileManager: FileManager = .default
    ) {
        self.configurationURL = configurationURL
        self.fileManager = fileManager
    }

    func loadConfiguration() throws -> CompanionCaptureExclusionConfiguration {
        try writeDefaultConfigurationIfMissing()

        let configurationData = try Data(contentsOf: configurationURL)
        return try JSONDecoder().decode(
            CompanionCaptureExclusionConfiguration.self,
            from: configurationData
        )
    }

    private func writeDefaultConfigurationIfMissing() throws {
        guard !fileManager.fileExists(atPath: configurationURL.path) else { return }

        let directoryURL = configurationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let defaultConfiguration = CompanionCaptureExclusionConfiguration(
            schemaVersion: 1,
            blockedBundleIdentifiers: [
                "com.1password.1password",
                "com.agilebits.onepassword7",
                "com.bitwarden.desktop",
                "com.apple.keychainaccess",
                "com.apple.MobileSMS",
                "com.apple.mail"
            ],
            blockedBundleIdentifierPrefixes: [
                "com.bank",
                "com.chase",
                "com.wellsfargo",
                "com.citi"
            ]
        )

        let encodedConfiguration = try JSONEncoder.prettyPrinted.encode(defaultConfiguration)
        try encodedConfiguration.write(to: configurationURL, options: .atomic)
    }

    private static func defaultConfigurationURL() -> URL {
        return applicationSupportDirectory()
            .appendingPathComponent("capture-exclusions.json", isDirectory: false)
    }

    static func applicationSupportDirectory() -> URL {
        if let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            return applicationSupportDirectory
                .appendingPathComponent("a3b-buddy", isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/a3b-buddy", isDirectory: true)
    }
}

struct CompanionCapturePrivacyGate {
    private let exclusionList: CompanionCaptureExclusionList

    init(exclusionList: CompanionCaptureExclusionList = CompanionCaptureExclusionList()) {
        self.exclusionList = exclusionList
    }

    func evaluate(frontmostBundleIdentifier: String?) -> CompanionCapturePrivacyDecision {
        guard let frontmostBundleIdentifier, !frontmostBundleIdentifier.isEmpty else {
            return .blocked(CompanionCaptureBlock(
                bundleIdentifier: "unknown",
                matchedRule: "no-frontmost-application"
            ))
        }

        do {
            let configuration = try exclusionList.loadConfiguration()

            if configuration.blockedBundleIdentifiers.contains(frontmostBundleIdentifier) {
                return .blocked(CompanionCaptureBlock(
                    bundleIdentifier: frontmostBundleIdentifier,
                    matchedRule: "bundle-id:\(frontmostBundleIdentifier)"
                ))
            }

            if let blockedPrefix = configuration.blockedBundleIdentifierPrefixes.first(where: {
                frontmostBundleIdentifier.hasPrefix($0)
            }) {
                return .blocked(CompanionCaptureBlock(
                    bundleIdentifier: frontmostBundleIdentifier,
                    matchedRule: "bundle-prefix:\(blockedPrefix)"
                ))
            }

            return .allowed
        } catch {
            return .blocked(CompanionCaptureBlock(
                bundleIdentifier: frontmostBundleIdentifier,
                matchedRule: "exclusion-list-error:\(error.localizedDescription)"
            ))
        }
    }
}

final class SentFrameAuditLogger {
    let sentFramesDirectoryURL: URL
    private let fileManager: FileManager

    init(
        sentFramesDirectoryURL: URL = CompanionCaptureExclusionList.applicationSupportDirectory()
            .appendingPathComponent("sent-frames", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.sentFramesDirectoryURL = sentFramesDirectoryURL
        self.fileManager = fileManager
    }

    @discardableResult
    func saveSentFrame(
        imageData: Data,
        captureMode: CompanionCaptureMode,
        sourceIdentifier: String
    ) throws -> URL {
        try fileManager.createDirectory(
            at: sentFramesDirectoryURL,
            withIntermediateDirectories: true
        )
        try pruneFramesOlderThanThirtyDays()

        let fileURL = sentFramesDirectoryURL
            .appendingPathComponent(Self.fileName(
                captureMode: captureMode,
                sourceIdentifier: sourceIdentifier
            ))
        try imageData.write(to: fileURL, options: .atomic)
        print("SENT_FRAME_SAVED path=\(fileURL.path)")
        return fileURL
    }

    func pruneFramesOlderThanThirtyDays() throws {
        let cutoffDate = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let frameFileURLs = try fileManager.contentsOfDirectory(
            at: sentFramesDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var removedCount = 0
        var keptCount = 0

        for frameFileURL in frameFileURLs {
            let resourceValues = try frameFileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let modificationDate = resourceValues.contentModificationDate ?? Date()
            if modificationDate < cutoffDate {
                try fileManager.removeItem(at: frameFileURL)
                removedCount += 1
            } else {
                keptCount += 1
            }
        }

        print("SENT_FRAME_PRUNE removed=\(removedCount) kept=\(keptCount)")
    }

    private static func fileName(
        captureMode: CompanionCaptureMode,
        sourceIdentifier: String
    ) -> String {
        let timestamp = SentFrameAuditLogger.timestampFormatter.string(from: Date())
        let sanitizedSourceIdentifier = sourceIdentifier
            .replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
        return "\(timestamp)-\(captureMode.rawValue)-\(sanitizedSourceIdentifier).jpg"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}

@MainActor
enum SentFramesFolderOpener {
    static func openSentFramesFolder(
        auditLogger: SentFrameAuditLogger = SentFrameAuditLogger()
    ) {
        try? FileManager.default.createDirectory(
            at: auditLogger.sentFramesDirectoryURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([auditLogger.sentFramesDirectoryURL])
    }
}

extension Notification.Name {
    static let companionCaptureDidSucceed = Notification.Name("CompanionCaptureDidSucceed")
}

@MainActor
enum CompanionCaptureIndicatorNotifier {
    static func postCaptureSucceeded(mode: CompanionCaptureMode) {
        NotificationCenter.default.post(
            name: .companionCaptureDidSucceed,
            object: nil,
            userInfo: ["mode": mode.rawValue]
        )
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
