package dev.submonitor

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream

sealed interface FlvEvent {
    /** VPS/SPS/PPS를 Annex-B로 이어 붙인 것 (MediaCodec csd-0) */
    class Config(val csd: ByteArray) : FlvEvent

    /** Annex-B 한 프레임 */
    class Frame(val data: ByteArray, val ptsMs: Long, val key: Boolean) : FlvEvent
}

/**
 * FFmpeg flv 먹서가 내보내는 Enhanced FLV(HEVC, fourcc hvc1) 스트림을 프레임 단위로 읽는다.
 * 태그마다 크기가 붙어 있어 다음 프레임을 기다리지 않고 프레임 경계를 안다.
 */
class FlvReader(input: InputStream) {
    private val input = DataInputStream(input)
    private var headerRead = false
    private var lengthSize = 4

    /** 다음 Config 또는 Frame. 스트림이 끝나면 null. */
    fun next(): FlvEvent? {
        try {
            if (!headerRead) readHeader()
            while (true) {
                val type = input.readUnsignedByte()
                val size = readU24()
                val ts = readU24() or (input.readUnsignedByte() shl 24)
                readU24() // stream id
                val body = ByteArray(size).also { input.readFully(it) }
                input.readInt() // PreviousTagSize
                if (type == 9) parseVideo(body, ts.toLong())?.let { return it }
            }
        } catch (_: EOFException) {
            return null
        }
    }

    private fun readHeader() {
        val sig = ByteArray(3).also { input.readFully(it) }
        if (String(sig, Charsets.US_ASCII) != "FLV") throw IOException("FLV 스트림이 아닙니다")
        input.readUnsignedByte() // version
        input.readUnsignedByte() // flags
        val dataOffset = input.readInt()
        input.skipNBytes((dataOffset - 9).toLong())
        input.readInt() // PreviousTagSize0
        headerRead = true
    }

    private fun parseVideo(body: ByteArray, ptsMs: Long): FlvEvent? {
        if (body.size < 5) return null
        val b = body[0].toInt() and 0xFF
        if (b and 0x80 == 0) return null // 확장 헤더가 아닌 구형 FLV 비디오는 쓰지 않는다
        if (String(body, 1, 4, Charsets.US_ASCII) != "hvc1") return null
        val key = (b shr 4) and 7 == 1
        return when (b and 0x0F) {
            0 -> FlvEvent.Config(parseHvcc(body, 5))
            1 -> FlvEvent.Frame(toAnnexB(body, 8), ptsMs, key) // fourcc 뒤 composition time 3바이트
            3 -> FlvEvent.Frame(toAnnexB(body, 5), ptsMs, key)
            else -> null // 메타데이터 등
        }
    }

    private fun parseHvcc(b: ByteArray, off: Int): ByteArray {
        need(b.size >= off + 23)
        lengthSize = (b[off + 21].toInt() and 3) + 1
        val out = ByteArrayOutputStream()
        var p = off + 23
        repeat(b[off + 22].toInt() and 0xFF) {
            need(p + 3 <= b.size)
            p += 1 // NAL type
            val count = u16(b, p); p += 2
            repeat(count) {
                need(p + 2 <= b.size)
                val len = u16(b, p); p += 2
                need(p + len <= b.size)
                out.write(START); out.write(b, p, len); p += len
            }
        }
        return out.toByteArray()
    }

    private fun toAnnexB(b: ByteArray, off: Int): ByteArray {
        val out = ByteArrayOutputStream(b.size + 16)
        var p = off
        while (p + lengthSize <= b.size) {
            var len = 0
            repeat(lengthSize) { len = (len shl 8) or (b[p++].toInt() and 0xFF) }
            need(len >= 0 && p + len <= b.size)
            out.write(START); out.write(b, p, len); p += len
        }
        return out.toByteArray()
    }

    /** 잘못된 입력은 크래시가 아니라 IOException(연결 끊고 재접속)으로 처리한다. */
    private fun need(ok: Boolean) {
        if (!ok) throw IOException("잘못된 FLV 데이터")
    }

    private fun readU24() = (input.readUnsignedByte() shl 16) or (input.readUnsignedByte() shl 8) or input.readUnsignedByte()
    private fun u16(b: ByteArray, p: Int) = ((b[p].toInt() and 0xFF) shl 8) or (b[p + 1].toInt() and 0xFF)

    private companion object {
        val START = byteArrayOf(0, 0, 0, 1)
    }
}
