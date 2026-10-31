// What PageCoverObserver tells a page, through a real navigator: when
// another page opens on top of it, and when it is the page on top again.
// Sheets do not count. The reels feed relies on exactly this; see
// covered_feed_test.dart for the feed itself.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/page_cover_observer.dart';

/// Writes down what it hears.
class _Heard with RouteAware {
  final List<String> said = [];

  @override
  void didPushNext() => said.add('covered');

  @override
  void didPopNext() => said.add('on top');
}

MaterialPageRoute<void> _page(String words) =>
    MaterialPageRoute<void>(builder: (_) => Scaffold(body: Text(words)));

void main() {
  late GlobalKey<NavigatorState> nav;

  Future<_Heard> openOn(WidgetTester t, Route<dynamic> route) async {
    final heard = _Heard();
    PageCoverObserver.instance.subscribe(heard, route as PageRoute<dynamic>);
    addTearDown(() => PageCoverObserver.instance.unsubscribe(heard));
    return heard;
  }

  Future<_Heard> home(WidgetTester t) async {
    nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [PageCoverObserver.instance],
        home: const Scaffold(body: Text('home')),
      ),
    );
    return openOn(t, ModalRoute.of(t.element(find.text('home')))!);
  }

  testWidgets('a page on top: covered, then on top again when it closes', (
    t,
  ) async {
    final heard = await home(t);
    nav.currentState!.push(_page('a'));
    await t.pumpAndSettle();
    expect(heard.said, ['covered']);
    nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(heard.said, ['covered', 'on top']);
  });

  testWidgets('a sheet is not a page: nothing is said', (t) async {
    final heard = await home(t);
    showModalBottomSheet<void>(
      context: nav.currentContext!,
      builder: (_) => const Text('sheet'),
    );
    await t.pumpAndSettle();
    expect(find.text('sheet'), findsOneWidget);
    expect(heard.said, isEmpty);
  });

  testWidgets('a page opened from a sheet covers the page under the sheet, '
      'and closing it leaves that page on top again', (t) async {
    final heard = await home(t);
    showModalBottomSheet<void>(
      context: nav.currentContext!,
      builder: (_) => const Text('sheet'),
    );
    await t.pumpAndSettle();
    nav.currentState!.push(_page('from the sheet'));
    await t.pumpAndSettle();
    expect(heard.said, ['covered']);
    nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(find.text('sheet'), findsOneWidget, reason: 'the sheet is still up');
    expect(heard.said, ['covered', 'on top']);
  });

  testWidgets('a page that closes is not told it is covered: it is gone', (
    t,
  ) async {
    await home(t);
    final a = _page('a');
    nav.currentState!.push(a);
    await t.pumpAndSettle();
    final heard = await openOn(t, a);
    nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(find.text('a'), findsNothing);
    expect(heard.said, isEmpty);
  });

  testWidgets('a second page on top of the first: only the one directly '
      'under it is told, once', (t) async {
    final heard = await home(t);
    final a = _page('a');
    nav.currentState!.push(a);
    await t.pumpAndSettle();
    final heardA = await openOn(t, a);
    nav.currentState!.push(_page('b'));
    await t.pumpAndSettle();
    expect(heard.said, ['covered'], reason: 'home was already covered');
    expect(heardA.said, ['covered']);
    nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(heardA.said, ['covered', 'on top']);
    expect(heard.said, ['covered'], reason: 'a is still over home');
  });
}
