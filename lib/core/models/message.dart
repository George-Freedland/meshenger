enum MessageStatus {
  /// Waiting for a route (stored in outbox / relay spool).
  pending,

  /// Handed to the mesh: accepted by the peer directly or by ≥1 relay.
  sent,

  /// The recipient's device confirmed receipt (end-to-end ack).
  delivered,

  /// No delivery confirmation within the deadline — likely a gap in the
  /// mesh (not enough nodes between sender and recipient). Background
  /// retries continue and a late ack still flips this to delivered; the
  /// user can also manually resend, without limit.
  failed,
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

  /// For outgoing group messages: members whose device confirmed receipt.
  final List<String> deliveredTo;

  /// Local system notice (group renamed, member added, etc.).
  final bool isSystem;

  /// True when the message text was edited after sending.
  final bool edited;

  /// Auto-delete deadline (epoch ms); message disappears after this.
  final int? expiresAtMs;

  // --- Media attachment ---
  final String? kind; // image | audio | file (null => text)
  final String? mediaId; // id in the local MediaStore
  final String? mediaName;
  final String? mediaMime;
  final bool mediaTemp; // Snapchat-style view-once
  final int? durationMs; // audio duration
  final bool voicemail;

  /// For view-once media: set after the receiver opened it (media deleted).
  final bool viewed;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.isMe,
    required this.timestamp,
    required this.status,
    this.senderAddress,
    this.pendingTo = const <String>[],
    this.deliveredTo = const <String>[],
    this.isSystem = false,
    this.edited = false,
    this.expiresAtMs,
    this.kind,
    this.mediaId,
    this.mediaName,
    this.mediaMime,
    this.mediaTemp = false,
    this.durationMs,
    this.voicemail = false,
    this.viewed = false,
  });

  ChatMessage copyWith({
    String? text,
    MessageStatus? status,
    List<String>? pendingTo,
    List<String>? deliveredTo,
    bool? edited,
    bool? viewed,
    String? mediaId,
    bool clearMedia = false,
  }) {
    return ChatMessage(
      id: id,
      text: text ?? this.text,
      isMe: isMe,
      timestamp: timestamp,
      status: status ?? this.status,
      senderAddress: senderAddress,
      pendingTo: pendingTo ?? this.pendingTo,
      deliveredTo: deliveredTo ?? this.deliveredTo,
      isSystem: isSystem,
      edited: edited ?? this.edited,
      expiresAtMs: expiresAtMs,
      kind: kind,
      mediaId: clearMedia ? null : (mediaId ?? this.mediaId),
      mediaName: mediaName,
      mediaMime: mediaMime,
      mediaTemp: mediaTemp,
      durationMs: durationMs,
      voicemail: voicemail,
      viewed: viewed ?? this.viewed,
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
        if (deliveredTo.isNotEmpty) 'deliveredTo': deliveredTo,
        if (isSystem) 'system': true,
        if (edited) 'edited': true,
        if (expiresAtMs != null) 'expires': expiresAtMs,
        if (kind != null) 'kind': kind,
        if (mediaId != null) 'mediaId': mediaId,
        if (mediaName != null) 'mediaName': mediaName,
        if (mediaMime != null) 'mediaMime': mediaMime,
        if (mediaTemp) 'mediaTemp': true,
        if (durationMs != null) 'dur': durationMs,
        if (voicemail) 'vm': true,
        if (viewed) 'viewed': true,
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
      deliveredTo:
          (json['deliveredTo'] as List?)?.whereType<String>().toList() ??
              <String>[],
      isSystem: json['system'] == true,
      edited: json['edited'] == true,
      expiresAtMs: (json['expires'] as num?)?.toInt(),
      kind: json['kind'] as String?,
      mediaId: json['mediaId'] as String?,
      mediaName: json['mediaName'] as String?,
      mediaMime: json['mediaMime'] as String?,
      mediaTemp: json['mediaTemp'] == true,
      durationMs: (json['dur'] as num?)?.toInt(),
      voicemail: json['vm'] == true,
      viewed: json['viewed'] == true,
    );
  }
}
