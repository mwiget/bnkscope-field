/// The entire platform divergence of the app. Everything else is one code
/// path; a `Platform.is…` check anywhere else is a smell.
library;

import 'dart:io';

import 'package:bnk_engines/bnk_engines.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// What to call the machine, where its privacy switch lives, and where a
/// file comes from. An iPad's wording on a Mac reads as a bug.
DeviceWords get deviceWords {
  if (Platform.isMacOS) {
    return const DeviceWords(
        thisDevice: 'this Mac',
        localNetworkSetting: 'System Settings › Privacy & Security › Local Network',
        importSource: 'from Finder');
  }
  if (Platform.isIOS) {
    return const DeviceWords(
        thisDevice: 'this iPad',
        localNetworkSetting: 'Settings › Privacy & Security › Local Network',
        importSource: 'from Files');
  }
  if (Platform.isWindows) {
    return const DeviceWords(
        thisDevice: 'this PC',
        localNetworkSetting: 'Windows Security › Firewall & network protection',
        importSource: 'from File Explorer');
  }
  return const DeviceWords(
      thisDevice: 'this device',
      localNetworkSetting: 'the system privacy settings',
      importSource: 'from a file');
}

/// Room for the system's own window controls, which only iPadOS draws over
/// the app's content. Everything else puts them in a title bar.
double get windowControlInset => Platform.isIOS ? 72 : 0;

/// Trailing on iPadOS, leading elsewhere, and the difference is not taste:
/// in a window, iPadOS draws its close/minimise/resize controls over the
/// top-left corner and does not inset the content to make room.
bool get wordmarkTrailing => Platform.isIOS;

/// Open a desktop window wide enough for the sidebar and two chart panels
/// beside it. The split folds the sidebar away below 900 points, and the
/// platform templates' 800-point windows start life looking collapsed.
Future<void> sizeDesktopWindow() async {
  if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) return;
  await windowManager.ensureInitialized();
  await windowManager.setMinimumSize(const Size(480, 400));
  final size = await windowManager.getSize();
  if (size.width < 1180) {
    await windowManager.setSize(const Size(1180, 780));
    await windowManager.center();
  }
}
