package top.huangxuanqi.otacounter

import android.Manifest.permission
import android.content.ContentResolver
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.MediaStore.Images.Media
import androidx.core.content.PermissionChecker
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private var cameraSourcesChannel: MethodChannel? = null
    private var pendingAccessRequest: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val context = applicationContext
        cameraSourcesChannel = MethodChannel(
            messenger,
            "ota_counter/album_camera_sources",
            StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "accessStatus" -> result.success(cameraAccessStatus(context))
                    "requestAccess" -> runOnUiThread { requestCameraAccess(result) }
                    "list" -> listWithFullAccess(context, call.arguments, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun requestCameraAccess(result: MethodChannel.Result) {
        val status = cameraAccessStatus(this)
        if (status == "full") {
            result.success(status)
            return
        }
        if (cameraSourcesChannel == null || pendingAccessRequest != null) {
            result.error("request_unavailable", "Photo permission request unavailable", null)
            return
        }
        pendingAccessRequest = result
        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            arrayOf(permission.READ_MEDIA_IMAGES, permission.READ_MEDIA_VISUAL_USER_SELECTED)
        } else {
            arrayOf(imageReadPermission())
        }
        requestPermissions(permissions, CAMERA_ACCESS_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        if (requestCode == CAMERA_ACCESS_REQUEST_CODE) {
            val result = pendingAccessRequest
            pendingAccessRequest = null
            result?.success(cameraAccessStatus(this))
        } else {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        cameraSourcesChannel?.setMethodCallHandler(null)
        cameraSourcesChannel = null
        pendingAccessRequest?.error("request_unavailable", "Photo permission request interrupted", null)
        pendingAccessRequest = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

private const val CAMERA_ACCESS_REQUEST_CODE = 5813

private fun imageReadPermission() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
    permission.READ_MEDIA_IMAGES
} else {
    permission.READ_EXTERNAL_STORAGE
}

private fun cameraAccessStatus(context: Context): String {
    // A legacy permission prompt can report a temporary READ_MEDIA_IMAGES
    // grant even though its AppOp still disallows full access.
    val images = imageReadPermission()
    val selected = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
        context.checkSelfPermission(permission.READ_MEDIA_VISUAL_USER_SELECTED) ==
        PackageManager.PERMISSION_GRANTED
    val full = context.checkSelfPermission(images) == PackageManager.PERMISSION_GRANTED &&
        (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
            PermissionChecker.checkSelfPermission(context, images) == PermissionChecker.PERMISSION_GRANTED)
    return when {
        full -> "full"
        selected -> "limited"
        else -> "denied"
    }
}

private fun listWithFullAccess(context: Context, arguments: Any?, result: MethodChannel.Result) {
    val args = arguments as? Map<*, *>
    val start = args?.get("start").asEpochMillis()
    val end = args?.get("end").asEpochMillis()
    if (start == null || end == null || start > end) {
        result.error("invalid_range", "Expected start <= end in epoch milliseconds", null)
        return
    }
    val before = cameraAccessStatus(context)
    if (before != "full") {
        result.photoAccessError(before, changedDuringQuery = false)
        return
    }
    val sources = try {
        if (start == end) emptyList() else listCameraSources(context.contentResolver, start, end)
    } catch (_: SecurityException) {
        val after = cameraAccessStatus(context)
        result.photoAccessError(if (after == "full") "denied" else after, changedDuringQuery = true)
        return
    } catch (error: IOException) {
        val after = cameraAccessStatus(context)
        if (after != "full") {
            result.photoAccessError(after, changedDuringQuery = true)
        } else {
            result.error("camera_source_unavailable", error.message, null)
        }
        return
    }
    val after = cameraAccessStatus(context)
    if (after == "full") {
        result.success(sources)
    } else {
        result.photoAccessError(after, changedDuringQuery = true)
    }
}

private fun MethodChannel.Result.photoAccessError(status: String, changedDuringQuery: Boolean) {
    error(
        "camera_access_required",
        if (changedDuringQuery) "Photo access was lost during query" else "Full photo access is required",
        mapOf("status" to status, "changedDuringQuery" to changedDuringQuery),
    )
}

private fun Any?.asEpochMillis(): Long? = when (this) {
    is Int -> toLong()
    is Long -> this
    else -> null
}

// Match direct camera folders on shared volumes, not nested app folders named DCIM.
private val cameraJpegPath = Regex(
    "^/storage/(?:emulated/[0-9]+|[^/]+)/DCIM/(?:Camera|OpenCamera|100ANDRO|100MEDIA)/" +
        "(?!screen[-_ ]?shot)[^/]+\\.jpe?g$",
    RegexOption.IGNORE_CASE,
)

@Suppress("DEPRECATION") // DATA is read-only here; Dart needs the original file path.
private fun listCameraSources(
    resolver: ContentResolver,
    start: Long,
    end: Long,
): List<Map<String, Any>> {
    val columns = arrayOf(Media.DATA, Media.DATE_TAKEN, Media.DATE_MODIFIED, Media.SIZE)
    val selection = "${Media.MIME_TYPE} = ? AND ${Media.DATE_TAKEN} > 0 " +
        "AND ${Media.DATE_TAKEN} >= ? AND ${Media.DATE_TAKEN} < ?"
    val args = arrayOf("image/jpeg", start.toString(), end.toString())
    val cursor = checkNotNull(
        resolver.query(Media.EXTERNAL_CONTENT_URI, columns, selection, args, "${Media.DATE_TAKEN} ASC"),
    ) { "MediaStore did not return a cursor" }
    return cursor.use { rows ->
        buildList {
            while (rows.moveToNext()) {
                val path = rows.getString(0) ?: continue
                if (!cameraJpegPath.matches(path)) continue
                val file = File(path)
                // MediaStore listed a candidate. A failed file check does not
                // distinguish a stale row from temporarily unavailable storage.
                if (!file.isFile || !file.canRead()) {
                    throw IOException("A camera photo is unavailable; retry the query")
                }
                add(
                    mapOf(
                        "path" to path,
                        "taken" to rows.getLong(1),
                        "modified" to rows.getLong(2),
                        "size" to rows.getLong(3),
                    ),
                )
            }
        }
    }
}
