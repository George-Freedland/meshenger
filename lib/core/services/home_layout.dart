import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';

/// One entry on a springboard surface: an app icon or a named group.
sealed class HomeItem {
  /// Unique key across the whole layout (app id or folder id).
  String get key;
}

class HomeAppItem extends HomeItem {
  final String appId;
  HomeAppItem(this.appId);

  @override
  String get key => appId;
}

class HomeFolderItem extends HomeItem {
  final String id;
  String name;

  /// Apps and (one level of) sub-groups. Depth is capped at two group
  /// levels total: root → group → group → apps, never deeper.
  final List<HomeItem> items;

  HomeFolderItem({required this.id, required this.name, required this.items});

  @override
  String get key => id;

  /// Every app id contained anywhere inside this folder.
  Iterable<String> get allAppIds sync* {
    for (final item in items) {
      switch (item) {
        case HomeAppItem(:final appId):
          yield appId;
        case HomeFolderItem folder:
          yield* folder.allAppIds;
      }
    }
  }
}

/// iPhone-style home layout: icon order, groups (max two levels deep),
/// and group names. Persisted per identity, so each profile arranges its
/// own home screen.
class HomeLayoutController extends ChangeNotifier {
  static const _layoutKey = 'home_layout_v1';

  /// Groups may nest exactly one level: a group inside a group holds only
  /// apps. Container depth: 0 = home screen, 1 = inside a group,
  /// 2 = inside a sub-group.
  static const int maxContainerDepth = 2;

  final List<HomeItem> root = <HomeItem>[];
  bool _loaded = false;
  int _folderSeq = 0;

  bool get isLoaded => _loaded;

  // ---------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------

  /// Loads the stored layout, drops apps that no longer exist, and appends
  /// any new apps (in [defaultOrder]) that the stored layout predates.
  Future<void> load(List<String> defaultOrder) async {
    final valid = defaultOrder.toSet();
    root.clear();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_layoutKey));
    final seenApps = <String>{};

    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded.whereType<Map>()) {
            final item = _decodeItem(
              entry.cast<String, Object?>(),
              depth: 0,
              valid: valid,
              seenApps: seenApps,
            );
            if (item != null) root.add(item);
          }
        }
      } catch (_) {
        root.clear();
        seenApps.clear();
      }
    }

    // Apps added in newer versions of the OS land at the end.
    for (final appId in defaultOrder) {
      if (!seenApps.contains(appId)) {
        root.add(HomeAppItem(appId));
        seenApps.add(appId);
      }
    }

    _dissolveDegenerateFolders(root, parent: null);
    _loaded = true;
    notifyListeners();
  }

  HomeItem? _decodeItem(
    Map<String, Object?> json, {
    required int depth,
    required Set<String> valid,
    required Set<String> seenApps,
  }) {
    final appId = json['a'];
    if (appId is String) {
      if (!valid.contains(appId) || seenApps.contains(appId)) return null;
      seenApps.add(appId);
      return HomeAppItem(appId);
    }

    final folderJson = json['f'];
    if (folderJson is Map && depth < maxContainerDepth) {
      final f = folderJson.cast<String, Object?>();
      final id = f['id'] as String? ?? _newFolderId();
      final name = f['n'] as String? ?? 'Group';
      final items = <HomeItem>[];
      final children = f['items'];
      if (children is List) {
        for (final child in children.whereType<Map>()) {
          final item = _decodeItem(
            child.cast<String, Object?>(),
            depth: depth + 1,
            valid: valid,
            seenApps: seenApps,
          );
          if (item != null) items.add(item);
        }
      }
      return HomeFolderItem(id: id, name: name, items: items);
    }
    return null;
  }

  Map<String, Object?> _encodeItem(HomeItem item) => switch (item) {
        HomeAppItem(:final appId) => <String, Object?>{'a': appId},
        HomeFolderItem folder => <String, Object?>{
            'f': <String, Object?>{
              'id': folder.id,
              'n': folder.name,
              'items': folder.items.map(_encodeItem).toList(),
            },
          },
      };

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_layoutKey),
      jsonEncode(root.map(_encodeItem).toList()),
    );
  }

  Timer? _persistTimer;

  /// Live drag-reflow mutates many times per second; writes are debounced.
  void _mutated() {
    _persistTimer?.cancel();
    _persistTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_persist()),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    super.dispose();
  }

  String _newFolderId() =>
      'g${DateTime.now().microsecondsSinceEpoch}${_folderSeq++}';

  // ---------------------------------------------------------------------
  // Lookups
  // ---------------------------------------------------------------------

  /// Items of a container: null = the home screen, otherwise a folder id.
  List<HomeItem> itemsOf(String? containerId) {
    if (containerId == null) return root;
    final folder = findFolder(containerId);
    return folder?.items ?? const <HomeItem>[];
  }

  HomeFolderItem? findFolder(String id) {
    for (final item in root) {
      if (item is HomeFolderItem) {
        if (item.id == id) return item;
        for (final sub in item.items) {
          if (sub is HomeFolderItem && sub.id == id) return sub;
        }
      }
    }
    return null;
  }

  /// The folder containing [folderId], or null when it sits on the home
  /// screen.
  String? parentOf(String folderId) {
    for (final item in root) {
      if (item is HomeFolderItem) {
        if (item.id == folderId) return null;
        for (final sub in item.items) {
          if (sub is HomeFolderItem && sub.id == folderId) return item.id;
        }
      }
    }
    return null;
  }

  /// Container depth: 0 = home screen, 1 = top-level group, 2 = sub-group.
  int depthOf(String? containerId) {
    if (containerId == null) return 0;
    return parentOf(containerId) == null ? 1 : 2;
  }

  /// Whether dropping [dragKey] onto [targetKey] inside [containerId] may
  /// group them. Only app icons group; a new group can only be created
  /// where its contents stay within the depth cap.
  bool canMerge(String? containerId, String dragKey, String targetKey) {
    if (dragKey == targetKey) return false;
    final items = itemsOf(containerId);
    HomeItem? drag;
    HomeItem? target;
    for (final item in items) {
      if (item.key == dragKey) drag = item;
      if (item.key == targetKey) target = item;
    }
    if (drag is! HomeAppItem || target == null) return false;
    if (target is HomeFolderItem) return true; // join existing group
    return depthOf(containerId) < maxContainerDepth; // create a new one
  }

  // ---------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------

  /// Moves an item within its container so it occupies [toIndex] (the
  /// live reflow while dragging).
  void move(String? containerId, String itemKey, int toIndex) {
    final items = itemsOf(containerId);
    final from = items.indexWhere((i) => i.key == itemKey);
    if (from < 0) return;
    final clamped = toIndex.clamp(0, items.length - 1);
    if (from == clamped) return;
    final item = items.removeAt(from);
    items.insert(clamped, item);
    _mutated();
  }

  /// Drops app [dragKey] onto [targetKey]: joins the target group, or
  /// forms a new one where the target app stood. Returns the group id and
  /// whether it was newly created (callers prompt for a name then).
  (String, bool)? mergeInto(
    String? containerId,
    String dragKey,
    String targetKey, {
    String defaultName = 'Group',
  }) {
    if (!canMerge(containerId, dragKey, targetKey)) return null;
    final items = itemsOf(containerId);
    final dragIndex = items.indexWhere((i) => i.key == dragKey);
    final targetIndex = items.indexWhere((i) => i.key == targetKey);
    if (dragIndex < 0 || targetIndex < 0) return null;

    final drag = items[dragIndex] as HomeAppItem;
    final target = items[targetIndex];

    if (target is HomeFolderItem) {
      items.removeAt(dragIndex);
      target.items.add(drag);
      _mutated();
      return (target.id, false);
    }

    final folder = HomeFolderItem(
      id: _newFolderId(),
      name: defaultName,
      items: <HomeItem>[target, drag],
    );
    // Replace the target with the group first, then drop the dragged app
    // from its old slot.
    items[targetIndex] = folder;
    items.removeAt(dragIndex);
    _mutated();
    return (folder.id, true);
  }

  /// Moves an item out of [folderId] back to its parent container (right
  /// after the group icon). Groups left with fewer than two entries
  /// dissolve, exactly like iOS folders.
  void eject(String folderId, String itemKey) {
    final folder = findFolder(folderId);
    if (folder == null) return;
    final index = folder.items.indexWhere((i) => i.key == itemKey);
    if (index < 0) return;
    final item = folder.items.removeAt(index);

    final parentItems = itemsOf(parentOf(folderId));
    final folderIndex = parentItems.indexWhere((i) => i.key == folderId);
    parentItems.insert(
      folderIndex < 0 ? parentItems.length : folderIndex + 1,
      item,
    );

    _dissolveDegenerateFolders(root, parent: null);
    _mutated();
  }

  void renameFolder(String folderId, String name) {
    final folder = findFolder(folderId);
    if (folder == null) return;
    final trimmed = name.trim();
    folder.name = trimmed.isEmpty ? 'Group' : trimmed;
    _mutated();
  }

  /// Replaces 0/1-item folders with their content, bottom-up.
  void _dissolveDegenerateFolders(List<HomeItem> items,
      {required String? parent}) {
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item is! HomeFolderItem) continue;
      _dissolveDegenerateFolders(item.items, parent: item.id);
      if (item.items.isEmpty) {
        items.removeAt(i);
      } else if (item.items.length == 1) {
        items[i] = item.items.single;
      }
    }
  }
}
