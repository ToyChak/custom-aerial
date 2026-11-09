# custom-aerial

Play your own video on the macOS lock screen and desktop.

macOS Sonoma and later play an "aerial" video on the lock screen when an aerial is your wallpaper. This tool converts any video into the format the aerial player expects. Then it puts your video in place of the aerial you selected. It also includes an optional helper that keeps the display on while the Mac is locked and on power.

No admin rights and no changes to system security settings.

## Requirements

- macOS 14 Sonoma or later. Tested on macOS 26.
- Apple silicon. The converter uses the hardware HEVC 10-bit encoder.
- Xcode Command Line Tools (`xcode-select --install`), for `swiftc`.

## Use

1. Open **System Settings > Wallpaper** and select an aerial, for example Tahiti Coast. Wait until it has downloaded.
2. Run the converter:

   ```bash
   ./custom-aerial set ~/Movies/my-video.mov
   ```

   The conversion takes a few minutes. The first time, the tool backs up Apple's original video to `~/Library/Application Support/custom-aerial/backup/`.
3. Lock the screen with ctrl-cmd-Q.

Other commands:

```bash
./custom-aerial status       # which aerial is selected and whether it is replaced
./custom-aerial restore      # put Apple's original back
./custom-aerial lockawake on # keep the display on while locked, only on power
./custom-aerial lockawake off
```

## Why the conversion is necessary

If you copy a normal video over an aerial file, it plays once. On the next lock the screen goes black. The cause is how the aerial player works:

- On lock and unlock it speeds the video up and slows it down. To do that, it drops HEVC **temporal layers**.
- A video without temporal-layer data makes the player fail. The log shows `VideoSampleReadingErrors Code=4` ("noTemporalInfo").

`aerialize` (in `Sources/aerialize.swift`) writes the same format Apple uses:

- HEVC Main10 at 240 fps. Each source frame is repeated to fill the 240 fps timeline.
- Hierarchical temporal layers with a 15 fps base layer.
- A keyframe every second, so playback starts quickly after a lock.
- Video only, looped to at least 5 minutes. Use the second argument of `set` to change the minimum length in seconds.

## Lock Awake

About 30 seconds after you lock the Mac, `loginwindow` turns the display off. Lock Awake is a small background agent that prevents this:

- It holds a "prevent display sleep" power assertion only while the screen is locked **and** the Mac is on power.
- On unlock or on battery, it releases the assertion.

It runs as a LaunchAgent (`~/Library/LaunchAgents/local.customaerial.lockawake.plist`) and logs to `~/Library/Logs/LockAwake.log`.

## Limits

- A macOS update or an aerial re-download can restore Apple's file. Run `set` again if that happens.
- The video replaces one specific aerial. If you select a different aerial, run `set` again.
- Use only videos that you have the right to use.

## License

MIT
