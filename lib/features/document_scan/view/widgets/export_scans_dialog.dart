import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:paperless_mobile/core/widgets/dialog_utils/dialog_cancel_button.dart';
import 'package:paperless_mobile/core/widgets/dialog_utils/dialog_confirm_button.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

class ExportScansDialog extends StatefulWidget {
  const ExportScansDialog({super.key});

  @override
  State<ExportScansDialog> createState() => _ExportScansDialogState();
}

class _ExportScansDialogState extends State<ExportScansDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _filename;
  late final String _defaultName;

  @override
  void initState() {
    super.initState();
    final date = DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now());
    _defaultName = 'Scan_$date';
    _filename = TextEditingController(text: _defaultName);
    _filename.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _defaultName.length,
    );
  }

  @override
  void dispose() {
    _filename.dispose();
    super.dispose();
  }

  void _export() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _filename.text.trim().replaceFirst(
      RegExp(r'\.pdf$', caseSensitive: false),
      '',
    );
    Navigator.pop(context, name.isEmpty ? _defaultName : name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      title: Text(S.of(context)!.exportScansToPdf),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(S.of(context)!.allScansWillBeMerged),
              SizedBox(height: 16),
              TextFormField(
                controller: _filename,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _export(),
                autofocus: true,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: (value) {
                  final matches = RegExp(
                    r'[<>:"/\\|?*\x00-\x1F]',
                  ).allMatches(value!);
                  if (matches.isNotEmpty) {
                    final illegalCharacters = matches
                        .map((match) => match.group(0))
                        .toList()
                        .toSet()
                        .join(" ");
                    return S
                        .of(context)!
                        .invalidFilenameCharacter(illegalCharacters);
                  }

                  if (value.trim() == '.' || value.trim() == '..') {
                    return S.of(context)!.invalidFilenameCharacter('.');
                  }
                  return null;
                },
                decoration: InputDecoration(
                  labelText: S.of(context)!.fileName,
                  errorMaxLines: 5,
                  suffixText: ".pdf",
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        const DialogCancelButton(),
        DialogConfirmButton(label: S.of(context)!.export, onPressed: _export),
      ],
    );
  }
}
