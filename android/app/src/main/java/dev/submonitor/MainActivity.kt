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
import java.io.IOException

class MainActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var root: FrameLayout
    private lateinit var surfaceView: SurfaceView
    @Volatile private var running = false
    @Volatile private var videoSocket: LocalSocket? = null
    private var videoThread: Thread? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        root = FrameLayout(this)
        surfaceView = SurfaceView(this)
        root.addView(surfaceView, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
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
        running = true
        videoThread = Thread({ videoLoop(holder.surface) }, "submonitor-video").apply { start() }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        running = false
        videoSocket?.closeNow()
        videoThread?.join(1000)
        videoThread = null
    }

    /** 연결 → 스트림 디코딩 → 끊기면 500ms 뒤 다시 연결. 화면이 사라지면(백그라운드 등) 끝난다. */
    private fun videoLoop(surface: Surface) {
        while (running) {
            var decoder: VideoDecoder? = null
            try {
                connectAdb(VIDEO_SOCKET).use { s ->
                    videoSocket = s
                    val reader = FlvReader(BufferedInputStream(s.getInputStream(), 1 shl 16))
                    while (running) {
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
            if (running) Thread.sleep(500)
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
        const val VIDEO_WIDTH = 2960
        const val VIDEO_HEIGHT = 1848
    }
}
