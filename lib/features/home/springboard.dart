import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/services/home_layout.dart';
import '../../core/ui/unread_badge.dart';
import 'app_registry.dart';

/// iPhone-springboard grid: long-press starts jiggle mode, dragging
/// reflows the other icons live, dropping one icon onto another groups
/// them (groups can nest one level), and unread badges bubble up onto
/// group icons.
class Springboard extends StatefulWidget {
  final HomeLayoutController controller;

  /// null = home screen; otherwise the group whose contents this grid shows.
  final String? containerId;

  final ValueListenable<bool> editing;
  final VoidCallback onEnterEdit;
  final ValueListenable<Map<String, int>> badges;
  final void Function(AppDefinition app) onOpenApp;
  final void Function(HomeFolderItem folder) onOpenFolder;

  /// Called when a drop just created a brand-new group (prompt to name it).
  final void Function(HomeFolderItem folder) onFolderCreated;

  const Springboard({
    super.key,
    required this.controller,
    this.containerId,
    required this.editing,
    required this.onEnterEdit,
    required this.badges,
    required this.onOpenApp,
    required this.onOpenFolder,
    required this.onFolderCreated,
  });

  @override
  State<Springboard> createState() => _SpringboardState();
}

class _SpringboardState extends State<Springboard>
    with SingleTickerProviderStateMixin {
  static const double _cellHeight = 104;
  static const double _iconSize = 58;
  static const double _iconCenterY = 39; // icon center within a cell
  static const double _mergeRadius = 34;

  late final AnimationController _jiggle;

  String? _dragKey;
  String? _mergeKey;

  @override
  void initState() {
    super.initState();
    _jiggle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    widget.editing.addListener(_syncJiggle);
    _syncJiggle();
  }

  @override
  void dispose() {
    widget.editing.removeListener(_syncJiggle);
    _jiggle.dispose();
    super.dispose();
  }

  void _syncJiggle() {
    if (!mounted) return;
    if (widget.editing.value) {
      _jiggle.repeat();
    } else {
      _jiggle.stop();
      _jiggle.value = 0;
    }
    setState(() {});
  }

  List<HomeItem> get _items => widget.controller.itemsOf(widget.containerId);

  int _badgeOf(HomeItem item) {
    final badges = widget.badges.value;
    return switch (item) {
      HomeAppItem(:final appId) => badges[appId] ?? 0,
      HomeFolderItem folder =>
        folder.allAppIds.fold(0, (sum, id) => sum + (badges[id] ?? 0)),
    };
  }

  int? _indexAt(Offset local, int cols, double cellW, int count) {
    if (count == 0) return null;
    final col = (local.dx / cellW).floor().clamp(0, cols - 1);
    final row = math.max(0, (local.dy / _cellHeight).floor());
    return math.min(row * cols + col, count - 1);
  }

  void _handleHover(String dragKey, Offset local, int cols, double cellW) {
    final items = _items;
    final index = _indexAt(local, cols, cellW, items.length);
    if (index == null) return;
    final target = items[index];

    if (target.key == dragKey) {
      if (_mergeKey != null) setState(() => _mergeKey = null);
      return;
    }

    final iconCenter = Offset(
      (index % cols + 0.5) * cellW,
      (index ~/ cols) * _cellHeight + _iconCenterY,
    );
    final inMergeZone = (local - iconCenter).distance < _mergeRadius;

    if (inMergeZone &&
        widget.controller.canMerge(widget.containerId, dragKey, target.key)) {
      if (_mergeKey != target.key) setState(() => _mergeKey = target.key);
      return;
    }

    if (_mergeKey != null) setState(() => _mergeKey = null);
    widget.controller.move(widget.containerId, dragKey, index);
  }

  void _handleDrop(String dragKey) {
    final mergeKey = _mergeKey;
    if (mergeKey != null) {
      final result = widget.controller.mergeInto(
        widget.containerId,
        dragKey,
        mergeKey,
      );
      if (result != null && result.$2) {
        final folder = widget.controller.findFolder(result.$1);
        if (folder != null) widget.onFolderCreated(folder);
      }
    }
    setState(() {
      _dragKey = null;
      _mergeKey = null;
    });
  }

  Widget _appIcon(AppDefinition app, {double size = _iconSize}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: app.color,
        borderRadius: BorderRadius.circular(size * 0.26),
        boxShadow: [
          BoxShadow(
            color: app.color.withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Icon(app.icon, color: Colors.white, size: size * 0.52),
    );
  }

  Widget _folderIcon(HomeFolderItem folder, {double size = _iconSize}) {
    final minis = folder.items.take(9).toList();
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.26),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: GridView.count(
        crossAxisCount: 3,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        mainAxisSpacing: size * 0.05,
        crossAxisSpacing: size * 0.05,
        children: [
          for (final item in minis)
            switch (item) {
              HomeAppItem(:final appId) => Builder(builder: (_) {
                  final app = appById(appId);
                  return Container(
                    decoration: BoxDecoration(
                      color: app?.color ?? Colors.grey,
                      borderRadius: BorderRadius.circular(size * 0.06),
                    ),
                    child: app == null
                        ? null
                        : Icon(app.icon,
                            color: Colors.white, size: size * 0.16),
                  );
                }),
              HomeFolderItem _ => Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(size * 0.06),
                  ),
                  child: Icon(Icons.grid_view_rounded,
                      color: Colors.white, size: size * 0.14),
                ),
            },
        ],
      ),
    );
  }

  Widget _tileVisual(HomeItem item, ThemeData theme) {
    final badge = _badgeOf(item);
    final icon = switch (item) {
      HomeAppItem(:final appId) => Builder(builder: (_) {
          final app = appById(appId);
          return app == null ? const SizedBox(width: 58, height: 58) : _appIcon(app);
        }),
      HomeFolderItem folder => _folderIcon(folder),
    };
    final label = switch (item) {
      HomeAppItem(:final appId) => appById(appId)?.label ?? appId,
      HomeFolderItem folder => folder.name,
    };
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        UnreadBadge(count: badge, child: icon),
        const SizedBox(height: 8),
        Text(
          label,
          style: theme.textTheme.labelMedium,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _feedback(HomeItem item, ThemeData theme, double cellW) {
    return Transform.translate(
      offset: Offset(-cellW / 2, -_cellHeight / 2),
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: cellW,
          height: _cellHeight,
          child: Transform.scale(
            scale: 1.18,
            child: Opacity(opacity: 0.9, child: _tileVisual(item, theme)),
          ),
        ),
      ),
    );
  }

  Widget _tile(
    HomeItem item,
    int index,
    int cols,
    double cellW,
    ThemeData theme,
    bool editing,
  ) {
    final isDragged = item.key == _dragKey;
    final isMergeTarget = item.key == _mergeKey;
    final insideFolder = widget.containerId != null;

    Widget body = _tileVisual(item, theme);

    // Merge highlight: the drop target swells like iOS folder creation.
    body = AnimatedScale(
      scale: isMergeTarget ? 1.22 : 1.0,
      duration: const Duration(milliseconds: 140),
      child: body,
    );

    if (editing) {
      final phase = index * 1.9;
      body = AnimatedBuilder(
        animation: _jiggle,
        builder: (context, child) => Transform.rotate(
          angle: math.sin(_jiggle.value * 2 * math.pi + phase) * 0.028,
          child: child,
        ),
        child: body,
      );
    }

    // Inside a group while editing: a small "move out" button, since
    // drags cannot cross the group overlay boundary.
    if (editing && insideFolder) {
      body = Stack(
        clipBehavior: Clip.none,
        children: [
          body,
          Positioned(
            top: 2,
            left: 2,
            child: GestureDetector(
              onTap: () =>
                  widget.controller.eject(widget.containerId!, item.key),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
                child: const Icon(Icons.north_west,
                    size: 13, color: Colors.white),
              ),
            ),
          ),
        ],
      );
    }

    final child = InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        switch (item) {
          case HomeAppItem(:final appId):
            if (editing) return; // taps navigate only outside jiggle mode
            final app = appById(appId);
            if (app != null) widget.onOpenApp(app);
          case HomeFolderItem folder:
            widget.onOpenFolder(folder);
        }
      },
      child: body,
    );

    return AnimatedPositioned(
      key: ValueKey(item.key),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: (index % cols) * cellW,
      top: (index ~/ cols) * _cellHeight,
      width: cellW,
      height: _cellHeight,
      child: LongPressDraggable<String>(
        data: item.key,
        delay: const Duration(milliseconds: 350),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _feedback(item, theme, cellW),
        childWhenDragging: const SizedBox.shrink(),
        onDragStarted: () {
          widget.onEnterEdit();
          setState(() => _dragKey = item.key);
        },
        onDraggableCanceled: (_, __) => setState(() {
          _dragKey = null;
          _mergeKey = null;
        }),
        onDragEnd: (_) {
          if (_dragKey != null || _mergeKey != null) {
            setState(() {
              _dragKey = null;
              _mergeKey = null;
            });
          }
        },
        child: isDragged ? const SizedBox.shrink() : child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.controller, widget.badges]),
      builder: (context, _) {
        final items = _items;
        return LayoutBuilder(
          builder: (context, constraints) {
            final cols =
                (constraints.maxWidth / 96).floor().clamp(3, 8);
            final cellW = constraints.maxWidth / cols;
            final rows = items.isEmpty ? 1 : ((items.length - 1) ~/ cols) + 1;
            final editing = widget.editing.value;

            return DragTarget<String>(
              onWillAcceptWithDetails: (details) =>
                  items.any((i) => i.key == details.data),
              onMove: (details) {
                final box = context.findRenderObject() as RenderBox?;
                if (box == null) return;
                _handleHover(
                  details.data,
                  box.globalToLocal(details.offset),
                  cols,
                  cellW,
                );
              },
              onLeave: (_) {
                if (_mergeKey != null) setState(() => _mergeKey = null);
              },
              onAcceptWithDetails: (details) => _handleDrop(details.data),
              builder: (context, _, __) => SizedBox(
                height: rows * _cellHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (var i = 0; i < items.length; i++)
                      _tile(items[i], i, cols, cellW, theme, editing),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Opens a group as an iOS-style folder overlay: blurred backdrop, the
/// group name (tap to rename), and a springboard of its contents that
/// supports the same drag mechanics one level deeper.
Future<void> showFolderOverlay(
  BuildContext context, {
  required HomeLayoutController controller,
  required String folderId,
  required ValueListenable<bool> editing,
  required VoidCallback onEnterEdit,
  required ValueListenable<Map<String, int>> badges,
  required void Function(AppDefinition app) onOpenApp,
  required void Function(HomeFolderItem folder) onFolderCreated,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close group',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 220),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeIn,
      );
      return BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: 8 * animation.value,
          sigmaY: 8 * animation.value,
        ),
        child: FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: curved, child: child),
        ),
      );
    },
    pageBuilder: (dialogContext, _, __) {
      return SafeArea(
        child: Center(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final folder = controller.findFolder(folderId);
              // The group dissolved (last icon ejected) — close the overlay.
              if (folder == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                });
                return const SizedBox.shrink();
              }

              final width = math.min(
                MediaQuery.sizeOf(context).width - 48,
                440.0,
              );

              return Material(
                type: MaterialType.transparency,
                child: Container(
                  width: width,
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10151E).withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => _renameFolder(
                                  dialogContext, controller, folder),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        folder.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Icon(
                                      Icons.edit_outlined,
                                      size: 15,
                                      color: Colors.white
                                          .withValues(alpha: 0.5),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Springboard(
                            controller: controller,
                            containerId: folderId,
                            editing: editing,
                            onEnterEdit: onEnterEdit,
                            badges: badges,
                            onOpenApp: (app) {
                              Navigator.pop(dialogContext);
                              onOpenApp(app);
                            },
                            onOpenFolder: (sub) {
                              showFolderOverlay(
                                dialogContext,
                                controller: controller,
                                folderId: sub.id,
                                editing: editing,
                                onEnterEdit: onEnterEdit,
                                badges: badges,
                                onOpenApp: (app) {
                                  // Close both overlays before launching.
                                  Navigator.pop(dialogContext);
                                  onOpenApp(app);
                                },
                                onFolderCreated: onFolderCreated,
                              );
                            },
                            onFolderCreated: onFolderCreated,
                          ),
                        ),
                      ),
                      ValueListenableBuilder<bool>(
                        valueListenable: editing,
                        builder: (context, isEditing, _) => isEditing
                            ? Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  'Drag to rearrange · ↖ moves an app out '
                                  'of the group',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Colors.white
                                            .withValues(alpha: 0.45),
                                      ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

Future<void> _renameFolder(
  BuildContext context,
  HomeLayoutController controller,
  HomeFolderItem folder,
) async {
  final nameController = TextEditingController(text: folder.name);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Group name'),
      content: TextField(
        controller: nameController,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (_) {
          controller.renameFolder(folder.id, nameController.text);
          Navigator.pop(ctx);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            controller.renameFolder(folder.id, nameController.text);
            Navigator.pop(ctx);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Prompt shown right after a drop creates a new group.
Future<void> promptNameForNewFolder(
  BuildContext context,
  HomeLayoutController controller,
  HomeFolderItem folder,
) =>
    _renameFolder(context, controller, folder);
