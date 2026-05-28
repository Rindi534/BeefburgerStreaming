// NowPlayingHelper.swift
//
// Setzt iOS Now-Playing-Info (Lockscreen-Karte mit Titel, Cover,
// Play/Pause + Skip-Buttons + Scrubbing-Bar) und verkabelt
// MPRemoteCommandCenter-Handler die auf den aktuellen VLCMediaPlayer
// einwirken.
//
// Aktivierung: VLCPlayerPlugin ruft `configure(...)` auf wenn ein
// Video gestartet wird, `updateState(...)` bei Position/State-Changes
// und `clear()` beim dispose.
//
// Apple-API-Details:
//   - MPNowPlayingInfoCenter: das Dictionary das im Lockscreen / im
//     Control-Center / auf der Apple-Watch erscheint.
//   - MPRemoteCommandCenter: die "Hardware"-Commands (Headphone-
//     Buttons, CarPlay, Lockscreen-Buttons). Wir registrieren
//     Handler die VLC-Calls absetzen.

import Foundation
import MediaPlayer
import MobileVLCKit
import UIKit

class NowPlayingHelper: NSObject {

    static let shared = NowPlayingHelper()

    /// Schwacher Player-Ref damit wir auf play/pause/seek-Commands
    /// reagieren können. Wird in configure() gesetzt, in clear()
    /// auf nil.
    private weak var mediaPlayer: VLCMediaPlayer?

    /// Aktueller Now-Playing-Info-Dict, mutable damit wir
    /// inkrementell Position/Rate updaten ohne alles neu zu setzen.
    private var info: [String: Any] = [:]

    /// True wenn wir die Remote-Commands schon einmal registriert
    /// haben. Idempotent halten — addTarget kann mehrmals den gleichen
    /// Handler registrieren, also vorher removeTarget(nil).
    private var commandsWired: Bool = false

    /// Callback Richtung Dart wenn der User am Lockscreen
    /// "next track" / "previous track" drückt. Plugin setzt's auf
    /// einen Event-Sink.
    var onNextTrack: (() -> Void)?
    var onPreviousTrack: (() -> Void)?

    /// Konfiguriert eine NEUE Now-Playing-Session. Ruft auf wenn
    /// ein Video geöffnet wird oder auf eine neue Folge gewechselt
    /// wird. Bisheriger State wird überschrieben.
    func configure(player: VLCMediaPlayer,
                   title: String,
                   artist: String?,
                   artworkPath: String?,
                   duration: TimeInterval) {
        self.mediaPlayer = player

        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let artist = artist, !artist.isEmpty {
            dict[MPMediaItemPropertyArtist] = artist
        }
        if let path = artworkPath,
           !path.isEmpty,
           let img = UIImage(contentsOfFile: path) {
            dict[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        self.info = dict
        MPNowPlayingInfoCenter.default().nowPlayingInfo = dict

        if !commandsWired {
            wireRemoteCommands()
            commandsWired = true
        }
    }

    /// Inkrementelles Update der Wiedergabe-Position. Sollte beim
    /// position-Event von VLC gerufen werden (5-10 Hz reicht).
    func updateState(elapsed: TimeInterval, isPlaying: Bool) {
        if info.isEmpty { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Wird beim dispose des Players gerufen. Räumt die Lockscreen-
    /// Karte ab und entfernt die Command-Handler.
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        info = [:]
        mediaPlayer = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        commandsWired = false
    }

    private func wireRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.mediaPlayer?.play()
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.mediaPlayer?.pause()
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let p = self?.mediaPlayer else { return .commandFailed }
            if p.isPlaying { p.pause() } else { p.play() }
            return .success
        }

        // ±10s Skip-Buttons am Lockscreen.
        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.preferredIntervals = [10.0]
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let player = self?.mediaPlayer else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?
                .interval ?? 10.0
            let targetMs = player.time.intValue + Int32(interval * 1000)
            player.time = VLCTime(int: max(0, targetMs))
            return .success
        }

        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.preferredIntervals = [10.0]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let player = self?.mediaPlayer else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?
                .interval ?? 10.0
            let targetMs = player.time.intValue - Int32(interval * 1000)
            player.time = VLCTime(int: max(0, targetMs))
            return .success
        }

        // Scrubbing über die Lockscreen-Progressbar.
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let player = self?.mediaPlayer,
                  let e = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            player.time = VLCTime(int: Int32(e.positionTime * 1000))
            return .success
        }

        // Next/Previous Track für Folgenwechsel — wir routen an Dart
        // weil die Episode-Liste dort verwaltet wird.
        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNextTrack?()
            return .success
        }

        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPreviousTrack?()
            return .success
        }
    }
}
