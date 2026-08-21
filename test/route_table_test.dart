import 'package:flutter_test/flutter_test.dart';
import 'package:meshenger/core/services/route_table.dart';

void main() {
  setUp(() => RouteTable.instance.reset());

  test('ranks online next hops by distance; unknown destinations are empty',
      () {
    final table = RouteTable.instance;
    table.learn('dest', 'nearHop', 3);
    table.learn('dest', 'farHop', 9);
    table.learn('dest', 'offlineHop', 1);

    expect(
      table.nextHopsFor('dest', online: {'nearHop', 'farHop', 'stranger'}),
      ['nearHop', 'farHop'],
    );
    expect(table.nextHopsFor('nobody', online: {'nearHop'}), isEmpty);
  });

  test('shorter fresh routes are kept when a longer duplicate arrives', () {
    final table = RouteTable.instance;
    table.learn('dest', 'hop', 2);
    table.learn('dest', 'hop', 7); // stale info via the same neighbor
    // Still ranked (and not degraded to 7-hop quality vs a 3-hop rival).
    table.learn('dest', 'rival', 3);
    expect(
      table.nextHopsFor('dest', online: {'hop', 'rival'}),
      ['hop', 'rival'],
    );
  });

  test('keeps only the best few next hops per destination', () {
    final table = RouteTable.instance;
    for (var i = 0; i < 10; i++) {
      table.learn('dest', 'hop$i', i + 1);
    }
    final ranked = table.nextHopsFor(
      'dest',
      online: {for (var i = 0; i < 10; i++) 'hop$i'},
    );
    expect(ranked.length, lessThanOrEqualTo(4));
    expect(ranked.first, 'hop0');
  });
}
