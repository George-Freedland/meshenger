import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../media/progressive_player.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatDuration(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Voice notes and push-to-talk: speech needs far fewer bits than music,
/// and every clip crosses Bluetooth, so 32 kbps at 24 kHz (half of the old
/// 64 kbps). Windows' AAC encoder only does 96 kbps and up at 44.1/48 kHz
/// whatever it's asked, so it keeps the settings it accepts.
RecordConfig voiceRecordConfig() => Platform.isWindows
    ? const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        numChannels: 1,
      )
    : const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 32000,
        sampleRate: 24000,
        numChannels: 1,
      );

const _mimeByExtension = <String, String>{
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'svg': 'image/svg+xml',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/mp4',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
  'ogg': 'audio/ogg',
  'oga': 'audio/ogg',
  'opus': 'audio/ogg',
  'aif': 'audio/aiff',
  'aiff': 'audio/aiff',
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'mkv': 'video/x-matroska',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'html': 'text/html',
  'json': 'application/json',
  'zip': 'application/zip',
  'epub': 'application/epub+zip',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'apk': 'application/vnd.android.package-archive',
};

String mimeFromName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  return _mimeByExtension[name.substring(dot + 1).toLowerCase()] ??
      'application/octet-stream';
}

/// A picked media payload ready for sending or saving.
class PickedMedia {
  final Uint8List bytes;
  final String name;
  final String mime;

  const PickedMedia({
    required this.bytes,
    required this.name,
    required this.mime,
  });
}

/// Picks (and downsizes) an image from the gallery or, on phones, the
/// camera. Returns null when cancelled. Network posts pass tighter
/// [maxWidth]/[imageQuality] so broadcast payloads stay small.
Future<PickedMedia?> pickImage({
  required bool fromCamera,
  double maxWidth = 1600,
  int imageQuality = 80,
}) async {
  final picker = ImagePicker();
  final file = await picker.pickImage(
    source: fromCamera ? ImageSource.camera : ImageSource.gallery,
    maxWidth: maxWidth,
    imageQuality: imageQuality,
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return PickedMedia(
    bytes: bytes,
    name: file.name,
    mime: file.mimeType ?? mimeFromName(file.name),
  );
}

/// Whether this platform can capture with a live camera via image_picker.
bool get supportsCameraCapture => Platform.isIOS || Platform.isAndroid;

/// A file selected for P2P transfer: path + metadata only. The content is
/// never loaded into memory — transfers stream it from disk chunk by
/// chunk, which is what makes multi-GB sends possible.
class PickedFileHandle {
  final String path;
  final String name;
  final String mime;
  final int size;

  const PickedFileHandle({
    required this.path,
    required this.name,
    required this.mime,
    required this.size,
  });
}

/// Picks a file of any size for P2P transfer without reading it.
Future<PickedFileHandle?> pickFileForTransfer() async {
  final file = await openFile();
  if (file == null) return null;
  final size = await File(file.path).length();
  return PickedFileHandle(
    path: file.path,
    name: file.name,
    mime: mimeFromName(file.name),
    size: size,
  );
}

// ---------------------------------------------------------------------
// Audio playback
// ---------------------------------------------------------------------

/// Inline audio player used by chat bubbles, voice memos, and voicemail.
class AudioClipPlayer extends StatefulWidget {
  final String path;
  final int? durationMs;
  final Color? color;

  const AudioClipPlayer({
    super.key,
    required this.path,
    this.durationMs,
    this.color,
  });

  @override
  State<AudioClipPlayer> createState() => _AudioClipPlayerState();
}

class _AudioClipPlayerState extends State<AudioClipPlayer> {
  final ProgressivePlayer _player = ProgressivePlayer();

  @override
  void initState() {
    super.initState();
    _sync();
    _player.addListener(_onPlayer);
  }

  @override
  void didUpdateWidget(covariant AudioClipPlayer old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final ms = widget.durationMs;
    _player.update(
      path: widget.path,
      length: ms == null ? null : Duration(milliseconds: ms),
    );
  }

  void _onPlayer() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayer);
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() => _player.toggle();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.color ?? theme.colorScheme.primary;
    final total = _player.length ?? Duration.zero;
    final position = _player.position;
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final playing = _player.playing;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(playing ? Icons.pause_circle : Icons.play_circle,
              color: color, size: 34),
          onPressed: _toggle,
        ),
        SizedBox(
          width: 120,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                color: color,
                backgroundColor: color.withValues(alpha: 0.2),
              ),
              const SizedBox(height: 4),
              Text(
                playing || position > Duration.zero
                    ? formatDuration(position)
                    : formatDuration(total),
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Plays an audio file once (used to auto-play call audio). Returns a
/// function that stops it early; the player cleans up after itself either
/// way.
Future<Future<void> Function()> playOnce(String path) async {
  final player = Player();
  var disposed = false;
  Future<void> stop() async {
    if (disposed) return;
    disposed = true;
    await player.dispose();
  }

  player.stream.completed.listen((completed) {
    if (completed) unawaited(stop());
  });
  await player.open(Media(path));
  return stop;
}

// ---------------------------------------------------------------------
// Recording
// ---------------------------------------------------------------------

/// A recorded audio clip.
class RecordedClip {
  final Uint8List bytes;
  final int durationMs;

  const RecordedClip({required this.bytes, required this.durationMs});
}

/// Full-featured record sheet: tap to start, tap to stop, preview length,
/// send or discard. Returns null when discarded.
Future<RecordedClip?> showRecordSheet(
  BuildContext context, {
  String title = 'Record voice message',
  String sendLabel = 'Send',
}) {
  return showModalBottomSheet<RecordedClip>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (ctx) => _RecordSheet(title: title, sendLabel: sendLabel),
  );
}

class _RecordSheet extends StatefulWidget {
  final String title;
  final String sendLabel;

  const _RecordSheet({required this.title, required this.sendLabel});

  @override
  State<_RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<_RecordSheet> {
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  bool _finished = false;
  String? _error;
  String? _path;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _error = 'Microphone permission denied.');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(voiceRecordConfig(), path: path);
      _startedAt = DateTime.now();
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted && _startedAt != null) {
          setState(
              () => _elapsed = DateTime.now().difference(_startedAt!));
        }
      });
      setState(() {
        _recording = true;
        _path = path;
      });
    } catch (e) {
      setState(() => _error = 'Could not start recording: $e');
    }
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    try {
      await _recorder.stop();
    } catch (_) {}
    setState(() {
      _recording = false;
      _finished = true;
    });
  }

  Future<void> _send() async {
    final path = _path;
    if (path == null) return;
    try {
      final bytes = await File(path).readAsBytes();
      await File(path).delete();
      if (!mounted) return;
      Navigator.pop(
        context,
        RecordedClip(bytes: bytes, durationMs: _elapsed.inMilliseconds),
      );
    } catch (e) {
      setState(() => _error = 'Could not read recording: $e');
    }
  }

  Future<void> _discard() async {
    _ticker?.cancel();
    if (_recording) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
    final path = _path;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            if (_error != null) ...[
              Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 12),
              TextButton(onPressed: _discard, child: const Text('Close')),
            ] else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.mic,
                    size: 32,
                    color: _recording
                        ? Colors.redAccent
                        : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    formatDuration(_elapsed),
                    style: theme.textTheme.headlineSmall,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    onPressed: _discard,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Discard'),
                  ),
                  if (_recording)
                    FilledButton.icon(
                      onPressed: _stop,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'),
                    )
                  else if (_finished)
                    FilledButton.icon(
                      onPressed: _send,
                      icon: const Icon(Icons.send),
                      label: Text(widget.sendLabel),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Image viewing
// ---------------------------------------------------------------------

/// Full-screen image viewer.
Future<void> showImageViewer(
  BuildContext context,
  String path, {
  String? caption,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.9),
    builder: (ctx) => GestureDetector(
      onTap: () => Navigator.pop(ctx),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  child: Center(child: Image.file(File(path))),
                ),
              ),
              if (caption != null && caption.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    caption,
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
