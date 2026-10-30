import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

/// Renders a site page's HTML the way a small browser would: on a white
/// canvas, with the author's own inline styles. No scripts run and nothing
/// is fetched — pages come from strangers, and loading an internet image
/// would tell its host who is reading. Images must be inline (`data:`).
class MeshHtmlView extends StatelessWidget {
  const MeshHtmlView({super.key, required this.html, required this.onLink});

  final String html;

  /// Called with the raw `href` of a tapped link.
  final void Function(String href) onLink;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: HtmlWidget(
          html,
          factoryBuilder: _OfflineWidgetFactory.new,
          onTapUrl: (url) {
            onLink(url);
            return true;
          },
          textStyle: const TextStyle(
            color: Color(0xFF1A1A1A),
            fontSize: 16,
            height: 1.45,
          ),
        ),
      ),
    );
  }
}

class _OfflineWidgetFactory extends WidgetFactory {
  @override
  ImageProvider? imageProviderFromNetwork(String url) => null;

  @override
  ImageProvider? imageProviderFromFileUri(String url) => null;

  @override
  ImageProvider? imageProviderFromAsset(String url) => null;
}
