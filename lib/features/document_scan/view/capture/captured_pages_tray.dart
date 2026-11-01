import 'package:flutter/material.dart';
import 'package:paperless_mobile/features/document_scan/capture/capture_draft.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

/// Horizontal strip of captured pages. Scrolls to the newest page and marks
/// the page being retaken.
class CapturedPagesTray extends StatefulWidget {
  final List<CapturedPage> pages;
  final int? retakeIndex;
  final ValueChanged<int> onOpen;

  const CapturedPagesTray({
    super.key,
    required this.pages,
    required this.onOpen,
    this.retakeIndex,
  });

  @override
  State<CapturedPagesTray> createState() => _CapturedPagesTrayState();
}

class _CapturedPagesTrayState extends State<CapturedPagesTray> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(CapturedPagesTray oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pages.length > oldWidget.pages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: widget.pages.isEmpty
          ? const SizedBox(width: double.infinity)
          : SizedBox(
              height: 88,
              child: ListView.separated(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                scrollDirection: Axis.horizontal,
                itemCount: widget.pages.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final page = widget.pages[index];
                  final retaking = widget.retakeIndex == index;
                  return Semantics(
                    button: true,
                    label: s.scannerPageLabel(index + 1),
                    hint: s.scannerEditCaptured,
                    excludeSemantics: true,
                    child: GestureDetector(
                      key: ValueKey(page.originalFile.path),
                      onTap: () => widget.onOpen(index),
                      child: Container(
                        width: 54,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: retaking ? scheme.primary : Colors.white24,
                            width: retaking ? 2.5 : 1,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.memory(
                              page.preview,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              cacheWidth: 160,
                            ),
                            Align(
                              alignment: Alignment.bottomRight,
                              child: Container(
                                margin: const EdgeInsets.all(3),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '${index + 1}',
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
