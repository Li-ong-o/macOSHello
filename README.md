# macOSHello

macOSHello 是一个纯本地的 macOS 菜单栏人脸解锁工具。它使用 Vision 和摄像头完成人脸检测、特征识别、相似度阈值判断和基础活体检测，不访问网络，也不上传人脸数据。

## 功能

- 多人脸注册，每张人脸保存 8 组本地特征样本
- 相似度阈值可调，默认 `0.86`
- 基础活体检测，要求注册和识别时缓慢转头
- 枚举并指定内置或外接摄像头
- 屏幕唤醒、系统唤醒或屏保出现后自动识别
- 密码保存在本机钥匙串，识别通过后通过键盘事件解锁当前已登录会话
- 支持设置开机启动

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
- 登录密码必须保存在本机钥匙串，应用依赖辅助功能权限模拟键盘输入。
- 活体检测为基础级姿态变化检测，不等同于 Face ID 的 3D 结构光活体检测。
- 人脸特征样本保存于 `~/.macOSHello/faces.json`，识别过程全部在本机完成。
