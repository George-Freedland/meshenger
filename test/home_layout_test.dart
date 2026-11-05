import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshenger/core/services/home_layout.dart';
import 'package:meshenger/core/services/identity_scope.dart';

/// Springboard layout rules: reorder, grouping (max two levels), ejecting,
/// folder dissolution, and persistence across restarts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Layouts are stored per profile.
  IdentityScope.setActive('testProfilePublicKey');

  const apps = ['messages', 'phone', 'network', 'camera', 'settings'];

  Future<HomeLayoutController> freshController() async {
    final controller = HomeLayoutController();
    await controller.load(apps);
    return controller;
  }

  List<String> rootKeys(HomeLayoutController c) =>
      c.root.map((i) => i.key).toList();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('first load lays out the default app order', () async {
    final c = await freshController();
    expect(rootKeys(c), apps);
  });

  test('move reorders within the home screen', () async {
    final c = await freshController();
    c.move(null, 'settings', 0);
    expect(rootKeys(c), ['settings', 'messages', 'phone', 'network', 'camera']);
  });

  test('dropping one app onto another forms a named group', () async {
    final c = await freshController();
    final result = c.mergeInto(null, 'phone', 'messages');
    expect(result, isNotNull);
    final (folderId, created) = result!;
    expect(created, isTrue);

    final folder = c.findFolder(folderId)!;
    expect(folder.allAppIds, ['messages', 'phone']);
    // The group stands where the target app stood; the drag slot is gone.
    expect(rootKeys(c), [folderId, 'network', 'camera', 'settings']);

    c.renameFolder(folderId, '  Social  ');
    expect(c.findFolder(folderId)!.name, 'Social');
  });

  test('dropping onto an existing group joins it instead', () async {
    final c = await freshController();
    final (folderId, _) = c.mergeInto(null, 'phone', 'messages')!;
    final joined = c.mergeInto(null, 'network', folderId);
    expect(joined, (folderId, false));
    expect(c.findFolder(folderId)!.allAppIds, ['messages', 'phone', 'network']);
  });

  test('groups nest one level deep and no deeper', () async {
    final c = await freshController();
    final (outerId, _) = c.mergeInto(null, 'phone', 'messages')!;
    c.mergeInto(null, 'network', outerId);

    // Inside the group, two apps may still form a sub-group…
    final inner = c.mergeInto(outerId, 'phone', 'messages');
    expect(inner, isNotNull);
    final (innerId, _) = inner!;
    expect(c.depthOf(innerId), 2);

    // …but nothing may group inside the sub-group.
    c.mergeInto(outerId, 'network', innerId); // joining is still fine
    expect(c.findFolder(innerId)!.allAppIds, ['messages', 'phone', 'network']);
    expect(
      c.canMerge(innerId, 'messages', 'phone'),
      isFalse,
      reason: 'no groups within groups within groups',
    );
  });

  test('ejecting below two members dissolves the group like iOS', () async {
    final c = await freshController();
    final (folderId, _) = c.mergeInto(null, 'phone', 'messages')!;

    c.eject(folderId, 'phone');
    expect(c.findFolder(folderId), isNull,
        reason: 'single-item groups dissolve into a plain icon');
    expect(rootKeys(c), ['messages', 'phone', 'network', 'camera', 'settings']);
  });

  test('layout survives a restart and absorbs newly shipped apps', () async {
    final c = await freshController();
    final (folderId, _) = c.mergeInto(null, 'phone', 'messages')!;
    c.renameFolder(folderId, 'Comms');
    // Persistence is debounced behind a short timer.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final reloaded = HomeLayoutController();
    await reloaded.load([...apps, 'contacts']);
    final folder = reloaded.findFolder(folderId)!;
    expect(folder.name, 'Comms');
    expect(folder.allAppIds, ['messages', 'phone']);
    expect(reloaded.root.last.key, 'contacts',
        reason: 'apps added by an update land at the end');
  });

  test('badges roll up: a folder covers all apps inside it', () async {
    final c = await freshController();
    final (outerId, _) = c.mergeInto(null, 'phone', 'messages')!;
    c.mergeInto(null, 'network', outerId);
    final (innerId, _) = c.mergeInto(outerId, 'phone', 'messages')!;

    final outer = c.findFolder(outerId)!;
    expect(outer.allAppIds.toSet(), {'messages', 'phone', 'network'},
        reason: 'folder badge sums nested app badges too');
    expect(c.findFolder(innerId)!.allAppIds.toSet(), {'messages', 'phone'});
  });
}
