import AVKit

private let defaultPlaybackRate: Float = 1.0
private let defaultVolume: Float = 1.0
private let defaultPlayingRoute = "speakers"

class WrappedMediaPlayer {
    var reference: SwiftAudioplayersPlugin
    
    var playerId: String
    var player: AVPlayer?
    
    var observers: [TimeObserver]
    var keyVakueObservation: NSKeyValueObservation?
    
    var isPlaying: Bool
    var playbackRate: Float
    var volume: Float
    var playingRoute: String
    var looping: Bool
    var url: String?
    var onReady: ((AVPlayer) -> Void)?
    
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
        self.keyVakueObservation = nil
        
        self.isPlaying = isPlaying
        self.playbackRate = playbackRate
        self.volume = volume
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
    
    func getCurrentPosition() -> Int? {
        guard let time = getCurrentCMTime() else {
            return nil
        }
        return fromCMTime(time: time)
    }
    
    func pause() {
        isPlaying = false
        player?.pause()
    }
    
    func resume() {
        isPlaying = true
        if #available(iOS 10.0, macOS 10.12, *) {
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
        isPlaying = false
        seek(time: toCMTime(millis: 0))
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
    
    func onTimeInterval(time: CMTime) {
        if reference.isDealloc {
            return
        }
        let millis = fromCMTime(time: time)
        reference.onCurrentPosition(playerId: playerId, millis: millis)
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
        bufferSeconds: Int,
        onReady: @escaping (AVPlayer) -> Void
    ) {
        reference.updateCategory(recordingActive: recordingActive, isNotification: isNotification, playingRoute: playingRoute)
        let playbackStatus = player?.currentItem?.status
        
        if self.url != url || playbackStatus == .failed || playbackStatus == nil {
            let parsedUrl = isLocal ? URL.init(fileURLWithPath: url) : URL.init(string: url)!
            let playerItem = AVPlayerItem.init(url: parsedUrl)
            playerItem.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithm.timeDomain
            if #available(iOS 10.0, *) {
                playerItem.preferredForwardBufferDuration = Double(bufferSeconds)
            }

            if let time = time {
                playerItem.seek(to: time)
            } else {
                playerItem.seek(to: CMTime.zero)
            }

            let player: AVPlayer
            if let existingPlayer = self.player {
                keyVakueObservation?.invalidate()
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
                let interval = toCMTime(millis: 0.2)
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
            let newKeyValueObservation = playerItem.observe(\AVPlayerItem.status) { (playerItem, change) in
                let status = playerItem.status
                log("player status: %@ change: %@", status, change)
                
                // Do something with the status...
                if status == .readyToPlay {
                    self.updateDuration()
                    
                    if let onReady = self.onReady {
                        self.onReady = nil
                        onReady(self.player!)
                    }
                } else if status == .failed {
                    self.reference.onError(playerId: self.playerId)
                }
            }
            
            keyVakueObservation?.invalidate()
            keyVakueObservation = newKeyValueObservation
        } else {
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
    
    func play(
        url: String,
        isLocal: Bool,
        volume: Float,
        time: CMTime?,
        isNotification: Bool,
        recordingActive: Bool,
        bufferSeconds: Int
    ) {
        reference.updateCategory(recordingActive: recordingActive, isNotification: isNotification, playingRoute: playingRoute)
        
        setUrl(
            url: url,
            isLocal: isLocal,
            isNotification: isNotification,
            recordingActive: recordingActive,
            time: time,
            bufferSeconds: bufferSeconds
        ) {
            player in
            player.volume = volume
            self.resume()
        }
        
        reference.lastPlayerId = playerId
    }
}
