( dx7_voice_render.fy - the complete DX7 voice, composed from validated parts.

  The complete voice is: advance each operator's DX7 envelope (k-dx7-eg),
  scale the operator's output level by the envelope gain, then run the
  algorithm matrix (k-dx7-voice). This file just pulls both kernels together;
  the per-operator loop is driven by the caller (the machine's render path on
  the audio thread, or the rig test), one k-dx7-eg call per operator followed
  by one k-dx7-voice call.

  Note: folding the six envelope advances and the matrix into a single dsp2
  word corrupts the dsp2 local frames (a fy deep-composition limit), so the
  voice is composed from separate, individually-validated kernel calls. )

include "dx7_voice.fy"
include "../03-envelopes/dx7_eg.fy"
