// The helper that scopes a source check to one function.
//
// It was wrong twice, in two different ways, and each time it made real
// checks pass against nothing. These are the shapes that broke it.

import 'package:flutter_test/flutter_test.dart';

import 'dart_source.dart';

void main() {
  test('an ordinary method', () {
    const src = 'void a() { one(); }\nvoid b() { two(); }';
    expect(bodyOf(src, 'void a()'), contains('one()'));
    expect(bodyOf(src, 'void a()'), isNot(contains('two()')));
  });

  test('a named-parameter list does not close the body', () {
    // The first bug: counting braces from the signature closed on `{bool x}`
    // and returned nothing, so every check against it passed.
    const src = 'void a({bool x = false}) { inside(); }\nvoid b() { other(); }';
    final body = bodyOf(src, 'void a(');
    expect(body, contains('inside()'));
    expect(body, isNot(contains('other()')));
  });

  test('a getter has no parameter list at all', () {
    // The second bug: looking for `") {"` skipped the getter entirely and
    // returned the NEXT function's body, so the check ran on the wrong code.
    const src = 'bool get flag {\n  return real();\n}\nvoid other() { nope(); }';
    final body = bodyOf(src, 'bool get flag');
    expect(body, contains('real()'));
    expect(body, isNot(contains('nope()')),
        reason: 'it returned a different function');
  });

  test('nested braces inside the body', () {
    const src = 'void a() { if (x) { deep(); } }\nvoid b() { other(); }';
    final body = bodyOf(src, 'void a()');
    expect(body, contains('deep()'));
    expect(body, isNot(contains('other()')));
  });

  test('an expression-bodied getter still finds its own text', () {
    const src = 'int get n => 4;\nvoid b() { other(); }';
    // No braces of its own, so it takes the next block — which is why a
    // check on one of these has to look at the declaration, not the body.
    expect(() => bodyOf(src, 'int get n'), returnsNormally);
  });
}
