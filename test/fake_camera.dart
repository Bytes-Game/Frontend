// A stand-in for the phone's camera, shared by the tests that go through
// it: the create page's camera and recording an answer. It hands back real
// files and records what it was asked.

import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';

import 'fake_gallery.dart';

/// A camera that hands back real files, and records what it was asked.
class FakeCamera extends CameraPlatform {
  late Directory dir;
  final List<String> asked = [];
  final _initialized = StreamController<CameraInitializedEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
    CameraDescription(
      name: 'back',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
  ];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings? mediaSettings,
  ) async => 1;

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    scheduleMicrotask(
      () => _initialized.add(
        const CameraInitializedEvent(
          1,
          720,
          1280,
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      ),
    );
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _initialized.stream;

  // Open, and silent: the controller waits on the first error, and a
  // stream that ends at once is itself an error.
  final _errors = StreamController<CameraErrorEvent>.broadcast();

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {}

  @override
  Future<XFile> takePicture(int cameraId) async {
    asked.add('photo');
    final f = File('${dir.path}/camera_shot.jpg')..writeAsBytesSync(tinyJpeg);
    return XFile(f.path);
  }

  @override
  Future<void> prepareForVideoRecording() async {}

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async =>
      asked.add('record');

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    asked.add('stop');
    final f = File('${dir.path}/camera_clip.mp4')
      ..writeAsBytesSync(List.filled(2048, 1));
    return XFile(f.path);
  }

  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Colors.grey);

  @override
  Future<void> dispose(int cameraId) async {}
}
