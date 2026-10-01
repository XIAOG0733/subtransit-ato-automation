# Subtransit ATO (visual-only macOS prototype)

This repository contains a conservative, screen-reading ATO prototype for **Subtransit Drive**. It uses macOS Vision OCR and CoreGraphics screenshots; it does not read game memory or use an API.

> Use only in the game and only where automation is permitted. This is an experimental prototype, not real railway-control software.

## Controls

- **⌘⇧D** — enable ATO (only arms the controller; it does not depart immediately)
- **⌘⇧E** — disable/pause ATO without terminating the program
- **⌘⇧Q** — quit

The controller refuses to apply traction when the OCR result does not positively identify closed doors. OCR confidence is deliberately conservative.

## Build and run

Requirements: macOS 13+, Xcode Command Line Tools, and Accessibility permission for the terminal/application.

```sh
make
./bin/subtransit-ato
```

Grant the binary **Screen Recording** permission and **Accessibility** permission in System Settings → Privacy & Security. Start the game first and keep its window visible.

The default geometry is based on a 2880×1880 screenshot. Set `SCREEN_W` and `SCREEN_H` if the game uses another resolution. The program currently OCRs the complete display for robustness; the constants in `ato.m` are ready for later region-specific tuning.
