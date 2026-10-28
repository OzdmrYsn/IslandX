import AppKit
import Combine
import Foundation

enum MediaSource: String, Sendable {
    case none
    case appleMusic
    case spotify

    var displayName: String {
        switch self {
        case .none: "No Media"
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        }
    }

    fileprivate var bundleIdentifier: String? {
        switch self {
        case .none: nil
        case .appleMusic: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    fileprivate static let players: [MediaSource] = [
        .appleMusic,
        .spotify
    ]
}

private struct MediaSnapshot: Sendable {
    let source: MediaSource
    let trackName: String
    let artistName: String
    let albumName: String
    let isPlaying: Bool
    let position: TimeInterval
    let duration: TimeInterval
    let artworkURL: URL?
    let trackIdentifier: String
}

private enum PlayerCommand: Sendable {
    case togglePlayPause
    case next
    case previous
    case seek(TimeInterval)
}

private enum AppleScriptBridgeError: LocalizedError {
    case couldNotCreateScript
    case executionFailed(message: String, number: Int?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .couldNotCreateScript:
            "AppleScript could not be created."
        case let .executionFailed(message, number):
            if number == -1743 {
                "Automation access was denied. Enable IslandX for Music/Spotify "
                    + "in System Settings > Privacy & Security > Automation."
            } else if number == -1742 {
                "The App Sandbox blocked media automation. Verify the Music and "
                    + "Spotify scripting-target entitlements."
            } else if let number {
                "AppleScript error \(number): \(message)"
            } else {
                "AppleScript error: \(message)"
            }
        case .invalidResponse:
            "The media player returned an invalid AppleScript response."
        }
    }
}

/// Serializes AppleScript work away from the main actor. Only Sendable value
/// types leave this actor; NSAppleScript and NSAppleEventDescriptor stay inside.
private actor AppleScriptBridge {
    func snapshot(for source: MediaSource) throws -> MediaSnapshot {
        let descriptor = try execute(scriptForSnapshot(source))
        guard descriptor.numberOfItems >= 8 else {
            throw AppleScriptBridgeError.invalidResponse
        }

        let state = string(in: descriptor, at: 4).lowercased()
        let rawIdentifier = string(in: descriptor, at: 8)
        let trackName = string(in: descriptor, at: 1)
        let artistName = string(in: descriptor, at: 2)
        let albumName = string(in: descriptor, at: 3)
        let fallbackIdentifier = [trackName, artistName, albumName]
            .joined(separator: "|")

        let artworkURLString = string(in: descriptor, at: 7)
        let artworkURL: URL?
        if let candidate = URL(string: artworkURLString),
           let scheme = candidate.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            artworkURL = candidate
        } else {
            artworkURL = nil
        }

        return MediaSnapshot(
            source: source,
            trackName: trackName,
            artistName: artistName,
            albumName: albumName,
            isPlaying: state == "playing",
            position: max(0, number(in: descriptor, at: 5)),
            duration: max(0, number(in: descriptor, at: 6)),
            artworkURL: artworkURL,
            trackIdentifier: rawIdentifier.isEmpty
                ? fallbackIdentifier
                : rawIdentifier
        )
    }

    func perform(_ command: PlayerCommand, on source: MediaSource) throws {
        guard source != .none else { return }

        let applicationIdentifier = source == .appleMusic
            ? "com.apple.Music"
            : "com.spotify.client"
        let commandText: String

        switch command {
        case .togglePlayPause:
            commandText = "playpause"
        case .next:
            commandText = "next track"
        case .previous:
            commandText = "previous track"
        case let .seek(value):
            let safeValue = value.isFinite ? max(0, value) : 0
            let literal = String(
                format: "%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                safeValue
            )
            commandText = "set player position to \(literal)"
        }

        _ = try execute(
            """
            tell application id "\(applicationIdentifier)"
                \(commandText)
            end tell
            """
        )
    }

    func systemVolume() throws -> Double {
        let descriptor = try execute(
            """
            use scripting additions
            return output volume of (get volume settings)
            """
        )
        return min(max(descriptor.doubleValue / 100, 0), 1)
    }

    func setSystemVolume(_ normalizedValue: Double) throws -> Double {
        let value = normalizedValue.isFinite ? normalizedValue : 0
        let percentage = Int((min(max(value, 0), 1) * 100).rounded())
        let descriptor = try execute(
            """
            use scripting additions
            set volume output volume \(percentage)
            if \(percentage) > 0 then set volume output muted false
            return output volume of (get volume settings)
            """
        )
        return min(max(descriptor.doubleValue / 100, 0), 1)
    }

    func appleMusicArtworkData() throws -> Data? {
        let descriptor = try execute(
            """
            if not (application id "com.apple.Music" is running) then ¬
                return {false, ""}
            tell application id "com.apple.Music"
                try
                    if (count of artworks of current track) > 0 then
                        return {true, raw data of artwork 1 of current track}
                    end if
                    return {false, ""}
                on error
                    return {false, ""}
                end try
            end tell
            """
        )

        guard
            descriptor.numberOfItems >= 2,
            descriptor.atIndex(1)?.booleanValue == true,
            let data = descriptor.atIndex(2)?.data,
            !data.isEmpty
        else {
            return nil
        }
        return data
    }

    private func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptBridgeError.couldNotCreateScript
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            throw AppleScriptBridgeError.executionFailed(
                message: message,
                number: number
            )
        }

        return result
    }

    private func string(
        in descriptor: NSAppleEventDescriptor,
        at index: Int
    ) -> String {
        descriptor.atIndex(index)?.stringValue ?? ""
    }

    private func number(
        in descriptor: NSAppleEventDescriptor,
        at index: Int
    ) -> Double {
        descriptor.atIndex(index)?.doubleValue ?? 0
    }

    private func scriptForSnapshot(_ source: MediaSource) -> String {
        switch source {
        case .appleMusic:
            return """
            tell application id "com.apple.Music"
                set stateText to (player state as text)
                try
                    set currentTrack to current track
                on error
                    return {"", "", "", stateText, 0, 0, "", ""}
                end try

                set trackName to ""
                set artistName to ""
                set albumName to ""
                set playerPosition to 0
                set trackDuration to 0
                set trackID to ""

                try
                    set trackName to name of currentTrack as text
                end try
                try
                    set artistName to artist of currentTrack as text
                end try
                try
                    set albumName to album of currentTrack as text
                end try
                try
                    set playerPosition to player position
                end try
                try
                    set trackDuration to duration of currentTrack
                end try
                try
                    set trackID to persistent ID of currentTrack as text
                end try

                return {trackName, artistName, albumName, stateText, ¬
                    playerPosition, trackDuration, "", trackID}
            end tell
            """

        case .spotify:
            return """
            tell application id "com.spotify.client"
                set stateText to (player state as text)
                try
                    set currentTrack to current track
                on error
                    return {"", "", "", stateText, 0, 0, "", ""}
                end try

                set trackName to ""
                set artistName to ""
                set albumName to ""
                set playerPosition to 0
                set trackDuration to 0
                set artworkURL to ""
                set trackID to ""

                try
                    set trackName to name of currentTrack as text
                end try
                try
                    set artistName to artist of currentTrack as text
                end try
                try
                    set albumName to album of currentTrack as text
                end try
                try
                    set playerPosition to player position
                end try
                try
                    set trackDuration to (duration of currentTrack) / 1000
                end try
                try
                    set artworkURL to artwork url of currentTrack as text
                end try
                try
                    set trackID to spotify url of currentTrack as text
                end try

                return {trackName, artistName, albumName, stateText, ¬
                    playerPosition, trackDuration, artworkURL, trackID}
            end tell
            """

        case .none:
            return "return {\"\", \"\", \"\", \"stopped\", 0, 0, \"\", \"\"}"
        }
    }
}

@MainActor
final class MediaManager: ObservableObject {
    @Published private(set) var source: MediaSource = .none
    @Published private(set) var trackName = ""
    @Published private(set) var artistName = ""
    @Published private(set) var albumName = ""
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackPosition: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var volume: Double = 0
    @Published private(set) var lastError: String?

    private let bridge = AppleScriptBridge()
    private var monitorTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var volumeWriteTask: Task<Void, Never>?
    private var isRefreshing = false
    private var artworkKey: String?
    private var volumeRevision = 0
    private var permissionRetryAfter: [MediaSource: Date] = [:]

    var hasActiveTrack: Bool {
        source != .none && !trackName.isEmpty
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()

                do {
                    try await Task<Never, Never>.sleep(
                        nanoseconds: 1_000_000_000
                    )
                } catch {
                    return
                }
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        artworkTask?.cancel()
        volumeWriteTask?.cancel()
        monitorTask = nil
        artworkTask = nil
        volumeWriteTask = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if volumeWriteTask == nil {
            do {
                volume = try await bridge.systemVolume()
            } catch {
                lastError = readableMessage(for: error)
            }
        }

        let runningPlayers = runningMediaSources()
        guard !runningPlayers.isEmpty else {
            resetMediaState()
            permissionRetryAfter.removeAll()
            lastError = nil
            return
        }

        // A denied TCC request returns -1743 immediately. Backing off keeps the
        // monitor from sending the same rejected Apple Event every second while
        // still allowing access granted in System Settings to recover at runtime.
        let now = Date()
        let eligiblePlayers = runningPlayers.filter { player in
            guard let retryDate = permissionRetryAfter[player] else {
                return true
            }
            return retryDate <= now
        }

        guard !eligiblePlayers.isEmpty else {
            resetMediaState()
            return
        }

        let orderedPlayers: [MediaSource]
        if eligiblePlayers.contains(source) {
            orderedPlayers = [source] + eligiblePlayers.filter { $0 != source }
        } else {
            orderedPlayers = eligiblePlayers
        }

        var fallbackSnapshot: MediaSnapshot?
        var selectedSnapshot: MediaSnapshot?
        var latestError: Error?

        for player in orderedPlayers {
            do {
                let snapshot = try await bridge.snapshot(for: player)
                permissionRetryAfter[player] = nil
                fallbackSnapshot = fallbackSnapshot ?? snapshot

                if snapshot.isPlaying {
                    selectedSnapshot = snapshot
                    break
                }
            } catch {
                latestError = error
                if isAutomationPermissionDenied(error) {
                    permissionRetryAfter[player] = now.addingTimeInterval(30)
                }
            }
        }

        if let snapshot = selectedSnapshot ?? fallbackSnapshot {
            lastError = nil
            apply(snapshot)
        } else if let latestError {
            resetMediaState()
            lastError = readableMessage(for: latestError)
        }
    }

    func togglePlayPause() {
        perform(.togglePlayPause)
    }

    func nextTrack() {
        perform(.next)
    }

    func previousTrack() {
        perform(.previous)
    }

    func seek(to time: TimeInterval) {
        playbackPosition = min(max(time, 0), max(duration, 0))
        perform(.seek(playbackPosition))
    }

    /// Changes the system output volume, not merely the Music/Spotify app volume.
    /// Rapid slider updates are coalesced to avoid flooding AppleScript.
    func setVolume(_ normalizedValue: Double) {
        let value = normalizedValue.isFinite ? normalizedValue : 0
        let clampedValue = min(max(value, 0), 1)
        volume = clampedValue

        volumeRevision += 1
        let revision = volumeRevision
        volumeWriteTask?.cancel()

        volumeWriteTask = Task { [weak self, bridge] in
            do {
                try await Task<Never, Never>.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else { return }
                let actualVolume = try await bridge.setSystemVolume(clampedValue)

                guard let self, self.volumeRevision == revision else { return }
                self.volume = actualVolume
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.lastError = self.readableMessage(for: error)
            }

            guard let self, self.volumeRevision == revision else { return }
            self.volumeWriteTask = nil
        }
    }

    private func perform(_ command: PlayerCommand) {
        let target = source != .none ? source : runningMediaSources().first
        guard let target, target != .none else { return }

        Task { [weak self, bridge] in
            do {
                try await bridge.perform(command, on: target)
                self?.permissionRetryAfter[target] = nil
                try await Task<Never, Never>.sleep(nanoseconds: 120_000_000)
                await self?.refresh()
            } catch {
                if self?.isAutomationPermissionDenied(error) == true {
                    self?.permissionRetryAfter[target] = Date()
                        .addingTimeInterval(30)
                }
                self?.lastError = self?.readableMessage(for: error)
            }
        }
    }

    private func apply(_ snapshot: MediaSnapshot) {
        source = snapshot.source
        trackName = snapshot.trackName
        artistName = snapshot.artistName
        albumName = snapshot.albumName
        isPlaying = snapshot.isPlaying
        playbackPosition = min(snapshot.position, max(snapshot.duration, 0))
        duration = snapshot.duration

        let nextArtworkKey = [
            snapshot.source.rawValue,
            snapshot.trackIdentifier
        ].joined(separator: "|")

        guard artworkKey != nextArtworkKey else { return }
        artworkKey = nextArtworkKey
        artwork = nil
        loadArtwork(for: snapshot, key: nextArtworkKey)
    }

    private func loadArtwork(for snapshot: MediaSnapshot, key: String) {
        artworkTask?.cancel()

        artworkTask = Task { [weak self, bridge] in
            let data: Data?

            do {
                switch snapshot.source {
                case .appleMusic:
                    data = try await bridge.appleMusicArtworkData()
                case .spotify:
                    guard let url = snapshot.artworkURL else { return }
                    let (downloadedData, response) = try await URLSession.shared
                        .data(from: url)

                    if let httpResponse = response as? HTTPURLResponse,
                       !(200..<300).contains(httpResponse.statusCode) {
                        return
                    }
                    data = downloadedData.count <= 10_000_000
                        ? downloadedData
                        : nil
                case .none:
                    data = nil
                }
            } catch {
                return
            }

            guard
                !Task.isCancelled,
                let self,
                self.artworkKey == key,
                let data,
                let image = NSImage(data: data)
            else {
                return
            }

            self.artwork = image
        }
    }

    private func runningMediaSources() -> [MediaSource] {
        MediaSource.players.filter { source in
            guard let bundleIdentifier = source.bundleIdentifier else {
                return false
            }
            return !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).isEmpty
        }
    }

    private func resetMediaState() {
        source = .none
        trackName = ""
        artistName = ""
        albumName = ""
        artwork = nil
        isPlaying = false
        playbackPosition = 0
        duration = 0
        artworkKey = nil
    }

    private func readableMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let message = localizedError.errorDescription {
            return message
        }
        return error.localizedDescription
    }

    private func isAutomationPermissionDenied(_ error: Error) -> Bool {
        guard case let AppleScriptBridgeError.executionFailed(_, number) = error
        else {
            return false
        }
        return number == -1743 || number == -1742
    }
}
