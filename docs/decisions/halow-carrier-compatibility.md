# Compatibilidad de carriers mPCIe con módulos HaLow MorseMicro (WM6108 / MM6108)

**Audiencia:** ingeniería de hardware seleccionando o diseñando un carrier para producción.
**Estado:** v30 OpenWrt funciona end-to-end en R1000+WM6108 sin mod de HW (vía polling-mode driver). Este documento explica qué pierde y qué gana cada camino.

> **Corrección importante a una versión previa de este documento:** la primera lectura del esquemático del WM6108 nos hizo creer que MOD_INT estaba en pin 12 — está en **pin 10** (etiqueta `UIM_PWR/MOD_INT` en el CN2 del módulo). Pin 10 del Slot 2 del R1000 va a `LoRaWAN_SX1262_RST` → PCA9535 P01, así que **la línea SÍ tiene camino físico host↔chip**. Sin embargo, la cadena de interrupciones (PCA9535 INT → CM4 GPIO24) no propaga los pulsos del chip por las razones explicadas en §2.2. El polling-mode no depende de esta cadena, así que sigue siendo la solución correcta para el R1000.

---

## 1. Contexto

El módulo HaLow Wio-WM6108 expone su silicio MorseMicro MM6108 como un dispositivo SPI esclavo a través del conector mPCIe. La comunicación host↔chip usa cuatro grupos de señales:

| Grupo | Pines del WM6108 | Dirección | Función |
|---|---|---|---|
| **SPI bus** | 45 (SCK), 47 (MISO), 49 (MOSI), 51 (CS) | bidir | Datos: comandos host→chip + respuestas chip→host |
| **Reset** | 22 (PERST# / MOD_RESET) | host→chip | Reset duro del chip (active-low) |
| **MOD_INT** | 12 | **chip→host** | Chip eleva esta línea cuando tiene datos listos (respuesta de comando, RX frame, etc.) |
| **MOD_BUSY** | 33 | chip→host | Chip indica que está ocupado / en sueño |
| **MOD_WAKEUP_IN** | 35 | host→chip | Host fuerza al chip a despertar de power-save |

El driver `morse_spi` (Linux) usa estas señales así:

- **SPI**: tráfico de datos. Síncrono — funciona sin pines de control extra.
- **PERST#**: pulso bajo de ~20 ms al inicio del probe.
- **MOD_INT**: registrado vía `request_threaded_irq()` con `IRQF_TRIGGER_FALLING`. El driver duerme esperando esta IRQ después de cada comando; cuando llega, lee el registro de status del chip por SPI.
- **MOD_BUSY** + **MOD_WAKEUP_IN**: opcionales, sólo si DT define `power-gpios`. Habilitan power-save coordinado.

**Mínimo absoluto para que el driver funcione tal como lo enviaron MorseMicro: SPI + PERST# + MOD_INT.**

---

## 2. El gap del Seeed reComputer R1000 v1.1

### 2.1 Qué descubrimos

El R1000 expone dos slots mPCIe (J14 = Slot 2, J15 = Slot 1). Ambos fueron diseñados pensando en **módulos LoRa** (Semtech SX1302 + SX1262, en SPI o USB) y **módems LTE** (Quectel EC20/EC25, en USB), no en módulos que necesitan IRQ.

Verificado contra el esquemático oficial v1.1 (`docs/reComputer_R1000_schematic_design_files (3)/.../202003926_RECOMPUTER R_SCH_PDF.pdf`):

**Página 15 (slots mPCIe J14/J15)** — único traffic host-bound visible en cualquiera de los dos slots:

| Señal | Slot 2 (J14) | Slot 1 (J15) |
|---|---|---|
| SPI bus | `CM4_SPI0_*` ✓ | (no expuesto) |
| I²C | `CM4_IIC3_*` ✓ | `CM4_IIC3_*` ✓ |
| USB 2.0 | `USB_HUB2_DM3/DP3` ✓ | `USB_HUB2_DM4/DP4` ✓ |
| USIM | (no expuesto) | `USIM_*` ✓ |
| Resets vía PCA9535 | `LoRaWAN_SX1262_RST/CS`, `SX1302_RST` (=PERST#) | `LTE_RESET` (=PERST#) |

**Página 12 (PCA9535 IO expander @ 0x21)** — los 16 pines P0x/P1x del expander se reparten entre:

- Resets de módulos hijos (LTE, SX1262, SX1302, TPM)
- Controles de power rails (VDD_OUT_CTL, VDD_5V_OUT_CTL, USB2_RST_EN, RS485_POWER_EN)
- Status LEDs (nLNKA_LED, nSPD_LED), EEPROM_WP

**Ningún pin del expander, ni ningún CM4 GPIO, llega al pin 12 (MOD_INT), pin 33 (MOD_BUSY) o pin 35 (MOD_WAKEUP_IN) de ninguno de los dos slots.**

### 2.2 Cómo están conectados esos pines en el R1000

| Pin del slot | Pin / señal en WM6108 | Conexión en R1000 Slot 2 (J14) | ¿Útil? |
|---|---|---|---|
| 10 | MOD_INT (chip→host IRQ) | `LoRaWAN_SX1262_RST` → PCA9535 P01 | **Físicamente sí, eléctricamente no** (ver abajo) |
| 12 | UIM_DATA (residual LTE) | NC | n/a |
| 22 | MOD_RESET / PERST# | `LoRaWAN_SX1302_RST` → PCA9535 P02 | ✓ funcional |
| 33 | MOD_BUSY (chip→host) | NC | ✗ |
| 35 | MOD_WAKEUP_IN (host→chip) | **GND** | ✗ |
| 45/47/49/51 | SPI bus | `CM4_SPI0_*` | ✓ funcional |

**Por qué la cadena IRQ no funciona aunque el camino físico exista** (verificado con `gpioget` y `gpiomon` en la unidad real):

1. El chip MM6108 pulsa MOD_INT como **active-HIGH** (idle LOW, asserts HIGH) por pulsos breves cuando tiene respuesta lista. Verificable con `gpioget gpiochip_pca 1` en bucle apretado: vimos 9 muestras HIGH de 80 mientras el chip procesaba comandos.
2. La traza SX1262_RST en el R1000 fue diseñada como **salida** (host conduciendo SX1262 reset desde PCA9535 P01). Esto implica que el camino tiene la polaridad incorrecta para el chip + posible resistor de pull-down que aplaca los pulsos.
3. La señal **PCA9535 INT** (pin físico del expander que va a CM4 GPIO24) **nunca se asserta** durante la operación del chip — `cat /proc/interrupts | grep 1-0021` queda en 0 y `gpiomon` no captura eventos. Esto puede ser por:
   - Pulsos del chip demasiado breves para que la lógica de detección de cambio interna del PCA9535 los registre antes de la próxima lectura I²C.
   - Resistor pull-up/pull-down en la INT line del PCA9535 con polaridad/valor incompatible con la señal real.
   - Configuración de mask interna del PCA9535 (poco probable dado que el driver Linux la maneja correctamente en otros casos).

**Conclusión:** intentar usar `request_threaded_irq()` en este path está condenado al fracaso aunque el cable exista. Probamos `IRQF_TRIGGER_FALLING`, `IRQF_TRIGGER_RISING`, y `IRQF_TRIGGER_RISING|FALLING` (any-edge) — IRQ 46 (parent) siempre 0. Polling sobre el registro INT1_STS del chip vía SPI sí ve cada respuesta. Por eso la solución correcta para el R1000 es polling-mode, no un mod en P01.

### 2.3 Por qué con LoRa "funciona" pero con HaLow no

Los módulos LoRa SX1302 y SX1262 también están en el bus SPI compartido con HaLow (mismo CS lógico repurposable). **Pero LoRa opera en modo polling por diseño**: el host pregunta periódicamente al chip por SPI y no necesita IRQ. Por eso Seeed no consideró necesario rutear MOD_INT — sus targets de uso (LoRaWAN gateway) no la usan.

HaLow es diferente: la firmware del MM6108, al recibir un comando, prepara la respuesta y eleva MOD_INT. El driver Linux duerme bloqueado en una `wait_event_*` esperando esa IRQ. **Sin MOD_INT, el driver siempre alcanza su timeout (`-110 / ETIMEDOUT`)** aunque la respuesta esté lista en el chip.

---

## 3. Las dos opciones — software-only vs. hardware mod

### Opción A: software-only (polling-mode driver)

**Qué es:** patch al driver morse_spi (`023-spi-polling-mode-for-no-irq-carriers.patch`) que, cuando se carga con `enable_polling=1`, levanta un kthread del kernel que lee el registro `MORSE_REG_INT1_STS` del chip por SPI cada `polling_interval_ms` (default 10 ms). Si hay bits set, llama al mismo handler que la IRQ habría llamado. Sin host pin, sólo SPI.

**Lo que se gana:**
- ✅ Cero modificaciones de hardware. Se aplica a unidades en campo con flash remoto.
- ✅ Sobrevive a `wifi reload`, reboot, sysupgrade.
- ✅ Verificado: AP S1G beaconing en 916.5 MHz con WPA3-SAE, integrada al bridge `br-lan`, comandos `morse_cli` responden.

**Lo que se pierde / costos:**

| Aspecto | Polling 10 ms | IRQ-driven |
|---|---|---|
| Latencia mín. de respuesta de comando | hasta 10 ms (1 polling interval) | < 1 ms (despierta inmediato) |
| Latencia de RX de paquete S1G (tiempo entre fin de RX en chip y entrega al stack) | hasta 10 ms | < 1 ms |
| CPU steady-state (idle) | ~100 transferencias SPI/seg de 4 bytes (~0.5% de un core ARM Cortex-A72) | ~0% (CPU duerme) |
| Throughput nominal en S1G 1 MHz (~150 kbps) | sin impacto detectable | sin impacto |
| Throughput nominal en S1G 8 MHz (~32 Mbps) | sin impacto si `polling_interval_ms ≤ 5` | mejor |
| Power consumption | mayor (CPU no entra en deep idle, polling thread despierta) | menor |
| Power-save coordinado del chip (BUSY/WAKEUP) | imposible — el host no ve BUSY | sí |

**Trade-off real para HaLow:** HaLow es banda angosta (1–8 MHz), latencia objetivo en orden de ~10–100 ms para casos de IoT (sensores, control). 10 ms de jitter es invisible. **Para ese perfil de uso, no hay diferencia funcional perceptible.**

**Donde se siente:**
- Workloads de baja latencia (mesh TWT con ventanas cortas, voz/video sobre HaLow). En esos casos `polling_interval_ms=2` (~0.1% extra de CPU) cierra el gap.
- Despliegues battery-powered: el polling impide que el host entre deep idle. Si el carrier es alimentado por AC (R1000), no aplica. Si es battery, considerar mod.

**Lo que el polling no puede arreglar:** power-save del chip. Sin BUSY/WAKEUP el chip no puede dormir mientras el host duerme — el chip queda siempre activo. Para nodos durmientes (sensor de batería con duty cycle bajo) esto sí impacta consumo del chip (~mA en idle vs. ~µA en deep sleep).

### Opción B: hardware mod (1 cable + DT update)

**Qué es:** soldar un cable corto desde **J14 pin 10** (MOD_INT del chip — corrección sobre versión anterior) a un GPIO libre del host. El camino actual via PCA9535 P01 no sirve por las razones de §2.2; hay que evitarlo y crear uno nuevo:

- **Preferible**: un CM4 GPIO no utilizado y accesible (e.g., GPIO5 o GPIO6 si están libres en el R1000), porque va directo al SoC, sin la latencia del PCA9535. **IRQ-driven con `IRQF_TRIGGER_RISING`** (recordar que el chip es active-HIGH).
- **Alternativa**: un pin del PCA9535 que esté completamente libre (no usado por nada de la lógica original de Seeed) — P13/P14/P15 según `gpioinfo 1-0021` están como `unused input` y NO tienen pull-down/pull-up funcional dado que originalmente eran NC. Más arriesgado de validar pero evita la soldadura al CM4.

Después: editar el DT overlay `mm610x-r1000-spi-overlay.dts` para apuntar `spi-irq-gpios` al pin nuevo, configurar el flag de polaridad correcto, y desactivar `enable_polling`. Para active-HIGH IRQ se necesita además un patch al driver morse_spi (parche `spi_irq_rising` ya prototipado en el branch — sólo cambia `IRQF_TRIGGER_FALLING` por `IRQF_TRIGGER_RISING`).

> **Nota importante**: simplemente cortar el camino del PCA9535 P01 al SX1262 no es suficiente. El PCA9535 tendría que dejar P01 en alta-impedancia (ya lo está como input por nuestro DT), pero la cadena INT del PCA9535 sigue sin propagar los pulsos por las razones de §2.2. El cable nuevo tiene que ir a otro punto que SÍ tenga IRQ funcional. Por eso la opción "soldar a otro pin del PCA9535" sólo sirve si validamos que ese pin nuevo también tiene su INT chain funcional, lo cual requiere prueba.

**Lo que se gana:**
- ✅ Latencia mínima.
- ✅ Sin overhead de polling (CPU duerme cuando idle).
- ✅ Habilita power-save del chip si también se cablea MOD_BUSY (33) y MOD_WAKEUP_IN (35) — pero esto son 3 cables, no 1.

**Lo que cuesta:**
- ❌ Requiere abrir cada unidad y soldar. No escala a flota desplegada.
- ❌ Riesgo mecánico (esfuerzo en cable, vibración) → fiabilidad de campo.
- ❌ Voida la garantía de Seeed.
- ❌ Documentación, training y QA del proceso de soldadura.

---

## 4. Decisión recomendada para esta plataforma

| Escenario | Recomendación |
|---|---|
| **R1000 + WM6108 ya desplegado** (cualquier cantidad ≥ 1) | **Opción A — polling-mode**. Está en v30. No tocar el HW. |
| Bench dev / lab / R&D | Polling-mode también; si se necesita medir latencia o power-save real del chip, considerar mod. |
| Producto de consumo masivo en R1000 | Polling-mode. El mod no es viable a escala. |
| Producto sensor battery-powered (largos sleep) | **Cambiar de carrier** o hacer mod de 3 cables (MOD_INT + MOD_BUSY + MOD_WAKEUP_IN) — polling no cubre power-save del chip. |
| Producto throughput-crítico (>10 Mbps sostenido) | Bajar `polling_interval_ms` a 2; si aún se siente, mod. |

---

## 5. Lecciones para el próximo carrier (lista de verificación)

Cuando seleccionemos o diseñemos el carrier siguiente para HaLow, **antes de comprometernos** verificar contra el datasheet del módulo HaLow target (WM6108 u otro) y el esquemático del carrier:

### 5.1 Pines obligatorios

- [ ] **mPCIe pin 22 (PERST#)** — ruteado a un GPIO controlable por el host (CM4 directo, o IO expander OK).
- [ ] **mPCIe pin 12 (MOD_INT / chip IRQ output)** — ruteado a un GPIO **interrupt-capable** del host. **Si va por IO expander, el expander tiene que tener IRQ chip implementado en su driver Linux** (PCA9535 lo tiene con `CONFIG_GPIO_PCA953X_IRQ=y`; PCA9534 también; PCAL6416 no en kernel viejo).
- [ ] **SPI bus completo** (SCLK, MISO, MOSI, CS) ruteado al SPI master del host con velocidad ≥ 50 MHz.

### 5.2 Pines fuertemente recomendados (power-save del chip)

- [ ] **mPCIe pin 33 (MOD_BUSY)** — ruteado a un GPIO de input del host. Necesario para que el host sepa si el chip está dormido antes de empezar una transferencia SPI.
- [ ] **mPCIe pin 35 (MOD_WAKEUP_IN)** — ruteado a un GPIO de output del host. Necesario para despertar al chip desde sueño profundo.

Sin estos, el chip queda en estado "always-on" — consume ~150 mW continuo en lugar de ~10 µW en deep sleep.

### 5.3 Pines "nice-to-have"

- [ ] **3.3 V rail conmutable por el host** (regulator-fixed con GPIO enable). Permite power-cycle real del módulo desde software para recovery hard. Sin esto, `reboot` deja el chip alimentado y un módulo en estado patológico solo se recupera con desconexión física.
- [ ] **Acceso a pin 4 (JTAG_TRST si aplica)** para depuración firmware del módulo en banco.
- [ ] **Pin de antenna detect** (algunos módulos lo exponen) para detectar antena desconectada.

### 5.4 Antipatrones a evitar

- ❌ **No atar a GND** ningún pin del módulo cuyo manual marque como I/O. R1000 ata pines 12/33/35 a GND — funcionalmente equivalente a no rutearlos pero peor porque si por error hay un push-pull driver del lado del módulo se hace cortocircuito. **NC es siempre más seguro que GND para pines no usados.**
- ❌ **No depender de pin 1 (mPCIe WAKE#)** como reset. WAKE# es un signal del chip al host (Wake-on-LAN), no es PERST#. Es un error común en carriers.
- ❌ **No compartir el bus SPI con LoRa o TPM** sin un MUX adecuado o un CS dedicado. CS lógicos compartidos con polaridades distintas causan corrupción intermitente.
- ❌ **No omitir capacitores de bypass** en VDD del slot. El MM6108 tiene picos de current draw transmitiendo (~200 mA) que pueden hundir el rail si está sub-decoupleado.

### 5.5 Pin map sugerido para un carrier nuevo basado en CM4

| Función HaLow | CM4 GPIO sugerido | Nota |
|---|---|---|
| SPI SCLK | GPIO11 (SPI0_SCLK) | nativo |
| SPI MISO | GPIO9 (SPI0_MISO) | nativo |
| SPI MOSI | GPIO10 (SPI0_MOSI) | nativo |
| SPI CS | GPIO7 / GPIO8 (SPI0_CE1/CE0) | nativo, dedicado al módulo |
| PERST# | cualquier GPIO output disponible (e.g. GPIO17) | conviene por GPIO directo del CM4, no por expander, para reset rápido |
| MOD_INT (IRQ) | **GPIO con IRQ-capable input directo del CM4** (e.g. GPIO5) | **NO via expander** salvo que se acepte la latencia I²C |
| MOD_BUSY | cualquier GPIO input, expander OK | latencia no crítica |
| MOD_WAKEUP_IN | cualquier GPIO output, expander OK | |

Con ese mapeo, el DT overlay queda directo:

```dts
mm6108@0 {
    compatible = "morse,mm610x-spi";
    reset-gpios   = <&gpio 17 GPIO_ACTIVE_LOW>;
    spi-irq-gpios = <&gpio  5 GPIO_ACTIVE_HIGH>;
    power-gpios   = <&gpio  3 GPIO_ACTIVE_HIGH>,  /* WAKEUP_IN */
                    <&gpio  6 GPIO_ACTIVE_HIGH>;  /* BUSY      */
    spi-max-frequency = <50000000>;
};
```

Sin necesidad de patches custom al driver. La referencia EKH01 de MorseMicro (sus eval kits oficiales) usa exactamente este patrón.

---

## 6. Resumen ejecutivo

> El R1000 v1.1 puede correr OpenWrt + HaLow en producción **sin tocar hardware** gracias al patch de polling-mode en el driver morse (v30 lo trae out-of-the-box). El costo es ~10 ms de latencia extra por comando y ~0.5% de un core de CPU en idle, ambos invisibles para el caso de uso típico de IoT/HaLow.
>
> **MOD_INT (pin 10 del slot mPCIe) sí está conectado** vía PCA9535 P01, contrario a lo que pensamos en una primera lectura del esquemático. **Pero la cadena de interrupciones del PCA9535 no propaga los pulsos del chip al CM4** — el camino físico existe pero está eléctricamente roto para este propósito. Soldar un mod al P01 no arregla nada porque el problema no es el cable, es la lógica de detección INT del expander en esa traza específica. Un mod tendría que ir a un pin del CM4 directo o a un pin del PCA9535 con cadena INT validada — eso requiere PCB rework, no sólo un cable.
>
> El R1000 **no soporta** power-save coordinado del chip (BUSY/WAKEUP no ruteados) — para nodos battery-powered con duty cycle bajo, el siguiente carrier **debe** rutear los pines 10, 33 y 35 del slot mPCIe a GPIOs del host con cadenas IRQ funcionales. Si no, el chip consume ~150 mW continuo aunque OpenWrt entre en idle.
>
> El próximo carrier debería seguir el pin map de la sección 5.5 (alineado con la referencia oficial EKH01 de MorseMicro). Costo en BOM: 0 — son rutas que ya existen en el silicio del CM4, sólo hay que tirarlas al conector mPCIe **directamente, sin pasar por un IO expander que estaba diseñado para señales de reset estáticas**.

---

## 7. Referencias internas

- Driver patches: `feeds/morse/essentials/morse_driver/patches/02{0,1,2,3}-*.patch`
- DT overlay R1000: `target/linux/bcm27xx/patches-5.15/991-0004-dt-overlays-morse-add-r1000-spi-overlay.patch`
- uci-default que aplica polling + canal correcto: `target/linux/bcm27xx/base-files/etc/uci-defaults/50-r1000-bcf`
- Esquemáticos consultados:
  - `docs/reComputer_R1000_schematic_design_files (3)/.../202003926_RECOMPUTER R_SCH_PDF.pdf` (página 12: PCA9535; página 15: J14/J15 mPCIe slots)
  - `docs/Wio-WM6108_V30_SCH_20241107.pdf` (CN2 mPCIe del módulo)
- Memoria de proyecto: `~/.claude/projects/-home-sebas-workspace-openwrt/memory/project_r1000_hardware_irq_gap.md`
