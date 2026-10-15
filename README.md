https://github.com/user-attachments/assets/c1bcc1ab-702e-4376-a81b-91391e8bb858
# GazeBreak

A lightweight, native macOS focus timer. Pick a work duration, hide the app, and get a fullscreen nudge to rest your eyes when time is up. Built with AppKit — no dependencies.

## Features

- **Flexible timers** — type any work/rest duration (Seconds or Minutes). Invalid input is rejected with a message, valid choices persist across launches.
- **Custom break screen** — your own title and message on a fullscreen, always-on-top overlay with a live countdown, progress bar, and Skip button.
- **True background focus mode** — the Settings window animates away and the app leaves the Dock while the timer runs, then restores itself.
  
## Install

Download `GazeBreak.app, move to Applications. On first launch open then click done, go to settings privacy and security and scroll
down and click open anyway

## Use

1. Set work time (`10` Seconds to test, `20` Minutes for real use) and rest time.
2. Edit the break title/message if you like.
3. **Start Focus Session** → window hides, timer runs.
4. Break screen appears at zero, closes itself when rest ends.
