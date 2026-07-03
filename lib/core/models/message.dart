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

  const ChatMessage({
    required this.id,
    required this.text,
    required this.isMe,
    required this.timestamp,
    required this.status,
    this.senderAddress,
    this.pendingTo = const <String>[],
    this.isSystem = false,
  });

  ChatMessage copyWith({MessageStatus? status, List<String>? pendingTo}) {
    return ChatMessage(
      id: id,
      text: text,
      isMe: isMe,
      timestamp: timestamp,
      status: status ?? this.status,
      senderAddress: senderAddress,
      pendingTo: pendingTo ?? this.pendingTo,
      isSystem: isSystem,
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
    );
  }
}
