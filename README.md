# SoC-IP-Portfolio

SystemVerilog ile yazılmış, yeniden kullanılabilir küçük RTL IP blokları ve
her blok için cocotb + Verilator tabanlı testbench'ler.

Amaç: her modülü "yazdım" değil **"yazdım ve doğruladım"** seviyesinde tutmak.

## Modüller ve doğrulama durumu

| Modül | Dosya | Test | Durum |
| --- | --- | --- | --- |
| Adder | `arithmetic/adder.sv` | `tb/test_adder.py` | ✅ PASS |
| Multiplier | `arithmetic/multiplier.sv` | `tb/test_multiplier.py` | ✅ PASS |
| MAC | `arithmetic/mac.sv` | `tb/test_mac.py` | ✅ PASS |
| CORDIC | `arithmetic/cordic.sv` | — | ⚠️ Taslak (bkz. Bilinen sorunlar) |
| Sync FIFO | `memory/fifo_sync.sv` | `tb/test_fifo_sync.py` | ✅ PASS |
| Register file | `memory/register_file.sv` | `tb/test_register_file.py` | ✅ PASS |
| GPIO | `peripherals/gpio.sv` | `tb/test_gpio.py` | ✅ PASS |
| UART | `peripherals/uart.sv` | `tb/test_uart.py` | ✅ PASS (RX hatası düzeltildi) |
| SPI master | `peripherals/spi.sv` (`spi_master`) | `tb/test_spi.py` | ⚠️ Veri yolu PASS, SCLK kenar hatası açık |

## Testleri çalıştırma

Gerekli: Verilator + cocotb (1.9.x).

```bash
cd tb
# kullanim: python run.py <toplevel> <test_modulu> <kaynak.sv> [PARAM=deger ...]
python run.py adder         test_adder         ../arithmetic/adder.sv
python run.py mac           test_mac           ../arithmetic/mac.sv
python run.py fifo_sync     test_fifo_sync     ../memory/fifo_sync.sv
python run.py register_file test_register_file ../memory/register_file.sv
python run.py gpio          test_gpio          ../peripherals/gpio.sv
python run.py uart          test_uart          ../peripherals/uart.sv CLK_FREQ=8 BAUD_RATE=1
python run.py spi_master    test_spi           ../peripherals/spi.sv
```

## Bilinen sorunlar

- **CORDIC (taslak):** Açı tablosu 16 iterasyon için ama yalnızca 9 değer dolu
  (gerisi 0). Açı sabitleri (`32'h2_C8CB_F0E8` vb.) 32 biti aşıyor ve truncate
  oluyor. Sabit nokta formatı belgelenmemiş. Düzgün testbench için önce format
  ve açı tablosunun netleştirilmesi gerekiyor.
- **SPI master – SCLK kenar sayısı:** 8 bitlik aktarımda yalnızca 7 SCLK
  yükselen kenarı üretiliyor; son örnekleme cevriminde `sclk <= ~sclk` ile
  `sclk <= CPOL` çakışıyor ve son kenar bastırılıyor. Master kendi RX'ini FSM
  olayından örneklediği için içi doğru, ama gerçek bir slave son biti kaçırır.
  `tb/test_spi.py::test_spi_master_sclk_edges` bu hatayı sabitliyor.
- **SPI slave – çok sürücü:** `rx_shift`, `tx_shift`, `miso` sinyalleri birden
  fazla always bloğunda sürülüyor; temiz sentezlenebilir RTL değil, elden
  geçirilmesi gerekiyor.
- **GPIO – giriş okuma yok:** `pin_in` girişi modülde hiç kullanılmıyor; giriş
  pinlerini okuma yolu yok (yalnızca çıkış + yön).

## Yol haritası (henüz yok)

Aşağıdaki bloklar planlı, henüz uygulanmadı: bus (AXI4-Lite, AXI4-Stream, APB),
DSP (FIR, IIR, FFT, CIC), ML (systolic array, PE), crypto (AES-128, SHA-256).
Formal doğrulama (SymbiYosys) FIFO ve adder için eklenecek.
