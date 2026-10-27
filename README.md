# 无界（Boundless）

一套键盘鼠标同时控制两台 Mac。鼠标推到屏幕边缘就进入另一台，键盘跟着过去，切换时自动同步剪贴板。

- 主控端：接着键盘鼠标的那台（Mac mini）
- 被控端：被控制的那台（MacBook Pro）

## 安装

两台都要装同一个版本。

1. 在 MacBook Pro 上构建：`./scripts/build-app.sh`，产物是 `build/Boundless.app` 和 `build/Boundless.zip`
2. MacBook Pro：把 `build/Boundless.app` 拖进「应用程序」
3. Mac mini：用隔空投送把 `build/Boundless.zip` 发过去，解压后拖进「应用程序」。
   第一次打开时系统会提示「无法验证开发者」：macOS 14 及以前**右键 → 打开**；macOS 15 起到「系统设置 → 隐私与安全性」底部点「仍要打开」。或者直接在终端执行：
   ```
   xattr -dr com.apple.quarantine /Applications/Boundless.app
   ```

二进制同时包含 Apple 芯片和 Intel 版本，最低 macOS 13。

## 首次设置

**Mac mini（主控端）**
1. 打开「无界」，选「主控端」
2. 按提示授予两项权限：系统设置 → 隐私与安全性 → **辅助功能**、**输入监控**，勾选「无界」
3. 点菜单栏的键盘图标（无界），看到「配对码：XXXX-XXXX-XXXX」（点击可复制）
4. 被控端连上后，点菜单「屏幕排列…」，把紫色的 MacBook 方块拖到它相对 Mac mini 屏幕的实际位置（可以上下错开），松手自动贴边

**MacBook Pro（被控端）**
1. 打开「无界」，选「被控端」
2. 授予**辅助功能**权限；要把窗口拖到 Mac mini 上，再授予**屏幕与系统录音**权限（授权后需退出重开无界）
3. 输入主控端的配对码
4. 系统询问「允许查找本地网络设备」时选允许

两台在同一局域网内会自动发现并连接，菜单栏图标变成双屏图标即为已连接。

## 使用

| 操作 | 效果 |
|---|---|
| 鼠标推过两块屏幕贴合的那段边（排列窗口里的青色边） | 进入 MacBook，落点按真实位置对齐，键盘同时切过去 |
| 在 MacBook 上把鼠标从贴合的那段边推回去 | 回到 Mac mini |
| ⌃⌥⌘ + 方向键 | 朝被控端方向切过去，反方向切回来（菜单里会显示具体按键） |
| 在一台上复制，切到另一台粘贴 | 文本、富文本、图片自动同步（可在菜单关闭） |
| 在 MacBook 上按住窗口标题栏，拖过通向 Mac mini 的那段边 | 窗口像拖到副屏上一样到了 Mac mini 上，松手放下，接着就能打字 |
| 在 Mac mini 上把这个窗口拖过通向 MacBook 的那段边 | 窗口回到 MacBook 屏幕，鼠标也进入 MacBook |
| 主控端菜单「把被控端窗口移过来」→ 选一个窗口 | 不用拖，直接把它放到 Mac mini 屏幕中间；「全部移回被控端」一次收回 |

### 虚拟副屏：把 MacBook 的窗口拖到 Mac mini 上

效果和给 MacBook 接了一块副屏一样：MacBook 上会多出一块看不见的虚拟屏，大小和位置与 Mac mini 的屏幕一一对应（按「屏幕排列」里的位置摆）。窗口拖过边，其实是在 MacBook 上原生地挪到了这块屏上；Mac mini 在同样的位置把它显示出来。程序仍然跑在 MacBook 上。

- **操作**：Mac mini 的光标停在这些窗口上时，点击、拖动、滚动、拉边框改大小都由 MacBook 原生处理；光标移开就回到 Mac mini 本机。Mac mini 自己的窗口可以正常盖住它们
- **键盘**：点了这些窗口之后，键盘发给 MacBook（用 MacBook 的输入法）；点一下 Mac mini 自己的窗口或按 ⌘Tab，键盘回到 Mac mini。⌘Tab 始终留在 Mac mini 上
- **按需创建**：第一次拖窗口时才建虚拟屏（约半秒），上面没有窗口 30 秒后自动撤掉；撤掉、断线超过 10 秒或退出无界时，上面的窗口由系统挪回 MacBook 屏幕
- **清晰度**：窗口静止时只采它所在的区域、用原生 2 倍分辨率，和 MacBook 上看到的像素一致；画面停下 0.15 秒后再补几帧，把滚动时降下去的画质补回来。拖动窗口时改采整屏（约 1.5 倍），停下约 0.6 秒后切回，切换时画面会顿一下。窗口很大、像素超出约 470 万时自动降倍率（4K 整屏 2 倍采集跟不上 60fps）
- **流畅度**（有线实测）：画面变化快的窗口 55~57fps，端到端延迟平均约 12ms、P95 约 20ms；终端满屏刷字符时约 30fps，这是终端自己刷屏的速度。有线码率每像素 12 bit、最高 80 Mbps，Wi-Fi 每像素 4 bit、最高 40 Mbps
- 有虚拟屏时连接退到 Wi-Fi 也会定时尝试切回有线，切换时画面黑一下，窗口不会被弹回

断线时控制权自动回到 Mac mini，MacBook 上按住的键会自动松开，不会卡键。

## 已知限制

- **触控板手势**（三指切换桌面、捏合缩放等）不转发，仍作用在主控端上；双指滚动可以正常转发
- **安全输入**：某个应用开启安全输入（常见于密码框、部分终端）时，macOS 不允许截获键盘，菜单里会出现 ⚠️ 提示
- **大写锁定**：尽力转发，但在被控端切换输入法的行为未在真机验证；不稳定时建议改用 ⌃空格 切换输入法
- **跨机器拖文件**不支持；拖拽途中（按住鼠标键）不会切换机器，例外是虚拟屏已建好时（见「虚拟副屏」）
- 虚拟副屏：第一次拖窗口时要等约半秒建好虚拟屏，一开始就贴着边拖可能过不去，再拖一次即可；窗口的菜单栏不搬过来（仍在 MacBook 那块看不见的屏上），光标形状（如文字输入的 I 形）不同步，窗口阴影不显示，不支持在 Mac mini 上全屏
- 窗口在虚拟屏上并处于激活状态时，该应用新开的窗口也会开在虚拟屏上（和真副屏一样）；在 MacBook 本机用触控板时，光标可能走进看不见的虚拟屏
- 剪贴板单次最大 32MB，不同步文件，也不同步密码管理器标记为隐藏的内容
- 同一时间只连一台被控端
- 虚拟副屏：画面是视频编码，彩色小字的边缘会比原生显示略虚；不传声音；用的是苹果未公开的虚拟显示器接口（`CGVirtualDisplay`），系统升级后可能需要跟着改
- macOS 15 起，系统会定期提醒确认「屏幕与系统录音」权限，这是系统行为

## 安全

配对码 12 位（约 59 bit），经 PBKDF2 派生为 TLS 1.2 预共享密钥，所有键鼠和剪贴板数据都加密传输。配对码不一致时握手直接失败。怀疑泄露时在主控端菜单「重新生成配对码」。

## 开发

```
swift test                 # 单元测试 + 本机回环 TLS 集成测试
./scripts/build-app.sh     # 打包签名
./scripts/icons/make-icns.sh   # 重新渲染图标（3D 场景在 scripts/icons/render.swift，当前用 B 无限之环）
```

中文系统下 App 显示为「无界」，英文系统显示 Boundless（`Resources/*.lproj/InfoPlist.strings`）。bundle ID 保持 `app.boundless.Boundless` 不变，改了会让已授予的系统权限失效。

联调：被控端可以不注入、只打印收到的动作，便于在同一台机器上调试：

```
.build/apple/Products/Release/Boundless -role client -clientCode XXXX-XXXX-XXXX -dryRun YES
```

排查连接问题：打开「控制台」App，搜索 `Boundless`。

压测流畅度（开发参数，两台都可加）：

```
open /Applications/Boundless.app --args -streamStats YES            # 每 2 秒打印帧率、码率、最大间隔、延迟、丢帧
open /Applications/Boundless.app --args -streamStats YES -autoMove 关键词   # 主控端：连上后自动把匹配的窗口挪过来
open /Applications/Boundless.app --args -streamScale 2              # 被控端：强制采集倍率，对比分辨率的影响
```

代码结构：
- `Sources/BoundlessCore`：纯逻辑与网络，不依赖 AppKit，全部有测试
  - `Message.swift` 协议与分帧，`Transport.swift` TLS 连接 / Bonjour / 心跳
  - `ServerSwitch.swift` 主控端切换状态机（在哪边按下就在哪边松开，防卡键）
  - `ClientCursor.swift` 被控端虚拟光标与按键状态
  - `Geometry.swift` 多显示器边缘判定，`Arrangement.swift` 屏幕排列（贴边吸附、坐标换算）
  - `VirtualScreen.swift` 虚拟屏与主控端屏幕的对应关系，`StreamGeometry.swift` 采集尺寸与码率，`FrameStats.swift` 流畅度统计
- `Sources/Boundless`：菜单栏 App，事件截获（`InputCapture`）、注入（`InputInjector`）、剪贴板、屏幕排列窗口（`ArrangementWindow`）
  - 虚拟副屏：被控端建屏、采集（`VirtualDisplay`，CGVirtualDisplay + ScreenCaptureKit）与编码（`VideoEncoder`，VideoToolbox），主控端按窗口位置遮罩显示（`VirtualOverlay`）
- `Sources/VirtualDisplayAPI`：`CGVirtualDisplay` 私有接口的头文件声明

协议版本 7：控制通道和视频通道是两条独立的 TLS 连接，连上后由 `hello` 里的通道字段区分。
