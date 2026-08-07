// Minimal Covox+OPL3 build: the DOSBox software OPL3 synth (dbopl.cpp +
// opl3emu.cpp, ~167 KB) is dead weight when a real OPL3 is present - FM is
// passed straight through to the chip (MAIN_HW_OPL3IODT at 388-38B). This stub
// satisfies the OPL3EMU_* symbols and reports the emulator as inactive, so
// main.c never takes the software OPL path (all its call sites are guarded by
// !fm_aui.fm / OPL3EMU_IsActive()).  Built in place of opl3emu.cpp/dbopl.cpp.
#include "opl3emu.h"

void     OPL3EMU_Init(int samplerate)            { (void)samplerate; }
int      OPL3EMU_IsActive(void)                  { return 0; }   // never the SW path
int      OPL3EMU_GetMode(void)                   { return 0; }
int      OPL3EMU_GenSamples(int16_t* pcm, int n) { (void)pcm; (void)n; return 0; }

uint32_t OPL3EMU_PrimaryRead(uint32_t v)         { (void)v; return 0xFF; }
uint32_t OPL3EMU_PrimaryWriteIndex(uint32_t v)   { return v; }
uint32_t OPL3EMU_PrimaryWriteData(uint32_t v)    { return v; }
uint32_t OPL3EMU_SecondaryRead(uint32_t v)       { (void)v; return 0xFF; }
uint32_t OPL3EMU_SecondaryWriteIndex(uint32_t v) { return v; }
uint32_t OPL3EMU_SecondaryWriteData(uint32_t v)  { return v; }
