import 'dart:async';

import 'package:flutter/material.dart';

/// A TextField with a backend-driven suggestions overlay.
///
/// Built on Flutter's [OverlayPortal] (Flutter 3.10+) so the overlay
/// rebuilds **whenever this widget's State rebuilds**. The previous
/// implementation managed a raw [OverlayEntry] manually, which only
/// re-rendered when we explicitly `markNeedsBuild`-ed it — which led
/// to the well-known "I typed but no dropdown appears, even after the
/// response landed" symptom. With OverlayPortal, the overlay child is
/// part of this State's build phase, so any setState (including the
/// parent's setState that delivers fresh suggestions) repaints it
/// immediately.
///
/// Lifecycle:
///   * On focus gain → fire a warmup [onQuery] with the current text
///     and show the portal.
///   * On every text change → debounce [onQuery] by [debounce] and
///     call setState() so the overlay repaints with the latest
///     (potentially-stale) cached suggestions while the network is in
///     flight.
///   * On focus loss → hide the portal (parent's suggestion list
///     stays cached — re-focusing repaints it without a refetch).
class SuggestField<T> extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? Function(String?)? validator;

  /// Called (debounced) on every text change AND once on focus gain.
  /// Parent should use this to fetch suggestions and setState them.
  final ValueChanged<String> onQuery;

  /// Source of truth for the dropdown contents. Whatever the parent
  /// puts here is what gets painted — so the moment the async fetch
  /// lands and setState fires, the dropdown updates.
  final List<T> suggestions;

  /// How to extract the underlying string from a suggestion. This is
  /// what gets stamped into the text field when the user taps a row.
  final String Function(T) displayString;

  /// How to paint one row inside the dropdown.
  final Widget Function(T) buildRow;

  /// Optional override for what to do on tap. The default behavior
  /// stamps `displayString(value)` into the controller and unfocuses
  /// the field.
  final ValueChanged<T>? onSelected;

  /// Debounce window for [onQuery]. 150 ms is the typing-feels-
  /// instant sweet spot — every keystroke under that gets coalesced.
  final Duration debounce;

  const SuggestField({
    super.key,
    required this.controller,
    required this.label,
    required this.onQuery,
    required this.suggestions,
    required this.displayString,
    required this.buildRow,
    this.hint,
    this.validator,
    this.onSelected,
    this.debounce = const Duration(milliseconds: 150),
  });

  @override
  State<SuggestField<T>> createState() => _SuggestFieldState<T>();
}

class _SuggestFieldState<T> extends State<SuggestField<T>> {
  // OverlayPortalController is the modern, declarative way to drive
  // an overlay from a State. We toggle .show() / .hide() based on
  // focus; the overlay child is rebuilt on every State.build pass,
  // so async suggestion updates land immediately.
  final OverlayPortalController _portal = OverlayPortalController();
  final FocusNode _focus = FocusNode();
  // LayerLink + CompositedTransformTarget/Follower keeps the overlay
  // dropdown anchored to the field, even if the field reflows when
  // the keyboard opens or the form scrolls.
  final LayerLink _link = LayerLink();
  Timer? _debounce;

  // Height of the TextFormField when rendered with our InputDecoration.
  // Measured at first build; defaults to 56 (Material standard) until
  // we've seen the real value. Used to position the dropdown directly
  // below the field with no overlap.
  double _fieldHeight = 56;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant SuggestField<T> old) {
    super.didUpdateWidget(old);
    // Defensive — if the parent swaps the controller mid-flight (it
    // shouldn't in our usage but the contract allows it), re-wire the
    // listener so we don't leak the old subscription.
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.removeListener(_onFocusChanged);
    widget.controller.removeListener(_onTextChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focus.hasFocus) {
      // Fire a warmup query with the current text — guarantees the
      // dropdown has something to show on first focus, even before
      // the user has typed.
      widget.onQuery(widget.controller.text);
      _portal.show();
    } else {
      _portal.hide();
    }
  }

  void _onTextChanged() {
    if (!_focus.hasFocus) return;
    _debounce?.cancel();
    _debounce = Timer(widget.debounce, () {
      widget.onQuery(widget.controller.text);
    });
    // setState so the OverlayPortal rebuilds NOW with whatever
    // suggestions the parent currently has cached. Without this, the
    // overlay only refreshes when the parent setStates after the
    // debounced query — leaving a visible "I typed but the dropdown
    // didn't react" gap that the user reported as "autocomplete
    // doesn't work."
    if (mounted) setState(() {});
  }

  void _onTap(T value) {
    final s = widget.displayString(value);
    widget.controller.text = s;
    widget.controller.selection = TextSelection.collapsed(offset: s.length);
    if (widget.onSelected != null) {
      widget.onSelected!(value);
    }
    // Drop focus so the overlay closes — the user picked a
    // suggestion, attention moves on.
    _focus.unfocus();
  }

  /// Build the dropdown panel. Lives in the overlay so it floats on
  /// top of every form field below it. We attach to the LayerLink so
  /// position stays correct even if the field scrolls or the keyboard
  /// reflows the layout.
  Widget _buildOverlay(BuildContext overlayCtx) {
    if (widget.suggestions.isEmpty) {
      // Returning an empty widget rather than hiding the portal is
      // intentional — the portal toggle is driven by FOCUS, not by
      // empty-suggestions. A user who's typing should see "no
      // results yet" briefly rather than the panel flickering off
      // and on as suggestions arrive.
      return const SizedBox.shrink();
    }
    final cs = Theme.of(overlayCtx).colorScheme;
    final screenWidth = MediaQuery.of(overlayCtx).size.width;
    // Width matches the form's content column (page is padded by 16
    // on each side in challenge_metadata_page.dart). Picking this up
    // from the LayerLink's target box would be more robust but
    // introduces a measure-then-paint cycle for a value we already
    // know — the static page padding lets us position immediately.
    final width = (screenWidth - 32).clamp(0, screenWidth);

    return Positioned(
      width: width.toDouble(),
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        // Offset the dropdown by the actual measured field height so
        // it sits directly under the input. Static 56 was wrong for
        // fields with helper text — they're taller, and the
        // dropdown overlapped them.
        offset: Offset(0, _fieldHeight + 4),
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          color: cs.surfaceContainerHigh,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: widget.suggestions.length,
              itemBuilder: (_, i) {
                final opt = widget.suggestions[i];
                return InkWell(
                  onTap: () => _onTap(opt),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: widget.buildRow(opt),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CompositedTransformTarget(
      link: _link,
      // OverlayPortal wraps the field. When .show() is called the
      // overlayChildBuilder is mounted into the nearest Overlay; on
      // every State.build it rebuilds, so async suggestion updates
      // flow through automatically.
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildOverlay,
        child: _MeasuredField(
          onMeasured: (h) {
            if ((h - _fieldHeight).abs() > 0.5) {
              setState(() => _fieldHeight = h);
            }
          },
          child: TextFormField(
            controller: widget.controller,
            focusNode: _focus,
            validator: widget.validator,
            style: TextStyle(color: cs.onSurface),
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.hint,
              labelStyle:
                  TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
              hintStyle:
                  TextStyle(color: cs.onSurface.withValues(alpha: 0.45)),
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
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiny helper that measures its child's height and reports it via
/// [onMeasured] on the next frame. Used by [SuggestField] so the
/// dropdown can sit immediately below the field regardless of how
/// the InputDecoration renders (with/without helper text, error
/// state, etc.).
class _MeasuredField extends StatefulWidget {
  final Widget child;
  final ValueChanged<double> onMeasured;
  const _MeasuredField({required this.child, required this.onMeasured});

  @override
  State<_MeasuredField> createState() => _MeasuredFieldState();
}

class _MeasuredFieldState extends State<_MeasuredField> {
  final GlobalKey _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _key.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      widget.onMeasured(box.size.height);
    });
    return SizedBox(key: _key, child: widget.child);
  }
}
