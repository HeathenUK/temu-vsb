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
 // Stage 2: arm the fast PIT ch0 ISR here.
}

static void COVOX_card_stop(struct mpxplay_audioout_info_s *aui)
{
 // Stage 2: disarm the fast PIT ch0 ISR here (idle-gate the timer).
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
// Timer/monitor. STAGE 1: no fast ISR yet, so advance the play position by the
// per-tick sample budget here (SBEMU calls this at ~115 Hz while playing) to
// keep virtual-DMA bookkeeping live and prove the integration. STAGE 2 replaces
// this with a fast per-sample PIT ISR that OUTs to card->port and does this
// advance at the sub-rate - VSB's engine (idle gating / /Q / /E applicable).
//----------------------------------------------------------------------------
static void COVOX_int_monitor(struct mpxplay_audioout_info_s *aui)
{
 covox_card_s *card = aui->card_private_data;
 unsigned long step = aui->card_dmaout_under_int08;
 if(!step) step = 1;
 card->playpos += step;
 while(card->playpos >= aui->card_dmasize) card->playpos -= aui->card_dmasize;
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
 &COVOX_int_monitor,    // cardbuf_int_monitor
 NULL,                  // irq_routine

 NULL,                  // card_writemixer
 NULL,                  // card_readmixer
 NULL,                  // card_mixerchans
 NULL, NULL,            // fm write/read (FM is real-OPL3 passthrough)
 NULL, NULL,            // mpu401 write/read
};

#endif // AU_CARDS_LINK_COVOX
