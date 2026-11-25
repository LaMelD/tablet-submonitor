package dev.submonitor

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.DataInputStream
import java.io.IOException

class CursorProtocolTest {
    // host/Tests/SubmonitorCoreTests/CursorMessageTests.swift와 같은 바이트다. 두 언어 사이의 계약.
    private val displayBytes = bytes(0x01, 0, 0, 0, 8, 0x44, 0xB9, 0, 0, 0x44, 0x67, 0, 0)
    private val positionBytes = bytes(0x02, 0, 0, 0, 9, 0x3F, 0xC0, 0, 0, 0x40, 0x00, 0, 0, 0x01)
    private val shapeBytes = bytes(0x03, 0, 0, 0, 0x12, 0x40, 0x80, 0, 0, 0x40, 0x80, 0, 0, 0x41, 0x80, 0, 0, 0x41, 0x80, 0, 0, 0xAA, 0xBB)

    @Test fun decodesGoldenBytes() {
        val input = DataInputStream((displayBytes + positionBytes + shapeBytes).inputStream())
        assertEquals(CursorMsg.Display(1480f, 924f), readCursorMsg(input))
        assertEquals(CursorMsg.Position(1.5f, 2f, true), readCursorMsg(input))
        val s = readCursorMsg(input) as CursorMsg.Shape
        assertEquals(listOf(4f, 4f, 16f, 16f), listOf(s.hotX, s.hotY, s.width, s.height))
        assertArrayEquals(bytes(0xAA, 0xBB), s.png)
        assertNull(readCursorMsg(input))
    }

    @Test fun skipsUnknownType() {
        val input = DataInputStream((bytes(0x09, 0, 0, 0, 2, 0x11, 0x22) + positionBytes).inputStream())
        assertEquals(CursorMsg.Position(1.5f, 2f, true), readCursorMsg(input))
    }

    // 보안: 잘못된 길이는 크래시·메모리 폭주가 아니라 IOException
    @Test(expected = IOException::class) fun rejectsShapeShorterThanHeader() {
        readCursorMsg(DataInputStream(bytes(0x03, 0, 0, 0, 4, 0, 0, 0, 0).inputStream()))
    }

    @Test(expected = IOException::class) fun rejectsHugeLength() {
        readCursorMsg(DataInputStream(bytes(0x03, 0x7F, 0xFF, 0xFF, 0xFF).inputStream()))
    }

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }
}
