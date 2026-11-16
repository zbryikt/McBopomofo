# OpenVanilla McBopomofo 小麥注音輸入法

## 大麥語音（DaMai Voice）

這個分支在小麥注音上加入實驗性的語音輸入：用 ElevenLabs Scribe 即時辨識語音，再用 OpenAI 模型潤飾成文字。

### 開啟語音輸入

語音輸入預設是關閉的。開啟方式：

```
defaults write io.github.zbryikt.inputmethod.DaMaiVoice VoiceInputEnabled -bool true
```

第一次說話時，macOS 會詢問是否允許使用麥克風。

### 設定 API key

在 `~/Library/Application Support/DaMaiVoice/voice-input.env` 建立檔案，每行一個 `KEY=VALUE`：

```
ELEVENLABS_API_KEY=你的 ElevenLabs key
OPENAI_API_KEY=你的 OpenAI key
```

- `ELEVENLABS_API_KEY`：語音辨識，必要。缺少時按下說話鍵不會錄音，只會出現提示。
- `OPENAI_API_KEY`：潤飾與校正時的候選字。缺少時仍可辨識，但潤飾會失敗，辨識的文字會保留下來供校正後送出；把潤飾強度設為 0 就不會用到。

想用其他位置的檔案：

```
defaults write io.github.zbryikt.inputmethod.DaMaiVoice VoiceInputAPIKeyFile ~/path/to/file
```

API key 只從這個檔案讀取，不會寫進 log。語音與文字會送往上述服務，詳見 `context/project/tasks/todo/privacy.md`。

### 操作

| 按鍵 | 作用 |
|---|---|
| 按住右 Option | 說話，放開後辨識並潤飾 |
| Cmd + 右 Option | 開始說話，再按一次右 Option 或 Enter 結束；說話時可以同時打字 |
| 說話時 ↑ / ↓ | 調整潤飾強度（0 不潤飾，10 最多） |
| 說話時單按左 Option | 切換打字用注音或英文 |
| Esc | 取消 |
| 校正時 ← / → / ↑ / ↓ | 移動與調整選取範圍；加 Shift 增減範圍，加 Cmd 微調位置 |
| 校正時右 Option | 列出選取範圍的候選字，按數字選字 |
| 校正時 Cmd+Z / Shift+Cmd+Z | 復原 / 重做 |
| 校正時 Enter | 送出 |

### 中英切換

單按右 Cmd 或左 Option 切換中文與英文，游標上方會顯示「中」或「EN」。按住超過 0.15 秒或與其他鍵一起按時不會切換。中文模式下不論 Caps Lock 開關都輸入注音；英文模式下 Caps Lock 照常切換大小寫。

改用其他鍵（以逗號分隔，可用 `leftOption`、`leftCommand`、`rightCommand`、`rightShift`；設為 `capsLock` 則回到小麥原本用 Caps Lock 切換的方式）：

```
defaults write io.github.zbryikt.inputmethod.DaMaiVoice ModeToggleKey leftOption
```

常駐顯示「中／EN」與 Caps Lock 狀態（綠點為開）：

```
defaults write io.github.zbryikt.inputmethod.DaMaiVoice ModeTipPersistent -bool true
```

### 開發

`Source/Tools/dev-install.sh` 會 build 並直接安裝到 `~/Library/Input Methods`。第一次安裝新的 bundle ID 仍需執行安裝程式一次。

## 系統需求

小麥注音輸入法可以在 macOS 13 以上版本運作。如果您要自行編譯小麥注音輸入法，或參與開發，您需要：

- macOS 26 或更高版本
- Xcode 26 或更高版本
- Python 3.9 (使用 Xcode 安裝後內附的就可以，也可使用 homebrew 等方式安裝)

## 開發流程

用 Xcode 開啟 `McBopomofo.xcodeproj`，選 "McBopomofo Installer" target，build 完之後直接執行該安裝程式，就可以安裝小麥注音。

第一次安裝完，日後程式碼或詞庫有任何修改，只要重複上述流程，再次安裝小麥注音即可。

要注意的是 macOS 可能會限制同一次 login session 能 kill 同一個輸入法 process 的次數（安裝程式透過 kill input method process 來讓新版的輸入法生效）。如果安裝若干次後，發現程式修改的結果並沒有出現，或甚至輸入法已無法再選用，只要登出目前帳號再重新登入即可。

## 社群公約

歡迎小麥注音用戶回報問題與指教，也歡迎大家參與小麥注音開發。

首先，請參考我們在「[常見問題](https://github.com/openvanilla/McBopomofo/wiki/常見問題)」中所提「[我可以怎麼參與小麥注音？](https://github.com/openvanilla/McBopomofo/wiki/常見問題#我可以怎麼參與小麥注音)」一節的說明。

我們採用了 GitHub 的[通用社群公約](https://github.com/openvanilla/McBopomofo/blob/master/CODE_OF_CONDUCT.md)。公約的中文版請參考[這裡的翻譯](https://www.contributor-covenant.org/zh-tw/version/1/4/code-of-conduct/)。

## 軟體授權

本專案採用 MIT License 釋出，使用者可自由使用、散播本軟體，惟散播時必須完整保留版權聲明及軟體授權（[詳全文](https://github.com/openvanilla/McBopomofo/blob/master/LICENSE.txt)）。
