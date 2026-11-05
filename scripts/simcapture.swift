// Records a simulator's screen straight from its framebuffer, at the device's own pixel
// size and without compression (ProRes 422 HQ), until SIGINT. A frame's time is taken the
// moment it arrives and encoding happens apart, so a busy encoder never bunches frames. No window is involved: the
// frames come from CoreSimulator's private IO client, the same place Device Hub and
// `simctl io recordVideo` take them from, so the Mac's screen stays free.
//
// Usage: simcapture <out.mov> <udid> [screen width in points]
//        simcapture --snapshot <out.png> <udid>
//
// Writes <out>.json beside the movie: the wall clock time of the first frame, the
// recording's pixels per screen point and the frame count.
import AVFoundation
import CoreMedia
import Foundation
import IOSurface
import ObjectiveC

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: simcapture <out.mov> <udid> [points] | --snapshot <out.png> <udid>\n".utf8))
    exit(2)
}
let snapshot = arguments[1] == "--snapshot"
let output = URL(fileURLWithPath: arguments[snapshot ? 2 : 1])
let udid = arguments[snapshot ? 3 : 2].uppercased()
let screenPoints = arguments.count > 3 && !snapshot ? Double(arguments[3]) ?? 0 : 0

guard dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) != nil else {
    FileHandle.standardError.write(Data("CoreSimulator.framework not found\n".utf8))
    exit(1)
}

// CoreSimulator ----------------------------------------------------------------------

typealias ObjectWithError = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> AnyObject?
typealias WithError = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?
typealias SizeGetter = @convention(c) (AnyObject, Selector) -> CGSize
typealias IntGetter = @convention(c) (AnyObject, Selector) -> Int32
typealias Register = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject) -> Void

func implementation(_ target: AnyObject, _ name: String) -> IMP {
    class_getMethodImplementation(object_getClass(target), NSSelectorFromString(name))!
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func screenOfDevice() -> (screen: AnyObject, size: CGSize) {
    let contextClass: AnyObject = NSClassFromString("SimServiceContext")!
    var error: NSError?
    let developerDir = "/Applications/Xcode.app/Contents/Developer" as NSString
    let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
    guard let context = unsafeBitCast(implementation(contextClass, "sharedServiceContextForDeveloperDir:error:"), to: ObjectWithError.self)(contextClass, contextSelector, developerDir, &error) else {
        fail("No CoreSimulator service: \(error?.localizedDescription ?? "")")
    }
    let setSelector = NSSelectorFromString("defaultDeviceSetWithError:")
    guard let set = unsafeBitCast(implementation(context, "defaultDeviceSetWithError:"), to: WithError.self)(context, setSelector, &error) else {
        fail("No device set: \(error?.localizedDescription ?? "")")
    }
    let devices = set.perform(NSSelectorFromString("devicesByUDID")).takeUnretainedValue() as! [AnyHashable: AnyObject]
    guard let device = devices.first(where: { "\($0.key)".uppercased() == udid })?.value else { fail("No simulator \(udid)") }
    let io = device.perform(NSSelectorFromString("io")).takeUnretainedValue()
    let ports = io.perform(NSSelectorFromString("ioPorts")).takeUnretainedValue() as! [AnyObject]
    let registerSelector = NSSelectorFromString("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
    for port in ports {
        guard let descriptor = port.perform(NSSelectorFromString("descriptor"))?.takeUnretainedValue(), descriptor.responds(to: registerSelector) else { continue }
        let properties = descriptor.perform(NSSelectorFromString("screenProperties")).takeUnretainedValue()
        let power = unsafeBitCast(implementation(properties, "powerState"), to: IntGetter.self)(properties, NSSelectorFromString("powerState"))
        guard power != 0 else { continue }
        let size = unsafeBitCast(implementation(properties, "pixelSize"), to: SizeGetter.self)(properties, NSSelectorFromString("pixelSize"))
        return (descriptor, size)
    }
    fail("No powered screen on \(udid); is it booted?")
}

// Recording --------------------------------------------------------------------------

final class Recorder: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pool: CVPixelBufferPool
    /// Encoding runs here, apart from the screen's callbacks, so a slow frame never delays
    /// the moment the next one is taken: each frame keeps the time it arrived.
    private let encoding = DispatchQueue(label: "simcapture.encoding", qos: .userInitiated)
    /// Frames copied out and not yet written; past this many a frame is dropped rather
    /// than letting memory run away.
    private let backlog = DispatchSemaphore(value: 90)
    private(set) var firstFrameWallTime: Double?
    private(set) var frames = 0
    private(set) var dropped = 0
    private var started = false
    private var lastSeed: UInt32?

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary, &created)
        pool = created!
    }

    /// Takes the frame now: notes the time and copies the pixels out, since the simulator
    /// draws the next frame into the same surface. The screen calls back more often than
    /// it changes; a surface whose seed hasn't moved is the frame already taken.
    func capture(_ surface: IOSurface) {
        let seed = surface.seed
        guard seed != lastSeed else { return }
        lastSeed = seed
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        if firstFrameWallTime == nil {
            firstFrameWallTime = Date().timeIntervalSince1970
        }
        guard backlog.wait(timeout: .now()) == .success else {
            dropped += 1
            return
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else {
            backlog.signal()
            dropped += 1
            return
        }
        surface.lock(options: .readOnly, seed: nil)
        CVPixelBufferLockBaseAddress(buffer, [])
        let source = surface.baseAddress
        let destination = CVPixelBufferGetBaseAddress(buffer)!
        let sourceRow = surface.bytesPerRow
        let destinationRow = CVPixelBufferGetBytesPerRow(buffer)
        if sourceRow == destinationRow {
            memcpy(destination, source, sourceRow * surface.height)
        } else {
            let rowBytes = min(sourceRow, destinationRow)
            for row in 0..<surface.height {
                memcpy(destination + row * destinationRow, source + row * sourceRow, rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        surface.unlock(options: .readOnly, seed: nil)
        encoding.async { [self] in
            defer { backlog.signal() }
            if !started {
                writer.startSession(atSourceTime: time)
                started = true
            }
            // The writer catches up on its own time; the frame's time is already fixed.
            var waited = 0
            while !input.isReadyForMoreMediaData, waited < 500 {
                usleep(1000)
                waited += 1
            }
            if adaptor.append(buffer, withPresentationTime: time) {
                frames += 1
            } else {
                dropped += 1
            }
        }
    }

    func finish() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            encoding.async { done.resume() }
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

func savePNG(_ surface: IOSurface, to url: URL) {
    surface.lock(options: .readOnly, seed: nil)
    defer { surface.unlock(options: .readOnly, seed: nil) }
    let context = CGContext(data: surface.baseAddress, width: surface.width, height: surface.height, bitsPerComponent: 8,
                            bytesPerRow: surface.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let (screen, size) = screenOfDevice()
let width = Int(size.width), height = Int(size.height)
let queue = DispatchQueue(label: "simcapture", qos: .userInteractive)
let recorder = snapshot ? nil : try Recorder(url: output, width: width, height: height)
nonisolated(unsafe) var surface: IOSurface?
nonisolated(unsafe) var frameCount = 0

let frameCallback: @convention(block) () -> Void = {
    guard let surface else { return }
    frameCount += 1
    if snapshot {
        savePNG(surface, to: output)
        print("\(width)x\(height)")
        exit(0)
    }
    recorder?.capture(surface)
}
// The screen's buffers: the first is the one the simulator shows.
let surfacesCallback: @convention(block) (IOSurface?, IOSurface?) -> Void = { front, _ in
    surface = front
}
let propertiesCallback: @convention(block) (AnyObject?) -> Void = { _ in }
let token = NSUUID()
let registerSelector = NSSelectorFromString("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
unsafeBitCast(implementation(screen, "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"), to: Register.self)(
    screen, registerSelector, token, queue, frameCallback as AnyObject, surfacesCallback as AnyObject, propertiesCallback as AnyObject)

if !snapshot {
    print("recording \(width)x\(height)\(screenPoints > 0 ? String(format: ", %.3f px per point", Double(width) / screenPoints) : "")")
}

signal(SIGINT, SIG_IGN)
let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
stop.setEventHandler {
    let unregister = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
    _ = screen.perform(unregister, with: token)
    Task {
        guard let recorder else { exit(0) }
        await recorder.finish()
        var info: [String: Any] = [
            "first_frame": recorder.firstFrameWallTime ?? 0,
            "frames": recorder.frames,
            "dropped": recorder.dropped,
            "width": width,
            "height": height,
        ]
        if screenPoints > 0 { info["scale"] = Double(width) / screenPoints }
        let data = try JSONSerialization.data(withJSONObject: info)
        try data.write(to: output.deletingPathExtension().appendingPathExtension("json"))
        print("wrote \(recorder.frames) frames, dropped \(recorder.dropped)")
        exit(0)
    }
}
stop.resume()
dispatchMain()
