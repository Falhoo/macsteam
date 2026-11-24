// Emergency switch for the install path. The current scanner is healthy: it audits
// every installed pack, rewrites dlllist.txt correctly, and PICO PARK 2 boots with
// the fix. Keep the switch so a genuinely broken release can disable installs, but
// leave it off in normal builds.
enum OnlineFixAvailability {
    static let isBroken = false

    static let message = "OnlineFix is unavailable in this build. Don't use the install buttons."
}
