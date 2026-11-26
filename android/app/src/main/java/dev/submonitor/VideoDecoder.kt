package dev.submonitor

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap

/** HEVC 저지연 디코더. 출력은 쌓지 않고 받는 즉시 Surface에 표시한다. 스트림 하나(Config 한 번)당 하나씩 만든다. */
class VideoDecoder(private val surface: Surface, private val width: Int, private val height: Int) {
    private val thread = HandlerThread("submonitor-decoder").apply { start() }
    private val inputs = DecoderInputs()
    private val queuedAt = ConcurrentHashMap<Long, Long>() // ptsUs -> 투입 시각(ns)
    private var codec: MediaCodec? = null

    /**
     * 1초마다 한 줄로 남기는 통계. 버벅임이 어디서 생기는지 가른다.
     * ptsGap = 맥에서 캡처한 시각 간격(캡처 쪽 끊김), arrivalGap = 탭에 도착한 간격(인코딩·전송 포함),
     * late = 이 스트림에서 가장 빨리 온 프레임보다 늦게 온 정도(캡처 이후 밀린 시간),
     * decode = 투입→출력 지연(탭 디코더), inputWait = 빈 입력 버퍼를 기다린 시간(디코더 밀림).
     */
    private val stats = Any()
    private var winStartNs = System.nanoTime()
    private var inFrames = 0
    private var outFrames = 0
    private var bytes = 0L
    private var maxSize = 0
    private var lastArrivalNs = 0L
    private var lastPtsMs = -1L
    private var maxArrivalGapNs = 0L
    private var maxPtsGapMs = 0L
    private var decodeNsSum = 0L
    private var maxDecodeNs = 0L
    private var maxInputWaitNs = 0L
    private var minOffsetNs = Long.MAX_VALUE
    private var maxLateNs = 0L
    private var lateNsSum = 0L

    fun configure(csd: ByteArray) {
        val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(csd))
            setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            // S8 Ultra의 c2.qti.hevc.decoder는 표준 FEATURE_LowLatency를 지원하지 않는다. 퀄컴 전용 키(다른 디코더는 무시).
            setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // 실시간
            setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt()) // 디코더 클럭을 최대로
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height) // 키프레임도 들어가게 넉넉히
        }
        val c = MediaCodec.createDecoderByType(MIME)
        val lowLatency = c.codecInfo.getCapabilitiesForType(MIME)
            .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
        Log.i(TAG, "decoder=${c.name} lowLatencySupported=$lowLatency")
        c.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                inputs.offer(index)
            }

            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                try {
                    codec.releaseOutputBuffer(index, true)
                } catch (_: IllegalStateException) {
                    return // release() 이후 늦게 온 콜백
                }
                queuedAt.remove(info.presentationTimeUs)?.let { record(System.nanoTime() - it) }
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "decoder error", e)
                inputs.fail(e.diagnosticInfo ?: e.toString())
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                Log.i(TAG, "output format: $format")
            }
        }, Handler(thread.looper))
        c.configure(format, surface, null, 0)
        c.start()
        codec = c
    }

    /** 디코더가 오류 상태이거나 입력 버퍼가 제때 안 나오면 IOException(연결을 끊고 디코더를 새로 만든다). */
    @Throws(IOException::class)
    fun decode(frame: FlvEvent.Frame) {
        val c = codec ?: return
        val arrived = System.nanoTime()
        val index = inputs.take()
        onInput(frame, arrived, System.nanoTime() - arrived)
        val ptsUs = frame.ptsMs * 1000
        try {
            c.getInputBuffer(index)!!.apply { clear(); put(frame.data) }
            queuedAt[ptsUs] = System.nanoTime()
            c.queueInputBuffer(index, 0, frame.data.size, ptsUs, if (frame.key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
        } catch (e: IllegalStateException) {
            throw IOException("decode 실패", e)
        }
    }

    fun release() {
        codec?.let {
            try { it.stop() } catch (_: IllegalStateException) {}
            it.release()
        }
        codec = null
        thread.quitSafely()
    }

    private fun onInput(frame: FlvEvent.Frame, arrivedNs: Long, waitNs: Long) = synchronized(stats) {
        inFrames++
        bytes += frame.data.size
        maxSize = maxOf(maxSize, frame.data.size)
        if (lastArrivalNs != 0L) maxArrivalGapNs = maxOf(maxArrivalGapNs, arrivedNs - lastArrivalNs)
        if (lastPtsMs >= 0) maxPtsGapMs = maxOf(maxPtsGapMs, frame.ptsMs - lastPtsMs)
        val offset = arrivedNs - frame.ptsMs * 1_000_000
        minOffsetNs = minOf(minOffsetNs, offset)
        maxLateNs = maxOf(maxLateNs, offset - minOffsetNs)
        lateNsSum += offset - minOffsetNs
        lastArrivalNs = arrivedNs
        lastPtsMs = frame.ptsMs
        maxInputWaitNs = maxOf(maxInputWaitNs, waitNs)
    }

    private fun record(decodeNs: Long) = synchronized(stats) {
        outFrames++
        decodeNsSum += decodeNs
        maxDecodeNs = maxOf(maxDecodeNs, decodeNs)
        val now = System.nanoTime()
        val winNs = now - winStartNs
        if (winNs < 1_000_000_000L) return
        Log.i(TAG, "stats win=%dms fps=%.1f in=%d Mbps=%.1f maxKB=%d ptsGapMax=%dms arrivalGapMax=%.1fms lateAvg=%.1fms lateMax=%.1fms decodeAvg=%.1fms decodeMax=%.1fms inputWaitMax=%.1fms".format(
            winNs / 1_000_000, outFrames * 1e9 / winNs, inFrames, bytes * 8e3 / winNs, maxSize / 1024,
            maxPtsGapMs, maxArrivalGapNs / 1e6, lateNsSum / maxOf(inFrames, 1) / 1e6, maxLateNs / 1e6, decodeNsSum / outFrames / 1e6, maxDecodeNs / 1e6, maxInputWaitNs / 1e6))
        winStartNs = now
        inFrames = 0; outFrames = 0; bytes = 0; maxSize = 0
        maxArrivalGapNs = 0; maxPtsGapMs = 0; decodeNsSum = 0; maxDecodeNs = 0; maxInputWaitNs = 0; maxLateNs = 0; lateNsSum = 0
    }

    private companion object {
        const val MIME = MediaFormat.MIMETYPE_VIDEO_HEVC
        const val TAG = "submonitor"
    }
}
