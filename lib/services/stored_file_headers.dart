/// What every file the app uploads says about how long a copy of it may
/// be kept. Storage keeps this line with the file and hands it out with
/// every copy.
///
/// - `max-age`: a phone may keep the file for a year. A file never changes
///   once it is uploaded: a new upload gets a new address.
/// - `s-maxage`: a copy held between the storage and the phones
///   (Cloudflare, at media.flexete.com) is good for two hours only. A
///   video that has been deleted or removed has to stop opening.
///
/// Cloudflare also has a rule of its own, made by hand, that says the same
/// two hours. But a rule entered wrong matches nothing and says nothing.
/// That happened on 14 November: with only "a year" on the file, the
/// picture of a deleted video still opened eleven hours after it had gone
/// from storage. So the two hours are written on the file itself.
const String uploadCacheControl =
    'public, max-age=31536000, s-maxage=7200, immutable';
