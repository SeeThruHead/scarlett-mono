#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#include <ranges>
#include <memory>
#include <stdexcept>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include "Audio.h"

static NSString *const bundleID = @"com.shanekeulen.ScarlettMono";
static NSString *const inputName = @"Scarlett 8i6 USB";
static NSString *const outputName = @"BlackHole 2ch";

static AudioObjectPropertyAddress property(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}

static void require(OSStatus status, const char *operation) {
    if (status != noErr) throw std::runtime_error(std::string(operation) + " (Core Audio " + std::to_string(status) + ")");
}

template <typename T> static T readValue(AudioObjectID id, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    T value{};
    UInt32 size = sizeof(value);
    const auto address = property(selector, scope);
    require(AudioObjectGetPropertyData(id, &address, 0, nullptr, &size, &value), "Read device property");
    return value;
}

static NSString *readString(AudioObjectID id, AudioObjectPropertySelector selector) {
    return CFBridgingRelease(readValue<CFStringRef>(id, selector));
}

template <typename T> static std::vector<T> readArray(AudioObjectID id, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    const auto address = property(selector, scope);
    UInt32 size = 0;
    require(AudioObjectGetPropertyDataSize(id, &address, 0, nullptr, &size), "Read property size");
    std::vector<T> values(size / sizeof(T));
    if (size == 0) return {};
    const auto result = AudioObjectGetPropertyData(id, &address, 0, nullptr, &size, values.data());
    require(result, ("Read array on device " + std::to_string(id) + " selector " + std::to_string(selector)).c_str());
    values.resize(size / sizeof(T));
    return values;
}

static AudioDeviceID findDevice(NSString *name) {
    const auto devices = readArray<AudioDeviceID>(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
    const auto found = std::ranges::find_if(devices, [=](const auto id) {
        return [readString(id, kAudioObjectPropertyName) isEqualToString:name];
    });
    return found == devices.end() ? kAudioObjectUnknown : *found;
}

static Channel channelAt(const AudioBufferList *buffers, UInt32 index) {
    if (!buffers) return {nullptr, 0, 0};
    const auto entries = std::span(buffers->mBuffers, buffers->mNumberBuffers);
    const auto entry = std::ranges::find_if(entries, [&index](const auto &buffer) {
        if (index < buffer.mNumberChannels) return true;
        index -= buffer.mNumberChannels;
        return false;
    });
    if (entry == entries.end() || !entry->mData || entry->mNumberChannels == 0) return {nullptr, 0, 0};
    return {static_cast<const float *>(entry->mData) + index, entry->mNumberChannels,
        static_cast<uint32_t>(entry->mDataByteSize / (sizeof(float) * entry->mNumberChannels))};
}

static void silence(AudioBufferList *buffers) {
    if (!buffers) return;
    std::ranges::for_each(std::span(buffers->mBuffers, buffers->mNumberBuffers), [](auto &buffer) {
        if (buffer.mData) memset(buffer.mData, 0, buffer.mDataByteSize);
    });
}

struct Route {
    AudioDeviceID aggregate = kAudioObjectUnknown;
    AudioDeviceID input = kAudioObjectUnknown;
    AudioDeviceID output = kAudioObjectUnknown;
    AudioDeviceIOProcID io = nullptr;
    AudioDeviceIOProcID monitor = nullptr;
    UInt32 sourceChannel = 0;
    UInt32 outputOffset = 0;
    Float64 sampleRate = 0;
    AudioStats stats;
    ~Route() {
        if (monitor) {
            AudioDeviceStop(output, monitor);
            AudioDeviceDestroyIOProcID(output, monitor);
        }
        if (io) {
            AudioDeviceStop(aggregate, io);
            AudioDeviceDestroyIOProcID(aggregate, io);
        }
        if (aggregate) AudioHardwareDestroyAggregateDevice(aggregate);
    }
};

static OSStatus routeAudio(AudioDeviceID, const AudioTimeStamp *, const AudioBufferList *input,
                           const AudioTimeStamp *, AudioBufferList *output, const AudioTimeStamp *, void *context) {
    const auto route = static_cast<Route *>(context);
    silence(output);
    const auto source = channelAt(input, route->sourceChannel);
    const auto left = channelAt(output, route->outputOffset);
    const auto right = channelAt(output, route->outputOffset + 1);
    const auto peak = copyChannel(source, const_cast<float *>(left.samples), left.stride, left.frames);
    copyChannel(source, const_cast<float *>(right.samples), right.stride, right.frames);
    route->stats.inputPeak.store(std::max(peak, route->stats.inputPeak.load(std::memory_order_relaxed)), std::memory_order_relaxed);
    route->stats.callbacks.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}

static OSStatus monitorAudio(AudioDeviceID, const AudioTimeStamp *, const AudioBufferList *input,
                             const AudioTimeStamp *, AudioBufferList *output, const AudioTimeStamp *, void *context) {
    silence(output);
    const auto stats = static_cast<AudioStats *>(context);
    const auto left = channelAt(input, 0);
    const auto right = channelAt(input, 1);
    if (!left.samples || !right.samples) return noErr;
    const auto frames = std::min(left.frames, right.frames);
    const auto positions = std::views::iota(UInt32{0}, frames);
    const auto peak = [=](Channel channel) {
        return std::transform_reduce(positions.begin(), positions.end(), 0.0f,
            [](float a, float b) { return std::max(a, b); },
            [=](const auto i) { return std::abs(channel.samples[i * channel.stride]); });
    };
    const auto difference = std::transform_reduce(positions.begin(), positions.end(), 0.0f,
        [](float a, float b) { return std::max(a, b); },
        [=](const auto i) { return std::abs(left.samples[i * left.stride] - right.samples[i * right.stride]); });
    stats->leftPeak.store(std::max(peak(left), stats->leftPeak.load(std::memory_order_relaxed)), std::memory_order_relaxed);
    stats->rightPeak.store(std::max(peak(right), stats->rightPeak.load(std::memory_order_relaxed)), std::memory_order_relaxed);
    stats->difference.store(std::max(difference, stats->difference.load(std::memory_order_relaxed)), std::memory_order_relaxed);
    stats->verifiedFrames.fetch_add(frames, std::memory_order_relaxed);
    return noErr;
}

static UInt32 streamChannels(AudioDeviceID device, AudioObjectPropertyScope scope) {
    const auto streams = readArray<AudioStreamID>(device, kAudioDevicePropertyStreams, scope);
    return std::transform_reduce(streams.begin(), streams.end(), UInt32{0}, std::plus<>(), [](const auto stream) {
        const auto format = readValue<AudioStreamBasicDescription>(stream, kAudioStreamPropertyVirtualFormat);
        if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat) || format.mBitsPerChannel != 32)
            throw std::runtime_error("Device must expose native 32-bit float audio");
        return format.mChannelsPerFrame;
    });
}

static void enableStreams(AudioDeviceID device, AudioDeviceIOProcID io, AudioObjectPropertyScope scope, UInt32 firstChannel, UInt32 channels) {
    const auto streams = readArray<AudioStreamID>(device, kAudioDevicePropertyStreams, scope);
    std::vector<UInt32> channelCounts;
    std::ranges::transform(streams, std::back_inserter(channelCounts), [](const auto stream) {
        return readValue<AudioStreamBasicDescription>(stream, kAudioStreamPropertyVirtualFormat).mChannelsPerFrame;
    });
    const auto bytes = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + streams.size() * sizeof(UInt32);
    std::vector<uint8_t> storage(bytes);
    const auto usage = reinterpret_cast<AudioHardwareIOProcStreamUsage *>(storage.data());
    usage->mIOProc = reinterpret_cast<void *>(io);
    usage->mNumberStreams = static_cast<UInt32>(streams.size());
    std::ranges::for_each(std::views::iota(size_t{0}, streams.size()), [&](const auto index) {
        const auto offset = std::accumulate(channelCounts.begin(), channelCounts.begin() + index, UInt32{0});
        usage->mStreamIsOn[index] = channels > 0 && offset < firstChannel + channels && offset + channelCounts[index] > firstChannel;
    });
    const auto address = property(kAudioDevicePropertyIOProcStreamUsage, scope);
    require(AudioObjectSetPropertyData(device, &address, 0, nullptr, static_cast<UInt32>(bytes), usage), "Select audio streams");
}

static std::shared_ptr<Route> startRoute(AudioDeviceID input, AudioDeviceID output, UInt32 channel) {
    const auto route = std::make_shared<Route>();
    route->input = input;
    route->output = output;
    route->sourceChannel = channel;
    if (channel >= streamChannels(input, kAudioObjectPropertyScopeInput)) throw std::runtime_error("Selected microphone channel is unavailable");
    if (streamChannels(output, kAudioObjectPropertyScopeOutput) != 2) throw std::runtime_error("BlackHole must have two output channels");
    route->outputOffset = streamChannels(input, kAudioObjectPropertyScopeOutput);
    route->sampleRate = readValue<Float64>(input, kAudioDevicePropertyNominalSampleRate);
    const auto inputUID = readString(input, kAudioDevicePropertyDeviceUID);
    const auto outputUID = readString(output, kAudioDevicePropertyDeviceUID);
    const auto description = @{
        @kAudioAggregateDeviceNameKey: @"Scarlett Mono private bridge",
        @kAudioAggregateDeviceUIDKey: [bundleID stringByAppendingFormat:@".%@", NSUUID.UUID.UUIDString],
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceIsStackedKey: @NO,
        @kAudioAggregateDeviceMainSubDeviceKey: inputUID,
        @kAudioAggregateDeviceSubDeviceListKey: @[
            @{@kAudioSubDeviceUIDKey: inputUID, @kAudioSubDeviceDriftCompensationKey: @NO},
            @{@kAudioSubDeviceUIDKey: outputUID, @kAudioSubDeviceDriftCompensationKey: @YES}
        ]
    };
    require(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description, &route->aggregate), "Create private audio bridge");
    const auto rateAddress = property(kAudioDevicePropertyNominalSampleRate);
    require(AudioObjectSetPropertyData(route->aggregate, &rateAddress, 0, nullptr, sizeof(route->sampleRate), &route->sampleRate), "Set bridge sample rate");
    return route;
}

static void activateRoute(const std::shared_ptr<Route> &route) {
    const auto inputChannels = streamChannels(route->aggregate, kAudioObjectPropertyScopeInput);
    const auto outputChannels = streamChannels(route->aggregate, kAudioObjectPropertyScopeOutput);
    if (outputChannels < route->outputOffset + 2 || inputChannels <= route->sourceChannel)
        throw std::runtime_error("Audio bridge layout: input " + std::to_string(inputChannels) + ", output " + std::to_string(outputChannels));
    require(AudioDeviceCreateIOProcID(route->aggregate, routeAudio, route.get(), &route->io), "Create audio callback");
    enableStreams(route->aggregate, route->io, kAudioObjectPropertyScopeInput, route->sourceChannel, 1);
    enableStreams(route->aggregate, route->io, kAudioObjectPropertyScopeOutput, route->outputOffset, 2);
    require(AudioDeviceStart(route->aggregate, route->io), "Start microphone bridge");
    require(AudioDeviceCreateIOProcID(route->output, monitorAudio, &route->stats, &route->monitor), "Create output verification");
    enableStreams(route->output, route->monitor, kAudioObjectPropertyScopeOutput, 0, 0);
    require(AudioDeviceStart(route->output, route->monitor), "Verify BlackHole audio");
}

@interface MonoApp : NSObject <NSApplicationDelegate> {
    std::shared_ptr<Route> _route;
}
@property NSStatusItem *statusItem;
@property NSMenuItem *stateItem;
@property NSMenuItem *meterItem;
@property NSMenuItem *pauseItem;
@property NSTimer *timer;
@property NSString *state;
@property BOOL paused;
@property UInt32 channel;
@property NSURL *statusURL;
@property NSDictionary *lastBroadcast;
@end

@implementation MonoApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.channel = static_cast<UInt32>([NSUserDefaults.standardUserDefaults integerForKey:@"channel"]);
    const auto support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    const auto folder = [support URLByAppendingPathComponent:@"Scarlett Mono" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    self.statusURL = [folder URLByAppendingPathComponent:@"status.json"];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:@"Scarlett Mono"];
    const auto menu = [NSMenu new];
    self.stateItem = [menu addItemWithTitle:@"Starting microphone" action:nil keyEquivalent:@""];
    self.meterItem = [menu addItemWithTitle:@"Scarlett → BlackHole, both channels" action:nil keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    self.pauseItem = [menu addItemWithTitle:@"Pause microphone" action:@selector(togglePause:) keyEquivalent:@""];
    self.pauseItem.target = self;
    const auto channels = [NSMenu new];
    std::ranges::for_each(std::views::iota(UInt32{0}, UInt32{10}), [&](const auto index) {
        const auto item = [channels addItemWithTitle:[NSString stringWithFormat:@"Input %u", index + 1] action:@selector(selectChannel:) keyEquivalent:@""];
        item.tag = index;
        item.target = self;
        item.state = self.channel == index ? NSControlStateValueOn : NSControlStateValueOff;
    });
    const auto channelItem = [menu addItemWithTitle:@"Microphone channel" action:nil keyEquivalent:@""];
    channelItem.submenu = channels;
    const auto reconnect = [menu addItemWithTitle:@"Reconnect" action:@selector(reconnect:) keyEquivalent:@""];
    reconnect.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    const auto quit = [menu addItemWithTitle:@"Quit Scarlett Mono" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    self.statusItem.menu = menu;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reconnect:) name:@"ScarlettMonoReconnect" object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(sleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(reconnect:) name:NSWorkspaceDidWakeNotification object:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(update) userInfo:nil repeats:YES];
    [self update];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self update];
        });
    }];
}
- (void)togglePause:(id)sender {
    self.paused = !self.paused;
    self.pauseItem.title = self.paused ? @"Resume microphone" : @"Pause microphone";
    _route.reset();
    [self update];
}
- (void)selectChannel:(NSMenuItem *)sender {
    self.channel = static_cast<UInt32>(sender.tag);
    [NSUserDefaults.standardUserDefaults setInteger:self.channel forKey:@"channel"];
    [sender.menu.itemArray enumerateObjectsUsingBlock:^(NSMenuItem *item, NSUInteger index, BOOL *stop) {
        item.state = item == sender ? NSControlStateValueOn : NSControlStateValueOff;
    }];
    [self reconnect:nil];
}
- (void)sleep:(id)sender { _route.reset(); }
- (void)reconnect:(id)sender {
    _route.reset();
    [self update];
}
- (void)update {
    const auto report = [NSMutableDictionary dictionary];
    report[@"updatedAt"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    report[@"microphonePermission"] = @([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]);
    report[@"channel"] = @(self.channel + 1);
    report[@"input"] = inputName;
    report[@"output"] = outputName;
    try {
        if (self.paused) self.state = @"Microphone paused";
        else if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
            _route.reset();
            self.state = @"Microphone permission required";
        }
        else {
            const auto input = findDevice(inputName);
            const auto output = findDevice(outputName);
            if (!input || !output) {
                _route.reset();
                self.state = !input ? @"Waiting for Scarlett" : @"Waiting for BlackHole";
            } else {
                const auto rate = readValue<Float64>(input, kAudioDevicePropertyNominalSampleRate);
                if (_route && (_route->input != input || _route->output != output || _route->sampleRate != rate)) _route.reset();
                if (!_route) {
                    _route = startRoute(input, output, self.channel);
                    self.state = @"Connecting microphone";
                } else {
                    if (!_route->io) activateRoute(_route);
                    self.state = @"Mic running";
                }
                report[@"sampleRate"] = @(_route->sampleRate);
                report[@"callbacks"] = @(_route->stats.callbacks.load());
                report[@"verifiedFrames"] = @(_route->stats.verifiedFrames.load());
                report[@"inputPeak"] = @(_route->stats.inputPeak.exchange(0));
                report[@"leftPeak"] = @(_route->stats.leftPeak.exchange(0));
                report[@"rightPeak"] = @(_route->stats.rightPeak.exchange(0));
                report[@"maximumChannelDifference"] = @(_route->stats.difference.exchange(0));
            }
        }
    } catch (const std::exception &error) {
        _route.reset();
        self.state = [NSString stringWithUTF8String:error.what()];
    }
    self.stateItem.title = self.state;
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"Scarlett Mono: %@", self.state];
    self.statusItem.button.appearsDisabled = !_route;
    self.meterItem.title = [NSString stringWithFormat:@"Input %u → BlackHole left + right", self.channel + 1];
    report[@"state"] = self.state;
    const auto data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:self.statusURL options:NSDataWritingAtomic error:nil];
    NSDictionary *tokens = @{
        @"Microphone paused": @"paused",
        @"Microphone permission required": @"no-permission",
        @"Waiting for Scarlett": @"waiting-scarlett",
        @"Waiting for BlackHole": @"waiting-blackhole",
        @"Connecting microphone": @"connecting",
        @"Mic running": @"running",
    };
    [self broadcast:@{
        @"state": tokens[self.state] ?: @"error",
        @"channel": [NSString stringWithFormat:@"%u", self.channel + 1],
        @"message": self.state,
    }];
}
- (void)broadcast:(NSDictionary *)fields {
    if ([fields isEqualToDictionary:self.lastBroadcast]) return;
    self.lastBroadcast = fields;
    NSMutableDictionary *stamped = [fields mutableCopy];
    stamped[@"pid"] = [NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier];
    stamped[@"updatedAt"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    const auto folder = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:@"com.shanekeulen.ScarlettMono"];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:stamped options:NSJSONWritingSortedKeys error:nil]
        writeToURL:[folder URLByAppendingPathComponent:@"state.json"] options:NSDataWritingAtomic error:nil];
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"com.shanekeulen.ScarlettMono.state"
        object:nil userInfo:stamped deliverImmediately:YES];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
    _route.reset();
    [self broadcast:@{@"state": @"stopped"}];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && std::string(argv[1]) == "--devices") {
            const auto devices = readArray<AudioDeviceID>(kAudioObjectSystemObject, kAudioHardwarePropertyDevices);
            std::ranges::for_each(devices, [](const auto id) {
                try {
                    printf("%u %s uid=%s inputs=%u outputs=%u\n", id,
                        readString(id, kAudioObjectPropertyName).UTF8String,
                        readString(id, kAudioDevicePropertyDeviceUID).UTF8String,
                        streamChannels(id, kAudioObjectPropertyScopeInput),
                        streamChannels(id, kAudioObjectPropertyScopeOutput));
                } catch (const std::exception &error) { printf("%u: %s\n", id, error.what()); }
            });
            return 0;
        }
        if (argc > 1 && std::string(argv[1]) == "--check-layout") {
            try {
                const auto route = startRoute(findDevice(inputName), findDevice(outputName), 0);
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1, false);
                const auto inputs = streamChannels(route->aggregate, kAudioObjectPropertyScopeInput);
                const auto outputs = streamChannels(route->aggregate, kAudioObjectPropertyScopeOutput);
                if (inputs != 12 || outputs != 8) throw std::runtime_error("Unexpected private bridge layout");
                printf("PASS: private bridge has %u inputs, %u outputs; Scarlett input 1 maps to BlackHole outputs %u and %u at %.0f Hz. No recording started.\n", inputs, outputs, route->outputOffset + 1, route->outputOffset + 2, route->sampleRate);
                return 0;
            } catch (const std::exception &error) {
                fprintf(stderr, "%s\n", error.what());
                return 1;
            }
        }
        const auto lockPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Scarlett Mono/process.lock"];
        [NSFileManager.defaultManager createDirectoryAtPath:lockPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        const auto lockFile = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
        if (lockFile < 0 || flock(lockFile, LOCK_EX | LOCK_NB) != 0) return 0;
        const auto app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __attribute__((objc_precise_lifetime)) MonoApp *const delegate = [MonoApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
