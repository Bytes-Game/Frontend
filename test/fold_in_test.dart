// Rows and tiles that fold into place as they scroll into view.
//
// What matters about an effect like this is mostly what must NOT happen:
// an item stuck half-faded, a tap that misses because the item is drawn
// somewhere other than where it is, motion for somebody who asked their
// phone for none. Each of those is checked here — and, so a test that only
// checks for absence cannot pass by the effect never running at all, one
// test checks that it does run.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/widgets/fold_in.dart';

import 'support/dart_source.dart';

/// The fade FoldIn draws [key]'s item with right now, or null when it is
/// drawn plainly.
int? fadeOf(WidgetTester t, Key key) {
  final box = t.renderObject(find.byKey(key));
  RenderObject? r = box;
  // The fold is drawn by the FoldIn's own render object, just above.
  while (r != null && r.runtimeType.toString() != '_RenderReveal') {
    r = r.parent;
  }
  final layer = (r as dynamic)?.layer;
  if (layer is! TransformLayer) return null;
  final fade = layer.firstChild;
  return fade is OpacityLayer ? fade.alpha : null;
}

Widget list({int count = 12, bool still = false, VoidCallback? onTap}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(400, 800), disableAnimations: still),
      child: Scaffold(
        body: ListView(
          children: [
            for (var i = 0; i < count; i++)
              FoldIn(
                order: i,
                depth: true,
                child: GestureDetector(
                  onTap: i == 0 ? onTap : null,
                  child: SizedBox(
                    key: ValueKey('row$i'),
                    height: 100,
                    child: Text('row $i'),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('it runs: rows start folded and faded, one after another',
      (t) async {
    await t.pumpWidget(list());
    await t.pump(); // the first frame tells each row it has been seen
    await t.pump(const Duration(milliseconds: 120));
    final first = fadeOf(t, const ValueKey('row0'));
    final fourth = fadeOf(t, const ValueKey('row3'));
    expect(first, isNotNull, reason: 'the first row is not folding in');
    expect(first, greaterThan(0));
    expect(fourth, isNotNull);
    expect(fourth, lessThan(first!), reason: 'rows did not come in turn');
  });

  testWidgets('every row ends drawn plainly — nothing stuck half way',
      (t) async {
    await t.pumpWidget(list());
    await t.pumpAndSettle();
    // The rows on screen (the test screen is 600 high: rows 0 to 5).
    for (var i = 0; i < 6; i++) {
      expect(fadeOf(t, ValueKey('row$i')), isNull, reason: 'row $i');
    }
  });

  testWidgets('a tap mid-fold still works', (t) async {
    var taps = 0;
    await t.pumpWidget(list(onTap: () => taps++));
    await t.pump();
    await t.pump(const Duration(milliseconds: 150));
    expect(fadeOf(t, const ValueKey('row0')), isNotNull,
        reason: 'not mid-fold, so this checks nothing');
    await t.tap(find.text('row 0'), warnIfMissed: false);
    expect(taps, 1);
  });

  testWidgets('rows leaving the top lean away; back in, they are flat',
      (t) async {
    await t.pumpWidget(list());
    await t.pumpAndSettle();
    await t.drag(find.byType(ListView), const Offset(0, -150));
    await t.pump();
    expect(fadeOf(t, const ValueKey('row1')), isNotNull,
        reason: 'row 1 is half off the top and drawn plainly');
    await t.drag(find.byType(ListView), const Offset(0, 150));
    await t.pumpAndSettle();
    expect(fadeOf(t, const ValueKey('row1')), isNull);
  });

  testWidgets('no motion for anybody who asked for none', (t) async {
    await t.pumpWidget(list(still: true));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(fadeOf(t, const ValueKey('row0')), isNull);
    expect(fadeOf(t, const ValueKey('row3')), isNull);
  });

  test('the search grids and the chat list use it', () {
    String code(String path) => File(path)
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    final search = code('lib/pages/search_page.dart');
    expect(bodyOf(search, 'Widget _buildEmptyStateGrid'),
        contains('FoldIn('), reason: 'the explore grid lost it');
    expect(bodyOf(search, 'Widget _challengeGrid'), contains('FoldIn('),
        reason: 'the results grid lost it');
    final chats = code('lib/pages/chat_list_page.dart');
    expect(bodyOf(chats, 'Widget build(BuildContext context)'),
        contains('FoldIn('), reason: 'the chat list lost it');
  });
}
