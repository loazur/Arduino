# sensor_b – Capteur Arduino (ESP32) + IHM Godot

Projet de supervision d'un capteur connecté via la bibliothèque **MPS** :

- **Côté capteur** (Arduino / ESP32) : compteur, mesure température/humidité (DHT11), LED RGB pilotable.
- **Côté IHM** (Godot, `tile.gd`) : affichage des états, boutons de commande, détection de perte de connexion.

Ce document décrit le **contrat** entre les deux : la liste des *subjects* échangés, leur sens, et le format exact de leurs payloads.

---

## Configuration

| Élément | Valeur | Fichier |
|---|---|---|
| Nom du capteur (`DEVICE_NAME`) | `sensor_b` | `config.h` (Arduino) / `tile.gd` (constante `DEVICE_NAME`) |
| Adresse MAC de la passerelle | `90:DA:72:52:EE:1C` | `config.h` (`kGatewayMacAddress`) |
| Canal Wi-Fi | `5` | `config.h` (`kWifiChannel`) |
| Broche du DHT11 | `0` | `kDhtPin` |
| Broche de la LED RGB | `2` | `rgbLedWrite(2, ...)` |

> Le `DEVICE_NAME` doit être **identique** côté Arduino et côté Godot : il entre dans le nom de chaque subject.
> Si `kGatewayMacAddress` n'est pas renseignée (`00:00:00:00:00:00`), le capteur n'enregistre aucun callback ni client MPS et affiche un message d'erreur sur le port série.

---

## Conventions

- **Sens** : `Capteur → IHM` (le capteur publie, l'IHM s'abonne) ou `IHM → Capteur` (l'IHM publie, le capteur s'abonne via `MPS.on`).
- **Préfixes des subjects** :
  - `hb_` : heartbeat
  - `status_` : état publié par le capteur
  - `set_` : consigne envoyée au capteur (avec valeur)
  - `cmd_` : commande envoyée au capteur (sans valeur)
- **Format des payloads** : structures C `packed`, **little-endian** (ESP32 côté capteur, `decode_*` de Godot côté IHM), sans padding ni octet de terminaison.
- **Tolérance** : un message dont la taille de payload ne correspond pas au contrat est **ignoré** (côté capteur comme côté IHM).
- Côté IHM, seuls les messages dont l'émetteur (`source_id`) est le `node_id` du capteur `sensor_b` sont traités.

---

## Récapitulatif des subjects

| Subject | Sens | Payload | Taille |
|---|---|---|---|
| `hb_sensor_b` | Capteur → IHM | (géré par `MPS.publishHeartbeat`, non exploité par l'IHM) | – |
| `status_sensor_b_counter` | Capteur → IHM | `uint32 value` | 4 octets |
| `cmd_sensor_b_reset_counter` | IHM → Capteur | aucun | 0 octet |
| `status_sensor_b_climate` | Capteur → IHM | `int16` + `uint16` | 4 octets |
| `status_sensor_b_led_color` | Capteur → IHM | `uint8[3]` (R, G, B) | 3 octets |
| `set_sensor_b_led_color` | IHM → Capteur | `uint8[3]` (R, G, B) | 3 octets |
| `cmd_sensor_b_reset_led_color` | IHM → Capteur | aucun | 0 octet |

---

## Détail des subjects

### `hb_sensor_b` – Heartbeat

- **Sens** : Capteur → IHM
- **Rôle** : prouve à l'IHM que le code « métier » du capteur tourne (publié depuis `loop()`, sans `delay()`).
- **Période** : 1 s (`kHbPeriod = 1000` ms).
- **Payload** : géré par la bibliothèque (`MPS.publishHeartbeat`). L'IHM n'en lit pas le contenu, seul l'émetteur compte.
- **Côté IHM** :
  - chaque réception remet à zéro le chronomètre et marque le capteur comme *connecté* ;
  - l'icône de heartbeat reste allumée 0,5 s (`HB_BLINK_S`) ;
  - sans heartbeat pendant **3,5 s** (`HB_TIMEOUT_S`, soit 3,5 périodes), le capteur est considéré comme *déconnecté / bloqué* et les contrôles sont grisés et désactivés.

### `status_sensor_b_counter` – État du compteur

- **Sens** : Capteur → IHM
- **Rôle** : valeur courante d'un compteur incrémenté automatiquement.
- **Payload** (4 octets) :

| Offset | Champ | Type | Unité | Taille |
|---|---|---|---|---|
| 0 | `value` | `uint32` | nombre d'incréments (sans unité) | 4 octets |

- **Publication** :
  - toutes les 2 s, après incrément (`value++`) ;
  - à l'ouverture de la session MPS (état courant) ;
  - après réception de `cmd_sensor_b_reset_counter` (valeur remise à 0).
- **Côté IHM** : affiché dans `CounterLabel` (`Compteur : N`). Payload ≠ 4 octets → ignoré.

### `cmd_sensor_b_reset_counter` – Remise à zéro du compteur

- **Sens** : IHM → Capteur
- **Rôle** : remet le compteur à 0.
- **Payload** : **aucun** (0 octet). Un message avec un payload non vide est ignoré par le capteur.
- **Envoi** : par le bouton `ResetCounterButton` (publication avec le paramètre `true`).
- **Réponse** : le capteur republie immédiatement `status_sensor_b_counter` avec la valeur réelle (`0`), ce qui permet à l'IHM d'afficher le résultat effectif.

### `status_sensor_b_climate` – Température et humidité (DHT11)

- **Sens** : Capteur → IHM
- **Rôle** : dernière mesure valide du capteur DHT11.
- **Payload** (4 octets) :

| Offset | Champ | Type | Unité | Taille |
|---|---|---|---|---|
| 0 | `temperatureCentiDegrees` | `int16` (signé) | centièmes de °C (valeur ÷ 100 = °C) | 2 octets |
| 2 | `humidityCentiPercent` | `uint16` (non signé) | centièmes de % d'humidité relative (valeur ÷ 100 = %) | 2 octets |

  Exemple : `2350` → 23,50 °C ; `4500` → 45,00 %.
- **Publication** :
  - toutes les 2 s (`kClimatePeriodMs = 2000`), si la lecture est valide ;
  - si la lecture échoue (`NaN`), rien n'est publié (message de log série) ;
  - à l'ouverture de la session MPS, uniquement si au moins une mesure valide a déjà été obtenue.
- **Côté IHM** : affiché dans `TemperatureLabel` (`%.1f °C`) et `HumidityLabel` (`%.0f %%`). Payload ≠ 4 octets → ignoré.
  Si aucune mesure n'est reçue pendant **7 s** (`CLIMATE_TIMEOUT_S`) ou si le capteur est déconnecté, la zone température/humidité est grisée (donnée périmée).
- **Précision** : le DHT11 a une résolution d'environ 1 °C et 1 % ; les centièmes sont une représentation en virgule fixe, pas une précision de mesure.

### `status_sensor_b_led_color` – Couleur courante de la LED

- **Sens** : Capteur → IHM
- **Rôle** : couleur réellement appliquée à la LED RGB.
- **Payload** (3 octets) :

| Offset | Champ | Type | Unité | Taille |
|---|---|---|---|---|
| 0 | `ledColor[0]` – rouge (R) | `uint8` | intensité 0–255 | 1 octet |
| 1 | `ledColor[1]` – vert (G) | `uint8` | intensité 0–255 | 1 octet |
| 2 | `ledColor[2]` – bleu (B) | `uint8` | intensité 0–255 | 1 octet |

- **Publication** :
  - après chaque `set_sensor_b_led_color` valide ;
  - après chaque `cmd_sensor_b_reset_led_color` ;
  - à l'ouverture de la session MPS (la LED est aussi réappliquée à ce moment).
- **Côté IHM** : affiché dans `LEDColorLabel` (`LEDColor: (R, G, B)`). Payload ≠ 3 octets → ignoré.

### `set_sensor_b_led_color` – Consigne de couleur de la LED

- **Sens** : IHM → Capteur
- **Rôle** : demande au capteur d'appliquer une couleur à la LED RGB.
- **Payload** (3 octets) : même format que `status_sensor_b_led_color` (R, G, B, `uint8` chacun, 0–255).
- **Envoi** : par le bouton `RandomColorButton`, qui tire une couleur au hasard dans une palette de 15 couleurs prédéfinies (rouge, vert, bleu, jaune, cyan, magenta, blanc, orange, rose, violet, vert printemps, azur, lime, rose vif, or).
- **Réception côté capteur** : si la taille du payload n'est pas de 3 octets, le message est ignoré. Sinon la couleur est mémorisée, appliquée à la LED, puis publiée via `status_sensor_b_led_color`.

### `cmd_sensor_b_reset_led_color` – Extinction de la LED

- **Sens** : IHM → Capteur
- **Rôle** : remet la couleur de la LED à `(0, 0, 0)` (LED éteinte).
- **Payload** : **aucun** (0 octet). Un payload non vide est ignoré.
- **Envoi** : par le bouton `ResetColorButton`.
- **Réponse** : le capteur publie `status_sensor_b_led_color` avec `(0, 0, 0)`.

---

## Comportement de l'IHM selon l'état de connexion

| État | Déclencheur | Effet sur l'IHM |
|---|---|---|
| **Connecté** | réception d'un `hb_sensor_b` du bon nœud | icônes actives, zones compteur/LED à pleine opacité, boutons activés |
| **Déconnecté** | pas de heartbeat depuis 3,5 s, nœud signalé hors ligne par la passerelle, ou passerelle injoignable | zones compteur/LED grisées (opacité 0,4), boutons désactivés, `node_id: ∅` |

Le `node_id` du capteur est obtenu en priorité par l'annonce de la passerelle (`on_node_online`, filtrée sur `device_name == "sensor_b"`), ou à défaut par le premier heartbeat reçu. Il est réinitialisé si la passerelle devient injoignable (les identifiants peuvent être redistribués après son redémarrage).

---

## Résumé des périodes et délais

| Élément | Valeur |
|---|---|
| Période du heartbeat | 1 s |
| Délai avant déconnexion (sans heartbeat) | 3,5 s |
| Durée d'allumage de l'icône de heartbeat | 0,5 s |
| Période du compteur | 2 s |
| Période de lecture du DHT11 | 2 s |
| Délai avant péremption de la mesure climatique | 7 s |
