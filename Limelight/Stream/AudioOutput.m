//
//  AudioOutput.m
//  Moonlight
//
//  Audio output for the iOS 8 build.
//
//  This follows the design of Moonlight 2.x, which played audio reliably on
//  iOS 8 devices like the iPad 3:
//
//  - Decoded Opus packets go into a small ring buffer (written by the
//    moonlight-common-c audio thread, read by the AudioQueue thread).
//  - The AudioQueue is primed with silence before it's started, and every
//    buffer it hands back is immediately refilled and re-enqueued, with
//    audio if there is some, or with silence otherwise. The queue never runs
//    dry, so a network hiccup can't leave it stalled.
//
//  On top of that, it caps how much audio can pile up (to keep latency low),
//  restarts the queue after audio session interruptions or unexpected stops,
//  and records statistics and events in Documents/AudioLog.txt.
//

#import "AudioOutput.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#include "opus_multistream.h"

// Number of decoded packets the ring buffer can hold
#define RING_PACKETS 32

// Number of AudioQueue buffers; each holds one packet
#define QUEUE_BUFFERS 4

// Audio waiting in the ring buffer beyond this is dropped to keep latency low
#define MAX_BUFFERED_MS 40

#define MAX_EVENTS 200

static OpusMSDecoder* decoder;
static AudioQueueRef audioQueue;
static AudioQueueBufferRef queueBuffers[QUEUE_BUFFERS];

static int sampleRate;
static int channelCount;
static int packetFrames;        // maximum frames per packet
static int bytesPerFrame;
static int maxBufferedPackets;

// Single-producer/single-consumer ring of decoded packets
static short* ringSamples;
static int ringFrames[RING_PACKETS];
static int ringRead;    // advanced by the AudioQueue thread only
static int ringWrite;   // advanced by the decoder thread only

static int stopping;

static struct {
    unsigned received;          // packets passed to us
    unsigned decoded;           // packets decoded into the ring buffer
    unsigned decodeErrors;
    unsigned droppedPending;    // dropped because moonlight-common-c was backed up
    unsigned droppedFull;       // dropped because the ring buffer was full
    unsigned trimmed;           // dropped to cap latency
    unsigned played;            // buffers filled with audio
    unsigned underruns;         // buffers filled with silence (no audio ready)
    unsigned enqueueErrors;
    unsigned interruptions;
    unsigned unexpectedStops;
    unsigned restarts;
} stats;

static NSObject* stateLock;
static NSMutableArray* events;
static CFTimeInterval startTime;
static id interruptionObserver;
static id mediaResetObserver;

static void RecordEvent(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2);
static void RecordEvent(NSString* format, ...)
{
    va_list args;
    va_start(args, format);
    NSString* message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    Log(LOG_I, @"Audio: %@", message);

    @synchronized (stateLock) {
        if (events == nil) {
            return;
        }
        if (events.count >= MAX_EVENTS) {
            [events removeObjectAtIndex:0];
        }
        [events addObject:[NSString stringWithFormat:@"%8.3f s  %@", CACurrentMediaTime() - startTime, message]];
    }
}

static NSString* DescribeAudioSession(void)
{
    AVAudioSession* session = [AVAudioSession sharedInstance];
    NSMutableArray* outputs = [NSMutableArray array];
    for (AVAudioSessionPortDescription* port in session.currentRoute.outputs) {
        [outputs addObject:[NSString stringWithFormat:@"%@ (%@)", port.portName, port.portType]];
    }
    return [NSString stringWithFormat:@"session: category %@, sample rate %.0f Hz, IO buffer %.1f ms, output latency %.1f ms, outputs: %@, other audio playing: %d",
            session.category, session.sampleRate, session.IOBufferDuration * 1000,
            session.outputLatency * 1000, [outputs componentsJoinedByString:@", "],
            session.otherAudioPlaying];
}

static void WriteLog(NSString* reason)
{
    NSString* documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString* path = [documents stringByAppendingPathComponent:@"AudioLog.txt"];

    NSMutableString* log = [NSMutableString string];
    [log appendFormat:@"Moonlight audio log (%@), %@\n", reason, [NSDate date]];
    [log appendFormat:@"iOS %@, %@\n", [UIDevice currentDevice].systemVersion, [UIDevice currentDevice].model];
    [log appendFormat:@"stream: %d Hz, %d channels, %d frames (%.1f ms) per packet, max buffered %d packets\n",
     sampleRate, channelCount, packetFrames, packetFrames * 1000.0 / MAX(sampleRate, 1), maxBufferedPackets];
    [log appendFormat:@"%@\n\n", DescribeAudioSession()];
    [log appendFormat:@"packets received: %u, decoded: %u, decode errors: %u\n", stats.received, stats.decoded, stats.decodeErrors];
    [log appendFormat:@"dropped (common-c backed up): %u, dropped (ring full): %u, trimmed (latency cap): %u\n",
     stats.droppedPending, stats.droppedFull, stats.trimmed];
    [log appendFormat:@"buffers played: %u, silence (underruns): %u, enqueue errors: %u\n", stats.played, stats.underruns, stats.enqueueErrors];
    [log appendFormat:@"interruptions: %u, unexpected stops: %u, restarts: %u\n\n", stats.interruptions, stats.unexpectedStops, stats.restarts];
    [log appendString:@"Events:\n"];
    @synchronized (stateLock) {
        for (NSString* event in events) {
            [log appendFormat:@"%@\n", event];
        }
    }

    // Keep the previous session's log too
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if ([reason isEqualToString:@"stream started"] && [fileManager fileExistsAtPath:path]) {
        NSString* previous = [documents stringByAppendingPathComponent:@"AudioLog-previous.txt"];
        [fileManager removeItemAtPath:previous error:nil];
        [fileManager moveItemAtPath:path toPath:previous error:nil];
    }
    [log writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static int AvailablePackets(int read, int write)
{
    return (write - read + RING_PACKETS) % RING_PACKETS;
}

// Called on the AudioQueue's thread whenever it has finished playing a buffer
static void FillBuffer(void* userData, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    if (__atomic_load_n(&stopping, __ATOMIC_ACQUIRE)) {
        // Don't re-enqueue while we're shutting down
        return;
    }

    int read = __atomic_load_n(&ringRead, __ATOMIC_RELAXED);
    int write = __atomic_load_n(&ringWrite, __ATOMIC_ACQUIRE);
    int available = AvailablePackets(read, write);

    // If too much audio has piled up (e.g. after the queue was paused),
    // skip the oldest packets so we don't play it back with extra delay.
    if (available > maxBufferedPackets) {
        stats.trimmed += available - maxBufferedPackets;
        read = (read + available - maxBufferedPackets) % RING_PACKETS;
        available = maxBufferedPackets;
    }

    if (available > 0) {
        UInt32 size = (UInt32)(ringFrames[read] * bytesPerFrame);
        memcpy(buffer->mAudioData, ringSamples + (size_t)read * packetFrames * channelCount, size);
        buffer->mAudioDataByteSize = size;
        read = (read + 1) % RING_PACKETS;
        stats.played++;
    }
    else {
        // Nothing to play yet: keep the queue running with silence
        UInt32 size = (UInt32)(packetFrames * bytesPerFrame);
        memset(buffer->mAudioData, 0, size);
        buffer->mAudioDataByteSize = size;
        stats.underruns++;
    }

    __atomic_store_n(&ringRead, read, __ATOMIC_RELEASE);

    OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    if (status != noErr) {
        if (stats.enqueueErrors++ < 10) {
            RecordEvent(@"AudioQueueEnqueueBuffer() failed: %d", (int)status);
        }
    }
}

static void RestartQueue(NSString* reason)
{
    @synchronized (stateLock) {
        if (audioQueue == NULL || __atomic_load_n(&stopping, __ATOMIC_ACQUIRE)) {
            return;
        }
        NSError* error = nil;
        if (![[AVAudioSession sharedInstance] setActive:YES error:&error]) {
            RecordEvent(@"setActive:YES failed: %@", error);
        }
        OSStatus status = AudioQueueStart(audioQueue, NULL);
        stats.restarts++;
        RecordEvent(@"restarted queue (%@): %d", reason, (int)status);
    }
}

static void QueueRunningChanged(void* userData, AudioQueueRef queue, AudioQueuePropertyID property)
{
    UInt32 running = 0;
    UInt32 size = sizeof(running);
    AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size);

    if (__atomic_load_n(&stopping, __ATOMIC_ACQUIRE)) {
        return;
    }

    RecordEvent(@"queue is %@", running ? @"running" : @"stopped");
    if (!running) {
        stats.unexpectedStops++;
        // Restart it outside of the property listener callback
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            RestartQueue(@"it stopped");
        });
    }
}

int AudioOutputInit(POPUS_MULTISTREAM_CONFIGURATION opusConfig)
{
    int err;
    OSStatus status;

    if (stateLock == nil) {
        stateLock = [[NSObject alloc] init];
    }

    memset(&stats, 0, sizeof(stats));
    @synchronized (stateLock) {
        events = [NSMutableArray array];
    }
    startTime = CACurrentMediaTime();
    __atomic_store_n(&stopping, 0, __ATOMIC_RELEASE);

    sampleRate = opusConfig->sampleRate;
    channelCount = opusConfig->channelCount;
    packetFrames = opusConfig->samplesPerFrame;
    bytesPerFrame = (int)sizeof(short) * channelCount;
    double packetMs = packetFrames * 1000.0 / sampleRate;
    maxBufferedPackets = MAX(2, (int)(MAX_BUFFERED_MS / packetMs));
    maxBufferedPackets = MIN(maxBufferedPackets, RING_PACKETS - 1);

    // Configure the audio session like Moonlight 2.x did on iOS 8: match the
    // stream's sample rate and ask for a small I/O buffer to keep latency low.
    // MixWithOthers keeps other audio from being lowered (upstream behavior).
    AVAudioSession* audioSession = [AVAudioSession sharedInstance];
    NSError* error = nil;
    if (![audioSession setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error]) {
        RecordEvent(@"setCategory failed: %@", error);
    }
    [audioSession setPreferredSampleRate:sampleRate error:nil];
    [audioSession setPreferredIOBufferDuration:0.005 error:nil];
    if (![audioSession setActive:YES error:&error]) {
        RecordEvent(@"setActive:YES failed: %@", error);
    }
    RecordEvent(@"%@", DescribeAudioSession());

    decoder = opus_multistream_decoder_create(opusConfig->sampleRate,
                                              opusConfig->channelCount,
                                              opusConfig->streams,
                                              opusConfig->coupledStreams,
                                              opusConfig->mapping,
                                              &err);
    if (decoder == NULL) {
        RecordEvent(@"opus_multistream_decoder_create() failed: %d", err);
        WriteLog(@"init failed");
        AudioOutputCleanup();
        return -1;
    }

    ringSamples = calloc((size_t)RING_PACKETS * packetFrames * channelCount, sizeof(short));
    if (ringSamples == NULL) {
        RecordEvent(@"Failed to allocate the ring buffer");
        AudioOutputCleanup();
        return -1;
    }
    __atomic_store_n(&ringRead, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&ringWrite, 0, __ATOMIC_RELEASE);

    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    format.mChannelsPerFrame = channelCount;
    format.mBitsPerChannel = 16;
    format.mBytesPerFrame = bytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = bytesPerFrame;

    // A NULL run loop makes the AudioQueue call FillBuffer on its own thread
    status = AudioQueueNewOutput(&format, FillBuffer, NULL, NULL, NULL, 0, &audioQueue);
    if (status != noErr) {
        RecordEvent(@"AudioQueueNewOutput() failed: %d", (int)status);
        audioQueue = NULL;
        WriteLog(@"init failed");
        AudioOutputCleanup();
        return -1;
    }

    // Prime the queue with silence before starting it, so it never starts empty
    for (int i = 0; i < QUEUE_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(audioQueue, (UInt32)(packetFrames * bytesPerFrame), &queueBuffers[i]);
        if (status != noErr) {
            RecordEvent(@"AudioQueueAllocateBuffer() failed: %d", (int)status);
            WriteLog(@"init failed");
            AudioOutputCleanup();
            return -1;
        }
        FillBuffer(NULL, audioQueue, queueBuffers[i]);
    }

    AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning, QueueRunningChanged, NULL);

    // Phone calls, alarms, Siri etc. interrupt the audio session and stop the
    // queue. Restart it once the interruption is over.
    interruptionObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
                                                                             object:nil
                                                                              queue:nil
                                                                         usingBlock:^(NSNotification* note) {
        NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) {
            stats.interruptions++;
            RecordEvent(@"audio session interruption began");
        }
        else {
            RecordEvent(@"audio session interruption ended");
            RestartQueue(@"interruption ended");
        }
    }];
    mediaResetObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                                                                           object:nil
                                                                            queue:nil
                                                                       usingBlock:^(NSNotification* note) {
        RecordEvent(@"media services were reset");
    }];

    status = AudioQueueStart(audioQueue, NULL);
    if (status != noErr) {
        RecordEvent(@"AudioQueueStart() failed: %d", (int)status);
        WriteLog(@"init failed");
        AudioOutputCleanup();
        return -1;
    }

    RecordEvent(@"started: %d Hz, %d channels, %d frames per packet", sampleRate, channelCount, packetFrames);
    WriteLog(@"stream started");
    return 0;
}

void AudioOutputCleanup(void)
{
    __atomic_store_n(&stopping, 1, __ATOMIC_RELEASE);

    if (interruptionObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:interruptionObserver];
        interruptionObserver = nil;
    }
    if (mediaResetObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:mediaResetObserver];
        mediaResetObserver = nil;
    }

    @synchronized (stateLock) {
        if (audioQueue != NULL) {
            AudioQueueRemovePropertyListener(audioQueue, kAudioQueueProperty_IsRunning, QueueRunningChanged, NULL);
            // Stop before disposing to avoid a long delay inside AudioQueueDispose()
            AudioQueueStop(audioQueue, true);
            // Also frees the buffers
            AudioQueueDispose(audioQueue, true);
            audioQueue = NULL;
        }
    }
    memset(queueBuffers, 0, sizeof(queueBuffers));

    if (decoder != NULL) {
        opus_multistream_decoder_destroy(decoder);
        decoder = NULL;
    }

    if (events != nil) {
        RecordEvent(@"stopped");
        WriteLog(@"stream ended");
    }

    free(ringSamples);
    ringSamples = NULL;
}

// Called on the moonlight-common-c audio thread
void AudioOutputDecodeAndPlaySample(char* sampleData, int sampleLength)
{
    stats.received++;

    // Don't queue if there's already more than 30 ms of audio data waiting
    // in Moonlight's audio queue (same as upstream).
    if (LiGetPendingAudioDuration() > 30) {
        stats.droppedPending++;
        return;
    }

    int write = __atomic_load_n(&ringWrite, __ATOMIC_RELAXED);
    int read = __atomic_load_n(&ringRead, __ATOMIC_ACQUIRE);
    int next = (write + 1) % RING_PACKETS;
    if (next == read) {
        stats.droppedFull++;
        return;
    }

    int decodeLen = opus_multistream_decode(decoder, (unsigned char*)sampleData, sampleLength,
                                            ringSamples + (size_t)write * packetFrames * channelCount,
                                            packetFrames, 0);
    if (decodeLen <= 0) {
        if (stats.decodeErrors++ < 10) {
            RecordEvent(@"opus_multistream_decode() failed: %d", decodeLen);
        }
        return;
    }

    ringFrames[write] = decodeLen;
    __atomic_store_n(&ringWrite, next, __ATOMIC_RELEASE);
    stats.decoded++;
}

NSString* AudioOutputGetStatsText(void)
{
    if (audioQueue == NULL) {
        return nil;
    }

    int buffered = AvailablePackets(__atomic_load_n(&ringRead, __ATOMIC_RELAXED),
                                    __atomic_load_n(&ringWrite, __ATOMIC_RELAXED));
    return [NSString stringWithFormat:@"Audio: %d ms buffered, %u silence fills, %u dropped, %u restarts",
            (int)(buffered * packetFrames * 1000 / MAX(sampleRate, 1)),
            stats.underruns,
            stats.droppedPending + stats.droppedFull + stats.trimmed,
            stats.restarts];
}
