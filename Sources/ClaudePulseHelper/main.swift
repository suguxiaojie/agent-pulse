import Foundation
let arguments = Array(CommandLine.arguments.dropFirst())
if !ClaudeCodeHookMode.handles(arguments) {
    _ = AntigravityHookMode.handles(arguments)
}
