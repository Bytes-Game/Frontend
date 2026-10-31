/// What is wrong with [name] as a username, in words for the person typing,
/// or null when nothing is (or when nothing is typed yet). [name] is already
/// lower case.
///
/// The server's rule, said before asking it (usernameProblem in the
/// server's account_rules.go). Sign-up and Change username both use this
/// one, so a name allowed in one is allowed in the other.
String? usernameProblem(String name) {
  if (name.isEmpty) return null;
  if (!_usernameRe.hasMatch(name)) {
    return 'Use 3 to 20 characters: letters, numbers, _ and . only.';
  }
  if (name.startsWith('.') || name.endsWith('.') || name.contains('..')) {
    return "Can't start or end with a dot, or have two dots in a row.";
  }
  if (!name.contains(RegExp(r'[a-z]'))) {
    return 'Needs at least one letter.';
  }
  return null;
}

final _usernameRe = RegExp(r'^[a-z0-9_.]{3,20}$');
