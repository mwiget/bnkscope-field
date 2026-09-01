import os

/// The app's loggers. One subsystem, so everything Field says can be read with
///
///     log stream --predicate 'subsystem == "com.mwiget.bnkscope.field"'
///
/// The release build has no other window into what the scrape loop is doing:
/// CFNetwork logs the WebSocket upgrade and nothing after it, so a tunnel that
/// opens and then never delivers a byte is invisible from outside without this.
public enum Log {
    public static let subsystem = "com.mwiget.bnkscope.field"
    public static let telemetry = Logger(subsystem: subsystem, category: "telemetry")
    public static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
}
