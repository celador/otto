import Foundation

/// Where UI tests drop screenshots / trees for the agent to read: $HOME/.hermes/cache/scratch on the
/// Mac running the simulator (SIMULATOR_HOST_HOME), else the runner's temporary directory.
let hostScratch: String = {
    let env = ProcessInfo.processInfo.environment
    if let home = env["SIMULATOR_HOST_HOME"], !home.isEmpty { return home + "/.hermes/cache/scratch" }
    return NSTemporaryDirectory()
}()
