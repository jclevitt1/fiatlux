# POC1 - Breadboard Prototype

**Goal:** Prove the core concept works - camera tracks paper movement, pressure detects pen contact, data syncs to backend.

## Architecture

See `poc1-diagram.mmd` (render at https://mermaid.live)

```
[Camera] → [ESP32-S3] → [Flash Storage] → [WiFi Sync] → [Backend]
   ↑            ↑
[Paper]    [Pressure Sensor]
```

## Components

| Part | Model | Pins Used |
|------|-------|-----------|
| MCU | ESP32-S3-DevKitC-1 | - |
| Camera | OV2640 | GPIO 4-7, 13, 15-22 |
| Pressure | FSR 402 | GPIO 1 (ADC) |
| Flash | W25Q128 | GPIO 10-13 (SPI) |
| Power | TP4056 + LiPo 500mAh | VIN |

## Data Flow

1. **Capture** - Camera grabs frames at 100+ fps
2. **Track** - Optical flow calculates pen movement relative to paper
3. **Pressure** - FSR detects contact + pressure level
4. **Combine** - Create stroke point: `{x, y, pressure, timestamp}`
5. **Store** - Buffer stroke points to flash
6. **Sync** - On trigger, POST to `/ingest/pen` endpoint
7. **Process** - Backend writes to `raw/`, worker summarizes

## Pin Assignments

```
ESP32-S3-DevKitC-1
├── Camera (OV2640)
│   ├── SIOD  → GPIO 4
│   ├── SIOC  → GPIO 5
│   ├── VSYNC → GPIO 6
│   ├── HREF  → GPIO 7
│   ├── PCLK  → GPIO 13
│   └── D0-D7 → GPIO 15-22
│
├── Pressure (FSR 402)
│   └── Signal → GPIO 1 (ADC)
│       └── 10kΩ pull-down to GND
│
├── Flash (W25Q128)
│   ├── CS   → GPIO 10
│   ├── CLK  → GPIO 12
│   ├── MOSI → GPIO 11
│   └── MISO → GPIO 13
│
└── Power
    └── VIN ← TP4056 output (3.7-4.2V from LiPo)
```

## Success Criteria

- [ ] Camera captures frames
- [ ] Can detect paper texture / movement
- [ ] FSR reads pressure values (0-4095)
- [ ] Stroke data saves to flash
- [ ] WiFi sync uploads to backend
- [ ] Backend receives and stores data
- [ ] Worker processes uploaded strokes

## Files

```
poc1/
├── README.md           # This file
├── poc1-diagram.mmd    # Architecture diagram
├── firmware/           # ESP32 code (TODO)
└── test-scripts/       # Python test scripts (TODO)
```
