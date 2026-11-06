#include <MPS.h>
#include <DHT.h>
#include "config.h"

// ---- Constantes ----
constexpr uint32_t kSerialBaudRate = 115200;  // débit du moniteur série
constexpr uint32_t kHeartbeatPeriodMs = 1000; // période des heartbeats
constexpr uint32_t kCounterPeriodMs = 2000;   // période d'incrément du compteur
constexpr uint32_t kClimatePeriodMs = 2000;   // le DHT11 ne mesure pas plus d'une fois par seconde
constexpr uint8_t kDhtPin = 0;                // broche DATA du DHT11 (port Grove, fil jaune)
constexpr uint8_t kRgbLedPin = 2;             // LED RGB SK6812 intégrée au M5Stamp C3U
constexpr float kCentiPerUnit = 100.0f;       // conversion d'une unité en centièmes

// ---- Structures de payloads ----
/// Valeur du compteur de démonstration (sans unité).
struct __attribute__((packed)) CounterPayload {
  uint32_t value;
};

static_assert(sizeof(CounterPayload) == 4, "CounterPayload = 4 octets");

/// Température et humidité mesurées par le DHT11.
struct __attribute__((packed)) ClimatePayload {
  int16_t temperatureCentiDegrees; // centièmes de degré Celsius
  uint16_t humidityCentiPercent;   // centièmes de % d'humidité relative
};

static_assert(sizeof(ClimatePayload) == 4, "ClimatePayload = 4 octets");

/// Couleur de la LED RGB : une composante par octet, de 0 (éteinte) à 255 (pleine intensité).
struct __attribute__((packed)) LedColorPayload {
  uint8_t red;
  uint8_t green;
  uint8_t blue;
};

static_assert(sizeof(LedColorPayload) == 3, "LedColorPayload = 3 octets");

/// Couleur au démarrage et après un reset : LED éteinte.
constexpr LedColorPayload kDefaultLedColor = {0, 0, 0};

// ---- Variables globales ----
static CounterPayload counter = {0};
static ClimatePayload climate = {0, 0};
static LedColorPayload ledColor = kDefaultLedColor;
static bool hasClimateReading = false; // on ne republie jamais une mesure qui n'a pas été lue
static DHT dht(kDhtPin, DHT11);

// ---- Subjects ----
constexpr mps::Subject kSubHb = mps::makeSubject("hb_" DEVICE_NAME);
constexpr mps::Subject kSubStatusCounter = mps::makeSubject("status_" DEVICE_NAME "_counter");
constexpr mps::Subject kSubCmdResetCounter = mps::makeSubject("cmd_" DEVICE_NAME "_reset_counter");
constexpr mps::Subject kSubStatusClimate = mps::makeSubject("status_" DEVICE_NAME "_climate");
constexpr mps::Subject kSubStatusLedColor = mps::makeSubject("status_" DEVICE_NAME "_led_color");
constexpr mps::Subject kSubSetLedColor = mps::makeSubject("set_" DEVICE_NAME "_led_color");
constexpr mps::Subject kSubCmdResetLedColor = mps::makeSubject("cmd_" DEVICE_NAME "_reset_led_color");

// ---- Fonctions utilitaires ----
/// @brief Recopie la couleur mémorisée sur la LED physique.
static void applyLedColor() {
  rgbLedWrite(kRgbLedPin, ledColor.red, ledColor.green, ledColor.blue);
}

// ---- Callbacks MPS ----
/// @brief Ouverture de session : republie tout l'état courant, car la passerelle ne garde aucun message.
static void onSessionOpened() {
  Serial.println("Session opened!");
  MPS.publishValue(kSubStatusCounter, counter);
  MPS.publishValue(kSubStatusLedColor, ledColor);
  if (hasClimateReading) MPS.publishValue(kSubStatusClimate, climate);
}

/// @brief Signale sur le port série un envoi définitivement perdu (on ne republie pas d'ici).
static void onSendFailed(uint16_t sequenceNumber, uint32_t subjectId, mps::SendFailureReason, mps::AcknowledgementStatus) {
  Serial.printf("/!\\ envoi %u (subject 0x%08lX) perdu\n", sequenceNumber, (unsigned long)subjectId);
}

// ---- Handlers de subjects ----
/// @brief Remet le compteur à 0 puis le republie : le status_ prouve à l'IHM que l'ordre est appliqué.
static void onCmdResetCounter(const mps::FrameView& message, void*) {
  if (message.payloadLength != 0) return; // payload vide attendu
  counter.value = 0;
  MPS.publishValue(kSubStatusCounter, counter);
}

/// @brief Applique la couleur demandée par l'IHM puis confirme la couleur réelle par un status_.
static void onSetLedColor(const mps::FrameView& message, void*) {
  LedColorPayload requestedColor;
  if (!mps::readPayloadAs(message, &requestedColor)) return; // taille inattendue : ignoré
  ledColor = requestedColor;
  applyLedColor();
  MPS.publishValue(kSubStatusLedColor, ledColor);
}

/// @brief Remet la LED à sa couleur par défaut puis confirme par un status_.
static void onCmdResetLedColor(const mps::FrameView& message, void*) {
  if (message.payloadLength != 0) return; // payload vide attendu
  ledColor = kDefaultLedColor;
  applyLedColor();
  MPS.publishValue(kSubStatusLedColor, ledColor);
}

// ---- Tâches périodiques (non bloquantes, appelées par loop) ----
/// @brief Publie un heartbeat toutes les kHeartbeatPeriodMs : son arrêt révèle un code bloqué.
static void publishHeartbeat() {
  static uint32_t lastHeartbeatTimeMs = 0;
  if (millis() - lastHeartbeatTimeMs < kHeartbeatPeriodMs) return;
  lastHeartbeatTimeMs = millis();
  MPS.publishHeartbeat(kSubHb);
}

/// @brief Incrémente et publie le compteur de démonstration toutes les kCounterPeriodMs.
static void publishCounter() {
  static uint32_t lastCounterTimeMs = 0;
  if (millis() - lastCounterTimeMs < kCounterPeriodMs) return;
  lastCounterTimeMs = millis();
  counter.value++;
  MPS.publishValue(kSubStatusCounter, counter);
}

/// @brief Lit le DHT11 toutes les kClimatePeriodMs et publie la mesure si elle est valide.
static void publishClimate() {
  static uint32_t lastClimateTimeMs = 0;
  if (millis() - lastClimateTimeMs < kClimatePeriodMs) return;
  lastClimateTimeMs = millis();

  const float temperatureDegrees = dht.readTemperature();
  const float humidityPercent = dht.readHumidity();
  if (isnan(temperatureDegrees) || isnan(humidityPercent)) {
    Serial.println("DHT11: lecture impossible");
    return; // mieux vaut ne rien publier qu'une valeur fausse
  }

  climate.temperatureCentiDegrees = static_cast<int16_t>(lroundf(temperatureDegrees * kCentiPerUnit));
  climate.humidityCentiPercent = static_cast<uint16_t>(lroundf(humidityPercent * kCentiPerUnit));
  hasClimateReading = true;
  MPS.publishValue(kSubStatusClimate, climate);
}

// ---- Fonctions Arduino ----
/// @brief Initialise le matériel, enregistre les callbacks et démarre le client MPS.
void setup() {
  Serial.begin(kSerialBaudRate);
  MPS.setLogOutput(&Serial);

  dht.begin();
  applyLedColor(); // la LED prend son état initial même si la passerelle est injoignable

  MPS.setRegisteredCallback(onSessionOpened);
  MPS.setSendFailedCallback(onSendFailed);

  // Une adresse restée à zéro signifie que config.h n'a pas été rempli
  static const uint8_t kUnsetMacAddress[sizeof(kGatewayMacAddress)] = {};
  if (memcmp(kGatewayMacAddress, kUnsetMacAddress, sizeof(kGatewayMacAddress)) == 0) {
    Serial.println("MPS: renseignez kGatewayMacAddress dans config.h (adresse affichee par l'IHM)");
    return;
  }

  MPS.on(kSubCmdResetCounter, onCmdResetCounter);
  MPS.on(kSubSetLedColor, onSetLedColor);
  MPS.on(kSubCmdResetLedColor, onCmdResetLedColor);

  if (!MPS.begin(kGatewayMacAddress, DEVICE_NAME, kWifiChannel)) Serial.println("MPS: demarrage impossible");
}

/// @brief Boucle principale : rien de bloquant, MPS.loop() doit tourner au moins toutes les 10 ms.
void loop() {
  MPS.loop();
  publishHeartbeat();
  publishCounter();
  publishClimate();
}
