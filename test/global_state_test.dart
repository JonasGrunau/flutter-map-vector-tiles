import 'dart:ui' show Color;

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/lifecycle_harness.dart';

/// A map whose land colour is global state.
Theme _statefulLand() => const ThemeReader().read({
      'state': {
        'land': {'default': '#ff0000'},
      },
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#0000ff'},
        },
        {
          'id': 'land',
          'type': 'fill',
          'source': 's',
          'source-layer': 'land',
          'paint': {
            'fill-color': [
              'to-color',
              ['global-state', 'land']
            ],
          },
        },
      ],
    });

void main() {
  testWidgets(
      'another global state redraws in place: the old imagery holds until '
      'the new one lands', (tester) async {
    final provider = EverywhereProvider(fullTile());
    final controller = MapController();
    final theme = _statefulLand();
    const red = Color(0xffff0000);
    const green = Color(0xff00ff00);

    await tester.pumpWidget(app(controller, provider, theme: theme));
    expect(await settle(tester), isTrue);
    await settleLoads(tester, provider);

    /// Switches to [next] and records the centre on every frame until it
    /// shows [until].
    Future<Set<Color>> switchTo(Theme next, Color until) async {
      final seen = <Color>{};
      await tester.pumpWidget(app(controller, provider, theme: next));
      final arrived = await pumpUntil(tester, () async {
        final c = await centrePixel(tester);
        seen.add(c);
        return c == until;
      });
      expect(arrived, isTrue, reason: 'never showed $until; saw $seen');
      return seen;
    }

    // A theme swap clears the tiles and the background shows through
    // until they are drawn again; a sibling theme must not.
    expect(await switchTo(theme.withGlobalState({'land': '#00ff00'}), green),
        everyElement(isIn([red, green])));
    // Back to the default: the very theme the map started with.
    expect(theme.withGlobalState(const {}), same(theme));
    expect(await switchTo(theme, red), everyElement(isIn([red, green])));
  });
}
