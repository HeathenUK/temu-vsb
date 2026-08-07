@echo off
rem ===========================================================================
rem  SBCOVOX - one command: a transparent Sound Blaster on Covox + real OPL3.
rem
rem  Brings up the whole minimal stack in order and hands control back. After
rem  this runs, any DOS program (real-mode OR protected-mode/DOS-extender) that
rem  talks to an SB Pro at 220/IRQ7/DMA1 gets: PCM -> Covox on LPT1, FM -> your
rem  real OPL3 (388h passthrough).
rem
rem  The stack is layered by necessity, not by choice - on a 386 you cannot trap
rem  a game's sound ports without these underneath:
rem    JEMMEX    XMS + V86 host (lets real-mode games be trapped, gives XMS)
rem    QPIEMU    real-mode (V86) port-trap provider on JEMM
rem    HDPMI32i  DPMI host + port trapping (traps protected-mode games; DOOM)
rem    SBEMU     the SB emulator + our Covox output (card CVX)
rem
rem  Put JEMMEX.EXE, JLOAD.EXE, QPIEMU.DLL, HDPMI32I.EXE and SBEMU.EXE in this
rem  directory (or on PATH). Edit the two SET lines below for your hardware.
rem
rem  Usage:  SBCOVOX              (defaults: LPT1=378h, 11 kHz)
rem          SBCOVOX /K22050      (pass extra args straight to SBEMU)
rem ===========================================================================

rem ---- your hardware ----
set COVOX=378
set BLASTER=A220 I7 D1 T4

rem ---- substrate (only loads each piece if not already resident) ----
JEMMEX LOAD NOEMS
JLOAD QPIEMU.DLL
HDPMI32i -r -x

rem ---- the emulator: /K11025 halves 386SX CPU and is lossless for DMX ----
rem  (drop /K11025, or pass /K22050, if a game genuinely needs 22 kHz PCM)
SBEMU /K11025 %1 %2 %3 %4 %5

echo.
echo SBCOVOX ready: SB Pro on 220/IRQ7/DMA1  -  PCM to Covox %COVOX%h, FM to real OPL3.
