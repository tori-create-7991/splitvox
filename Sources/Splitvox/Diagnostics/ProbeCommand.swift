import CoreAudio
import Foundation

/// `Splitvox --probe-tap` — create a tap against the configured meeting
/// applications, report what it resolved, and destroy it.
///
/// Exists because every interesting failure in the capture path is invisible
/// from unit tests: whether a bundle ID matches a live process, what format the
/// tap negotiates, and whether taps leak when a session ends.
enum ProbeCommand {

    static func run(bundleIDs: [String]) {
        print("configured bundle IDs:")
        for id in bundleIDs { print("  \(id)") }

        let matched = AudioProcessLookup.processObjectIDs(forBundleIDs: bundleIDs)
        print("\nmatching process objects: \(matched.count)")
        for object in matched {
            let bundle = AudioProcessLookup.bundleID(of: object) ?? "(unknown)"
            let active = AudioProcessLookup.isProducingOutput(object) ? "  <- producing output" : ""
            print("  [\(object)] \(bundle)\(active)")
        }

        let producing = AudioProcessLookup.bundleIDsProducingOutput()
        print("\nbundle IDs producing output right now: \(producing.isEmpty ? "(none)" : "")")
        for id in Set(producing).sorted() {
            let covered = bundleIDs.contains(id) ? "captured" : "NOT captured"
            print("  \(id)  — \(covered)")
        }

        let tapsBefore = ProcessTap.systemTapIDs().count

        do {
            let tap = try ProcessTap(bundleIDs: bundleIDs)
            print("\ntap created")
            print("  objectID: \(tap.tapID)")
            print("  uid:      \(tap.uid)")

            if let format = tap.streamDescription {
                print("  format:   \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, "
                      + "\(format.mBitsPerChannel) bit")
            } else {
                print("  format:   (unavailable)")
            }

            print("  system taps: \(tapsBefore) -> \(ProcessTap.systemTapIDs().count)")

            let destroyStatus = tap.invalidate()
            print("  destroy status: \(destroyStatus)"
                  + (destroyStatus == noErr ? " (noErr)" : " (FAILED)"))
            print("  immediately after destroy: \(ProcessTap.systemTapIDs().count)")

            // The tap list is maintained by coreaudiod, so a destroy may not be
            // reflected in the very next property read from this process.
            Thread.sleep(forTimeInterval: 0.3)
            let tapsAfter = ProcessTap.systemTapIDs().count
            print("  after 300ms:               \(tapsAfter)")

            print(tapsAfter == tapsBefore
                  ? "\nOK — no tap leaked."
                  : "\nWARNING — tap count did not return to \(tapsBefore).")
        } catch {
            print("\ntap creation FAILED: \(error.localizedDescription)")
        }
    }
}
