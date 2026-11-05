import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/incoming_message.dart';
import '../models/post_attachment.dart';
import '../services/identity_service.dart';
import '../services/location_service.dart';
import 'message_body.dart';

/// A verified peer identity learned from a signed announcement.
class PeerIdentity {
  final String address; // base64 Ed25519 public key
  final String x25519Base64; // base64 X25519 public key

  const PeerIdentity({required this.address, required this.x25519Base64});
}

/// Message envelope crypto for everything sent over the mesh.
///
/// Envelope: AES-256-GCM ciphertext under an X25519 ECDH shared key,
/// signed with the sender's Ed25519 identity key. Relay nodes (other
/// phones, Raspberry Pi gateways) only ever see ciphertext plus the
/// routing header (`to`, `hops`, `via`, `exp`) — never the content.
class EnvelopeCodec {
  EnvelopeCodec._();

  /// Default relay budget for an envelope.
  ///
  /// Physical distance is finite, so this is a safety valve, not a range
  /// limit. Loops are prevented by per-node dedup and the via window — not
  /// by this cap — so a huge value costs nothing on healthy paths.
  static const int defaultMaxHops = 1000;

  /// Gossip (presence + key discovery) floods more aggressively than
  /// envelopes — every fresher record re-floods to all neighbors — so its
  /// depth stays bounded. Beyond this radius, keys travel by QR exchange.
  static const int gossipMaxHops = 128;

  /// Only the most recent relayers ride in the `via` list. Dedup-by-ID at
  /// every node already prevents loops; the window just keeps envelopes
  /// small on thousand-hop paths (a full path would add ~45 B per hop).
  static const int viaWindow = 16;

  /// Network posts (mesh-local broadcasts) flood like gossip but carry
  /// content, so their radius is bounded tighter than envelopes. 64 hops
  /// still blankets a city-scale mesh.
  static const int postMaxHops = 64;

  /// Cap for post images: every node in the radius stores + re-floods the
  /// bytes, so posts stay lean (chat attachments go up to 8 MB because
  /// they travel point-to-point instead).
  static const int maxPostMediaBytes = 512 * 1024;

  /// Cap for a site page's HTML (UTF-8 bytes, inline images included), for
  /// the same reason: every device in the radius carries every page.
  static const int maxPageBytes = 96 * 1024;

  /// Files up to this size ride inside their post; bigger ones travel on
  /// request from whoever has them (BlobService).
  static const int maxInlineFileBytes = maxPostMediaBytes;

  /// Cover art embedded in a post with an audio file.
  static const int maxPostArtBytes = 64 * 1024;

  /// Network post audiences: the shared public square, or the author's own
  /// site (their public key's page in the Network browser).
  static const String scopeGlobal = 'global';
  static const String scopeSite = 'site';

  /// Valid site page path: '' (home) or lowercase segments like `blog` or
  /// `blog/day-1`.
  static final RegExp pagePathPattern =
      RegExp(r'^$|^[a-z0-9][a-z0-9_-]*(/[a-z0-9][a-z0-9_-]*)*$');

  /// How long relays keep an undeliverable envelope (store-and-forward).
  static const Duration defaultRelayLifetime = Duration(hours: 48);

  static Future<SecretKey> sharedKeyWith(String theirX25519Base64) async {
    final myKeyPair = await IdentityService.instance.getAgreementKeyPair();
    final shared = await X25519().sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(
        base64Decode(theirX25519Base64),
        type: KeyPairType.x25519,
      ),
    );
    // Hash the raw ECDH output into a uniform AES key.
    final hashed = await Sha256().hash(await shared.extractBytes());
    return SecretKey(hashed.bytes);
  }

  static Future<String> myX25519Base64() async {
    final keyPair = await IdentityService.instance.getAgreementKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  /// Builds the encrypted + signed message envelope with a relay header.
  static Future<Map<String, Object?>> encryptEnvelope({
    required String from,
    required String to,
    required String toX25519Base64,
    required MessageBody body,
  }) async {
    final sharedKey = await sharedKeyWith(toX25519Base64);
    final plaintext = utf8.encode(jsonEncode(body.toJson()));

    final algorithm = AesGcm.with256bits();
    final secretBox = await algorithm.encrypt(plaintext, secretKey: sharedKey);

    final nonceB64 = base64Encode(secretBox.nonce);
    final cipherB64 = base64Encode(secretBox.cipherText);
    final macB64 = base64Encode(secretBox.mac.bytes);
    final myX = await myX25519Base64();

    final signature = await IdentityService.instance.sign(
      utf8.encode(
          'msg|$from|$to|${body.messageId}|$nonceB64|$cipherB64|$macB64'),
    );

    final ttl = body.ttlSeconds;
    final lifetime = (ttl != null && ttl > 0)
        ? Duration(seconds: ttl) < defaultRelayLifetime
            ? Duration(seconds: ttl)
            : defaultRelayLifetime
        : defaultRelayLifetime;

    return <String, Object?>{
      't': 'msg',
      'from': from,
      'to': to,
      'fromX': myX,
      'id': body.messageId,
      'nonce': nonceB64,
      'cipher': cipherB64,
      'mac': macB64,
      'sig': base64Encode(signature.bytes),
      // Relay routing header (mutable by relays; not signed).
      'hops': 0,
      'max': defaultMaxHops,
      'via': const <String>[],
      'exp': DateTime.now().add(lifetime).millisecondsSinceEpoch,
    };
  }

  /// Verifies the signature and decrypts a received envelope.
  ///
  /// Returns null when the envelope is malformed, not addressed to
  /// [myAddress], has a bad signature, or fails to decrypt.
  static Future<IncomingMessage?> decryptEnvelope(
    Map<Object?, Object?> decoded, {
    required String myAddress,
  }) async {
    try {
      if (decoded['t'] != 'msg') return null;

      final from = decoded['from'] as String;
      final to = decoded['to'] as String;
      final fromX = decoded['fromX'] as String;
      final id = decoded['id'] as String;
      final nonceB64 = decoded['nonce'] as String;
      final cipherB64 = decoded['cipher'] as String;
      final macB64 = decoded['mac'] as String;
      final sigB64 = decoded['sig'] as String;

      if (to != myAddress) return null;

      final valid = await IdentityService.verify(
        message: utf8.encode('msg|$from|$to|$id|$nonceB64|$cipherB64|$macB64'),
        signatureBytes: base64Decode(sigB64),
        publicKeyBase64: from,
      );
      if (!valid) return null;

      final sharedKey = await sharedKeyWith(fromX);
      final plainBytes = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(cipherB64),
          nonce: base64Decode(nonceB64),
          mac: Mac(base64Decode(macB64)),
        ),
        secretKey: sharedKey,
      );

      final body = jsonDecode(utf8.decode(plainBytes)) as Map;
      return IncomingMessage(
        fromAddress: from,
        id: body['id'] as String,
        text: body['text'] as String? ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          (body['ts'] as num).toInt(),
        ),
        groupId: body['gid'] as String?,
        groupMembers: (body['members'] as List?)?.whereType<String>().toList(),
        groupAdmin: body['admin'] as String?,
        groupName: body['gname'] as String?,
        groupEvent: body['gevt'] as String?,
        action: body['act'] as String?,
        targetId: body['target'] as String?,
        ttlSeconds: (body['ttl'] as num?)?.toInt(),
        kind: body['kind'] as String?,
        mediaB64: body['media'] as String?,
        mediaName: body['mname'] as String?,
        mediaMime: body['mmime'] as String?,
        mediaTemp: body['mtemp'] == true,
        durationMs: (body['dur'] as num?)?.toInt(),
        voicemail: body['vm'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Gossip: signed presence records flooded through the mesh so devices
  // learn about nodes beyond direct radio range (feeds the Mesh Map and
  // lets senders encrypt to recipients they have not met directly).
  // -----------------------------------------------------------------------

  /// Builds my signed gossip record. [nickname] is broadcast to the mesh
  /// (like a Bluetooth device name) so nearby strangers see a friendly name.
  /// [location], when the person shares it, puts this device on everyone's
  /// Mesh Map globe. It is signed on its own (`loc|address|value`): older
  /// builds keep verifying the record as before and pass `loc` along, and
  /// no relay can move someone on the map.
  static Future<Map<String, Object?>> buildGossip({
    String? nickname,
    GeoPoint? location,
  }) async {
    final identity = IdentityService.instance;
    final address = await identity.getPublicAddressBase64();
    if (address == null || !identity.isUnlocked) {
      throw StateError('Identity must be unlocked');
    }
    final x25519 = await myX25519Base64();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final nick = nickname ?? '';
    final signature =
        await identity.sign(utf8.encode('gossip|$address|$x25519|$nick|$ts'));
    Map<String, Object?>? loc;
    if (location != null) {
      final value = location.encode();
      final locSignature =
          await identity.sign(utf8.encode('loc|$address|$value'));
      loc = <String, Object?>{
        'v': value,
        'sig': base64Encode(locSignature.bytes),
      };
    }

    return <String, Object?>{
      't': 'gossip',
      'addr': address,
      'x25519': x25519,
      'nick': nick,
      'ts': ts,
      'sig': base64Encode(signature.bytes),
      'hops': 0,
      'max': gossipMaxHops,
      if (loc != null) 'loc': loc,
    };
  }

  /// The location in a gossip record when its own signature holds.
  static Future<GeoPoint?> _verifyGossipLocation(
    Object? loc,
    String address,
  ) async {
    if (loc is! Map) return null;
    final value = loc['v'];
    final sig = loc['sig'];
    if (value is! String || sig is! String) return null;
    final point = GeoPoint.decode(value);
    if (point == null) return null;
    final valid = await IdentityService.verify(
      message: utf8.encode('loc|$address|$value'),
      signatureBytes: base64Decode(sig),
      publicKeyBase64: address,
    );
    return valid ? point : null;
  }

  /// Verifies a gossip record's signature. Returns null when invalid.
  static Future<GossipRecord?> verifyGossip(
    Map<Object?, Object?> decoded,
  ) async {
    try {
      if (decoded['t'] != 'gossip') return null;
      final addr = decoded['addr'] as String?;
      final x25519 = decoded['x25519'] as String?;
      final nick = decoded['nick'] as String? ?? '';
      final ts = (decoded['ts'] as num?)?.toInt();
      final sig = decoded['sig'] as String?;
      if (addr == null || x25519 == null || ts == null || sig == null) {
        return null;
      }

      final valid = await IdentityService.verify(
        message: utf8.encode('gossip|$addr|$x25519|$nick|$ts'),
        signatureBytes: base64Decode(sig),
        publicKeyBase64: addr,
      );
      if (!valid) return null;

      GeoPoint? location;
      try {
        location = await _verifyGossipLocation(decoded['loc'], addr);
      } catch (_) {
        // A damaged location doesn't spoil the rest of the record.
      }

      return GossipRecord(
        address: addr,
        x25519Base64: x25519,
        nickname: nick.isEmpty ? null : nick,
        tsMs: ts,
        hops: (decoded['hops'] as num?)?.toInt() ?? 0,
        location: location,
      );
    } catch (_) {
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Network posts: signed public broadcasts for everyone in the mesh
  // (the Network app's feed). Unlike envelopes they are intentionally
  // *not* encrypted — they are town-square content — but they are signed,
  // so authorship cannot be forged, and they expire.
  // -----------------------------------------------------------------------

  static String _postSigningPayload({
    required String author,
    required String id,
    required int tsMs,
    required int expMs,
    required bool deleted,
    required String kind,
    required String nick,
    required String text,
    required String mediaB64,
  }) =>
      'netpost|$author|$id|$tsMs|$expMs|${deleted ? 1 : 0}|$kind|$nick|$text|$mediaB64';

  /// Signing payload for v2 posts (site posts and pages). A JSON list
  /// keeps field boundaries unambiguous now that titles and HTML may
  /// contain any character.
  static String _postSigningPayloadV2({
    required String author,
    required String id,
    required int tsMs,
    required int expMs,
    required bool deleted,
    required String kind,
    required String nick,
    required String scope,
    required String path,
    required String title,
    required String text,
    required String mediaB64,
  }) =>
      'netpost2|${jsonEncode(<Object>[
            author,
            id,
            tsMs,
            expMs,
            deleted,
            kind,
            nick,
            scope,
            path,
            title,
            text,
            mediaB64,
          ])}';

  /// Signing payload for v3 posts (a file attached). Like v2, plus the
  /// attachment's description (signed as the exact text that travels) and
  /// its cover art.
  static String _postSigningPayloadV3({
    required String author,
    required String id,
    required int tsMs,
    required int expMs,
    required bool deleted,
    required String nick,
    required String scope,
    required String text,
    required String mediaB64,
    required String attachment,
    required String artB64,
  }) =>
      'netpost3|${jsonEncode(<Object>[
            author,
            id,
            tsMs,
            expMs,
            deleted,
            'file',
            nick,
            scope,
            text,
            mediaB64,
            attachment,
            artB64,
          ])}';

  /// Builds my signed Network post (or its deletion tombstone).
  ///
  /// Global text/image posts keep the original (v1) format so older apps
  /// still show them; site posts and pages ([pagePath] set, with the HTML
  /// in [text]) use v2; posts with a file attached use v3 (older apps skip
  /// them). For a file, [mediaB64] is the whole file when it is small
  /// enough to ride along, and [artB64] its cover art.
  static Future<Map<String, Object?>> buildNetworkPost({
    required String id,
    required String text,
    required int tsMs,
    required int expMs,
    String? mediaB64,
    String? mediaMime,
    String? nickname,
    bool deleted = false,
    String scope = scopeGlobal,
    String? pagePath,
    String? pageTitle,
    PostAttachment? attachment,
    String? artB64,
  }) async {
    final identity = IdentityService.instance;
    final address = await identity.getPublicAddressBase64();
    if (address == null || !identity.isUnlocked) {
      throw StateError('Identity must be unlocked');
    }
    final nick = nickname ?? '';
    if (attachment != null && pagePath == null) {
      final described = attachment.encode();
      final signature = await identity.sign(utf8.encode(_postSigningPayloadV3(
        author: address,
        id: id,
        tsMs: tsMs,
        expMs: expMs,
        deleted: deleted,
        nick: nick,
        scope: scope,
        text: text,
        mediaB64: mediaB64 ?? '',
        attachment: described,
        artB64: artB64 ?? '',
      )));
      return <String, Object?>{
        't': 'post',
        'v': 3,
        'id': id,
        'author': address,
        'nick': nick,
        'text': text,
        'kind': 'file',
        'scope': scope,
        'att': described,
        if (artB64 != null) 'art': artB64,
        if (mediaB64 != null) 'media': mediaB64,
        'ts': tsMs,
        'exp': expMs,
        if (deleted) 'del': true,
        'sig': base64Encode(signature.bytes),
        'hops': 0,
        'max': postMaxHops,
      };
    }
    final isPage = pagePath != null;
    final kind = isPage ? 'page' : (mediaB64 != null ? 'image' : 'text');
    final v2 = isPage || scope != scopeGlobal;
    final title = pageTitle ?? '';
    final payload = v2
        ? _postSigningPayloadV2(
            author: address,
            id: id,
            tsMs: tsMs,
            expMs: expMs,
            deleted: deleted,
            kind: kind,
            nick: nick,
            scope: scope,
            path: pagePath ?? '',
            title: title,
            text: text,
            mediaB64: mediaB64 ?? '',
          )
        : _postSigningPayload(
            author: address,
            id: id,
            tsMs: tsMs,
            expMs: expMs,
            deleted: deleted,
            kind: kind,
            nick: nick,
            text: text,
            mediaB64: mediaB64 ?? '',
          );
    final signature = await identity.sign(utf8.encode(payload));

    return <String, Object?>{
      't': 'post',
      if (v2) 'v': 2,
      'id': id,
      'author': address,
      'nick': nick,
      'text': text,
      'kind': kind,
      if (v2) 'scope': scope,
      if (isPage) 'path': pagePath,
      if (isPage && title.isNotEmpty) 'title': title,
      if (mediaB64 != null) 'media': mediaB64,
      if (mediaMime != null) 'mmime': mediaMime,
      'ts': tsMs,
      'exp': expMs,
      if (deleted) 'del': true,
      'sig': base64Encode(signature.bytes),
      'hops': 0,
      'max': postMaxHops,
    };
  }

  /// Verifies a Network post's signature. Returns null when invalid.
  static Future<VerifiedNetworkPost?> verifyNetworkPost(
    Map<Object?, Object?> decoded,
  ) async {
    try {
      if (decoded['t'] != 'post') return null;
      final id = decoded['id'] as String?;
      final author = decoded['author'] as String?;
      final nick = decoded['nick'] as String? ?? '';
      final text = decoded['text'] as String? ?? '';
      final kind = decoded['kind'] as String? ?? 'text';
      final mediaB64 = decoded['media'] as String?;
      final ts = (decoded['ts'] as num?)?.toInt();
      final exp = (decoded['exp'] as num?)?.toInt();
      final deleted = decoded['del'] == true;
      final sig = decoded['sig'] as String?;
      if (id == null ||
          author == null ||
          ts == null ||
          exp == null ||
          sig == null) {
        return null;
      }

      if (decoded['v'] == 3) {
        final scope = decoded['scope'] as String?;
        final described = decoded['att'] as String?;
        final artB64 = decoded['art'] as String?;
        if (kind != 'file' || described == null) return null;
        if (scope != scopeGlobal && scope != scopeSite) return null;
        final attachment = PostAttachment.decode(described);
        if (attachment == null) return null;
        final valid = await IdentityService.verify(
          message: utf8.encode(_postSigningPayloadV3(
            author: author,
            id: id,
            tsMs: ts,
            expMs: exp,
            deleted: deleted,
            nick: nick,
            scope: scope!,
            text: text,
            mediaB64: mediaB64 ?? '',
            attachment: described,
            artB64: artB64 ?? '',
          )),
          signatureBytes: base64Decode(sig),
          publicKeyBase64: author,
        );
        if (!valid) return null;
        return VerifiedNetworkPost(
          id: id,
          author: author,
          nickname: nick.isEmpty ? null : nick,
          text: text,
          kind: 'file',
          mediaB64: mediaB64,
          mediaMime: attachment.mime,
          tsMs: ts,
          expMs: exp,
          deleted: deleted,
          hops: (decoded['hops'] as num?)?.toInt() ?? 0,
          scope: scope,
          attachment: attachment,
          artB64: artB64,
        );
      }

      final v2 = decoded['v'] == 2;
      final scope = v2 ? decoded['scope'] as String? : scopeGlobal;
      if (scope != scopeGlobal && scope != scopeSite) return null;
      if (kind != 'text' && kind != 'image' && kind != 'page') return null;
      final isPage = kind == 'page';
      if (isPage && !v2) return null;
      final path = isPage ? (decoded['path'] as String? ?? '') : '';
      if (!pagePathPattern.hasMatch(path)) return null;
      final title = decoded['title'] as String? ?? '';

      final payload = v2
          ? _postSigningPayloadV2(
              author: author,
              id: id,
              tsMs: ts,
              expMs: exp,
              deleted: deleted,
              kind: kind,
              nick: nick,
              scope: scope!,
              path: path,
              title: title,
              text: text,
              mediaB64: mediaB64 ?? '',
            )
          : _postSigningPayload(
              author: author,
              id: id,
              tsMs: ts,
              expMs: exp,
              deleted: deleted,
              kind: kind,
              nick: nick,
              text: text,
              mediaB64: mediaB64 ?? '',
            );
      final valid = await IdentityService.verify(
        message: utf8.encode(payload),
        signatureBytes: base64Decode(sig),
        publicKeyBase64: author,
      );
      if (!valid) return null;

      return VerifiedNetworkPost(
        id: id,
        author: author,
        nickname: nick.isEmpty ? null : nick,
        text: text,
        kind: kind,
        mediaB64: mediaB64,
        mediaMime: decoded['mmime'] as String?,
        tsMs: ts,
        expMs: exp,
        deleted: deleted,
        hops: (decoded['hops'] as num?)?.toInt() ?? 0,
        scope: scope!,
        path: isPage ? path : null,
        title: title.isEmpty ? null : title,
      );
    } catch (_) {
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Bluetooth announcements (no host/port, signed over a fixed context)
  // -----------------------------------------------------------------------

  static Future<Uint8List> buildBleAnnouncementBytes() async {
    final identity = IdentityService.instance;
    final address = await identity.getPublicAddressBase64();
    if (address == null || !identity.isUnlocked) {
      throw StateError('Identity must be unlocked');
    }
    final x25519 = await myX25519Base64();
    final signature =
        await identity.sign(utf8.encode('announce|$address|$x25519|ble'));

    return Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
      't': 'announce',
      'addr': address,
      'x25519': x25519,
      'sig': base64Encode(signature.bytes),
    })));
  }

  static Future<PeerIdentity?> verifyBleAnnouncementBytes(
    Uint8List bytes,
  ) async {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map || decoded['t'] != 'announce') return null;

      final addr = decoded['addr'] as String?;
      final x25519 = decoded['x25519'] as String?;
      final sig = decoded['sig'] as String?;
      if (addr == null || x25519 == null || sig == null) return null;

      final valid = await IdentityService.verify(
        message: utf8.encode('announce|$addr|$x25519|ble'),
        signatureBytes: base64Decode(sig),
        publicKeyBase64: addr,
      );
      if (!valid) return null;

      return PeerIdentity(address: addr, x25519Base64: x25519);
    } catch (_) {
      return null;
    }
  }
}

/// A verified Network post: signed public content from someone in the
/// mesh (possibly many hops away).
class VerifiedNetworkPost {
  final String id;
  final String author;
  final String? nickname;
  final String text;
  final String kind; // 'text' | 'image' | 'page' | 'file'
  final String? mediaB64;
  final String? mediaMime;
  final int tsMs;
  final int expMs;
  final bool deleted;
  final int hops;

  /// [EnvelopeCodec.scopeGlobal] or [EnvelopeCodec.scopeSite].
  final String scope;

  /// Site pages only ('' = the author's home page).
  final String? path;
  final String? title;

  /// File posts only: what's attached, and its cover art.
  final PostAttachment? attachment;
  final String? artB64;

  const VerifiedNetworkPost({
    required this.id,
    required this.author,
    required this.nickname,
    required this.text,
    required this.kind,
    required this.mediaB64,
    required this.mediaMime,
    required this.tsMs,
    required this.expMs,
    required this.deleted,
    required this.hops,
    this.scope = EnvelopeCodec.scopeGlobal,
    this.path,
    this.title,
    this.attachment,
    this.artB64,
  });
}

/// A verified gossip record: a node somewhere in the mesh (not necessarily
/// in direct range) with its encryption key and optional public nickname.
class GossipRecord {
  final String address;
  final String x25519Base64;
  final String? nickname;
  final int tsMs;
  final int hops;

  /// Where the node says it is, when it shares that (signature checked).
  final GeoPoint? location;

  const GossipRecord({
    required this.address,
    required this.x25519Base64,
    required this.nickname,
    required this.tsMs,
    required this.hops,
    this.location,
  });
}
