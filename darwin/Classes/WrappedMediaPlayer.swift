import AVKit

private let defaultPlaybackRate: Float = 1.0
private let defaultVolume: Float = 1.0
private let defaultPlayingRoute = "speakers"

class WrappedMediaPlayer {
    var reference: SwiftAudioplayersPlugin
    
    var playerId: String
    var player: AVPlayer?
    
    var observers: [TimeObserver]
    var statusObservation: NSKeyValueObservation?
    var bufferEmptyObservation: NSKeyValueObservation?
    var stallTimer: Timer?

    var isPlaying: Bool
    var playbackRate: Float
    var volume: Float
    var waitForBufferFull: Bool
    var playingRoute: String
    var looping: Bool
    var url: String?
    var onReady: ((AVPlayer) -> Void)?
    var baseTime: Int? // timestamp in seconds
    var elapsedTime: CMTime?

    // (liveStreamChunkDuration is a special purpose variable and should be removed
    //  when all of HLS playlist contain DATETIME tag.)
    // At the writing time Wowza stream does not contain DATETIME tag and also
    // the length of a playlist is fixed by the server side.
    // To calculate the current playback position under this circumastance, we use
    // the chunk length of the playlist of the first loading.
    var liveStreamChunkDuration: CMTime?

    init(
        reference: SwiftAudioplayersPlugin,
        playerId: String,
        player: AVPlayer? = nil,
        observers: [TimeObserver] = [],
        
        isPlaying: Bool = false,
        playbackRate: Float = defaultPlaybackRate,
        volume: Float = defaultVolume,
        playingRoute: String = defaultPlayingRoute,
        looping: Bool = false,
        url: String? = nil,
        onReady: ((AVPlayer) -> Void)? = nil
    ) {
        self.reference = reference
        self.playerId = playerId
        self.player = player
        self.observers = observers

        self.isPlaying = isPlaying
        self.playbackRate = playbackRate
        self.volume = volume
        self.waitForBufferFull = false
        self.playingRoute = playingRoute
        self.looping = looping
        self.url = url
        self.onReady = onReady
    }
    
    func clearObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer.observer)
        }
        observers = []
    }
    
    func getDurationCMTime() -> CMTime? {
        guard let currentItem = player?.currentItem else {
            return nil
        }
        
        return currentItem.asset.duration
    }
    
    func getDuration() -> Int? {
        guard let duration = getDurationCMTime() else {
            return nil
        }
        return fromCMTime(time: duration)
    }
    
    private func getCurrentCMTime() -> CMTime? {
        guard let player = player else {
            return nil
        }
        return player.currentTime()
    }
    
    func pause() {
        isPlaying = false
        player?.pause()
    }
    
    func resume() {
        isPlaying = true
        if #available(iOS 10.0, macOS 10.12, *), !waitForBufferFull {
            player?.playImmediately(atRate: playbackRate)
        } else {
            player?.play()
        }
        
        // update last player that was used
        reference.lastPlayerId = playerId
    }
    
    func setVolume(volume: Float) {
        self.volume = volume
        player?.volume = volume
    }
    
    func setPlaybackRate(playbackRate: Float) {
        self.playbackRate = playbackRate
        player?.rate = playbackRate
        
        if let currentTime = getCurrentCMTime() {
            reference.updateNotifications(player: self, time: currentTime)
        }
    }
    
    func seek(time: CMTime) {
        guard let currentItem = player?.currentItem else {
            return
        }
        // TODO(luan) currently when you seek, the play auto-unpuses. this should set a seekTo property, similar to what WrappedMediaPlayer
        currentItem.seek(to: time) {
            finished in
            if finished {
                self.reference.updateNotifications(player: self, time: time)
            }
            self.reference.onSeekCompleted(playerId: self.playerId, finished: finished)
        }
    }
    
    func skipForward(interval: TimeInterval) {
        guard let currentTime = getCurrentCMTime() else {
            log("Cannot skip forward, unable to determine currentTime")
            return
        }
        guard let maxDuration = getDurationCMTime() else {
            log("Cannot skip forward, unable to determine maxDuration")
            return
        }
        let newTime = CMTimeAdd(currentTime, toCMTime(sec: interval))
        
        // if CMTime is more than max duration, limit it
        let clampedTime = CMTimeGetSeconds(newTime) > CMTimeGetSeconds(maxDuration) ? maxDuration : newTime
        seek(time: clampedTime)
    }
    
    func skipBackward(interval: TimeInterval) {
        guard let currentTime = getCurrentCMTime() else {
            log("Cannot skip forward, unable to determine currentTime")
            return
        }
        
        let newTime = CMTimeSubtract(currentTime, toCMTime(sec: interval))
        // if CMTime is negative, set it to zero
        let clampedTime = CMTimeGetSeconds(newTime) < 0 ? toCMTime(millis: 0) : newTime
        
        seek(time: clampedTime)
    }
    
    func stop() {
        pause()
        player?.replaceCurrentItem(with: nil)
    }
    
    func release() {
        stop()
        clearObservers()
    }
    
    func onSoundComplete() {
        if !isPlaying {
            return
        }
        
        pause()
        if looping {
            seek(time: toCMTime(millis: 0))
            resume()
        }
        
        reference.maybeDeactivateAudioSession()
        reference.onComplete(playerId: playerId)
        reference.notificationsHandler?.onNotificationBackgroundPlayerStateChanged(playerId: playerId, value: "completed")
    }
    
    func getCurrentPosition() -> Int? {
      guard let player = player else {
          return nil
      }

      if let baseTime = baseTime,
         let position = getLiveStreamProgramDateTime() {
          let liveStreamTimestamp = Int(position * 1000)
          return liveStreamTimestamp - baseTime * 1000
      }

      let time = player.currentTime()
      if let elapsedTime = elapsedTime {
          var millis = fromCMTime(time: time) + fromCMTime(time: elapsedTime)
          if let liveStreamChunkDuration = liveStreamChunkDuration {
              millis -= fromCMTime(time: liveStreamChunkDuration)
          }
          return millis
      }

      return fromCMTime(time: time)
    }

    func onTimeInterval(time: CMTime) {
        if reference.isDealloc {
            return
        }

        var liveStreamTimestamp: Int?
        let millis = { () -> Int in
            if let baseTime = baseTime,
               let position = getLiveStreamProgramDateTime() {
                liveStreamTimestamp = Int(position * 1000)
                return liveStreamTimestamp! - baseTime * 1000
            }

            if let elapsedTime = elapsedTime {
              var millis = fromCMTime(time: time) + fromCMTime(time: elapsedTime)
                if let liveStreamChunkDuration = liveStreamChunkDuration {
                    millis -= fromCMTime(time: liveStreamChunkDuration)
                }
                return millis
            }
            return fromCMTime(time: time)
        }()

        reference.onCurrentPosition(playerId: playerId, millis: millis, liveStreamTimestamp: liveStreamTimestamp)
    }

    // Read current playback timestamp based on #EXT-X-PROGRAM-DATE-TIME value in HC-AAC stream.
    func getLiveStreamProgramDateTime() -> Double? {
      guard
        let item = player?.currentItem,
        let date = item.currentDate() else { return nil }
      return date.timeIntervalSince1970;
    }

    func updateDuration() {
        guard let duration = player?.currentItem?.asset.duration else {
            return
        }
        if CMTimeGetSeconds(duration) > 0 {
            let millis = fromCMTime(time: duration)
            reference.onDuration(playerId: playerId, millis: millis)
        }
    }
    
    func setUrl(
        url: String,
        isLocal: Bool,
        isNotification: Bool,
        recordingActive: Bool,
        time: CMTime?,
        baseTime: Int?,
        elapsedTime: CMTime?,
        timeOffsetFromLive: CMTime?,
        bufferSeconds: Int?,
        followLiveWhilePaused: Bool,
        waitForBufferFull: Bool,
        onReady: @escaping (AVPlayer) -> Void
    ) {
        reference.updateCategory(recordingActive: recordingActive, isNotification: isNotification, playingRoute: playingRoute)
        let playbackStatus = player?.currentItem?.status
        self.waitForBufferFull = waitForBufferFull
        
        if self.url != url || playbackStatus == .failed || playbackStatus == nil {
            let parsedUrl = isLocal ? URL.init(fileURLWithPath: url) : URL.init(string: url)!
            let playerItem = AVPlayerItem.init(url: parsedUrl)
            playerItem.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithm.timeDomain

            if let bufferSeconds = bufferSeconds {
                playerItem.preferredForwardBufferDuration = Double(bufferSeconds)
            }
            if let timeOffsetFromLive = timeOffsetFromLive {
                playerItem.configuredTimeOffsetFromLive = timeOffsetFromLive
            } else {
                playerItem.configuredTimeOffsetFromLive = CMTime.positiveInfinity
            }
            playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = followLiveWhilePaused

            if let time = time {
              playerItem.seek(to: time, completionHandler: nil)
            }

            let player: AVPlayer
            if let existingPlayer = self.player {
                statusObservation?.invalidate()
                bufferEmptyObservation?.invalidate()
                self.url = url
                clearObservers()
                existingPlayer.replaceCurrentItem(with: playerItem)
                player = existingPlayer
            } else {
                player = AVPlayer.init(playerItem: playerItem)

                self.player = player
                self.observers = []
                self.url = url
                
                // stream player position
                let interval = toCMTime(millis: 200)
                let timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: nil) {
                    [weak self] time in
                    self!.onTimeInterval(time: time)
                }
                reference.timeObservers.append(TimeObserver(player: player, observer: timeObserver))
            }
            
            let anObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: nil
            ) {
                [weak self] (notification) in
                self!.onSoundComplete()
            }
            self.observers.append(TimeObserver(player: player, observer: anObserver))
            
            // is sound ready
            self.onReady = onReady
            self.baseTime = baseTime
            self.elapsedTime = elapsedTime
            let statusObservation = playerItem.observe(\AVPlayerItem.status) { (playerItem, change) in
                let status = playerItem.status
                log("player status: %@ change: %@", status, change)
                
                // Do something with the status...
                if status == .readyToPlay {
                    let isLiveStream = CMTIME_IS_INDEFINITE(playerItem.duration)
                    self.reference.onSeekable(playerId: self.playerId, seekable: !isLiveStream)

                    if !playerItem.seekableTimeRanges.isEmpty && self.getLiveStreamProgramDateTime() == nil {
                        self.liveStreamChunkDuration = playerItem.seekableTimeRanges.last!.timeRangeValue.duration
                    } else {
                        self.liveStreamChunkDuration = nil
                    }
                    self.updateDuration()
                    
                    if let onReady = self.onReady {
                        self.onReady = nil
                        onReady(self.player!)
                    }
                } else if status == .failed {
                    self.reference.onError(playerId: self.playerId, error: "AVPlayerItem.Status.failed")
                }
            }
            
            self.statusObservation?.invalidate()
            self.statusObservation = statusObservation

            let bufferEmptyObservation = playerItem.observe(\AVPlayerItem.isPlaybackBufferEmpty) { (playerItem, change) in
              if playerItem.isPlaybackBufferEmpty {
                self.stallTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                  self.reference.onError(playerId: self.playerId, error: "AVPlayerItem.isPlaybackBufferEmpty")
                }
              } else {
                self.stallTimer?.invalidate()
              }
            }
            self.bufferEmptyObservation?.invalidate()
            self.bufferEmptyObservation = bufferEmptyObservation
        } else {
            self.baseTime = baseTime
            self.elapsedTime = elapsedTime
            if playbackStatus == .readyToPlay {
                if let time = time {
                    player!.seek(to: time)
                } else {
                    player!.seek(to: CMTime.zero)
                }
                onReady(player!)
            }
        }
    }
    
    func play(volume: Float, time: CMTime?) {
        guard let player = player else { return }
        player.volume = volume
        if let time = time {
          player.seek(to: time)
        }
        self.resume()
        reference.lastPlayerId = playerId
    }

    func updateLiveStreamInfo(baseTime: Int?, elapsedTime: CMTime?) {
        self.baseTime = baseTime
        self.elapsedTime = elapsedTime
    }
}
