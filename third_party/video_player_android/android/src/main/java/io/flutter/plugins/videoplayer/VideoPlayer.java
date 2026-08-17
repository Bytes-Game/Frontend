// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import static androidx.media3.common.Player.REPEAT_MODE_ALL;
import static androidx.media3.common.Player.REPEAT_MODE_OFF;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.TrackGroup;
import androidx.media3.common.TrackSelectionOverride;
import androidx.media3.common.Tracks;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector;
import io.flutter.view.TextureRegistry.SurfaceProducer;
import java.util.ArrayList;
import java.util.List;

/**
 * A class responsible for managing video playback using {@link ExoPlayer}.
 *
 * <p>It provides methods to control playback, adjust volume, and handle seeking.
 */
public abstract class VideoPlayer implements VideoPlayerInstanceApi {
  @NonNull protected final VideoPlayerCallbacks videoPlayerEvents;
  @Nullable protected final SurfaceProducer surfaceProducer;
  @Nullable private DisposeHandler disposeHandler;
  @NonNull protected ExoPlayer exoPlayer;
  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @UnstableApi @Nullable protected DefaultTrackSelector trackSelector;

  /** A closure-compatible signature since {@link java.util.function.Supplier} is API level 24. */
  public interface ExoPlayerProvider {
    /**
     * Returns a new {@link ExoPlayer}.
     *
     * @return new instance.
     */
    @NonNull
    ExoPlayer get();
  }

  /** A handler to run when dispose is called. */
  public interface DisposeHandler {
    void onDispose();
  }

  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @UnstableApi
  // Error thrown for this-escape warning on JDK 21+ due to https://bugs.openjdk.org/browse/JDK-8015831.
  // Keeping behavior as-is and addressing the warning could cause a regression: https://github.com/flutter/packages/pull/10193
  @SuppressWarnings("this-escape")
  public VideoPlayer(
      @NonNull VideoPlayerCallbacks events,
      @NonNull MediaItem mediaItem,
      @NonNull VideoPlayerOptions options,
      @Nullable SurfaceProducer surfaceProducer,
      @NonNull ExoPlayerProvider exoPlayerProvider) {
    this.videoPlayerEvents = events;
    this.surfaceProducer = surfaceProducer;
    exoPlayer = exoPlayerProvider.get();

    // Try to get the track selector from the ExoPlayer if it was built with one
    if (exoPlayer.getTrackSelector() instanceof DefaultTrackSelector) {
      trackSelector = (DefaultTrackSelector) exoPlayer.getTrackSelector();
    }

    exoPlayer.setMediaItem(mediaItem);
    exoPlayer.prepare();
    exoPlayer.addListener(createExoPlayerEventListener(exoPlayer, surfaceProducer));
    setAudioAttributes(exoPlayer, options.mixWithOthers);
  }

  public void setDisposeHandler(@Nullable DisposeHandler handler) {
    disposeHandler = handler;
  }

  @NonNull
  protected abstract ExoPlayerEventListener createExoPlayerEventListener(
      @NonNull ExoPlayer exoPlayer, @Nullable SurfaceProducer surfaceProducer);

  private static void setAudioAttributes(ExoPlayer exoPlayer, boolean isMixMode) {
    exoPlayer.setAudioAttributes(
        new AudioAttributes.Builder().setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
        !isMixMode);
  }

  @Override
  public void play() {
    exoPlayer.play();
  }

  @Override
  public void pause() {
    exoPlayer.pause();
  }

  @Override
  public void setLooping(boolean looping) {
    exoPlayer.setRepeatMode(looping ? REPEAT_MODE_ALL : REPEAT_MODE_OFF);
  }

  @Override
  public void setVolume(double volume) {
    float bracketedValue = (float) Math.max(0.0, Math.min(1.0, volume));
    exoPlayer.setVolume(bracketedValue);
  }

  @Override
  public void setPlaybackSpeed(double speed) {
    // We do not need to consider pitch and skipSilence for now as we do not handle them and
    // therefore never diverge from the default values.
    final PlaybackParameters playbackParameters = new PlaybackParameters((float) speed);

    exoPlayer.setPlaybackParameters(playbackParameters);
  }

  @Override
  public long getCurrentPosition() {
    return exoPlayer.getCurrentPosition();
  }

  @Override
  public long getBufferedPosition() {
    return exoPlayer.getBufferedPosition();
  }

  @Override
  public void seekTo(long position) {
    exoPlayer.seekTo(position);
  }

  @NonNull
  public ExoPlayer getExoPlayer() {
    return exoPlayer;
  }

  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @UnstableApi
  @Override
  public @NonNull NativeAudioTrackData getAudioTracks() {
    List<ExoPlayerAudioTrackData> audioTracks = new ArrayList<>();

    // Get the current tracks from ExoPlayer
    Tracks tracks = exoPlayer.getCurrentTracks();

    // Iterate through all track groups
    for (int groupIndex = 0; groupIndex < tracks.getGroups().size(); groupIndex++) {
      Tracks.Group group = tracks.getGroups().get(groupIndex);

      // Only process audio tracks
      if (group.getType() == C.TRACK_TYPE_AUDIO) {
        for (int trackIndex = 0; trackIndex < group.length; trackIndex++) {
          Format format = group.getTrackFormat(trackIndex);
          boolean isSelected = group.isTrackSelected(trackIndex);

          // Create audio track data with metadata
          ExoPlayerAudioTrackData audioTrack =
              new ExoPlayerAudioTrackData(
                  (long) groupIndex,
                  (long) trackIndex,
                  format.label,
                  format.language,
                  isSelected,
                  format.bitrate != Format.NO_VALUE ? (long) format.bitrate : null,
                  format.sampleRate != Format.NO_VALUE ? (long) format.sampleRate : null,
                  format.channelCount != Format.NO_VALUE ? (long) format.channelCount : null,
                  format.codecs != null ? format.codecs : null);

          audioTracks.add(audioTrack);
        }
      }
    }
    return new NativeAudioTrackData(audioTracks);
  }

  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @UnstableApi
  @Override
  public void selectAudioTrack(long groupIndex, long trackIndex) {
    if (trackSelector == null) {
      throw new IllegalStateException("Cannot select audio track: track selector is null");
    }

    // Get current tracks
    Tracks tracks = exoPlayer.getCurrentTracks();

    if (groupIndex < 0 || groupIndex >= tracks.getGroups().size()) {
      throw new IllegalArgumentException(
          "Cannot select audio track: groupIndex "
              + groupIndex
              + " is out of bounds (available groups: "
              + tracks.getGroups().size()
              + ")");
    }

    Tracks.Group group = tracks.getGroups().get((int) groupIndex);

    // Verify it's an audio track
    if (group.getType() != C.TRACK_TYPE_AUDIO) {
      throw new IllegalArgumentException(
          "Cannot select audio track: group at index "
              + groupIndex
              + " is not an audio track (type: "
              + group.getType()
              + ")");
    }

    // Verify the track index is valid
    if (trackIndex < 0 || (int) trackIndex >= group.length) {
      throw new IllegalArgumentException(
          "Cannot select audio track: trackIndex "
              + trackIndex
              + " is out of bounds (available tracks in group: "
              + group.length
              + ")");
    }

    // Get the track group and create a selection override
    TrackGroup trackGroup = group.getMediaTrackGroup();
    TrackSelectionOverride override = new TrackSelectionOverride(trackGroup, (int) trackIndex);

    // Apply the track selection override
    trackSelector.setParameters(
        trackSelector.buildUponParameters().setOverrideForType(override).build());
  }

  /**
   * Enables or disables audio decoding entirely for this player.
   *
   * <p>LOCAL ADDITION — this method is not in upstream video_player_android. It is the only reason
   * this package is vendored; see third_party/video_player_android/LOCAL_CHANGES.md.
   *
   * <p>WHY IT EXISTS. A reels feed keeps several players warm so a swipe lands on a video that is
   * already decoding. Only one of them is on screen. The rest are muted with setVolume(0), which
   * silences the output and does nothing whatsoever about the work: ExoPlayer still selects the
   * audio track, still opens a hardware AAC decoder, still allocates an AudioTrack and its thread,
   * and still decodes every frame of sound before throwing it away. A device profile showed one
   * such player at "Qinput: 126, Render: 0, Drop: 122" — a hundred-odd chunks of audio decoded and
   * none of it played.
   *
   * <p>That matters because concurrent hardware decoders are a fixed, small budget on the SoC, not
   * a memory question. Every warm player was quietly spending two slots to use one, and when the
   * budget ran out Android's resource manager took decoders back from us mid-playback
   * ("E/MediaCodec: Released by resource manager"), which the user sees as a video frozen on its
   * last frame.
   *
   * <p>Disabling the audio track type releases the audio renderer and its decoder. The video
   * carries on untouched.
   *
   * <p>TIMING. This is a per-player toggle rather than a creation-time option, because a warm spare
   * later becomes the video on screen and needs its sound back. The consequence is that a player
   * opens with audio and gives it up a moment later, rather than never taking it: the
   * platform-interface create call offers nowhere to pass the flag, and widening it would mean
   * vendoring two more packages. What this reclaims is the whole time a spare sits warm — seconds
   * to minutes — not the few milliseconds around its creation.
   *
   * @param enabled false to stop decoding audio for this player, true to resume.
   */
  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @UnstableApi
  @Override
  public void setAudioEnabled(boolean enabled) {
    if (trackSelector == null) {
      // The player was built without a DefaultTrackSelector, so there is no
      // track selection to override. Nothing to disable, and nothing broken:
      // this is a resource optimisation, not a correctness requirement.
      return;
    }
    // Built as a statement rather than a fluent chain on purpose: the override
    // of setTrackTypeDisabled on Parameters.Builder has changed its declared
    // return type across Media3 releases, and the builder mutates in place
    // either way.
    DefaultTrackSelector.Parameters.Builder params = trackSelector.buildUponParameters();
    params.setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, !enabled);
    trackSelector.setParameters(params.build());
  }

  public void dispose() {
    if (disposeHandler != null) {
      disposeHandler.onDispose();
    }
    exoPlayer.release();
  }
}
