// Thermyx insole firmware — Seeed XIAO ESP32-C3
//
// Implements ThermyxApp/BLE_PROTOCOL.md (telemetry v3, 22 bytes, 1 Hz; mode
// and target-temperature commands) for the prototype parts list:
//
//   MCU           Seeed XIAO ESP32-C3
//   Peltier       CUI CP3495-46 (or Dilwe TEC104901 in the proof-of-concept),
//                 driven reversibly through channel A of a DRV8833
//   Fan           Easycargo 20 mm fan on channel B of the same DRV8833 (one
//                 direction only: BIN1 on D8, BIN2 tied to GND)
//   Temperature   2 x SparkFun TMP117 on I2C (0x48 foot contact, 0x49 ambient)
//   Motion        GY-521 (MPU-6050) on I2C at 0x68
//   Pressure      3 x FSR402 (heel, arch, forefoot), each in a divider with a
//                 10 kOhm resistor to GND, read on A0-A2
//   Battery       optional 2:1 divider (2 x 100 kOhm); off by default, see
//                 PIN_BATTERY for why it cannot simply go on A3
//
// STATUS: written against the protocol and the parts list; not yet compiled
// or flashed. Check the pin map below against the real wiring before the
// first power-up, and test the Peltier with the insole OFF the foot first.
//
// Build: Arduino IDE 2.x, board package "esp32" by Espressif (3.x), board
// "XIAO_ESP32C3". No extra libraries: sensors are read over raw I2C.
//
// One insole per foot: set THERMYX_FOOT below before flashing each one.

#include <Arduino.h>
#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <esp_task_wdt.h>

// ---------------------------------------------------------------- settings

#define THERMYX_FOOT 1            // 1 = left, 2 = right (protocol byte 11)
#define HAS_BATTERY_SENSE 0       // 1 once a battery divider is fitted (see PIN_BATTERY)

// Pin map (XIAO ESP32-C3 silkscreen names).
static const int PIN_FSR_HEEL = A0;
static const int PIN_FSR_ARCH = A1;
static const int PIN_FSR_FOREFOOT = A2;
#if HAS_BATTERY_SENSE
// The XIAO ESP32-C3's only dependable analog pins are A0-A2 (ADC1), and the
// FSRs use all three. GPIO5 ("A3") is on ADC2, which reads unreliably while
// Bluetooth is on. Choose a pin (or an external ADC such as an ADS1115), set
// it here, and delete the #error.
#error "Choose PIN_BATTERY before enabling HAS_BATTERY_SENSE (see the comment above)."
static const int PIN_BATTERY = -1;
#endif
static const int PIN_PELTIER_IN1 = D6;   // DRV8833 AIN1
static const int PIN_PELTIER_IN2 = D7;   // DRV8833 AIN2
static const int PIN_FAN = D8;           // DRV8833 BIN1; wire BIN2 to GND
static const int PIN_DRIVER_SLEEP = D10; // DRV8833 nSLEEP (high = enabled)
// D9 (GPIO9) is deliberately unused: it is the ESP32-C3 boot strap pin, and
// the DRV8833's input pull-down could hold it low and stop the board booting.

// I2C addresses.
static const uint8_t TMP117_FOOT = 0x48;
static const uint8_t TMP117_AMBIENT = 0x49;
static const uint8_t MPU6050 = 0x68;

// Safety limits. These are enforced here, in firmware, whatever the app asks.
static const float BURN_LIMIT_C = 40.0f;      // never heat at or above this
static const float HEAT_RESUME_C = 38.5f;     // resume heating below this
static const float COLD_LIMIT_C = 15.0f;      // never cool at or below this
static const float TARGET_MIN_C = 26.0f;
static const float TARGET_MAX_C = 38.0f;
static const uint8_t HEAT_DUTY = 150;         // of 255; kept below cooling
static const uint8_t COOL_DUTY = 220;
static const uint8_t FAN_DUTY = 255;

// Protocol.
#define SERVICE_UUID   "7B7E0001-7A3B-4D2D-9C9E-000000000001"
#define TELEMETRY_UUID "7B7E0002-7A3B-4D2D-9C9E-000000000001"
#define COMMAND_UUID   "7B7E0003-7A3B-4D2D-9C9E-000000000001"

enum Mode : uint8_t { MODE_OFF = 0, MODE_HEATING = 1, MODE_COOLING = 2, MODE_VENTILATION = 3 };

static const int16_t NO_TEMPERATURE = INT16_MIN;   // outside -20..80 C: the app reads it as absent
static const uint16_t NO_VALUE = 0xFFFF;           // gait / balance / cadence / standing unknown
static const uint8_t NO_BATTERY = 0xFF;

// ------------------------------------------------------------------ state

// What the app asked for. MODE_VENTILATION is the app's "Auto": regulate
// towards targetC. Heating and cooling are explicit requests.
static volatile uint8_t commandedMode = MODE_VENTILATION;
static volatile float targetC = 31.0f;
// What the hardware is actually doing, reported back in byte 1.
static uint8_t activeMode = MODE_VENTILATION;
// True while the burn cutoff is holding the heater off (flags bit 4).
static bool burnCutoff = false;
// A loop that hangs for this long resets the chip, so a stuck heater
// cannot stay on with nothing watching it.
static const uint32_t WATCHDOG_MS = 4000;

static BLECharacteristic *telemetry = nullptr;
static volatile bool connected = false;

// Gait tracking.
static const int STEP_HISTORY = 12;
static uint32_t stepTimes[STEP_HISTORY];
static int stepCount = 0;
static bool aboveThreshold = false;
static uint32_t loadedStillMs = 0;
static uint32_t windowMs = 0;

// ------------------------------------------------------------------- I2C

static bool readRegister16(uint8_t address, uint8_t reg, int16_t &out) {
  Wire.beginTransmission(address);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(address, (uint8_t)2) != 2) return false;
  out = (int16_t)((Wire.read() << 8) | Wire.read());
  return true;
}

// TMP117: register 0x00, 7.8125 m°C per LSB. Returns false on a missing
// sensor so the caller reports "absent" rather than a number.
static bool readTMP117(uint8_t address, float &celsius) {
  int16_t raw;
  if (!readRegister16(address, 0x00, raw)) return false;
  if (raw == (int16_t)0x8000) return false;  // TMP117 reset value: no conversion yet
  celsius = raw * 0.0078125f;
  return celsius > -40.0f && celsius < 125.0f;
}

static bool mpuReady = false;

static void initMPU() {
  Wire.beginTransmission(MPU6050);
  Wire.write(0x6B);  // PWR_MGMT_1
  Wire.write(0x00);  // wake
  mpuReady = Wire.endTransmission() == 0;
  if (!mpuReady) return;
  Wire.beginTransmission(MPU6050);
  Wire.write(0x1C);  // ACCEL_CONFIG
  Wire.write(0x08);  // ±4 g
  Wire.endTransmission();
}

// Acceleration magnitude in g, or a negative number when unavailable.
static float accelMagnitudeG() {
  if (!mpuReady) return -1.0f;
  Wire.beginTransmission(MPU6050);
  Wire.write(0x3B);
  if (Wire.endTransmission(false) != 0) return -1.0f;
  if (Wire.requestFrom(MPU6050, (uint8_t)6) != 6) return -1.0f;
  int16_t ax = (Wire.read() << 8) | Wire.read();
  int16_t ay = (Wire.read() << 8) | Wire.read();
  int16_t az = (Wire.read() << 8) | Wire.read();
  const float scale = 1.0f / 8192.0f;  // ±4 g
  float x = ax * scale, y = ay * scale, z = az * scale;
  return sqrtf(x * x + y * y + z * z);
}

// -------------------------------------------------------------- actuators

static void driveBridge(int in1, int in2, int8_t direction, uint8_t duty) {
  // DRV8833 slow-decay PWM: hold one input high, PWM the other inverted.
  if (direction == 0 || duty == 0) {
    analogWrite(in1, 0);
    analogWrite(in2, 0);
  } else if (direction > 0) {
    analogWrite(in2, 0);
    analogWrite(in1, duty);
  } else {
    analogWrite(in1, 0);
    analogWrite(in2, duty);
  }
}

static void applyMode(uint8_t mode) {
  activeMode = mode;
  switch (mode) {
    case MODE_HEATING:
      driveBridge(PIN_PELTIER_IN1, PIN_PELTIER_IN2, +1, HEAT_DUTY);
      analogWrite(PIN_FAN, 0);
      break;
    case MODE_COOLING:
      driveBridge(PIN_PELTIER_IN1, PIN_PELTIER_IN2, -1, COOL_DUTY);
      analogWrite(PIN_FAN, FAN_DUTY);  // reject heat
      break;
    case MODE_VENTILATION:
      driveBridge(PIN_PELTIER_IN1, PIN_PELTIER_IN2, 0, 0);
      analogWrite(PIN_FAN, FAN_DUTY);
      break;
    default:
      driveBridge(PIN_PELTIER_IN1, PIN_PELTIER_IN2, 0, 0);
      analogWrite(PIN_FAN, 0);
      break;
  }
}

// Decides what to do from the command and the foot temperature, with the
// safety limits applied last so nothing can override them.
static uint8_t decideMode(bool haveFoot, float footC) {
  uint8_t want = commandedMode;

  if (want == MODE_VENTILATION) {  // Auto
    if (!haveFoot) {
      want = MODE_VENTILATION;
    } else if (footC > targetC + 0.6f) {
      want = MODE_COOLING;
    } else if (footC < targetC - 0.6f) {
      want = MODE_HEATING;
    } else if (activeMode == MODE_COOLING || activeMode == MODE_HEATING) {
      want = fabsf(footC - targetC) < 0.2f ? (uint8_t)MODE_VENTILATION : activeMode;
    }
  }

  // Fail safe: with no foot temperature there is nothing to regulate on.
  if (!haveFoot && (want == MODE_HEATING || want == MODE_COOLING)) return MODE_VENTILATION;
  // Burn protection, with hysteresis.
  burnCutoff = false;
  if (want == MODE_HEATING) {
    if (footC >= BURN_LIMIT_C || (activeMode != MODE_HEATING && footC >= HEAT_RESUME_C)) {
      burnCutoff = true;
      return MODE_VENTILATION;
    }
  }
  // Cold protection.
  if (want == MODE_COOLING && footC <= COLD_LIMIT_C) return MODE_VENTILATION;
  return want;
}

// ------------------------------------------------------------------ BLE

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override { connected = true; }
  void onDisconnect(BLEServer *server) override {
    connected = false;
    // Unsupervised heating is not allowed: drop back to Auto without heat
    // until the app reconnects, then advertise again.
    if (commandedMode == MODE_HEATING) commandedMode = MODE_VENTILATION;
    server->getAdvertising()->start();
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    String value = characteristic->getValue();
    if (value.length() >= 2 && (uint8_t)value[0] == 1) {
      uint8_t mode = (uint8_t)value[1];
      if (mode <= MODE_VENTILATION) commandedMode = mode;
    } else if (value.length() >= 3 && (uint8_t)value[0] == 2) {
      int16_t centi = (int16_t)((uint8_t)value[1] | ((uint8_t)value[2] << 8));
      float c = centi / 100.0f;
      targetC = constrain(c, TARGET_MIN_C, TARGET_MAX_C);
    }
  }
};

static void startBLE() {
  const char *name = THERMYX_FOOT == 1 ? "Thermyx Left" : "Thermyx Right";
  BLEDevice::init(name);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService *service = server->createService(SERVICE_UUID);

  telemetry = service->createCharacteristic(TELEMETRY_UUID, BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ);
  telemetry->addDescriptor(new BLE2902());

  BLECharacteristic *command = service->createCharacteristic(COMMAND_UUID, BLECharacteristic::PROPERTY_WRITE);
  command->setCallbacks(new CommandCallbacks());

  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
}

// ----------------------------------------------------------------- gait

// Samples the accelerometer and FSRs quickly between telemetry packets.
static void sampleMotion(uint32_t now, bool loaded) {
  static uint32_t lastSample = 0;
  if (now - lastSample < 20) return;  // 50 Hz
  uint32_t dt = now - lastSample;
  lastSample = now;

  float g = accelMagnitudeG();
  if (g >= 0) {
    // A heel strike shows up as a spike above ~1.35 g; count rising edges.
    if (!aboveThreshold && g > 1.35f) {
      aboveThreshold = true;
      if (stepCount == 0 || now - stepTimes[(stepCount - 1) % STEP_HISTORY] > 250) {
        stepTimes[stepCount % STEP_HISTORY] = now;
        stepCount++;
      }
    } else if (aboveThreshold && g < 1.15f) {
      aboveThreshold = false;
    }
  }

  // Standing: loaded, but no step in the last 1.5 s.
  bool recentStep = stepCount > 0 && now - stepTimes[(stepCount - 1) % STEP_HISTORY] < 1500;
  windowMs += dt;
  if (loaded && !recentStep) loadedStillMs += dt;
}

// Cadence in steps per minute from the recent step intervals, or -1.
static float cadence(uint32_t now) {
  int n = min(stepCount, STEP_HISTORY);
  if (n < 3) return -1;
  uint32_t newest = stepTimes[(stepCount - 1) % STEP_HISTORY];
  if (now - newest > 3000) return 0;  // stopped walking
  uint32_t oldest = stepTimes[(stepCount - n) % STEP_HISTORY];
  float seconds = (newest - oldest) / 1000.0f;
  if (seconds <= 0) return -1;
  // One insole sees every other step; double it for whole-body cadence.
  return (n - 1) / seconds * 60.0f * 2.0f;
}

// Gait stability 0..1: one minus the coefficient of variation of the step
// intervals. Regular steps score near 1; stumbling, shuffling steps fall.
static float gaitStability(uint32_t now) {
  int n = min(stepCount, STEP_HISTORY);
  if (n < 4) return -1;
  if (now - stepTimes[(stepCount - 1) % STEP_HISTORY] > 3000) return -1;
  float intervals[STEP_HISTORY];
  float mean = 0;
  for (int i = 1; i < n; i++) {
    uint32_t a = stepTimes[(stepCount - n + i - 1) % STEP_HISTORY];
    uint32_t b = stepTimes[(stepCount - n + i) % STEP_HISTORY];
    intervals[i - 1] = (b - a);
    mean += intervals[i - 1];
  }
  mean /= (n - 1);
  if (mean <= 0) return -1;
  float variance = 0;
  for (int i = 0; i < n - 1; i++) variance += (intervals[i] - mean) * (intervals[i] - mean);
  float cv = sqrtf(variance / (n - 1)) / mean;
  return constrain(1.0f - cv, 0.0f, 1.0f);
}

// ------------------------------------------------------------- telemetry

static void putInt16(uint8_t *p, int16_t v) { p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; }
static void putUInt16(uint8_t *p, uint16_t v) { p[0] = v & 0xFF; p[1] = v >> 8; }
static int16_t centi(bool ok, float c) { return ok ? (int16_t)lroundf(c * 100.0f) : NO_TEMPERATURE; }

static uint8_t batteryPercent() {
#if HAS_BATTERY_SENSE
  // 2:1 divider; 3.3 V reference; LiPo 3.3 V empty to 4.2 V full.
  float volts = analogReadMilliVolts(PIN_BATTERY) * 2.0f / 1000.0f;
  float pct = (volts - 3.3f) / (4.2f - 3.3f) * 100.0f;
  return (uint8_t)constrain(lroundf(pct), 0, 100);
#else
  return NO_BATTERY;
#endif
}

static void sendTelemetry(bool haveFoot, float footC, bool haveAmbient, float ambientC,
                          float heel, float arch, float forefoot, uint32_t now) {
  uint8_t packet[22];
  packet[0] = 3;                    // protocol version
  packet[1] = activeMode;           // what the hardware is doing
  packet[2] = batteryPercent();
  // The app treats this as the foot average. With a single contact sensor
  // it is that sensor.
  putInt16(&packet[3], centi(haveFoot, footC));
  putInt16(&packet[5], centi(haveAmbient, ambientC));

  float stability = gaitStability(now);
  putUInt16(&packet[7], stability < 0 ? NO_VALUE : (uint16_t)lroundf(stability * 10000));

  float total = heel + arch + forefoot;
  putUInt16(&packet[9], total < 0.05f ? NO_VALUE : (uint16_t)lroundf(forefoot / total * 10000));

  // Flags: bits 0-1 foot; bits 2-3 the setting being followed (1 Cool,
  // 2 Auto, 3 Heat) so the app can confirm a command landed; bit 4 burn cutoff.
  uint8_t echo = commandedMode == MODE_COOLING ? 1 : commandedMode == MODE_HEATING ? 3 : 2;
  packet[11] = THERMYX_FOOT | (echo << 2) | (burnCutoff ? 0x10 : 0);

  // Zones: this build has one contact sensor, not three, so the zone fields
  // carry the "absent" marker and the app hides the zone map.
  putInt16(&packet[12], NO_TEMPERATURE);
  putInt16(&packet[14], NO_TEMPERATURE);
  putInt16(&packet[16], NO_TEMPERATURE);

  float spm = cadence(now);
  putUInt16(&packet[18], spm < 0 ? NO_VALUE : (uint16_t)lroundf(spm * 10));
  float standing = windowMs > 0 ? (float)loadedStillMs / windowMs : -1;
  putUInt16(&packet[20], standing < 0 ? NO_VALUE : (uint16_t)lroundf(standing * 10000));
  loadedStillMs = 0;
  windowMs = 0;

  telemetry->setValue(packet, sizeof(packet));
  telemetry->notify();
}

// FSR reading normalised 0..1 (divider output over full scale).
static float readFSR(int pin) {
  return analogReadMilliVolts(pin) / 3300.0f;
}

// ---------------------------------------------------------------- Arduino

void setup() {
  // Outputs low first, then wake the driver, so nothing is driven mid-boot.
  pinMode(PIN_PELTIER_IN1, OUTPUT);
  pinMode(PIN_PELTIER_IN2, OUTPUT);
  pinMode(PIN_FAN, OUTPUT);
  applyMode(MODE_OFF);
  pinMode(PIN_DRIVER_SLEEP, OUTPUT);
  digitalWrite(PIN_DRIVER_SLEEP, HIGH);

  // Task watchdog (esp32 core 3.x). The core may already have one running;
  // reconfigure it if so.
  esp_task_wdt_config_t wdt = { .timeout_ms = WATCHDOG_MS, .idle_core_mask = 0, .trigger_panic = true };
  if (esp_task_wdt_reconfigure(&wdt) != ESP_OK) esp_task_wdt_init(&wdt);
  esp_task_wdt_add(NULL);

  analogReadResolution(12);
  Wire.begin();
  Wire.setClock(400000);
  initMPU();
  startBLE();
}

void loop() {
  static uint32_t lastPacket = 0;
  uint32_t now = millis();
  esp_task_wdt_reset();

  float heel = readFSR(PIN_FSR_HEEL);
  float arch = readFSR(PIN_FSR_ARCH);
  float forefoot = readFSR(PIN_FSR_FOREFOOT);
  sampleMotion(now, heel + arch + forefoot > 0.15f);

  if (now - lastPacket < 1000) return;
  lastPacket = now;

  float footC = 0, ambientC = 0;
  bool haveFoot = readTMP117(TMP117_FOOT, footC);
  bool haveAmbient = readTMP117(TMP117_AMBIENT, ambientC);

  applyMode(decideMode(haveFoot, footC));

  if (connected && telemetry) {
    sendTelemetry(haveFoot, footC, haveAmbient, ambientC, heel, arch, forefoot, now);
  }
}
