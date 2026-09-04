/// Turning a typed line into the argv `pods/exec` wants, and back again.
///
/// There is no shell on the far side of exec, the argv goes to the container
/// directly, so pipes, redirection and globbing genuinely do not work, and
/// nothing here pretends otherwise. Quoting is a different matter. `imish`
/// takes each ZebOS command as a single argument, as in
/// `imish -e en -e "show ip bgp summary"`, so a line that cannot express one
/// argument containing spaces cannot drive the routing container at all.
class Argv {
  /// Split on whitespace, honouring single and double quotes and backslash.
  static List<String> split(String line) {
    final out = <String>[];
    final current = StringBuffer();
    var started = false;
    String? quote;
    var escaped = false;

    for (var i = 0; i < line.length; i++) {
      final character = line[i];
      if (escaped) {
        current.write(character);
        started = true;
        escaped = false;
      } else if (character == r'\' && quote != "'") {
        // A backslash inside single quotes is literal, as in a shell.
        escaped = true;
      } else if (quote != null) {
        started = true;
        if (character == quote) {
          quote = null;
        } else {
          current.write(character);
        }
      } else if (character == "'" || character == '"') {
        quote = character;
        started = true;
      } else if (character.trim().isEmpty) {
        if (started) out.add(current.toString());
        current.clear();
        started = false;
      } else {
        current.write(character);
        started = true;
      }
    }
    if (started) out.add(current.toString());
    return out;
  }

  /// The line that would split back into [arguments].
  ///
  /// This is what the screen shows for a command that has run, so what is
  /// echoed can be edited and run again rather than being a lossy rendering
  /// that quietly loses the quotes.
  static String join(List<String> arguments) {
    return arguments.map((argument) {
      if (argument.isEmpty) return '""';
      final needsQuotes = argument.split('').any(
          (c) => c.trim().isEmpty || c == '"' || c == "'" || c == r'\');
      if (!needsQuotes) return argument;
      final escaped =
          argument.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      return '"$escaped"';
    }).join(' ');
  }
}
