package dev.submonitor

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// sample.flv 생성 명령 (FFmpeg 9, 이 맥북의 hevc_videotoolbox):
// ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=640x400:rate=30 -frames:v 3 -c:v hevc_videotoolbox -bf 0 -f flv android/app/src/test/resources/sample.flv
class FlvReaderTest {
    private val START = byteArrayOf(0, 0, 0, 1)

    @Test fun parsesConfigThenThreeFramesFromFfmpegOutput() {
        val events = generateSequence(FlvReader(javaClass.getResourceAsStream("/sample.flv")!!)::next).toList()
        val config = events[0] as FlvEvent.Config
        assertArrayEquals(START + byteArrayOf(0x40, 0x01), config.csd.copyOf(6)) // VPS 먼저
        assertTrue(config.csd.indexOf(START + byteArrayOf(0x42, 0x01)) > 0)       // SPS 포함
        assertTrue(config.csd.indexOf(START + byteArrayOf(0x44, 0x01)) > 0)       // PPS 포함
        val frames = events.drop(1).map { it as FlvEvent.Frame }
        assertEquals(listOf(true, false, false), frames.map { it.key })
        assertEquals(listOf(0L, 33L, 67L), frames.map { it.ptsMs })
        frames.forEach { assertArrayEquals(START, it.data.copyOf(4)) }
    }

    @Test fun convertsLengthPrefixedNalsToAnnexB() {
        val frame = readFrames(flv(sequenceStart(lengthSize = 4), codedFramesX(nal(0x26, 0x01), nal(0x02, 0x01, 0xAA)))).single()
        assertArrayEquals(START + bytes(0x26, 0x01) + START + bytes(0x02, 0x01, 0xAA), frame.data)
    }

    @Test fun skipsCompositionTimeForCodedFrames() {
        val frame = readFrames(flv(sequenceStart(lengthSize = 4), codedFrames(cts = 0x000102, nal(0x26, 0x01)))).single()
        assertArrayEquals(START + bytes(0x26, 0x01), frame.data)
    }

    // --- 테스트용 FLV 조립 헬퍼 (Enhanced FLV: 첫 바이트 = 확장헤더 비트 | frameType<<4 | packetType, 이어서 fourcc) ---

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }
    private fun nal(vararg v: Int) = bytes(*v)
    private fun u32(v: Int) = bytes(v ushr 24 and 0xFF, v ushr 16 and 0xFF, v ushr 8 and 0xFF, v and 0xFF)
    private fun u24(v: Int) = bytes(v ushr 16 and 0xFF, v ushr 8 and 0xFF, v and 0xFF)
    private val hvc1 = "hvc1".toByteArray()

    /** hvcC: 고정 헤더 22바이트([21] 하위 2비트 = 길이 필드 크기-1) + 배열 0개 */
    private fun sequenceStart(lengthSize: Int): ByteArray {
        val hvcc = ByteArray(23).also { it[0] = 1; it[21] = (0xFC or (lengthSize - 1)).toByte(); it[22] = 0 }
        return bytes(0x90) + hvc1 + hvcc
    }

    private fun lengthPrefixed(nals: Array<out ByteArray>) = nals.fold(ByteArray(0)) { acc, n -> acc + u32(n.size) + n }
    private fun codedFramesX(vararg nals: ByteArray) = bytes(0x93) + hvc1 + lengthPrefixed(nals)
    private fun codedFrames(cts: Int, vararg nals: ByteArray) = bytes(0x91) + hvc1 + u24(cts) + lengthPrefixed(nals)

    private fun flv(vararg videoBodies: ByteArray): ByteArray {
        var out = bytes('F'.code, 'L'.code, 'V'.code, 1, 1) + u32(9) + u32(0)
        for (body in videoBodies) {
            out += bytes(9) + u24(body.size) + u24(0) + bytes(0) + u24(0) + body + u32(11 + body.size)
        }
        return out
    }

    private fun readFrames(data: ByteArray) =
        generateSequence(FlvReader(data.inputStream())::next).filterIsInstance<FlvEvent.Frame>().toList()

    private fun ByteArray.indexOf(sub: ByteArray): Int =
        (0..size - sub.size).firstOrNull { i -> sub.indices.all { this[i + it] == sub[it] } } ?: -1
}
