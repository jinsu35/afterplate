<p align="center"><b>English</b> · <a href="build.ko.md">한국어</a></p>

# Build Afterplate yourself

The source is here so you can check what the app does, and run a copy you built yourself instead of the one in Releases. This page goes from a Mac with nothing installed to a working `Afterplate.app`.

It takes about 20 minutes, most of it downloads. You don't need an Apple developer account.

## Let an AI do it

Most of this is typing commands, which a coding agent (Claude Code, Codex, Cursor…) does well. The repo has [AGENTS.md](../AGENTS.md), the same steps written for an agent, each with how to tell it worked. Paste this into your agent:

> Build the Mac app from https://github.com/jinsu35/afterplate for me. Follow AGENTS.md in that repo, step by step, including the photo model. Don't change the source; just build it. Ask me before anything that needs my password. At the end, tell me where Afterplate.app is.

The agent will need you for the parts only you can do: your Mac password for Homebrew, and the Photos permission when the app first opens.

## 1. What you need

- A Mac with macOS 14 or later.
- **Xcode** from the App Store (tested with Xcode 26). Open it once after installing, so it can finish setting up.
- **Homebrew**, from [brew.sh](https://brew.sh). Paste the one line from that page into Terminal.

Then, in Terminal:

```bash
xcode-select --install          # command-line tools; skip if it says they are installed
brew install xcodegen uv git
```

`xcodegen` makes the Xcode project from `mac/project.yml`. `uv` is only for the photo model in step 3.

## 2. Get the source

```bash
mkdir -p ~/Developer && cd ~/Developer   # or any folder outside ~/Documents and ~/Desktop
git clone https://github.com/jinsu35/afterplate.git
cd afterplate
```

Keep it out of `~/Documents` and `~/Desktop` if iCloud Drive syncs them: iCloud marks every file there, and macOS then refuses to sign the app.

## 3. The photo model (optional, recommended)

The model that tells a meal photo from food merely being in the frame is not in the source. Make your own copy:

```bash
mac/model/get-model.sh
```

This downloads [SigLIP](https://huggingface.co/google/siglip-base-patch16-224) (Google, Apache 2.0, about 800MB) from Hugging Face and converts it to Core ML on your Mac. It ends with `saved …/SigLIPImage.mlpackage; prompt embeddings match the model: 1.0000`.

Without it the app still works, sorting photos with Apple Vision alone, and misses some meals: a table laid outdoors, a bowl of 빙수.

## 4. Build

To build and open it straight away:

```bash
mac/run.sh
```

To build an app you can keep in Applications:

```bash
cd mac
xcodegen generate
xcodebuild -project Afterplate.xcodeproj -scheme Afterplate -configuration Release \
  -derivedDataPath ~/Library/Developer/Afterplate build
open ~/Library/Developer/Afterplate/Build/Products/Release
```

Drag **Afterplate** from that folder into Applications. The first time, open it with right-click › **Open**: macOS asks once about an app that was not downloaded from a known developer.

The build is signed "ad hoc", with no certificate. It runs the same, but macOS treats every rebuild as a new app and asks for Photos access again. To stop that, put your own development certificate in `mac/Signing.local.xcconfig` (not checked in):

```
CODE_SIGN_IDENTITY = Apple Development: Your Name (TEAMID)
```

## 5. First run

1. Allow Photos access. Photos are read in place, never copied or uploaded.
2. Pick the AI: ChatGPT or Grok on a paid plan, or Claude with your own API key.
3. Place search goes through Afterplate's proxy by default, with a weekly share per Mac. To use your own Google key instead, see [google-maps-key.md](google-maps-key.md) and add it in **Settings › Place search**.

[What leaves your Mac](../README.md#what-leaves-your-mac) lists everything the app sends anywhere.

## Checking the app from Releases

Builds are not byte-for-byte reproducible, so a Releases download cannot be matched to this source by hash. What you can check is who signed it and that Apple notarized it:

```bash
spctl -a -vv /Applications/Afterplate.app       # source=Notarized Developer ID
codesign -dv /Applications/Afterplate.app 2>&1 | grep -E "Authority|TeamIdentifier"
```

If you want to be sure of what runs, build it yourself as above.

## When something goes wrong

- **`xcodegen: command not found`**: run `brew install xcodegen`.
- **`xcodebuild: error: … requires Xcode`**: open Xcode once, then run `sudo xcode-select -s /Applications/Xcode.app`.
- **"resource fork, Finder information, or similar detritus not allowed"**: the source is in a folder iCloud syncs. Move it, for example to `~/Developer`.
- **No Photos permission prompt, or the first screen after every build**: that's the ad hoc signature. See the end of step 4.
- **`get-model.sh` fails while downloading**: run it again. Downloads resume.
