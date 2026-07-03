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
  });

  bool get isGroupEvent => groupEvent != null;
}
