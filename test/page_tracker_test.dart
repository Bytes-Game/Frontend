import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/services/page_tracker.dart';

/// Leaving a page must not throw.
///
/// It did. Every exit from the profile page produced, mid-frame:
///
///     Null check operator used on a null value
///     #3  _ProfilePageState.pageParams (profile_page.dart:76)
///     #4  PageTracker.dispose (page_tracker.dart:67)
///
/// The cause is worth stating plainly, because it is easy to reintroduce:
/// the exit event asked the page to describe itself AFTER the page had been
/// taken out of the widget tree. A page that describes itself by looking
/// something up from the tree above it — which profile does, to say whether
/// the profile is your own — has nothing left to look at.
///
/// The page below reproduces exactly that: its params read an InheritedWidget
/// through its context, which is fine while it is on screen and throws once it
/// is not.

class _LooksUpTheTree extends StatefulWidget {
  const _LooksUpTheTree();

  @override
  State<_LooksUpTheTree> createState() => _LooksUpTheTreeState();
}

class _LooksUpTheTreeState extends State<_LooksUpTheTree>
    with PageTracker<_LooksUpTheTree> {
  @override
  String get pageName => 'looks_up_the_tree';

  @override
  Map<String, dynamic> get pageParams => {
        // Throws once this State is detached — the same shape as
        // Provider.of(context) in a real page.
        'width': MediaQuery.of(context).size.width,
      };

  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// A page whose params are only known some time after it opens.
class _FillsInLater extends StatefulWidget {
  const _FillsInLater();

  @override
  State<_FillsInLater> createState() => _FillsInLaterState();
}

class _FillsInLaterState extends State<_FillsInLater>
    with PageTracker<_FillsInLater> {
  String? _conversationId;

  @override
  String get pageName => 'fills_in_later';

  @override
  Map<String, dynamic> get pageParams => {'conversationId': _conversationId};

  void arrive(String id) => setState(() => _conversationId = id);

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('leaving a page that reads the tree does not throw',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _LooksUpTheTree()));
    // Replace the page, which unmounts the old one and runs its dispose
    // inside the frame — where the original crash happened.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: 'exiting the page threw. The exit event is asking the page to '
          'describe itself after it has left the widget tree; it has to use '
          'the description taken while the page was still on screen.',
    );
  });

  testWidgets('a page that learns its params late still reports them',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _FillsInLater()));
    final state = tester.state<_FillsInLaterState>(find.byType(_FillsInLater));
    state.arrive('conv-42');
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The value that arrived after opening is the one worth carrying, so the
    // snapshot must not be allowed to freeze the page at whatever it knew in
    // initState.
    expect(state.pageParamsAtExit['conversationId'], 'conv-42');
  });
}
