#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

luac5.1 -p OlympusMytikas/*.lua OlympusMytikas/libs/*.lua
lua5.1 tests/shared-window.lua
lua5.1 tests/chat-version.lua
lua5.1 tests/gameplay.lua
python3 -m unittest discover -s tests -p 'test_*.py' -v
