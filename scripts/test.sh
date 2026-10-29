set -eu
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
mkdir -p build
xcrun clang++ -std=c++20 -O1 -g -fsanitize=undefined -fno-sanitize-recover=all Sources/test.cpp -o build/audio-tests
perl -e 'alarm 10; exec @ARGV' -- build/audio-tests
