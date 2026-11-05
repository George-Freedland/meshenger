import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/models/contact.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/peer_directory.dart';
import '../../core/transport/envelope_codec.dart';

/// The QR payload for [address] (see [normalizeScannedAddress]). It also
/// carries this identity's X25519 encryption key, so whoever scans it can
/// send end-to-end encrypted messages immediately, through any number of
/// relays, without waiting for gossip to deliver the key.
Future<String> myContactQrPayload(String address) async {
  try {
    final x25519 = await EnvelopeCodec.myX25519Base64();
    return 'meshenger:$address:$x25519';
  } catch (_) {
    // Identity locked mid-flight; an address-only QR still works.
    return 'meshenger:$address';
  }
}

/// QR payloads are `meshenger:<address>[:<x25519 key>]`. This returns
/// just the address; [extractScannedKey] pulls the optional key.
String normalizeScannedAddress(String raw) {
  var v = raw.trim();
  if (v.startsWith('meshenger:')) {
    v = v.substring('meshenger:'.length);
  }
  final sep = v.indexOf(':');
  if (sep > 0) v = v.substring(0, sep);
  return v.trim();
}

/// The encryption key embedded in a scanned QR, when present. Seeding it
/// lets the mesh carry encrypted messages to this contact immediately —
/// no need to wait for gossip to propagate their key across the mesh.
String? extractScannedKey(String raw) {
  var v = raw.trim();
  if (v.startsWith('meshenger:')) {
    v = v.substring('meshenger:'.length);
  }
  final sep = v.indexOf(':');
  if (sep <= 0 || sep >= v.length - 1) return null;
  final key = v.substring(sep + 1).trim();
  return key.isEmpty ? null : key;
}

/// Shared add-contact dialog (manual paste or QR scan). Returns true when
/// a contact was added.
Future<bool> showAddContactDialog(BuildContext context) async {
  final manualController = TextEditingController();
  final nicknameController = TextEditingController();
  String? error;
  bool showScanner = false;
  bool added = false;

  Future<bool> addContact(String rawAddress, String nickname) async {
    final address = normalizeScannedAddress(rawAddress);
    if (address.isEmpty) {
      error = 'Please enter an address';
      return false;
    }
    await ContactsService.instance.upsertContact(
      Contact(
        address: address,
        nickname: nickname.trim().isEmpty ? null : nickname.trim(),
      ),
    );
    // A QR-carried encryption key enables end-to-end encrypted sending
    // right away, even to someone far beyond gossip range.
    final scannedKey = extractScannedKey(rawAddress);
    if (scannedKey != null) {
      await PeerDirectory.instance.seedKey(address, scannedKey);
    }
    return true;
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setModalState) {
          return Dialog(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Add contact',
                        style: Theme.of(dialogContext).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: manualController,
                              decoration: const InputDecoration(
                                labelText: 'Public address',
                                hintText: 'meshenger:… or base64 public key',
                              ),
                              minLines: 1,
                              maxLines: 3,
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Scan QR with camera',
                            icon: const Icon(Icons.qr_code_scanner),
                            onPressed: () {
                              setModalState(() {
                                showScanner = !showScanner;
                              });
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (showScanner) ...[
                        // Fixed-size scanner avoids intrinsic sizing issues
                        // in dialogs (web).
                        SizedBox(
                          height: 260,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: MobileScanner(
                              onDetect: (capture) async {
                                final barcodes = capture.barcodes;
                                if (barcodes.isEmpty) return;
                                final raw = barcodes.first.rawValue;
                                if (raw == null || raw.isEmpty) return;
                                // Keep the raw payload so the embedded key
                                // survives until Add is pressed.
                                setModalState(() {
                                  manualController.text = raw;
                                  showScanner = false;
                                });
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      TextField(
                        controller: nicknameController,
                        decoration: const InputDecoration(
                          labelText: 'Nickname (optional)',
                        ),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(dialogContext).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () async {
                              try {
                                error = null;
                                final ok = await addContact(
                                  manualController.text,
                                  nicknameController.text,
                                );
                                if (ok) {
                                  added = true;
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext);
                                  }
                                } else {
                                  setModalState(() {});
                                }
                              } catch (e) {
                                setModalState(
                                    () => error = 'Failed to add: $e');
                              }
                            },
                            child: const Text('Add'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
  return added;
}

/// Shared nickname editor for an existing contact. Returns true on save.
Future<bool> showEditContactDialog(
    BuildContext context, Contact contact) async {
  final controller = TextEditingController(text: contact.nickname ?? '');
  var saved = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Edit nickname'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Nickname'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final nick = controller.text.trim();
            await ContactsService.instance.upsertContact(
              contact.copyWith(nickname: nick.isEmpty ? null : nick),
            );
            saved = true;
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  return saved;
}
