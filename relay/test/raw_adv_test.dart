import 'package:meshenger_relay/meshenger_relay.dart';
import 'package:test/test.dart';

// The raw-HCI fallback programs the controller's legacy advertising
// registers directly, so the parameter blocks must be byte-exact.
void main() {
  group('rawAdvDataParam', () {
    final param = BleTransport.rawAdvDataParam(BleTransport.serviceUuid);

    test('is a full 32-byte parameter block of hex pairs', () {
      expect(param, hasLength(32));
      for (final byte in param) {
        expect(byte, matches(RegExp(r'^[0-9a-f]{2}$')));
      }
    });

    test('declares 21 significant bytes: flags + 128-bit UUID', () {
      expect(param[0], '15'); // 3 (flags TLV) + 18 (UUID TLV)
      expect(param.sublist(1, 4), ['02', '01', '06']); // LE general disc.
      expect(param.sublist(4, 6), ['11', '07']); // complete 128-bit list
    });

    test('carries the service UUID little-endian (reversed)', () {
      // Textual UUID 4d455348-...-4c4530303031 ends in byte 0x31 and
      // starts with 0x4d — on air those swap ends.
      expect(param[6], '31');
      expect(param[21], '4d');
    });

    test('zero-pads the tail', () {
      expect(param.sublist(22), everyElement('00'));
    });
  });

  group('rawScanRspParam', () {
    test('encodes a short name as a complete-local-name TLV', () {
      final param = BleTransport.rawScanRspParam('Pi Gateway');
      expect(param, hasLength(32));
      expect(param[0], '0c'); // 12 significant bytes: 2 + name(10)
      expect(param[1], '0b'); // TLV length: type byte + 10 name bytes
      expect(param[2], '09'); // Complete Local Name
      expect(param.sublist(3, 13),
          ['50', '69', '20', '47', '61', '74', '65', '77', '61', '79']);
      expect(param.sublist(13), everyElement('00'));
    });

    test('truncates long names to the 31-byte legacy PDU', () {
      final param = BleTransport.rawScanRspParam('X' * 40);
      expect(param, hasLength(32));
      expect(param[0], '1f'); // 31 significant bytes: 2 + 29
      expect(param[1], '1e'); // 30: type byte + 29 name bytes
      expect(param.sublist(3, 32), everyElement('58')); // 'X'
    });
  });
}
