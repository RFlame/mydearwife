# 《零食叮叮咚》小红书小工具版

## 产物与源码

- 源码：`minitool/`
- 构建脚本：`tools/build_minitool.py`
- 完整审计：`tools/audit_minitool.py`
- 构建目录：`build/minitool/`
- 待上传 ZIP：`build/snack-dingdong-minitool.zip`
- Godot 原版继续保留；小工具不是对 Godot Web 导出物的重新压缩。

```bash
python3 -I tools/build_minitool.py
node tools/minitool_tests/core_test.js
python3 -I .claude/minitool-zip-builder/scripts/audit_artifact.py build/minitool
python3 -I tools/audit_minitool.py build/minitool
python3 -I .claude/minitool-zip-builder/scripts/audit_artifact.py build/snack-dingdong-minitool.zip
python3 -I tools/audit_minitool.py build/snack-dingdong-minitool.zip
```

## 功能映射

- 保留 20 关、40 款原创零食、12 位原创顾客、难度预设、星级、金币、解锁、设备升级和两类图鉴。
- 保留左侧屏幕外篮口撒落，全部落地前锁定交互。
- 保留真实旋转包装遮挡、露出比例门槛、辅助触摸热区、整桌拖动、秤区与收银员过道禁放。
- 保留四个无边框椭圆集货区；同款必须全部位于同一区才完整。
- 未入队区域可点击退回；混放不结算，退走异类后可立即完整。
- 自动与手动模式共用 FIFO 队列和串行称重。手动模式一次双击授权会消费当前队列，而不是只结算一个区。
- 保留连击、耐心、礼盒、盲袋、LED 重量、价签、装袋、收银员反馈、暂停、失败与完成结算。
- 吸附改为把当前可拿取的同款送入符合四区规则的集货区，次数仍受升级影响；不再走旧“直接放入称重台”路径。
- 电子秤升级缩短 LED 动画；吸附升级增加次数。称重台升级等级与成本保留，但当前四区完整批次本就不受旧台位格数限制，因此该等级不改变批次容量。
- 旧额外台位、冻结道具入口没有重新加入；轻松预设提供自动提示。最上层物品始终可拿取，不依赖旧防死锁道具。
- 使用本地 Web Audio 合成音效，不包含 WAV；不支持时无声降级。没有连续背景音乐。
- 存档严格使用 `window.xhs.miniTool` Storage，数据为 JSON 字符串；版本或方法不满足时明确提示仅保留到关闭前，不使用浏览器存储替代。
- 振动与窗口信息按在线文档做客户端版本和方法检测。未接入无关 AI、定位、陀螺仪、关注、赞赏或云能力。

## 已明确的适配差异

- 这是独立 ES2017 + Canvas 2D 实现。JS 种子可复现自身布局，但不承诺逐坐标复现 Godot RNG。
- 零食与人物沿用原创 SVG；音效改为实时合成；字体使用系统字体栈。
- 四区称重、顾客切换由同一核心状态机驱动，最后一批价签动画独立跨越换客撒落，不被新顾客重置。
- 普通浏览器没有小红书 Storage，会显示不可持久保存提示。普通浏览器运行结果仅用于开发辅助，不是小工具功能、兼容性或交付验收。

## 验证边界

聚焦测试仅覆盖新增小工具核心及受影响交互，不运行无关 Godot 全量测试。最终仍必须上传同一 ZIP 到创服平台，依次完成：

1. 创服平台模拟器完整功能验证；
2. Android 真机扫码验证；
3. iOS 真机扫码验证。

以上三项均待用户验证，本地脚本与普通浏览器结果不能替代。
