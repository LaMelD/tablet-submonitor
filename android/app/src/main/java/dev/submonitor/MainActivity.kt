package dev.submonitor

import android.app.Activity
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Bundle
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var root: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var cursorOverlay: CursorOverlay
    private var session: Session? = null

    /**
     * Surface 한 번의 수명. 스레드는 자기 세션의 플래그만 본다.
     * 공용 플래그를 쓰면 join이 시간 초과된 옛 스레드가 다음 세션에서 되살아나 연결을 가로챘다.
     */
    private class Session {
        val active = AtomicBoolean(true)
        @Volatile var video: LocalSocket? = null
        @Volatile var cursor: LocalSocket? = null
        val threads = mutableListOf<Thread>()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        root = FrameLayout(this)
        surfaceView = SurfaceView(this)
        cursorOverlay = CursorOverlay(this)
        val match = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        root.addView(surfaceView, match)
        root.addView(cursorOverlay, FrameLayout.LayoutParams(match))
        setContentView(root)
        surfaceView.holder.addCallback(this)
        hideSystemBars()
        preferHighestRefreshRate()
    }

    private fun hideSystemBars() {
        window.setDecorFitsSystemWindows(false)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }
        window.insetsController?.apply {
            hide(WindowInsets.Type.systemBars())
            systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    /** 삼성 적응형 주사율이 60Hz로 내려가지 않게 같은 해상도에서 가장 높은 주사율 모드를 요청한다. */
    private fun preferHighestRefreshRate() {
        val d = display ?: return
        val current = d.mode
        val best = d.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        window.attributes = window.attributes.apply { preferredDisplayModeId = best.modeId }
        Log.i(TAG, "preferred mode: ${best.physicalWidth}x${best.physicalHeight}@${best.refreshRate}")
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        holder.surface.setFrameRate(120f, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
        val s = Session().also { session = it }
        s.threads += Thread({ videoLoop(s, holder.surface) }, "submonitor-video").apply { start() }
        s.threads += Thread({ cursorLoop(s) }, "submonitor-cursor").apply { start() }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        val s = session ?: return
        session = null
        s.active.set(false)
        s.video?.closeNow()
        s.cursor?.closeNow()
        s.threads.forEach { it.join(1000) }
    }

    /** 연결 → 스트림 디코딩 → 끊기면 500ms 뒤 다시 연결. 화면이 사라지면(백그라운드 등) 끝난다. */
    private fun videoLoop(s: Session, surface: Surface) {
        while (s.active.get()) {
            var decoder: VideoDecoder? = null
            try {
                connectAdb(VIDEO_SOCKET).use { sock ->
                    s.video = sock
                    val reader = FlvReader(BufferedInputStream(sock.inputStream, 1 shl 16))
                    while (s.active.get()) {
                        when (val e = reader.next() ?: break) {
                            is FlvEvent.Config -> {
                                decoder?.release()
                                decoder = VideoDecoder(surface, VIDEO_WIDTH, VIDEO_HEIGHT).also { it.configure(e.csd) }
                            }
                            is FlvEvent.Frame -> decoder?.decode(e)
                        }
                    }
                }
            } catch (e: IOException) {
                Log.d(TAG, "video connection: ${e.message}")
            } catch (e: RuntimeException) {
                Log.w(TAG, "video stream error", e) // 앱을 죽이지 않고 다시 접속한다
            } finally {
                decoder?.release()
            }
            if (s.active.get()) Thread.sleep(500)
        }
    }

    /** 커서 채널. 영상과 같은 수명·재접속 방식. 끊기면 커서를 숨긴다. */
    private fun cursorLoop(s: Session) {
        while (s.active.get()) {
            try {
                connectAdb(CURSOR_SOCKET).use { sock ->
                    s.cursor = sock
                    val input = DataInputStream(BufferedInputStream(sock.inputStream))
                    while (s.active.get()) cursorOverlay.update(readCursorMsg(input) ?: break)
                }
            } catch (e: IOException) {
                Log.d(TAG, "cursor connection: ${e.message}")
            } catch (e: RuntimeException) {
                Log.w(TAG, "cursor stream error", e)
            }
            cursorOverlay.hide()
            if (s.active.get()) Thread.sleep(500)
        }
    }

    /**
     * adb reverse가 만든 추상 네임스페이스 소켓에 접속한다. 상대가 adbd(shell uid)가 아니면 거부한다.
     * 탭의 다른 앱이 같은 이름을 먼저 차지해 조작된 데이터를 보내는 것을 막는다.
     */
    private fun connectAdb(name: String): LocalSocket {
        val s = LocalSocket()
        try {
            s.connect(LocalSocketAddress(name, LocalSocketAddress.Namespace.ABSTRACT))
            val uid = s.peerCredentials.uid
            if (uid != ADBD_UID) throw IOException("adbd가 아닌 상대(uid=$uid)라 연결을 거부함")
            return s
        } catch (e: IOException) {
            s.close()
            throw e
        }
    }

    /** 다른 스레드에서 막혀 있는 read를 깨우고 닫는다. */
    private fun LocalSocket.closeNow() {
        try { shutdownInput() } catch (_: IOException) {}
        try { close() } catch (_: IOException) {}
    }

    private companion object {
        const val TAG = "submonitor"
        const val ADBD_UID = 2000 // shell
        const val VIDEO_SOCKET = "submonitor-video"
        const val CURSOR_SOCKET = "submonitor-cursor"
        const val VIDEO_WIDTH = 2960
        const val VIDEO_HEIGHT = 1848
    }
}
