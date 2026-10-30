import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/features/network/mesh_url.dart';

void main() {
  // A 32-byte key whose base64 form contains both '/' and '+'.
  final keyBytes = List<int>.generate(32, (i) => i == 0 ? 0xfb : i * 7);
  final key = base64Encode(keyBytes);
  final urlSafeKey =
      key.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');

  setUpAll(() {
    expect(key.contains('/') || key.contains('+'), isTrue);
  });

  group('parse', () {
    test('global and empty input', () {
      expect(MeshUrl.parse('global'), const MeshUrl.global());
      expect(MeshUrl.parse('  GLOBAL '), const MeshUrl.global());
      expect(MeshUrl.parse(''), const MeshUrl.global());
      expect(MeshUrl.parse('mesh:global'), const MeshUrl.global());
    });

    test('a pasted public key opens that site', () {
      expect(MeshUrl.parse(key), MeshUrl.site(key));
      expect(MeshUrl.parse(' $key '), MeshUrl.site(key));
      expect(MeshUrl.parse('mesh://$key'), MeshUrl.site(key));
    });

    test('key plus path, even though the key itself contains "/"', () {
      expect(MeshUrl.parse('$key/blog'), MeshUrl.site(key, 'blog'));
      expect(
          MeshUrl.parse('$key/Blog/Day-1/'), MeshUrl.site(key, 'blog/day-1'));
      expect(MeshUrl.parse('$key/blog#top'), MeshUrl.site(key, 'blog'));
    });

    test('URL-safe keys are accepted', () {
      expect(MeshUrl.parse(urlSafeKey), MeshUrl.site(key));
      expect(MeshUrl.parse('$urlSafeKey/blog'), MeshUrl.site(key, 'blog'));
    });

    test('a pasted contact QR opens the site', () {
      expect(MeshUrl.parse('meshenger:$key:someEncryptionKey='),
          MeshUrl.site(key));
    });

    test('names and junk are not addresses', () {
      expect(MeshUrl.parse('alice'), isNull);
      expect(MeshUrl.parse('${key.substring(0, 40)}=='), isNull);
      expect(MeshUrl.parse('$key/bad path'), isNull);
    });

    test('toString round-trips', () {
      for (final url in [
        const MeshUrl.global(),
        MeshUrl.site(key),
        MeshUrl.site(key, 'blog/day-1'),
      ]) {
        expect(MeshUrl.parse(url.toString()), url);
      }
    });
  });

  group('resolveLink', () {
    final site = MeshUrl.site(key, 'blog');

    test('relative links stay on the site being viewed', () {
      expect(MeshUrl.resolveLink('/', site), MeshUrl.site(key));
      expect(MeshUrl.resolveLink('/about', site), MeshUrl.site(key, 'about'));
      expect(MeshUrl.resolveLink('./about', site), MeshUrl.site(key, 'about'));
      expect(MeshUrl.resolveLink('photos/2026', site),
          MeshUrl.site(key, 'photos/2026'));
    });

    test('absolute mesh links go anywhere', () {
      expect(MeshUrl.resolveLink('global', site), const MeshUrl.global());
      expect(MeshUrl.resolveLink('mesh:$key/x', const MeshUrl.global()),
          MeshUrl.site(key, 'x'));
    });

    test('internet links and anchors are not followed', () {
      expect(MeshUrl.isExternal('https://example.com'), isTrue);
      expect(MeshUrl.isExternal('//example.com/x'), isTrue);
      expect(MeshUrl.isExternal('mailto:a@b.c'), isTrue);
      expect(MeshUrl.isExternal('/blog'), isFalse);
      expect(MeshUrl.isExternal(key), isFalse);
      expect(MeshUrl.resolveLink('https://example.com', site), isNull);
      expect(MeshUrl.resolveLink('#top', site), isNull);
    });

    test('relative links on global have nowhere to go', () {
      expect(MeshUrl.resolveLink('/blog', const MeshUrl.global()), isNull);
    });
  });
}
