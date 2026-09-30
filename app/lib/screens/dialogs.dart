import 'package:flutter/material.dart';

/// Asks for one line of text; null when cancelled or left empty.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  bool obscure = false,
  String? message,
  /// Return '' for an empty answer instead of null, so it can be told
  /// apart from cancelling.
  bool allowEmpty = false,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message != null) ...[Text(message), const SizedBox(height: 8)],
          TextField(
            key: const Key('askText'),
            controller: controller,
            autofocus: true,
            obscureText: obscure,
            decoration: InputDecoration(labelText: label),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          key: const Key('askTextOk'),
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('確定'),
        ),
      ],
    ),
  );
  final text = result?.trim();
  if (text == null) return null;
  return text.isEmpty && !allowEmpty ? null : text;
}

/// A yes/no question; true only when [action] is chosen.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String action,
  String? message,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: message == null ? null : Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            key: const Key('confirmOk'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

/// Shows [message] briefly at the bottom of the screen.
void showMessage(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
