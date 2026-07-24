import AppCore
import ArgumentParser
import Foundation

/// The root command. Existing command names and options are preserved; the new
/// `client` group adds machine and dashboard read commands.
struct RootCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ccusage-gauge",
    abstract: "Local ccusage dashboard server and dashboard API client.",
    version: Version.current,
    subcommands: [
      ConfigCheckCommand.self,
      UsageSnapshotCommand.self,
      ServeCommand.self,
      ClientCommand.self
    ]
  )
}

extension RootCommand {
  /// Maps an entry-point failure to the documented exit statuses: 0 for
  /// help/version, 2 for usage/validation errors, and 1 for other runtime
  /// failures. Client commands throw `ExitCode` directly and never reach this.
  static func terminationStatus(for error: Error) -> Int32 {
    let status = exitCode(for: error)
    if status == ExitCode.success { return 0 }
    return status == ExitCode.validationFailure ? 2 : 1
  }
}

/// Custom entry point. It maps ArgumentParser parse/validation failures to the
/// documented exit status 2 and other runtime failures to exit status 1 while
/// keeping help and version output on exit 0. Command runtime failures that
/// throw `ExitCode` values are surfaced verbatim.
@main
enum CCUsageGaugeMain {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var bootstrapLogger: BootstrapLogger?
    do {
      let command = try RootCommand.parseAsRoot(arguments)
      if let runtime = bootstrapRuntime(arguments: arguments) {
        let paths = AppPaths.production()
        let logger = BootstrapLogger(paths: paths, runtime: runtime)
        logger.activate()
        bootstrapLogger = logger
      }
      if var asyncCommand = command as? AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        var syncCommand = command
        try syncCommand.run()
      }
    } catch let exit as ExitCode {
      if exit != .success {
        bootstrapLogger?.append(
          phase: "clientRequest",
          code: "client_request_failed",
          message: "Dashboard client request failed"
        )
      }
      Foundation.exit(exit.rawValue)
    } catch {
      let status = RootCommand.terminationStatus(for: error)
      if status == 0 {
        print(RootCommand.fullMessage(for: error))
        Foundation.exit(0)
      }
      bootstrapLogger?.append(
        phase: "runtime",
        code: "runtime_failed",
        message: "Command runtime failed"
      )
      FileHandle.standardError.write(Data((RootCommand.fullMessage(for: error) + "\n").utf8))
      Foundation.exit(status)
    }
  }

  private static func bootstrapRuntime(arguments: [String]) -> BootstrapRuntime? {
    switch arguments.first {
    case "config-check": .configCheck
    case "usage-snapshot": .usageSnapshot
    case "serve": .serve
    case "client": .client
    default: nil
    }
  }
}
