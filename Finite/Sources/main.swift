import AppKit

// Initialize the Ghostty library before anything else.
let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
guard initResult == GHOSTTY_SUCCESS else {
    fatalError("ghostty_init failed with code \(initResult)")
}

// Create the application and set up the delegate manually
// (no MainMenu.nib — we build the UI programmatically)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Create a complete menu bar
let mainMenu = NSMenu()

// -- Application menu --
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About Finite", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit Finite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

// -- Edit menu (needed for Cmd+C/V to work with the responder chain) --
let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenu.addItem(NSMenuItem.separator())
let deselectItem = editMenu.addItem(withTitle: "Deselect All", action: #selector(AppDelegate.deselectAll(_:)), keyEquivalent: "\u{1B}")
deselectItem.keyEquivalentModifierMask = []
editMenuItem.submenu = editMenu

// -- Terminal menu --
let terminalMenuItem = NSMenuItem()
mainMenu.addItem(terminalMenuItem)
let terminalMenu = NSMenu(title: "Terminal")
terminalMenu.addItem(withTitle: "New Terminal", action: #selector(AppDelegate.newTerminal(_:)), keyEquivalent: "n")

let dupItem = terminalMenu.addItem(withTitle: "Duplicate Terminal", action: #selector(AppDelegate.duplicateTerminal(_:)), keyEquivalent: "d")
dupItem.keyEquivalentModifierMask = [.command, .shift]

terminalMenu.addItem(NSMenuItem.separator())

let closeItem = terminalMenu.addItem(withTitle: "Close Terminal", action: #selector(AppDelegate.closeTerminal(_:)), keyEquivalent: "w")
closeItem.keyEquivalentModifierMask = [.command]

terminalMenuItem.submenu = terminalMenu

// -- View menu --
let viewMenuItem = NSMenuItem()
mainMenu.addItem(viewMenuItem)
let viewMenu = NSMenu(title: "View")

let toggleSidebarItem = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(AppDelegate.toggleSidebarPanel(_:)), keyEquivalent: "s")
toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]

let toggleMinimapItem = viewMenu.addItem(withTitle: "Toggle Minimap", action: #selector(AppDelegate.toggleMinimap(_:)), keyEquivalent: "m")
toggleMinimapItem.keyEquivalentModifierMask = [.command, .option]

viewMenu.addItem(NSMenuItem.separator())

let fitAllItem = viewMenu.addItem(withTitle: "Zoom to Fit All", action: #selector(AppDelegate.zoomToFitAll(_:)), keyEquivalent: "0")
fitAllItem.keyEquivalentModifierMask = [.command, .option]

let fitFocusedItem = viewMenu.addItem(withTitle: "Zoom to Fit Terminal", action: #selector(AppDelegate.zoomToFitFocused(_:)), keyEquivalent: "f")
fitFocusedItem.keyEquivalentModifierMask = [.command, .option]

viewMenu.addItem(NSMenuItem.separator())

let tidyItem = viewMenu.addItem(withTitle: "Tidy Selection", action: #selector(AppDelegate.tidySelection(_:)), keyEquivalent: "t")
tidyItem.keyEquivalentModifierMask = [.command, .option]

viewMenu.addItem(NSMenuItem.separator())

let navLeftItem = viewMenu.addItem(withTitle: "Navigate Left", action: #selector(AppDelegate.navigateLeft(_:)), keyEquivalent: "\u{F702}")
navLeftItem.keyEquivalentModifierMask = [.command, .option]

let navRightItem = viewMenu.addItem(withTitle: "Navigate Right", action: #selector(AppDelegate.navigateRight(_:)), keyEquivalent: "\u{F703}")
navRightItem.keyEquivalentModifierMask = [.command, .option]

let navUpItem = viewMenu.addItem(withTitle: "Navigate Up", action: #selector(AppDelegate.navigateUp(_:)), keyEquivalent: "\u{F700}")
navUpItem.keyEquivalentModifierMask = [.command, .option]

let navDownItem = viewMenu.addItem(withTitle: "Navigate Down", action: #selector(AppDelegate.navigateDown(_:)), keyEquivalent: "\u{F701}")
navDownItem.keyEquivalentModifierMask = [.command, .option]

viewMenuItem.submenu = viewMenu

// -- Window menu --
let windowMenuItem = NSMenuItem()
mainMenu.addItem(windowMenuItem)
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
windowMenu.addItem(NSMenuItem.separator())
windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
windowMenuItem.submenu = windowMenu
app.windowsMenu = windowMenu

app.mainMenu = mainMenu
app.run()
