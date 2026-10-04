// Apple's audio encoders through AudioToolbox's ExtAudioFile (docs/27
// §Format): ALAC and AAC in an .m4a. Called from src/native_audio.zig.

#include <AudioToolbox/AudioToolbox.h>
#include <string.h>

// Write `frames` stereo frames to `path` as .m4a. ALAC (`alac` != 0) takes
// `ints`: interleaved samples of `bits` bits (16 or 24), lossless. AAC takes
// `floats` at `bitrate` bits per second. Returns 0, or the OSStatus.
int slab_write_m4a(const char *path, const int *ints, const float *floats,
                   unsigned long frames, double rate, int alac, int bits, int bitrate) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (url == NULL) return -1;

    AudioStreamBasicDescription file = {0};
    file.mSampleRate = rate;
    file.mChannelsPerFrame = 2;
    if (alac) {
        file.mFormatID = kAudioFormatAppleLossless;
        file.mFormatFlags = bits == 16 ? kAppleLosslessFormatFlag_16BitSourceData : kAppleLosslessFormatFlag_24BitSourceData;
        file.mFramesPerPacket = 4096;
    } else {
        file.mFormatID = kAudioFormatMPEG4AAC;
        file.mFramesPerPacket = 1024;
    }

    ExtAudioFileRef f = NULL;
    OSStatus st = ExtAudioFileCreateWithURL(url, kAudioFileM4AType, &file, NULL, kAudioFileFlags_EraseFile, &f);
    CFRelease(url);
    if (st != noErr) return (int)st;

    // What we hand it: ALAC 32-bit ints (the samples in the top bits, so
    // the converter only drops zeros), AAC 32-bit floats.
    AudioStreamBasicDescription client = {0};
    client.mSampleRate = rate;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mChannelsPerFrame = 2;
    client.mBitsPerChannel = 32;
    client.mBytesPerFrame = 8;
    client.mBytesPerPacket = 8;
    client.mFramesPerPacket = 1;
    client.mFormatFlags = alac ? (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
                               : (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked);
    st = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    if (st == noErr && !alac) {
        AudioConverterRef conv = NULL;
        UInt32 size = sizeof(conv);
        st = ExtAudioFileGetProperty(f, kExtAudioFileProperty_AudioConverter, &size, &conv);
        if (st == noErr) {
            UInt32 br = (UInt32)bitrate;
            st = AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, sizeof(br), &br);
        }
        if (st == noErr) {
            CFArrayRef cfg = NULL;
            st = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ConverterConfig, sizeof(cfg), &cfg);
        }
    }

    // In chunks: the converter takes any size, but buffers stay small.
    const unsigned long CHUNK = 32768;
    int shifted[32768 * 2];
    unsigned long done = 0;
    while (st == noErr && done < frames) {
        unsigned long n = frames - done < CHUNK ? frames - done : CHUNK;
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = 2;
        list.mBuffers[0].mDataByteSize = (UInt32)(n * 8);
        if (alac) {
            int up = 32 - bits;
            for (unsigned long i = 0; i < n * 2; i++) shifted[i] = (int)((unsigned)ints[done * 2 + i] << up);
            list.mBuffers[0].mData = shifted;
        } else {
            list.mBuffers[0].mData = (void *)(floats + done * 2);
        }
        st = ExtAudioFileWrite(f, (UInt32)n, &list);
        done += n;
    }
    OSStatus closed = ExtAudioFileDispose(f);
    return (int)(st != noErr ? st : closed);
}
