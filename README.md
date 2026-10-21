<p align="center">
  <img src="Assets/banner.svg" alt="Strobe — Rapid Serial Visual Presentation" width="100%" />
</p>

<h1 align="center">Read more. Move less.</h1>

<p align="center">
  <b>Strobe</b> is a free, open-source speed reader for iPhone, iPad, and Mac.
  Read books, papers, and articles one word at a time, with adjustable speed,
  word timing, and a searchable full-text view.
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/strobe-speed-reading/id6759187873">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160" />
  </a>
</p>

<p align="center">
  <a href="https://strobefast.app">
    <img src="https://img.shields.io/badge/Website-strobefast.app-FF3B30?style=for-the-badge" alt="Website" />
  </a>
  <a href="https://github.com/Cuzeth/Rapid-Serial-Visual-Presentation/actions/workflows/tests.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/Cuzeth/Rapid-Serial-Visual-Presentation/tests.yml?style=for-the-badge&label=Tests" alt="Tests" />
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-Apache_2.0-green?style=for-the-badge" alt="License" />
  </a>
  <img src="https://img.shields.io/badge/Platform-iOS_17+_·_macOS_14+-lightgrey?style=for-the-badge&logo=apple" alt="Platform" />
</p>

<p align="center">
  <img src="AppStore/Screenshots/iPhone%206.9-inch/01-one-word.png" width="24%" alt="Reading Moby-Dick one word at a time, with the word's red focus letter in the center of the screen" />
  <img src="AppStore/Screenshots/iPhone%206.9-inch/03-hold-to-read.png" width="24%" alt="Holding to read, with a control for changing speed while the words play" />
  <img src="AppStore/Screenshots/iPhone%206.9-inch/05-while-reading.png" width="24%" alt="The previous and next words shown faintly beside the current word, with an open quote above it" />
  <img src="AppStore/Screenshots/iPhone%206.9-inch/08-full-text.png" width="24%" alt="The full text of Moby-Dick with the current word highlighted below a search field" />
</p>

## How it works

Strobe uses **Rapid Serial Visual Presentation (RSVP)** to display words in sequence. Each word aligns on a highlighted letter, called the **Optimal Recognition Point**, at a fixed position on the screen.

Set the pace from **100 to 1,000 words per minute** and adjust it while you read.

## Built for focused reading

### Hold to read. Let go to pause.

Press and hold anywhere on the screen to read, and lift your finger to stop. Slide up or down mid-sentence to change speed on the fly, and swipe sideways while paused to step word by word. Prefer hands-free? Turn off Hold to Read and tap to play instead.

### Adjustable word timing

Add time for long words and choose pause lengths for sentence ends, commas, dashes, ellipses, and closing quotes. Acronyms and hyphenated compounds receive extra time automatically. Complexity Timing adjusts for common words, rare words, and names. You can also add a blank interval between sentences.

### Context and chapter titles

Keep the previous and next words beside the one you're reading, and see an open quote or parenthesis hover above until it closes. Each new chapter shows its title as you reach it.

### The whole page, one tap away.

Open the full text with your place highlighted. Search for any word or phrase, jump between matches, and tap any word to pick up reading from there.

### Fonts and text colors

Choose from seven typefaces, including Fraunces and JetBrains Mono, with adjustable text size. Four text colors (Bright, Soft, Sepia, and Night) tone down the word and its red letter, and a true black background is made for reading in the dark. Every document remembers its own speed.

### Made for the keyboard.

On a Mac, or an iPad with a keyboard: <kbd>Space</kbd> reads and pauses, <kbd>←</kbd> <kbd>→</kbd> step through words, <kbd>Esc</kbd> goes back, <kbd>⌘N</kbd> starts a new text, and <kbd>⌘O</kbd> imports a file.

## Bring what you already read

<p align="center">
  <img src="AppStore/Screenshots/Mac/02-library.png" width="100%" alt="The Strobe library on the Mac: a Continue Reading banner above a grid of generated book covers" />
</p>

Import EPUB, PDF, plain-text, and Markdown files from Files or with drag and drop, or paste in an article and see its word count and reading time before you start. Every book gets its own cover, the one you're reading waits at the top, and Strobe picks up at your exact word.

- **Share from anywhere.** Share an article from Safari, a link, or selected text from any app to Strobe, and it's waiting in your library without the page's menus and ads.
- **Chapters at a glance.** EPUB tables of contents and PDF bookmarks become chapters, each with its reading time at your speed.
- **Clean text.** Page numbers, running headers, and footers are stripped on import.
- **Not just English.** Chinese, Japanese, and Korean text is split into words automatically, and Arabic keeps its connected letterforms.

DRM-protected EPUBs and password-protected PDFs can't be imported.

## Private by design

Strobe processes documents and stores your library on your device. It requires no account and includes no ads or analytics.

## Free and open source

Strobe is free, with no subscription or in-app purchases. The source is available under the Apache 2.0 license. If it earns a place in your reading routine, you can [support development on Buy Me a Coffee](https://buymeacoffee.com/cuzeth) or give the repo a star.

---

## Under the hood

Strobe is SwiftUI and SwiftData with no third-party dependencies.

- **Import:** EPUBs are unzipped and read from their package manifest, with chapters from nested tables of contents and a DRM check up front. PDFs bring their bookmarks along.
- **Sharing:** a Share extension reads the article out of the Safari page you're on, or loads a shared link in an offscreen web view, and hands the text to the app through an App Group.
- **Tokenizer:** rejoins words hyphenated across line breaks, splits words joined by em dashes, keeps `10:30 PM` and `44 B.C.` in one piece, and segments CJK text with `NLTokenizer`.
- **Timing:** word length, punctuation, acronyms, compounds, and per-word complexity scores (computed once at import with the NaturalLanguage framework) all shape how long each word stays up.
- **Tests:** 500+ Swift Testing cases, run on an iOS simulator and on macOS in CI.

## Build it yourself

1. Open `Strobe.xcodeproj` in Xcode 27.
2. Pick the **Strobe** scheme and an iPhone, iPad, or Mac to run on.
3. To run on your own device or Mac, choose your team under **Signing & Capabilities** for the **Strobe** and **StrobeShare** targets. App Group IDs are unique across teams, so also replace `group.com.abdeen.strobe` in `SharedContainer.swift` and both `.entitlements` files with a group of your own.

There are no packages to resolve and no API keys to add.

## Contributing

Issues and pull requests are welcome. Keep changes focused, include tests when you can, and run the test suite before opening a PR.

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
