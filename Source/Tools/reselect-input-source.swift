// Switches the current input source away and back, if it is from the given
// bundle, so that the frontmost app connects to a newly installed build.
//
// Usage: swift reselect-input-source.swift <bundle ID>

import Carbon

func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
    guard let value = TISGetInputSourceProperty(source, key) else {
        return nil
    }
    return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue() as? T
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: reselect-input-source.swift <bundle ID>\n".data(using: .utf8)!)
    exit(2)
}
let bundleID = CommandLine.arguments[1]
let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
guard property(current, kTISPropertyBundleID) as String? == bundleID else {
    exit(0)
}

// Any other enabled keyboard layout, e.g. ABC.
let filter = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout] as CFDictionary
let layouts = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
guard let other = layouts.first(where: { property($0, kTISPropertyInputSourceIsSelectCapable) == true }) else {
    FileHandle.standardError.write("no other keyboard layout to switch to\n".data(using: .utf8)!)
    exit(1)
}
TISSelectInputSource(other)
Thread.sleep(forTimeInterval: 0.3)
TISSelectInputSource(current)
