//**************************************************************************
//* Covox / LPT-DAC output backend for SBEMU
//*
//* Emulated SB PCM -> parallel-port DAC (Covox Speech Thing). Music/FM is
//* NOT handled here: with a real OPL3, SBEMU's hardware-OPL3 passthrough
//* (MAIN_HW_OPL3IODT) sends FM straight to the chip. This backend is the one
//* piece a Covox+OPL3 machine lacks: getting the trapped SB PCM stream to the
//* only device that can play it - the LPT DAC.
//*
//* Target: 386SX @ 40 MHz. SBEMU mixes to 8-bit unsigned mono (bits_card=8,
//* chan_card=1) so each DMA-buffer byte IS one Covox sample - no per-sample
//* conversion. The output path is VSB's proven lean timer->LPT engine.
//*
//* STAGE 1 (this commit): compile, register, format/buffer path via MDma_*,
//* selectable as card "CVX". The per-sample fast-timer output ISR is Stage 2
//* (see build/harness/covox-backend-plan.md); until then cardbuf_int_monitor
//* advances the play position so SBEMU's virtual-DMA bookkeeping runs and the
//* integration can be validated end to end.
//**************************************************************************

#include <stdlib.h>
#include <string.h>
#include "au_cards.h"
#include "dmairq.h"

#ifdef AU_CARDS_LINK_COVOX

#define COVOX_DEFAULT_PORT 0x378   // LPT1 data register
#define COVOX_DMABUF_SIZE  4096    // software "DMA" ring (bytes = samples)
#define COVOX_DMABUF_PAGE  512
#define COVOX_FREQ_MIN     6000
#define COVOX_FREQ_MAX     22050   // Covox/386SX practical ceiling
#define COVOX_REFILL_HZ    1000    // STAGE 2a burst-drain rate (PIT ch0)

typedef struct covox_card_s
{
 unsigned short port;        // LPT data port
 unsigned long  playpos;     // ring read position (samples) - Stage 2 ISR owns
} covox_card_s;

static covox_card_s covox_card;

static int COVOX_card_detect(struct mpxplay_audioout_info_s *aui)
{
 covox_card_s *card = &covox_card;
 char *ep;
 card->port = COVOX_DEFAULT_PORT;
 // BLASTER-style override not standard for LPT; allow COVOX=<hexport>
 ep = getenv("COVOX");
 if(ep){
  unsigned int p = 0;
  while(*ep==' ') ep++;
  while((*ep>='0'&&*ep<='9')||(*ep>='A'&&*ep<='F')||(*ep>='a'&&*ep<='f')){
   char c=*ep++; int d = (c<='9')?c-'0':((c|0x20)-'a'+10);
   p = (p<<4)|d;
  }
  if(p) card->port = (unsigned short)p;
 }
 aui->card_private_data = card;
 aui->card_irq = 0;   // the TIMER. Covox has no HW IRQ, so we borrow
                      // IRQ0: SBEMU installs+routes its PM/RM handler here,
                      // card_start reprograms PIT, our irq_routine drains.
 aui->card_pci_dev = 0;
 return 1; // a Covox is passive; assume present at the configured LPT port
}

static void COVOX_card_info(struct mpxplay_audioout_info_s *aui)
{
 covox_card_s *card = aui->card_private_data;
 char sout[80];
 sprintf(sout,"Covox LPT-DAC at port %03Xh (8-bit mono PCM)", card->port);
 pds_textdisplay_printf(sout);
}

static void COVOX_card_setrate(struct mpxplay_audioout_info_s *aui)
{
 covox_card_s *card = aui->card_private_data;

 // 8-bit unsigned mono: SBEMU mixes directly to Covox sample format.
 aui->bits_card = 8;
 aui->chan_card = 1;
 if(aui->freq_card < COVOX_FREQ_MIN) aui->freq_card = COVOX_FREQ_MIN;
 if(aui->freq_card > COVOX_FREQ_MAX) aui->freq_card = COVOX_FREQ_MAX;

 aui->card_dma_buffer_size = COVOX_DMABUF_SIZE;
 MDma_init_pcmoutbuf(aui, COVOX_DMABUF_SIZE, COVOX_DMABUF_PAGE, 0);
 card->playpos = 0;
}

static void COVOX_card_start(struct mpxplay_audioout_info_s *aui)
{
 covox_card_s *card = aui->card_private_data;
 card->playpos = aui->card_dma_lastgoodpos;
 // Borrow PIT ch0: reprogram to the refill/drain rate. STAGE 2a runs the
 // heavy producer every tick so keep it modest (~1 kHz); each tick drains
 // the samples produced since last tick (burst - timing fixed in 2b).
 {
  unsigned int div = 1193182UL / COVOX_REFILL_HZ;
  outp(0x43, 0x34);            // ch0, lobyte/hibyte, mode 2
  outp(0x40, div & 0xFF);
  outp(0x40, (div >> 8) & 0xFF);
 }
}

static void COVOX_card_stop(struct mpxplay_audioout_info_s *aui)
{
 outp(0x43, 0x34);            // restore PIT ch0 to 18.2 Hz (divisor 0=65536)
 outp(0x40, 0);
 outp(0x40, 0);
}

static long COVOX_getbufpos(struct mpxplay_audioout_info_s *aui)
{
 covox_card_s *card = aui->card_private_data;
 unsigned long pos = card->playpos;
 if(pos >= aui->card_dmasize) pos = 0;
 aui->card_dma_lastgoodpos = pos;
 return pos;
}

//----------------------------------------------------------------------------
// Timer/monitor.
//
// STAGE 2a (data-path proof, this commit): drive output from SBEMU's existing
// ~115 Hz timer. Each call, OUT to the LPT DAC every sample the producer has
// added since last call, and advance the play position. This is a BURST dump -
// the ~140 bytes/call go out back-to-back, not sample-paced - so playback is
// time-distorted, but the BYTES are the real trapped-PCM stream reaching the
// Covox port. It proves the whole chain (game -> HDPMI trap -> SBEMU mix ->
// card_DMABUFF -> LPT) end to end with zero new interrupt code.
//
// STAGE 2b (next): a minimal fast PIT ISR at the sample rate does the OUT once
// per sample (VSB's lean engine; idle gating / /Q / /E), calling the producer
// only every K ticks. That fixes timing; this proves the path.
//----------------------------------------------------------------------------
// Called by SBEMU's IRQ0 (timer) handler each tick. Drain every sample the
// producer added since last tick to the LPT DAC, then return 1 so SBEMU runs
// MAIN_Interrupt() (the producer) to refill from the game's trapped DMA.
static int COVOX_irq_routine(struct mpxplay_audioout_info_s *aui)
{
 covox_card_s *card = aui->card_private_data;
 unsigned long target = aui->card_dmalastput;
 char *buf = aui->card_DMABUFF;
 unsigned short port = card->port;
 if(buf){
  while(card->playpos != target){
   outp(port, (unsigned char)buf[card->playpos]);
   if(++card->playpos >= aui->card_dmasize) card->playpos = 0;
  }
 }
 return 1; // ours: SBEMU will call MAIN_Interrupt() to refill
}

static void COVOX_card_close(struct mpxplay_audioout_info_s *aui)
{
 MDma_free_cardmem(aui->card_dma_dosmem);
 aui->card_dma_dosmem = NULL;
 aui->card_DMABUFF = NULL;
}

one_sndcard_info COVOX_sndcard_info = {
 "CVX",
 SNDCARD_LOWLEVELHAND | SNDCARD_INT08_ALLOWED,

 NULL,                  // card_config
 NULL,                  // card_init
 &COVOX_card_detect,    // card_detect
 &COVOX_card_info,      // card_info
 &COVOX_card_start,     // card_start
 &COVOX_card_stop,      // card_stop
 &COVOX_card_close,     // card_close
 &COVOX_card_setrate,   // card_setrate

 &MDma_writedata,       // cardbuf_writedata  (fills the 8-bit mono ring)
 &COVOX_getbufpos,      // cardbuf_pos
 &MDma_clearbuf,        // cardbuf_clear
 NULL,                  // cardbuf_int_monitor (SBEMU has no int08 timer)
 &COVOX_irq_routine,    // irq_routine (drains on the borrowed IRQ0)

 NULL,                  // card_writemixer
 NULL,                  // card_readmixer
 NULL,                  // card_mixerchans
 NULL, NULL,            // fm write/read (FM is real-OPL3 passthrough)
 NULL, NULL,            // mpu401 write/read
};

#endif // AU_CARDS_LINK_COVOX
