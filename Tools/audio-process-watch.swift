// Read-only diagnostic: watch Core Audio process objects and print a line
// whenever a process starts or stops producing output / consuming input.
//
// Why this exists: CATapDescription targets processes by bundle ID, but both
// Chrome and Zoom route audio through helper processes that register under
// their own bundle IDs (com.google.Chrome.helper, us.zoom.caphost). This tool
// reveals which bundle ID actually carries the audio, which decides what goes
// into the tap description.
//
// Usage:
//   swift Tools/audio-process-watch.swift [seconds]
//
// Play audio while it runs. Lines appear the moment a process starts or stops.

import CoreAudio
import Foundation

let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 60
let interval: TimeInterval = 0.25
let system = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func processObjectIDs() -> [AudioObjectID] {
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func bundleID(of object: AudioObjectID) -> String? {
    var addr = address(kAudioProcessPropertyBundleID)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value as String
}

func processIdentifier(of object: AudioObjectID) -> pid_t? {
    var addr = address(kAudioProcessPropertyPID)
    var size = UInt32(MemoryLayout<pid_t>.size)
    var value: pid_t = 0
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func flag(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> Bool {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return false }
    return value != 0
}

func label(for object: AudioObjectID) -> String {
    let bundle = bundleID(of: object) ?? "(no bundle id)"
    let pid = processIdentifier(of: object).map(String.init) ?? "?"
    return "\(bundle)  [pid \(pid)]"
}

let formatter = DateFormatter()
formatter.dateFormat = "HH:mm:ss"

func log(_ message: String) {
    print("\(formatter.string(from: Date()))  \(message)")
    fflush(stdout)
}

var activeOutput: Set<AudioObjectID> = []
var activeInput: Set<AudioObjectID> = []
var everOutput: Set<String> = []
var everInput: Set<String> = []

log("watching for \(Int(seconds))s — play audio now (Chrome, Zoom, anything)")
log("waiting…")

let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    var currentOutput: Set<AudioObjectID> = []
    var currentInput: Set<AudioObjectID> = []

    for object in processObjectIDs() {
        if flag(kAudioProcessPropertyIsRunningOutput, of: object) { currentOutput.insert(object) }
        if flag(kAudioProcessPropertyIsRunningInput, of: object) { currentInput.insert(object) }
    }

    for object in currentOutput.subtracting(activeOutput) {
        log("OUTPUT  start   \(label(for: object))")
        if let bundle = bundleID(of: object) { everOutput.insert(bundle) }
    }
    for object in activeOutput.subtracting(currentOutput) {
        log("OUTPUT  stop    \(label(for: object))")
    }
    for object in currentInput.subtracting(activeInput) {
        log("INPUT   start   \(label(for: object))")
        if let bundle = bundleID(of: object) { everInput.insert(bundle) }
    }
    for object in activeInput.subtracting(currentInput) {
        log("INPUT   stop    \(label(for: object))")
    }

    activeOutput = currentOutput
    activeInput = currentInput
    Thread.sleep(forTimeInterval: interval)
}

print("\n=== bundle IDs that produced OUTPUT ===")
print(everOutput.isEmpty ? "(none)" : everOutput.sorted().joined(separator: "\n"))
print("\n=== bundle IDs that consumed INPUT ===")
print(everInput.isEmpty ? "(none)" : everInput.sorted().joined(separator: "\n"))
