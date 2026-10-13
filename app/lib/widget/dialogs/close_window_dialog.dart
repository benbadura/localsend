import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';

enum CloseWindowAction { quit, hide }

class CloseWindowDialog extends StatelessWidget {
  const CloseWindowDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final isMacOS = Theme.of(context).platform == TargetPlatform.macOS;
    return AlertDialog(
      title: Text(t.dialogs.closeWindow.title),
      content: Text(t.dialogs.closeWindow.content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.general.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(CloseWindowAction.quit),
          child: Text(t.tray.close),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(CloseWindowAction.hide),
          child: Text(isMacOS ? t.dialogs.closeWindow.minimizeToMenuBar : t.dialogs.closeWindow.minimizeToTray),
        ),
      ],
    );
  }
}
