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

  Future<void> _redeem(BuildContext context) async {
    final controller = TextEditingController();
    String? error;
    var busy = false;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(t.appAccess.reviewAccess),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t.appAccess.reviewAccessInstructions),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 4096,
                  decoration: InputDecoration(labelText: t.appAccess.reviewCode, errorText: error),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: Text(t.common.cancel)),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => busy = true);
                        var accepted = false;
                        try {
                          accepted = await service.redeemReviewAccess(controller.text);
                        } catch (_) {
                          // No token, signature, or store credentials in logs.
                        }
                        if (!context.mounted) return;
                        if (accepted) {
                          Navigator.pop(context);
                        } else {
                          setState(() {
                            busy = false;
                            error = t.appAccess.reviewCodeInvalid;
                          });
                        }
                      },
                child: Text(t.appAccess.activateReviewAccess),
              ),
            ],
          ),
        ),
      );
    } finally {
      // Dialog route transitions finish after showDialog completes.
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }
}
