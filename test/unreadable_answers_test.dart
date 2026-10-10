// An answer the app cannot read says so.
//
// A request that fails is already logged where every request passes. An
// answer that ARRIVES but in a shape the app does not expect was not: it
// turned into "nothing" without a word, which is how a profile refresh was
// thrown away on every app open and nobody saw it. These check that it
// now leaves a line in the log, and that a plain network failure is not
// reported twice.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';

void main() {
  late List<String> said;
  final original = debugPrint;

  setUp(() {
    said = [];
    debugPrint = (String? m, {int? wrapWidth}) => said.add(m ?? '');
  });
  tearDown(() {
    debugPrint = original;
    ApiService.useClient(http.Client());
  });

  test('a profile answer in the wrong shape says so, and gives nothing',
      () async {
    ApiService.useClient(MockClient((req) async =>
        http.Response(json.encode(['not', 'a', 'profile']), 200)));
    final user = await ApiService.getUserByUsername('maya_wrong_shape');
    expect(user, isNull);
    expect(
      said.where((l) =>
          l.contains('getUserByUsername') && l.contains('could not be read')),
      hasLength(1),
    );
  });

  test('a dropped connection is said once, by the request, not again',
      () async {
    ApiService.useClient(MockClient((req) async =>
        throw http.ClientException('connection reset')));
    final user = await ApiService.getUserByUsername('maya_offline');
    expect(user, isNull);
    expect(said.where((l) => l.contains('could not be read')), isEmpty);
    expect(said.where((l) => l.contains('never completed')), hasLength(1));
  });
}
