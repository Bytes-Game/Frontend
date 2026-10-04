import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import 'package:myapp/pages/record_video_page.dart';

/// The phone's own photos and videos, for the page the + button opens.
///
/// That page works like Instagram's and TikTok's: a grid of everything on
/// the phone, newest first, photos and videos together. Nobody says "this
/// is a photo" — each item already knows what it is ([GalleryItem.isVideo]),
/// and the app takes it from there.
///
/// Everything that talks to the phone sits behind [DeviceGallery], with a
/// stand-in for tests, the same way the camera and the photo picker do.

/// Whether the app may read the phone's photos and videos.
enum GalleryAccess {
  /// All of them.
  all,

  /// Only the ones the person picked (iPhone, and Android 14 and newer, let
  /// people share a few instead of everything).
  limited,

  /// None. The page then offers to ask again, and the phone's own picker.
  denied,
}

/// One photo or video on the phone.
@immutable
class GalleryItem {
  final String id;
  final bool isVideo;

  /// How long a video runs; zero for a photo.
  final Duration duration;

  const GalleryItem({
    required this.id,
    required this.isVideo,
    this.duration = Duration.zero,
  });

  @override
  bool operator ==(Object other) => other is GalleryItem && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A photo or video picked with the phone's own picker.
@immutable
class PickedMedia {
  final File file;
  final bool isVideo;
  const PickedMedia(this.file, {required this.isVideo});
}

abstract class DeviceGallery {
  /// The one the app uses. A seam: tests put a stand-in here.
  static DeviceGallery instance = PhoneGallery();

  /// Ask for access (the phone shows its own question the first time) and
  /// say what was given.
  Future<GalleryAccess> requestAccess();

  /// One page of photos and videos, newest first. [page] counts from 0.
  Future<List<GalleryItem>> recent({required int page, required int size});

  /// A small square picture of [item], [size] pixels across, for the grid.
  Future<Uint8List?> thumbnail(GalleryItem item, int size);

  /// The file to post. A video's own file, which the trim screen cuts down.
  /// A photo shrunk to a JPEG at most about [maxPhotoSide] pixels on its
  /// long side: a phone photo straight from the camera can be 12 million
  /// pixels and several MB, and on an iPhone it is not even a JPEG.
  Future<File?> fileFor(GalleryItem item);

  /// Let the person share more photos after sharing only a few.
  Future<void> chooseMore();

  /// The app's page in the phone's settings, where access is changed after
  /// it was refused for good.
  Future<void> openSettings();

  /// The phone's own picker, for somebody who would rather not share their
  /// gallery: it needs no permission. Photos and videos both; a photo comes
  /// back shrunk the same way as [fileFor]'s. Null when they backed out.
  Future<PickedMedia?> pickWithPhone();

  static const int maxPhotoSide = 1600;
}

/// The real phone, through photo_manager.
class PhoneGallery implements DeviceGallery {
  /// What [recent] found, by id, so the grid and [fileFor] can go back to
  /// it without asking the phone to find it again.
  final Map<String, AssetEntity> _found = {};

  static const _request = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,
      mediaLocation: false,
    ),
  );

  @override
  Future<GalleryAccess> requestAccess() async {
    try {
      final state = await PhotoManager.requestPermissionExtend(
        requestOption: _request,
      );
      if (state == PermissionState.authorized) return GalleryAccess.all;
      if (state == PermissionState.limited) return GalleryAccess.limited;
      debugPrint('[gallery] access to photos and videos: ${state.name}');
      return GalleryAccess.denied;
    } catch (e) {
      debugPrint('[gallery] could not ask for photos and videos: $e');
      return GalleryAccess.denied;
    }
  }

  @override
  Future<List<GalleryItem>> recent({
    required int page,
    required int size,
  }) async {
    try {
      final assets = await PhotoManager.getAssetListPaged(
        page: page,
        pageCount: size,
        type: RequestType.common,
        filterOption: FilterOptionGroup(
          orders: const [OrderOption(type: OrderOptionType.createDate)],
        ),
      );
      return [
        for (final a in assets)
          if (a.type == AssetType.image || a.type == AssetType.video) _keep(a),
      ];
    } catch (e) {
      debugPrint(
        '[gallery] could not read page $page of the phone\'s '
        'photos and videos: $e',
      );
      rethrow;
    }
  }

  GalleryItem _keep(AssetEntity a) {
    _found[a.id] = a;
    return GalleryItem(
      id: a.id,
      isVideo: a.type == AssetType.video,
      duration: a.type == AssetType.video ? a.videoDuration : Duration.zero,
    );
  }

  @override
  Future<Uint8List?> thumbnail(GalleryItem item, int size) async {
    final a = _found[item.id];
    if (a == null) return null;
    try {
      return await a.thumbnailDataWithSize(ThumbnailSize.square(size));
    } catch (e) {
      debugPrint('[gallery] no picture for ${item.id}: $e');
      return null;
    }
  }

  @override
  Future<File?> fileFor(GalleryItem item) async {
    final a = _found[item.id];
    if (a == null) return null;
    try {
      if (item.isVideo) return await a.file;
      const side = ThumbnailSize(
        DeviceGallery.maxPhotoSide,
        DeviceGallery.maxPhotoSide,
      );
      // Full quality, not the quick first answer an iPhone gives by
      // default, and fitted inside the square rather than cropped to it.
      final option = Platform.isIOS
          ? ThumbnailOption.ios(
              size: side,
              quality: 88,
              deliveryMode: DeliveryMode.highQualityFormat,
              resizeMode: ResizeMode.exact,
            )
          : const ThumbnailOption(size: side, quality: 88);
      final bytes = await a.thumbnailDataWithOption(option);
      if (bytes == null || bytes.isEmpty) {
        debugPrint('[gallery] the phone gave no picture for ${item.id}');
        return null;
      }
      final dir = await getTemporaryDirectory();
      final out = File(
        '${dir.path}/post_photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await out.writeAsBytes(bytes, flush: true);
      return out;
    } catch (e) {
      debugPrint('[gallery] could not get ${item.id} ready to post: $e');
      return null;
    }
  }

  @override
  Future<void> chooseMore() async {
    try {
      await PhotoManager.presentLimited(type: RequestType.common);
    } catch (e) {
      debugPrint('[gallery] could not open the phone\'s chooser: $e');
    }
  }

  @override
  Future<PickedMedia?> pickWithPhone() async {
    try {
      final x = await ImagePicker().pickMedia(
        maxWidth: DeviceGallery.maxPhotoSide.toDouble(),
        maxHeight: DeviceGallery.maxPhotoSide.toDouble(),
        imageQuality: 88,
      );
      if (x == null) return null;
      final mime = x.mimeType ?? '';
      final isVideo =
          mime.startsWith('video/') ||
          (mime.isEmpty && !RecordVideoPage.isPhotoPath(x.path));
      return PickedMedia(File(x.path), isVideo: isVideo);
    } catch (e) {
      debugPrint('[gallery] the phone\'s picker did not open: $e');
      return null;
    }
  }

  @override
  Future<void> openSettings() async {
    try {
      await PhotoManager.openSetting();
    } catch (e) {
      debugPrint('[gallery] could not open the app\'s settings: $e');
    }
  }
}
