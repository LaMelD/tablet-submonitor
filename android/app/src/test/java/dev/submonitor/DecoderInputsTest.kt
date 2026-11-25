package dev.submonitor

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.IOException

// 리뷰 Important: 코덱이 오류에 빠지거나 입력 버퍼가 안 나오면 프레임을 조용히 버리며 화면이 영원히 멈췄다.
// 이제 IOException으로 연결을 끊어 디코더를 새로 만들고 키프레임부터 다시 받는다.
class DecoderInputsTest {
    @Test fun takeReturnsOfferedIndex() {
        val inputs = DecoderInputs(timeoutMs = 50)
        inputs.offer(3)
        assertEquals(3, inputs.take())
    }

    @Test(expected = IOException::class) fun takeThrowsAfterCodecError() {
        val inputs = DecoderInputs(timeoutMs = 50)
        inputs.offer(1)
        inputs.fail("codec error")
        inputs.take()
    }

    @Test(expected = IOException::class) fun takeThrowsWhenNoBufferInTime() {
        DecoderInputs(timeoutMs = 50).take()
    }
}
