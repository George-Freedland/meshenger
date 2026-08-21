class IncomingMessage {
  final String fromAddress;
  final String id;
  final String text;
  final DateTime timestamp;

  /// Set when this message belongs to a group chat.
  final String? groupId;

  /// Full member list of the group (including the sender and me), so the
  /// receiving device can create the same group chat locally.
  final List<String>? groupMembers;

  /// Admin address for the group (included on group messages and events).
  final String? groupAdmin;

  /// Group display name, when included in a group event.
  final String? groupName;

  /// When set, this is a group metadata event rather than a chat message.
  /// Values: `rename`, `members`, `leave`.
  final String? groupEvent;

  /// Message-level action: `edit`, `delete`, `story`, `ack`, or one of the
  /// `call-*` signals. Absent for normal chat messages.
  final String? action;

  /// Target message id for `edit`/`delete`/`ack` actions, story id for
  /// `story`, call id for `call-*`.
  final String? targetId;

  /// Auto-delete TTL in seconds requested by the sender (also used as the
  /// story lifetime for `story` actions).
  final int? ttlSeconds;

  // --- Media attachment ---
  final String? kind; // image | audio | file (null => text)
  final String? mediaB64;
  final String? mediaName;
  final String? mediaMime;
  final bool mediaTemp; // view-once
  final int? durationMs;
  final bool voicemail;

  const IncomingMessage({
    required this.fromAddress,
    required this.id,
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

  bool get isGroupEvent => groupEvent != null;
}
