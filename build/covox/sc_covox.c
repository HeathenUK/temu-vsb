//**************************************************************************
//* Covox / LPT-DAC output backend for SBEMU  (Path A: VSB's engine under HDPMI)
//* Emulated SB PCM -> parallel-port DAC. FM is real-OPL3 passthrough (not here).
//* Own raw IRQ0 (PIT) ISR at the output sample rate: cheap per-sample OUT to
//* LPT (consumer); heavy producer MAIN_Interrupt() only every refill_k ticks.
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
} covox_card_s;

static covox_card_s covox_card;
static struct mpxplay_audioout_info_s *covox_aui;
static DPMI_ISR_HANDLE covox_pm, covox_rm;
static DPMI_REG covox_rmreg;
static HDPMIPT_IRQRoutedHandle covox_oldroute = HDPMIPT_IRQRoutedHandle_Default;
static int covox_armed = 0;
static volatile int covox_in_pump = 0;

extern void MAIN_Interrupt(void);
static int COVOX_irq_routine(struct mpxplay_audioout_info_s *aui)
{
 outp(0x70, 0x0C); inp(0x71); // ack RTC periodic int (read status C)
 (void)aui;
 return 1; // ours -> SBEMU calls MAIN_Interrupt() to refill (safe context)
}

static void COVOX_timer_isr(void)
{
 covox_card_s *card = &covox_card;
 struct mpxplay_audioout_info_s *aui = covox_aui;
 char *buf = aui->card_DMABUFF;
 if(buf && card->playpos != aui->card_dmalastput){       // consumer: 1 sample/tick
  outp(card->port, (unsigned char)buf[card->playpos]);
  if(++card->playpos >= aui->card_dmasize) card->playpos = 0;
 }
 PIC_SendEOIWithIRQ(0);
}

static void COVOX_arm(struct mpxplay_audioout_info_s *aui)
{
 unsigned int div;
 covox_card_s *card = aui->card_private_data;
 if(covox_armed) return;
 covox_aui = aui;
 card->playpos = aui->card_dma_lastgoodpos;
 card->tick = 0;
 card->refill_k = aui->freq_card / COVOX_REFILL_HZ;
 if(card->refill_k < 1) card->refill_k = 1;
 HDPMIPT_GetIRQRoutedHandlerH(0, &covox_oldroute);
 DPMI_InstallISR(0x08, COVOX_timer_isr, &covox_pm, FALSE);
 DPMI_InstallRealModeISR(0x08, COVOX_timer_isr, &covox_rmreg, &covox_rm, FALSE);
 HDPMIPT_InstallIRQRoutedHandler(0, covox_pm.wrapper_cs, covox_pm.wrapper_offset,
                                 covox_rm.wrapper_cs, (uint16_t)covox_rm.wrapper_offset);
 div = 1193182UL / aui->freq_card;
 outp(0x43, 0x34); outp(0x40, div & 0xFF); outp(0x40, (div >> 8) & 0xFF);
 // RTC periodic interrupt (IRQ8) ~128 Hz drives the producer via SBEMU
 __asm__ __volatile__("cli");
 outp(0x70, 0x8B); { unsigned char b=inp(0x71); outp(0x70,0x8B); outp(0x71, b|0x40); } // PIE on
 outp(0x70, 0x8A); { unsigned char a=inp(0x71); outp(0x70,0x8A); outp(0x71, (a&0xF0)|0x09); } // 128 Hz
 outp(0x70, 0x0C); inp(0x71); // clear pending
 outp(0x70, 0x00); // re-enable NMI
 __asm__ __volatile__("sti");
 covox_armed = 1;
}

static void COVOX_disarm(void)
{
 if(!covox_armed) return;
 outp(0x43, 0x34); outp(0x40, 0); outp(0x40, 0);
 outp(0x70, 0x8B); { unsigned char b=inp(0x71); outp(0x70,0x8B); outp(0x71, b&~0x40); } // PIE off
 outp(0x70, 0x00);
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
 aui->card_irq = 8;
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
