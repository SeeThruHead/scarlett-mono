set -eu
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
mkdir -p 'build/Scarlett Mono.app/Contents/MacOS'
xcrun clang++ -std=c++20 -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=14.0 -framework AppKit -framework AVFoundation -framework CoreAudio Sources/main.mm -o 'build/Scarlett Mono.app/Contents/MacOS/ScarlettMono'
cp Info.plist 'build/Scarlett Mono.app/Contents/Info.plist'
python3 scripts/sign.py
