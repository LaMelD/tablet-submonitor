package dev.submonitor

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** HEVC 저지연 디코더. 출력은 쌓지 않고 받는 즉시 Surface에 표시한다. 스트림 하나(Config 한 번)당 하나씩 만든다. */
class VideoDecoder(private val surface: Surface, private val width: Int, private val height: Int) {
    private val thread = HandlerThread("submonitor-decoder").apply { start() }
    private val freeInputs = ArrayBlockingQueue<Int>(64)
    private val queuedAt = ConcurrentHashMap<Long, Long>() // ptsUs -> 투입 시각(ns)
    private var codec: MediaCodec? = null

    // 통계(디코더 스레드에서만 갱신)
    private var statFrames = 0
    private var statDecodeNs = 0L
    private var statStartNs = 0L

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
                freeInputs.offer(index)
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
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                Log.i(TAG, "output format: $format")
            }
        }, Handler(thread.looper))
        c.configure(format, surface, null, 0)
        c.start()
        codec = c
    }

    fun decode(frame: FlvEvent.Frame) {
        val c = codec ?: return
        val index = freeInputs.poll(1, TimeUnit.SECONDS) ?: run {
            Log.w(TAG, "입력 버퍼가 없어 프레임을 버림")
            return
        }
        val ptsUs = frame.ptsMs * 1000
        try {
            c.getInputBuffer(index)!!.apply { clear(); put(frame.data) }
            queuedAt[ptsUs] = System.nanoTime()
            c.queueInputBuffer(index, 0, frame.data.size, ptsUs, if (frame.key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "decode 실패", e)
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

    private fun record(decodeNs: Long) {
        val now = System.nanoTime()
        if (statFrames == 0) statStartNs = now
        statFrames++
        statDecodeNs += decodeNs
        if (statFrames == 120) {
            val fps = 119 * 1e9 / (now - statStartNs)
            Log.i(TAG, "fps=%.1f decodeMs=%.1f".format(fps, statDecodeNs / 120 / 1e6))
            statFrames = 0
            statDecodeNs = 0
        }
    }

    private companion object {
        const val MIME = MediaFormat.MIMETYPE_VIDEO_HEVC
        const val TAG = "submonitor"
    }
}
