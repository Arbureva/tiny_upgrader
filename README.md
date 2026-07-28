# TinyUpgrader

TinyUpgrader 是一个仅支持 Android 的 Flutter 应用内升级插件，提供更新检查、Flutter 自定义更新 UI、原生前台服务下载、断点续传、APK 完整性校验和安装器唤起。

## 特色功能

- 可选更新、推荐更新和不可返回的强制更新页面
- 支持自定义 Flutter 弹窗、页面或完全无 UI 的事件驱动流程
- Android `dataSync` 前台服务下载，App 退到后台后仍可继续
- 安全的 HTTP Range 断点续传、网络退避重试和独立的文件校验重试
- APK 流式 MD5/SHA-256 校验，避免大文件一次性读入内存
- 结构化的更新检查结果、安装结果和全流程事件
- 下载任务持久化，Flutter 引擎重新连接后恢复状态

## 安装

```yaml
dependencies:
  tiny_upgrader: ^1.2.0
```

插件仅支持 Android，最低 Android SDK 为 21。

## 开始使用

在检查更新前初始化一次：

```dart
import 'package:flutter/material.dart';
import 'package:tiny_upgrader/tiny_upgrader.dart';

TinyUpgrader.init(
  isDebug: true,
  baseUrl: 'https://example.cn:8080/',
  errorHandler: (error) {
    debugPrint('出现错误: $error');
  },
  parser: (response) async {
    final res = VersionInfo.fromMap(
      (response as Map<String, dynamic>)['data'] as Map<String, dynamic>,
    );
    res.downloadUrl = '${res.downloadUrl}?token=123123';
    return res;
  },
  autoStartForcedDownload: false,
  maxNetworkRetryCount: 2,
  maxValidationRetryCount: 3,
  minFreeSpaceMarginBytes: 64 * 1024 * 1024,
);
```

调用 `check()`。不传 `onUpdateAvailable` 时，可选/推荐更新使用默认弹窗，强制更新使用默认全屏页面：

```dart
final upgrader = TinyUpgrader.instance;
final result = await upgrader.check(
  context,
  url: 'api/apk-manager-v1/latest',
);

switch (result) {
  case UpdateAvailable(:final info):
    debugPrint('发现 ${info.latestVersion!.version}');
  case NoUpdate():
    debugPrint('当前已是最新版本');
  case UpdateCheckFailed(:final error):
    debugPrint('检查失败: ${error.message}');
  case UpdateUnsupported(:final message):
    debugPrint(message);
}
```

传入 `onUpdateAvailable` 可以关闭默认 UI 并接管展示：

```dart
await upgrader.check(
  context,
  url: 'api/apk-manager-v1/latest',
  onUpdateAvailable: (context, info) {
    // 展示自己的更新页面；需要下载时调用 upgrader.startDownload()。
  },
);
```

版本号按数字段比较，支持 `1.2`、`1.2.0` 与 `v1.2.0`。版本相同时才比较构建号；非法版本会返回 `UpdateCheckFailed`。

### 下载状态

默认更新 UI 已包含开始、暂停、恢复和安装按钮。自定义 UI 可监听：

```dart
ValueListenableBuilder<DownloadStatus>(
  valueListenable: upgrader.statusNotifier,
  builder: (_, status, __) {
    return ValueListenableBuilder<double>(
      valueListenable: upgrader.progressNotifier,
      builder: (_, progress, __) => Text(
        '${status.name}: ${(progress * 100).toStringAsFixed(1)}%',
      ),
    );
  },
);
```

也可以直接调用 `startDownload()`、`pauseDownload()`、`install()` 和 `reset()`。

### 安装权限

Android 8 及以上可能需要用户授权“安装未知应用”：

```dart
final result = await upgrader.install();
if (result.status == InstallStatus.permissionRequired) {
  await upgrader.openInstallPermissionSettings();
  // 用户返回应用后，再次调用 install()。
}
```

请确保通过此权限发布应用符合目标应用商店的政策。

## 服务端响应

默认解析器读取以下 JSON 字段；如果响应外层还有 `data` 等结构，请像上面的初始化示例一样传入 `parser`：

```json
{
  "update_status": 0,
  "version": "1.2.0",
  "build_version": 12,
  "modify_content": "修复问题并提升下载稳定性",
  "download_url": "/api/apk-manager-v1/download/1.2.0",
  "apk_size": 52428800,
  "apk_hash_code": "APK 文件摘要",
  "apk_hash_algorithm": "sha256"
}
```

- `update_status`：`0` 可选更新、`1` 推荐更新、`2` 强制更新。
- `download_url`：可使用完整 URL；相对 URL 会基于 `baseUrl` 解析。
- `apk_size`：APK 字节数，建议提供。
- `apk_hash_code`：MD5 或 SHA-256 十六进制摘要，建议提供。
- `apk_hash_algorithm`：`md5`（默认）或 `sha256`。

建议同时提供文件大小和摘要。校验采用流式读取，不会把整个 APK 加载进内存。

## 前台下载服务

下载由 Android 原生前台服务执行，通知栏提供进度和暂停操作。任务参数与进度保存在应用私有存储中；Flutter 引擎重新连接后会恢复 `statusNotifier`、`progressNotifier` 和安装文件路径。

插件 Manifest 已声明 `INTERNET`、`WAKE_LOCK`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、`POST_NOTIFICATIONS` 和 `REQUEST_INSTALL_PACKAGES`，并注册了下载服务与 FileProvider。

Android 13 及以上仍需宿主 App 在运行时请求通知权限。若未授权，系统可能只在“活动应用”区域显示前台服务，而不会在通知抽屉展示完整进度。

前台服务必须由用户可感知的前台操作启动。默认强制更新页不会自动开始下载；如果启用 `autoStartForcedDownload`，请确保页面出现时应用仍处于前台。

服务端若支持断点续传，应对 `Range: bytes=<offset>-` 返回 `206`、准确的 `Content-Range` 和 `Content-Length`。若返回 `200`，TinyUpgrader 会安全地删除已有片段并从头下载。

## Example 人工验收

不需要部署后端。下面的单一入口会启动本地 HTTP 服务、设置 `adb reverse`，然后通过 `flutter run` 启动真实的 example App：

```bash
python3 example/tool/run_foreground_download_test.py
```

终端需要保持运行。App 启动后点击“更新测试”，可实际查看更新弹窗并开始下载；下载过程中按 Home 键，即可检查通知栏进度和退到后台后的下载行为。下载内容是本次 `flutter run` 生成的真实 `app-debug.apk`。

有多个 Android 设备时指定目标：

```bash
python3 example/tool/run_foreground_download_test.py -d <device-id>
```

默认使用 `adb reverse`，所以测试 App 中的 `127.0.0.1` 会被转发到开发机。如果设备不支持 reverse，可自动读取 Mac 的 Wi‑Fi IP，或手动指定：

```bash
python3 example/tool/run_foreground_download_test.py --wifi
python3 example/tool/run_foreground_download_test.py --host-ip 192.168.1.20
```

本地服务脚本与 integration tests 已通过 `.pubignore` 排除，不会进入发布到 pub.dev 的插件包。

## 后端代码示例

```go
package main

import (
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"github.com/gin-gonic/gin"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path"
	"strconv"
	"strings"
)

var fileData *fileInfo

const (
	version      = "1.2.0"
	buildVersion = 1
)

func main() {
	r := gin.Default()

	{
		base := r.Group("/api/apk-manager-v1")
		base.POST("/upload", func(c *gin.Context) {
			// 解析表单数据
			file, err := c.FormFile("apk")
			if err != nil {
				fmt.Println(err)
				return
			}

			fileData, err = processFile(c, file, version, buildVersion)
			if err != nil {
				fmt.Println(err)
				return
			}
		})

		base.GET("/download/:version", func(c *gin.Context) {
			c.Header("Content-Type", "application/octet-stream")
			c.File(fileData.Path)
		})

		base.GET("/latest", func(c *gin.Context) {
			c.JSON(http.StatusOK, gin.H{
				"update_status":  2,
				"version":        version,
				"build_version":  buildVersion,
				"modify_content": "修复了一些bug",
				"download_url":   "/api/apk-manager-v1/download/" + version,
				"apk_size":       fileData.Size,
				"apk_hash_code":  fileData.MD5,
				"apk_hash_algorithm": "md5",
				"apk_path":       fileData.Path,
			})
		})
	}
}

// 辅助结构体
type uploadParams struct {
	UpdateStatus  int
	Version       string
	BuildVersion  int
	ModifyContent string
}

type fileInfo struct {
	Size int64
	MD5  string
	Path string
}

// 解析上传参数
func parseUploadParams(c *gin.Context) (*uploadParams, error) {
	updateStatus, err := strconv.Atoi(c.PostForm("update_status"))
	if err != nil || updateStatus < 0 || updateStatus > 2 {
		return nil, fmt.Errorf("invalid update_status")
	}

	version := c.PostForm("version")
	if version == "" {
		return nil, fmt.Errorf("必须填写版本号")
	}

	buildVersion, err := strconv.ParseInt(c.PostForm("build_version"), 10, 32)
	if err != nil || buildVersion < 0 {
		return nil, fmt.Errorf("构建号必须是大于0的整数")
	}

	return &uploadParams{
		UpdateStatus:  updateStatus,
		Version:       version,
		BuildVersion:  int(buildVersion),
		ModifyContent: c.PostForm("modify_content"),
	}, nil
}

// 处理文件保存 只是一个参考，也可以自行处理
func processFile(c *gin.Context, file *multipart.FileHeader, bigVersion string, buildVersion int) (*fileInfo, error) {
	// 打开文件
	src, err := file.Open()
	if err != nil {
		return nil, fmt.Errorf("failed to open file")
	}
	defer src.Close()

	// 创建一个 MD5 哈希器
	hash := md5.New()
	// 将文件内容拷贝到哈希器中
	if _, err := io.Copy(hash, src); err != nil {
		fmt.Println("无法读取文件:", err)
		return nil, err
	}
	// 计算 MD5 哈希值
	hashInBytes := hash.Sum(nil)[:16]
	// 将哈希值转换为十六进制字符串
	hashString := strings.ToUpper(hex.EncodeToString(hashInBytes))

	_, err = src.Seek(0, io.SeekStart)
	if err != nil {
		return nil, err
	}

	// 创建保存路径
	ext := path.Ext(file.Filename)
	newFilename := fmt.Sprintf("app-v%s-%d%s", bigVersion, buildVersion, ext)
	filePath := path.Join("./", newFilename)

	// 保存文件到磁盘
	dst, err := os.Create(filePath)
	if err != nil {
		return nil, fmt.Errorf("failed to create file")
	}
	defer dst.Close()

	if _, err := io.Copy(dst, src); err != nil {
		return nil, fmt.Errorf("failed to save file")
	}

	return &fileInfo{
		Size: file.Size,
		MD5:  hashString,
		Path: filePath,
	}, nil
}
```
