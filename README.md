# Sprint

A local macOS app and CLI for deciding what fits in a sprint and preparing standup and planning updates.

## Install

Requires macOS, the Xcode command-line tools, and Python 3 for the CLI.

```sh
make install
open ~/Applications/Sprint.app
```

Add `~/.local/bin` to your PATH if `sprint` is unavailable. Quit a running copy before reinstalling.

## Keyboard shortcuts

- **Option-J** opens Ticket Decision. Control-Tab and Control-Shift-Tab cycle through stories. Enter copies the story key.
- **Option-D** opens Daily Standup. Control-Shift-Tab goes to an earlier standup, and Control-Tab moves forward.
- **Option-P** opens Planning and the weekly budget.

## CLI

Use `sprint --help` to discover commands. Writes operate on the same local data as the app.

```sh
sprint ticket create SAMPLE-1 --title "Validate import" --story-points 2
sprint --ticket SAMPLE-1 task add tests --title "Test invalid rows" --estimate-minutes 90
sprint --ticket SAMPLE-1 task start tests
sprint --ticket SAMPLE-1 task pause tests
sprint --ticket SAMPLE-1 notes set daily --body "Validated the import path."
sprint --ticket SAMPLE-1 ticket view --json
```

## Data

Tickets and speaking notes stay in `~/Library/Application Support/Sprint`. This repository contains source and build instructions. The app does not connect to Jira.
