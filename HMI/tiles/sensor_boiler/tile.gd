extends Tile

# ---- CONSTANTES ----
const DEVICE_NAME = "sensor_b"
## Valeur de _node_id tant que le capteur n'a pas été vu.
const NO_NODE_ID := -1

# Heartbeat
const SUB_HB = "hb_" + DEVICE_NAME
## Délai sans heartbeat au-delà duquel le capteur est considéré comme bloqué (3,5 périodes de 1 s).
const HB_TIMEOUT_S := 3.5
## Durée d'allumage de l'icône de heartbeat à chaque réception.
const HB_BLINK_S := 0.5

# Compteur
const SUB_STATUS_COUNTER = "status_" + DEVICE_NAME + "_counter"
const SUB_CMD_RESET_COUNTER = "cmd_" + DEVICE_NAME + "_reset_counter"
## Contrat de status_<appareil>_counter : uint32.
const COUNTER_PAYLOAD_SIZE := 4
const COUNTER_OFFSET := 0

# Couleur de la LED
const SUB_STATUS_LED_COLOR = "status_" + DEVICE_NAME + "_led_color"
const SUB_SET_LED_COLOR = "set_" + DEVICE_NAME + "_led_color"
const SUB_CMD_RESET_LED_COLOR = "cmd_" + DEVICE_NAME + "_reset_led_color"
## Contrat de status_ et set_<appareil>_led_color : 3 × uint8 (rouge, vert, bleu).
const LED_COLOR_PAYLOAD_SIZE := 3
const RED_OFFSET := 0
const GREEN_OFFSET := 1
const BLUE_OFFSET := 2
## Couleurs tirées au sort par le bouton « couleur aléatoire ».
const LED_COLORS: Array[Color] = [
	Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.CYAN,
	Color.MAGENTA, Color.WHITE, Color.ORANGE, Color.PINK, Color.PURPLE,
	Color.SPRING_GREEN, Color.DEEP_SKY_BLUE, Color.CHARTREUSE, Color.DEEP_PINK, Color.GOLD,
]

# Température et humidité
const SUB_STATUS_CLIMATE = "status_" + DEVICE_NAME + "_climate"
## Contrat de status_<appareil>_climate : int16 température (c°C) + uint16 humidité (c%).
const CLIMATE_PAYLOAD_SIZE := 4
const TEMPERATURE_OFFSET := 0
const HUMIDITY_OFFSET := 2
const CENTI_PER_UNIT := 100.0
## Délai sans mesure au-delà duquel elle est périmée (3,5 périodes de 2 s).
const CLIMATE_TIMEOUT_S := 7.0

# Affichage
## Teinte des valeurs périmées et des valeurs à jour.
const STALE_MODULATE := Color(1, 1, 1, 0.4)
const FRESH_MODULATE := Color.WHITE

# ---- VARIABLES ----
var _node_id: int = NO_NODE_ID
var _seconds_since_hb := INF
var _seconds_since_climate := INF
# Setter personnalisé : chaque changement d'état de connexion met l'interface à jour
var _connected: bool = false:
	set(value):
		if value == _connected: return
		_connected = value
		if _connected:
			_on_sensor_connected()
		else:
			_on_sensor_disconnected()


## Branche les boutons et démarre en état « aucun capteur vu ».
func _ready() -> void:
	super()
	_apply_connection_state(false)
	%ResetCounterButton.pressed.connect(func(): publish(SUB_CMD_RESET_COUNTER, PackedByteArray(), true))
	%RandomColorButton.pressed.connect(_on_random_color_button_pressed)
	%ResetColorButton.pressed.connect(func(): publish(SUB_CMD_RESET_LED_COLOR, PackedByteArray(), true))


## Liste des subjects reçus par la tuile.
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


## Passe le capteur hors ligne quand la passerelle l'annonce parti.
func on_node_offline(node_id: int, _reason_code: int) -> void:
	if node_id == _node_id: _connected = false


## Passerelle perdue : capteur hors ligne et identifiant oublié.
func on_gateway_reachability_changed(is_gateway_reachable: bool) -> void:
	if is_gateway_reachable: return
	_connected = false
	_node_id = NO_NODE_ID  # la passerelle peut redistribuer les identifiants en redémarrant


## Aiguille chaque message de notre capteur vers son décodeur.
func on_message(subject_name: String, source_id: int, payload: PackedByteArray) -> void:
	if subject_name == SUB_HB: _on_hb(source_id)
	if source_id != _node_id: return # seuls les messages de notre capteur nous concernent
	if subject_name == SUB_STATUS_COUNTER: _on_counter(payload)
	if subject_name == SUB_STATUS_CLIMATE: _on_climate(payload)
	if subject_name == SUB_STATUS_LED_COLOR: _on_led_color(payload)


## Fait clignoter le heartbeat et détecte les pertes de capteur et de mesure.
func _process(delta: float) -> void:
	_seconds_since_hb += delta
	%HeartbeatIcon.state = _seconds_since_hb < HB_BLINK_S
	if _connected and _seconds_since_hb >= HB_TIMEOUT_S:
		_connected = false  # plus de heartbeat : code du capteur bloqué ou capteur hors de portée
	_seconds_since_climate += delta
	var climate_fresh := _connected and _seconds_since_climate < CLIMATE_TIMEOUT_S
	%TempHumManagement.modulate = FRESH_MODULATE if climate_fresh else STALE_MODULATE


## Tire une couleur au hasard et la demande au capteur ; l'affichage attendra son status_.
func _on_random_color_button_pressed() -> void:
	var color: Color = LED_COLORS.pick_random()
	var payload := PackedByteArray()
	payload.resize(LED_COLOR_PAYLOAD_SIZE)
	payload.encode_u8(RED_OFFSET, color.r8)
	payload.encode_u8(GREEN_OFFSET, color.g8)
	payload.encode_u8(BLUE_OFFSET, color.b8)
	publish(SUB_SET_LED_COLOR, payload, true)


## Met l'interface en état « capteur connecté ».
func _on_sensor_connected() -> void:
	%IDLabel.text = "node_id: %d" % _node_id
	%ConnectedIcon.state = true
	_apply_connection_state(true)


## Met l'interface en état « capteur déconnecté ».
func _on_sensor_disconnected() -> void:
	%IDLabel.text = "node_id: ∅"
	%ConnectedIcon.state = false
	_apply_connection_state(false)


## Traite un heartbeat : (re)connecte le capteur et relance la temporisation.
## @param source_id  Identifiant de l'appareil émetteur.
func _on_hb(source_id: int) -> void:
	# Secours si la tuile n'a pas vu on_node_online (IHM lancée après le capteur, par exemple)
	if _node_id == NO_NODE_ID: _node_id = source_id
	if source_id != _node_id: return
	_seconds_since_hb = 0.0
	_connected = true


## Affiche le compteur ; ignore un payload de taille inattendue.
func _on_counter(payload: PackedByteArray) -> void:
	if payload.size() != COUNTER_PAYLOAD_SIZE: return
	%CounterLabel.text = "Compteur : %d" % payload.decode_u32(COUNTER_OFFSET)


## Affiche la mesure du DHT11 ; ignore un payload de taille inattendue.
func _on_climate(payload: PackedByteArray) -> void:
	if payload.size() != CLIMATE_PAYLOAD_SIZE: return
	var temperature_degrees := payload.decode_s16(TEMPERATURE_OFFSET) / CENTI_PER_UNIT
	var humidity_percent := payload.decode_u16(HUMIDITY_OFFSET) / CENTI_PER_UNIT
	%TemperatureLabel.text = "Température : %.1f °C" % temperature_degrees
	%HumidityLabel.text = "Humidité : %.0f %%" % humidity_percent
	_seconds_since_climate = 0.0


## Affiche la couleur réellement appliquée par le capteur ; ignore un payload de taille inattendue.
func _on_led_color(payload: PackedByteArray) -> void:
	if payload.size() != LED_COLOR_PAYLOAD_SIZE: return
	var red := payload.decode_u8(RED_OFFSET)
	var green := payload.decode_u8(GREEN_OFFSET)
	var blue := payload.decode_u8(BLUE_OFFSET)
	%LEDColorLabel.text = "LEDColor: (%d, %d, %d)" % [red, green, blue]


## Grise les valeurs et bloque les commandes quand le capteur est hors ligne ; rétablit tout à la reconnexion.
## @param sensor_online  true si le capteur envoie ses heartbeats.
func _apply_connection_state(sensor_online: bool) -> void:
	var tint := FRESH_MODULATE if sensor_online else STALE_MODULATE
	%LEDColorManagement.modulate = tint
	%CounterManagement.modulate = tint
	%ResetCounterButton.disabled = not sensor_online
	%RandomColorButton.disabled = not sensor_online
	%ResetColorButton.disabled = not sensor_online
