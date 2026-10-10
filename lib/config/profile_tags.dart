/// The words a profile can be described by, in the order they are offered.
///
/// The server keeps the same list (profileTags in profile_photo.go) and
/// refuses anything else; keep the two in step, or the app offers a word the
/// server will not save.
const profileTags = <String>[
  'Creator',
  'Influencer',
  'Motivator',
  'Philanthropist',
  'Entertainer',
  'Comedian',
  'Dancer',
  'Singer',
  'Musician',
  'Rapper',
  'Artist',
  'Actor',
  'Photographer',
  'Vlogger',
  'Storyteller',
  'Gamer',
  'Athlete',
  'Fitness coach',
  'Educator',
  'Student',
  'Tech enthusiast',
  'Entrepreneur',
  'Foodie',
  'Chef',
  'Traveller',
  'Fashion',
  'Beauty',
  'Lifestyle',
  'Spiritual',
  'Activist',
  'Pet lover',
];
