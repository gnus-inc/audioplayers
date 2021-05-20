class AudioPosition {
  AudioPosition(this.position, this.liveStreamTime);

  final Duration position;
  final DateTime? liveStreamTime;

  @override
  String toString() => 'AudioPosition(position: $position, '
      'liveStreamTime: $liveStreamTime)';
}
