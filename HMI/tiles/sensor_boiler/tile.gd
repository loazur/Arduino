extends Tile

# ---- CONSTANTES ----
const DEVICE_NAME = "sensor_b"
const SUB_HB = "hb_" + DEVICE_NAME
## Délai sans heartbeat au-delà duquel le capteur est considéré comme bloqué (3,5 périodes de 1 s).
const HB_TIMEOUT_S := 3.5
## Durée d'allumage de l'icône de heartbeat à chaque réception.
const HB_BLINK_S := 0.5

# Counter
const SUB_STATUS_COUNTER = "status_" + DEVICE_NAME + "_counter"
const SUB_CMD_RESET_COUNTER = "cmd_" + DEVICE_NAME + "_reset_counter"
const SUB_STATUS_CLIMATE = "status_" + DEVICE_NAME + "_climate"

const CLIMATE_PAYLOAD_SIZE := 4
const TEMPERATURE_OFFSET := 0
const HUMIDITY_OFFSET := 2
const CENTI_PER_UNIT := 100.0

# LED Color
const SUB_STATUS_LED_COLOR = "status_" + DEVICE_NAME + "_led_color"
const SUB_SET_LED_COLOR = "set_" + DEVICE_NAME + "_led_color"
const SUB_CMD_RESET_LED_COLOR = "cmd_" + DEVICE_NAME + "_reset_led_color"

# ---- VARIABLES ----
var _node_id: int = -1
var _seconds_since_hb := INF
# Variable "_connected" avec setter personnalisé pour appeler la MAJ de l'UI au changement d'état
var _connected: bool = false:
	set(value):
		if value == _connected: return
		_connected = value
		if _connected:
			_on_sensor_connected()
		else:
			_on_sensor_disconnected()
			
var LED_COLORS: Array[PackedByteArray] = [
	PackedByteArray([255,   0,   0]), # Red
	PackedByteArray([  0, 255,   0]), # Green
	PackedByteArray([  0,   0, 255]), # Blue
	PackedByteArray([255, 255,   0]), # Yellow
	PackedByteArray([  0, 255, 255]), # Cyan
	PackedByteArray([255,   0, 255]), # Magenta
	PackedByteArray([255, 255, 255]), # White
	PackedByteArray([255, 128,   0]), # Orange
	PackedByteArray([255, 192, 203]), # Pink
	PackedByteArray([128,   0, 255]), # Purple
	PackedByteArray([  0, 255, 128]), # Spring green
	PackedByteArray([  0, 128, 255]), # Azure
	PackedByteArray([128, 255,   0]), # Lime
	PackedByteArray([255,   0, 128]), # Rose
	PackedByteArray([255, 215,   0]), # Gold
]
			
func _ready() -> void:
	super()
	
	%ResetCounterButton.pressed.connect(func(): publish(SUB_CMD_RESET_COUNTER, PackedByteArray(), true))
	%RandomColorButton.pressed.connect(_on_random_color_button_pressed)
	%ResetColorButton.pressed.connect(func(): publish(SUB_CMD_RESET_LED_COLOR, PackedByteArray(), true))


func get_subscriptions() -> PackedStringArray:
	var subscriptions: PackedStringArray = []
	subscriptions.append(SUB_HB)
	subscriptions.append(SUB_STATUS_COUNTER)
	subscriptions.append(SUB_STATUS_CLIMATE)
	subscriptions.append(SUB_STATUS_LED_COLOR)
	return subscriptions


## Source principale du node_id : la passerelle annonce le capteur par son nom dès son enregistrement,
## avant ses premières publications (dont l'état republié dans onSessionOpened côté Arduino).
func on_node_online(node_id: int, _mac_address: String, device_name: String) -> void:
	if device_name != DEVICE_NAME: return
	_node_id = node_id  # nouvel identifiant possible après un redémarrage du capteur
	%IDLabel.text = "node_id: %d" % _node_id


func on_node_offline(node_id: int, _reason_code: int) -> void:
	if node_id == _node_id: _connected = false


func on_gateway_reachability_changed(is_gateway_reachable: bool) -> void:
	if is_gateway_reachable: return
	_connected = false
	_node_id = -1  # la passerelle peut redistribuer les identifiants en redémarrant


func on_message(subject_name: String, source_id: int, _payload: PackedByteArray) -> void:
	if subject_name == SUB_HB: _on_hb(source_id)
	if source_id != _node_id: return # ne traitez que les messages dédiés à votre capteur
	if subject_name == SUB_STATUS_COUNTER:
		if _payload.size() != 4: return # le contrat : 4 octets, sinon on ignore
		%CounterLabel.text = "Compteur : %d" % _payload.decode_u32(0)
	if subject_name == SUB_STATUS_CLIMATE:
		_on_climate(_payload)
		
	if subject_name == SUB_STATUS_LED_COLOR:
		if _payload.size() != 3: return # le contrat : 3 octets, sinon on ignore
		
		var r := _payload.decode_u8(0)
		var g := _payload.decode_u8(1)
		var b := _payload.decode_u8(2)
		%LEDColorLabel.text = "LEDColor: (%d, %d, %d)" % [r, g, b]

func _on_random_color_button_pressed() -> void:
	var color: PackedByteArray = LED_COLORS.pick_random()

	publish(SUB_SET_LED_COLOR, color, true)
	
func _process(delta: float) -> void:
	_seconds_since_hb += delta
	%HeartbeatIcon.state = _seconds_since_hb < HB_BLINK_S
	if _connected and _seconds_since_hb >= HB_TIMEOUT_S:
		_connected = false  # plus de heartbeat : code du capteur bloqué ou capteur hors de portée


func _on_sensor_connected():
	%IDLabel.text = "node_id: %d" % _node_id
	%ConnectedIcon.state = true


func _on_sensor_disconnected():
	%IDLabel.text = "node_id: ∅"
	%ConnectedIcon.state = false

## @brief Traite un heartbeat : (re)connecte le capteur et relance la temporisation.
## @param source_id  Identifiant de l'appareil émetteur.
func _on_hb(source_id: int):
	# Secours si la tuile n'a pas vu on_node_online (IHM lancée après le capteur, par exemple)
	if _node_id == -1: _node_id = source_id
	if source_id != _node_id: return
	_seconds_since_hb = 0.0
	_connected = true
	
func _on_climate(payload: PackedByteArray) -> void:
	if payload.size() != CLIMATE_PAYLOAD_SIZE: return
	var temperature_degrees := payload.decode_s16(TEMPERATURE_OFFSET) / CENTI_PER_UNIT
	var humidity_percent := payload.decode_u16(HUMIDITY_OFFSET) / CENTI_PER_UNIT
	%TemperatureLabel.text = "Température : %.1f °C" % temperature_degrees
	%HumidityLabel.text = "Humidité : %.0f %%" % humidity_percent
