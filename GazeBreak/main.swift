import Cocoa

// MARK: - GazeBreak
// Lightweight native macOS eye-break timer.
// Settings window -> background timer (hidden from Dock) -> fullscreen break overlay.

// Borderless window that can still take keyboard focus (needed for
// typing in fields + Return key). Gives us full control of corner radius.
final class GlassWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {

    var settingsWindow: NSWindow!
    var breakWindow: NSWindow?

    var workValueField: NSTextField!
    var workUnitPopUp: NSPopUpButton!
    var restValueField: NSTextField!
    var restUnitPopUp: NSPopUpButton!
    var breakTitleField: NSTextField!
    var breakMessageField: NSTextField!
    var statusLabel: NSTextField!
    var startButton: NSButton!

    var focusTimer: Timer?
    var breakTimer: Timer?
    var breakSecondsLeft: Int = 20
    var breakCountdownLabel: NSTextField?
    var breakProgress: NSProgressIndicator?

    var breakDurationSeconds = 20
    var currentBreakTitle = "Time to step away!"
    var currentBreakMessage = "Look away from your screen and rest your eyes."

    let defaults = UserDefaults.standard

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildSettingsWindow()
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Only quit if the user closed Settings and no break is showing.
        // If a focus session is running in the background, keep running.
        if focusTimer != nil || breakWindow != nil {
            return false
        }
        return true
    }

    // MARK: - Settings window

    func loadGazeIcon() -> NSImage? {
        // 1. Preferred: Gaze_v3.0.png in app bundle Resources
        if let url = Bundle.main.url(forResource: "Gaze_v3.0", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        // 2. Fallback: Resources next to executable (dev runs)
        let fm = FileManager.default
        if let resPath = Bundle.main.resourcePath {
            let p = (resPath as NSString).appendingPathComponent("Gaze_v3.0.png")
            if fm.fileExists(atPath: p), let img = NSImage(contentsOfFile: p) {
                return img
            }
        }
        return nil
    }

    // Wraps an editable field in a clear, pill-rounded glass box.
    // Container carries the border + radius; the field itself is transparent.
    func glassFieldBox(_ field: NSTextField, width: CGFloat, height: CGFloat = 30, radius: CGFloat = 11) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = radius
        if #available(macOS 11.0, *) {
            box.layer?.cornerCurve = .continuous
        }
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.35).cgColor
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.delegate = self
        box.addSubview(field)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            box.heightAnchor.constraint(equalToConstant: height),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    func setBoxHighlight(_ field: NSTextField, focused: Bool) {
        guard let box = field.superview else { return }
        box.layer?.borderColor = focused ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
        box.layer?.borderWidth = focused ? 1.5 : 1.0
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField {
            setBoxHighlight(field, focused: true)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField {
            setBoxHighlight(field, focused: false)
        }
    }

    func buildSettingsWindow() {
        let rect = NSRect(x: 0, y: 0, width: 460, height: 710)
        // Custom rounded panel (Droppy-style radius) instead of a standard
        // titled window, so corners are big and continuous.
        settingsWindow = GlassWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "GazeBreak Settings"
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.minSize = NSSize(width: 420, height: 660)
        settingsWindow.maxSize = NSSize(width: 560, height: 800)
        settingsWindow.isOpaque = false
        settingsWindow.backgroundColor = .clear
        settingsWindow.hasShadow = true
        settingsWindow.isMovableByWindowBackground = true
        settingsWindow.delegate = self

        // Clear, big-radius glass background. Desktop blurs through it.
        // The PLAIN container carries the single corner mask (rounding the
        // effect view itself leaves a hairline seam at the corners).
        let container = NSView()
        // NOTE: keep autoresizing (window manages contentView's frame).
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        if #available(macOS 11.0, *) {
            container.layer?.cornerCurve = .continuous
        }
        container.layer?.masksToBounds = true
        settingsWindow.contentView = container
        let content: NSView = container

        let glass = NSVisualEffectView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Traffic lights on a borderless window: borrow them from a throwaway
        // titled window, reparent + retarget. They look and behave standard.
        let helper = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let lightKinds: [(NSWindow.ButtonType, Selector)] = [
            (.closeButton, #selector(NSWindow.performClose(_:))),
            (.miniaturizeButton, #selector(NSWindow.performMiniaturize(_:))),
            (.zoomButton, #selector(NSWindow.performZoom(_:))),
        ]
        var lightX: CGFloat = 20
        for (kind, action) in lightKinds {
            if let b = helper.standardWindowButton(kind) {
                b.removeFromSuperview()
                b.target = settingsWindow
                b.action = action
                b.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(b)
                NSLayoutConstraint.activate([
                    b.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: lightX),
                    b.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
                ])
                lightX += 20
            }
        }

        // --- Icon (128x128, crisp) ---
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 28
        iconView.layer?.masksToBounds = true
        if let icon = loadGazeIcon() {
            iconView.image = icon
        } else {
            // Placeholder so layout still looks right without the asset.
            iconView.image = NSImage(systemSymbolName: "eye.circle.fill", accessibilityDescription: "GazeBreak")
            iconView.contentTintColor = .systemGreen
        }

        // --- Titles ---
        let titleLabel = NSTextField(labelWithString: "GazeBreak")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        titleLabel.alignment = .center

        let subtitle = NSTextField(labelWithString: "Give your eyes a break. Stay focused.")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        // --- Work duration (type any value + unit) ---
        let durationLabel = NSTextField(labelWithString: "Work duration")
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        durationLabel.textColor = .secondaryLabelColor
        durationLabel.alignment = .center

        // Migrate old popup selection once, then use typed values.
        var workText = defaults.string(forKey: "GazeBreak.workText")
        var workUnitIdx = defaults.integer(forKey: "GazeBreak.workUnit")
        if workText == nil, defaults.object(forKey: "GazeBreak.workIndex") != nil {
            switch defaults.integer(forKey: "GazeBreak.workIndex") {
            case 0: workText = "10"; workUnitIdx = 1
            case 2: workText = "45"; workUnitIdx = 0
            case 3: workText = "60"; workUnitIdx = 0
            default: workText = "20"; workUnitIdx = 0
            }
        }
        workValueField = NSTextField(string: workText ?? "20")
        workValueField.translatesAutoresizingMaskIntoConstraints = false
        workValueField.font = NSFont.systemFont(ofSize: 13)
        workValueField.alignment = .center
        workValueField.isEditable = true
        (workValueField.cell as? NSTextFieldCell)?.placeholderString = "20"
        let workBox = glassFieldBox(workValueField, width: 110)
        workUnitPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        workUnitPopUp.translatesAutoresizingMaskIntoConstraints = false
        workUnitPopUp.addItems(withTitles: ["Minutes", "Seconds"])
        workUnitPopUp.selectItem(at: (workUnitIdx == 0 || workUnitIdx == 1) ? workUnitIdx : 0)
        workUnitPopUp.controlSize = .large
        workUnitPopUp.bezelStyle = .rounded
        let workRow = NSStackView()
        workRow.translatesAutoresizingMaskIntoConstraints = false
        workRow.orientation = .horizontal
        workRow.alignment = .centerY
        workRow.spacing = 8
        workRow.addArrangedSubview(workBox)
        workRow.addArrangedSubview(workUnitPopUp)

        // --- Rest duration (type any value + unit) ---
        let restLabel = NSTextField(labelWithString: "Rest duration")
        restLabel.translatesAutoresizingMaskIntoConstraints = false
        restLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        restLabel.textColor = .secondaryLabelColor
        restLabel.alignment = .center

        var restText = defaults.string(forKey: "GazeBreak.restText")
        var restUnitIdx = defaults.integer(forKey: "GazeBreak.restUnit")
        if restText == nil {
            let savedRest = defaults.integer(forKey: "GazeBreak.restSeconds")
            restText = savedRest > 0 ? "\(savedRest)" : "20"
            restUnitIdx = 0 // Seconds
        }
        restValueField = NSTextField(string: restText ?? "20")
        restValueField.translatesAutoresizingMaskIntoConstraints = false
        restValueField.font = NSFont.systemFont(ofSize: 13)
        restValueField.alignment = .center
        restValueField.isEditable = true
        (restValueField.cell as? NSTextFieldCell)?.placeholderString = "20"
        let restBox = glassFieldBox(restValueField, width: 110)
        restUnitPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        restUnitPopUp.translatesAutoresizingMaskIntoConstraints = false
        restUnitPopUp.addItems(withTitles: ["Seconds", "Minutes"])
        restUnitPopUp.selectItem(at: (restUnitIdx == 0 || restUnitIdx == 1) ? restUnitIdx : 0)
        restUnitPopUp.controlSize = .large
        restUnitPopUp.bezelStyle = .rounded
        let restRow = NSStackView()
        restRow.translatesAutoresizingMaskIntoConstraints = false
        restRow.orientation = .horizontal
        restRow.alignment = .centerY
        restRow.spacing = 8
        restRow.addArrangedSubview(restBox)
        restRow.addArrangedSubview(restUnitPopUp)

        // --- Custom break text (editable) ---
        let breakTitleLabel = NSTextField(labelWithString: "Break title")
        breakTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        breakTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        breakTitleLabel.textColor = .secondaryLabelColor
        breakTitleLabel.alignment = .center

        breakTitleField = NSTextField(string: defaults.string(forKey: "GazeBreak.breakTitle") ?? "Time to step away!")
        breakTitleField.translatesAutoresizingMaskIntoConstraints = false
        breakTitleField.font = NSFont.systemFont(ofSize: 13)
        breakTitleField.alignment = .center
        breakTitleField.isEditable = true
        (breakTitleField.cell as? NSTextFieldCell)?.placeholderString = "Time to step away!"
        let breakTitleBox = glassFieldBox(breakTitleField, width: 320)

        let breakMessageLabel = NSTextField(labelWithString: "Break message")
        breakMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        breakMessageLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        breakMessageLabel.textColor = .secondaryLabelColor
        breakMessageLabel.alignment = .center

        breakMessageField = NSTextField(string: defaults.string(forKey: "GazeBreak.breakMessage") ?? "Look away from your screen and rest your eyes.")
        breakMessageField.translatesAutoresizingMaskIntoConstraints = false
        breakMessageField.font = NSFont.systemFont(ofSize: 13)
        breakMessageField.alignment = .center
        breakMessageField.isEditable = true
        (breakMessageField.cell as? NSTextFieldCell)?.placeholderString = "Look away from your screen and rest your eyes."
        let breakMessageBox = glassFieldBox(breakMessageField, width: 320)

        // --- Start button (prominent, modern) ---
        // Native prominent style: keyEquivalent "\r" + defaultButtonCell below
        // makes AppKit render it in the accent color automatically.
        startButton = NSButton(title: "Start Focus Session", target: self, action: #selector(startFocusSession))
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        startButton.keyEquivalent = "\r" // Return key triggers it -> becomes blue/accent default button

        statusLabel = NSTextField(labelWithString: "Ready • Choose a duration and start focusing.")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 2
        statusLabel.cell?.wraps = true

        // --- Stack layout, centered ---
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitle)
        // spacer
        let spacer1 = NSView()
        spacer1.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spacer1.heightAnchor.constraint(equalToConstant: 8)
        ])
        stack.addArrangedSubview(spacer1)
        stack.addArrangedSubview(durationLabel)
        stack.addArrangedSubview(workRow)
        stack.addArrangedSubview(restLabel)
        stack.addArrangedSubview(restRow)
        stack.addArrangedSubview(breakTitleLabel)
        stack.addArrangedSubview(breakTitleBox)
        stack.addArrangedSubview(breakMessageLabel)
        stack.addArrangedSubview(breakMessageBox)
        let spacer2 = NSView()
        spacer2.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spacer2.heightAnchor.constraint(equalToConstant: 8)
        ])
        stack.addArrangedSubview(spacer2)
        stack.addArrangedSubview(startButton)
        stack.addArrangedSubview(statusLabel)
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(16, after: spacer2)

        content.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 128),
            iconView.heightAnchor.constraint(equalToConstant: 128),

            workUnitPopUp.widthAnchor.constraint(equalToConstant: 130),
            restUnitPopUp.widthAnchor.constraint(equalToConstant: 130),
            startButton.widthAnchor.constraint(equalToConstant: 240),
            startButton.heightAnchor.constraint(equalToConstant: 38),

            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),

            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            // Clear the floating traffic lights at the top.
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 56),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])

        // Make Return key + blue highlight work as the default button.
        settingsWindow.defaultButtonCell = startButton.cell as? NSButtonCell
    }

    // MARK: - Focus session

    /// Parses a typed duration. Accepts whole or decimal numbers; returns seconds, or nil if invalid.
    func parseDurationSeconds(text: String, unitIndex: Int, secondsFirst: Bool) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(t), value > 0 else { return nil }
        // Work popup order: Minutes, Seconds. Rest popup order: Seconds, Minutes.
        let isMinutes: Bool
        if secondsFirst {
            isMinutes = (unitIndex == 1)
        } else {
            isMinutes = (unitIndex == 0)
        }
        let seconds = Int((value * (isMinutes ? 60 : 1)).rounded())
        guard seconds >= 1 && seconds <= 86400 else { return nil }
        return seconds
    }

    @objc func startFocusSession() {
        guard let seconds = parseDurationSeconds(text: workValueField.stringValue, unitIndex: workUnitPopUp.indexOfSelectedItem, secondsFirst: false) else {
            statusLabel.stringValue = "Enter a valid work time, e.g. 20 Minutes or 90 Seconds."
            NSSound.beep()
            return
        }
        guard let restSeconds = parseDurationSeconds(text: restValueField.stringValue, unitIndex: restUnitPopUp.indexOfSelectedItem, secondsFirst: true) else {
            statusLabel.stringValue = "Enter a valid rest time, e.g. 20 Seconds or 2 Minutes."
            NSSound.beep()
            return
        }

        // Capture + persist custom rest settings.
        let titleText = breakTitleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageText = breakMessageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        currentBreakTitle = titleText.isEmpty ? "Time to step away!" : titleText
        currentBreakMessage = messageText.isEmpty ? "Look away from your screen and rest your eyes." : messageText
        breakDurationSeconds = max(1, restSeconds)

        defaults.set(workValueField.stringValue, forKey: "GazeBreak.workText")
        defaults.set(workUnitPopUp.indexOfSelectedItem, forKey: "GazeBreak.workUnit")
        defaults.set(restValueField.stringValue, forKey: "GazeBreak.restText")
        defaults.set(restUnitPopUp.indexOfSelectedItem, forKey: "GazeBreak.restUnit")
        defaults.set(breakDurationSeconds, forKey: "GazeBreak.restSeconds")
        defaults.set(currentBreakTitle, forKey: "GazeBreak.breakTitle")
        defaults.set(currentBreakMessage, forKey: "GazeBreak.breakMessage")

        let readable: String
        if seconds < 60 {
            readable = "\(seconds) seconds"
        } else {
            readable = "\(seconds / 60) minutes"
        }
        let restReadable = breakDurationSeconds < 60 ? "\(breakDurationSeconds)s" : "\(breakDurationSeconds / 60)min"
        statusLabel.stringValue = "Focusing for \(readable)… \(restReadable) break next. Settings will hide."
        print("[GazeBreak] Starting focus session: \(seconds)s, break: \(breakDurationSeconds)s")

        // Cancel any previous timer.
        focusTimer?.invalidate()
        focusTimer = nil

        // Animate Settings window closed, then hide from screen + Dock.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.settingsWindow.animator().alphaValue = 0.0
        }, completionHandler: {
            self.settingsWindow.orderOut(nil)
            self.settingsWindow.alphaValue = 1.0 // restore for next show

            // Completely hide app from screen and Dock.
            // LSUIElement in Info.plist is NOT used here because we want
            // Dock visible in Settings mode and hidden only during focus.
            _ = NSApp.setActivationPolicy(.prohibited)
        })

        // Background countdown. Common modes so it fires reliably.
        let t = Timer(
            timeInterval: TimeInterval(seconds),
            target: self,
            selector: #selector(workFinished),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(t, forMode: .common)
        focusTimer = t
    }

    @objc func workFinished() {
        focusTimer?.invalidate()
        focusTimer = nil
        print("[GazeBreak] Work finished — showing break.")
        // Restore normal visibility BEFORE showing break so it can become key.
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showBreakWindow()
    }

    // MARK: - Break window

    func screenUnionFrame() -> NSRect {
        var union = NSRect.zero
        for s in NSScreen.screens {
            union = union.union(s.frame)
        }
        if union.size.width == 0 {
            return NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        }
        return union
    }

    func showBreakWindow() {
        closeBreakWindow()
        breakSecondsLeft = breakDurationSeconds

        let frame = screenUnionFrame()
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver // absolute front of all screens
        win.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.97)
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.isMovable = false

        let content = NSView(frame: frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.97).cgColor
        win.contentView = content

        // Icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 28
        iconView.layer?.masksToBounds = true
        if let icon = loadGazeIcon() {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "eye.circle.fill", accessibilityDescription: "GazeBreak")
            iconView.contentTintColor = .systemGreen
        }

        let headline = NSTextField(labelWithString: currentBreakTitle)
        headline.translatesAutoresizingMaskIntoConstraints = false
        headline.font = NSFont.systemFont(ofSize: 38, weight: .bold)
        headline.textColor = .white
        headline.alignment = .center
        headline.maximumNumberOfLines = 3
        headline.cell?.wraps = true
        headline.preferredMaxLayoutWidth = 900

        let message = NSTextField(labelWithString: currentBreakMessage)
        message.translatesAutoresizingMaskIntoConstraints = false
        message.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        message.textColor = NSColor.white.withAlphaComponent(0.75)
        message.alignment = .center
        message.maximumNumberOfLines = 4
        message.cell?.wraps = true
        message.preferredMaxLayoutWidth = 900

        breakCountdownLabel = NSTextField(labelWithString: "\(breakSecondsLeft)")
        breakCountdownLabel!.translatesAutoresizingMaskIntoConstraints = false
        breakCountdownLabel!.font = NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .bold)
        breakCountdownLabel!.textColor = .white
        breakCountdownLabel!.alignment = .center

        let secsLabel = NSTextField(labelWithString: "seconds to rest")
        secsLabel.translatesAutoresizingMaskIntoConstraints = false
        secsLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        secsLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        secsLabel.alignment = .center

        breakProgress = NSProgressIndicator()
        breakProgress!.translatesAutoresizingMaskIntoConstraints = false
        breakProgress!.style = .bar
        breakProgress!.isIndeterminate = false
        breakProgress!.minValue = 0
        breakProgress!.maxValue = Double(breakDurationSeconds)
        breakProgress!.doubleValue = Double(breakSecondsLeft)
        breakProgress!.controlSize = .large

        let skipButton = NSButton(title: "Skip Break", target: self, action: #selector(endBreak))
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.bezelStyle = .rounded
        skipButton.controlSize = .regular
        skipButton.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        skipButton.contentTintColor = .white

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(headline)
        stack.addArrangedSubview(message)
        stack.addArrangedSubview(breakCountdownLabel!)
        stack.addArrangedSubview(secsLabel)
        stack.addArrangedSubview(breakProgress!)
        stack.addArrangedSubview(skipButton)
        stack.setCustomSpacing(24, after: message)
        stack.setCustomSpacing(4, after: breakCountdownLabel!)

        content.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 128),
            iconView.heightAnchor.constraint(equalToConstant: 128),
            breakProgress!.widthAnchor.constraint(equalToConstant: 320),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -40),
        ])

        breakWindow = win
        win.orderFrontRegardless()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Fade in for a soft, beautiful transition.
        win.alphaValue = 0.0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            win.animator().alphaValue = 1.0
        }

        breakTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(breakTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        breakTimer = t
    }

    @objc func breakTick() {
        breakSecondsLeft -= 1
        if breakSecondsLeft < 0 { breakSecondsLeft = 0 }
        breakCountdownLabel?.stringValue = "\(breakSecondsLeft)"
        breakProgress?.doubleValue = Double(breakSecondsLeft)
        if breakSecondsLeft <= 0 {
            endBreak()
        }
    }

    @objc func endBreak() {
        breakTimer?.invalidate()
        breakTimer = nil
        print("[GazeBreak] Break over — restoring Settings.")
        if let win = breakWindow {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                win.animator().alphaValue = 0.0
            }, completionHandler: {
                win.orderOut(nil)
            })
        }
        breakWindow = nil
        breakCountdownLabel = nil
        breakProgress = nil

        // Restore normal app visibility and bring Settings back.
        _ = NSApp.setActivationPolicy(.regular)
        settingsWindow.alphaValue = 1.0
        statusLabel.stringValue = "Nice work! Ready for another session?"
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeBreakWindow() {
        breakTimer?.invalidate()
        breakTimer = nil
        breakWindow?.orderOut(nil)
        breakWindow = nil
    }
}

// MARK: - Keep Settings close behavior friendly
extension AppDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        if win == settingsWindow {
            // If a focus/break session is active, don't quit — just hide.
            // Otherwise a red-X close quits the app.
            if focusTimer != nil || breakWindow != nil {
                return
            }
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
