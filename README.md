# smudge

Multi-touch support for external USB touchscreens on macOS.

macOS recognizes many touch monitors only as a mouse: a tap lands on the wrong
display as a click (sometimes a right click), and there are no gestures. Even
macOS 27, which brings touch to the MacBook Pro's own display, does not deliver
touches from external panels to apps. smudge reads the panel directly and turns
touches into regular input events.

| Gesture | Result |
| --- | --- |
| Tap / double tap | Click / double click |
| One finger drag | Drag (select text, move windows) |
| Two finger drag | Scroll, with momentum |
| Two finger tap | Right click |
| Pinch | Magnify (experimental) |

The pointer jumps to the finger, as with touchscreen pointer emulation on
Windows and Linux. With `--return-cursor` it goes back to where it was after
each gesture if it started on another display.

## How it works

Many panels start in mouse-emulation mode and only switch to multi-touch once
the host behaves like the Windows touch driver. smudge parses the panel's HID
report descriptor, sets the Input Mode feature to multi-touch where the panel
has one and reads the Windows certification blob (`0xFF00:0xC5`), which is what
flips the panels that have no Input Mode. It then decodes the digitizer reports
(up to ten contacts), maps them onto the chosen display and posts synthetic
events through Quartz. Panels are switched again on reconnect and after sleep.

Tested on macOS 27.2 with an ILITEK touch panel (`222a:0001`). Any HID
touchscreen that works on Windows should behave the same way; reports for
other panels are welcome.

## Install

### home-manager

```nix
{
  inputs.smudge.url = "github:dfjay/smudge";

  # in a home-manager configuration
  imports = [ inputs.smudge.homeModules.default ];

  services.smudge = {
    enable = true;
    display = "SU13TO";         # optional: name of the touch display; first external one by default
    returnCursor = true;        # optional
    signingIdentity = "My Code Signing"; # optional, see below
  };
}
```

This runs smudge as a launchd agent at login. It idles until a touchscreen is
connected.

### nix

```sh
nix run github:dfjay/smudge -- --help
```

### From source

```sh
swift build -c release
.build/release/smudge --list
```

## Usage

```
smudge [--display NAME] [--return-cursor] [--verbose] [--list]

  -d, --display NAME  map touches to the display whose name contains NAME
                      (default: first external display)
  -r, --return-cursor put the pointer back after a gesture
                      if it was on another display
  -v, --verbose       log recognized gestures
  -l, --list          list displays and touchscreens, then exit
```

## Permissions

smudge needs **Input Monitoring** (to read the panel) and **Accessibility**
(to post events). It asks for both on first launch and waits until they are
granted in System Settings → Privacy & Security.

macOS ties these grants to the binary's code signature. Nix builds are ad-hoc
signed, so every rebuild would need them granted again. To avoid that, create
a self-signed certificate once (Keychain Access → Certificate Assistant →
Create a Certificate…, Identity Type *Self-Signed Root*, Certificate Type
*Code Signing*) and set `services.smudge.signingIdentity` to its name. The
module then signs a stable copy of the binary on activation and the grants
survive rebuilds.

## Limitations

- Touches become mouse, scroll and gesture events, not real touch events:
  apps using the macOS 27 touch APIs do not see them.
- Pinch relies on undocumented gesture event fields and may not work everywhere.
- One touchscreen display at a time; rotated displays are not handled.

## License

[MIT](LICENSE)
