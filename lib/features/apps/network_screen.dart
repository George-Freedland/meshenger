import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/contacts_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/media_store.dart';
import '../../core/services/mesh_activity.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/network_service.dart';
import '../../core/services/peer_directory.dart';
import '../../core/services/transport_log.dart';
import '../../core/transport/envelope_codec.dart';
import '../network/global_feed.dart';
import '../network/mesh_url.dart';
import '../network/network_common.dart';
import '../network/page_editor_screen.dart';
import '../network/post_composer.dart';
import '../network/site_view.dart';
import '../shared/transport_status_banner.dart';

/// The Network: a small browser for the mesh. `global` is the public
/// square everyone in range shares; every public key is a site — its
/// owner's home page, pages (`<key>/blog`), and posts — carried
/// device-to-device with no internet and no server.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key, this.initialUrl});

  /// Address to open first (defaults to `global`).
  final String? initialUrl;

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  late MeshUrl _url;
  final List<MeshUrl> _back = <MeshUrl>[];
  final List<MeshUrl> _forward = <MeshUrl>[];

  final TextEditingController _address = TextEditingController();
  final FocusNode _addressFocus = FocusNode();

  List<NetworkPost> _posts = const <NetworkPost>[];
  List<MeshActivityEvent> _events = const <MeshActivityEvent>[];
  NetworkNames _names = const NetworkNames();
  final Map<String, String?> _mediaPaths = <String, String?>{};

  /// Everyone I could look up by name: address → display name.
  Map<String, String> _people = const <String, String>{};
  int _meshCount = 0;
  bool _loaded = false;

  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    final initial = widget.initialUrl;
    _url = (initial == null ? null : MeshUrl.parse(initial)) ??
        const MeshUrl.global();
    _address.text = _url.toString();
    _addressFocus.addListener(() {
      if (_addressFocus.hasFocus) {
        _address.selection =
            TextSelection(baseOffset: 0, extentOffset: _address.text.length);
      } else {
        _address.text = _url.toString();
      }
    });
    _reload();
    _subs.add(NetworkService.instance.onPostsChanged.listen((_) => _reload()));
    _subs.add(MeshActivityLog.instance.onChanged.listen((_) => _reload()));
    _subs
        .add(MessengerService.instance.onPeersChanged.listen((_) => _reload()));
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------

  bool _reloading = false;
  bool _reloadQueued = false;

  /// Coalesces bursts of change events into at most one pending reload.
  Future<void> _reload() async {
    if (_reloading) {
      _reloadQueued = true;
      return;
    }
    _reloading = true;
    try {
      do {
        _reloadQueued = false;
        try {
          await _reloadOnce();
        } catch (e, st) {
          TransportLog.instance.log('Network: reload failed: $e');
          debugPrintStack(stackTrace: st, label: 'Network reload');
        }
      } while (_reloadQueued && mounted);
    } finally {
      _reloading = false;
    }
  }

  Future<void> _reloadOnce() async {
    final posts = await NetworkService.instance.listActive();
    final allEvents = await MeshActivityLog.instance.list();
    final contacts = await ContactsService.instance.listContacts();
    final me = await IdentityService.instance.getPublicAddressBase64();
    final recent = await PeerDirectory.instance.listRecent();

    final dayAgo = DateTime.now().millisecondsSinceEpoch -
        const Duration(hours: 24).inMilliseconds;
    final events = allEvents.where((e) => e.tsMs > dayAgo).take(20).toList();

    for (final post in posts) {
      final mediaId = post.mediaId;
      if (mediaId != null && !_mediaPaths.containsKey(mediaId)) {
        _mediaPaths[mediaId] = await MediaStore.instance.pathFor(mediaId);
      }
    }

    final heard = <String, String>{};
    for (final address in <String>{
      ...posts.map((p) => p.author),
      ...events.map((e) => e.address),
      ...recent.map((p) => p.address),
    }) {
      final nick =
          (await PeerDirectory.instance.get(address))?.nickname?.trim();
      if (nick != null && nick.isNotEmpty) heard[address] = nick;
    }
    final names = NetworkNames(myAddress: me, contacts: contacts, heard: heard);

    final people = <String, String>{};
    void addPerson(String address, String? carried) {
      if (address == me) return;
      final name = names.of(address, carried: carried);
      if (name != shortAddress(address)) people[address] = name;
    }

    for (final c in contacts) {
      addPerson(c.address, null);
    }
    for (final address in heard.keys) {
      addPerson(address, null);
    }
    for (final p in posts) {
      addPerson(p.author, p.authorNick);
    }

    if (_url.isGlobal) await NetworkService.instance.markSeen();
    if (!mounted) return;
    setState(() {
      _posts = posts;
      _events = events;
      _names = names;
      _people = people;
      _meshCount = recent.length;
      _loaded = true;
    });
  }

  // ---------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------

  void _go(MeshUrl url) {
    _addressFocus.unfocus();
    if (url == _url) {
      _address.text = url.toString();
      return;
    }
    setState(() {
      _back.add(_url);
      _forward.clear();
      _url = url;
      _address.text = url.toString();
    });
    if (url.isGlobal) unawaited(NetworkService.instance.markSeen());
  }

  void _goBack() {
    if (_back.isEmpty) return;
    setState(() {
      _forward.add(_url);
      _url = _back.removeLast();
      _address.text = _url.toString();
    });
  }

  void _goForward() {
    if (_forward.isEmpty) return;
    setState(() {
      _back.add(_url);
      _url = _forward.removeLast();
      _address.text = _url.toString();
    });
  }

  void _exit() => context.canPop() ? context.pop() : context.go('/home');

  void _openLink(String href) {
    if (MeshUrl.isExternal(href)) {
      _toast('Internet links don\'t open on the mesh — there is no internet '
          'here. Link to pages with a public key or /path.');
      return;
    }
    final target = MeshUrl.resolveLink(href, _url);
    if (target != null) _go(target);
  }

  void _openSite(String address) => _go(MeshUrl.site(address));

  List<_Suggestion> _suggestionsFor(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty || q == _url.toString().toLowerCase()) {
      return const <_Suggestion>[];
    }
    final out = <_Suggestion>[];
    final parsed = MeshUrl.parse(query);
    if (parsed != null && !parsed.isGlobal) {
      out.add(_Suggestion(
          parsed, 'Go to ${_labelFor(parsed)}', Icons.arrow_forward));
    }
    if (MeshUrl.globalName.startsWith(q)) {
      out.add(const _Suggestion(MeshUrl.global(), 'Global', Icons.public));
    }
    final me = _names.myAddress;
    if (me != null && ('my site'.contains(q) || 'me'.startsWith(q))) {
      out.add(_Suggestion(MeshUrl.site(me), 'My site', Icons.person_outline));
    }
    for (final entry in _people.entries) {
      if (entry.value.toLowerCase().contains(q) ||
          entry.key.toLowerCase().startsWith(q)) {
        out.add(_Suggestion(MeshUrl.site(entry.key), entry.value,
            Icons.account_circle_outlined));
      }
    }
    return out.take(8).toList();
  }

  void _submitAddress(String text) {
    final parsed = MeshUrl.parse(text);
    if (parsed != null) {
      _go(parsed);
      return;
    }
    final people = _suggestionsFor(text)
        .where((s) => s.icon == Icons.account_circle_outlined)
        .toList();
    if (people.isNotEmpty) {
      _go(people.first.url);
      return;
    }
    _addressFocus.unfocus();
    _toast('Nobody called "${text.trim()}" has reached your mesh yet. Paste '
        'their public key to visit their site.');
  }

  String _labelFor(MeshUrl url) {
    if (url.isGlobal) return 'global';
    final name = _names.of(url.site!);
    return url.path.isEmpty ? '$name\'s site' : '$name/${url.path}';
  }

  // ---------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------

  void _toast(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _copyLink(MeshUrl url) async {
    await Clipboard.setData(ClipboardData(text: url.toString()));
    _toast('Copied ${_labelFor(url)} — paste it in the Network address bar');
  }

  Future<void> _refresh() async {
    _toast('Refreshing from nearby devices…');
    await MessengerService.instance.rescan();
    await _reload();
  }

  Future<void> _newPost() async {
    final scope =
        _url.isGlobal ? EnvelopeCodec.scopeGlobal : EnvelopeCodec.scopeSite;
    final posted = await showPostComposer(context, scope: scope);
    if (!posted || !mounted) return;
    _toast('Posted. It spreads device-to-device as people move.');
  }

  Future<void> _editPage({NetworkPost? existing, String? path}) async {
    final me = _names.myAddress;
    if (me == null) return;
    final published = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PageEditorScreen(
          myAddress: me,
          existing: existing,
          initialPath: path,
        ),
      ),
    );
    if (published == null || !mounted) return;
    _go(MeshUrl.site(me, published));
  }

  Future<void> _delete(NetworkPost post) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(post.isPrivate
            ? 'Delete this private ${post.isPage ? 'page' : 'post'}?'
            : 'Remove this ${post.isPage ? 'page' : 'post'} from the mesh?'),
        content: Text(post.isPrivate
            ? 'It only exists on this device.'
            : 'It disappears here immediately, and a signed removal spreads '
                'through the mesh so every device carrying it drops it too.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await MessengerService.instance.deleteNetworkPost(post.id);
  }

  Future<void> _setPrivate(NetworkPost post, bool makePrivate) async {
    await MessengerService.instance.setNetworkPostPrivate(post.id, makePrivate);
    _toast(makePrivate
        ? 'Private now — withdrawn from the mesh, kept on this device'
        : 'Public now — it spreads to everyone your mesh reaches');
  }

  NetworkPost? _myPageHere() {
    final me = _names.myAddress;
    if (_url.site != me || me == null) return null;
    for (final p in _posts) {
      if (p.isPage && p.author == me && p.path == _url.path) return p;
    }
    return null;
  }

  Future<void> _onMenu(String action) async {
    final me = _names.myAddress;
    switch (action) {
      case 'global':
        _go(const MeshUrl.global());
      case 'mysite':
        if (me != null) _go(MeshUrl.site(me));
      case 'post':
        await _newPost();
      case 'page':
        await _editPage();
      case 'edit':
        final page = _myPageHere();
        await _editPage(existing: page, path: page == null ? _url.path : null);
      case 'copy':
        await _copyLink(_url);
    }
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = _names.myAddress;
    final onMySite = me != null && _url.site == me;

    return PopScope(
      canPop: _back.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: _back.isEmpty ? 'Close' : 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: _back.isEmpty ? _exit : _goBack,
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              if (_forward.isNotEmpty)
                IconButton(
                  tooltip: 'Forward',
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _goForward,
                ),
              Expanded(child: _addressBar(theme)),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh from nearby devices',
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
            ),
            PopupMenuButton<String>(
              tooltip: 'Menu',
              onSelected: _onMenu,
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'global',
                  child: ListTile(
                    leading: Icon(Icons.public),
                    title: Text('Global'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'mysite',
                  child: ListTile(
                    leading: Icon(Icons.person_outline),
                    title: Text('My site'),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'post',
                  child: ListTile(
                    leading: Icon(Icons.edit_note),
                    title: Text('New post…'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'page',
                  child: ListTile(
                    leading: Icon(Icons.note_add_outlined),
                    title: Text('New page…'),
                  ),
                ),
                if (onMySite)
                  PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: Text(_url.path.isEmpty
                          ? 'Edit home page'
                          : 'Edit this page'),
                    ),
                  ),
                const PopupMenuItem(
                  value: 'copy',
                  child: ListTile(
                    leading: Icon(Icons.link),
                    title: Text('Copy address'),
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            const TransportStatusBanner(),
            Expanded(
              child: !_loaded
                  ? const Center(child: CircularProgressIndicator())
                  : _url.isGlobal
                      ? GlobalFeed(
                          posts: _posts
                              .where((p) => p.isGlobal && !p.isPage)
                              .toList(),
                          names: _names,
                          mediaPaths: _mediaPaths,
                          events: _events,
                          meshCount: _meshCount,
                          onOpenSite: _openSite,
                          onDelete: _delete,
                        )
                      : SiteView(
                          key: ValueKey(_url),
                          url: _url,
                          posts: _posts,
                          names: _names,
                          mediaPaths: _mediaPaths,
                          onGo: _go,
                          onLink: _openLink,
                          onEditPage: _editPage,
                          onNewPost: () async {
                            final posted = await showPostComposer(
                              context,
                              scope: EnvelopeCodec.scopeSite,
                            );
                            if (posted && mounted) {
                              _toast('Posted to your site');
                            }
                          },
                          onDelete: _delete,
                          onSetPrivate: _setPrivate,
                          onMessage: (address) => context.push(
                              '/chat?peer=${Uri.encodeComponent(address)}'),
                          onCopyLink: _copyLink,
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addressBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: RawAutocomplete<_Suggestion>(
        textEditingController: _address,
        focusNode: _addressFocus,
        optionsBuilder: (value) => _suggestionsFor(value.text),
        displayStringForOption: (s) => s.url.toString(),
        onSelected: (s) => _go(s.url),
        fieldViewBuilder: (context, controller, focusNode, onSubmit) =>
            TextField(
          key: const ValueKey('network-address-bar'),
          controller: controller,
          focusNode: focusNode,
          textInputAction: TextInputAction.go,
          onSubmitted: _submitAddress,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            hintText: 'Search people or enter a public key',
            prefixIcon: Icon(
              _url.isGlobal
                  ? Icons.public
                  : _url.path.isEmpty
                      ? Icons.person_outline
                      : Icons.article_outlined,
              size: 18,
            ),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 36, minHeight: 36),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320, maxWidth: 480),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  for (final option in options)
                    ListTile(
                      leading: Icon(option.icon),
                      title: Text(option.label),
                      subtitle: option.url.isGlobal
                          ? null
                          : Text(
                              option.url.path.isEmpty
                                  ? shortAddress(option.url.site!)
                                  : '${shortAddress(option.url.site!)}/${option.url.path}',
                            ),
                      onTap: () => onSelected(option),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Suggestion {
  const _Suggestion(this.url, this.label, this.icon);

  final MeshUrl url;
  final String label;
  final IconData icon;
}
