import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/contact.dart';
import 'identity_scope.dart';

class ContactsService {
  ContactsService._();
  static final ContactsService instance = ContactsService._();

  static const _contactsKey = 'contacts_v1';

  Future<List<Contact>> listContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_contactsKey));
    if (raw == null || raw.isEmpty) return <Contact>[];

    final decoded = jsonDecode(raw);
    if (decoded is! List) return <Contact>[];

    return decoded
        .whereType<Map>()
        .map((m) => Contact.fromJson(m.cast<String, Object?>()))
        .toList()
      ..sort((a, b) {
        final an = (a.nickname ?? '').toLowerCase();
        final bn = (b.nickname ?? '').toLowerCase();
        if (an.isEmpty && bn.isNotEmpty) return 1;
        if (an.isNotEmpty && bn.isEmpty) return -1;
        if (an != bn) return an.compareTo(bn);
        return a.address.compareTo(b.address);
      });
  }

  Future<void> upsertContact(Contact contact) async {
    final contacts = await listContacts();
    final idx = contacts.indexWhere((c) => c.address == contact.address);
    if (idx >= 0) {
      contacts[idx] = contact;
    } else {
      contacts.add(contact);
    }
    await _writeAll(contacts);
  }

  Future<void> deleteContact(String address) async {
    final contacts = await listContacts();
    contacts.removeWhere((c) => c.address == address);
    await _writeAll(contacts);
  }

  Future<Contact?> getContact(String address) async {
    final contacts = await listContacts();
    for (final c in contacts) {
      if (c.address == address) return c;
    }
    return null;
  }

  Future<void> _writeAll(List<Contact> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(contacts.map((c) => c.toJson()).toList());
    await prefs.setString(IdentityScope.key(_contactsKey), raw);
  }
}
