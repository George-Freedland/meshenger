import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../transport/envelope_codec.dart';
import 'identity_scope.dart';
import 'media_store.dart';
import 'peer_directory.dart';
import 'transport_log.dart';

/// Lifecycle of a peer-to-peer file transfer.
enum FtStatus {
  /// Offer sent (outgoing) or received (incoming); waiting on a human.
  offered,

  /// Receiver said yes; chunks are about to flow.
  accepted,

  /// Chunks are flowing right now.
  active,

  /// Link lost / peer offline / app restarted mid-transfer. Resumes
  /// automatically from the last confirmed chunk when both sides meet.
  paused,

  /// Every chunk confirmed; the file is complete on the receiver.
  done,

  declined,
  canceled,

  /// Unrecoverable (source file vanished, decrypt failure).
  failed,
}

/// One large-file transfer, persisted so it survives app restarts.
class FileTransfer {
  final String tid;
  final String peer; // 1:1 chat address on the other end
  final bool outgoing;
  final String name;
  final String mime;
  final int size;
  final int chunkSize;
  final int totalChunks;

  /// Watermark of durable progress, in chunks. Receiver: chunks written to
  /// disk. Sender: chunks the receiver has confirmed (via `fta` packets).
  int confirmed;

  FtStatus status;

  /// Outgoing: absolute path of the source file (never copied).
  /// Incoming: the `.part` file while running.
  String? path;

  /// Receiver only: Storage-app media id once complete.
  String? mediaId;

  final int createdMs;

  FileTransfer({
    required this.tid,
    required this.peer,
    required this.outgoing,
    required this.name,
    required this.mime,
    required this.size,
    required this.chunkSize,
    required this.totalChunks,
    required this.confirmed,
    required this.status,
    this.path,
    this.mediaId,
    required this.createdMs,
  });

  bool get isTerminal =>
      status == FtStatus.done ||
      status == FtStatus.declined ||
      status == FtStatus.canceled ||
      status == FtStatus.failed;

  double get progress =>
      totalChunks == 0 ? 0 : (confirmed / totalChunks).clamp(0.0, 1.0);

  int get transferredBytes =>
      confirmed >= totalChunks ? size : confirmed * chunkSize;

  Map<String, Object?> toJson() => <String, Object?>{
        'tid': tid,
        'peer': peer,
        'out': outgoing,
        'name': name,
        'mime': mime,
        'size': size,
        'chunk': chunkSize,
        'total': totalChunks,
        'confirmed': confirmed,
        'status': status.name,
        if (path != null) 'path': path,
        if (mediaId != null) 'mediaId': mediaId,
        'ts': createdMs,
      };

  static FileTransfer fromJson(Map<String, Object?> json) => FileTransfer(
        tid: json['tid'] as String,
        peer: json['peer'] as String,
        outgoing: json['out'] == true,
        name: json['name'] as String? ?? 'file',
        mime: json['mime'] as String? ?? 'application/octet-stream',
        size: (json['size'] as num?)?.toInt() ?? 0,
        chunkSize: (json['chunk'] as num?)?.toInt() ?? defaultLanChunk,
        totalChunks: (json['total'] as num?)?.toInt() ?? 0,
        confirmed: (json['confirmed'] as num?)?.toInt() ?? 0,
        status: FtStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => FtStatus.paused,
        ),
        path: json['path'] as String?,
        mediaId: json['mediaId'] as String?,
        createdMs: (json['ts'] as num?)?.toInt() ?? 0,
      );

  static const int defaultLanChunk = 256 * 1024;
  static const int defaultBleChunk = 24 * 1024;
}

/// Peer-to-peer large-file transfer over whatever transport is active.
///
/// Built for multi-gigabyte payloads (video clips between two PCs), which
/// the normal 8 MB message path cannot carry:
///
/// - **Streamed, never buffered**: chunks are read from / written to disk
///   with a file cursor; memory use is one chunk regardless of file size.
/// - **End-to-end encrypted per chunk**: AES-256-GCM under a key derived
///   from the X25519 shared secret and the transfer id; the chunk index is
///   the nonce, so replayed/reordered/forged chunks fail authentication.
/// - **Resumable**: the receiver's confirmed-chunk watermark is persisted;
///   after a drop or app restart the transfer continues from that offset
///   instead of starting over.
/// - **Flow-controlled**: the sender stays at most [window] chunks ahead
///   of the receiver's confirmations, so a fast sender cannot flood a slow
///   link (Bluetooth) or a pass-through relay.
///
/// Offers/accepts/cancels ride the normal encrypted store-and-forward
/// message path (they are small and must be reliable); the bulk chunks go
/// peer-to-peer — directly, or through one pass-through node (a phone or a
/// Pi gateway forwards chunks live but never spools them).
class FileTransferService {
  FileTransferService._();
  static final FileTransferService instance = FileTransferService._();

  static const _storeKey = 'file_transfers_v1';

  /// Sender may run at most this many chunks past the receiver's last
  /// confirmation before it waits (bounds pass-through relay buffering).
  static const int window = 64;

  /// Receiver confirms progress every this many chunks.
  static const int progressEvery = 16;

  /// How long the sender waits for confirmations to advance before it
  /// parks the transfer as paused.
  static const Duration progressTimeout = Duration(seconds: 60);

  static const Duration _chunkRetryDelay = Duration(milliseconds: 400);
  static const int _chunkRetries = 3;

  final _uuid = const Uuid();
  final Map<String, FileTransfer> _byId = <String, FileTransfer>{};
  final Set<String> _pumping = <String>{};

  /// Per-transfer write queue: chunk packets can arrive faster than disk
  /// writes complete, and interleaved writes would corrupt the file.
  final Map<String, Future<void>> _writeQueues = <String, Future<void>>{};
  final Map<String, RandomAccessFile> _rafs = <String, RandomAccessFile>{};
  final Map<String, SecretKey> _keys = <String, SecretKey>{};

  /// Last time a chunk landed, per transfer (receiver side) — used to
  /// tell a healthy stream from a stalled one when deciding to re-accept.
  final Map<String, int> _lastChunkMs = <String, int>{};

  /// A receiving transfer with no chunk for this long is considered
  /// stalled and re-announces its watermark when the sender reappears.
  static const Duration stallAfter = Duration(seconds: 10);

  /// Throttle for automatic resume attempts per transfer.
  final Map<String, int> _lastResumeMs = <String, int>{};

  bool _loaded = false;

  final _changed = StreamController<String>.broadcast();

  /// Emits the transfer id whenever any transfer's state moves.
  Stream<String> get onChanged => _changed.stream;

  // --- Wired by MessengerService (avoids an import cycle) ---------------
  Future<void> Function(
    String act,
    String peer,
    String tid,
    String? meta, {
    bool unique,
  })? _sendControl;
  Future<bool> Function(String peer, Map<String, Object?> packet)? _sendPacket;
  Set<String> Function()? _onlinePeers;
  int Function()? _chunkSizeForNewOffers;
  void Function(FileTransfer transfer)? _onIncomingOffer;
  void Function(FileTransfer transfer)? _onCompleted;

  void attach({
    required Future<void> Function(
      String act,
      String peer,
      String tid,
      String? meta, {
      bool unique,
    }) sendControl,
    required Future<bool> Function(String peer, Map<String, Object?> packet)
        sendPacket,
    required Set<String> Function() onlinePeers,
    required int Function() chunkSizeForNewOffers,
    void Function(FileTransfer transfer)? onIncomingOffer,
    void Function(FileTransfer transfer)? onCompleted,
  }) {
    _sendControl = sendControl;
    _sendPacket = sendPacket;
    _onlinePeers = onlinePeers;
    _chunkSizeForNewOffers = chunkSizeForNewOffers;
    _onIncomingOffer = onIncomingOffer;
    _onCompleted = onCompleted;
  }

  Future<void> detach() async {
    _sendControl = null;
    _sendPacket = null;
    _onlinePeers = null;
    _chunkSizeForNewOffers = null;
    _onIncomingOffer = null;
    _onCompleted = null;
    for (final raf in _rafs.values) {
      try {
        await raf.close();
      } catch (_) {}
    }
    _rafs.clear();
    _keys.clear();
    _byId.clear();
    _writeQueues.clear();
    _lastChunkMs.clear();
    _lastResumeMs.clear();
    _loaded = false;
  }

  // ---------------------------------------------------------------------
  // Pure helpers (unit-tested)
  // ---------------------------------------------------------------------

  static int chunkCountFor(int size, int chunkSize) =>
      size == 0 ? 0 : (size + chunkSize - 1) ~/ chunkSize;

  /// 12-byte GCM nonce for chunk [i]: zero-padded big-endian counter. The
  /// key is unique per (pair, transfer, direction), so a plain counter can
  /// never repeat under the same key.
  static Uint8List nonceForChunk(int i) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, i);
    return nonce;
  }

  /// Transfer key: SHA-256 over the X25519 shared secret and the transfer
  /// id. Both only the two endpoints can derive; pass-through nodes see
  /// ciphertext.
  static Future<SecretKey> deriveKey(
    List<int> sharedSecretBytes,
    String tid,
  ) async {
    final hashed = await Sha256().hash(<int>[
      ...sharedSecretBytes,
      ...utf8.encode('|ft|'),
      ...utf8.encode(tid),
    ]);
    return SecretKey(hashed.bytes);
  }

  // ---------------------------------------------------------------------
  // Store
  // ---------------------------------------------------------------------

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_storeKey));
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final entry in decoded.whereType<Map>()) {
        final transfer = FileTransfer.fromJson(entry.cast<String, Object?>());
        // Anything mid-flight when the app died resumes as paused.
        if (transfer.status == FtStatus.active ||
            transfer.status == FtStatus.accepted) {
          transfer.status = FtStatus.paused;
        }
        _byId[transfer.tid] = transfer;
      }
    } catch (_) {
      _byId.clear();
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_storeKey),
      jsonEncode(_byId.values.map((t) => t.toJson()).toList()),
    );
  }

  void _ping(String tid) => _changed.add(tid);

  Future<FileTransfer?> get(String tid) async {
    await _ensureLoaded();
    return _byId[tid];
  }

  Future<List<FileTransfer>> listForChat(String chatKey) async {
    await _ensureLoaded();
    return _byId.values.where((t) => t.peer == chatKey).toList()
      ..sort((a, b) => a.createdMs.compareTo(b.createdMs));
  }

  /// Transfers that are moving or waiting on someone, for badges.
  Future<int> activeCount() async {
    await _ensureLoaded();
    return _byId.values.where((t) => !t.isTerminal).length;
  }

  Future<Directory> _partDir() async {
    final fp = IdentityScope.activeFingerprint;
    if (fp == null) throw StateError('No active identity');
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/transfers/$fp');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<SecretKey> _keyFor(FileTransfer transfer) async {
    final cached = _keys[transfer.tid];
    if (cached != null) return cached;
    final peerX = await _x25519For(transfer.peer);
    if (peerX == null) {
      throw StateError('No encryption key known for this peer yet');
    }
    final shared = await EnvelopeCodec.sharedKeyWith(peerX);
    final key = await deriveKey(await shared.extractBytes(), transfer.tid);
    _keys[transfer.tid] = key;
    return key;
  }

  Future<String?> _x25519For(String peer) async =>
      (await PeerDirectory.instance.get(peer))?.x25519Base64;

  bool _isOnline(String peer) =>
      _onlinePeers?.call().contains(peer) ?? false;

  // ---------------------------------------------------------------------
  // Sender side
  // ---------------------------------------------------------------------

  /// Offers [path] to [peer]. The file is read in place — nothing is
  /// copied — so multi-GB sources cost nothing until chunks flow.
  Future<FileTransfer> offer({
    required String peer,
    required String path,
    required String name,
    required String mime,
  }) async {
    await _ensureLoaded();
    final size = await File(path).length();
    if (size == 0) throw StateError('File is empty');

    final chunkSize =
        _chunkSizeForNewOffers?.call() ?? FileTransfer.defaultLanChunk;
    final transfer = FileTransfer(
      tid: _uuid.v4(),
      peer: peer,
      outgoing: true,
      name: name,
      mime: mime,
      size: size,
      chunkSize: chunkSize,
      totalChunks: chunkCountFor(size, chunkSize),
      confirmed: 0,
      status: FtStatus.offered,
      path: path,
      createdMs: DateTime.now().millisecondsSinceEpoch,
    );
    _byId[transfer.tid] = transfer;
    await _persist();

    await _sendControl?.call(
      'ftoffer',
      peer,
      transfer.tid,
      jsonEncode(<String, Object?>{
        'tid': transfer.tid,
        'name': name,
        'mime': mime,
        'size': size,
        'chunk': chunkSize,
        'total': transfer.totalChunks,
      }),
      unique: false,
    );
    TransportLog.instance.log(
        'FT: offered "$name" (${transfer.totalChunks} chunks of '
        '$chunkSize B) to ${_short(peer)}');
    _ping(transfer.tid);
    return transfer;
  }

  /// Receiver accepted (possibly again after a drop): start/resume pumping
  /// from their watermark.
  Future<void> handleAccept(String from, String tid, int have) async {
    await _ensureLoaded();
    final transfer = _byId[tid];
    if (transfer == null || !transfer.outgoing || transfer.peer != from) {
      return;
    }
    if (transfer.isTerminal) return;
    transfer.confirmed = have.clamp(0, transfer.totalChunks);
    transfer.status = FtStatus.accepted;
    await _persist();
    _ping(tid);
    unawaited(_pump(tid));
  }

  Future<void> _pump(String tid) async {
    if (_pumping.contains(tid)) return;
    _pumping.add(tid);
    try {
      final transfer = _byId[tid];
      final path = transfer?.path;
      final send = _sendPacket;
      if (transfer == null || path == null || send == null) return;

      final source = File(path);
      if (!await source.exists()) {
        transfer.status = FtStatus.failed;
        await _persist();
        _ping(tid);
        TransportLog.instance
            .log('FT: source file for "${transfer.name}" is gone — failed');
        return;
      }

      final key = await _keyFor(transfer);
      final raf = await source.open();
      transfer.status = FtStatus.active;
      _ping(tid);
      var cursor = transfer.confirmed;
      final algorithm = AesGcm.with256bits();

      try {
        while (true) {
          if (transfer.isTerminal) return;
          if (cursor >= transfer.totalChunks) {
            // Everything sent; completion lands via the receiver's final
            // confirmation (fta / ftdone).
            return;
          }
          if (!_isOnline(transfer.peer)) {
            transfer.status = FtStatus.paused;
            await _persist();
            _ping(tid);
            return;
          }
          if (cursor - transfer.confirmed >= window) {
            // Too far ahead of the receiver — wait for confirmations.
            if (!await _awaitProgress(transfer)) {
              transfer.status = FtStatus.paused;
              await _persist();
              _ping(tid);
              return;
            }
            // The receiver may confirm past our cursor after a rewind.
            if (transfer.confirmed > cursor) cursor = transfer.confirmed;
            continue;
          }

          final offset = cursor * transfer.chunkSize;
          final length = (transfer.size - offset) < transfer.chunkSize
              ? transfer.size - offset
              : transfer.chunkSize;
          await raf.setPosition(offset);
          final plain = await raf.read(length);

          final box = await algorithm.encrypt(
            plain,
            secretKey: key,
            nonce: nonceForChunk(cursor),
          );
          final packet = <String, Object?>{
            't': 'ftc',
            'tid': tid,
            'to': transfer.peer,
            'i': cursor,
            'data': base64Encode(box.cipherText),
            'mac': base64Encode(box.mac.bytes),
          };

          var delivered = false;
          for (var attempt = 0; attempt < _chunkRetries; attempt++) {
            if (await send(transfer.peer, packet)) {
              delivered = true;
              break;
            }
            await Future<void>.delayed(_chunkRetryDelay);
          }
          if (!delivered) {
            transfer.status = FtStatus.paused;
            await _persist();
            _ping(tid);
            TransportLog.instance.log(
                'FT: link to ${_short(transfer.peer)} dropped at chunk '
                '$cursor/${transfer.totalChunks} — paused, will resume');
            return;
          }
          cursor++;
          if (transfer.confirmed > cursor) cursor = transfer.confirmed;
          if (cursor % progressEvery == 0) _ping(tid);
        }
      } finally {
        await raf.close();
      }
    } catch (e) {
      final transfer = _byId[tid];
      if (transfer != null && !transfer.isTerminal) {
        transfer.status = FtStatus.paused;
        await _persist();
        _ping(tid);
      }
      TransportLog.instance.log('FT: pump error, transfer paused: $e');
    } finally {
      _pumping.remove(tid);
    }
  }

  /// Waits until the receiver's watermark advances (or the transfer ends).
  Future<bool> _awaitProgress(FileTransfer transfer) async {
    final before = transfer.confirmed;
    final deadline = DateTime.now().add(progressTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (transfer.isTerminal) return false;
      if (transfer.confirmed > before) return true;
      if (!_isOnline(transfer.peer)) return false;
    }
    return false;
  }

  /// Progress/completion signal (`fta`) from the receiver.
  Future<void> handleProgress(Map<String, Object?> packet) async {
    await _ensureLoaded();
    final tid = packet['tid'] as String?;
    final have = (packet['have'] as num?)?.toInt();
    if (tid == null || have == null) return;
    final transfer = _byId[tid];
    if (transfer == null || !transfer.outgoing || transfer.isTerminal) return;

    // Advance-only: fta packets each ride their own connection and can
    // arrive out of order, so an older (lower) watermark is just stale.
    // Genuine rollbacks (receiver restarted and truncated its part file)
    // arrive through the reliable re-accept path instead (handleAccept).
    if (have > transfer.confirmed) {
      transfer.confirmed = have.clamp(0, transfer.totalChunks);
    }
    if (packet['ok'] == true || transfer.confirmed >= transfer.totalChunks) {
      transfer.confirmed = transfer.totalChunks;
      transfer.status = FtStatus.done;
      TransportLog.instance
          .log('FT: "${transfer.name}" fully delivered to '
              '${_short(transfer.peer)}');
    }
    await _persist();
    _ping(tid);
  }

  /// Reliable completion signal that rode the store-and-forward path.
  Future<void> handleDone(String from, String tid) async {
    await handleProgress(<String, Object?>{
      'tid': tid,
      'have': _byId[tid]?.totalChunks ?? 0,
      'ok': true,
    });
  }

  // ---------------------------------------------------------------------
  // Receiver side
  // ---------------------------------------------------------------------

  /// Incoming offer (rode the encrypted message path). Registers the
  /// transfer; the user accepts or declines from the chat bubble.
  Future<FileTransfer?> handleOffer(String from, String metaJson) async {
    await _ensureLoaded();
    try {
      final meta = jsonDecode(metaJson) as Map;
      final tid = meta['tid'] as String;
      // Store-and-forward can deliver the offer more than once; only the
      // first one creates the transfer (and the chat bubble upstream).
      if (_byId.containsKey(tid)) return null;
      final size = (meta['size'] as num).toInt();
      final chunkSize = (meta['chunk'] as num).toInt();
      if (size <= 0 || chunkSize <= 0 || chunkSize > 4 * 1024 * 1024) {
        return null;
      }
      final transfer = FileTransfer(
        tid: tid,
        peer: from,
        outgoing: false,
        name: (meta['name'] as String?)?.trim().isNotEmpty == true
            ? (meta['name'] as String).trim()
            : 'file',
        mime: meta['mime'] as String? ?? 'application/octet-stream',
        size: size,
        chunkSize: chunkSize,
        totalChunks: chunkCountFor(size, chunkSize),
        confirmed: 0,
        status: FtStatus.offered,
        createdMs: DateTime.now().millisecondsSinceEpoch,
      );
      _byId[tid] = transfer;
      await _persist();
      _ping(tid);
      _onIncomingOffer?.call(transfer);
      return transfer;
    } catch (_) {
      return null;
    }
  }

  /// User said yes (or the app is resuming after a drop): tell the sender
  /// where to start from.
  Future<void> accept(String tid) async {
    await _ensureLoaded();
    final transfer = _byId[tid];
    if (transfer == null || transfer.outgoing || transfer.isTerminal) return;

    // Close any open write handle before touching the file: accept can
    // rerun on resume, and truncating under an open handle would corrupt.
    final openRaf = _rafs.remove(tid);
    if (openRaf != null) {
      try {
        await openRaf.close();
      } catch (_) {}
    }

    // Truncate any partial file to the last durable watermark, so a chunk
    // that hit the disk but missed persistence cannot desync the offsets.
    final part = File('${(await _partDir()).path}/$tid.part');
    if (await part.exists()) {
      final wantBytes = transfer.confirmed * transfer.chunkSize;
      if (await part.length() != wantBytes) {
        final raf = await part.open(mode: FileMode.append);
        await raf.truncate(wantBytes);
        await raf.close();
      }
    } else {
      transfer.confirmed = 0;
      await part.create(recursive: true);
    }
    transfer.path = part.path;
    transfer.status = FtStatus.accepted;
    await _persist();
    _ping(tid);

    await _sendControl?.call(
      'ftaccept',
      transfer.peer,
      tid,
      jsonEncode(<String, Object?>{'tid': tid, 'have': transfer.confirmed}),
      unique: true,
    );
    TransportLog.instance.log(
        'FT: accepted "${transfer.name}" from ${_short(transfer.peer)} '
        '(resuming at chunk ${transfer.confirmed}/${transfer.totalChunks})');
  }

  /// An encrypted chunk arrived. Writes are serialized per transfer and
  /// strictly in order; anything unexpected answers with our watermark so
  /// the sender rewinds.
  Future<void> handleChunk(Map<String, Object?> packet) async {
    final tid = packet['tid'] as String?;
    if (tid == null) return;
    final previous = _writeQueues[tid] ?? Future<void>.value();
    final task = previous.then((_) => _writeChunk(packet));
    _writeQueues[tid] = task.catchError((_) {});
    await task;
  }

  Future<void> _writeChunk(Map<String, Object?> packet) async {
    await _ensureLoaded();
    final tid = packet['tid'] as String?;
    final i = (packet['i'] as num?)?.toInt();
    final dataB64 = packet['data'] as String?;
    final macB64 = packet['mac'] as String?;
    if (tid == null || i == null || dataB64 == null || macB64 == null) return;

    final transfer = _byId[tid];
    if (transfer == null ||
        transfer.outgoing ||
        transfer.isTerminal ||
        transfer.status == FtStatus.offered) {
      return;
    }

    if (i < transfer.confirmed) return; // duplicate of an old chunk
    if (i > transfer.confirmed) {
      // Gap (a pass-through node dropped one): rewind the sender.
      unawaited(_sendProgress(transfer));
      return;
    }

    try {
      final key = await _keyFor(transfer);
      final plain = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(dataB64),
          nonce: nonceForChunk(i),
          mac: Mac(base64Decode(macB64)),
        ),
        secretKey: key,
      );

      final raf = _rafs[tid] ??=
          await File(transfer.path!).open(mode: FileMode.append);
      await raf.writeFrom(plain);

      transfer.confirmed = i + 1;
      transfer.status = FtStatus.active;
      _lastChunkMs[tid] = DateTime.now().millisecondsSinceEpoch;

      final finished = transfer.confirmed >= transfer.totalChunks;
      if (finished) {
        await raf.flush();
        await raf.close();
        _rafs.remove(tid);
        await _finalize(transfer);
      } else if (transfer.confirmed % progressEvery == 0) {
        await _persist();
        unawaited(_sendProgress(transfer));
        _ping(tid);
      }
    } catch (e) {
      // A chunk that fails authentication is forged or corrupted — do not
      // advance; the sender rewinds to our watermark.
      TransportLog.instance.log('FT: chunk $i rejected: $e');
      unawaited(_sendProgress(transfer));
    }
  }

  Future<void> _sendProgress(FileTransfer transfer, {bool ok = false}) async {
    final send = _sendPacket;
    if (send == null || !_isOnline(transfer.peer)) return;
    await send(transfer.peer, <String, Object?>{
      't': 'fta',
      'tid': transfer.tid,
      'to': transfer.peer,
      'have': transfer.confirmed,
      if (ok) 'ok': true,
    });
  }

  Future<void> _finalize(FileTransfer transfer) async {
    final part = transfer.path;
    if (part == null) return;
    try {
      final item = await MediaStore.instance.adoptFile(
        part,
        name: transfer.name,
        mime: transfer.mime,
        source: MediaSource.received,
      );
      transfer.mediaId = item.id;
      transfer.path = null;
      transfer.status = FtStatus.done;
      await _persist();
      _ping(transfer.tid);

      // Instant signal plus a reliable store-and-forward one.
      unawaited(_sendProgress(transfer, ok: true));
      await _sendControl?.call('ftdone', transfer.peer, transfer.tid, null,
          unique: true);
      TransportLog.instance.log(
          'FT: "${transfer.name}" complete (${transfer.totalChunks} chunks) '
          '— saved to Storage');
      _onCompleted?.call(transfer);
    } catch (e) {
      transfer.status = FtStatus.failed;
      await _persist();
      _ping(transfer.tid);
      TransportLog.instance.log('FT: failed to finalize file: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Decline / cancel (either side) + resume triggers
  // ---------------------------------------------------------------------

  Future<void> decline(String tid) async {
    await _terminate(tid, FtStatus.declined, notifyAct: 'ftdecline');
  }

  Future<void> cancel(String tid) async {
    await _terminate(tid, FtStatus.canceled, notifyAct: 'ftcancel');
  }

  Future<void> handleDecline(String from, String tid) async {
    await _terminate(tid, FtStatus.declined, remote: from);
  }

  Future<void> handleCancel(String from, String tid) async {
    await _terminate(tid, FtStatus.canceled, remote: from);
  }

  Future<void> _terminate(
    String tid,
    FtStatus status, {
    String? notifyAct,
    String? remote,
  }) async {
    await _ensureLoaded();
    final transfer = _byId[tid];
    if (transfer == null || transfer.isTerminal) return;
    if (remote != null && transfer.peer != remote) return;
    transfer.status = status;

    final raf = _rafs.remove(tid);
    if (raf != null) {
      try {
        await raf.close();
      } catch (_) {}
    }
    // Drop a half-written incoming file.
    if (!transfer.outgoing && transfer.path != null) {
      try {
        final part = File(transfer.path!);
        if (await part.exists()) await part.delete();
      } catch (_) {}
      transfer.path = null;
    }
    await _persist();
    _ping(tid);

    if (notifyAct != null) {
      await _sendControl?.call(notifyAct, transfer.peer, tid, null,
          unique: true);
    }
  }

  /// Removes a finished/declined transfer row (history cleanup from UI).
  Future<void> remove(String tid) async {
    await _ensureLoaded();
    final transfer = _byId.remove(tid);
    if (transfer == null) return;
    await _persist();
    _ping(tid);
  }

  /// Called when peers appear: paused transfers resume by themselves when
  /// the two devices meet again. The receiver re-announces its watermark
  /// (restarting the sender's pump); a paused sender also restarts its own
  /// pump directly — whichever side noticed the drop, the transfer moves.
  Future<void> onPeersChanged(Set<String> peers) async {
    await _ensureLoaded();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final transfer in _byId.values) {
      if (transfer.isTerminal || transfer.status == FtStatus.offered) {
        continue;
      }
      if (!peers.contains(transfer.peer)) continue;
      final lastResume = _lastResumeMs[transfer.tid] ?? 0;
      if (now - lastResume < stallAfter.inMilliseconds) continue;

      if (transfer.outgoing) {
        if (transfer.status == FtStatus.paused) {
          _lastResumeMs[transfer.tid] = now;
          unawaited(_pump(transfer.tid));
        }
        continue;
      }

      // Receiver: only re-announce when the stream is NOT visibly flowing
      // — re-accepting mid-stream would truncate a healthy transfer.
      final last = _lastChunkMs[transfer.tid] ?? 0;
      final stalled = now - last > stallAfter.inMilliseconds;
      if (transfer.status == FtStatus.paused || stalled) {
        _lastResumeMs[transfer.tid] = now;
        unawaited(accept(transfer.tid)); // re-sends the watermark
      }
    }
  }

  String _short(String address) =>
      address.length <= 12 ? address : '${address.substring(0, 12)}…';
}
