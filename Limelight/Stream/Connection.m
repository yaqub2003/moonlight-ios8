//
//  Connection.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "Utils.h"

#import <VideoToolbox/VideoToolbox.h>

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#include "Limelight.h"
#include "opus_multistream.h"

@implementation Connection {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    CONNECTION_LISTENER_CALLBACKS _clCallbacks;
    DECODER_RENDERER_CALLBACKS _drCallbacks;
    AUDIO_RENDERER_CALLBACKS _arCallbacks;
    char _hostString[256];
    char _appVersionString[32];
    char _gfeVersionString[32];
    char _rtspSessionUrl[128];
}

static NSLock* initLock;
static OpusMSDecoder* opusDecoder;
static id<ConnectionCallbacks> _callbacks;
static int lastFrameNumber;
static int activeVideoFormat;
static video_stats_t currentVideoStats;
static video_stats_t lastVideoStats;
static NSLock* videoStatsLock;

// Audio output uses an AudioQueue directly. Upstream Moonlight uses SDL2
// for this, but SDL2 no longer supports iOS 8 or 32-bit ARM.
#define AUDIO_QUEUE_BUFFERS 10
static AudioQueueRef audioQueue;
static AudioQueueBufferRef audioQueueBuffers[AUDIO_QUEUE_BUFFERS];
static AudioQueueBufferRef freeAudioBuffers[AUDIO_QUEUE_BUFFERS];
static int freeAudioBufferCount;
static NSLock* audioBufferLock;
static dispatch_semaphore_t audioBufferSemaphore;
static OPUS_MULTISTREAM_CONFIGURATION audioConfig;
static int audioFrameSize;

static VideoDecoderRenderer* renderer;

int DrDecoderSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags)
{
    [renderer setupWithVideoFormat:videoFormat width:width height:height frameRate:redrawRate];
    lastFrameNumber = 0;
    activeVideoFormat = videoFormat;
    memset(&currentVideoStats, 0, sizeof(currentVideoStats));
    memset(&lastVideoStats, 0, sizeof(lastVideoStats));
    return 0;
}

void DrStart(void)
{
    [renderer start];
}

void DrStop(void)
{
    [renderer stop];
}

-(BOOL) getVideoStats:(video_stats_t*)stats
{
    // We return lastVideoStats because it is a complete 1 second window
    [videoStatsLock lock];
    if (lastVideoStats.endTime != 0) {
        memcpy(stats, &lastVideoStats, sizeof(*stats));
        [videoStatsLock unlock];
        return YES;
    }
    
    // No stats yet
    [videoStatsLock unlock];
    return NO;
}

-(NSString*) getActiveCodecName
{
    switch (activeVideoFormat)
    {
        case VIDEO_FORMAT_H264:
            return @"H.264";
        case VIDEO_FORMAT_H264_HIGH8_444:
            return @"H.264 (4:4:4)";
        case VIDEO_FORMAT_H265:
            return @"HEVC";
        case VIDEO_FORMAT_H265_REXT8_444:
            return @"HEVC (4:4:4)";
        case VIDEO_FORMAT_H265_MAIN10:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"HEVC Main 10 HDR";
            }
            else {
                return @"HEVC Main 10 SDR";
            }
        case VIDEO_FORMAT_H265_REXT10_444:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"HEVC Main 10 HDR (4:4:4)";
            }
            else {
                return @"HEVC Main 10 SDR (4:4:4)";
            }
        case VIDEO_FORMAT_AV1_MAIN8:
            return @"AV1";
        case VIDEO_FORMAT_AV1_HIGH8_444:
            return @"AV1 (4:4:4)";
        case VIDEO_FORMAT_AV1_MAIN10:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"AV1 10-bit HDR";
            }
            else {
                return @"AV1 10-bit SDR";
            }
        case VIDEO_FORMAT_AV1_HIGH10_444:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"AV1 10-bit HDR (4:4:4)";
            }
            else {
                return @"AV1 10-bit SDR (4:4:4)";
            }
        default:
            return @"UNKNOWN";
    }
}

int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit)
{
    int offset = 0;
    int ret;
    unsigned char* data = (unsigned char*) malloc(decodeUnit->fullLength);
    if (data == NULL) {
        // A frame was lost due to OOM condition
        return DR_NEED_IDR;
    }
    
    CFTimeInterval now = CACurrentMediaTime();
    if (!lastFrameNumber) {
        currentVideoStats.startTime = now;
        lastFrameNumber = decodeUnit->frameNumber;
    }
    else {
        // Flip stats roughly every second
        if (now - currentVideoStats.startTime >= 1.0f) {
            currentVideoStats.endTime = now;
            
            [videoStatsLock lock];
            lastVideoStats = currentVideoStats;
            [videoStatsLock unlock];
            
            memset(&currentVideoStats, 0, sizeof(currentVideoStats));
            currentVideoStats.startTime = now;
        }
        
        // Any frame number greater than m_LastFrameNumber + 1 represents a dropped frame
        currentVideoStats.networkDroppedFrames += decodeUnit->frameNumber - (lastFrameNumber + 1);
        currentVideoStats.totalFrames += decodeUnit->frameNumber - (lastFrameNumber + 1);
        lastFrameNumber = decodeUnit->frameNumber;
    }
    
    if (decodeUnit->frameHostProcessingLatency != 0) {
        if (currentVideoStats.minHostProcessingLatency == 0 || decodeUnit->frameHostProcessingLatency < currentVideoStats.minHostProcessingLatency) {
            currentVideoStats.minHostProcessingLatency = decodeUnit->frameHostProcessingLatency;
        }
        
        if (decodeUnit->frameHostProcessingLatency > currentVideoStats.maxHostProcessingLatency) {
            currentVideoStats.maxHostProcessingLatency = decodeUnit->frameHostProcessingLatency;
        }
        
        currentVideoStats.framesWithHostProcessingLatency++;
        currentVideoStats.totalHostProcessingLatency += decodeUnit->frameHostProcessingLatency;
    }
    
    currentVideoStats.receivedFrames++;
    currentVideoStats.totalFrames++;

    PLENTRY entry = decodeUnit->bufferList;
    while (entry != NULL) {
        // Submit parameter set NALUs directly since no copy is required by the decoder
        if (entry->bufferType != BUFFER_TYPE_PICDATA) {
            ret = [renderer submitDecodeBuffer:(unsigned char*)entry->data
                                        length:entry->length
                                    bufferType:entry->bufferType
                                     decodeUnit:decodeUnit];
            if (ret != DR_OK) {
                free(data);
                return ret;
            }
        }
        else {
            memcpy(&data[offset], entry->data, entry->length);
            offset += entry->length;
        }

        entry = entry->next;
    }

    // This function will take our picture data buffer
    return [renderer submitDecodeBuffer:data
                                 length:offset
                             bufferType:BUFFER_TYPE_PICDATA
                             decodeUnit:decodeUnit];
}

static void AudioQueueBufferDone(void* userData, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    // The buffer has been played, so return it to the free list
    [audioBufferLock lock];
    freeAudioBuffers[freeAudioBufferCount++] = buffer;
    [audioBufferLock unlock];
    dispatch_semaphore_signal(audioBufferSemaphore);
}

int ArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION opusConfig, void* context, int flags)
{
    int err;
    OSStatus status;
    AudioStreamBasicDescription format;
    
    // Do not lower the volume of other audio streams
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    
    audioConfig = *opusConfig;
    audioFrameSize = opusConfig->samplesPerFrame * sizeof(short) * opusConfig->channelCount;
    
    opusDecoder = opus_multistream_decoder_create(opusConfig->sampleRate,
                                                  opusConfig->channelCount,
                                                  opusConfig->streams,
                                                  opusConfig->coupledStreams,
                                                  opusConfig->mapping,
                                                  &err);
    if (opusDecoder == NULL) {
        Log(LOG_E, @"Failed to create Opus decoder");
        ArCleanup();
        return -1;
    }
    
    memset(&format, 0, sizeof(format));
    format.mSampleRate = opusConfig->sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    format.mChannelsPerFrame = opusConfig->channelCount;
    format.mBitsPerChannel = 16;
    format.mBytesPerFrame = sizeof(short) * opusConfig->channelCount;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = format.mBytesPerFrame;
    
    // A NULL run loop makes the AudioQueue invoke the callback on its own thread
    status = AudioQueueNewOutput(&format, AudioQueueBufferDone, NULL, NULL, NULL, 0, &audioQueue);
    if (status != noErr) {
        Log(LOG_E, @"AudioQueueNewOutput() failed: %d", (int)status);
        audioQueue = NULL;
        ArCleanup();
        return -1;
    }
    
    audioBufferLock = [[NSLock alloc] init];
    audioBufferSemaphore = dispatch_semaphore_create(0);
    freeAudioBufferCount = 0;
    for (int i = 0; i < AUDIO_QUEUE_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(audioQueue, audioFrameSize, &audioQueueBuffers[i]);
        if (status != noErr) {
            Log(LOG_E, @"AudioQueueAllocateBuffer() failed: %d", (int)status);
            ArCleanup();
            return -1;
        }
        freeAudioBuffers[freeAudioBufferCount++] = audioQueueBuffers[i];
        dispatch_semaphore_signal(audioBufferSemaphore);
    }
    
    status = AudioQueueStart(audioQueue, NULL);
    if (status != noErr) {
        Log(LOG_E, @"AudioQueueStart() failed: %d", (int)status);
        ArCleanup();
        return -1;
    }
    
    return 0;
}

void ArCleanup(void)
{
    if (audioQueue != NULL) {
        // Stopping synchronously also disposes of the buffers
        AudioQueueStop(audioQueue, true);
        AudioQueueDispose(audioQueue, true);
        audioQueue = NULL;
    }
    memset(audioQueueBuffers, 0, sizeof(audioQueueBuffers));
    freeAudioBufferCount = 0;
    audioBufferSemaphore = nil;
    audioBufferLock = nil;
    
    if (opusDecoder != NULL) {
        opus_multistream_decoder_destroy(opusDecoder);
        opusDecoder = NULL;
    }
}

void ArDecodeAndPlaySample(char* sampleData, int sampleLength)
{
    int decodeLen;
    AudioQueueBufferRef buffer;
    
    // Don't queue if there's already more than 30 ms of audio data waiting
    // in Moonlight's audio queue.
    if (LiGetPendingAudioDuration() > 30) {
        return;
    }
    
    // Provide backpressure: wait (briefly) until the AudioQueue hands a buffer back.
    // If it doesn't within 100 ms, the audio device is stuck so drop the sample.
    if (dispatch_semaphore_wait(audioBufferSemaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        return;
    }
    
    [audioBufferLock lock];
    buffer = freeAudioBuffers[--freeAudioBufferCount];
    [audioBufferLock unlock];
    
    decodeLen = opus_multistream_decode(opusDecoder, (unsigned char *)sampleData, sampleLength,
                                        (short*)buffer->mAudioData, audioConfig.samplesPerFrame, 0);
    if (decodeLen > 0) {
        buffer->mAudioDataByteSize = (UInt32)(sizeof(short) * decodeLen * audioConfig.channelCount);
        OSStatus status = AudioQueueEnqueueBuffer(audioQueue, buffer, 0, NULL);
        if (status == noErr) {
            return;
        }
        Log(LOG_E, @"AudioQueueEnqueueBuffer() failed: %d", (int)status);
    }
    
    // Not submitted, so return the buffer to the free list
    [audioBufferLock lock];
    freeAudioBuffers[freeAudioBufferCount++] = buffer;
    [audioBufferLock unlock];
    dispatch_semaphore_signal(audioBufferSemaphore);
}

void ClStageStarting(int stage)
{
    [_callbacks stageStarting:LiGetStageName(stage)];
}

void ClStageComplete(int stage)
{
    [_callbacks stageComplete:LiGetStageName(stage)];
}

void ClStageFailed(int stage, int errorCode)
{
    [_callbacks stageFailed:LiGetStageName(stage) withError:errorCode portTestFlags:LiGetPortFlagsFromStage(stage)];
}

void ClConnectionStarted(void)
{
    [_callbacks connectionStarted];
}

void ClConnectionTerminated(int errorCode)
{
    [_callbacks connectionTerminated: errorCode];
}

void ClLogMessage(const char* format, ...)
{
    va_list va;
    va_start(va, format);
    vfprintf(stderr, format, va);
    va_end(va);
}

void ClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor)
{
    [_callbacks rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

void ClConnectionStatusUpdate(int status)
{
    [_callbacks connectionStatusUpdate:status];
}

void ClSetHdrMode(bool enabled)
{
    [renderer setHdrMode:enabled];
    [_callbacks setHdrMode:enabled];
}

void ClRumbleTriggers(uint16_t controllerNumber, uint16_t leftTriggerMotor, uint16_t rightTriggerMotor)
{
    [_callbacks rumbleTriggers:controllerNumber leftTrigger:leftTriggerMotor rightTrigger:rightTriggerMotor];
}

void ClSetMotionEventState(uint16_t controllerNumber, uint8_t motionType, uint16_t reportRateHz)
{
    [_callbacks setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

void ClSetControllerLED(uint16_t controllerNumber, uint8_t r, uint8_t g, uint8_t b)
{
    [_callbacks setControllerLed:controllerNumber r:r g:g b:b];
}

-(void) terminate
{
    // Interrupt any action blocking LiStartConnection(). This is
    // thread-safe and done outside initLock on purpose, since we
    // won't be able to acquire it if LiStartConnection is in
    // progress.
    LiInterruptConnection();
    
    // We dispatch this async to get out because this can be invoked
    // on a thread inside common and we don't want to deadlock. It also avoids
    // blocking on the caller's thread waiting to acquire initLock.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [initLock lock];
        LiStopConnection();
        [initLock unlock];
    });
}

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks
{
    self = [super init];

    // Use a lock to ensure that only one thread is initializing
    // or deinitializing a connection at a time.
    if (initLock == nil) {
        initLock = [[NSLock alloc] init];
    }
    
    if (videoStatsLock == nil) {
        videoStatsLock = [[NSLock alloc] init];
    }
    
    NSString *rawAddress = [Utils addressPortStringToAddress:config.host];
    strncpy(_hostString,
            [rawAddress cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_hostString) - 1);
    strncpy(_appVersionString,
            [config.appVersion cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_appVersionString) - 1);
    if (config.gfeVersion != nil) {
        strncpy(_gfeVersionString,
                [config.gfeVersion cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_gfeVersionString) - 1);
    }
    if (config.rtspSessionUrl != nil) {
        strncpy(_rtspSessionUrl,
                [config.rtspSessionUrl cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_rtspSessionUrl) - 1);
    }

    LiInitializeServerInformation(&_serverInfo);
    _serverInfo.address = _hostString;
    _serverInfo.serverInfoAppVersion = _appVersionString;
    if (config.gfeVersion != nil) {
        _serverInfo.serverInfoGfeVersion = _gfeVersionString;
    }
    if (config.rtspSessionUrl != nil) {
        _serverInfo.rtspSessionUrl = _rtspSessionUrl;
    }
    _serverInfo.serverCodecModeSupport = config.serverCodecModeSupport;

    renderer = myRenderer;
    _callbacks = callbacks;

    LiInitializeStreamConfiguration(&_streamConfig);
    _streamConfig.width = config.width;
    _streamConfig.height = config.height;
    _streamConfig.fps = config.frameRate;
    _streamConfig.bitrate = config.bitRate;
    _streamConfig.supportedVideoFormats = config.supportedVideoFormats;
    _streamConfig.audioConfiguration = config.audioConfiguration;
    
#if defined(__arm64__) || defined(__aarch64__)
    // 64-bit devices have ARMv8 crypto instructions, so encrypting
    // everything is cheap.
    _streamConfig.encryptionFlags = ENCFLG_ALL;
#else
    // 32-bit devices (iPad 2/3/4, iPad mini 1, iPhone 4S/5/5c) have no
    // AES acceleration. Only encrypt audio to save CPU, like Moonlight
    // does on other platforms without hardware AES.
    _streamConfig.encryptionFlags = ENCFLG_AUDIO;
#endif
    
    if ([Utils isActiveNetworkVPN]) {
        // Force remote streaming mode when a VPN is connected
        _streamConfig.streamingRemotely = STREAM_CFG_REMOTE;
        _streamConfig.packetSize = 1024;
    }
    else {
        // Detect remote streaming automatically based on the IP address of the target
        _streamConfig.streamingRemotely = STREAM_CFG_AUTO;
        _streamConfig.packetSize = 1392;
    }

    memcpy(_streamConfig.remoteInputAesKey, [config.riKey bytes], [config.riKey length]);
    memset(_streamConfig.remoteInputAesIv, 0, 16);
    int riKeyId = htonl(config.riKeyId);
    memcpy(_streamConfig.remoteInputAesIv, &riKeyId, sizeof(riKeyId));

    LiInitializeVideoCallbacks(&_drCallbacks);
    _drCallbacks.setup = DrDecoderSetup;
    _drCallbacks.start = DrStart;
    _drCallbacks.stop = DrStop;
    _drCallbacks.capabilities = CAPABILITY_PULL_RENDERER |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;

    LiInitializeAudioCallbacks(&_arCallbacks);
    _arCallbacks.init = ArInit;
    _arCallbacks.cleanup = ArCleanup;
    _arCallbacks.decodeAndPlaySample = ArDecodeAndPlaySample;
    _arCallbacks.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    LiInitializeConnectionCallbacks(&_clCallbacks);
    _clCallbacks.stageStarting = ClStageStarting;
    _clCallbacks.stageComplete = ClStageComplete;
    _clCallbacks.stageFailed = ClStageFailed;
    _clCallbacks.connectionStarted = ClConnectionStarted;
    _clCallbacks.connectionTerminated = ClConnectionTerminated;
    _clCallbacks.logMessage = ClLogMessage;
    _clCallbacks.rumble = ClRumble;
    _clCallbacks.connectionStatusUpdate = ClConnectionStatusUpdate;
    _clCallbacks.setHdrMode = ClSetHdrMode;
    _clCallbacks.rumbleTriggers = ClRumbleTriggers;
    _clCallbacks.setMotionEventState = ClSetMotionEventState;
    _clCallbacks.setControllerLED = ClSetControllerLED;

    return self;
}

-(void) main
{
    [initLock lock];
    LiStartConnection(&_serverInfo,
                      &_streamConfig,
                      &_clCallbacks,
                      &_drCallbacks,
                      &_arCallbacks,
                      NULL, 0,
                      NULL, 0);
    [initLock unlock];
}

@end
