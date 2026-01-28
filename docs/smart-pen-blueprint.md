# Smart Pen Prototype Blueprint

## Design Philosophy
- Local storage, batch sync (not real-time streaming)
- Module on end opposite ink tip
- USB-C for charging + data sync
- WiFi sync when available, USB fallback

---

## Phase 1: Breadboard Prototype (Prove the concept)

Goal: Get camera + pressure sensor → MCU → storage → sync working. Not pen-shaped yet.

### Core Components

| Component | Specific Part | Purpose | Price | Source |
|-----------|---------------|---------|-------|--------|
| **MCU** | ESP32-S3-DevKitC-1 | Brain + WiFi/BLE + camera interface | ~$10 | [Amazon](https://amazon.com) / [Adafruit](https://adafruit.com) |
| **Camera** | OV2640 module (small) | Captures paper surface | ~$8 | AliExpress / Amazon |
| **Pressure Sensor** | FSR 402 (Interlink) | Detects pen pressure | ~$7 | [Adafruit](https://www.adafruit.com/product/166) / SparkFun |
| **Flash Storage** | W25Q128 (16MB SPI flash) | Stores stroke data locally | ~$2 | AliExpress / Digikey |
| **Battery** | 3.7V LiPo 400mAh (small) | Power | ~$5 | Adafruit / Amazon |
| **Charging** | TP4056 USB-C module | Charge management | ~$2 | AliExpress / Amazon |
| **Dev supplies** | Breadboard, jumper wires, resistors | Prototyping | ~$15 | Amazon |

**Phase 1 Total: ~$50-60**

### Wiring Overview
```
                    +------------------+
                    |    ESP32-S3      |
                    |                  |
  [OV2640 Camera]---|--GPIO (CSI/SPI)  |
                    |                  |
  [FSR Pressure]----|--GPIO (ADC pin)  |
                    |                  |
  [W25Q128 Flash]---|--SPI bus         |
                    |                  |
  [TP4056 + LiPo]---|--VIN             |
                    +------------------+
                           |
                      WiFi/USB sync
                           |
                      [Your Backend]
```

### ESP32-S3 Pin Assignments (tentative)
```
Camera (OV2640):
  - SIOD  → GPIO 4
  - SIOC  → GPIO 5
  - VSYNC → GPIO 6
  - HREF  → GPIO 7
  - PCLK  → GPIO 13
  - D0-D7 → GPIO 15-22

Pressure Sensor (FSR):
  - One leg → 3.3V
  - Other leg → GPIO 1 (ADC) + 10kΩ resistor to GND

Flash (W25Q128):
  - CS   → GPIO 10
  - CLK  → GPIO 12
  - MOSI → GPIO 11
  - MISO → GPIO 13
```

---

## Phase 2: Miniaturization (Pen-sized)

Goal: Custom PCB, smaller components, actual pen form factor.

### Upgraded Components

| Component | Specific Part | Size | Price |
|-----------|---------------|------|-------|
| **MCU** | ESP32-S3-WROOM-1 (module only) | 18x25mm | ~$4 |
| **Camera** | OV7670 (tiny) or GC0328 | 8x8mm | ~$5 |
| **Pressure** | Piezo film sensor | Paper thin | ~$10 |
| **Flash** | W25Q128 SOIC-8 | 5x4mm | ~$1 |
| **Battery** | LiPo 100-200mAh cylindrical | 8x30mm | ~$5 |
| **PMIC** | BQ24072 (TI) | 3x3mm QFN | ~$3 |
| **PCB** | Custom (JLCPCB/PCBWay) | Your design | ~$20 for 5 |

### Form Factor Target
```
Total module size: ~15mm diameter x 25mm length
(like a fat pen cap on the end)

[====INK TIP====|-------barrel-------|●MODULE●]
                                      ↑
                              - Camera (angled down)
                              - MCU + Flash
                              - Battery
                              - USB-C port
```

---

## Phase 3: Production Prototype

- Work with contract manufacturer
- Injection molded enclosure
- FCC/CE certification prep
- Beta units

---

## Firmware Architecture

```
┌─────────────────────────────────────────┐
│              MAIN LOOP                  │
├─────────────────────────────────────────┤
│  1. Camera capture (100+ fps)           │
│  2. Optical flow calculation            │
│  3. Read pressure sensor                │
│  4. Combine into stroke point           │
│  5. Store to flash buffer               │
│  6. Check for sync trigger              │
│     - USB connected?                    │
│     - WiFi available?                   │
│     - Button pressed?                   │
│  7. If sync: upload to backend          │
└─────────────────────────────────────────┘
```

### Key Algorithms Needed
1. **Optical flow** - Track paper texture movement (OpenCV has examples, need to port to ESP32)
2. **Stroke segmentation** - Detect pen lift (pressure < threshold)
3. **Data compression** - Strokes are just arrays of (x, y, pressure, time) - compress before storage

---

## Software Stack

### On-device (ESP32)
- ESP-IDF or Arduino framework
- ESP32 Camera driver
- Custom optical flow (simplified)
- LittleFS for flash storage
- WiFi + HTTP client for sync

### Backend (already built!)
Your existing FiatLux backend with new endpoint:
```
POST /ingest/pen
  - Accepts stroke data
  - Writes to raw/ storage
  - Triggers summarize/create workers
```

---

## Order List for Phase 1

### From Amazon (fast shipping)
- [ ] ESP32-S3-DevKitC-1 (~$10)
- [ ] Breadboard + jumper wires kit (~$10)
- [ ] OV2640 camera module (~$10)
- [ ] 3.7V LiPo battery 500mAh (~$8)
- [ ] USB-C breakout board (~$6)

### From Adafruit (quality + documentation)
- [ ] FSR 402 pressure sensor (~$7)
- [ ] TP4056 charger or PowerBoost 500 (~$10)

### From AliExpress (cheap, slow - order now)
- [ ] W25Q128 flash modules 5-pack (~$3)
- [ ] Extra OV2640 modules 3-pack (~$12)
- [ ] ESP32-S3-WROOM modules for Phase 2 (~$8)
- [ ] Small LiPo batteries variety pack (~$10)

**Total Phase 1 order: ~$80-100**

---

## Learning Resources

### ESP32 Camera
- https://github.com/espressif/esp32-camera
- https://randomnerdtutorials.com/esp32-cam-video-streaming-face-recognition-arduino-ide/

### Optical Flow
- https://docs.opencv.org/4.x/d4/dee/tutorial_optical_flow.html
- For ESP32: simplified Lucas-Kanade or block matching

### FSR Pressure Sensors
- https://learn.adafruit.com/force-sensitive-resistor-fsr/using-an-fsr

### PCB Design (Phase 2)
- KiCad (free): https://www.kicad.org/
- EasyEDA (web-based): https://easyeda.com/

---

## Timeline Estimate

| Phase | Duration | Outcome |
|-------|----------|---------|
| Phase 1 | 2-4 weeks | Working breadboard prototype, proves concept |
| Phase 2 | 4-8 weeks | Custom PCB, pen-shaped prototype |
| Phase 3 | 3-6 months | Production-ready prototype, certification |

---

## Open Questions

1. **Camera angle** - How far from tip? What angle? Need to test.
2. **Optical flow accuracy** - Will simplified algorithm be good enough?
3. **Power budget** - How long between charges?
4. **Sync UX** - Button? Auto when docked? WiFi auto-detect?
5. **Pen ink compatibility** - Standard cartridge? Which one?

---

## Next Steps

1. Order Phase 1 parts
2. While waiting: study ESP32-CAM examples
3. Build basic camera → display pipeline
4. Add optical flow calculation
5. Add pressure sensor
6. Add flash storage
7. Add WiFi sync to your backend
8. Test end-to-end: write → sync → worker processes
