# TinyUpgreade

这是一个 Flutter 项目，APP 升级插件，支持使用 Flutter 组件作为更新弹窗。

与其他插件最大的不同是这里**尽最大可能只使用 Dart 一个语言处理逻辑**，例如 APP 安装等系统接口调用以外的部分都会用 Dart&Flutter 完成。

## 特色功能

- 支持使用 Flutter Widget 自定义更新弹窗样式
- 支持使用事件回调无 UI 更新，当你需要自定义一个 APP 更新**”页面“**而非弹窗时，它会非常有用。
- 至少 2 年的维护支持

## 开始使用

使用门槛很低，在你的 APP 启动时或者任何在需要更新前，调用初始化接口，例如

```dart
TinyUpgrader.init(
  // 是否为开发调试模式，能看到更多日志
  isDebug: true,

  // APP路径前缀
  baseUrl: 'https://example.cn:8080/',

  // 错误回调函数，为了避免影响您的业务，只在这里进行回调提示，而不去throw错误
  errorHandler: (error) {
    debugPrint('出现错误: $error');
  },

  /// 自定义解析器，这里你可以将回调函数返回的json数据解析成VersionInfo对象，也可以对其进行加工处理
  parser: (response) async {
    /// response 就是 dio 的 response data 没有做任何处理，我的响应结构是 { success: boolean, data: dynamic }
    var res = VersionInfo.fromMap((response as Map<String, dynamic>)['data']);

    // 例如我这里就对它进行token校验
    res.downloadUrl = '${res.downloadUrl}?token=123123';
    return res;
  },
);
```

而在检查更新时，只需要简单一行代码即可完成

```dart
await _upgrader.check(context, url: 'api/apk-manager-v1/latest');
```

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
				"file_path":      fileData.Path,
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
