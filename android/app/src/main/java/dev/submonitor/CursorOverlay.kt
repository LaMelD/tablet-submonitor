package dev.submonitor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.View

/** 영상 위에 커서를 직접 그린다. update()는 아무 스레드에서나 불러도 된다. */
class CursorOverlay(context: Context) : View(context) {
    private class Shape(val bitmap: Bitmap, val hotX: Float, val hotY: Float, val width: Float, val height: Float)

    @Volatile private var displayWidth = 0f
    @Volatile private var position = CursorMsg.Position(0f, 0f, false)
    @Volatile private var shape: Shape? = null
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val dst = RectF()

    fun update(msg: CursorMsg) {
        when (msg) {
            is CursorMsg.Display -> displayWidth = msg.width
            is CursorMsg.Position -> position = msg
            is CursorMsg.Shape -> BitmapFactory.decodeByteArray(msg.png, 0, msg.png.size)?.let {
                shape = Shape(it, msg.hotX, msg.hotY, msg.width, msg.height)
            }
        }
        postInvalidateOnAnimation()
    }

    fun hide() = update(CursorMsg.Position(0f, 0f, false))

    override fun onDraw(canvas: Canvas) {
        val p = position
        val s = shape ?: return
        if (!p.visible || displayWidth <= 0f) return
        val scale = width / displayWidth
        val left = (p.x - s.hotX) * scale
        val top = (p.y - s.hotY) * scale
        dst.set(left, top, left + s.width * scale, top + s.height * scale)
        canvas.drawBitmap(s.bitmap, null, dst, paint)
    }
}
