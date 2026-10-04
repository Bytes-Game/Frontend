// A stand-in for the phone's photos and videos (DeviceGallery), shared by
// the tests of the create page. It records what the page asked of it.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:myapp/services/device_gallery.dart';

/// A 4 x 3 red picture, for the grid's thumbnails.
final Uint8List tinyPicture = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGP4z8AARww4OQD1MQv1NXv7ggAAAABJRU5ErkJggg==',
);

/// A 16 x 12 blue photo, as a real JPEG — what the phone's gallery hands
/// over. The photo editor hands back these very bytes when nothing was
/// changed, which it only does for a photo that is a JPEG already.
final Uint8List tinyJpeg = base64.decode(
  '/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYwLjMxLjEwMgD/2wBDAAgGBgcGBwgICAgI'
  'CAkJCQoKCgkJCQkKCgoKCgoMDAwKCgoKCgoKDAwMDA0ODQ0NDA0ODg8PDxISEREVFRUZGR//'
  'xABLAAEBAAAAAAAAAAAAAAAAAAAABQEBAAAAAAAAAAAAAAAAAAAABhABAAAAAAAAAAAAAAAA'
  'AAAAABEBAAAAAAAAAAAAAAAAAAAAAP/AABEIAAwAEAMBIgACEQADEQD/2gAMAwEAAhEDEQA/'
  'AIIB2Ov/2Q==',
);

class FakeGallery implements DeviceGallery {
  /// What [requestAccess] answers once [answers] has run out.
  GalleryAccess access = GalleryAccess.all;

  /// The phone's photos and videos, newest first.
  final List<GalleryItem> items = [];

  /// Answers for [requestAccess], one per call, before [access].
  final List<GalleryAccess> answers = [];

  /// The file [fileFor] hands back for each item, by id.
  final Map<String, File> files = {};

  /// When set, reading the gallery fails.
  bool broken = false;

  /// What the phone's own picker returns.
  PickedMedia? phonePick;

  int accessAsked = 0;
  int choseMore = 0;
  int settingsOpened = 0;
  int phonePickerOpened = 0;
  final List<int> pagesAsked = [];
  final List<String> filesAsked = [];

  @override
  Future<GalleryAccess> requestAccess() async {
    accessAsked++;
    return answers.isNotEmpty ? answers.removeAt(0) : access;
  }

  @override
  Future<List<GalleryItem>> recent({
    required int page,
    required int size,
  }) async {
    pagesAsked.add(page);
    if (broken) throw const FileSystemException('no gallery');
    final start = page * size;
    if (start >= items.length) return const [];
    return items.sublist(start, math.min(items.length, start + size));
  }

  @override
  Future<Uint8List?> thumbnail(GalleryItem item, int size) async => tinyPicture;

  @override
  Future<File?> fileFor(GalleryItem item) async {
    filesAsked.add(item.id);
    return files[item.id];
  }

  @override
  Future<void> chooseMore() async => choseMore++;

  @override
  Future<void> openSettings() async => settingsOpened++;

  @override
  Future<PickedMedia?> pickWithPhone() async {
    phonePickerOpened++;
    return phonePick;
  }

  /// A photo and a video, each with a real file in [dir].
  void addPhoto(Directory dir, String id) {
    items.add(GalleryItem(id: id, isVideo: false));
    files[id] = File('${dir.path}/$id.jpg')..writeAsBytesSync(tinyJpeg);
  }

  void addVideo(Directory dir, String id, Duration length) {
    items.add(GalleryItem(id: id, isVideo: true, duration: length));
    files[id] = File('${dir.path}/$id.mp4')
      ..writeAsBytesSync(List.filled(2048, 1));
  }
}
