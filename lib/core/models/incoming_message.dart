class IncomingMessage {
  final String fromAddress;
  final String id;
  final String text;
  final DateTime timestamp;

  const IncomingMessage({
    required this.fromAddress,
    required this.id,
    required this.text,
    required this.timestamp,
  });
}
