/// Everything that travels *inside* the encrypted envelope body.
///
/// Only the sender and the final recipient ever see these fields; relays
/// (phones in the middle, Raspberry Pi gateways) only handle ciphertext.
class MessageBody {
  final String messageId;
  final String text;
  final DateTime timestamp;

  // Group chat metadata.
  final String? groupId;
  final List<String>? groupMembers;
  final String? groupAdmin;
  final String? groupName;
  final String? groupEvent; // rename | members | leave

  // Message-level operations.
  //
  // edit | delete | story | ack |
  // call-invite | call-accept | call-decline | call-busy | call-end
  final String? action;
  final String? targetId;
  final int? ttlSeconds;

  // Media attachment (image / audio / file), base64-encoded.
  final String? kind; // image | audio | file (null => plain text)
  final String? mediaB64;
  final String? mediaName;
  final String? mediaMime;
  final bool mediaTemp; // Snapchat-style view-once
  final int? durationMs; // audio duration
  final bool voicemail;

  const MessageBody({
    required this.messageId,
    required this.text,
    required this.timestamp,
    this.groupId,
    this.groupMembers,
    this.groupAdmin,
    this.groupName,
    this.groupEvent,
    this.action,
    this.targetId,
    this.ttlSeconds,
    this.kind,
    this.mediaB64,
    this.mediaName,
    this.mediaMime,
    this.mediaTemp = false,
    this.durationMs,
    this.voicemail = false,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'id': messageId,
        'text': text,
        'ts': timestamp.millisecondsSinceEpoch,
        if (groupId != null) 'gid': groupId,
        if (groupMembers != null) 'members': groupMembers,
        if (groupAdmin != null) 'admin': groupAdmin,
        if (groupName != null) 'gname': groupName,
        if (groupEvent != null) 'gevt': groupEvent,
        if (action != null) 'act': action,
        if (targetId != null) 'target': targetId,
        if (ttlSeconds != null) 'ttl': ttlSeconds,
        if (kind != null) 'kind': kind,
        if (mediaB64 != null) 'media': mediaB64,
        if (mediaName != null) 'mname': mediaName,
        if (mediaMime != null) 'mmime': mediaMime,
        if (mediaTemp) 'mtemp': true,
        if (durationMs != null) 'dur': durationMs,
        if (voicemail) 'vm': true,
      };
}
