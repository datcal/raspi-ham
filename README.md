# raspi-ham

portable ham radio SDR setup. raspberry pi zero w + rtl-sdr v3 in a backpack, streams radio to your ipad/iphone over wifi.

i wanted to listen to ham radio freqs on my ipad while walking around. no screen on the pi, no keyboard, just plug in the sdr, press a button, and go.

## what it does

- pi runs `rtl_tcp` which streams raw IQ data over TCP
- you connect with an SDR app on your ipad (i use [SDR Receiver](https://apps.apple.com/app/sdr-receiver/id1289939888) ~$5)
- two physical buttons on the case: one connects to your phone hotspot, other one connects to home wifi
- also does ADS-B aircraft tracking with dump1090 (switch modes via ssh)
- covers everything: VHF/UHF (144/430 MHz), HF (shortwave, direct sampling), ADS-B (1090 MHz)
- optional: plug in a USB WiFi adapter (mine is TP-Link RTL8812AU) for WiFi monitoring/capture via aircrack-ng

## hardware

- raspberry pi zero w
- rtl-sdr v3 dongle
- some kind of antenna (i have a bunch, check below)
- 2 push buttons + 2 LEDs for the case
- power source (lipo, power bank, whatever)
- micro-USB OTG hub (if using USB WiFi adapter alongside the SDR)
- USB WiFi adapter with monitor mode support (optional, for WiFi capture)
- 3d printed case (i'll share the STL when its done)

### my antennas

- HYS dual band VHF/UHF 144/430 MHz (main one for ham)
- AirNav ADS-B 1090 MHz XBoost (for aircraft tracking)
- Bingfu tactical foldable 144/430 MHz
- 6 section telescopic (for HF/general)
- HYS SMA female flexible VHF/UHF
- bias-T + LNA preamp for weak signals

### power options

still figuring out the best setup, here are the options:

**option A: single lipo (good for proof of concept)**
```
3.7V 3300mAh LiPo → TP4056 charger → MT3608 boost to 5V → Pi GPIO pins 2+6
runtime: ~3.2 hours
```

**option B: two lipos in parallel**
```
same as above but 6600mAh total
runtime: ~6.4 hours
```

**option C: usb power bank (lazy but works)**
```
any 5000mAh+ power bank → micro-usb cable → Pi
runtime: ~8 hours, zero extra circuit
```

total draw is about 570mA at 5V (~2.85W) with the sdr running and wifi active.

## quick start

flash [Raspberry Pi OS Lite (Bookworm 32-bit)](https://www.raspberrypi.com/software/) to an SD card, enable SSH, boot it up, then:

```bash
curl -sL https://raw.githubusercontent.com/datcal/raspi-ham/main/install.sh | sudo bash
```

this does everything: updates the system, builds rtl-sdr drivers, installs dump1090, sets up systemd services, configures the firewall, the whole thing. takes maybe 20-30 min on a pi zero (most of that is compiling).

after install:

```bash
# 1. set your wifi networks
sudo nano /etc/raspi-ham/wifi.conf

# 2. apply wifi config
sudo raspi-ham-setup-wifi

# 3. (optional) set up MQTT remote control
sudo nano /etc/raspi-ham/remote.conf

# 4. reboot
sudo reboot
```

then connect your ipad to the same network, open your sdr app, point it at the pi's IP on port 1234.

## remote control (web panel)

you can control the pi from anywhere via your own website. tap a button on the web panel → MQTT message → pi executes it in <1 second.

**setup:**

1. sign up for [HiveMQ Cloud](https://www.hivemq.com/mqtt-cloud-broker/) (free tier, 25 devices)
2. create a cluster, create credentials
3. upload `web/index.php` and `web/phpMQTT.php` to your website
4. edit the MQTT config in both files:
   - `web/index.php` → `$MQTT_HOST`, `$MQTT_USER`, `$MQTT_PASS`
   - `/etc/raspi-ham/remote.conf` on the pi → same broker details
5. reboot the pi or `sudo systemctl restart raspi-ham-remote`

the web panel shows current status (wifi network, active mode) and lets you:

- switch wifi (hotspot / home)
- change SDR mode (sdr / adsb)
- toggle monitor mode
- control bias-T (LNA power)

## buttons

hold for 1 second (not just tap - prevents accidental switches):

| button | GPIO | what it does |
|--------|------|-------------|
| A | GPIO17 (pin 11) | switch to iphone hotspot |
| B | GPIO27 (pin 13) | switch to home wifi |

LEDs:
- green (GPIO5, pin 29): hotspot active
- blue (GPIO6, pin 31): home wifi active
- fast blink = switching, solid = connected, 3 slow blinks = error

## mode switching

one sdr dongle = one mode at a time. switch via ssh:

```bash
raspi-ham-mode sdr       # rtl_tcp on port 1234 (default)
raspi-ham-mode adsb      # dump1090 on port 8080
raspi-ham-mode monitor   # USB WiFi adapter → monitor mode
raspi-ham-mode managed   # USB WiFi adapter → back to normal
raspi-ham-mode status    # what's running?
```

## button circuit

```
    3.3V (pin 1)
        │
     ┌──┴──┐  ┌──┴──┐
     │ 10k │  │ 10k │   pull-up resistors
     └──┬──┘  └──┬──┘
        │        │
  GPIO17├──┐ GPIO27├──┐
        │  │     │   │
        │ 100nF  │  100nF  debounce caps
        │  │     │   │
       [BTN]    [BTN]
        │        │
       GND (pin 9)


    GPIO5 ──[330Ω]──[LED green]──GND (pin 14)
    GPIO6 ──[330Ω]──[LED blue]──GND (pin 14)
```

buttons go between GPIO and ground. internal pull-ups + external 10k + 100nF cap for clean debounce.

## rtl_tcp tuning

default config is safe for pi zero w. if you wanna tweak:

```bash
sudo nano /etc/raspi-ham/rtl-tcp.conf
sudo systemctl restart rtl-tcp
```

| param | default | notes |
|-------|---------|-------|
| sample rate | 1.024 MSPS | don't go above 2.048, wifi can't handle it |
| buffers | 32 | prevents audio dropouts |
| port | 1234 | standard rtl_tcp port |
| gain | 0 (AGC) | auto gain, change if you know your setup |

## useful commands

```bash
# check if dongle is detected
rtl_test -t

# watch rtl_tcp logs
journalctl -u rtl-tcp -f

# watch button presses
journalctl -u wifi-switch -f

# service status
systemctl status rtl-tcp
systemctl status wifi-switch

# enable bias-T for LNA
rtl_biast -b 1

# find pi's IP
hostname -I
```

## wifi monitoring (optional)

if you have a USB WiFi adapter that supports monitor mode (like TP-Link with RTL8812AU chipset), the install script builds the aircrack-ng driver automatically. you need a micro-USB OTG hub to plug both the SDR and WiFi adapter in.

```
Pi Zero W → OTG hub → RTL-SDR v3 (ham radio)
                     → USB WiFi (monitor mode)
```

the built-in wifi (wlan0) stays connected to your phone/home network for SSH. the USB adapter does the monitoring independently.

```bash
# put USB WiFi in monitor mode
sudo raspi-ham-mode monitor

# scan nearby networks (default 30 seconds)
sudo raspi-ham-monitor scan
sudo raspi-ham-monitor scan 60    # scan for 60 seconds

# capture packets on a specific channel
sudo raspi-ham-monitor capture 6  # channel 6
sudo raspi-ham-monitor capture 11

# hop across all channels while capturing
sudo raspi-ham-monitor channel-hop

# list your captures
raspi-ham-monitor list

# copy a capture to your laptop for analysis in wireshark
scp pi@<pi-ip>:/opt/raspi-ham/captures/capture-ch6-*.pcap .

# when done, put adapter back to normal
sudo raspi-ham-mode managed
```

captures are saved to `/opt/raspi-ham/captures/`. analyze them with wireshark on your main machine — the pi zero is too weak for real-time analysis.

**authorized use only** — only use on your own networks or with written permission. you know the deal.

### supported USB WiFi adapters

the install builds `rtl8812au` driver from the aircrack-ng repo. works with:

- TP-Link Archer T2U / T2U Nano / T3U (RTL8811AU/RTL8812AU)
- Alfa AWUS036ACH (RTL8812AU) — the classic
- Alfa AWUS036ACS (RTL8811AU)
- most other RTL8812AU/RTL8811AU based adapters

## antenna guide

which antenna to use for what. all mine have SMA connectors so just swap them on the RTL-SDR.

| band | frequency | antenna to use | notes |
|------|-----------|---------------|-------|
| AM broadcast | 530 kHz – 1.7 MHz | telescopic (fully extended) | HF direct sampling mode, extend to max length |
| shortwave | 3 – 30 MHz | telescopic (fully extended) | best you can do portable. a long wire antenna would be better at home |
| 80m ham | 3.5 – 4.0 MHz | telescopic | local/regional contacts, better at night |
| 40m ham | 7.0 – 7.3 MHz | telescopic | most popular HF ham band |
| 20m ham | 14.0 – 14.35 MHz | telescopic | DX long distance, good during daytime |
| CB radio | 27 MHz | telescopic | citizens band, truckers etc |
| 2m ham | 144 – 146 MHz | HYS dual band / Bingfu tactical / HYS flexible | any of the VHF/UHF antennas work great here |
| FM broadcast | 88 – 108 MHz | HYS dual band / telescopic | FM radio stations, anything works |
| 70cm ham | 430 – 440 MHz | HYS dual band / Bingfu tactical / HYS flexible | local repeaters, simplex |
| ADS-B | 1090 MHz | AirNav ADS-B XBoost | purpose-built for this, way better than general antennas |
| ADS-B (no dedicated antenna) | 1090 MHz | HYS dual band (UHF side) | works but weaker, ~50% range compared to dedicated antenna |

**rule of thumb:**
- HF (below 30 MHz) → telescopic antenna, fully extended, direct sampling mode kicks in automatically
- VHF/UHF (144/430 MHz) → any of the dual band antennas
- ADS-B (1090 MHz) → dedicated ADS-B antenna, or UHF antenna as fallback
- **bias-T + LNA** → use for weak signals on any band. turn on via web panel or `rtl_biast -b 1`

**pro tip:** for HF at home, hang 10m of wire out a window. connect it to the RTL-SDR via an SMA wire adapter. way better than any telescopic antenna for shortwave.

## ios sdr apps

you need an app that supports rtl_tcp protocol:

| app | price | notes |
|-----|-------|-------|
| **CocaSDR** | free | basic but works. good for testing |
| **SDR Receiver** | ~$5 | full featured, waterfall display, many demod modes |
| **SmartSDR** | ~$10 | advanced, good UI, supports rtl_tcp |

connect to your pi's IP address, port 1234. set sample rate to 1.024 MSPS to match the pi config.

**how to connect:**
1. make sure your ipad is on the same network as the pi (home wifi or phone hotspot)
2. find pi's IP: `hostname -I` (via SSH) 
3. in the app: server = pi's IP, port = 1234
4. hit connect, you should see the waterfall

## berlin frequency guide

stuff you can listen to in berlin with this setup. i'll be at Tempelhof this saturday — it's perfect for SDR because it's a huge open field (old airport) with clear line of sight in all directions and very low RF noise.

**legal note for germany:** receiving radio is legal. sharing/distributing content from non-public frequencies is illegal. emergency services (police/fire) use encrypted TETRA — you can't decode it anyway. with a ham license you're fully legit for amateur bands.

### aviation (VHF airband: use dual band antenna)

BER airport is ~20km from Tempelhof but you'll hear everything clearly from the open field.

| what | frequency | notes |
|------|-----------|-------|
| BER Tower | 127.870 MHz | main tower frequency |
| BER Tower 2 | 120.020 MHz | secondary |
| BER Ground | 121.600 MHz | taxiing aircraft |
| BER ATIS | 124.950 MHz | automated weather/runway info, good to test your setup |
| BER Approach | 123.220 MHz | incoming aircraft |
| BER Approach 2 | 119.700 MHz | |
| BER Departure | 120.620 MHz | outgoing aircraft |
| Emergency | 121.500 MHz | international aviation distress (hopefully quiet) |
| Helicopter traffic | 123.050 MHz | common heli frequency over Berlin |

### 2m ham repeaters — berlin (use dual band antenna)

check [repeaterbook.com](https://www.repeaterbook.com/row_repeaters/location_search.php?state_id=DE&type=city&loc=Berlin) or [repeatermap.de](https://www.repeatermap.de) for current list. repeaters change, these databases are live.

common Berlin area 2m repeaters to try:

| callsign | output freq | offset | notes |
|----------|-------------|--------|-------|
| DB0BLO | 145.600 MHz | -0.6 MHz | Berlin, very active |
| DB0SP | 145.750 MHz | -0.6 MHz | Berlin Spandau |
| DB0BER | 145.650 MHz | -0.6 MHz | Berlin area |

**tip:** scan 145.000 – 146.000 MHz in your SDR app. you'll see active repeaters as spikes on the waterfall.

### 70cm ham repeaters — berlin (use dual band antenna)

| callsign | output freq | offset | notes |
|----------|-------------|--------|-------|
| DB0BLO | 438.650 MHz | -7.6 MHz | same club as above, UHF |
| DB0SP | 439.150 MHz | -7.6 MHz | Berlin Spandau UHF |

scan 438.000 – 440.000 MHz to find active ones.

### FM radio — berlin (any antenna works)

| station | frequency | what |
|---------|-----------|------|
| Star FM | 87.9 MHz | rock |
| Fritz (rbb) | 102.6 MHz | alternative/electronic |
| radioeins (rbb) | 95.8 MHz | talk/music |
| Deutschlandfunk | 97.7 MHz | news/culture |
| FluxFM | 100.6 MHz | indie |
| Berliner Rundfunk | 91.4 MHz | oldies/pop |
| Kiss FM | 98.8 MHz | dance/pop |
| Radio Energy | 103.4 MHz | pop |

### shortwave / HF (use telescopic antenna, fully extended)

best reception from Tempelhof will be daytime HF bands. bring the telescopic antenna.

| what | frequency | notes |
|------|-----------|-------|
| 40m ham band | 7.000 – 7.200 MHz | most active ham band in europe, SSB above 7.050 |
| 20m ham band | 14.000 – 14.350 MHz | DX band, active during daytime |
| BBC World Service | various | check short-wave.info for current schedule |
| Radio Romania | 7.325 MHz, 9.700 MHz | often strong in Berlin |
| China Radio Int'l | 7.350 MHz, 9.880 MHz | strong signal into europe |
| WTWW (US religious) | 9.475 MHz | sometimes audible in europe |

### ADS-B aircraft tracking (use ADS-B antenna)

| what | frequency | notes |
|------|-----------|-------|
| Mode S transponders | 1090 MHz | all commercial aircraft |

from Tempelhof you'll track 100+ aircraft easily. switch to ADS-B mode:
```bash
sudo raspi-ham-mode adsb
# then open browser to pi's IP:8080 for the map
```

### what you WON'T hear

| what | why |
|------|-----|
| Police/Fire/EMS | TETRA digital encrypted (380-395 MHz). can't decode. |
| BVG (public transport) | also TETRA encrypted |
| Deutsche Bahn (railway) | GSM-R encrypted digital |
| Cell phones | encrypted, illegal to intercept anyway |

## files

```
raspi-ham/
├── install.sh                # one-liner installer
├── config/
│   ├── wifi.conf.template    # wifi creds template
│   ├── rtl-tcp.conf          # sdr tuning params
│   └── remote.conf.template  # MQTT broker config
├── scripts/
│   ├── wifi-switch.py        # GPIO button daemon
│   ├── mode-switch.sh        # sdr/adsb/monitor toggle
│   ├── wifi-monitor.sh       # wifi capture/scanning tools
│   ├── remote-control.sh     # MQTT subscriber daemon
│   ├── start-rtl-tcp.sh      # rtl_tcp wrapper
│   └── setup-wifi.sh         # apply wifi creds
├── web/
│   ├── index.php             # control panel (upload to your website)
│   └── phpMQTT.php           # MQTT client library
└── systemd/
    ├── rtl-tcp.service
    ├── raspi-ham-dump1090.service
    ├── raspi-ham-remote.service
    └── wifi-switch.service
```

## other gear

i also have 3x baofeng uv-5r, mixer, mic/speaker stuff. the rtl-sdr is receive only but maybe i'll add tx support later with a separate board.

## license

MIT - do whatever you want with it

## 73

de datcal
