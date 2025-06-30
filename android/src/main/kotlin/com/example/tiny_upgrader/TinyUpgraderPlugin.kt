package com.example.tiny_upgrader

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
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
                    installApk(filePath)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("INSTALL_ERROR", "Failed to install APK: ${e.message}", e.toString())
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
    private fun installApk(filePath: String) {
        val currentActivity = activity
        if (currentActivity == null) {
            // 如果没有可用的 Activity，无法启动安装意图
            throw IllegalStateException("No activity available to start installation intent.")
        }

        val apkFile = File(filePath)
        if (!apkFile.exists()) {
            throw java.io.FileNotFoundException("APK file not found at path: $filePath")
        }

        // 针对 Android 8.0 (API 26) 及以上版本，需要检查“安装未知应用”权限
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val hasInstallPermission = context.packageManager.canRequestPackageInstalls()
            if (!hasInstallPermission) {
                // 如果没有权限，引导用户到设置页面开启
                // 注意：这里只是启动设置，用户授权后需要重新触发安装
                val intent = Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                intent.data = Uri.parse("package:${context.packageName}")
                currentActivity.startActivity(intent)
                // 抛出异常或返回特定代码，让 Dart 端知道需要用户授权
                throw SecurityException("Missing permission to install unknown apps.")
            }
        }

        // 使用 FileProvider 来获取安全的文件 URI，这是 Android 7.0+ 的标准做法
        val apkUri: Uri
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val authority = "${context.packageName}.fileprovider"
            apkUri = FileProvider.getUriForFile(context, authority, apkFile)
        } else {
            // 对于旧版本，可以直接从文件创建 Uri
            apkUri = Uri.fromFile(apkFile)
        }

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, "application/vnd.android.package-archive")
            // 添加此标志以授予接收 Intent 的应用（包安装程序）临时读取 URI 的权限
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            // 如果在非 Activity 上下文中启动，需要此标志
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        currentActivity.startActivity(intent)
    }
}