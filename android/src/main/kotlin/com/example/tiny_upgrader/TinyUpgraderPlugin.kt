package com.example.tiny_upgrader

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File

/** TinyUpgraderPlugin */
class TinyUpgraderPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null

    // ========== FlutterPlugin 生命周期 ==========

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        // 获取应用上下文
        context = flutterPluginBinding.applicationContext
        // 创建 MethodChannel
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "tiny_upgrader")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    // ========== ActivityAware 生命周期 ==========
    // 获取当前 Activity 实例，这对于启动 Intent 和请求权限至关重要

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    // ========== MethodCallHandler 实现 ==========
    // 处理来自 Dart 的方法调用

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> {
                result.success("Android ${Build.VERSION.RELEASE}")
            }
            "installApk" -> {
                val filePath = call.argument<String>("filePath")
                if (filePath.isNullOrEmpty()) {
                    result.error("INVALID_ARGUMENT", "File path cannot be null or empty.", null)
                    return
                }
                try {
                    result.success(installApk(filePath))
                } catch (e: Exception) {
                    result.error("INSTALL_ERROR", "Failed to install APK: ${e.message}", e.toString())
                }
            }
            "canRequestPackageInstalls" -> {
                result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                        context.packageManager.canRequestPackageInstalls(),
                )
            }
            "openInstallPermissionSettings" -> {
                val currentActivity = activity
                if (currentActivity == null) {
                    result.error("ACTIVITY_UNAVAILABLE", "No activity is available.", null)
                    return
                }
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    result.success(null)
                    return
                }
                try {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${context.packageName}"),
                    )
                    currentActivity.startActivity(intent)
                    result.success(null)
                } catch (e: ActivityNotFoundException) {
                    result.error(
                        "ACTIVITY_UNAVAILABLE",
                        "Install permission settings are unavailable.",
                        e.toString(),
                    )
                }
            }
            "getAvailableStorageBytes" -> {
                val directoryPath = call.argument<String>("directoryPath")
                if (directoryPath.isNullOrEmpty()) {
                    result.error("INVALID_ARGUMENT", "Directory path is required.", null)
                    return
                }
                try {
                    result.success(StatFs(directoryPath).availableBytes)
                } catch (e: IllegalArgumentException) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "Cannot inspect storage for the supplied path.",
                        e.toString(),
                    )
                }
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    /**
     * 执行安装 APK 的核心逻辑
     * @param filePath APK 文件的路径
     */
    private fun installApk(filePath: String): String {
        val currentActivity = activity
        if (currentActivity == null) {
            return "activityUnavailable"
        }

        val apkFile = File(filePath)
        if (!apkFile.isFile) {
            return "fileNotFound"
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val hasInstallPermission = context.packageManager.canRequestPackageInstalls()
            if (!hasInstallPermission) {
                return "permissionRequired"
            }
        }

        val apkUri = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                val authority = "${context.packageName}.tiny_upgrader.fileprovider"
                FileProvider.getUriForFile(context, authority, apkFile)
            } else {
                Uri.fromFile(apkFile)
            }
        } catch (e: IllegalArgumentException) {
            return "providerError"
        } catch (e: SecurityException) {
            return "providerError"
        }

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        return try {
            currentActivity.startActivity(intent)
            "installerLaunched"
        } catch (e: ActivityNotFoundException) {
            "activityUnavailable"
        } catch (e: SecurityException) {
            "failed"
        }
    }
}
