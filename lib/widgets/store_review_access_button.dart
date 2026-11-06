import 'package:flutter/material.dart';

import '../services/supporter/supporter_service.dart';
import '../i18n/strings.g.dart';

/// Visible, documented store-review access. Not a purchase or a trial reset.
class StoreReviewAccessButton extends StatelessWidget {
  const StoreReviewAccessButton({super.key, required this.service});

  final SupporterService service;

  @override
  Widget build(BuildContext context) {
    if (!service.supportsReviewAccess) return const SizedBox.shrink();
    return TextButton(
      onPressed: () => _redeem(context),
      child: Text(service.hasReviewAccess ? t.appAccess.reviewAccessActive : t.appAccess.reviewAccess),
    );
  }

  Future<void> _redeem(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => _ReviewAccessDialog(service: service),
  );
}

class _ReviewAccessDialog extends StatefulWidget {
  const _ReviewAccessDialog({required this.service});
  final SupporterService service;

  @override
  State<_ReviewAccessDialog> createState() => _ReviewAccessDialogState();
}

class _ReviewAccessDialogState extends State<_ReviewAccessDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    setState(() => _busy = true);
    var accepted = false;
    try {
      accepted = await widget.service.redeemReviewAccess(_controller.text);
    } catch (_) {
      // Never log the grant, signature, or store credentials.
    }
    if (!mounted) return;
    if (accepted) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = t.appAccess.reviewCodeInvalid;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t.appAccess.reviewAccess),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(t.appAccess.reviewAccessInstructions),
        const SizedBox(height: 12),
        TextField(
          controller: _controller,
          autofocus: true,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 4096,
          decoration: InputDecoration(labelText: t.appAccess.reviewCode, errorText: _error),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(t.common.cancel)),
      FilledButton(onPressed: _busy ? null : _activate, child: Text(t.appAccess.activateReviewAccess)),
    ],
  );
}
