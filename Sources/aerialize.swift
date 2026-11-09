// aerialize — re-encode any video into the format macOS aerial wallpapers use,
// so it can stand in for an Apple aerial on the desktop and lock screen.
//
// The aerial player speeds the video up and slows it down (lock/unlock) by
// dropping HEVC temporal layers. Videos without temporal-layer info make it
// fail ("VideoSampleReadingErrors Code=4" = noTemporalInfo) and go black.
// So: HEVC Main10, 240 fps (each source frame repeated), hierarchical
// temporal layers with a 15 fps base layer, video only, looped to minSeconds.
//
// Usage: aerialize <in> <out.mov> [minSeconds=300]

import AVFoundation
import VideoToolbox

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("aerialize: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: aerialize <in> <out.mov> [minSeconds]") }
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let minSeconds = args.count > 3 ? Double(args[3]) ?? 300 : 300

let outFPS: Int32 = 240
let baseLayerFPS = 15

/// Appends encoded samples (decode order) to a passthrough writer input.
final class Sink {
    var writer: AVAssetWriter?
    var input: AVAssetWriterInput?
    let outURL: URL
    var error: String?
    init(outURL: URL) { self.outURL = outURL }

    func append(_ sb: CMSampleBuffer) {
        if writer == nil {
            do {
                let w = try AVAssetWriter(outputURL: outURL, fileType: .mov)
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                           sourceFormatHint: CMSampleBufferGetFormatDescription(sb))
                i.expectsMediaDataInRealTime = false
                w.add(i)
                guard w.startWriting() else { error = "writer: \(String(describing: w.error))"; return }
                w.startSession(atSourceTime: .zero)
                writer = w; input = i
            } catch { self.error = "writer: \(error)"; return }
        }
        guard let input else { return }
        while !input.isReadyForMoreMediaData { usleep(1000) }
        if !input.append(sb) { error = "append failed: \(String(describing: writer?.error))" }
    }
}

let sink = Sink(outURL: output)
try? FileManager.default.removeItem(at: output)

// Source facts
let asset = AVURLAsset(url: input)
let sem = DispatchSemaphore(value: 0)
var srcTrack: AVAssetTrack!
var srcSize = CGSize.zero
var srcDuration = 0.0
Task {
    guard let t = try? await asset.loadTracks(withMediaType: .video).first else { fail("no video track") }
    srcTrack = t
    srcSize = try await t.load(.naturalSize)
    srcDuration = CMTimeGetSeconds(try await t.load(.timeRange).duration)
    sem.signal()
}
sem.wait()
guard srcDuration > 0 else { fail("empty video") }
let copies = max(1, Int((minSeconds / srcDuration).rounded(.up)))

// Encoder
var session: VTCompressionSession?
let status = VTCompressionSessionCreate(
    allocator: nil, width: Int32(srcSize.width), height: Int32(srcSize.height),
    codecType: kCMVideoCodecType_HEVC,
    encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
    imageBufferAttributes: nil, compressedDataAllocator: nil,
    outputCallback: nil, refcon: nil, compressionSessionOut: &session)
guard status == noErr, let session else { fail("cannot create HEVC encoder (\(status))") }

func set(_ key: CFString, _ value: CFTypeRef) {
    let s = VTSessionSetProperty(session, key: key, value: value)
    if s != noErr { FileHandle.standardError.write("aerialize: warning: \(key) not set (\(s))\n".data(using: .utf8)!) }
}
set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
set(kVTCompressionPropertyKey_ExpectedFrameRate, outFPS as CFNumber)
set(kVTCompressionPropertyKey_BaseLayerFrameRate, baseLayerFPS as CFNumber)
set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue)
set(kVTCompressionPropertyKey_AverageBitRate, 14_000_000 as CFNumber)
// Short keyframe spacing: on lock the player seeks to where it left off and
// must decode from the previous keyframe first. At 240 fps a 10 s gap meant
// up to 2,400 frames (~1 s of preroll); 1 s keeps that to ~240 frames.
set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1 as CFNumber)
set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
VTCompressionSessionPrepareToEncodeFrames(session)

// Encode: every decoded source frame is submitted repeat× at 240 fps.
var outIndex: Int64 = 0
let frameDur = CMTime(value: 1, timescale: outFPS)
for copy in 0..<copies {
    guard let reader = try? AVAssetReader(asset: asset) else { fail("cannot read input") }
    let out = AVAssetReaderTrackOutput(track: srcTrack, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    out.alwaysCopiesSampleData = false
    reader.add(out)
    reader.startReading()

    // Source timing decides how many 240 fps slots each frame covers.
    var pending: (CVPixelBuffer, Double)?
    func emit(_ pb: CVPixelBuffer, until end: Double) {
        let target = Int64((end + Double(copy) * srcDuration) * Double(outFPS) + 0.5)
        while outIndex < target {
            let pts = CMTime(value: outIndex, timescale: outFPS)
            let s = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts,
                                                    duration: frameDur, frameProperties: nil,
                                                    infoFlagsOut: nil) { st, _, sb in
                if st == noErr, let sb { sink.append(sb) } else if st != noErr { sink.error = "encode \(st)" }
            }
            if s != noErr { fail("encode failed (\(s))") }
            outIndex += 1
        }
    }
    while let sb = out.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        if let (prev, _) = pending { emit(prev, until: t) }
        pending = (pb, t)
    }
    if let (prev, _) = pending { emit(prev, until: srcDuration) }
    if reader.status == .failed { fail("read failed: \(String(describing: reader.error))") }
    if let e = sink.error { fail(e) }
    FileHandle.standardError.write("aerialize: copy \(copy + 1)/\(copies) done\n".data(using: .utf8)!)
}
VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
VTCompressionSessionInvalidate(session)
if let e = sink.error { fail(e) }

guard let writer = sink.writer, let winput = sink.input else { fail("nothing encoded") }
winput.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: outIndex, timescale: outFPS))
writer.finishWriting { sem.signal() }
sem.wait()
guard writer.status == .completed else { fail("finish failed: \(String(describing: writer.error))") }
print(String(format: "wrote %@: %d × %.1fs = %.1fs, %d frames at %d fps, HEVC temporal layers",
             output.lastPathComponent, copies, srcDuration, Double(outIndex) / Double(outFPS),
             outIndex, outFPS))
