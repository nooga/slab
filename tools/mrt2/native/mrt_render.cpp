// mrt_render — render a MIDI file (or a fixed duration) through magentart::core.
//
// Notes condition the model frame by frame (25 Hz); the prompt sets the style; the seed
// makes the render reproducible: same inputs + same seed = byte-identical WAV.
//
//   mrt_render <model.mlxfn> <resource_dir> -o out.wav [--midi in.mid] [--seconds S]
//              [--prompt TEXT] [--seed N] [--tail S] [--temperature T] [--top-k K]
//              [--cfg-musiccoca X] [--cfg-notes X] [--onset-mode 0|1] [--transpose N]

#include <magentart/detail/autorelease_pool.h>
#include <magentart/mlx_engine.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using namespace magentart::core;

namespace {

constexpr int kSampleRate = 48000;
constexpr int kMidiPitches = 128;  // 128..131 are MRT2's drum triggers, not MIDI notes
constexpr double kFrameSeconds = static_cast<double>(kFrameSamples) / kSampleRate;  // 0.04

struct NoteEvent {
  double seconds;
  int pitch;
  bool on;
};

// Minimal Standard MIDI File reader: formats 0 and 1, PPQ timing, tempo map merged across
// tracks. Returns pitched note on/off events in time order; drums and everything else are skipped.
std::vector<NoteEvent> read_midi(const std::string &path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw std::runtime_error("cannot open " + path);
  std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), {});
  size_t p = 0;
  auto need = [&](size_t n) {
    if (p + n > b.size()) throw std::runtime_error("truncated MIDI file");
  };
  auto u32 = [&] { need(4); uint32_t v = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]; p += 4; return v; };
  auto u16 = [&] { need(2); uint16_t v = (b[p] << 8) | b[p + 1]; p += 2; return v; };
  auto vlq = [&] { uint32_t v = 0; uint8_t c; do { need(1); c = b[p++]; v = (v << 7) | (c & 0x7f); } while (c & 0x80); return v; };

  need(4);
  if (std::string(b.begin(), b.begin() + 4) != "MThd") throw std::runtime_error("not a MIDI file");
  p = 4;
  uint32_t hlen = u32();
  size_t after_header = p + hlen;
  u16();  // format
  uint16_t ntracks = u16();
  uint16_t division = u16();
  if (division & 0x8000) throw std::runtime_error("SMPTE time division is not supported");
  p = after_header;

  struct TickEvent { uint64_t tick; int kind; int a; };  // kind: 0 off, 1 on, 2 tempo (a = us/quarter)
  std::vector<TickEvent> evs;
  for (int t = 0; t < ntracks && p + 8 <= b.size(); ++t) {
    need(4);
    bool is_track = std::string(b.begin() + p, b.begin() + p + 4) == "MTrk";
    p += 4;
    uint32_t len = u32();
    size_t end = p + len;
    if (!is_track) { p = end; continue; }
    uint64_t tick = 0;
    uint8_t status = 0;
    while (p < end) {
      tick += vlq();
      need(1);
      if (b[p] & 0x80) status = b[p++];
      if (status == 0xff) {
        need(1);
        uint8_t type = b[p++];
        uint32_t n = vlq();
        need(n);
        if (type == 0x51 && n == 3) evs.push_back({tick, 2, (b[p] << 16) | (b[p + 1] << 8) | b[p + 2]});
        p += n;
        status = 0;  // meta and sysex cancel running status
      } else if (status == 0xf0 || status == 0xf7) {
        uint32_t n = vlq();
        need(n);
        p += n;
        status = 0;
      } else {
        uint8_t hi = status & 0xf0;
        int nbytes = (hi == 0xc0 || hi == 0xd0) ? 1 : 2;
        need(nbytes);
        // Channel 10 is General MIDI percussion: its note numbers name drums, not pitches.
        if ((hi == 0x90 || hi == 0x80) && (status & 0x0f) != 9) {
          int pitch = b[p], vel = b[p + 1];
          evs.push_back({tick, (hi == 0x90 && vel > 0) ? 1 : 0, pitch});
        }
        p += nbytes;
      }
    }
    p = end;
  }

  // Tempo changes sort before notes at the same tick; note-offs before note-ons so a
  // repeated pitch re-articulates instead of being swallowed.
  std::stable_sort(evs.begin(), evs.end(), [](const TickEvent &x, const TickEvent &y) {
    if (x.tick != y.tick) return x.tick < y.tick;
    auto rank = [](int k) { return k == 2 ? 0 : (k == 0 ? 1 : 2); };
    return rank(x.kind) < rank(y.kind);
  });
  std::vector<NoteEvent> out;
  double us_per_quarter = 500000.0, seconds = 0.0;
  uint64_t last_tick = 0;
  for (const auto &e : evs) {
    seconds += (e.tick - last_tick) * us_per_quarter / 1e6 / division;
    last_tick = e.tick;
    if (e.kind == 2) us_per_quarter = e.a;
    else out.push_back({seconds, e.a, e.kind == 1});
  }
  return out;
}

bool write_wav(const std::string &path, const std::vector<float> &interleaved) {
  const uint16_t channels = kNumChannels, bits = 32, format = 3;  // IEEE float
  const uint32_t rate = kSampleRate, block = channels * bits / 8, byte_rate = rate * block;
  const uint32_t data = static_cast<uint32_t>(interleaved.size() * sizeof(float)), riff = 36 + data, fmt_len = 16;
  std::ofstream f(path, std::ios::binary);
  if (!f) return false;
  auto w = [&](const void *v, size_t n) { f.write(static_cast<const char *>(v), n); };
  w("RIFF", 4); w(&riff, 4); w("WAVE", 4);
  w("fmt ", 4); w(&fmt_len, 4); w(&format, 2); w(&channels, 2); w(&rate, 4); w(&byte_rate, 4); w(&block, 2); w(&bits, 2);
  w("data", 4); w(&data, 4); w(interleaved.data(), data);
  return f.good();
}

[[noreturn]] void usage(const char *argv0) {
  std::fprintf(stderr,
      "usage: %s <model.mlxfn> <resource_dir> -o out.wav [--midi in.mid] [--seconds S]\n"
      "          [--prompt TEXT] [--seed N] [--tail S] [--temperature T] [--top-k K]\n"
      "          [--cfg-musiccoca X] [--cfg-notes X] [--onset-mode 0|1] [--transpose N]\n",
      argv0);
  std::exit(2);
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 3) usage(argv[0]);
  std::string model = argv[1], resources = argv[2], out, midi, prompt = "a jazz piano trio";
  double seconds = 0, tail = 2.0;
  int seed = 0, top_k = 100, onset_mode = 1, transpose = 0;
  // hello_mrt2's defaults, except onset mode: a score knows exactly where notes start.
  float temperature = 1.0f, cfg_musiccoca = 3.0f, cfg_notes = 5.0f;

  for (int i = 3; i < argc; ++i) {
    std::string a = argv[i];
    auto val = [&]() -> std::string { if (i + 1 >= argc) usage(argv[0]); return argv[++i]; };
    if (a == "-o" || a == "--output") out = val();
    else if (a == "--midi") midi = val();
    else if (a == "--seconds") seconds = std::stod(val());
    else if (a == "--prompt" || a == "-p") prompt = val();
    else if (a == "--seed") seed = std::stoi(val());
    else if (a == "--tail") tail = std::stod(val());
    else if (a == "--temperature") temperature = std::stof(val());
    else if (a == "--top-k") top_k = std::stoi(val());
    else if (a == "--cfg-musiccoca") cfg_musiccoca = std::stof(val());
    else if (a == "--cfg-notes") cfg_notes = std::stof(val());
    else if (a == "--onset-mode") onset_mode = std::stoi(val());
    else if (a == "--transpose") transpose = std::stoi(val());
    else usage(argv[0]);
  }
  if (out.empty() || (midi.empty() && seconds <= 0)) usage(argv[0]);

  std::vector<NoteEvent> notes;
  if (!midi.empty()) {
    try {
      notes = read_midi(midi);
    } catch (const std::exception &e) {
      std::fprintf(stderr, "%s: %s\n", midi.c_str(), e.what());
      return 1;
    }
    if (notes.empty()) { std::fprintf(stderr, "%s has no notes\n", midi.c_str()); return 1; }
    // --seconds with --midi fixes the length (a clip plus its tail); else the last note plus --tail.
    if (seconds <= 0) seconds = notes.back().seconds + tail;
  }
  const int num_frames = static_cast<int>(std::ceil(seconds / kFrameSeconds));

  MLXEngine engine;
  if (!engine.init_assets(resources.c_str())) { std::fprintf(stderr, "failed to load assets from %s\n", resources.c_str()); return 1; }
  if (!engine.load_model(model.c_str())) { std::fprintf(stderr, "failed to load %s\n", model.c_str()); return 1; }
  engine.set_temperature(temperature);
  engine.set_top_k(top_k);
  engine.set_cfg_musiccoca(cfg_musiccoca);
  engine.set_cfg_notes(cfg_notes);
  engine.set_onset_mode(onset_mode);
  engine.set_seed_rotation(seed);
  engine.reset_state();  // applies the seed rotation

  engine.set_text_prompt(prompt);
  // The worker sets the two statuses one at a time (the encoder's success before the
  // quantizer starts), so "neither busy" can come before the style tokens exist.
  // Wait for both to succeed; rendering without them would ignore the prompt.
  for (int waited_ms = 0;; waited_ms += 10) {
    const int enc = engine.get_text_encoder_status(), quant = engine.get_quantizer_status();
    if (enc == 2 && quant == 2) break;
    if (enc == 3 || quant == 3 || waited_ms > 120000) {
      std::fprintf(stderr, "prompt encoding failed\n");
      return 1;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }

  std::vector<float> interleaved;
  interleaved.reserve(static_cast<size_t>(num_frames) * kFrameSamples * kNumChannels);
  std::vector<float> L(kFrameSamples), R(kFrameSamples);
  size_t next = 0;
  int skipped = 0;
  // The engine keeps one state per pitch, so overlapping notes of a pitch are counted
  // here and only the last release reaches it.
  std::array<int, kMidiPitches> held{};
  const auto t0 = std::chrono::steady_clock::now();
  for (int f = 0; f < num_frames; ++f) {
    // Every event that starts inside this frame's 40 ms window conditions this frame.
    const double frame_end = (f + 1) * kFrameSeconds;
    for (; next < notes.size() && notes[next].seconds < frame_end; ++next) {
      int pitch = notes[next].pitch + transpose;
      if (pitch < 0 || pitch >= kMidiPitches) { skipped += notes[next].on; continue; }
      if (notes[next].on) {
        ++held[pitch];
        engine.set_note_on(pitch);  // a re-strike while held is a new onset
      } else if (held[pitch] > 0 && --held[pitch] == 0) {
        engine.set_note_off(pitch);
      }
    }
    magentart::detail::AutoreleasePool pool;  // MLX leaks Metal temporaries without a drained pool per frame
    if (!engine.generate_frame(L.data(), R.data())) { std::fprintf(stderr, "generate_frame failed at frame %d\n", f); return 1; }
    for (size_t i = 0; i < kFrameSamples; ++i) { interleaved.push_back(L[i]); interleaved.push_back(R[i]); }
    // Once a second of audio: a host following the log shows the last line.
    if ((f + 1) % 25 == 0 || f + 1 == num_frames) {
      std::printf("rendered %.0f of %.0f s\n", (f + 1) * kFrameSeconds, num_frames * kFrameSeconds);
      std::fflush(stdout);
    }
  }
  const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

  if (!write_wav(out, interleaved)) { std::fprintf(stderr, "failed to write %s\n", out.c_str()); return 1; }
  if (skipped) std::printf("warning: %d notes fell outside 0-127 after transpose and were dropped\n", skipped);
  std::printf("wrote %s%s\n", out.c_str(), midi.empty() ? "" : (" from " + midi).c_str());
  // Last and short: a host shows the final line as the outcome.
  std::printf("done: %.2f s in %.1f s (%.1f frames/s), seed %d\n", num_frames * kFrameSeconds, elapsed, num_frames / elapsed, seed);
  return 0;
}
