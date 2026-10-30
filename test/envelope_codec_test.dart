import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/core/services/identity_service.dart';
import 'package:meshenger/core/transport/envelope_codec.dart';
import 'package:meshenger/core/transport/message_body.dart';

/// End-to-end crypto tests for the mesh envelope: what leaves Alice's
/// device, what a relay may touch, and what only Bob can open.
void main() {
  late SimpleKeyPair alice;
  late SimpleKeyPair bob;
  late SimpleKeyPair carol; // an untrusted relay in the middle
  late String aliceAddress;
  late String bobAddress;
  late String bobX25519;

  Future<String> x25519Of(SimpleKeyPair identity) async {
    // Same deterministic derivation the app uses.
    final seed = await identity.extractPrivateKeyBytes();
    final derived = await Sha256().hash(<int>[
      ...utf8.encode('meshenger-x25519-v1'),
      ...seed,
    ]);
    final keyPair = await X25519().newKeyPairFromSeed(derived.bytes);
    return base64Encode((await keyPair.extractPublicKey()).bytes);
  }

  Future<void> unlockAs(SimpleKeyPair identity) =>
      IdentityService.instance.debugUnlockWithKeyPair(identity);

  setUpAll(() async {
    final ed25519 = Ed25519();
    alice = await ed25519.newKeyPair();
    bob = await ed25519.newKeyPair();
    carol = await ed25519.newKeyPair();
    aliceAddress =
        base64Encode((await alice.extractPublicKey()).bytes);
    bobAddress = base64Encode((await bob.extractPublicKey()).bytes);
    bobX25519 = await x25519Of(bob);
  });

  Future<Map<String, Object?>> aliceSendsToBob(MessageBody body) async {
    await unlockAs(alice);
    return EnvelopeCodec.encryptEnvelope(
      from: aliceAddress,
      to: bobAddress,
      toX25519Base64: bobX25519,
      body: body,
    );
  }

  group('envelope round trip', () {
    test('Bob decrypts text, media flags, and ttl intact', () async {
      final sentAt = DateTime.fromMillisecondsSinceEpoch(1755600000000);
      final envelope = await aliceSendsToBob(MessageBody(
        messageId: 'm-1',
        text: 'meet at the shed',
        timestamp: sentAt,
        ttlSeconds: 3600,
        kind: 'image',
        mediaB64: base64Encode(utf8.encode('fake-jpeg-bytes')),
        mediaName: 'photo.jpg',
        mediaMime: 'image/jpeg',
        mediaTemp: true,
        voicemail: false,
      ));

      await unlockAs(bob);
      final incoming = await EnvelopeCodec.decryptEnvelope(
        envelope,
        myAddress: bobAddress,
      );

      expect(incoming, isNotNull);
      expect(incoming!.fromAddress, aliceAddress);
      expect(incoming.id, 'm-1');
      expect(incoming.text, 'meet at the shed');
      expect(incoming.timestamp, sentAt);
      expect(incoming.ttlSeconds, 3600);
      expect(incoming.kind, 'image');
      expect(utf8.decode(base64Decode(incoming.mediaB64!)),
          'fake-jpeg-bytes');
      expect(incoming.mediaName, 'photo.jpg');
      expect(incoming.mediaMime, 'image/jpeg');
      expect(incoming.mediaTemp, isTrue);
    });

    test('envelope carries a relay header with sane defaults', () async {
      final envelope = await aliceSendsToBob(MessageBody(
        messageId: 'm-2',
        text: 'hop budget check',
        timestamp: DateTime.now(),
      ));

      expect(envelope['t'], 'msg');
      expect(envelope['hops'], 0);
      expect(envelope['max'], EnvelopeCodec.defaultMaxHops);
      expect(envelope['via'], isEmpty);
      final exp = envelope['exp'] as int;
      expect(exp, greaterThan(DateTime.now().millisecondsSinceEpoch));
      expect(
        exp,
        lessThanOrEqualTo(DateTime.now()
            .add(EnvelopeCodec.defaultRelayLifetime)
            .millisecondsSinceEpoch),
      );
    });

    test('short message ttl caps the relay lifetime', () async {
      final envelope = await aliceSendsToBob(MessageBody(
        messageId: 'm-3',
        text: 'disappears in 30s',
        timestamp: DateTime.now(),
        ttlSeconds: 30,
      ));
      final exp = envelope['exp'] as int;
      expect(
        exp,
        lessThanOrEqualTo(DateTime.now()
            .add(const Duration(seconds: 31))
            .millisecondsSinceEpoch),
      );
    });
  });

  group('relay security model', () {
    test('a relay (Carol) cannot decrypt an envelope for Bob', () async {
      final envelope = await aliceSendsToBob(MessageBody(
        messageId: 'm-4',
        text: 'not for carol',
        timestamp: DateTime.now(),
      ));

      await unlockAs(carol);
      final asCarol = await EnvelopeCodec.decryptEnvelope(
        envelope,
        myAddress: base64Encode((await carol.extractPublicKey()).bytes),
      );
      expect(asCarol, isNull, reason: 'not addressed to Carol');

      // Even if Carol lies about her address, ECDH fails without Bob's key.
      final asFakeBob = await EnvelopeCodec.decryptEnvelope(
        envelope,
        myAddress: bobAddress,
      );
      expect(asFakeBob, isNull,
          reason: 'wrong X25519 key -> AES-GCM MAC failure');
    });

    test('relay-mutated routing header still decrypts for Bob', () async {
      final envelope = await aliceSendsToBob(MessageBody(
        messageId: 'm-5',
        text: 'three hops later',
        timestamp: DateTime.now(),
      ));

      // What every relay does: bump hops, append itself to via.
      final relayed = Map<String, Object?>.from(envelope);
      relayed['hops'] = 3;
      relayed['via'] = ['relay-1', 'relay-2', 'relay-3'];

      await unlockAs(bob);
      final incoming = await EnvelopeCodec.decryptEnvelope(
        relayed,
        myAddress: bobAddress,
      );
      expect(incoming, isNotNull);
      expect(incoming!.text, 'three hops later');
    });

    test('tampered ciphertext or forged sender is rejected', () async {
      final envelope = await aliceSendsToBob(MessageBody(
        messageId: 'm-6',
        text: 'integrity check',
        timestamp: DateTime.now(),
      ));

      await unlockAs(bob);

      final flipped = Map<String, Object?>.from(envelope);
      final cipher = base64Decode(flipped['cipher'] as String);
      cipher[0] ^= 0xff;
      flipped['cipher'] = base64Encode(cipher);
      expect(
        await EnvelopeCodec.decryptEnvelope(flipped, myAddress: bobAddress),
        isNull,
        reason: 'signature over ciphertext must fail',
      );

      final impersonated = Map<String, Object?>.from(envelope);
      impersonated['from'] =
          base64Encode((await carol.extractPublicKey()).bytes);
      expect(
        await EnvelopeCodec.decryptEnvelope(
          impersonated,
          myAddress: bobAddress,
        ),
        isNull,
        reason: 'signature was made by Alice, not the claimed sender',
      );
    });
  });

  group('gossip', () {
    test('signed gossip verifies and carries key + nickname', () async {
      await unlockAs(alice);
      final gossip = await EnvelopeCodec.buildGossip(nickname: 'Alice');

      final record = await EnvelopeCodec.verifyGossip(gossip);
      expect(record, isNotNull);
      expect(record!.address, aliceAddress);
      expect(record.nickname, 'Alice');
      expect(record.x25519Base64, await x25519Of(alice));
    });

    test('tampered gossip (nickname or key swap) is rejected', () async {
      await unlockAs(alice);
      final gossip = await EnvelopeCodec.buildGossip(nickname: 'Alice');

      final renamed = Map<String, Object?>.from(gossip);
      renamed['nick'] = 'Mallory';
      expect(await EnvelopeCodec.verifyGossip(renamed), isNull);

      final keySwapped = Map<String, Object?>.from(gossip);
      keySwapped['x25519'] = await x25519Of(carol);
      expect(await EnvelopeCodec.verifyGossip(keySwapped), isNull,
          reason: 'swapping in an attacker key must break the signature');
    });
  });

  group('network posts', () {
    test('signed post round-trips with media and survives relay hops',
        () async {
      await unlockAs(alice);
      final now = DateTime.now().millisecondsSinceEpoch;
      final packet = await EnvelopeCodec.buildNetworkPost(
        id: 'post-1',
        text: 'accident on 5th & main',
        tsMs: now,
        expMs: now + 3600000,
        mediaB64: base64Encode(utf8.encode('fake-photo')),
        mediaMime: 'image/jpeg',
        nickname: 'Alice',
      );

      expect(packet['t'], 'post');
      expect(packet['max'], EnvelopeCodec.postMaxHops);

      // Relays bump hops without breaking the author signature.
      final relayed = Map<String, Object?>.from(packet);
      relayed['hops'] = 12;

      final verified = await EnvelopeCodec.verifyNetworkPost(relayed);
      expect(verified, isNotNull);
      expect(verified!.author, aliceAddress);
      expect(verified.nickname, 'Alice');
      expect(verified.text, 'accident on 5th & main');
      expect(verified.kind, 'image');
      expect(utf8.decode(base64Decode(verified.mediaB64!)), 'fake-photo');
      expect(verified.mediaMime, 'image/jpeg');
      expect(verified.deleted, isFalse);
      expect(verified.hops, 12);
    });

    test('deletion tombstone verifies and flags deleted', () async {
      await unlockAs(alice);
      final now = DateTime.now().millisecondsSinceEpoch;
      final tombstone = await EnvelopeCodec.buildNetworkPost(
        id: 'post-1',
        text: '',
        tsMs: now,
        expMs: now + 3600000,
        deleted: true,
      );

      final verified = await EnvelopeCodec.verifyNetworkPost(tombstone);
      expect(verified, isNotNull);
      expect(verified!.deleted, isTrue);
      expect(verified.author, aliceAddress);
    });

    test('tampered text or forged author is rejected', () async {
      await unlockAs(alice);
      final now = DateTime.now().millisecondsSinceEpoch;
      final packet = await EnvelopeCodec.buildNetworkPost(
        id: 'post-2',
        text: 'original words',
        tsMs: now,
        expMs: now + 3600000,
      );

      final reworded = Map<String, Object?>.from(packet);
      reworded['text'] = 'planted words';
      expect(await EnvelopeCodec.verifyNetworkPost(reworded), isNull);

      final impersonated = Map<String, Object?>.from(packet);
      impersonated['author'] =
          base64Encode((await carol.extractPublicKey()).bytes);
      expect(await EnvelopeCodec.verifyNetworkPost(impersonated), isNull,
          reason: 'posts must be unforgeable — Carol cannot claim this one');

      final fakeDelete = Map<String, Object?>.from(packet);
      fakeDelete['del'] = true;
      expect(await EnvelopeCodec.verifyNetworkPost(fakeDelete), isNull,
          reason: 'only the author can tombstone their own post');
    });

    test('global posts keep the v1 format older apps can read', () async {
      await unlockAs(alice);
      final now = DateTime.now().millisecondsSinceEpoch;
      final packet = await EnvelopeCodec.buildNetworkPost(
        id: 'post-3',
        text: 'hello square',
        tsMs: now,
        expMs: now + 3600000,
      );
      expect(packet.containsKey('v'), isFalse);
      expect(packet.containsKey('scope'), isFalse);
      final verified = await EnvelopeCodec.verifyNetworkPost(packet);
      expect(verified!.scope, EnvelopeCodec.scopeGlobal);
      expect(verified.path, isNull);
    });

    test('site page round-trips path, title, and HTML', () async {
      await unlockAs(alice);
      final now = DateTime.now().millisecondsSinceEpoch;
      const html = '<h1>Blog | day 1</h1><p>a "quote" & more</p>';
      final packet = await EnvelopeCodec.buildNetworkPost(
        id: 'page-1',
        text: html,
        tsMs: now,
        expMs: now + 3600000,
        nickname: 'Alice',
        scope: EnvelopeCodec.scopeSite,
        pagePath: 'blog/day-1',
        pageTitle: 'Day 1 | notes',
      );
      expect(packet['v'], 2);
      expect(packet['kind'], 'page');

      final relayed = Map<String, Object?>.from(packet)..['hops'] = 3;
      final verified = await EnvelopeCodec.verifyNetworkPost(relayed);
      expect(verified, isNotNull);
      expect(verified!.scope, EnvelopeCodec.scopeSite);
      expect(verified.kind, 'page');
      expect(verified.path, 'blog/day-1');
      expect(verified.title, 'Day 1 | notes');
      expect(verified.text, html);
      expect(verified.hops, 3);
    });

    test('v2 fields are covered by the signature', () async {
      await unlockAs(alice);
      final now = DateTime.now().millisecondsSinceEpoch;
      final page = await EnvelopeCodec.buildNetworkPost(
        id: 'page-2',
        text: '<p>home</p>',
        tsMs: now,
        expMs: now + 3600000,
        scope: EnvelopeCodec.scopeSite,
        pagePath: '',
        pageTitle: 'Home',
      );
      expect(await EnvelopeCodec.verifyNetworkPost(page), isNotNull);

      for (final (field, value) in <(String, Object)>[
        ('path', 'blog'),
        ('title', 'Hijacked'),
        ('text', '<p>planted</p>'),
        ('scope', EnvelopeCodec.scopeGlobal),
      ]) {
        final tampered = Map<String, Object?>.from(page)..[field] = value;
        expect(await EnvelopeCodec.verifyNetworkPost(tampered), isNull,
            reason: 'changing $field must break the signature');
      }

      final downgraded = Map<String, Object?>.from(page)..remove('v');
      expect(await EnvelopeCodec.verifyNetworkPost(downgraded), isNull,
          reason: 'a page cannot pass as a v1 post');

      final sitePost = await EnvelopeCodec.buildNetworkPost(
        id: 'post-4',
        text: 'on my site',
        tsMs: now,
        expMs: now + 3600000,
        scope: EnvelopeCodec.scopeSite,
      );
      final moved = Map<String, Object?>.from(sitePost)
        ..['scope'] = EnvelopeCodec.scopeGlobal;
      expect(await EnvelopeCodec.verifyNetworkPost(moved), isNull,
          reason: 'a site post cannot be moved onto global');
    });
  });

  group('BLE announcements', () {
    test('round trip verifies; tampering is rejected', () async {
      await unlockAs(alice);
      final bytes = await EnvelopeCodec.buildBleAnnouncementBytes();

      final peer = await EnvelopeCodec.verifyBleAnnouncementBytes(bytes);
      expect(peer, isNotNull);
      expect(peer!.address, aliceAddress);
      expect(peer.x25519Base64, await x25519Of(alice));

      final decoded =
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      decoded['x25519'] = await x25519Of(carol);
      final tampered = utf8.encode(jsonEncode(decoded));
      expect(
        await EnvelopeCodec.verifyBleAnnouncementBytes(
          Uint8List.fromList(tampered),
        ),
        isNull,
      );
    });
  });
}
