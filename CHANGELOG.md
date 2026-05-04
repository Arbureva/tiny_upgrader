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
