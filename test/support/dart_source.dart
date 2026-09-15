import 'package:flutter_test/flutter_test.dart';

/// The body of one declaration, braces balanced.
///
/// Scoping a source check to one function is what stops it matching a line
/// somewhere else in a five-thousand-line file and passing for the wrong
/// reason. Getting the START of the body right turned out to be the hard
/// part, and it was wrong twice in different ways:
///
///   * counting braces from the signature closes on a named-parameter list,
///     `({String url = ''})`, and returns an empty body — a check that
///     quietly stops checking;
///   * looking for `') {'` instead skips getters, which have no parameter
///     list at all, and silently returns some LATER function's body — so
///     the check runs against the wrong code entirely.
///
/// So: if a parameter list opens before the body does, step over it to its
/// matching `)` first. Otherwise the next `{` is the body. That covers
/// methods, getters, named parameters and generics alike.
///
/// Shared rather than copied because it had been copied, and each copy grew
/// its own version of the same bug.
String bodyOf(String src, String signature) {
  final at = src.indexOf(signature);
  expect(at, greaterThan(-1), reason: 'could not find $signature');

  var i = at + signature.length;
  final paren = src.indexOf('(', at);
  final brace = src.indexOf('{', at);
  expect(brace, greaterThan(-1), reason: 'no body found for $signature');

  if (paren > -1 && paren < brace) {
    var depth = 0;
    for (i = paren; i < src.length; i++) {
      if (src[i] == '(') depth++;
      if (src[i] == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
  } else {
    i = at;
  }

  final open = src.indexOf('{', i);
  expect(open, greaterThan(-1), reason: 'no body found for $signature');

  var depth = 0;
  for (var j = open; j < src.length; j++) {
    if (src[j] == '{') depth++;
    if (src[j] == '}') {
      depth--;
      if (depth == 0) return src.substring(at, j + 1);
    }
  }
  fail('never found the end of $signature');
}
