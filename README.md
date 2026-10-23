# macOSHello

macOSHello 是一个纯本地的 macOS 菜单栏人脸解锁工具。它使用系统自带 Vision 框架完成人脸检测和特征识别，使用 AVFoundation 获取摄像头画面，识别过程全部在本机执行，不需要联网，也不会上传摄像头画面或人脸特征。

## 功能

- 多人脸注册，每张人脸保存 8 组本地特征样本
- 人脸识别、相似度阈值判断、实时相似度显示
- 基础活体检测，要求注册和识别时缓慢转头
- 枚举并指定内置或外接摄像头
- 锁屏、屏幕唤醒、系统唤醒或屏保出现后自动识别
- 密码保存在本机钥匙串，识别通过后解锁当前已登录会话
- 显示器关闭或系统睡眠时停止人脸检测，避免摄像头长时间占用
- 支持设置开机启动

## 原理

### 人脸注册

注册时，macOSHello 通过 AVFoundation 读取摄像头帧，然后使用 Vision 完成以下处理：

1. `VNDetectFaceRectanglesRequest` 检测画面中的人脸区域。
2. `VNDetectFaceLandmarksRequest` 获取人脸关键点。
3. `VNDetectFaceCaptureQualityRequest` 评估人脸质量，低质量帧会被丢弃。
4. `VNGenerateImageFeaturePrintRequest` 生成人脸特征向量。
5. 保存 8 组满足姿态变化要求的特征向量到 `~/.macOSHello/faces.json`。

注册阶段会记录 yaw 和 pitch 的变化范围，要求缓慢转头。这不是 Face ID 那种 3D 结构光活体检测，而是基础姿态变化检测。

### 人脸识别

识别时使用同样的 Vision 请求生成当前人脸特征向量，再计算它和已注册样本的余弦相似度：

```text
当前特征向量 · 注册样本向量 / (当前向量长度 × 注册样本长度)
```

每一帧都会得到一个相似度。只有满足以下条件才会判定成功：

- 当前帧相似度达到设置阈值，例如 `0.83`
- 连续 8 帧都达到阈值
- 基础活体检测开启时，姿态变化范围满足要求

因此“最高相似度超过阈值”但不等于识别成功；如果中途有一帧低于阈值，连续计数会重新开始。

### 屏幕解锁

macOSHello 监听锁屏、屏幕唤醒、系统唤醒和屏保通知，并在锁屏状态下启动本地人脸识别。识别成功后：

1. 从本机钥匙串读取用户保存的登录密码。
2. 通过辅助功能权限向登录窗口提交密码。
3. 解锁当前用户已经登录后的锁屏会话。

显示器关闭或系统睡眠时会停止摄像头和识别循环；显示器唤醒后再恢复检测。

## 使用的技术

macOSHello 没有使用第三方库，全部依赖 macOS 系统框架：

| 用途        | 系统 API                                       |
| --------- | -------------------------------------------- |
| 摄像头采集     | AVFoundation                                 |
| 人脸检测与特征识别 | Vision                                       |
| 图像和视频缓冲处理 | CoreGraphics、CoreVideo                       |
| 菜单栏与设置界面  | AppKit                                       |
| 密码保存      | Security                                     |
| 开机启动      | ServiceManagement                            |
| 锁屏与系统状态日志 | os、DistributedNotificationCenter、NSWorkspace |

人脸识别的核心是 `VNGenerateImageFeaturePrintRequest` 生成的本地特征向量，以及余弦相似度比对。项目不依赖 OpenCV、Python 或云端模型。

## 使用

1. 打开 `macOSHello.xcodeproj`，运行 `macOSHello` target。
2. 首次运行时授予摄像头权限。
3. 在系统设置的“隐私与安全性 > 辅助功能”中允许 macOSHello。
4. 在菜单栏选择“设置密码...”，输入当前登录密码。
5. 选择“注册人脸...”，按提示缓慢左右转头完成采集。
6. 选择“立即识别测试”验证配置。
7. 锁屏或让显示器睡眠后再唤醒，应用会自动尝试人脸解锁。

## 命令行测试工具

```bash
swift build
.build/debug/FaceUnlockTool camera-probe --timeout 10
.build/debug/FaceUnlockTool enroll --timeout 30
.build/debug/FaceUnlockTool verify --timeout 30
.build/debug/FaceUnlockTool wake-test --wake-seconds 10
.build/debug/FaceUnlockTool wake-test --sleep-display --wake-seconds 3
```

## 安全边界

- 只能解锁当前用户已登录后的锁屏，不能解锁重启后的 FileVault 首次登录。
- 登录密码必须保存在本机钥匙串，应用依赖辅助功能权限向登录窗口提交密码。
- 活体检测是基础姿态变化检测，不等同于 Face ID 的 3D 结构光活体检测。
- 人脸特征样本保存在 `~/.macOSHello/faces.json`，请自行做好磁盘加密和备份控制。
- 人脸识别可能被照片、视频或相似长相影响。提高相似度阈值可以降低误识别概率，但也会降低识别成功率。
- 摄像头画面和人脸特征只在本机处理，应用不包含联网上传逻辑。

## English

macOSHello is a fully local macOS menu-bar face unlock utility. It captures camera frames with AVFoundation, detects faces and generates face feature vectors with Apple's Vision framework, and compares vectors locally using cosine similarity. It does not use any third-party library, cloud service, Python runtime, or OpenCV.

During enrollment, the app uses `VNDetectFaceRectanglesRequest`, `VNDetectFaceLandmarksRequest`, `VNDetectFaceCaptureQualityRequest`, and `VNGenerateImageFeaturePrintRequest`. It stores eight feature samples in `~/.macOSHello/faces.json`. During verification, it compares the current feature vector with enrolled samples. A successful match requires the configured similarity threshold to be met for eight consecutive frames, plus the basic pose-range liveness check when liveness detection is enabled.

After a successful match, macOSHello reads the password from the local Keychain and submits it to the login window using the Accessibility permission. It can unlock the lock screen only when the current user session has already been authenticated; it cannot unlock the FileVault first-login screen after a reboot.

Face detection stops while the display is off or the system is asleep. All camera frames and face feature vectors are processed on-device. The liveness check is based on yaw and pitch variation and is not equivalent to Face ID's 3D depth-based liveness detection.

## 致谢

macOSHello 的锁屏与自动解锁流程参考并衍生自 [BLEUnlock](https://github.com/Skyearn/BLEUnlock)，感谢 Takeshi Sone 和 Skyearn 的开源工作。

## License

MIT License. See [LICENSE](LICENSE).
