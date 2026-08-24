import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

SymbolThemeLayer _layer() {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'poi',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'poi',
        'layout': {'text-field': '{name}', 'text-size': 14},
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

SymbolInstance _symbol(SymbolThemeLayer layer, String text) => SymbolInstance(
      layer: layer,
      layerIndex: 0,
      anchor: Offset.zero,
      angle: 0,
      alongLine: false,
      text: text,
      iconName: null,
      sortKey: 0,
      properties: const {},
      geometryType: 'Point',
      featureId: null,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('prewarm is resumable', () {
    late SymbolThemeLayer layer;
    late List<SymbolInstance> symbols;

    setUp(() {
      layer = _layer();
      symbols = [
        for (var i = 0; i < 8; i++) _symbol(layer, 'Label$i'),
      ];
    });

    test('shapes the whole batch when given no budget limit', () {
      final painter = LabelPainter();
      expect(painter.prewarm(symbols, 14), symbols.length);
      expect(painter.debugShapedTextCount, symbols.length);
      painter.dispose();
    });

    test('yields the resume index and always makes progress', () {
      final painter = LabelPainter();
      // A caller whose tick is already spent still shapes one label, so
      // a requeued job can never spin on the same index forever.
      var cursor = 0;
      var slices = 0;
      while (cursor < symbols.length) {
        final next =
            painter.prewarm(symbols, 14, from: cursor, outOfBudget: () => true);
        expect(next, greaterThan(cursor), reason: 'every slice advances');
        cursor = next;
        slices++;
        expect(slices, lessThanOrEqualTo(symbols.length));
      }
      expect(cursor, symbols.length);
      expect(painter.debugShapedTextCount, symbols.length,
          reason: 'sliced shaping covers exactly the same labels');
      painter.dispose();
    });

    test('a slice with budget left runs on past the first label', () {
      final painter = LabelPainter();
      var calls = 0;
      // Spend the budget after four checks — the check runs before each
      // label except the first, so five labels are shaped.
      final next =
          painter.prewarm(symbols, 14, from: 0, outOfBudget: () => ++calls > 4);
      expect(next, 5);
      expect(painter.debugShapedTextCount, 5);
      expect(painter.prewarm(symbols, 14, from: next), symbols.length);
      expect(painter.debugShapedTextCount, symbols.length);
      painter.dispose();
    });

    test('resuming re-shapes nothing already in the cache', () {
      final painter = LabelPainter();
      painter.prewarm(symbols, 14, from: 0, outOfBudget: () => true); // 1 label
      final afterFirst = painter.debugShapedTextCount;
      // Re-running the whole batch from the top must find that label
      // cached rather than shaping it twice.
      expect(painter.prewarm(symbols, 14), symbols.length);
      expect(painter.debugShapedTextCount, symbols.length);
      expect(afterFirst, 1);
      painter.dispose();
    });

    test('text-less symbols advance the cursor without shaping', () {
      final painter = LabelPainter();
      final mixed = [
        _symbol(layer, ''),
        _symbol(layer, ''),
        _symbol(layer, 'Only'),
      ];
      expect(painter.prewarm(mixed, 14), mixed.length);
      expect(painter.debugShapedTextCount, 1);
      painter.dispose();
    });

    test('an empty batch completes immediately', () {
      final painter = LabelPainter();
      expect(painter.prewarm(const [], 14), 0);
      painter.dispose();
    });
  });
}
