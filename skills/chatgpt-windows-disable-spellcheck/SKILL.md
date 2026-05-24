---
name: chatgpt-windows-disable-spellcheck
description: Use when a user wants to disable red spellcheck underlines in the ChatGPT Windows Desktop/Microsoft Store app, especially when Czech or other non-English text is underlined despite Windows and Edge spellcheck being disabled. This skill edits the ChatGPT app's local Preferences file to clear the spellcheck dictionaries. Do not use for browser ChatGPT, mobile apps, or unrelated spellcheck problems.
---

# Disable spellcheck in the ChatGPT Windows app

## Purpose

The ChatGPT Windows Desktop/Microsoft Store app may keep its own Chromium/WebView-style `Preferences` file. Even when Windows typing settings and Microsoft Edge spellcheck are disabled, the app can still show red spellcheck underlines because a dictionary is configured inside this app-specific Preferences file.

The proven workaround is to clear the `dictionaries` entry in the ChatGPT Preferences file, changing for example:

```json
"dictionaries":["en-US"]
```

to:

```json
"dictionaries":[""]
```

This disables spellchecking in the ChatGPT Windows app without changing global Windows or Edge settings.

## When to use

Use this skill when the user says any of the following:

- ChatGPT Windows app underlines Czech, simplified English, or other text in red.
- Windows spellcheck is already disabled but ChatGPT still underlines words.
- Edge spellcheck is already disabled but ChatGPT still underlines words.
- The Codex app or browser behaves correctly but ChatGPT Windows app does not.
- The user wants to remove/disable spellcheck specifically in the ChatGPT Store/Desktop app.

Do not use this skill for:

- ChatGPT in Chrome, Edge, Firefox, or Safari.
- iOS, Android, or macOS app issues.
- General autocorrect settings unrelated to the ChatGPT Windows app.

## Manual fix

1. Completely close the ChatGPT app.
2. Open Task Manager and end any remaining `ChatGPT` processes.
3. Open this folder:

```text
%LOCALAPPDATA%\Packages\OpenAI.ChatGPT-Desktop_2p2nqsd0c76g0\LocalCache\Roaming\ChatGPT
```

If the exact package suffix differs, search under:

```text
%LOCALAPPDATA%\Packages
```

for a folder matching:

```text
OpenAI.ChatGPT-Desktop_*
```

4. Find the file named `Preferences`.
5. Make a backup copy, for example `Preferences.backup`.
6. Open `Preferences` in Notepad, VS Code, or another text editor.
7. Search for `"dictionaries"`.
8. Change the configured dictionary to an empty string array. Example:

```json
"dictionaries":["en-US"]
```

to:

```json
"dictionaries":[""]
```

9. Save the file.
10. Reopen ChatGPT and test by typing Czech or another previously underlined language.

## Scripted fix

Prefer the bundled script when the user wants a repeatable method:

```powershell
.\scripts\disable-chatgpt-spellcheck.ps1
```

The script:

- closes ChatGPT,
- finds the ChatGPT Desktop package folder,
- backs up the `Preferences` file with a timestamp,
- replaces the first `"dictionaries":[...]` entry with `"dictionaries":[""]`,
- writes the updated Preferences file back.

If the user wants to try an empty array instead of an empty string dictionary, run:

```powershell
.\scripts\disable-chatgpt-spellcheck.ps1 -UseEmptyArray
```

Use `-UseEmptyArray` only as a fallback. The known working forum workaround is `"dictionaries":[""]`.

## Restore backup

If the user wants to undo the change, run:

```powershell
.\scripts\restore-chatgpt-preferences-backup.ps1
```

This restores the latest timestamped backup created by the disable script.

## Troubleshooting

- If the red underlines return after an app update, rerun the script.
- If no `Preferences` file is found, ask the user to search under `%LOCALAPPDATA%\Packages` for `OpenAI.ChatGPT-Desktop_*` and confirm the installed package path.
- Do not recommend WebView2 flags such as `--disable-spell-checking` as a primary fix. They are not a reliable or documented solution for this app issue.
- Do not keep changing Windows Typing or Edge settings once the user has confirmed those are already disabled.
- Avoid making the `Preferences` file read-only unless the user explicitly asks for an aggressive workaround, because it may break unrelated ChatGPT app preferences.
