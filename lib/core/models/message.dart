enum MessageStatus {
  /// Waiting for the peer(s) to come online (stored in outbox).
  pending,

  /// Delivered to the peer (1:1) or to every group member.
  sent,
}

class ChatMessage {
  final String id;
  final String text;
  final bool isMe;
  final DateTime timestamp;
  final MessageStatus status;

  /// For incoming group messages: the sender's address.
  final String? senderAddress;

  /// For outgoing group messages: members that have not received it yet.
  final List<String> pendingTo;

  /// Local system notice (group renamed, member added, etc.).
  final bool isSystem;

  /// True when the message text was edited after sending.
  final bool edited;

  /// Auto-delete deadline (epoch ms); message disappears after this.
  final int? expiresAtMs;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.isMe,
    required this.timestamp,
    required this.status,
    this.senderAddress,
    this.pendingTo = const <String>[],
    this.isSystem = false,
    this.edited = false,
    this.expiresAtMs,
  });

  ChatMessage copyWith({
    String? text,
    MessageStatus? status,
    List<String>? pendingTo,
    bool? edited,
  }) {
    return ChatMessage(
      id: id,
      text: text ?? this.text,
      isMe: isMe,
      timestamp: timestamp,
      status: status ?? this.status,
      senderAddress: senderAddress,
      pendingTo: pendingTo ?? this.pendingTo,
      isSystem: isSystem,
      edited: edited ?? this.edited,
      expiresAtMs: expiresAtMs,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'text': text,
        'me': isMe,
        'ts': timestamp.millisecondsSinceEpoch,
        'status': status.name,
        if (senderAddress != null) 'sender': senderAddress,
        if (pendingTo.isNotEmpty) 'pendingTo': pendingTo,
        if (isSystem) 'system': true,
        if (edited) 'edited': true,
        if (expiresAtMs != null) 'expires': expiresAtMs,
      };

  static ChatMessage fromJson(Map<String, Object?> json) {
    return ChatMessage(
      id: json['id'] as String,
      text: json['text'] as String,
      isMe: json['me'] == true,
      timestamp:
          DateTime.fromMillisecondsSinceEpoch((json['ts'] as num).toInt()),
      status: MessageStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => MessageStatus.sent,
      ),
      senderAddress: json['sender'] as String?,
      pendingTo: (json['pendingTo'] as List?)?.whereType<String>().toList() ??
          <String>[],
      isSystem: json['system'] == true,
      edited: json['edited'] == true,
      expiresAtMs: (json['expires'] as num?)?.toInt(),
    );
  }
}
