package com.example.devf

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "devf/video_trim",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "trimVideo" -> {
                    val src = call.argument<String>("sourcePath")
                    val startMs = call.argument<Int>("startMs")
                    val endMs = call.argument<Int>("endMs")
                    val dst = call.argument<String>("destPath")
                    if (src == null || startMs == null || endMs == null || dst == null) {
                        result.error("INVALID_ARG", "sourcePath/startMs/endMs/destPath required", null)
                        return@setMethodCallHandler
                    }
                    // Run on background thread — MediaExtractor+MediaMuxer can take
                    // ~1s on a 60s clip; blocking the platform main thread would jank.
                    Thread {
                        try {
                            streamCopyTrim(src, startMs.toLong(), endMs.toLong(), dst)
                            runOnUiThread { result.success(dst) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("TRIM_FAILED", e.message ?: "trim error", null)
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Stream-copies all video and audio tracks from [src] into [dst], starting
     * at the keyframe at or before [startMs] and ending at [endMs]. No codec is
     * involved — bytes are moved container-to-container unchanged — so the AAC
     * audio track is preserved 100% on every SoC including MediaTek c2.mtk.*.
     *
     * Presentation timestamps in the output are zero-based: the first sample's
     * original PTS is subtracted from all subsequent samples so the clip plays
     * from t=0 regardless of where in the source it was cut from.
     */
    private fun streamCopyTrim(src: String, startMs: Long, endMs: Long, dst: String) {
        val extractor = MediaExtractor()
        extractor.setDataSource(src)

        val muxer = MediaMuxer(dst, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        // Map extractorTrackIndex → muxerTrackIndex for every AV track.
        val trackMap = mutableMapOf<Int, Int>()
        for (i in 0 until extractor.trackCount) {
            val fmt = extractor.getTrackFormat(i)
            val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                extractor.selectTrack(i)
                trackMap[i] = muxer.addTrack(fmt)
            }
        }

        val startUs = startMs * 1000L
        val endUs   = endMs   * 1000L

        // Seek to the nearest sync frame at or before startUs so the video
        // track begins at a decodable keyframe. Audio will also rewind to
        // roughly the same position since all tracks share one seek position.
        extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

        muxer.start()

        val buf = ByteBuffer.allocate(2 * 1024 * 1024)
        val info = MediaCodec.BufferInfo()
        var originUs = Long.MIN_VALUE

        while (true) {
            val trackIdx = extractor.sampleTrackIndex
            if (trackIdx < 0) break                       // end of stream

            val muxerTrack = trackMap[trackIdx]
            if (muxerTrack == null) {                     // unselected track
                extractor.advance()
                continue
            }

            val sampleUs = extractor.sampleTime
            if (sampleUs > endUs) break                   // past trim end

            val size = extractor.readSampleData(buf, 0)
            if (size < 0) break

            // Record the first sample's original PTS so we can subtract it from
            // every subsequent PTS — this zero-bases the output clip.
            if (originUs == Long.MIN_VALUE) originUs = sampleUs

            info.offset = 0
            info.size = size
            info.presentationTimeUs = sampleUs - originUs
            info.flags = extractor.sampleFlags

            muxer.writeSampleData(muxerTrack, buf, info)
            extractor.advance()
        }

        try { muxer.stop() } catch (_: Exception) {}
        muxer.release()
        extractor.release()
    }
}
