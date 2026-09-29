// The league shield sits in the profile box, and nowhere else.
//
// The owner asked for the shield in front of names to go everywhere except
// the box on a profile. It used to sit beside names in search results, the
// reel, the lists of who liked and voted, the battle page and under the
// name on a profile.
//
// Checked in the code of every screen, comment lines stripped, so a comment
// that mentions the shield can neither pass nor fail it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/widgets/battle_record_panel.dart';

String _code(File f) => f
    .readAsLinesSync()
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  test('only the profile box and the profile card draw the shield', () {
    final drawers = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (_code(f).contains('LeagueEmblem(')) {
        drawers.add(f.path.replaceAll('\\', '/'));
      }
    }
    drawers.sort();
    expect(drawers, [
      // The box itself: the class, and the shield in it.
      'lib/widgets/battle_record_panel.dart',
      // The same box on the profile card you open from search.
      'lib/widgets/profile_card_3d.dart',
    ]);
  });

  testWidgets('the profile box still shows it', (t) async {
    // Every other check here is about the shield NOT being somewhere; this
    // one makes sure it wasn't taken out of the one place it belongs.
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BattleRecordPanel(
            record: BattleRecord.fromJson(const {
              'rating': 1320,
              'league': 'Gold',
              'wins': 7,
              'losses': 3,
              'draws': 0,
              'counts': {'open': 0, 'live': 0, 'won': 7, 'lost': 3, 'draw': 0},
            }),
          ),
        ),
      ),
    );
    expect(find.byType(LeagueEmblem), findsOneWidget);
  });
}
