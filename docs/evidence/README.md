---
document_id: ESP32S3-EVID-INDEX
title: "Evidence Repository Instructions"
phase: ""
cluster: ""
work_package: ""
status: "Draft"
version: "0.1"
owner: "Me"
approver: "Me"
classification: "Internal Engineering"
created: "2026-07-14"
baseline_gate: "G-A"
platform: "ESP32-S3, 8 MB flash baseline"
toolchain: "ESP-IDF 6.0.x"
---

# Evidence Repository Instructions

| Control field | Value |
|---|---|
| Document ID | `ESP32S3-EVID-INDEX` |
| Version | `0.1` |
| Status | Draft |
| Owner / approver | Me |
| Product baseline | Heltec WiFi LoRa 32 V3 / exact revision TBD |
| Target gate | G-A — Phase A baseline approval |
| Change control | Changes after baseline require a recorded change request |
| Evidence rule | A claim is complete only when linked evidence exists |

> **Control note:** `TBD-*` items are not omissions. They are controlled decisions that require an owner, due date, and closure evidence before the applicable gate.


## Purpose

Store raw and derived proof used to complete WBS items and verify requirements.

## Folder rules

| Folder | Content |
|---|---|
| `logs/` | Serial, test-run, build, network, and fault-injection logs |
| `screenshots/` | UI, tool output, scope captures, setup photos |
| `measurements/` | CSV/raw measurements and analysis |
| `datasheets/` | Exact approved vendor documents and schematic revisions |

## Prohibited content

- Production private keys.
- Wi-Fi passwords.
- LoRaWAN root/session keys.
- Access tokens.
- Personal information not required for engineering.
- Unlicensed third-party material.

## Required naming

`YYYY-MM-DD_WBS_TEST_BOARD_RESULT.ext`

## Evidence acceptance

The evidence index must identify the generating test, hardware, firmware commit, configuration, result, and relative path.
