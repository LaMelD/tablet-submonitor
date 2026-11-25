package dev.submonitor

import java.io.IOException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * MediaCodec 입력 버퍼 번호를 콜백 스레드에서 받아 디코딩 스레드로 넘긴다.
 * 코덱 오류나 시간 초과는 IOException으로 알려 연결을 끊게 한다(조용히 프레임을 버리면 화면이 멈춘 채 남는다).
 */
class DecoderInputs(private val timeoutMs: Long = 1000) {
    private val free = ArrayBlockingQueue<Int>(64)
    @Volatile private var failure: String? = null

    fun offer(index: Int) {
        free.offer(index)
    }

    fun fail(reason: String) {
        failure = reason
    }

    @Throws(IOException::class)
    fun take(): Int {
        failure?.let { throw IOException("디코더 오류: $it") }
        val index = free.poll(timeoutMs, TimeUnit.MILLISECONDS)
            ?: throw IOException("디코더 입력 버퍼가 ${timeoutMs}ms 안에 나오지 않음")
        failure?.let { throw IOException("디코더 오류: $it") }
        return index
    }
}
