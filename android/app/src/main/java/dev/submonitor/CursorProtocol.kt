package dev.submonitor

import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException

/** 호스트 → 탭 커서 채널 메시지 (host/Sources/SubmonitorCore/CursorMessage.swift와 같은 형식). 좌표·크기는 가상 디스플레이 pt 단위. */
sealed interface CursorMsg {
    data class Display(val width: Float, val height: Float) : CursorMsg
    data class Position(val x: Float, val y: Float, val visible: Boolean) : CursorMsg
    class Shape(val hotX: Float, val hotY: Float, val width: Float, val height: Float, val png: ByteArray) : CursorMsg
}

private const val MAX_PAYLOAD = 1 shl 20 // 커서 이미지 PNG는 수십 KB면 충분하다

/** 다음 메시지. 스트림이 끝나면 null. 모르는 type은 건너뛴다. 잘못된 길이는 IOException. */
fun readCursorMsg(input: DataInputStream): CursorMsg? {
    while (true) {
        val type = try { input.readUnsignedByte() } catch (_: EOFException) { return null }
        val len = input.readInt()
        if (len !in 0..MAX_PAYLOAD) throw IOException("잘못된 커서 메시지 길이: $len")
        when (type) {
            1 -> return CursorMsg.Display(input.readFloat(), input.readFloat())
            2 -> return CursorMsg.Position(input.readFloat(), input.readFloat(), input.readUnsignedByte() != 0)
            3 -> {
                if (len < 16) throw IOException("잘못된 커서 모양 길이: $len")
                val hotX = input.readFloat(); val hotY = input.readFloat()
                val width = input.readFloat(); val height = input.readFloat()
                val png = ByteArray(len - 16).also { input.readFully(it) }
                return CursorMsg.Shape(hotX, hotY, width, height, png)
            }
            else -> input.skipNBytes(len.toLong())
        }
    }
}
