# 隱私：語音輸入的資料流與在地化

狀態：待辦（PoC 階段先用雲端，之後處理）

## 現況：哪些資料會離開這台 Mac

| 資料 | 送往 | 時機 |
|---|---|---|
| 麥克風音訊（24 kHz PCM） | OpenAI Realtime API（`gpt-4o-transcribe` 與預覽用的 `gpt-live-transcribe` 各一份） | 按住右 Option 期間即時串流 |
| 音訊（WAV） | OpenAI `/audio/transcriptions` 或 ElevenLabs Scribe | 只在 provider 設為 `openai` / `elevenlabs` 時，放開後整段上傳 |
| 辨識後的逐字稿 | OpenAI Chat Completions（潤飾模型） | 放開後，潤飾強度 > 0 時 |
| 目前 App 的名稱 | 同上，放在 system prompt | 同上 |

- API key 從偏好設定指定的 dotenv 檔讀取，不進 repo、不寫 log。
- 本機暫存：音訊只在記憶體，不落地；Console log 只記錄長度與音量，不記錄內容。

## 待辦

- [ ] 本機 ASR：在 Mac Studio 跑 whisper（或 Qwen ASR，見 `~/workspace/zbryikt/ai/voice/qwen-asr`），提供與 Realtime 相同的串流介面（WebSocket 或 HTTP chunk），讓 provider 可切換。
- [ ] 本機 LLM：潤飾改用本機模型（例如 Mac Studio 上的 Ollama / MLX），評估延遲與品質；強度 0 時完全不送文字。
- [ ] 「全部本機」模式開關：開啟時禁止任何雲端呼叫，設定錯誤時寧可失敗也不 fallback 到雲端。
- [ ] 安全輸入欄位：密碼欄（Secure Event Input）時停用語音輸入。
- [ ] App 黑名單：在指定 App（例如密碼管理器、網銀、內部工具）停用語音輸入或強制本機模式。
- [ ] 不送 App 名稱的選項。
- [ ] 首次啟用時的告知：說明音訊與文字會送往哪些服務，需使用者同意後才啟用。
- [ ] 確認各服務的資料保留政策（OpenAI API 預設保留天數、是否可申請 Zero Data Retention；ElevenLabs 的保留設定），寫進說明。
- [ ] 錄音中的明確提示（目前只有 tooltip），避免使用者不知道正在收音。
