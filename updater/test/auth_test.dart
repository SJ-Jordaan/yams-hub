import 'package:test/test.dart';
import 'package:yams_hub_updater/yams_hub_updater.dart';

void main() {
  const token = 'Zk3n_aQ0x9cV-7yL2mB5tR8wE1uI4oP6sD0fG3hJ6kL9zX2c';
  final auth = BearerAuth(token);

  test('accepts the exact bearer token, any scheme case', () {
    expect(auth.accepts('Bearer $token'), isTrue);
    expect(auth.accepts('bearer $token'), isTrue);
    expect(auth.accepts('BEARER  $token'), isTrue);
  });

  test('rejects everything else', () {
    expect(auth.accepts(null), isFalse);
    expect(auth.accepts(''), isFalse);
    expect(auth.accepts(token), isFalse);
    expect(auth.accepts('Basic $token'), isFalse);
    expect(auth.accepts('Bearer ${token.substring(1)}'), isFalse);
    expect(auth.accepts('Bearer ${token}x'), isFalse);
    expect(auth.accepts('Bearer $token extra'), isFalse);
    expect(auth.accepts('Bearer '), isFalse);
  });

  test('constantTimeEquals', () {
    expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
    expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
    expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
    expect(constantTimeEquals([], []), isTrue);
  });
}
