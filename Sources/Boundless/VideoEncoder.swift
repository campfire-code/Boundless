import BoundlessCore
import CoreMedia
import QuartzCore
import VideoToolbox

/// 被控端：把采集到的虚拟屏画面硬件编码成 HEVC（不支持时退回 H.264），低延迟、不重排帧
final class VideoEncoder {
    /// 编码完成的一帧（解码参数、帧、从采集到编码完成的耗时秒数）；关键帧带解码参数。在 VideoToolbox 的线程回调
    var onOutput: ((Message?, Message, Double) -> Void)?

    let width: Int
    let height: Int
    private let window: UInt32
    private var session: VTCompressionSession?
    private(set) var codec: VideoCodec = .hevc
    private var forceKeyframe = true

    init?(window: UInt32, width: Int, height: Int, wired: Bool) {
        self.window = window
        self.width = width
        self.height = height
        for codec in [VideoCodec.hevc, .h264] {
            if let s = VideoEncoder.makeSession(codec: codec, width: width, height: height, wired: wired) {
                session = s
                self.codec = codec
                break
            }
        }
        guard let session else { return nil }
        NSLog("Boundless 被控端：编码器 \(codec == .hevc ? "HEVC" : "H.264") \(width)×\(height) 码率 \(StreamGeometry.bitrate(width: width, height: height, wired: wired) / 1_000_000) Mbps")
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    func requestKeyframe() {
        forceKeyframe = true
    }

    func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let session else { return }
        let props: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: time,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample else { return }
            self.emit(sample)
        }
    }

    private func emit(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return }
        let data = Data(bytes: pointer, count: length)

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var format: Message?
        if keyframe, let desc = CMSampleBufferGetFormatDescription(sample) {
            format = parameterSets(desc)
        }
        // 采集时间戳用的是主机时钟，换算成 Unix 时间，主控端拿它算端到端延迟
        let age = CACurrentMediaTime() - CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let captureTime = Date().timeIntervalSince1970 - age
        onOutput?(format, .videoFrame(window: window, keyframe: keyframe, captureTime: captureTime, data: data), age)
    }

    private func parameterSets(_ desc: CMFormatDescription) -> Message? {
        var count = 0
        var nalLength: Int32 = 4
        let getter = codec == .hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex : CMVideoFormatDescriptionGetH264ParameterSetAtIndex
        guard getter(desc, 0, nil, nil, &count, &nalLength) == noErr else { return nil }
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard getter(desc, i, &ptr, &size, nil, nil) == noErr, let ptr else { return nil }
            sets.append(Data(bytes: ptr, count: size))
        }
        return .videoFormat(window: window, codec: codec, nalLengthSize: UInt8(nalLength), parameterSets: sets)
    }

    private static func makeSession(codec: VideoCodec, width: Int, height: Int, wired: Bool) -> VTCompressionSession? {
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        // 低延迟码率控制不可用时去掉再试，硬件编码必须有
        let specs: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
             kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true],
            [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true],
        ]
        for spec in specs {
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
                                                    encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                                    compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                    compressionSessionOut: &session)
            guard status == noErr, let session else { continue }
            NSLog("Boundless 被控端：编码器\(spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] != nil ? "启用" : "未启用")低延迟码率控制")
            let bitrate = StreamGeometry.bitrate(width: width, height: height, wired: wired)
            let props: [CFString: Any] = [
                kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_ExpectedFrameRate: 60,
                kVTCompressionPropertyKey_AverageBitRate: bitrate,
                // 关键帧只在开始、尺寸变化和解码出错时按需插入
                kVTCompressionPropertyKey_MaxKeyFrameInterval: 3600,
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 60,
            ]
            for (key, value) in props {
                VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            }
            // 瞬时码率上限：1 秒内最多 1.5 倍平均码率，避免整屏刷新时一帧太大堵住网络
            let limits = [bitrate * 3 / 2 / 8, 1] as CFArray
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
            return session
        }
        return nil
    }
}
