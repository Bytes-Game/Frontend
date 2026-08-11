/// Deciding whether a paginated feed has more pages behind it.
///
/// Small enough to inline, extracted because getting it wrong is silent.
/// A feed that stops early looks exactly like a feed that ran out, and
/// both look like nothing at all in the logs — so the rule lives here
/// where it can be stated once and tested.
class FeedPaging {
  const FeedPaging._();

  /// Whether to request another page.
  ///
  /// [declared] is the server's own `hasMore`, passed raw so the absent
  /// case stays distinguishable: `null` for a response that carried no
  /// such key, which is NOT the same claim as `false`. The widget's
  /// original `data['hasMore'] == true` collapsed those two, so a single
  /// endpoint that omitted the field capped its feed at page one for the
  /// whole session with no error anywhere.
  ///
  /// When the server does declare, it wins — it is the only party that
  /// knows. When it does not, fall back to the ordinary paging
  /// convention: a page filled to [limit] probably has more behind it, a
  /// short one is the end of the feed. The cost of being wrong that way
  /// is one request that comes back empty; the cost of the old default
  /// was content the user could never reach.
  ///
  /// [newItems] is the count AFTER de-duplication, and it guards the loop
  /// the fallback could otherwise start: a server that keeps replaying a
  /// page it has already sent yields nothing new each time, and asking
  /// again would spin forever.
  static bool hasMoreAfter({
    required Object? declared,
    required int rawCount,
    required int newItems,
    required int limit,
  }) {
    if (declared is bool) return declared;
    if (newItems == 0) return false;
    return rawCount >= limit;
  }
}
