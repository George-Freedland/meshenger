enum MessageStatus {
  /// Waiting for the peer to come online (stored in outbox).
  pending,

  /// Handed to the transport and delivered to at least one node.
  sent,
}

class ChatMessage {
  final String id;
  final String text;
  final bool isMe;
  final DateTime timestamp;
  final MessageStatus status;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.isMe,
    required this.timestamp,
    required this.status,
  });

  ChatMessage copyWith({MessageStatus? status}) {
    return ChatMessage(
      id: id,
      text: text,
      isMe: isMe,
      timestamp: timestamp,
      status: status ?? this.status,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'text': text,
        'me': isMe,
        'ts': timestamp.millisecondsSinceEpoch,
        'status': status.name,
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
    );
  }
}
