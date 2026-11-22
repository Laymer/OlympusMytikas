# Contributing to Olympus Mytikas

Report a bug using the bug report form on the repository’s Issues tab. Include the addon version from the shared window and the WoW build from the login screen.

## Check a change

Fork the repository and clone your fork. Install Git, Lua 5.1 (including its compiler) and Python 3.10 or later. On Ubuntu 24.04, run the following commands from your checkout.

```sh
sudo apt-get update
sudo apt-get install git lua5.1 python3
./scripts/check.sh
```

The command runs the same Lua syntax, gameplay, shared-window and Python packaging and publishing checks as pull request CI. The publishing tests use fixtures and run without release credentials.

## Try the addon in Forever

Exit WoW and back up your existing `_forever_/Interface/AddOns/OlympusMytikas` folder. Copy the checkout’s inner `OlympusMytikas` folder into `_forever_/Interface/AddOns`. The TOC should sit directly inside the installed addon folder. Keep the `WTF` directory in place to exercise the upgrade with your saved settings. Enable Olympus Mytikas at character selection, enter the world, open the shared window and exercise the changed command or control. Restore your backup after testing.

Keep Lua readable. Blizzard requires visible addon code and prohibits excessive chat use. In this addon a player click, key press or slash command starts a recruitment post. Echo handlers and timers only observe delivery. [Blizzard UI Add-On Development Policy](https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534/1)

Open a pull request with the player-visible change and your verification results. Maintainers use the first answer to prepare release notes.
