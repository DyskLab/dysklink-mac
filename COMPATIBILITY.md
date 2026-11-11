# Kompatibilitas DyskLink

Terakhir diperbarui: 11 November 2026.

## Ringkasan

| | Didukung |
|---|---|
| **Prosesor Mac** | Semua Apple Silicon: M1, M2, M3, M4 (dan penerusnya), termasuk varian Pro, Max, dan Ultra |
| **Mac Intel** | Tidak didukung. Aplikasi hanya dibuat untuk arm64, dan kontrol baterai, layar, serta daya memakai antarmuka khusus Apple Silicon |
| **macOS** | 15 Sequoia atau lebih baru (`LSMinimumSystemVersion` 15.0) |
| **Android** | 8.0 (API 26) atau lebih baru; target API 36 |
| **Browser (ekstensi YouTube)** | Firefox 115+ dan Zen (Manifest V3); Safari dan browser Chromium lewat AppleScript, tanpa ekstensi |

**Sudah diuji langsung:** MacBook Air 13" M4 (Mac16,12), macOS 27.0.1, dengan HP Android dan monitor LG L24D (USB-C Power Delivery 75 W).
**Belum diuji langsung:** chip lain, Mac desktop, dan macOS 15 atau 26. Bagian di bawah menjelaskan apa yang diharapkan, berdasarkan cara tiap fitur dibuat.

## Biner

| File | Arsitektur | Minimum OS |
|---|---|---|
| `DyskLink.app/Contents/MacOS/DyskLink` | arm64 | macOS 15.0 |
| `dysklink-power` (helper root untuk kontrol pengisian) | arm64 | macOS 15.0 |
| `dysklink-browser-host` (native messaging Firefox) | arm64 | macOS 15.0 |

Tidak ada kode yang bergantung pada jumlah inti P/E atau nama chip, jadi M1 sampai M4 menjalankan biner yang sama.

## Menurut jenis Mac

| Jenis Mac | Fitur yang tersedia |
|---|---|
| **MacBook Air / Pro dengan notch** (Air M2 dan lebih baru, Pro 14"/16" 2021 dan lebih baru) | Semua fitur. Notch tampil di sekitar kamera |
| **MacBook tanpa notch** (Air M1, Pro 13" M1/M2) | Semua fitur. Notch tampil sebagai bar kecil di tengah atas layar, dan bisa disembunyikan saat tertutup |
| **Mac desktop** (Mac mini, iMac, Mac Studio, Mac Pro) | Semua fitur, kecuali yang butuh baterai: Charge Limit, Top Up, Discharge, Sailing, kalibrasi, Battery Health, dan grafik baterai di menu bar disembunyikan otomatis. Notch tampil sebagai bar di layar utama |

## Fitur yang bergantung pada hardware

| Fitur | Yang dipakai | M1 | M2 | M3 | M4 | Catatan |
|---|---|:-:|:-:|:-:|:-:|---|
| Batas pengisian, Discharge, Top Up | Kunci SMC `CHIE` (memutus input charger) lewat helper root | ✓ | ✓ | ✓ | ✓ | Dicek saat aplikasi jalan: kalau `CHIE` tidak ada, kartu menampilkan "tidak tersedia" dan tidak mengubah apa pun |
| Menahan di 80–100% tanpa memakai baterai | Charge Limit bawaan macOS (`pmset -g battlimit`) | ✓ | ✓ | ✓ | ✓ | Hanya di versi macOS yang punya Charge Limit di System Settings › Battery. Tanpa itu DyskLink memutus charger di batas dan baterai turun sedikit |
| Suhu baterai | SMC `TB0T` | ✓ | ✓ | ✓ | ✓ | Kalau tidak terbaca, suhu dikosongkan dan perlindungan panas tidak aktif |
| Daya sistem dan adaptor | SMC `PSTR`, `PDTR`, IOKit `AppleSmartBattery` | ✓ | ✓ | ✓ | ✓ | Opsional; di desktop sebagian angka tidak tersedia |
| Daya GPU | IOReport "Energy Model" › GPU Energy | ✓ | ✓ | ✓ | ✓ | macOS 27 melaporkan energi CPU sebagai nol, jadi hanya GPU yang ditampilkan terpisah |
| Kecerahan layar bawaan dan Apple Display | DisplayServices (privat) | ✓ | ✓ | ✓ | ✓ | |
| Kecerahan/volume monitor lain | DDC/CI lewat `DCPAVServiceProxy` dan `IOAVService` | ✓* | ✓ | ✓ | ✓ | *Port HDMI bawaan Mac mini M1 tidak meneruskan DDC; lewat USB-C/Thunderbolt bisa. Adaptor DisplayLink tidak mendukung DDC. Kalau DDC tidak ada, monitor diredupkan dengan lapisan gelap |
| HP sebagai layar kedua | `CGVirtualDisplay` (privat) | ✓ | ✓ | ✓ | ✓ | Layar virtual tidak memakai jalur monitor fisik, tapi belum diuji pada M1/M2 dasar yang batas monitornya kecil |
| Layar Mac di HP | ScreenCaptureKit + encoder H.264 hardware (VideoToolbox) | ✓ | ✓ | ✓ | ✓ | Semua chip M punya encoder H.264 hardware. Butuh izin Screen Recording |
| Suara Mac ke HP | ScreenCaptureKit (audio) | ✓ | ✓ | ✓ | ✓ | Butuh izin Screen Recording. Suara DyskLink sendiri tidak ikut |
| Suara HP ke Mac | Android AudioPlaybackCapture | ✓ | ✓ | ✓ | ✓ | HP Android 10+; aplikasi yang melarang rekaman tetap diam |
| PDF scan yang bisa dicari | Vision (OCR di Mac) | ✓ | ✓ | ✓ | ✓ | Berjalan di Neural Engine/CPU; lebih lambat di M1 untuk dokumen panjang |
| Low Power Mode | `pmset lowpowermode` (butuh admin atau helper) | ✓ | ✓ | ✓ | ✓ | Di desktop hanya ada pengaturan "AC Power", sesuai yang diizinkan macOS untuk model itu |
| Kunci layar, info Mac, deteksi model | `CGSSessionScreenIsLocked`, `login.framework`, `hw.model` | ✓ | ✓ | ✓ | ✓ | |

## Menurut versi macOS

| Bagian | macOS 15 | macOS 26 | macOS 27 |
|---|---|---|---|
| Aplikasi berjalan | ✓ | ✓ | ✓ (diuji) |
| Charge Limit bawaan untuk menahan di 80–100% | Tidak ada; DyskLink memutus charger di batas | Kalau tersedia di System Settings, dipakai | ✓ (diuji) |
| Gaya "Glass" di pratinjau jendela | Bahan blur biasa sebagai gantinya | Liquid Glass | Liquid Glass |
| Energi CPU di grafik daya | Mungkin terbaca | Mungkin terbaca | Selalu nol, jadi disembunyikan |

Fitur yang memakai API privat (`CGVirtualDisplay`, DisplayServices, IOReport, kunci SMC) bisa berubah di versi macOS berikutnya. Tiap fitur dicek saat aplikasi berjalan dan disembunyikan atau dinonaktifkan kalau tidak tersedia, bukan membuat aplikasi crash.

## Izin yang diminta di Mac

| Izin | Untuk |
|---|---|
| Accessibility | Kontrol dari HP (mouse, keyboard, shortcut), kontrol game, tata letak jendela, mengetik emoji |
| Screen Recording | Layar Mac di HP, layar kedua, dan suara Mac ke HP |
| Automation (per aplikasi) | Detail pemutar: sampul album Music/Spotify, posisi video YouTube di Safari/Chrome (mati secara bawaan) |
| Password admin, sekali | Memasang helper `dysklink-power` untuk kontrol pengisian dan Low Power Mode |
| Local Network | Menemukan dan terhubung ke HP lewat Bonjour (`_phonelink._tcp`) dan TLS |

## Belum didukung

- Mac Intel.
- Windows dan Linux (direncanakan, lihat `TODO.md`).
- macOS 14 atau lebih lama.
