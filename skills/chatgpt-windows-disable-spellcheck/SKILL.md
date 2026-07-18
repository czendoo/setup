---
name: chatgpt-windows-disable-spellcheck
description: Use when a user wants to disable red spellcheck underlines in the Codex or ChatGPT Windows/Microsoft Store app, especially when Czech or other non-English text is underlined despite Windows and Edge spellcheck being disabled. This skill clears the spellcheck dictionaries in every relevant app Preferences file. Do not use for browser ChatGPT, mobile apps, or unrelated spellcheck problems.
---

# Disable spellcheck in the Codex or ChatGPT Windows app

## Purpose

The current Codex Windows/Microsoft Store app (and the legacy ChatGPT Desktop app) may keep multiple Chromium/WebView-style `Preferences` files. Even when Windows typing settings and Microsoft Edge spellcheck are disabled, the app can still show red spellcheck underlines because a dictionary is configured in one or more of those files.

The proven workaround is to clear the `dictionaries` entry in **every** Codex or ChatGPT `Preferences` file that contains it, changing for example:

```json
"dictionaries":["en-US"]
```

to:

```json
"dictionaries":[]
```

An empty list is required; do not replace the configured dictionary with an empty-string item such as `[""]`. This disables spellchecking in the Codex or ChatGPT Windows app without changing global Windows or Edge settings.

## When to use

Use this skill when the user says any of the following:

- ChatGPT Windows app underlines Czech, simplified English, or other text in red.
- Codex Windows app underlines Czech, simplified English, or other text in red.
- Windows spellcheck is already disabled but ChatGPT still underlines words.
- Edge spellcheck is already disabled but ChatGPT still underlines words.
- The user wants to remove/disable spellcheck specifically in the Codex or ChatGPT Store/Desktop app.

Do not use this skill for:

- ChatGPT in Chrome, Edge, Firefox, or Safari.
- iOS, Android, or macOS app issues.
- General autocorrect settings unrelated to the ChatGPT Windows app.

## Manual fix

1. Completely close the affected app.
2. Open Task Manager and end any remaining `Codex` or `ChatGPT` processes.
3. For the current Codex app, open this folder:

```text
%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0
```

For the legacy ChatGPT app, use:

```text
%LOCALAPPDATA%\Packages\OpenAI.ChatGPT-Desktop_2p2nqsd0c76g0\LocalCache\Roaming\ChatGPT
```

If the exact package suffix differs, search under:

```text
%LOCALAPPDATA%\Packages
```

for folders matching either:

```text
OpenAI.Codex_*
OpenAI.ChatGPT-Desktop_*
```

4. Find **all** files named `Preferences` within the matching package folder, including ones in nested profiles or cache directories. Do not stop after the first result.
5. For every `Preferences` file that contains `"dictionaries"`, make a backup copy, for example `Preferences.backup`.
6. Open each of those files in Notepad, VS Code, or another text editor.
7. Search for `"dictionaries"`.
8. Change each configured dictionary list to an empty array. Example:

```json
"dictionaries":["en-US"]
```

to:

```json
"dictionaries":[]
```

9. Save every edited file.
10. Reopen the affected app and test by typing Czech or another previously underlined language.

## Scripted fix

Before using the bundled script, inspect its current behavior. It must discover and update **all** matching `Preferences` files, rather than selecting a single package or file. If it only updates one file, use the manual process above or update the script before relying on it.

When a compatible version of the script is available, use:

```powershell
.\scripts\disable-chatgpt-spellcheck.ps1
```

The script:

- closes the affected Codex or ChatGPT app,
- finds every relevant Codex or ChatGPT `Preferences` file,
- backs up every file it will change with a timestamp,
- replaces each `"dictionaries":[...]` entry with `"dictionaries":[]`,
- writes every updated Preferences file back, and
- reports all paths it modified.

## Restore backup

If the user wants to undo the change, run:

```powershell
.\scripts\restore-chatgpt-preferences-backup.ps1
```

This restores the latest timestamped backup created by the disable script.

## Troubleshooting

- If red underlines remain after the first pass, search the package folder again for additional `Preferences` files and make sure each `dictionaries` list is `[]`.
- If the red underlines return after an app update, repeat the all-files process.
- If no `Preferences` file is found, ask the user to search under `%LOCALAPPDATA%\Packages` for `OpenAI.Codex_*` (or, for the legacy app, `OpenAI.ChatGPT-Desktop_*`) and confirm the installed package path.
- Do not recommend WebView2 flags such as `--disable-spell-checking` as a primary fix. They are not a reliable or documented solution for this app issue.
- Do not keep changing Windows Typing or Edge settings once the user has confirmed those are already disabled.
- Avoid making the `Preferences` file read-only unless the user explicitly asks for an aggressive workaround, because it may break unrelated ChatGPT app preferences.
