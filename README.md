# 快手双击打开评论区 Tweak

- 包名：`com.kuaishou.ksa`
- 平台：iOS 15+ / arm64 + arm64e
- 效果：**视频播放页双击 → 打开评论区**（不再是点赞），并取消双击爱心动画。只在播放页生效，其他页面双击行为不变。

## 目录

```
KSDoubleTap/
├── Makefile
├── KSDoubleTap.plist          # 过滤器（只注入快手）
├── Tweak.xm                   # 源码
└── layout/DEBIAN/             # control / postinst
```

## 编译

需要 Theos（macOS 或 iOS 上的 Theos 均可）：

```bash
export THEOS=~/theos
cd KSDoubleTap
make package FINALPACKAGE=1          # 出 deb
make package install                 # 直连设备安装
```

设备上装 `mobilesubstrate`（或 Dopamine 的 ElleKit 等兼容库）。

## 安装后

1. 打开快手，控制台看日志：
   ```bash
   idevicesyslog | grep KSDT
   ```
   或设备端 `oslog` / Filza 查看 `NSLog`。
2. 播放页双击一次，日志会打印：
   ```
   [KSDT] 接管双击手势 class=... view=... 原action: -[XXX handleDoubleTap:]
   [KSDT] 播放页双击 -> 打开评论区 (已拦截点赞)
   ```
   用这里的 **class / 原 action** 就能确认快手当前版本的真实类名。

## 工作原理（为什么不直接 %hook 具体类）

快手把双击/点赞的类名、方法名每个版本都可能变，直接 `%hook 某类名` 如果类不存在，会导致**整个 tweak 加载失败**（也是常见“闪退”原因）。所以这里走通用路径：

| 能力 | 做法 |
|---|---|
| 拦截双击点赞 | hook `UIView -addGestureRecognizer:`，遇到 `numberOfTapsRequired==2` 的手势就 `removeTarget:nil action:NULL` 清掉原生点赞，再挂自己的 `onDoubleTap:` |
| 只在播放页生效 | `KSDT_IsInPlayerPage()`：沿 responder 链 + 视图层级 + 所在 VC，匹配 `player/video/feed/photo/...` 关键字 |
| 打开评论区 | 先按方法名候选（`openComment`…）找实现；再找评论按钮 View 模拟点击；最后广播 `KSDT_OPEN_COMMENT` 兜底 |
| 取消爱心动画 | hook `CALayer -addAnimation:forKey:`，key/类名含 `heart/like/digg/praise/love/thumb` 直接 return |
| 防野指针闪退 | 全链路 `KSDT_OK()` 指针有效性校验 + `@try/@catch` + 手势用 `__weak` 延迟处理 + responder 链 20 层上限 |

## 如果某版本双击没反应

日志里看 `接管双击手势` 有没有出现：
- **没出现** → 快手没用标准 UITapGestureRecognizer，或手势在 `setNumberOfTapsRequired:` 之前就建好。可把 `KSDT_TakeOverGesture` 触发点再加到 `-[UIGestureRecognizer setTarget:action:]`。
- **出现了但不打开评论** → 说明接管成功、`KSDT_OpenComment` 没命中入口。把日志里打印的视图类名贴给我，我把对应方法名加进 `KSDT_OpenCommentSels()` 或 `KSDT_FindCommentBtn` 关键字。

## 已验证 / 未验证

- ✅ 代码结构、括号、hook 注入路径完整，可直接用 Theos 编译。
- ⚠️ 打开评论区的“方法名候选”是按常见命名推断的，**需在你实际的快手版本上跑一次日志确认**，再按上面的方法微调。这是所有无符号逆向 tweak 的常态。
