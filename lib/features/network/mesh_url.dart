import 'dart:convert';

import '../../core/transport/envelope_codec.dart';

/// An address in the Network browser:
/// - `global` — the square everyone in the mesh shares;
/// - `<public key>` — that person's site (home page, pages, and posts);
/// - `<public key>/<path>` — one of their pages, like `…=/blog`.
///
/// Keys are standard base64 Ed25519 addresses (what people copy from their
/// profile); typed input may also use the URL-safe alphabet or be a pasted
/// contact QR.
class MeshUrl {
  const MeshUrl.global()
      : site = null,
        path = '';

  const MeshUrl.site(String this.site, [this.path = '']);

  /// The site owner's address; null for the global square.
  final String? site;

  /// Page path under the site ('' = home page).
  final String path;

  bool get isGlobal => site == null;

  static const String globalName = 'global';

  static final RegExp _base64Key = RegExp(r'^[A-Za-z0-9+/]{43}=');
  static final RegExp _base64UrlKey = RegExp(r'^[A-Za-z0-9_-]{43}(?=$|[/:])');
  static final RegExp _scheme = RegExp(r'^[a-z][a-z0-9+.-]*:');

  /// Parses a typed address or an absolute link. Null when [input] isn't a
  /// mesh address (a name to search for, say).
  static MeshUrl? parse(String input) {
    var v = _stripFragment(input.trim());
    for (final prefix in const ['mesh://', 'mesh:', 'meshenger:']) {
      if (v.toLowerCase().startsWith(prefix)) {
        v = v.substring(prefix.length);
        break;
      }
    }
    if (v.isEmpty || v.toLowerCase() == globalName) {
      return const MeshUrl.global();
    }

    String key;
    String rest;
    final standard = _base64Key.firstMatch(v);
    if (standard != null) {
      key = standard.group(0)!;
      rest = v.substring(key.length);
    } else {
      final urlSafe = _base64UrlKey.firstMatch(v);
      if (urlSafe == null) return null;
      key = '${urlSafe.group(0)!.replaceAll('-', '+').replaceAll('_', '/')}=';
      rest = v.substring(43);
    }
    try {
      if (base64Decode(key).length != 32) return null;
    } catch (_) {
      return null;
    }
    // A pasted contact QR is `<key>:<encryption key>`: just the site.
    if (rest.startsWith(':')) rest = '';
    final path = normalizePath(rest);
    return path == null ? null : MeshUrl.site(key, path);
  }

  /// Resolves a link inside a page shown at [from]: absolute mesh
  /// addresses, `global`, or paths relative to the site being viewed
  /// (`/`, `/blog`, `blog`, `./blog`). Null for links that can't be
  /// followed on the mesh (see [isExternal]) or that only jump within the
  /// page.
  static MeshUrl? resolveLink(String href, MeshUrl from) {
    final v = _stripFragment(href.trim());
    if (v.isEmpty || isExternal(v)) return null;
    final absolute = parse(v);
    if (absolute != null) return absolute;
    final site = from.site;
    if (site == null) return null;
    var relative = v;
    while (relative.startsWith('./')) {
      relative = relative.substring(2);
    }
    final path = normalizePath(relative);
    return path == null ? null : MeshUrl.site(site, path);
  }

  /// True for links that leave the mesh (the internet, mail, phone).
  static bool isExternal(String href) {
    final v = href.trim().toLowerCase();
    if (v.startsWith('//')) return true;
    if (v.startsWith('mesh:') || v.startsWith('meshenger:')) return false;
    return _scheme.hasMatch(v);
  }

  /// Lowercases and validates a page path; null when it isn't one.
  static String? normalizePath(String raw) {
    var p = raw.trim().toLowerCase().replaceAll(RegExp('/+'), '/');
    if (p.startsWith('/')) p = p.substring(1);
    if (p.endsWith('/')) p = p.substring(0, p.length - 1);
    if (p.length > 64) return null;
    return EnvelopeCodec.pagePathPattern.hasMatch(p) ? p : null;
  }

  static String _stripFragment(String v) {
    final cut = v.indexOf(RegExp('[#?]'));
    return cut < 0 ? v : v.substring(0, cut);
  }

  @override
  String toString() =>
      site == null ? globalName : (path.isEmpty ? site! : '$site/$path');

  @override
  bool operator ==(Object other) =>
      other is MeshUrl && other.site == site && other.path == path;

  @override
  int get hashCode => Object.hash(site, path);
}
