// OnlineFix's install path is broken in this build: the fix that gets copied into a
// game cannot be trusted to leave the game playable. Its buttons say so instead of
// starting work that cannot finish, and the rest of macSteam is unaffected.
enum OnlineFixAvailability {
    static let isBroken = true

    static let message = "OnlineFix is broken in this build — don't use the install buttons."
}
