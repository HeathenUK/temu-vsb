//**************************************************************************
//* Covox / LPT-DAC output backend for SBEMU  (Path A: VSB's engine under HDPMI)
//* Emulated SB PCM -> parallel-port DAC. FM is real-OPL3 passthrough (not here).
//*
//* One raw IRQ0 (PIT ch0) ISR at the output sample rate does BOTH jobs:
//*   consumer  : every tick, OUT one 8-bit-unsigned byte from card_DMABUFF->LPT.
//*   producer  : every refill_k ticks, call MAIN_CovoxPump() (SBEMU's heavy
//*               MAIN_Interrupt refill) with a reentrancy guard.
//* This is VSB's proven timer->LPT engine reseated behind SBEMU's mixer. The
//* fast per-sample path is a minimal raw ISR (never SBEMU's MAIN_InterruptPM
//* wrapper); the heavy producer runs only ~REFILL_HZ times/second.
//**************************************************************************
#include <stdlib.h>
#include <string.h>
#include "au_cards.h"
#include "dmairq.h"
#include <pic.h>
#include <dpmi/dpmi.h>
#include <hdpmipt.h>

#ifdef AU_CARDS_LINK_COVOX

#define COVOX_DEFAULT_PORT 0x378
#define COVOX_DMABUF_SIZE  8192
#define COVOX_DMABUF_PAGE  512
#define COVOX_FREQ_MIN     6000
#define COVOX_FREQ_MAX     22050
#define COVOX_REFILL_HZ    120

typedef struct covox_card_s {
 unsigned short port;
 unsigned long  playpos;
 unsigned int   refill_k;
 unsigned int   tick;
 unsigned long  bios_acc;   // 18.2 Hz BIOS-tick reconstruction accumulator
 unsigned long  freq_x1000; // freq_card * 1000 (accumulator wrap point)
} covox_card_s;

static covox_card_s covox_card;
static struct mpxplay_audioout_info_s *covox_aui;
static DPMI_ISR_HANDLE covox_pm, covox_rm;
static DPMI_REG covox_rmreg;
static HDPMIPT_IRQRoutedHandle covox_oldroute = HDPMIPT_IRQRoutedHandle_Default;
static int covox_armed = 0;
static volatile int covox_in_pump = 0;

extern void MAIN_CovoxPump(void);

// irq_routine: only reached if SBEMU's MAIN_InterruptPM ever runs on card_irq.
// We don't use card_irq to pump (own IRQ0 ISR does), so this is a harmless stub.
static int COVOX_irq_routine(struct mpxplay_audioout_info_s *aui){ (void)aui; return 0; }

static void COVOX_timer_isr(void)
{
 covox_card_s *card = &covox_card;
 struct mpxplay_audioout_info_s *aui = covox_aui;
 char *buf = aui->card_DMABUFF;
 // consumer: one 8-bit-unsigned sample per tick to the LPT DAC
 if(buf && card->playpos != aui->card_dmalastput){
  outp(card->port, (unsigned char)buf[card->playpos]);
  if(++card->playpos >= aui->card_dmasize) card->playpos = 0;
 }
 // Reconstruct the ~18.2065 Hz BIOS timer tick from our fast PIT: at each
 // boundary, chain the original int8 (it updates 0040:006C and sends its own
 // EOI). Otherwise we EOI ourselves. Without this, DOS/game tick-delays hang.
 card->bios_acc += 18206UL; // 18.2065 Hz * 1000
 if(card->bios_acc >= card->freq_x1000){
  card->bios_acc -= card->freq_x1000;
  DPMI_CallOldISR(&covox_pm); // original int8: BIOS tick + EOI
 } else {
  PIC_SendEOIWithIRQ(0);
 }
 // producer: refill in bulk every refill_k ticks (reentrancy-guarded)
 if(++card->tick >= card->refill_k){
  card->tick = 0;
  if(!covox_in_pump){
   covox_in_pump = 1;
   MAIN_CovoxPump();   // HDPMI int context + MAIN_Interrupt() (refills card_DMABUFF)
   covox_in_pump = 0;
  }
 }
}

static void COVOX_arm(struct mpxplay_audioout_info_s *aui)
{
 unsigned int div;
 covox_card_s *card = aui->card_private_data;
 if(covox_armed) return;
 covox_aui = aui;
 card->playpos = aui->card_dma_lastgoodpos;
 card->tick = 0;
 card->bios_acc = 0;
 card->freq_x1000 = (unsigned long)aui->freq_card * 1000UL;
 card->refill_k = aui->freq_card / COVOX_REFILL_HZ;
 if(card->refill_k < 1) card->refill_k = 1;
 // Install our own IRQ0 ISR ahead of the game/host (PM + RM), route via HDPMI so
 // it fires in both protected mode (DOOM) and real mode.
 HDPMIPT_GetIRQRoutedHandlerH(0, &covox_oldroute);
 DPMI_InstallISR(0x08, COVOX_timer_isr, &covox_pm, FALSE);
 DPMI_InstallRealModeISR(0x08, COVOX_timer_isr, &covox_rmreg, &covox_rm, FALSE);
 HDPMIPT_InstallIRQRoutedHandler(0, covox_pm.wrapper_cs, covox_pm.wrapper_offset,
                                 covox_rm.wrapper_cs, (uint16_t)covox_rm.wrapper_offset);
 // Reprogram PIT ch0 to the output sample rate.
 div = 1193182UL / aui->freq_card;
 __asm__ __volatile__("cli");
 outp(0x43, 0x34); outp(0x40, div & 0xFF); outp(0x40, (div >> 8) & 0xFF);
 __asm__ __volatile__("sti");
 covox_armed = 1;
}

static void COVOX_disarm(void)
{
 if(!covox_armed) return;
 __asm__ __volatile__("cli");
 outp(0x43, 0x34); outp(0x40, 0); outp(0x40, 0); // restore PIT ch0 to 18.2 Hz
 __asm__ __volatile__("sti");
 if(covox_oldroute.valid) HDPMIPT_InstallIRQRoutedHandlerH(0, &covox_oldroute);
 DPMI_UninstallISR(&covox_rm);
 DPMI_UninstallISR(&covox_pm);
 covox_armed = 0;
}

static int COVOX_card_detect(struct mpxplay_audioout_info_s *aui)
{
 covox_card_s *card = &covox_card;
 char *ep;
 card->port = COVOX_DEFAULT_PORT;
 ep = getenv("COVOX");
 if(ep){
  unsigned int p = 0;
  while(*ep==' ') ep++;
  while((*ep>='0'&&*ep<='9')||((*ep|0x20)>='a'&&(*ep|0x20)<='f')){
   char c=*ep++; int d=(c<='9')?c-'0':((c|0x20)-'a'+10); p=(p<<4)|d;
  }
  if(p) card->port=(unsigned short)p;
 }
 aui->card_private_data = card;
 aui->card_irq = 8;      // harmless: we pump from our own IRQ0 ISR, not card_irq
 aui->card_pci_dev = 0;
 return 1;
}

static void COVOX_card_info(struct mpxplay_audioout_info_s *aui)
{
 covox_card_s *card = aui->card_private_data;
 char sout[80];
 sprintf(sout,"Covox LPT-DAC at port %03Xh (8-bit mono, own IRQ0 timer)", card->port);
 pds_textdisplay_printf(sout);
}

static void COVOX_card_setrate(struct mpxplay_audioout_info_s *aui)
{
 covox_card_s *card = aui->card_private_data;
 aui->bits_card = 8;
 aui->chan_card = 1;
 if(aui->freq_card < COVOX_FREQ_MIN) aui->freq_card = COVOX_FREQ_MIN;
 if(aui->freq_card > COVOX_FREQ_MAX) aui->freq_card = COVOX_FREQ_MAX;
 aui->card_dma_buffer_size = COVOX_DMABUF_SIZE;
 if(!aui->card_dma_dosmem){ // allocate the software "DMA" ring (our IRQ0 ISR drains it to the LPT)
  aui->card_dma_dosmem = MDma_alloc_cardmem(COVOX_DMABUF_SIZE);
  aui->card_DMABUFF = aui->card_dma_dosmem->linearptr;
 }
 MDma_init_pcmoutbuf(aui, COVOX_DMABUF_SIZE, COVOX_DMABUF_PAGE, 0);
 card->playpos = 0;
}

static void COVOX_card_start(struct mpxplay_audioout_info_s *aui){ COVOX_arm(aui); }
static void COVOX_card_stop(struct mpxplay_audioout_info_s *aui){ COVOX_disarm(); }

static long COVOX_getbufpos(struct mpxplay_audioout_info_s *aui)
{
 covox_card_s *card = aui->card_private_data;
 unsigned long pos = card->playpos;
 if(pos >= aui->card_dmasize) pos = 0;
 aui->card_dma_lastgoodpos = pos;
 return pos;
}

static void COVOX_writemixer(struct mpxplay_audioout_info_s *aui, unsigned long reg, unsigned long val){ (void)aui;(void)reg;(void)val; }
static unsigned long COVOX_readmixer(struct mpxplay_audioout_info_s *aui, unsigned long reg){ (void)aui;(void)reg; return 0; }

static void COVOX_card_close(struct mpxplay_audioout_info_s *aui)
{
 COVOX_disarm();
 MDma_free_cardmem(aui->card_dma_dosmem);
 aui->card_dma_dosmem = NULL;
 aui->card_DMABUFF = NULL;
}

one_sndcard_info COVOX_sndcard_info = {
 "CVX", SNDCARD_LOWLEVELHAND,
 NULL, NULL, &COVOX_card_detect, &COVOX_card_info,
 &COVOX_card_start, &COVOX_card_stop, &COVOX_card_close, &COVOX_card_setrate,
 &MDma_writedata, &COVOX_getbufpos, &MDma_clearbuf, NULL, &COVOX_irq_routine,
 &COVOX_writemixer, &COVOX_readmixer, NULL, NULL, NULL, NULL, NULL,
};

#endif
