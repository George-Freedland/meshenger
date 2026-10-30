import 'package:flutter/material.dart';

import '../../core/models/contact.dart';

/// Display names for addresses: "You", then my contacts' nicknames, then
/// names heard through gossip, then the name carried on a post, then a
/// short key.
class NetworkNames {
  const NetworkNames({
    this.myAddress,
    this.contacts = const <Contact>[],
    this.heard = const <String, String>{},
  });

  final String? myAddress;
  final List<Contact> contacts;
  final Map<String, String> heard;

  String of(String address, {String? carried, bool you = true}) {
    if (you && address == myAddress) return 'You';
    for (final c in contacts) {
      final nick = c.nickname?.trim();
      if (c.address == address && nick != null && nick.isNotEmpty) return nick;
    }
    final live = heard[address];
    if (live != null) return live;
    final trimmed = carried?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return shortAddress(address);
  }
}

String shortAddress(String address) {
  if (address.length <= 14) return address;
  return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
}

String timeAgo(int tsMs) {
  final delta =
      Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - tsMs);
  if (delta.inDays >= 1) return '${delta.inDays}d ago';
  if (delta.inHours >= 1) return '${delta.inHours}h ago';
  if (delta.inMinutes >= 1) return '${delta.inMinutes}m ago';
  return 'just now';
}

String timeLeft(int expiresMs) {
  final left =
      Duration(milliseconds: expiresMs - DateTime.now().millisecondsSinceEpoch);
  if (left.inDays >= 1) return '${left.inDays}d left';
  if (left.inHours >= 1) return '${left.inHours}h left';
  if (left.inMinutes >= 1) return '${left.inMinutes}m left';
  return 'expiring';
}

String hopsLabel(int hops, {required bool mine}) {
  if (hops == 0) return mine ? 'posted here' : 'right next to you';
  return '$hops hop${hops == 1 ? '' : 's'} away';
}

const _palettes = <(Color, Color)>[
  (Color(0xFF3A1C71), Color(0xFFD76D77)),
  (Color(0xFF134E5E), Color(0xFF71B280)),
  (Color(0xFF232526), Color(0xFF414345)),
  (Color(0xFF0F2027), Color(0xFF2C5364)),
  (Color(0xFF5A3F37), Color(0xFF2C7744)),
  (Color(0xFF41295A), Color(0xFF2F0743)),
  (Color(0xFF1E3C72), Color(0xFF2A5298)),
  (Color(0xFF8E2DE2), Color(0xFF4A00E0)),
];

/// Deterministic vivid gradient per post or person.
(Color, Color) paletteFor(String seed) =>
    _palettes[seed.hashCode.abs() % _palettes.length];

/// Round initial-letter avatar colored per address.
class InitialAvatar extends StatelessWidget {
  const InitialAvatar({
    super.key,
    required this.name,
    required this.seed,
    this.radius = 16,
  });

  final String name;
  final String seed;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final (colorA, colorB) = paletteFor(seed);
    return Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [colorA, colorB]),
      ),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: radius * 0.9,
        ),
      ),
    );
  }
}
