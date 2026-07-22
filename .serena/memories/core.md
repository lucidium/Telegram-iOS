# Telegram-iOS — Core Project Memory

## Build System

- **Bazel** via `build-system/Make/Make.py` wrapper. No selective per-module build — only full `Telegram/Telegram` target.
- Build command (sim, debug): `source ~/.zshrc 2>/dev/null; python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir ~/telegram-bazel-cache build --configurationPath build-system/appstore-configuration.json --gitCodesigningRepository git@gitlab.com:peter-iakovlev/fastlanematch.git --gitCodesigningType development --gitCodesigningUseCurrent --buildNumber=1 --configuration=debug_sim_arm64`
- `--continueOnError` after `build` → bazel `--keep_going` (see all errors at once).
- Needs `TELEGRAM_CODESIGNING_GIT_PASSWORD` from `~/.zshrc`.
- Tests: `Make.py test --target //submodules/TextFormat:TextFormatTests` (single target). Default `Tests/AllTests` is broken (dangling TgVoipWebrtc ref).
- After rebuild: copy whole `.app` bundle over installed sim bundle (not `simctl install` — doesn't replace at same build number).

## Language Split

- **~21k C/C++/ObjC files** (.h/.m/.mm/.cpp/.cc) — clangd (cpp LSP)
- **~5.6k Swift files** (.swift) — sourcekit-lsp (swift LSP)
- Both language servers are active.

## Directory Layout

- `submodules/` — most code; each subdir is a separate library (TelegramUI, TelegramCore, Display, Postbox, etc.)
- `Telegram/` — app target, extensions (NotificationContent, NotificationService, Share, SiriIntents, Watch, WidgetKitWidget)
- `third-party/` — external dependencies
- `build-system/` — Make.py wrapper, Bazel rules, codesigning helpers
- `bazel-Telegram-iOS/` — symlink to Bazel execroot; **never index/modify**
- `docs/` — architecture docs (richtext-composer.md, instantpage-richtext.md, superpowers/postbox-refactor-log.md)

## Code Style

- PascalCase types, camelCase vars/methods
- Strong typing, explicit annotations where needed
- Standard Swift/ObjC formatting
- Document public APIs

## Architecture Highlights

- **Postbox → TelegramEngine refactor** in progress: eliminate `import Postbox` from consumers. See `docs/superpowers/postbox-refactor-log.md` and mem: `project_postbox_refactor_next_wave`.
- **RichTextEditor** (`submodules/TelegramUI/Components/RichTextEditor`): WYSIWYG chat composer, `ChatInputContent` model. See `docs/richtext-composer.md`.
- **InstantPage V2**: rich messages (headings, lists, tables, formulas). See `docs/instantpage-richtext.md`.
- **ChatHistoryListNodeImpl**: composes (not inherits) `ListViewImpl`. π rotation stays on wrapper. See `CLAUDE.md`.
- **View frame ownership**: views never set own frame; parent/layout system does.
- **WatchApp**: vendored snapshot from `tgwatch` repo; do not hand-edit.
- **TelegramCore** never imports UIKit/Display (shared with Mac codebase).

## Submodule Memory References

- Postbox refactor next wave: `mem:project_postbox_refactor_next_wave`
