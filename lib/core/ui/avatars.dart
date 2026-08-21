import 'package:flutter/material.dart';

typedef AvatarPreset = ({IconData icon, Color color});

/// Preset profile avatars (Netflix-style). Referenced by index.
const List<AvatarPreset> kAvatarPresets = [
  (icon: Icons.rocket_launch, color: Color(0xFF7C4DFF)),
  (icon: Icons.pets, color: Color(0xFF26A69A)),
  (icon: Icons.sports_esports, color: Color(0xFFEF5350)),
  (icon: Icons.music_note, color: Color(0xFFFFA726)),
  (icon: Icons.eco, color: Color(0xFF66BB6A)),
  (icon: Icons.bolt, color: Color(0xFFFBC02D)),
  (icon: Icons.ac_unit, color: Color(0xFF29B6F6)),
  (icon: Icons.local_fire_department, color: Color(0xFFFF7043)),
  (icon: Icons.nightlight_round, color: Color(0xFF5C6BC0)),
  (icon: Icons.favorite, color: Color(0xFFEC407A)),
  (icon: Icons.anchor, color: Color(0xFF8D6E63)),
  (icon: Icons.star, color: Color(0xFF9CCC65)),
];

Widget presetAvatar(int id, {double size = 48}) {
  final preset = kAvatarPresets[id.abs() % kAvatarPresets.length];
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: preset.color, shape: BoxShape.circle),
    child: Icon(preset.icon, color: Colors.white, size: size * 0.55),
  );
}
