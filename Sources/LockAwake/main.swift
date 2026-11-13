// Lock Awake — keeps the display on while the screen is locked AND the Mac
// is on power, so the lock-screen aerial keeps playing.
//
// loginwindow turns the display off ~30s after locking (password-prompt
// timeout) unless a PreventUserIdleDisplaySleep assertion is held. This agent
// holds one only in that state, and releases it on unlock or on battery.
//
// It also restarts the aerial player a few seconds after a display is added
// or removed (lid closed, monitor plugged or unplugged). macOS's player can
// get stuck in its ramp-down state across such a change, and then the lock
// screen shows a frozen frame until the player restarts.

import AppKit
import IOKit.ps
import IOKit.pwr_mgt

func log(_ s: String) {
    FileHandle.standardError.write("\(Date()) \(s)\n".data(using: .utf8)!)
}

final class LockAwake {
    private var locked = false
    private var onAC = false
    private var assertion: IOPMAssertionID = 0
    private var holding = false
    private var pendingRestart: DispatchWorkItem?

    func start() {
        locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        onAC = Self.isOnAC()

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true; self?.update("locked")
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false; self?.update("unlocked")
        }

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<LockAwake>.fromOpaque(ctx).takeUnretainedValue()
            let ac = LockAwake.isOnAC()
            if ac != me.onAC { me.onAC = ac; me.update(ac ? "on power" : "on battery") }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard let ctx, flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
            let me = Unmanaged<LockAwake>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.restartAerialSoon() }
        }, ctx)
        update("start")
    }

    /// One restart per burst of display changes, once things have settled.
    private func restartAerialSoon() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["WallpaperAerialsExtension"]
            do { try p.run(); p.waitUntilExit(); log("display change: aerial player restarted (exit \(p.terminationStatus))") }
            catch { log("display change: could not restart aerial player: \(error)") }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    static func isOnAC() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return true }   // desktop Macs without a battery report nothing useful
        return type == kIOPMACPowerKey
    }

    private func update(_ why: String) {
        let want = locked && onAC
        if want && !holding {
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Lock screen aerial (on power)" as CFString, &assertion)
            holding = (r == kIOReturnSuccess)
            log("\(why): display kept on (\(holding ? "ok" : "failed \(r)"))")
        } else if !want && holding {
            IOPMAssertionRelease(assertion)
            holding = false
            log("\(why): display may sleep again")
        } else {
            log("\(why): locked=\(locked) onAC=\(onAC), no change")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let agent = LockAwake()
agent.start()
app.run()
