import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/core/services/file_transfer_service.dart';

/// The maths and crypto the P2P transfer engine relies on: chunk
/// accounting, nonce discipline, key derivation, and per-chunk AES-GCM.
void main() {
  group('chunk accounting', () {
    test('chunk count covers the file exactly', () {
      expect(FileTransferService.chunkCountFor(0, 1024), 0);
      expect(FileTransferService.chunkCountFor(1, 1024), 1);
      expect(FileTransferService.chunkCountFor(1024, 1024), 1);
      expect(FileTransferService.chunkCountFor(1025, 1024), 2);
      // 4 GB video in 256 KB chunks.
      expect(
        FileTransferService.chunkCountFor(4 * 1024 * 1024 * 1024, 256 * 1024),
        16384,
      );
    });
  });

  group('nonce discipline', () {
    test('nonces are 12 bytes and unique per chunk index', () {
      final seen = <String>{};
      for (final i in [0, 1, 2, 255, 256, 65535, 1 << 32, (1 << 40) + 7]) {
        final nonce = FileTransferService.nonceForChunk(i);
        expect(nonce.length, 12);
        expect(seen.add(base64Encode(nonce)), isTrue,
            reason: 'chunk $i must get a nonce no other chunk uses');
      }
    });
  });

  group('transfer keys', () {
    final secret = List<int>.generate(32, (i) => i * 7 % 256);

    test('both ends derive the same key; other transfers get another',
        () async {
      final a = await FileTransferService.deriveKey(secret, 'transfer-1');
      final b = await FileTransferService.deriveKey(secret, 'transfer-1');
      final other = await FileTransferService.deriveKey(secret, 'transfer-2');

      expect(await a.extractBytes(), await b.extractBytes());
      expect(await a.extractBytes(), isNot(await other.extractBytes()));
      expect((await a.extractBytes()).length, 32, reason: 'AES-256 key');
    });

    test('chunks round-trip; tampering or wrong index is rejected', () async {
      final key = await FileTransferService.deriveKey(secret, 'transfer-1');
      final plain = utf8.encode('4k drone shot, frame 000217');
      final algorithm = AesGcm.with256bits();

      final box = await algorithm.encrypt(
        plain,
        secretKey: key,
        nonce: FileTransferService.nonceForChunk(217),
      );

      final decrypted = await algorithm.decrypt(
        SecretBox(box.cipherText,
            nonce: FileTransferService.nonceForChunk(217), mac: box.mac),
        secretKey: key,
      );
      expect(decrypted, plain);

      // A chunk replayed under a different index must fail authentication.
      await expectLater(
        algorithm.decrypt(
          SecretBox(box.cipherText,
              nonce: FileTransferService.nonceForChunk(218), mac: box.mac),
          secretKey: key,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      // Flipped ciphertext must fail authentication.
      final flipped = [...box.cipherText];
      flipped[0] ^= 0xff;
      await expectLater(
        algorithm.decrypt(
          SecretBox(flipped,
              nonce: FileTransferService.nonceForChunk(217), mac: box.mac),
          secretKey: key,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });
}
