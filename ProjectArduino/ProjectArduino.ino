#include <MPS.h>
#include "config.h"
#include <map>
#include <string>
#include <random>

// ---- Structures de payloads ----
// Counter
struct __attribute__((packed)) CounterPayload {
  uint32_t value;
};

static_assert(sizeof(CounterPayload) == 4, "CounterPayload = 4 octets");

// LED
struct __attribute__((packed)) LEDPayload {
  std::array<uint32_t, 3> ledColor;
};

static_assert(sizeof(LEDPayload) == 4, "LEDPayload = 4 octets");

// ---- Variables globales ----
static CounterPayload counter = {0};
static LEDPayload ledColor = {0, 0, 0};

// ---- Subjects ----
constexpr mps::Subject kSubHb = mps::makeSubject("hb_" DEVICE_NAME); // déjà présent
constexpr mps::Subject kSubStatusCounter = mps::makeSubject("status_" DEVICE_NAME "_counter");
constexpr mps::Subject kSubCmdResetCounter = mps::makeSubject("cmd_" DEVICE_NAME "_reset_counter");

// Led Management
constexpr mps::Subject kSubStatusLEDColor = mps::makeSubject("status_" DEVICE_NAME "_led_color");
constexpr mps::Subject kSubCmdRandomLEDColor = mps::makeSubject("cmd_" DEVICE_NAME "_random_led_color");
constexpr mps::Subject kSubCmdResetLEDColor = mps::makeSubject("cmd_" DEVICE_NAME "_reset_led_color");


const std::vector<std::array<uint8_t, 3>> LED_COLORS = {
  {255, 0, 0}, // Red
  {0, 255, 0}, // Green
  {0, 0, 255}  // Blue
};

// ... ajoutez vos sujets ici sur le même schéma que le heartbeat, mais en précisant la donnée envoyée,
// par exemple : `constexpr mps::Subject kSubStatusSomeData = mps::makeSubject("status_" DEVICE_NAME "_some_data");`
// ou : `constexpr mps::Subject kSubCmdSomeOrder = mps::makeSubject("cmd_" DEVICE_NAME "_some_order");`

// ---- Callbacks ----
// Appelé lors de l'ouverture de la session (callback)
static void onSessionOpened() {
  Serial.println("Session opened!");
  
  MPS.publishValue(kSubStatusCounter, counter);
  MPS.publishValue(kSubStatusLEDColor, ledColor);
}

// Appelé en cas d'échec d'envoi (callback)
static void onSendFailed(uint16_t sequenceNumber, uint32_t subjectId, mps::SendFailureReason, mps::AcknowledgementStatus) {
  Serial.printf("/!\\ envoi %u (subject 0x%08lX) perdu\n", sequenceNumber, (unsigned long)subjectId);
}

// ---- Callbacks ----
static void onCmdResetCounter(const mps::FrameView& message, void*) {
  if (message.payloadLength != 0) return; // ce format n'a pas de payload
  counter.value = 0;
  MPS.publishValue(kSubStatusCounter, counter); // l'IHM voit le résultat réel
}

// LED Management

static void onCmdRandomLEDColor(const mps::FrameView& message, void*){
  if (message.payloadLength != 0) return;

  // Random Generation
  static std::mt19937 gen(std::random_device{}());
  std::uniform_int_distribution<size_t> distrib(0, LED_COLORS.size() - 1);

  const auto& c = LED_COLORS[distrib(gen)];
  ledColor.ledColor = {c[0], c[1], c[2]};   // conversion uint8_t -> uint32_t
  MPS.publishValue(kSubStatusLEDColor, ledColor);

  rgbLedWrite(2, ledColor.ledColor[0], ledColor.ledColor[1], ledColor.ledColor[2]);
}

static void onCmdResetLEDColor(const mps::FrameView& message, void*){
  if (message.payloadLength != 0) return;

  ledColor = {0, 0, 0};
  MPS.publishValue(kSubStatusLEDColor, ledColor);

  rgbLedWrite(2, ledColor.ledColor[0], ledColor.ledColor[1], ledColor.ledColor[2]);
}

// ---- Fonctions appelées par setup/loop ----
// envoi de heartbeats réguliers sans bloquer (comparaison au temps écoulé sans delay())
void publishHeartbeat(){
  static uint32_t lastHeartbeatTimeMs = 0;
  static const uint16_t kHbPeriod = 1000;
  if(millis() - lastHeartbeatTimeMs >= kHbPeriod) {
    lastHeartbeatTimeMs = millis();
    
    // L'envoi de heartbeats depuis loop() assure au récepteur (IHM) que le code "métier" n'est pas planté
    MPS.publishHeartbeat(kSubHb);
  }
}

// ---- Fonctions Arduino ----
// Exécutée une fois au démarrage
void setup() {
  Serial.begin(115200); // Démarrage de la communication série à 115200 bauds (sortie des Serial.print.. par exemple)
  MPS.setLogOutput(&Serial); // Définition de la sortie des messages de log de la lib MPS

  // enregistrement des callbacks
  MPS.setRegisteredCallback(onSessionOpened);
  MPS.setSendFailedCallback(onSendFailed);
  // ... ajoutez vos callbacks à l'aide de MPS.on(const mps::Subject& subject, mps::MessageHandler handler, void* userContext = nullptr)
  // par exemple :
  // MPS.on(kSubCmdSomeOrder, onCmdSomeOrder);

  // constante d'adresse vide pour vérifier que l'adresse a été définie dans config.h
  static const uint8_t kUnsetMacAddress[6] = {0, 0, 0, 0, 0, 0};
  if(memcmp(kGatewayMacAddress, kUnsetMacAddress, 6) == 0) {
    Serial.println("MPS: renseignez kGatewayMacAddress dans config.h (adresse affichee par l'IHM)");
    return;
  }

  // Counter
  MPS.on(kSubCmdResetCounter, onCmdResetCounter);

  // LED Color
  MPS.on(kSubCmdRandomLEDColor, onCmdRandomLEDColor);
  MPS.on(kSubCmdResetLEDColor, onCmdResetLEDColor);

  // démarrage du client MPS
  if(!MPS.begin(kGatewayMacAddress, DEVICE_NAME, kWifiChannel)) Serial.println("MPS: demarrage impossible");
}

// Exécutée en boucle (= while(true))
void loop() {
  // appel de la boucle MPS (/!\ du code bloquant dans votre boucle loop() pourrait occasionner des problèmes de connexion)
  MPS.loop();

  // Appel non bloquant de l'envoi d'HB (polling)
  publishHeartbeat();
  
  static uint32_t lastCounterTimeMs = 0;
  if (millis() - lastCounterTimeMs >= 2000) {
    lastCounterTimeMs = millis();
    counter.value++;
    MPS.publishValue(kSubStatusCounter, counter);
  }
}
