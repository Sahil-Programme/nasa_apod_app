package com.iamsahilyadav.stellarlens

import android.app.WallpaperManager
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.view.WindowMetrics
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val wallpaperChannel = "nasa_apod_app/wallpaper_android"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wallpaperChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getWallpaperTargetSize" -> {
                        try {
                            val target = getWallpaperTargetSize()
                            result.success(
                                mapOf(
                                    "widthPx" to target.first,
                                    "heightPx" to target.second,
                                )
                            )
                        } catch (e: Exception) {
                            result.error("TARGET_SIZE_ERROR", e.message, null)
                        }
                    }

                    "setWallpaperFromSelection" -> {
                        try {
                            val args = call.arguments as? Map<*, *>
                            if (args == null) {
                                result.error("BAD_ARGS", "Arguments are required.", null)
                                return@setMethodCallHandler
                            }
                            val ok = setWallpaperFromSelection(args)
                            result.success(ok)
                        } catch (e: Exception) {
                            result.error("SET_WALLPAPER_ERROR", e.message, null)
                        }
                    }

                    "setWallpaperFromPreparedFile" -> {
                        try {
                            val args = call.arguments as? Map<*, *>
                            if (args == null) {
                                result.error("BAD_ARGS", "Arguments are required.", null)
                                return@setMethodCallHandler
                            }
                            val ok = setWallpaperFromPreparedFile(args)
                            result.success(ok)
                        } catch (e: Exception) {
                            result.error("SET_WALLPAPER_ERROR", e.message, null)
                        }
                    }

                    "openSystemWallpaperPicker" -> {
                        try {
                            val args = call.arguments as? Map<*, *>
                            if (args == null) {
                                result.error("BAD_ARGS", "Arguments are required.", null)
                                return@setMethodCallHandler
                            }
                            val ok = openSystemWallpaperPicker(args)
                            result.success(ok)
                        } catch (e: Exception) {
                            result.error("WALLPAPER_PICKER_ERROR", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun getWallpaperTargetSize(): Pair<Int, Int> {
        val display = getDisplaySize()
        var targetW = display.first
        var targetH = display.second

        if (targetW <= 0 || targetH <= 0) {
            val manager = WallpaperManager.getInstance(applicationContext)
            if (targetW <= 0) targetW = manager.desiredMinimumWidth
            if (targetH <= 0) targetH = manager.desiredMinimumHeight
        }

        targetW = max(1, targetW)
        targetH = max(1, targetH)

        // Android framing in this app is always portrait-oriented.
        return if (targetH >= targetW) {
            Pair(targetW, targetH)
        } else {
            Pair(targetH, targetW)
        }
    }

    private fun getDisplaySize(): Pair<Int, Int> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val metrics: WindowMetrics = windowManager.currentWindowMetrics
            val bounds = metrics.bounds
            return Pair(max(1, bounds.width()), max(1, bounds.height()))
        }

        val dm = resources.displayMetrics
        return Pair(max(1, dm.widthPixels), max(1, dm.heightPixels))
    }

    private fun asInt(value: Any?): Int? {
        return when (value) {
            is Int -> value
            is Long -> value.toInt()
            is Double -> value.roundToInt()
            is Float -> value.roundToInt()
            else -> null
        }
    }

    private fun asDouble(value: Any?): Double? {
        return when (value) {
            is Double -> value
            is Float -> value.toDouble()
            is Int -> value.toDouble()
            is Long -> value.toDouble()
            else -> null
        }
    }

    private fun setWallpaperFromPreparedFile(args: Map<*, *>): Boolean {
        val path = args["path"] as? String ?: return false
        val preparedBitmap = BitmapFactory.decodeFile(path) ?: return false
        val width = preparedBitmap.width
        val height = preparedBitmap.height
        if (width <= 1 || height <= 1) {
            preparedBitmap.recycle()
            return false
        }

        val manager = WallpaperManager.getInstance(applicationContext)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            manager.setBitmap(
                preparedBitmap,
                Rect(0, 0, width, height),
                true,
                WallpaperManager.FLAG_SYSTEM,
            )
        } else {
            manager.setBitmap(preparedBitmap)
        }
        preparedBitmap.recycle()
        return true
    }

    private fun setWallpaperFromSelection(args: Map<*, *>): Boolean {
        val sourcePath = args["sourcePath"] as? String ?: return false
        val normalizedLeft = asDouble(args["normalizedLeft"]) ?: return false
        val normalizedTop = asDouble(args["normalizedTop"]) ?: return false
        val normalizedWidth = asDouble(args["normalizedWidth"]) ?: return false
        val normalizedHeight = asDouble(args["normalizedHeight"]) ?: return false

        val desiredWidthPx = asInt(args["desiredWidthPx"])
        val desiredHeightPx = asInt(args["desiredHeightPx"])

        val sourceBitmap = BitmapFactory.decodeFile(sourcePath) ?: return false
        val sourceW = sourceBitmap.width
        val sourceH = sourceBitmap.height
        if (sourceW <= 1 || sourceH <= 1) {
            sourceBitmap.recycle()
            return false
        }

        val left = (normalizedLeft * sourceW).roundToInt()
        val top = (normalizedTop * sourceH).roundToInt()
        val width = (normalizedWidth * sourceW).roundToInt()
        val height = (normalizedHeight * sourceH).roundToInt()

        val safeWidth = max(1, min(sourceW, width))
        val safeHeight = max(1, min(sourceH, height))
        val safeLeft = max(0, min(sourceW - safeWidth, left))
        val safeTop = max(0, min(sourceH - safeHeight, top))

        val cropHint = Rect(
            safeLeft,
            safeTop,
            safeLeft + safeWidth,
            safeTop + safeHeight,
        )

        val manager = WallpaperManager.getInstance(applicationContext)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val target = getWallpaperTargetSize()
            val finalDesiredW = max(1, desiredWidthPx ?: target.first)
            val finalDesiredH = max(1, desiredHeightPx ?: target.second)

            if (sourceW < finalDesiredW || sourceH < finalDesiredH) {
                val scale = max(
                    finalDesiredW.toDouble() / sourceW.toDouble(),
                    finalDesiredH.toDouble() / sourceH.toDouble(),
                )
                val upscaledW = max(sourceW, (sourceW * scale).roundToInt())
                val upscaledH = max(sourceH, (sourceH * scale).roundToInt())
                val upscaled = android.graphics.Bitmap.createScaledBitmap(
                    sourceBitmap,
                    upscaledW,
                    upscaledH,
                    true,
                )

                val upscaledCrop = Rect(
                    (safeLeft * scale).roundToInt().coerceIn(0, upscaledW - 1),
                    (safeTop * scale).roundToInt().coerceIn(0, upscaledH - 1),
                    ((safeLeft + safeWidth) * scale).roundToInt().coerceIn(1, upscaledW),
                    ((safeTop + safeHeight) * scale).roundToInt().coerceIn(1, upscaledH),
                )

                val fixedCrop = Rect(
                    min(upscaledCrop.left, upscaledCrop.right - 1),
                    min(upscaledCrop.top, upscaledCrop.bottom - 1),
                    max(upscaledCrop.left + 1, upscaledCrop.right),
                    max(upscaledCrop.top + 1, upscaledCrop.bottom),
                )

                manager.setBitmap(
                    upscaled,
                    fixedCrop,
                    true,
                    WallpaperManager.FLAG_SYSTEM,
                )
                if (upscaled !== sourceBitmap) {
                    upscaled.recycle()
                }
            } else {
                manager.setBitmap(
                    sourceBitmap,
                    cropHint,
                    true,
                    WallpaperManager.FLAG_SYSTEM,
                )
            }
        } else {
            manager.setBitmap(sourceBitmap)
        }

        sourceBitmap.recycle()
        return true
    }

    private fun openSystemWallpaperPicker(args: Map<*, *>): Boolean {
        val path = args["path"] as? String ?: return false
        val file = File(path)
        if (!file.exists() || !file.isFile) return false

        val contentUri: Uri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            file,
        )

        val intent = try {
            WallpaperManager.getInstance(applicationContext)
                .getCropAndSetWallpaperIntent(contentUri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: IllegalArgumentException) {
            Intent(Intent.ACTION_ATTACH_DATA).apply {
                setDataAndType(contentUri, "image/*")
                putExtra("mimeType", "image/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }

        val resolver = packageManager
        if (intent.resolveActivity(resolver) == null) return false
        startActivity(Intent.createChooser(intent, "Set wallpaper"))
        return true
    }
}
