import Foundation
import AVFoundation
import SwiftProtobuf

final class TeslaSEIParser {

    /// Parse SEI from one or more MP4s from the same camera stream (typically front).
    /// Uses video sample presentation timestamps for accurate timeline alignment.
    static func parseSEI(
        from mp4URLs: [URL],
        frameRate: Double = 30.0
    ) async -> [(seconds: Double, metadata: SeiMetadata)] {
        let sortedURLs = mp4URLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        guard !sortedURLs.isEmpty else {
            return []
        }

        var timeline: [(seconds: Double, metadata: SeiMetadata)] = []
        var cursor: Double = 0

        for url in sortedURLs {
            print("🔍 Parsing SEI from: \(url.lastPathComponent) @ \(frameRate) fps")

            let parsed = await parseSEIFrames(from: url, startTime: cursor, frameRate: frameRate)
            timeline.append(contentsOf: parsed)

            if let duration = await durationSeconds(for: url), duration > 0 {
                cursor += duration
            } else if let lastSecond = parsed.last?.seconds {
                cursor = lastSecond + (1.0 / frameRate)
            }
        }

        print("✅ Parsed \(timeline.count) SEI frames")
        return timeline.sorted(by: { $0.seconds < $1.seconds })
    }
    
    /// Convenience for single file (recommended)
    static func parseSEI(from mp4URL: URL, frameRate: Double = 30.0) async -> [(seconds: Double, metadata: SeiMetadata)] {
        await parseSEI(from: [mp4URL], frameRate: frameRate)
    }

    private static func parseSEIFrames(
        from mp4URL: URL,
        startTime: Double,
        frameRate: Double
    ) async -> [(seconds: Double, metadata: SeiMetadata)] {
        var result: [(Double, SeiMetadata)] = []

        do {
            let asset = AVURLAsset(url: mp4URL)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = tracks.first else {
                print("⚠️ No video track found in \(mp4URL.lastPathComponent)")
                return []
            }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                print("⚠️ Cannot read video samples from \(mp4URL.lastPathComponent)")
                return []
            }
            reader.add(output)
            guard reader.startReading() else {
                print("⚠️ Failed to start reading \(mp4URL.lastPathComponent)")
                return []
            }

            var frameIndex = 0
            var baseFrameSeqNo: UInt64?

            while let sampleBuffer = output.copyNextSampleBuffer() {
                defer { frameIndex += 1 }

                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                let sampleTime: Double? = pts.isFinite ? (startTime + max(pts, 0)) : nil

                guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
                      let sampleData = data(from: dataBuffer) else {
                    continue
                }

                for nal in iterNALUnits(from: sampleData) {
                    guard (nal.first ?? 0) & 0x1F == 6 else { continue }
                    guard let payload = extractProtoPayload(from: nal) else { continue }
                    guard let meta = try? SeiMetadata(serializedBytes: payload) else { continue }

                    let seconds: Double
                    if let sampleTime {
                        seconds = sampleTime
                    } else {
                        let seq = meta.frameSeqNo
                        if seq > 0 {
                            if baseFrameSeqNo == nil { baseFrameSeqNo = seq }
                            let normalizedSeq = seq &- (baseFrameSeqNo ?? seq)
                            seconds = startTime + (Double(normalizedSeq) / frameRate)
                        } else {
                            seconds = startTime + (Double(frameIndex) / frameRate)
                        }
                    }

                    if seconds.isFinite {
                        result.append((seconds, meta))
                    }
                }
            }

            if reader.status == .failed, let error = reader.error {
                print("⚠️ AVAssetReader failed for \(mp4URL.lastPathComponent): \(error.localizedDescription)")
            }
        } catch {
            print("❌ SEI parse error for \(mp4URL.lastPathComponent): \(error)")
        }

        return result
    }

    private static func data(from blockBuffer: CMBlockBuffer) -> Data? {
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    private static func iterNALUnits(from sampleData: Data) -> [Data] {
        if let units = parseLengthPrefixedNALs(sampleData) {
            return units
        }
        return parseAnnexBNALs(sampleData)
    }

    private static func parseLengthPrefixedNALs(_ data: Data) -> [Data]? {
        for lengthBytes in [4, 2, 1] {
            var units: [Data] = []
            var offset = 0
            var valid = false

            while offset + lengthBytes <= data.count {
                var nalLength = 0
                for i in 0..<lengthBytes {
                    nalLength = (nalLength << 8) | Int(data[offset + i])
                }
                offset += lengthBytes

                if nalLength <= 0 || offset + nalLength > data.count {
                    valid = false
                    break
                }

                units.append(data[offset..<(offset + nalLength)])
                offset += nalLength
                valid = true
            }

            if valid && offset == data.count && !units.isEmpty {
                return units
            }
        }
        return nil
    }

    private static func parseAnnexBNALs(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [] }

        var startCodes: [Int] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    startCodes.append(i)
                    i += 3
                    continue
                }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    startCodes.append(i)
                    i += 4
                    continue
                }
            }
            i += 1
        }

        guard !startCodes.isEmpty else { return [] }

        var nals: [Data] = []
        for idx in 0..<startCodes.count {
            let start = startCodes[idx]
            let next = (idx + 1 < startCodes.count) ? startCodes[idx + 1] : bytes.count
            let prefixLength = (start + 2 < bytes.count && bytes[start + 2] == 1) ? 3 : 4
            let nalStart = start + prefixLength
            if nalStart < next {
                nals.append(Data(bytes[nalStart..<next]))
            }
        }

        return nals
    }

    private static func extractProtoPayload(from nal: Data) -> Data? {
        guard nal.count > 3 else { return nil }
        let bytes = [UInt8](nal)

        var i = 3
        while i < bytes.count - 1 {
            if bytes[i] == 0x42 {
                i += 1
                continue
            }
            if bytes[i] == 0x69 {
                let payloadStart = i + 1
                guard payloadStart < bytes.count else { break }
                let rawBytes = Array(bytes[payloadStart..<bytes.count - 1])
                return stripEmulationPrevention(Data(rawBytes))
            }
            break
        }
        return nil
    }

    private static func stripEmulationPrevention(_ data: Data) -> Data {
        var stripped = Data()
        var zeroCount = 0
        for byte in data {
            if zeroCount >= 2 && byte == 0x03 {
                zeroCount = 0
                continue
            }
            stripped.append(byte)
            zeroCount = (byte == 0) ? zeroCount + 1 : 0
        }
        return stripped
    }

    private static func durationSeconds(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? seconds : nil
        } catch {
            return nil
        }
    }
}
