import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Chip-based multi-tag input with backend-driven autocomplete.
///
/// Renders existing tags as InputChip rows (each removable), plus an
/// inline TextField for adding more. Suggestions appear as a row of
/// tappable chips below the input — each tap appends to the selected
/// list. Pressing Enter on a non-empty input also appends, so users
/// can type free-form tags the autocomplete didn't suggest.
///
/// Why a single widget instead of two (suggest + chip-bar):
///   * Keeps the dirty/clean state in one place — easier to wire to
///     the parent form's validator.
///   * Lets the suggestion row filter out already-selected tags
///     inline without the suggest widget needing to know about the
///     selection state.
class TagsInput extends StatefulWidget {
  /// Currently-selected tags. The widget mutates this through
  /// [onChanged] — it doesn't own the list itself so the parent stays
  /// the source of truth for what the form will submit.
  final List<String> selectedTags;

  /// Called whenever the user adds or removes a tag.
  final ValueChanged<List<String>> onChanged;

  /// Fired (debounced) on every keystroke so the parent can fetch
  /// fresh suggestions from the backend. The parent then setStates
  /// the [suggestions] list, which this widget reads.
  final ValueChanged<String> onQuery;

  /// Source of truth for the suggestion row. Pass in whatever the
  /// last backend response yielded; we filter out tags the user has
  /// already selected so we don't waste row space on dupes.
  final List<String> suggestions;

  /// Max tags allowed. Defaults to 8 — more than that and the chip
  /// row gets unwieldy on phone screens.
  final int maxTags;

  /// Max chars per tag. Defaults to 30 — tags much longer than that
  /// stop being useful for ranking and start being mini-captions.
  final int maxTagLength;

  const TagsInput({
    super.key,
    required this.selectedTags,
    required this.onChanged,
    required this.onQuery,
    required this.suggestions,
    this.maxTags = 8,
    this.maxTagLength = 30,
  });

  @override
  State<TagsInput> createState() => _TagsInputState();
}

class _TagsInputState extends State<TagsInput> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      widget.onQuery(value);
    });
  }

  void _addTag(String raw) {
    final tag = _normalize(raw);
    if (tag.isEmpty) return;
    if (tag.length > widget.maxTagLength) return;
    if (widget.selectedTags.contains(tag)) {
      // Already selected — clear the input but don't re-add. Avoids
      // a tap-tap cycle silently doing nothing while the field
      // appears to be stuck.
      _input.clear();
      return;
    }
    if (widget.selectedTags.length >= widget.maxTags) {
      // Limit reached. Drop the input silently — the help text on
      // the field already calls out the max.
      _input.clear();
      return;
    }
    final next = [...widget.selectedTags, tag];
    widget.onChanged(next);
    _input.clear();
    // Re-fire the query with the now-empty input so the suggestion
    // row repopulates with default popularity-ranked entries.
    widget.onQuery('');
  }

  void _removeTag(String tag) {
    final next = widget.selectedTags.where((t) => t != tag).toList();
    widget.onChanged(next);
  }

  String _normalize(String raw) {
    // Lowercase + trim + collapse internal whitespace so "  Pranks  "
    // and "pranks" don't both end up in the selected list as
    // duplicates that look identical in the UI.
    return raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final atMax = widget.selectedTags.length >= widget.maxTags;
    final suggestionsToShow = widget.suggestions
        .where((s) => !widget.selectedTags.contains(_normalize(s)))
        .take(12)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Selected chips row.
        if (widget.selectedTags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in widget.selectedTags)
                  InputChip(
                    label: Text(tag),
                    onDeleted: () => _removeTag(tag),
                    backgroundColor: cs.primary,
                    labelStyle: TextStyle(
                      color: cs.onPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    deleteIconColor: cs.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
              ],
            ),
          ),

        // Input row.
        TextField(
          controller: _input,
          focusNode: _focus,
          enabled: !atMax,
          onChanged: _onChanged,
          onSubmitted: _addTag,
          inputFormatters: [
            LengthLimitingTextInputFormatter(widget.maxTagLength),
          ],
          style: TextStyle(color: cs.onSurface),
          decoration: InputDecoration(
            hintText: atMax
                ? 'Max ${widget.maxTags} tags'
                : 'Add a tag and tap Enter, or pick below',
            hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.45)),
            filled: true,
            fillColor: cs.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: cs.primary, width: 1.5),
            ),
            suffixIcon: _input.text.trim().isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.add_circle, size: 22),
                    tooltip: 'Add',
                    onPressed: () => _addTag(_input.text),
                  ),
          ),
        ),

        // Suggestion chips row.
        if (suggestionsToShow.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in suggestionsToShow)
                  ActionChip(
                    label: Text(s),
                    onPressed: atMax ? null : () => _addTag(s),
                    backgroundColor: cs.surfaceContainerHighest,
                    labelStyle: TextStyle(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
