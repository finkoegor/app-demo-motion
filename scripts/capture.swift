// Records a simulator's screen from its window (Device Hub in Xcode 27, Simulator before)
// to ProRes 422 HQ through ScreenCaptureKit, without the heavy compression of
// `simctl io recordVideo`, until SIGINT.
//
// Usage: capture <out.mov> <device name in the window title> <x> <y> <width> <height> <screen width in points>
//        capture --snapshot <out.png> <device name in the window title>
//
// x, y, width and height are the screen's rectangle in the window, in window points;
// find_screen.py works them out from a snapshot. Writes <out>.json beside the movie: the
// wall clock time of the first frame and the recording's pixels per screen point.
// Needs Screen Recording permission for the app that runs it (System Settings, Privacy).
import AVFoundation
import CoreMedia
import AppKit
import Foundation
import ScreenCaptureKit

let arguments = CommandLine.arguments
let windowOwners: Set<String> = ["com.apple.dt.Devices", "com.apple.iphonesimulator"]

// Window capture needs a connection to the window server.
_ = NSApplication.shared

func findWindow(titled name: String) async throws -> SCWindow {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: {
        windowOwners.contains($0.owningApplication?.bundleIdentifier ?? "") && ($0.title ?? "").contains(name)
    }) else {
        FileHandle.standardError.write(Data("No simulator window titled \(name) on screen\n".utf8))
        exit(1)
    }
    return window
}

if arguments.count == 4, arguments[1] == "--snapshot" {
    let window = try await findWindow(titled: arguments[3])
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
    config.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    let image: CGImage = try await withCheckedThrowingContinuation { continuation in
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
            if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile)) }
        }
    }
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[2]))
    print("\(image.width)x\(image.height), \(filter.pointPixelScale) px per window point")
    exit(0)
}

let numbers = arguments.dropFirst(3).compactMap(Double.init)
guard arguments.count == 8, numbers.count == 5 else {
    FileHandle.standardError.write(Data("usage: capture <out.mov> <device name> <x> <y> <width> <height> <screen width in points>\n".utf8))
    exit(2)
}
let screenRect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
let screenPoints = numbers[4]
let output = URL(fileURLWithPath: arguments[1])
let deviceName = arguments[2]

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    private let lock = NSLock()
    private var started = false
    private(set) var firstFrameWallTime: Double?
    private(set) var frames = 0

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, isComplete(buffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        let time = buffer.presentationTimeStamp
        if !started {
            writer.startSession(atSourceTime: time)
            // The frame's host time against the host clock now gives its wall clock time.
            let age = CMClockGetTime(CMClockGetHostTimeClock()).seconds - time.seconds
            firstFrameWallTime = Date().timeIntervalSince1970 - age
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(buffer)
            frames += 1
        }
    }

    /// Frames come only when the window changes; idle and blank ones carry no picture.
    private func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    func finish() async {
        lock.withLock { input.markAsFinished() }
        await writer.finishWriting()
    }
}

let window = try await findWindow(titled: deviceName)
let filter = SCContentFilter(desktopIndependentWindow: window)
let pixelsPerPoint = Double(filter.pointPixelScale)
let width = Int((screenRect.width * pixelsPerPoint).rounded()) & ~1
let height = Int((screenRect.height * pixelsPerPoint).rounded()) & ~1

let configuration = SCStreamConfiguration()
configuration.sourceRect = screenRect
configuration.width = width
configuration.height = height
configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
configuration.pixelFormat = kCVPixelFormatType_32BGRA
configuration.colorSpaceName = CGColorSpace.sRGB
configuration.showsCursor = false
configuration.ignoreShadowsSingleWindow = true
configuration.queueDepth = 8

let recorder = try Recorder(url: output, width: width, height: height)
let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    stream.startCapture { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
print("recording \(width)x\(height), \(Double(width) / screenPoints) px per point")

signal(SIGINT, SIG_IGN)
let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
stop.setEventHandler {
    Task {
        try? await stream.stopCapture()
        await recorder.finish()
        let info: [String: Any] = [
            "first_frame": recorder.firstFrameWallTime ?? 0,
            "scale": Double(width) / screenPoints,
            "frames": recorder.frames,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: info)
            try data.write(to: output.deletingPathExtension().appendingPathExtension("json"))
            print("wrote \(recorder.frames) frames")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Writing the timing failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
stop.resume()

// Runs until SIGINT stops it.
while true {
    try? await Task.sleep(for: .seconds(3600))
}
