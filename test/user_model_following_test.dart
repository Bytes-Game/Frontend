// The "following" count on a profile. A private account you do not follow
// has its list left out by the server, but its count still shows.

import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/models/user_model.dart';

void main() {
  test('the count comes from the server, even with the list left out', () {
    final u = UserModel.fromJson({
      'id': '7',
      'username': 'hidden_owner',
      'followers': 3,
      'following': 12,
      'followingList': <String>[],
    });
    expect(u.followingCount, 12);
    expect(u.followingList, isEmpty);
    expect(u.followersCount, 3);
  });

  test('an older server sends only the list: the count is its length', () {
    final u = UserModel.fromJson({
      'id': '8',
      'username': 'someone',
      'followingList': ['1', '2'],
    });
    expect(u.followingCount, 2);
    expect(u.followingList, ['1', '2']);
  });
}
