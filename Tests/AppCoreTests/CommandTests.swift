import Testing
@testable import AppCore

@Test func commandReportsVersion() throws {
  let command = AppCommand(arguments: ["--version"])
  #expect(try command.run() == Version.current)
}

@Test func commandReportsUsage() throws {
  let command = AppCommand(arguments: ["--help"])
  #expect(try command.run().contains("Usage: ccusage-gauge"))
}

@Test func commandRejectsUnknownFlags() throws {
  let command = AppCommand(arguments: ["--unknown"])
  do {
    _ = try command.run()
    Issue.record("Expected an unknown argument error")
  } catch AppCommand.Error.unknownArgument(let argument) {
    #expect(argument == "--unknown")
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
}

@Test func commandParsesServeOptions() throws {
  #expect(try AppCommand(arguments: ["serve"]).parse() == .serve(port: nil, assets: nil))
  #expect(
    try AppCommand(arguments: ["serve", "--port", "19090", "--assets", "/tmp/web"]).parse()
      == .serve(port: 19_090, assets: "/tmp/web")
  )
}

@Test func commandRejectsInvalidServeOptions() throws {
  #expect(throws: AppCommand.Error.invalidValue("Invalid port: 0")) {
    try AppCommand(arguments: ["serve", "--port", "0"]).parse()
  }
  #expect(throws: AppCommand.Error.invalidValue("Missing value for --port")) {
    try AppCommand(arguments: ["serve", "--port"]).parse()
  }
  #expect(throws: AppCommand.Error.unknownArgument("--unknown")) {
    try AppCommand(arguments: ["serve", "--unknown", "value"]).parse()
  }
  #expect(throws: AppCommand.Error.unknownArgument("dashboard")) {
    try AppCommand(arguments: ["dashboard"]).parse()
  }
}
