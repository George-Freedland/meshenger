class Contact {
  final String address; // base64 (or base64url) encoded public key
  final String? nickname;

  const Contact({
    required this.address,
    this.nickname,
  });

  Contact copyWith({String? nickname}) {
    return Contact(address: address, nickname: nickname);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'address': address,
        'nickname': nickname,
      };

  static Contact fromJson(Map<String, Object?> json) {
    return Contact(
      address: json['address'] as String,
      nickname: json['nickname'] as String?,
    );
  }
}

