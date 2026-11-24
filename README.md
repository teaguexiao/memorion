# Memorion

[简体中文](README.zh-CN.md) · [Website](https://memorion.me/) · [App Store](https://apps.apple.com/us/app/memorion-ai-voice-recorder/id6758304534) · [Developer setup](docs/development.md)

**Memorion is an open-source wearable AI platform for turning everyday conversations into searchable memory.** Record on iPhone or Apple Watch, or import audio from a compatible wearable. Then revisit what was said, ask follow-up questions, and see the day come together in your journal.

## Record on Apple Watch

Start and stop a recording from your wrist, even when your iPhone is out of reach. The watch app syncs the recording to your paired iPhone for transcription and AI processing. Review the transcript, summary, and timeline on iPhone after processing. All you need to start is the Memorion app and your paired Apple Watch. [See the Apple Watch walkthrough](https://memorion.me/en/app).

<p align="center"><img src="docs/screenshots/apple-watch-recording.png" width="236" alt="Memorion on Apple Watch showing an active recording and the Stop button"></p>

## From conversation to memory

### Conversations and transcripts

Open a chapter to revisit the transcript, summary, and key moments. Name speakers or correct their labels, and tap a transcript line to play the matching audio when it’s available. Suggested to-dos let you review follow-ups before adding them to your list.

### Conversation Chat and Ask

Ask a question from an individual chapter to follow up in context, such as “What did we agree to do next?” Use **Ask** to look across past conversations when you remember the topic but need help finding the moment. For example, ask what the team decided at last week’s product review, then return to the relevant conversation. [See more examples on the website](https://memorion.me/).

### Daily Journal

Memorion uses your conversations to create a dated journal entry. See what stood out across the day, what you want to remember, and what you want to pick up tomorrow. Browse older entries in the Journal tab, or switch to the conversation timeline for the full transcripts.

| Conversation chapter | Daily Journal |
| :---: | :---: |
| <img src="docs/screenshots/conversation.png" width="260" alt="Conversation chapter summarizing a bicycle repair workshop"> | <img src="docs/screenshots/daily-journal.png" width="260" alt="Daily Journal entry with a checklist for the next bicycle ride"> |

The iPhone screenshots use fictional conversations. The Apple Watch screenshot is from the [official app page](https://memorion.me/en/app).

The hosted app uses cloud speech-to-text and AI services. A self-hosted installation sends data to the providers you configure. Record with the knowledge and consent of the people involved.

## Recording sources

| Source | What is available |
| --- | --- |
| iPhone microphone | Start and stop recording in the app. No wearable is needed. |
| Apple Watch | Start and stop from the watch app. Audio syncs to the paired iPhone for processing. |
| soundcore Work (Anker D3200) | Import completed device recordings. |
| DingTalk A1 | Authorize the device and import completed recordings. Automatic sync is optional. |
| PLAUD Note | Authorize the original Note and sync completed recordings. The adapter supports Wi-Fi transfer. |
| ChipletRing BCL603 | Experimental iOS adapter in source for recording and audio sync. Device and firmware compatibility is limited. |
| Memorion DevKit / Omi, Brilliant Labs Frame | Development adapters in source. Omi and DevKit firmware projects are included. |

The App Store listing documents the first five recording sources. Memorion’s dedicated consumer recording hardware is coming soon.

## Inside the repository

The code covers the path from capturing audio on a phone or wearable to producing transcripts, chat responses, and journal entries.

| Layer | Where to start | What’s included |
| --- | --- | --- |
| Mobile app and device adapters | [`app/`](app/) · [Flutter source](app/lib/) | iOS and Android app source, recording and BLE device integrations, conversation timeline, Ask, and journal UI. |
| Apple Watch | [Watch app](app/ios/MemorionWatch/) · [Widgets](app/ios/MemorionWatchWidgets/) · [iPhone sync](app/ios/Runner/WatchSessionService.swift) | Native Swift recording app, watch controls, and audio transfer to the phone. |
| Backend and data | [`backend/`](backend/) · [API routes](backend/routers/) · [Data access](backend/database/) | FastAPI endpoints for audio ingestion, conversations, memories, chat, and the Developer API. |
| Speech and AI model layer | [Speech-to-text](backend/utils/stt/) · [LLM pipelines](backend/utils/llm/) · [Retrieval](backend/utils/retrieval/) · [Model routing](backend/config/README.md) | Speech provider adapters, prompts, embeddings and retrieval, model selection, and pipelines for summaries, chat, and journals. Configure the inference providers for your deployment. |
| Firmware | [`firmware/`](firmware/README.md) | Omi and DevKit embedded firmware, board presets, and build instructions. |
| Developer integrations | [CLI](cli/packages/cli/README.md) · [MCP server](cli/packages/mcp/README.md) · [Developer API](docs/api/README.md) | TypeScript command-line tools and MCP access to your Memorion data through the Developer API. |

Start with the [local development guide](docs/development.md) to configure your own backend and connect the app or developer tools.

## License

See the [MIT license](LICENSE) and [third-party notices](docs/third-party.md). The project builds on [Omi](https://github.com/BasedHardware/omi). Device names identify compatibility.
