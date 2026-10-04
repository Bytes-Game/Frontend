import 'package:cupertino_ui/cupertino_ui.dart' as cui;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:myapp/config/app_theme.dart';

// What the photo and video editors need from the app.
//
// The editors are built on Flutter's design library in its new standalone
// form (material_ui). It keeps its own words — "Cancel", "Done" — and its
// own colours, apart from the ones the rest of the app uses.

/// The editors' words, added to the whole app in main.dart. Without them
/// the editor's top bar refuses to draw, and so does the "please wait" box
/// it opens over the whole app while it saves.
const editorLocalizations = <LocalizationsDelegate<dynamic>>[
  mui.DefaultMaterialLocalizations.delegate,
  cui.DefaultCupertinoLocalizations.delegate,
];

/// Dark, with the app's blue for the buttons that matter.
final mui.ThemeData editorTheme = mui.ThemeData(
  brightness: Brightness.dark,
  colorScheme: mui.ColorScheme.fromSeed(
    seedColor: AppTheme.primary,
    brightness: Brightness.dark,
  ).copyWith(primary: AppTheme.primary),
  scaffoldBackgroundColor: const Color(0xFF000000),
);
