import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Computers save a copy through a save dialog; phones hand one to the
/// share sheet, which has Save to Files, Save Image and Save Video.
bool get savesWithDialog =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

String get saveActionLabel =>
    savesWithDialog ? 'Save to this computer…' : 'Save or share…';

IconData get saveActionIcon =>
    savesWithDialog ? Icons.download_outlined : Icons.ios_share;

/// Puts a copy of the file at [path], named [name], wherever the user
/// picks. [context] is the tapped widget's: on iPad the share sheet points
/// at it.
Future<void> saveFileCopy(
  BuildContext context, {
  required String path,
  required String name,
  String? mime,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final box = context.findRenderObject();
  final origin = box is RenderBox && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  final fileName = _safeFileName(name);
  try {
    if (!await File(path).exists()) {
      messenger?.showSnackBar(const SnackBar(
          content: Text('That file is no longer on this device.')));
      return;
    }
    if (savesWithDialog) {
      // In the Mac sandbox this would be the app's own container.
      final downloads = Platform.isMacOS ? null : await getDownloadsDirectory();
      final location = await getSaveLocation(
        suggestedName: fileName,
        initialDirectory: downloads?.path,
        confirmButtonText: 'Save',
      );
      if (location == null || location.path == path) return;
      await File(path).copy(location.path);
      messenger?.showSnackBar(SnackBar(
        content: Text('Saved to ${location.path}'),
        action: SnackBarAction(
          label: 'Show',
          onPressed: () => _reveal(location.path),
        ),
      ));
      return;
    }
    // Shared files go by their name on disk, and Storage keeps files
    // under ids.
    final folder = await Directory(
            '${(await getTemporaryDirectory()).path}/shared/${DateTime.now().millisecondsSinceEpoch}')
        .create(recursive: true);
    final copy = await File(path).copy('${folder.path}/$fileName');
    await SharePlus.instance.share(ShareParams(
      files: [XFile(copy.path, mimeType: mime)],
      sharePositionOrigin: origin,
    ));
  } catch (e) {
    messenger
        ?.showSnackBar(SnackBar(content: Text("Couldn't save the file: $e")));
  }
}

Future<void> _reveal(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', path]);
      return;
    }
    await launchUrl(Uri.directory(File(path).parent.path));
  } catch (_) {}
}

/// [name] without characters Windows or the share sheet refuse.
String _safeFileName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .trim()
      .replaceAll(RegExp(r'^\.+'), '');
  return cleaned.isEmpty ? 'file' : cleaned;
}
