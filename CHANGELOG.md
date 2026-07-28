# 1.2.0

- APK 摘要改为流式计算，并支持 MD5 与 SHA-256
- 新增严格的数字版本比较与结构化更新检查结果
- 新增未知来源安装权限 API 与结构化安装结果
- 下载改为按响应状态决定覆盖/续写，并严格校验 `Content-Range`
- 网络重试与文件校验重试分离，并对网络重试采用退避等待
- 大文件下载前检查下载、安装 staging 与安全余量所需空间
- 使用下载 session 隔离暂停、重置与旧异步回调
- APK 文件名和清理范围限制为 `tiny_upgrader_*.apk`
- Release 构建也会执行平台与初始化检查
- 业务事件不再受日志开关影响，且回调异常不会中断升级流程
- FileProvider 使用插件专属 authority，并显式依赖 AndroidX Core

# 1.1.1

- 新增下载重试上限机制，`TinyUpgrader.init()` 新增 `maxRetryCount` 参数（默认 3），防止文件大小不匹配或 HTTP 416 时无限循环
- `downloadStart`、`downloadConflict`、`downloadRetry` 事件数据中增加 `retryCount` 和 `maxRetryCount` 字段
- 重试耗尽时触发 `downloadError` 事件并回调 `errorHandler`，状态置为 error

# 1.1.0

- 新增统一的事件回调系统 (`UpgraderCallback`)，覆盖初始化、检测、下载、校验、安装、清理全部环节
- 新增 `UpgraderEvent` 和 `UpgraderEventType`，支持 24 种事件类型，携带结构化数据
- `TinyUpgrader.init()` 新增 `onEvent` 和 `enableLog` 参数
- 运行时可通过 `TinyUpgrader.instance.enableLog` 动态开关日志回调
- 每个关键节点均发射对应事件，下载进度每帧回调，方便自定义进度 UI

# 1.0.5
- fixs some bugs
- if server return http 416 code. it will be remove local apk
- local apk add build number. version format be like 'x.x.x-xx.apk'

# 1.0.4

- fixs some bugs
- set the download file write mothod to append write

# 1.0.3

- add more logs

# 1.0.2

- add some logs
- add shouldUpdate function

# 1.0.1

- restriction systems other than android

# 1.0.0

- fixs some bugs
- updated the description to make it more helpful

## 0.0.2

- updated callback function
- add enum Widgets

## 0.0.1

- complated basic functions
