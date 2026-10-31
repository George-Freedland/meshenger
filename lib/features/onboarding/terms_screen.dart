import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/safety_service.dart';

/// The bundled TERMS.md, rendered as headings, bullets and paragraphs.
class TermsText extends StatefulWidget {
  const TermsText({super.key});

  @override
  State<TermsText> createState() => _TermsTextState();
}

class _TermsTextState extends State<TermsText> {
  late final Future<String> _terms = rootBundle.loadString('TERMS.md');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<String>(
      future: _terms,
      builder: (context, snapshot) {
        final text = snapshot.data;
        if (text == null) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in text.trim().split('\n'))
              if (line.trim().isEmpty)
                const SizedBox(height: 8)
              else if (line.startsWith('# '))
                Text(line.substring(2), style: theme.textTheme.headlineSmall)
              else if (line.startsWith('## '))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(line.substring(3),
                      style: theme.textTheme.titleMedium),
                )
              else if (line.startsWith('- '))
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(child: Text(line.substring(2))),
                    ],
                  ),
                )
              else
                Text(line, style: theme.textTheme.bodyMedium),
          ],
        );
      },
    );
  }
}

/// Shown once per device, before anything else.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  Future<void> _agree(BuildContext context) async {
    await SafetyService.instance.acceptTerms();
    if (context.mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: const TermsText(),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: FilledButton(
                    onPressed: () => _agree(context),
                    child: const Text('Agree and continue'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
