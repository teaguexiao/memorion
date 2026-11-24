# Memorion

[English](README.md) · [App Store](https://apps.apple.com/us/app/memorion-ai-voice-recorder/id6758304534) · [开发环境搭建](docs/development.md)

Memorion 把日常对话整理成可搜索的时间线、笔记和日记。你可以从手机或 Apple Watch 开始录音，也可以同步兼容设备里的录音。这个仓库提供移动端、处理后端、设备适配层和固件，供开发者搭建自己的随身 AI。

## 现在可以做什么

- 回顾对话转写与摘要。有源音频时，可以点按某句转写来播放对应片段。
- 在时间线里搜索过去的对话，为参与者添加姓名并纠正说话人标注。
- 审阅建议待办、管理已保存的记忆，把当天的对话整理成日记。
- 从一段对话继续追问，也可以在 Ask 里检索自己的记录。

托管版使用云端转写和 AI 服务。自建版会使用你配置的处理服务。开始录音前请让在场人员知情并同意。

| 对话章节 | 每日日记 |
| :---: | :---: |
| <img src="docs/screenshots/conversation.png" width="290" alt="社区自行车维修活动的对话摘要"> | <img src="docs/screenshots/daily-journal.png" width="290" alt="含下次骑行备忘的日记"> |

截图由真实 Flutter 页面渲染，内容来自虚构示例。

## 支持的录音来源

| 来源 | 当前能力 |
| --- | --- |
| iPhone 麦克风 | 手动开始和停止录音，无需额外设备。 |
| Apple Watch | 在手表端开始和停止，录音同步到配对的 iPhone 后处理。 |
| 安克录音豆 soundcore Work（D3200） | 导入设备已经完成的录音。 |
| 钉钉 A1 | 设备授权后导入已完成的录音，可选自动同步。 |
| PLAUD Note | 授权并同步原版 Note 上已完成的录音，适配器支持 Wi-Fi 传输。 |
| ChipletRing BCL603 | 源码中的 iOS 实验性适配，包含录音和音频同步。适用范围取决于型号和固件。 |
| Memorion DevKit / Omi、Brilliant Labs Frame | 仓库包含开发用适配器，以及 Omi 和 DevKit 固件项目。 |

表中前五项已列入 App Store 版本说明。Memorion 自有消费版录音硬件尚未开放。

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| [`app/`](app/) | Flutter iOS / Android 应用、watchOS 伴侣应用和 BLE 适配器 |
| [`backend/`](backend/) | FastAPI、语音转写、对话处理和 Developer API |
| [`cli/`](cli/README.md) | TypeScript CLI 和 MCP 服务器 |
| [`firmware/`](firmware/README.md) | Omi 和 DevKit 固件 |
| [`docs/`](docs/) | 开发搭建、API 说明和截图 |

本地开发可从[开发环境搭建](docs/development.md)开始。对接服务可查看 [Developer API 说明](docs/api/README.md)。

## 许可

见 [MIT 许可证](LICENSE)和[第三方许可说明](docs/third-party.md)。项目基于 [Omi](https://github.com/BasedHardware/omi)，设备名称用于标明兼容性。
