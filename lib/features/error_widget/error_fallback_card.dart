import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:paperless_mobile/core/extensions/flutter_extensions.dart';
import 'package:url_launcher/url_launcher_string.dart';

class ErrorFallbackCard extends StatefulWidget {
  final FlutterErrorDetails errorDetails;

  @override
  const ErrorFallbackCard({super.key, required this.errorDetails});

  @override
  State<ErrorFallbackCard> createState() => _ErrorFallbackCardState();
}

class _ErrorFallbackCardState extends State<ErrorFallbackCard> {
  @override
  Widget build(BuildContext context) {
    final firstStackElement = widget.errorDetails.stack
        .toString()
        .split("\n")
        .firstOrNull
        ?.replaceFirst("#0 ", "");

    final issueBodyDescription =
        "Error Summary: ${widget.errorDetails.toStringShort()}: "
        "_${widget.errorDetails.summary.toDescription()}_\n"
        "Occurred in ${firstStackElement ?? "an unknown location"}\n\n";
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Column(
        spacing: 8,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.onErrorContainer,
            size: 48,
          ),
          Text(
            "Oops, seems like there was an issue with this element. This is not supposed to happen, feel free to file a bug on GitHub!",
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          ExpansionTile(
            title: Text('Error Details'),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Summary", style: Theme.of(context).textTheme.labelLarge),
              Text(widget.errorDetails.toStringShort()),
              Text(widget.errorDetails.summary.toDescription()),
              Text("Origin", style: Theme.of(context).textTheme.labelLarge),
              Text(firstStackElement ?? ""),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: issueBodyDescription));
                },
                icon: const Icon(Icons.copy),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: () {
                  final uri = Uri(
                    host: 'github.com',
                    path: '/pr3st0n007/paperless-mobile/issues/new',
                    scheme: 'https',
                    queryParameters: {
                      'assignees': 'pr3st0n007',
                      'labels': 'bug,triage,corrupt-element',
                      'projects': '',
                      'template': 'bug-report.yml',
                    },
                  );
                  launchUrlString(
                    uri.toString(),
                    mode: LaunchMode.externalApplication,
                  );
                },
                icon: const Icon(Icons.open_in_new),
                label: const Text("Report Bug"),
              ),
            ],
          ),
        ],
      ).padded(16),
    );
  }
}
