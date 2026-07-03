class GroupInfo {
  final String id;
  final String adminAddress;
  final String? name;
  final List<String> members;

  const GroupInfo({
    required this.id,
    required this.adminAddress,
    required this.members,
    this.name,
  });

  bool isAdmin(String address) => adminAddress == address;

  bool contains(String address) => members.contains(address);

  GroupInfo copyWith({
    String? adminAddress,
    String? name,
    List<String>? members,
    bool clearName = false,
  }) {
    return GroupInfo(
      id: id,
      adminAddress: adminAddress ?? this.adminAddress,
      name: clearName ? null : (name ?? this.name),
      members: members ?? this.members,
    );
  }

  String displayTitle(String? myAddress, String Function(String) labelFor) {
    if (name != null && name!.trim().isNotEmpty) return name!.trim();
    final others = members.where((a) => a != myAddress).toList();
    if (others.isEmpty) return 'Group chat';
    return others.map(labelFor).join(', ');
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'admin': adminAddress,
        'name': name,
        'members': members,
      };

  static GroupInfo fromJson(Map<String, Object?> json) {
    return GroupInfo(
      id: json['id'] as String,
      adminAddress: json['admin'] as String,
      name: json['name'] as String?,
      members: (json['members'] as List?)?.whereType<String>().toList() ??
          <String>[],
    );
  }
}

/// A group metadata update sent over the transport (rename, membership change).
class GroupEvent {
  final String groupId;
  final String actorAddress;
  final String adminAddress;
  final String? name;
  final List<String> members;

  /// `rename`, `members`, or `leave`.
  final String action;

  const GroupEvent({
    required this.groupId,
    required this.actorAddress,
    required this.adminAddress,
    required this.members,
    required this.action,
    this.name,
  });
}
