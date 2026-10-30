import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/services/identity_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/network_service.dart';
import '../../core/transport/envelope_codec.dart';
import '../../core/ui/media_widgets.dart';
import 'mesh_html_view.dart';
import 'mesh_url.dart';
import 'network_common.dart';

const _pageLifetimes = <(int, String)>[
  (604800, '1 week'),
  (2592000, '30 days'),
  (7776000, '90 days'),
];

/// Writes or edits a page of my site. Pops with the published path, or
/// null when closed without publishing.
class PageEditorScreen extends StatefulWidget {
  const PageEditorScreen({
    super.key,
    required this.myAddress,
    this.existing,
    this.initialPath,
  });

  final String myAddress;

  /// The version being edited; null for a new page.
  final NetworkPost? existing;

  /// Where a new page goes ('' = home page); null lets me choose.
  final String? initialPath;

  @override
  State<PageEditorScreen> createState() => _PageEditorScreenState();
}

class _PageEditorScreenState extends State<PageEditorScreen> {
  late final TextEditingController _path;
  late final TextEditingController _title;
  late final TextEditingController _html;
  late bool _private = widget.existing?.isPrivate ?? false;
  int _ttlSeconds = 2592000;
  bool _preview = false;
  bool _publishing = false;
  String? _error;

  bool get _isHome => (widget.existing?.path ?? widget.initialPath) == '';

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final path = existing?.path ?? widget.initialPath ?? '';
    final nickname = IdentityService.instance.active?.nickname?.trim();
    final name = (nickname == null || nickname.isEmpty) ? 'me' : nickname;
    _path = TextEditingController(text: path);
    _title = TextEditingController(
      text: existing?.title ?? (path.isEmpty ? '$name\'s site' : ''),
    );
    _html = TextEditingController(
      text: existing?.text ??
          (path.isEmpty ? _homeTemplate(name) : _pageTemplate()),
    );
    _html.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _path.dispose();
    _title.dispose();
    _html.dispose();
    super.dispose();
  }

  static String _homeTemplate(String name) => '''
<h1>Hi, I'm $name 👋</h1>
<p>This is my corner of the mesh. Anyone nearby can open it — no internet, no server.</p>

<h2>My pages</h2>
<ul>
  <li><a href="/blog">Blog</a></li>
</ul>

<p style="color:#666">Links starting with / go to my other pages. Link to someone else's site with their public key.</p>
''';

  static String _pageTemplate() => '''
<h1>A new page</h1>
<p>Write anything here: <b>bold</b>, <i>italic</i>, lists, images…</p>
<p><a href="/">← Back to my home page</a></p>
''';

  int get _sizeBytes => utf8.encode(_html.text).length;

  void _wrapSelection(String before, [String after = '']) {
    final value = _html.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final selected = text.substring(start, end);
    final inserted = '$before$selected$after';
    _html.value = TextEditingValue(
      text: text.replaceRange(start, end, inserted),
      selection: TextSelection.collapsed(
        offset: start + before.length + selected.length,
      ),
    );
  }

  Future<void> _insertImage() async {
    final picked =
        await pickImage(fromCamera: false, maxWidth: 800, imageQuality: 60);
    if (picked == null) return;
    final tag =
        '<img src="data:${picked.mime};base64,${base64Encode(picked.bytes)}" alt="">';
    if (_sizeBytes + tag.length > EnvelopeCodec.maxPageBytes) {
      setState(() => _error =
          'That image would push the page over 96 KB. Pick a smaller one.');
      return;
    }
    _wrapSelection(tag);
  }

  Future<void> _publish() async {
    final path = _isHome ? '' : MeshUrl.normalizePath(_path.text);
    if (path == null || (!_isHome && path.isEmpty)) {
      setState(() => _error = 'Give the page an address like "blog" or '
          '"blog/day-1": lowercase letters, numbers, - and _.');
      return;
    }
    setState(() {
      _publishing = true;
      _error = null;
    });
    try {
      await MessengerService.instance.publishSitePage(
        path: path,
        title: _title.text,
        html: _html.text,
        ttlSeconds: _ttlSeconds,
        isPrivate: _private,
        replacingId: widget.existing?.id,
      );
      if (mounted) Navigator.pop(context, path);
    } catch (e) {
      setState(() {
        _publishing = false;
        _error = e is StateError ? e.message : '$e';
      });
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this page?'),
        content: const Text('It disappears here, and a signed removal spreads '
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
    await MessengerService.instance.deleteNetworkPost(existing.id);
    if (mounted) Navigator.pop(context, '');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final size = _sizeBytes;
    final tooBig = size > EnvelopeCodec.maxPageBytes;
    final title = _isHome
        ? 'Home page'
        : widget.existing != null
            ? 'Edit page'
            : 'New page';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (widget.existing != null)
            IconButton(
              tooltip: 'Delete page',
              icon: const Icon(Icons.delete_outline),
              onPressed: _publishing ? null : _delete,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _publishing || tooBig ? null : _publish,
              child: Text(_publishing
                  ? 'Saving…'
                  : _private
                      ? 'Save'
                      : 'Publish'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _path,
            enabled: !_isHome,
            decoration: InputDecoration(
              labelText: 'Page address',
              prefixText: '${shortAddress(widget.myAddress)}/',
              helperText: _isHome
                  ? 'Your home page lives at your public key itself'
                  : 'Like blog or blog/day-1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.code, size: 18),
                    label: Text('Code'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.visibility_outlined, size: 18),
                    label: Text('Preview'),
                  ),
                ],
                selected: {_preview},
                onSelectionChanged: (s) => setState(() => _preview = s.first),
              ),
              const Spacer(),
              Text(
                '${(size / 1024).toStringAsFixed(1)} KB of 96 KB',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tooBig ? theme.colorScheme.error : muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_preview)
            MeshHtmlView(
              html: _html.text,
              onLink: (_) => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Links work once published')),
              ),
            )
          else ...[
            Wrap(
              spacing: 4,
              children: [
                _InsertButton('Heading', Icons.title,
                    () => _wrapSelection('<h2>', '</h2>')),
                _InsertButton('Bold', Icons.format_bold,
                    () => _wrapSelection('<b>', '</b>')),
                _InsertButton('Italic', Icons.format_italic,
                    () => _wrapSelection('<i>', '</i>')),
                _InsertButton('Link to a page', Icons.link,
                    () => _wrapSelection('<a href="/blog">', '</a>')),
                _InsertButton(
                    'List',
                    Icons.format_list_bulleted,
                    () => _wrapSelection(
                        '<ul>\n  <li>', '</li>\n  <li></li>\n</ul>')),
                _InsertButton('Divider', Icons.horizontal_rule,
                    () => _wrapSelection('<hr>')),
                _InsertButton('Image', Icons.image_outlined, _insertImage),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _html,
              minLines: 14,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                hintText: '<h1>Hello mesh</h1>',
                alignLabelWithHint: true,
              ),
            ),
          ],
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary:
                Icon(_private ? Icons.lock_outline : Icons.public_outlined),
            title: const Text('Private'),
            subtitle: Text(_private
                ? 'Only you can see it — it stays on this device.'
                : 'Anyone your mesh reaches can open it.'),
            value: _private,
            onChanged: (v) => setState(() => _private = v),
          ),
          if (!_private) ...[
            const SizedBox(height: 4),
            Text('Devices carry it for', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final (seconds, label) in _pageLifetimes)
                  ChoiceChip(
                    label: Text(label),
                    selected: _ttlSeconds == seconds,
                    onSelected: (_) => setState(() => _ttlSeconds = seconds),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Your own device keeps serving it to everyone it meets for as '
              'long as it lives.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

class _InsertButton extends StatelessWidget {
  const _InsertButton(this.label, this.icon, this.onPressed);

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: label,
        icon: Icon(icon, size: 20),
        onPressed: onPressed,
      );
}
