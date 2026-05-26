import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/video_processor_service.dart';

/// Full-screen camera with record button. Returns the recorded video's
/// local file path on Navigator.pop, or null on cancel.
///
/// We cap recording at [VideoProcessorService.maxReelDuration]; if the
/// user holds the button longer the recorder auto-stops. This way the
/// trim screen never has to deal with a 5-minute file.
class RecordVideoPage extends StatefulWidget {
  const RecordVideoPage({super.key});

  @override
  State<RecordVideoPage> createState() => _RecordVideoPageState();
}

class _RecordVideoPageState extends State<RecordVideoPage>
    with PageTracker<RecordVideoPage> {
  @override
  String get pageName => 'record_video_page';

  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _activeCameraIdx = 0;
  bool _initializing = true;
  bool _recording = false;
  DateTime? _recordStart;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  FlashMode _flash = FlashMode.off;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (!mounted) return;
      if (_cameras.isEmpty) {
        setState(() {
          _initializing = false;
          _initError = 'No cameras detected on this device.';
        });
        return;
      }
      // Prefer back camera as the default — most reels are filmed
      // outward, and starting on selfie mode feels jarring.
      _activeCameraIdx = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (_activeCameraIdx < 0) _activeCameraIdx = 0;
      await _attachController(_cameras[_activeCameraIdx]);
      if (!mounted) return;
      setState(() => _initializing = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _initError = 'Could not start camera: $e';
      });
    }
  }

  Future<void> _attachController(CameraDescription cam) async {
    final old = _controller;
    final ctrl = CameraController(
      cam,
      ResolutionPreset.high,
      enableAudio: true,
      // imageFormatGroup default is fine — we only need video output.
    );
    await ctrl.initialize();
    // The widget may have been disposed between create and now. If so,
    // we own this `ctrl` — `_controller` still points at the OLD
    // controller (which dispose() already released), so the new one
    // would leak its camera handle. Dispose it ourselves and bail.
    if (!mounted) {
      await ctrl.dispose();
      return;
    }
    await ctrl.setFlashMode(_flash);
    if (!mounted) {
      await ctrl.dispose();
      return;
    }
    setState(() {
      _controller = ctrl;
    });
    await old?.dispose();
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2 || _recording) return;
    setState(() => _initializing = true);
    _activeCameraIdx = (_activeCameraIdx + 1) % _cameras.length;
    await _attachController(_cameras[_activeCameraIdx]);
    if (!mounted) return;
    setState(() => _initializing = false);
    EventTracker.instance.trackTap(
      target: 'record_flip_camera',
      pageName: pageName,
    );
  }

  Future<void> _toggleFlash() async {
    if (_controller == null) return;
    final next = _flash == FlashMode.off
        ? FlashMode.torch
        : (_flash == FlashMode.torch ? FlashMode.auto : FlashMode.off);
    await _controller!.setFlashMode(next);
    if (!mounted) return;
    setState(() => _flash = next);
  }

  Future<void> _startRecording() async {
    final c = _controller;
    if (c == null || _recording) return;
    try {
      await c.prepareForVideoRecording();
      await c.startVideoRecording();
      _recordStart = DateTime.now();
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (_recordStart == null) return;
        final e = DateTime.now().difference(_recordStart!);
        setState(() => _elapsed = e);
        // Auto-stop at the cap so we never produce an out-of-spec clip.
        if (e >= VideoProcessorService.maxReelDuration) _stopRecording();
      });
      setState(() => _recording = true);
      EventTracker.instance.track(
        eventType: 'record_start',
        contentId: 'pending',
        contentType: 'challenge',
      );
    } catch (e) {
      if (!mounted) return;
      _toast('Could not start recording: $e');
    }
  }

  Future<void> _stopRecording() async {
    final c = _controller;
    if (c == null || !_recording) return;
    _ticker?.cancel();
    _ticker = null;
    try {
      final file = await c.stopVideoRecording();
      // Move into our temp dir under a stable name so the trim screen
      // doesn't have to worry about platform-specific cache paths.
      final tmp = await getTemporaryDirectory();
      final dest = File(
        '${tmp.path}/devf_record_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      await File(file.path).copy(dest.path);
      EventTracker.instance.track(
        eventType: 'record_stop',
        contentId: 'pending',
        contentType: 'challenge',
        metadata: {'durationMs': _elapsed.inMilliseconds},
      );
      if (!mounted) return;
      Navigator.of(context).pop(dest.path);
    } catch (e) {
      if (!mounted) return;
      _toast('Could not save recording: $e');
      setState(() => _recording = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _initializing
            ? const Center(
                child: CircularProgressIndicator(color: Colors.white))
            : (_initError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _initError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  )
                : _buildCameraStack()),
      ),
    );
  }

  Widget _buildCameraStack() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final maxSec = VideoProcessorService.maxReelDuration.inSeconds;
    final fraction =
        (_elapsed.inMilliseconds / (maxSec * 1000)).clamp(0.0, 1.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview is intrinsically sized — wrap in FittedBox so
        // it covers the whole screen without distortion.
        Center(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: c.value.previewSize?.height ?? 9,
              height: c.value.previewSize?.width ?? 16,
              child: CameraPreview(c),
            ),
          ),
        ),

        // Top bar: close, timer, flash.
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: _recording
                    ? null
                    : () => Navigator.of(context).pop(),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _formatElapsed(_elapsed, maxSec),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(_flashIcon(), color: Colors.white),
                onPressed: _toggleFlash,
              ),
            ],
          ),
        ),

        // Progress bar fills as we approach the duration cap.
        Positioned(
          top: 56,
          left: 16,
          right: 16,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 3,
              backgroundColor: Colors.white12,
            ),
          ),
        ),

        // Bottom controls.
        Positioned(
          bottom: 24,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              const SizedBox(width: 56),
              GestureDetector(
                onTap: _recording ? _stopRecording : _startRecording,
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                  ),
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: _recording ? 28 : 60,
                      height: _recording ? 28 : 60,
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius:
                            BorderRadius.circular(_recording ? 6 : 30),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.flip_camera_ios_outlined,
                  color: Colors.white,
                  size: 28,
                ),
                onPressed: _recording ? null : _flipCamera,
              ),
            ],
          ),
        ),
      ],
    );
  }

  IconData _flashIcon() {
    switch (_flash) {
      case FlashMode.off:
        return Icons.flash_off;
      case FlashMode.auto:
        return Icons.flash_auto;
      case FlashMode.always:
      case FlashMode.torch:
        return Icons.flash_on;
    }
  }

  String _formatElapsed(Duration d, int maxSec) {
    final s = d.inSeconds;
    return '$s / ${maxSec}s';
  }
}
