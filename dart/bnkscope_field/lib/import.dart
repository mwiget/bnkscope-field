import 'dart:convert';

import 'package:bnk_engines/bnk_engines.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Pick one or more kubeconfigs and adopt every context in them, then probe.
///
/// The file is read here and handed to the store as text: the store does not
/// know about pickers, and on iOS the picked file lives outside the sandbox
/// for exactly as long as the picker says.
Future<void> importKubeconfigs(BuildContext context, ClusterStore store) async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Import kubeconfig',
    allowMultiple: true,
    withData: true,
  );
  if (result == null) return;
  for (final file in result.files) {
    final bytes = file.bytes;
    if (bytes == null) continue;
    await store.importKubeconfig(utf8.decode(bytes, allowMalformed: true));
    final error = store.importError;
    if (error != null && context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not import that file'),
          content: Text(error),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
        ),
      );
    }
  }
  await store.probeAll();
}
