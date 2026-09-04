import 'package:logging/logging.dart';

/// The package's loggers. One subsystem, so everything Field says can be
/// caught by a single listener on [Logger.root]:
///
///     Logger.root.onRecord.listen((r) => stderr.writeln('${r.loggerName}: ${r.message}'));
///
/// The release build has no other window into what the scrape loop is doing:
/// a tunnel that opens and then never delivers a byte is invisible from
/// outside without this.
class Log {
  static const subsystem = 'com.mwiget.bnkscope.field';
  static final telemetry = Logger('$subsystem.telemetry');
  static final tunnel = Logger('$subsystem.tunnel');
}
