package oss.krtirtho.spotube

import android.os.Handler
import android.os.Looper
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDL.UpdateChannel
import com.yausername.youtubedl_android.YoutubeDLException
import com.yausername.youtubedl_android.YoutubeDLRequest
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity: AudioServiceActivity() {
  private val executor = Executors.newSingleThreadExecutor()
  private val mainHandler = Handler(Looper.getMainLooper())
  private var youtubeDlInitialized = false

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      "oss.krtirtho.spotube/yt_dlp"
    ).setMethodCallHandler { call, result ->
      when (call.method) {
        "isAvailable" -> executor.execute {
          try {
            ensureYoutubeDlInitialized()
            mainHandler.post { result.success(true) }
          } catch (error: YoutubeDLException) {
            mainHandler.post { result.success(false) }
          }
        }
        "extractInfo" -> executor.execute {
          try {
            ensureYoutubeDlInitialized()
            val url = call.argument<String>("url") ?: ""
            val extraArgs =
              call.argument<List<String>>("extraArgs") ?: emptyList()
            val request = YoutubeDLRequest(url)
            request.addOption("--dump-json")
            request.addOption("--skip-download")
            extraArgs.forEach { request.addOption(it) }
            val response = YoutubeDL.getInstance().execute(request)
            mainHandler.post { result.success(response.out) }
          } catch (error: Throwable) {
            mainHandler.post {
              result.error("yt_dlp_error", error.message, null)
            }
          }
        }
        "update" -> executor.execute {
          try {
            ensureYoutubeDlInitialized()
            YoutubeDL.getInstance().updateYoutubeDL(
              applicationContext,
              UpdateChannel.STABLE
            )
            mainHandler.post { result.success(true) }
          } catch (error: Throwable) {
            mainHandler.post {
              result.error("yt_dlp_update_error", error.message, null)
            }
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  @Synchronized
  private fun ensureYoutubeDlInitialized() {
    if (youtubeDlInitialized) return
    YoutubeDL.getInstance().init(applicationContext)
    youtubeDlInitialized = true
  }
}
