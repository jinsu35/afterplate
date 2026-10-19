<p align="center"><a href="build.md">English</a> · <b>한국어</b></p>

# Afterplate 직접 빌드하기

소스를 공개한 건, 앱이 무슨 일을 하는지 직접 확인하고 Releases의 앱 대신 내가 빌드한 앱을 쓸 수 있게 하려는 거예요. 이 문서는 아무것도 안 깔린 맥에서 `Afterplate.app`이 실행되기까지를 다뤄요.

20분쯤 걸리고, 대부분은 내려받는 시간이에요. Apple 개발자 계정은 필요 없어요.

## AI에게 맡기기

대부분 명령어를 입력하는 일이라 코딩 에이전트(Claude Code, Codex, Cursor…)가 잘해요. 리포에 있는 [AGENTS.md](../AGENTS.md)에는 같은 단계가 에이전트용으로 적혀 있고, 단계마다 성공했는지 확인하는 방법이 있어요. 에이전트에게 이렇게 붙여 넣으세요.

> https://github.com/jinsu35/afterplate 의 맥 앱을 빌드해 줘. 그 리포의 AGENTS.md를 단계별로 따라 하고, 사진 모델도 받아. 소스는 고치지 말고 빌드만 해. 내 비밀번호가 필요한 일은 하기 전에 물어봐. 끝나면 Afterplate.app이 어디 있는지 알려 줘.

에이전트가 대신할 수 없는 건 두 가지예요. Homebrew 설치에 필요한 맥 비밀번호, 그리고 앱을 처음 열 때 사진 접근을 허용하는 것.

## 1. 준비물

- macOS 14 이상인 맥
- App Store의 **Xcode** (Xcode 26에서 확인했어요). 설치한 뒤 한 번 열어서 설정을 끝내 두세요.
- **Homebrew**: [brew.sh](https://brew.sh)에 있는 한 줄을 터미널에 붙여 넣으면 깔려요.

그다음 터미널에서:

```bash
xcode-select --install          # 커맨드라인 도구. 이미 깔려 있다고 나오면 넘어가요
brew install xcodegen uv git
```

`xcodegen`은 `mac/project.yml`로 Xcode 프로젝트를 만들어요. `uv`는 3단계의 사진 모델에만 써요.

## 2. 소스 받기

```bash
mkdir -p ~/Developer && cd ~/Developer   # ~/Documents, ~/Desktop 밖이면 어디든 돼요
git clone https://github.com/jinsu35/afterplate.git
cd afterplate
```

iCloud Drive가 `~/Documents`와 `~/Desktop`을 동기화하고 있으면 그 밖에 두세요. iCloud가 거기 있는 파일마다 표시를 붙이는데, 그러면 macOS가 앱 서명을 거부해요.

## 3. 사진 모델 (선택이지만 추천)

식사 사진과 그냥 음식이 찍힌 사진을 가려내는 모델은 소스에 없어요. 직접 만드세요.

```bash
mac/model/get-model.sh
```

Hugging Face에서 [SigLIP](https://huggingface.co/google/siglip-base-patch16-224)(Google, Apache 2.0, 약 800MB)을 받아 내 맥에서 Core ML로 바꿔요. 마지막 줄에 `saved …/SigLIPImage.mlpackage; prompt embeddings match the model: 1.0000`이 나오면 성공이에요.

모델이 없어도 앱은 돌아가요. 다만 Apple Vision만으로 사진을 골라서, 야외에 차린 상이나 빙수 한 그릇 같은 식사를 놓쳐요.

## 4. 빌드

바로 빌드해서 열어 보려면:

```bash
mac/run.sh
```

응용 프로그램 폴더에 두고 쓸 앱을 만들려면:

```bash
cd mac
xcodegen generate
xcodebuild -project Afterplate.xcodeproj -scheme Afterplate -configuration Release \
  -derivedDataPath ~/Library/Developer/Afterplate build
open ~/Library/Developer/Afterplate/Build/Products/Release
```

열린 폴더에서 **Afterplate**를 응용 프로그램 폴더로 끌어다 놓으세요. 처음 한 번은 오른쪽 클릭 › **열기**로 여세요. 확인된 개발자에게서 받은 앱이 아니라서 macOS가 한 번 물어봐요.

이 빌드는 인증서 없이 "임시 서명(ad hoc)"으로 서명돼요. 똑같이 돌아가지만, macOS가 다시 빌드할 때마다 새 앱으로 보고 사진 접근을 다시 물어요. 그게 싫으면 내 개발 인증서를 `mac/Signing.local.xcconfig`에 넣으세요(리포에는 안 올라가요).

```
CODE_SIGN_IDENTITY = Apple Development: Your Name (TEAMID)
```

## 5. 처음 실행

1. 사진 접근을 허용하세요. 사진은 그 자리에서 읽기만 하고, 복사하거나 올리지 않아요.
2. AI를 고르세요. 유료 요금제의 ChatGPT나 Grok, 또는 내 API 키로 쓰는 Claude.
3. 장소 검색은 기본으로 Afterplate 프록시를 거치고, 맥마다 일주일 몫이 있어요. 내 Google 키를 쓰려면 [google-maps-key.ko.md](google-maps-key.ko.md)를 보고 **설정 › 장소 검색**에 넣으세요.

앱이 어디로 무엇을 보내는지는 [무엇이 맥 밖으로 나가나요](../README.ko.md#무엇이-맥-밖으로-나가나요)에 다 적어 뒀어요.

## Releases의 앱 확인하기

빌드는 바이트 단위로 똑같이 나오지 않아서, Releases에서 받은 앱을 해시로 이 소스와 맞춰 볼 수는 없어요. 대신 누가 서명했는지, Apple 공증을 받았는지는 확인할 수 있어요.

```bash
spctl -a -vv /Applications/Afterplate.app       # source=Notarized Developer ID
codesign -dv /Applications/Afterplate.app 2>&1 | grep -E "Authority|TeamIdentifier"
```

무엇이 돌아가는지 확실히 알고 싶으면 위처럼 직접 빌드하세요.

## 문제가 생기면

- **`xcodegen: command not found`**: `brew install xcodegen`을 실행하세요.
- **`xcodebuild: error: … requires Xcode`**: Xcode를 한 번 연 다음 `sudo xcode-select -s /Applications/Xcode.app`을 실행하세요.
- **"resource fork, Finder information, or similar detritus not allowed"**: 소스가 iCloud가 동기화하는 폴더에 있어요. `~/Developer` 같은 곳으로 옮기세요.
- **사진 접근을 안 묻거나, 빌드할 때마다 첫 화면이 나와요**: 임시 서명 때문이에요. 4단계 끝을 보세요.
- **`get-model.sh`가 받다가 실패해요**: 다시 실행하세요. 받던 데서 이어서 받아요.
