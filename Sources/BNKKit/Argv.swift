import Foundation

/// Turning a typed line into the argv `pods/exec` wants, and back again.
///
/// There is no shell on the far side of exec — the argv goes to the container
/// directly — so pipes, redirection and globbing genuinely do not work, and
/// nothing here pretends otherwise. Quoting is a different matter. `imish`
/// takes each ZebOS command as a single argument, as in
/// `imish -e en -e "show ip bgp summary"`, so a line that cannot express one
/// argument containing spaces cannot drive the routing container at all.
public enum Argv {

    /// Split on whitespace, honouring single and double quotes and backslash.
    public static func split(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
                started = true
                escaped = false
            } else if character == "\\" && quote != "'" {
                // A backslash inside single quotes is literal, as in a shell.
                escaped = true
            } else if let open = quote {
                started = true
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { out.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { out.append(current) }
        return out
    }

    /// The line that would split back into `arguments`.
    ///
    /// This is what the screen shows for a command that has run, so what is
    /// echoed can be edited and run again rather than being a lossy rendering
    /// that quietly loses the quotes.
    public static func join(_ arguments: [String]) -> String {
        arguments.map { argument in
            if argument.isEmpty { return "\"\"" }
            let needsQuotes = argument.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }
            guard needsQuotes else { return argument }
            let escaped = argument
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        .joined(separator: " ")
    }
}
