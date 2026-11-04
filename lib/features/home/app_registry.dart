import 'package:flutter/material.dart';

/// A built-in app on the home screen.
class AppDefinition {
  final String id;
  final String label;
  final IconData icon;
  final Color color;
  final String route;

  const AppDefinition(this.id, this.label, this.icon, this.color, this.route);
}

/// Every app, in default home-screen order. Ids are stable — the saved
/// home layout references them.
const List<AppDefinition> kAppRegistry = [
  AppDefinition(
      'messages', 'Messages', Icons.chat_bubble, Color(0xFF26A69A), '/chats'),
  AppDefinition('contacts', 'Contacts', Icons.contacts, Color(0xFF3949AB),
      '/app/contacts'),
  AppDefinition('network', 'Network', Icons.public, Color(0xFFEC407A),
      '/app/network'),
  AppDefinition('camera', 'Camera', Icons.photo_camera, Color(0xFF78909C),
      '/app/camera'),
  AppDefinition(
      'storage', 'Storage', Icons.folder, Color(0xFFFFA726), '/app/storage'),
  AppDefinition(
      'memos', 'Voice Memos', Icons.mic, Color(0xFFEF5350), '/app/memos'),
  AppDefinition(
      'meshmap', 'Mesh Map', Icons.hub, Color(0xFF7C4DFF), '/app/meshmap'),
  AppDefinition('store', 'App Store', Icons.apps, Color(0xFF5C6BC0),
      '/app/store'),
  AppDefinition('settings', 'Settings', Icons.settings, Color(0xFF8D6E63),
      '/app/settings'),
];

final Map<String, AppDefinition> _byId = {
  for (final app in kAppRegistry) app.id: app,
};

AppDefinition? appById(String id) => _byId[id];

List<String> get defaultAppOrder =>
    kAppRegistry.map((a) => a.id).toList(growable: false);
