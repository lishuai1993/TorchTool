import AppKit

logDebug("main.swift: entry point")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
logDebug("main.swift: starting run loop...")
app.run()
