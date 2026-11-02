// MIDI input through CoreMIDI (docs/44). Every source is connected to one
// input port; its channel messages are framed here and queued in a
// lock-free ring that the UI thread drains once a frame (src/midi_in.zig).
// Nothing in the CoreMIDI callback allocates or locks.

#include <CoreMIDI/CoreMIDI.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#define RING 1024 // messages; a power of two

static MIDIClientRef g_client;
static MIDIPortRef g_port;
static uint32_t g_ring[RING];
static atomic_uint g_w, g_r;
static atomic_uint g_dropped;
static atomic_int g_rescan;

// Queue one channel message: source<<24 | status<<16 | data1<<8 | data2.
static void push(uint32_t src, uint8_t st, uint8_t d1, uint8_t d2) {
    unsigned w = atomic_load_explicit(&g_w, memory_order_relaxed);
    unsigned r = atomic_load_explicit(&g_r, memory_order_acquire);
    if (w - r >= RING) {
        atomic_fetch_add_explicit(&g_dropped, 1, memory_order_relaxed);
        return;
    }
    g_ring[w % RING] = (src << 24) | ((uint32_t)st << 16) | ((uint32_t)d1 << 8) | d2;
    atomic_store_explicit(&g_w, w + 1, memory_order_release);
}

static int data_len(uint8_t st) {
    switch (st & 0xF0) {
    case 0xC0:
    case 0xD0: return 1;
    case 0x80:
    case 0x90:
    case 0xA0:
    case 0xB0:
    case 0xE0: return 2;
    default: return -1;
    }
}

// Frame the bytes of one packet: running status, realtime bytes anywhere,
// system exclusive and other system messages skipped.
static void frame(uint32_t src, const Byte *b, UInt16 n) {
    uint8_t st = 0, d[2] = {0, 0};
    int need = 0, have = 0;
    for (UInt16 i = 0; i < n; i++) {
        uint8_t x = b[i];
        if (x >= 0xF8) continue;
        if (x >= 0xF0) {
            st = 0;
            need = 0;
            continue;
        }
        if (x & 0x80) {
            st = x;
            need = data_len(x);
            have = 0;
            continue;
        }
        if (st == 0 || need < 0) continue;
        d[have++] = x;
        if (have == need) {
            push(src, st, d[0], need == 2 ? d[1] : 0);
            have = 0;
        }
    }
}

static void read_proc(const MIDIPacketList *list, void *ref, void *src_ref) {
    (void)ref;
    uint32_t src = (uint32_t)(uintptr_t)src_ref & 0xFF;
    const MIDIPacket *p = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++) {
        frame(src, p->data, p->length);
        p = MIDIPacketNext(p);
    }
}

static void notify(const MIDINotification *msg, void *ref) {
    (void)ref;
    if (msg->messageID == kMIDIMsgSetupChanged) atomic_store(&g_rescan, 1);
}

// Open the client and port and connect every source. 0 on success.
int slab_midi_start(void) {
    if (g_client) return 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (MIDIClientCreate(CFSTR("Slab"), notify, NULL, &g_client) != noErr) {
        g_client = 0;
        return -1;
    }
    if (MIDIInputPortCreate(g_client, CFSTR("Slab in"), read_proc, NULL, &g_port) != noErr) {
        MIDIClientDispose(g_client);
        g_client = 0;
        return -2;
    }
#pragma clang diagnostic pop
    atomic_store(&g_rescan, 1);
    return 0;
}

// Connect every source now present (again, after the setup changed).
// Returns how many there are.
int slab_midi_connect(void) {
    if (!g_client) return 0;
    atomic_store(&g_rescan, 0);
    ItemCount n = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < n; i++) {
        MIDIEndpointRef e = MIDIGetSource(i);
        MIDIPortDisconnectSource(g_port, e);
        MIDIPortConnectSource(g_port, e, (void *)(uintptr_t)i);
    }
    return (int)n;
}

// 1 once, after the MIDI setup changed (a device came or went).
int slab_midi_take_rescan(void) { return atomic_exchange(&g_rescan, 0); }

// The display name of source `i` (`buf` gets a NUL-terminated UTF-8
// string); 0 when there is none.
int slab_midi_source_name(int i, char *buf, int cap) {
    if (i < 0 || cap < 1 || (ItemCount)i >= MIDIGetNumberOfSources()) return 0;
    CFStringRef s = NULL;
    MIDIEndpointRef e = MIDIGetSource((ItemCount)i);
    if (MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &s) != noErr || s == NULL) return 0;
    Boolean ok = CFStringGetCString(s, buf, cap, kCFStringEncodingUTF8);
    CFRelease(s);
    return ok ? 1 : 0;
}

// The next queued message, or 0 when the ring is empty. A message always
// has a status byte, so 0 is never one.
uint32_t slab_midi_pop(void) {
    unsigned r = atomic_load_explicit(&g_r, memory_order_relaxed);
    unsigned w = atomic_load_explicit(&g_w, memory_order_acquire);
    if (r == w) return 0;
    uint32_t m = g_ring[r % RING];
    atomic_store_explicit(&g_r, r + 1, memory_order_release);
    return m;
}

// Messages lost to a full ring since the last call.
unsigned slab_midi_take_dropped(void) { return atomic_exchange(&g_dropped, 0); }
