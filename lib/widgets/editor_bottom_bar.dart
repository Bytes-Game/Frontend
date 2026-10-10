import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/editor_setup.dart';
import 'package:myapp/models/music_track.dart';

/// An editor's bottom row: its own tools, drawn the way it draws them, with
/// Music first, so a song is added where everything else is done to the
/// photo or video. [song] is the song chosen, if any: its name is shown in
/// place of "Music", and a tap opens its settings ([onMusic]) rather than
/// the picker ([onAddMusic]).
ReactiveWidget<Widget> editorBottomBar({
  required ProImageEditorState editor,
  required Stream<void> rebuild,
  required Key key,
  required List<SubEditorMode> tools,
  required MusicTrack? song,
  required VoidCallback onAddMusic,
  required VoidCallback onMusic,
}) {
  return ReactiveWidget(
    stream: rebuild,
    builder: (context) {
      final c = editor.configs;
      // Out of the way while a text or emoji on the video is being moved,
      // as the editor's own row is.
      if (editor.hasSelectedLayers &&
          c.layerInteraction.hideToolbarOnInteraction) {
        return const SizedBox.shrink();
      }
      final colour = c.mainEditor.style.bottomBarColor;
      Widget button(
        String key,
        String label,
        IconData icon,
        VoidCallback onPressed, {
        Color? iconColour,
      }) => FlatIconTextButton(
        key: ValueKey(key),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 72),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: colour),
          ),
        ),
        icon: Icon(icon, size: 22, color: iconColour ?? colour),
        onPressed: onPressed,
      );
      final buttons = <Widget>[
        if (song == null)
          button(
            'editor_add_music',
            'Music',
            Icons.music_note_rounded,
            onAddMusic,
          )
        else
          button(
            'editor_music',
            song.title,
            Icons.music_note_rounded,
            onMusic,
            iconColour: AppTheme.primary,
          ),
        for (final tool in tools)
          switch (tool) {
            SubEditorMode.cropRotate => button(
              'open-crop-rotate-editor-btn',
              c.i18n.cropRotateEditor.bottomNavigationBarText,
              c.cropRotateEditor.icons.bottomNavBar,
              editor.openCropRotateEditor,
            ),
            SubEditorMode.filter => button(
              'open-filter-editor-btn',
              c.i18n.filterEditor.bottomNavigationBarText,
              c.filterEditor.icons.bottomNavBar,
              editor.openFilterEditor,
            ),
            SubEditorMode.tune => button(
              'open-tune-editor-btn',
              c.i18n.tuneEditor.bottomNavigationBarText,
              c.tuneEditor.icons.bottomNavBar,
              () => editor.openTuneEditor(),
            ),
            SubEditorMode.text => button(
              'open-text-editor-btn',
              c.i18n.textEditor.bottomNavigationBarText,
              c.textEditor.icons.bottomNavBar,
              () => editor.openTextEditor(),
            ),
            SubEditorMode.emoji => button(
              'open-emoji-editor-btn',
              c.i18n.emojiEditor.bottomNavigationBarText,
              c.emojiEditor.icons.bottomNavBar,
              editor.openEmojiEditor,
            ),
            SubEditorMode.paint => button(
              'open-paint-editor-btn',
              c.i18n.paintEditor.bottomNavigationBarText,
              c.paintEditor.icons.bottomNavBar,
              editor.openPaintEditor,
            ),
            SubEditorMode.blur => button(
              'open-blur-editor-btn',
              c.i18n.blurEditor.bottomNavigationBarText,
              c.blurEditor.icons.bottomNavBar,
              editor.openBlurEditor,
            ),
            // Not offered (see the editors' own lists of tools).
            SubEditorMode.sticker ||
            SubEditorMode.audio ||
            SubEditorMode.videoClips => const SizedBox.shrink(),
          },
      ];
      return mui.Theme(
        data: editorTheme,
        child: mui.BottomAppBar(
          key: key,
          height: kBottomNavigationBarHeight,
          color: c.mainEditor.style.bottomBarBackground,
          padding: EdgeInsets.zero,
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: math.max(0, box.maxWidth - 24),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: buttons,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
