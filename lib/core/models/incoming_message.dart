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

  const IncomingMessage({
    required this.fromAddress,
    required this.id,
    required this.text,
    required this.timestamp,
    this.groupId,
    this.groupMembers,
  });
}
