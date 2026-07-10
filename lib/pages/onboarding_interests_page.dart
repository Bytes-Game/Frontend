import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';

/// Post-signup interest picker. The picks seed CategoryAffinity server-
/// side (POST /api/v1/profile/interests) so a brand-new account's very
/// first feed page is relevance-ordered instead of pure popularity —
/// this screen is a ranking feature wearing an onboarding costume.
///
/// Skippable on purpose: a forced picker produces junk picks, and the
/// cold-start ladder still works without them.
class OnboardingInterestsPage extends StatefulWidget {
  const OnboardingInterestsPage({super.key});

  @override
  State<OnboardingInterestsPage> createState() =>
      _OnboardingInterestsPageState();
}

class _OnboardingInterestsPageState extends State<OnboardingInterestsPage>
    with PageTracker<OnboardingInterestsPage> {
  List<String> _categories = [];
  final Set<String> _picked = {};
  bool _loading = true;
  bool _submitting = false;

  static const _minPicks = 3;

  @override
  String get pageName => 'onboarding_interests';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await ApiService.getCategories();
    if (!mounted) return;
    setState(() {
      _categories = (data['categories'] as List? ?? [])
          .map((e) => e.toString())
          .toList();
      _loading = false;
    });
  }

  Future<void> _finish({required bool skipped}) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    if (!skipped && _picked.isNotEmpty) {
      await ApiService.seedInterests(_picked.toList());
    }
    EventTracker.instance.trackTap(
      target: skipped ? 'onboarding_skip' : 'onboarding_done',
      pageName: pageName,
      params: {'pickedCount': _picked.length},
    );
    if (!mounted) return;
    Provider.of<AuthProvider>(context, listen: false).completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canContinue = _picked.length >= _minPicks && !_submitting;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: TextButton(
                  onPressed:
                      _submitting ? null : () => _finish(skipped: true),
                  child: const Text('Skip'),
                ),
              ),
              const SizedBox(height: 8),
              Text('What are you into?',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      )),
              const SizedBox(height: 8),
              Text(
                'Pick at least $_minPicks — your feed starts here and '
                'learns from everything you watch.',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : SingleChildScrollView(
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: _categories.map((cat) {
                            final selected = _picked.contains(cat);
                            return FilterChip(
                              label: Text(cat),
                              selected: selected,
                              showCheckmark: false,
                              selectedColor: cs.primaryContainer,
                              onSelected: (_) {
                                setState(() {
                                  if (selected) {
                                    _picked.remove(cat);
                                  } else {
                                    _picked.add(cat);
                                  }
                                });
                              },
                            );
                          }).toList(),
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      canContinue ? () => _finish(skipped: false) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _picked.length < _minPicks
                          ? 'Pick ${_minPicks - _picked.length} more'
                          : "Let's go",
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
