# Privileged helper (`com.conso.conso.helper`)

This directory holds the launchd property list for conso's privileged helper —
the `SMAppService` daemon that performs the few operations that genuinely
require root.

- **`com.conso.conso.helper.plist`** — the LaunchDaemon plist. The Xcode app
  target embeds it at `Contents/Library/LaunchDaemons/` so `SMAppService` can
  register and manage the daemon.

The helper's **source code** lives in **`conso/conso-helper/main.swift`** (the
Xcode `conso-helper` target). The app-side XPC client is
**`Sources/conso/HelperClient.swift`**.

## How it stays safe

- The XPC connection is **code-sign-validated in both directions**: the daemon
  only accepts the signed conso app, and the app only talks to a daemon signed
  by the same Apple Developer Team ID.
- The daemon exposes a **fixed, server-side allow-list** of operations — fixed
  command keys plus a regex-validated snapshot date. It never runs a shell or
  caller-supplied arguments.

> **Contributors:** the Team ID used for that mutual code-sign validation is set
> in `conso/conso-helper/main.swift` and `Sources/conso/HelperClient.swift` —
> replace it with your own (see [CONTRIBUTING](../CONTRIBUTING.md)).
