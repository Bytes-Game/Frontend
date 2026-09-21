package com.example.devf

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "devf/device_media",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "videoDecoderInstances" -> result.success(videoDecoderInstances("video/avc"))
                "hevcDecoderInstances" -> result.success(videoDecoderInstances("video/hevc"))
                else -> result.notImplemented()
            }
        }
    }

    /**
     * How many decoders of [mime] this chip carries, and how many instances
     * each says it will run at once, as name -> count.
     *
     * Asked for two things. "video/avc" is H.264 and answers "how many videos
     * may the feed keep open". "video/hevc" is H.265 and answers a different
     * question — whether this phone can decode it AT ALL. An empty map for
     * H.265 is the common, correct answer on an older phone, and it is what
     * keeps that phone on the files it has always been served.
     *
     * The app keeps several videos open so a swipe lands on one already
     * playing, and how many it may keep is a property of the CHIP, not of
     * memory. Nothing in Android tells you the number up front: today the app
     * assumes four for every phone, and only finds out it was wrong when a
     * request is refused or a decoder is taken back mid-playback, by which
     * point somebody is looking at a frozen video.
     *
     * The whole map is returned rather than one number because the answer is
     * per decoder, and a phone carries several: the chip's own (fast, few
     * instances) alongside Android's software fallback (slow, effectively
     * unlimited). Averaging or maxing those would report the software one's
     * generosity as though the chip had it. Which of them actually binds is a
     * question to answer with real readings from real phones, not with a
     * guess made here.
     *
     * Empty map means the question could not be asked — an old Android, or a
     * codec list that would not enumerate. The caller keeps its existing
     * behaviour in that case.
     */
    private fun videoDecoderInstances(mime: String): Map<String, Int> {
        // maxSupportedInstances arrived in API 23.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyMap()
        val out = mutableMapOf<String, Int>()
        try {
            for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
                if (info.isEncoder) continue
                val type = info.supportedTypes.firstOrNull {
                    it.equals(mime, ignoreCase = true)
                } ?: continue
                // One bad codec entry should not lose the readings from the
                // others — some devices ship an entry that throws here.
                try {
                    out[info.name] = info.getCapabilitiesForType(type).maxSupportedInstances
                } catch (_: Exception) {
                    // skip this one
                }
            }
        } catch (_: Exception) {
            return emptyMap()
        }
        return out
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
