# TGVSpeed

Application native macOS affichant dans la barre de menus la vitesse du TGV,
le trajet et l'état de la connexion Wi-Fi de bord.

Réécriture en Swift/AppKit de [`tgvspeed`](https://github.com/rene-d/tgvspeed) (Python/rumps).

## Fonctionnement

Les données proviennent du routeur de bord, joignable uniquement depuis le réseau
`_SNCF_WIFI_INOUI` :

| Endpoint | Usage |
|---|---|
| `/router/api/train/gps` | position et vitesse — interrogé toutes les 2 s |
| `/router/api/train/details` | trajet et arrêts — toutes les 30 s |
| `/router/api/connection/status` | forfait de données — à l'ouverture du menu |
| `/router/api/connection/statistics` | qualité du lien et nombre d'appareils — idem |

Le portail expose aussi un flux Socket.IO qui pousse le GPS à 1 Hz et quelques
événements sans équivalent REST. Le transport websocket y est refusé par la rame :
voir [`docs/socketio.md`](docs/socketio.md).

Hors du train, l'application se met en veille : le sondage passe de 2 s à 20 s,
le titre se réduit à l'icône et les entrées de menu qui dépendent du réseau sont désactivées.

## Menu

- **Voyage** — ouvre le portail SNCF
- **INOUI 8476 ▸** — les arrêts, heure réelle en tête ; les arrêts desservis sont grisés,
  les retards portent un badge et une infobulle avec le motif ; un clic ouvre la fiche de l'arrêt
- **Carte (Google)** — la position courante dans Google Maps
- **Wi-Fi ▸** — état de la connexion, débit, consommation, appareils connectés
- **Statistiques ▸** — vitesse max et moyenne, distance parcourue, altitude, cap, arrivée estimée
- **Affichage ▸** — contenu du titre, unité (km/h ou mph), icône monochrome, affichage du réseau
- **Statut** — le document GPS brut, copiable
- **Aide** — le dépôt

### Réseau Wi-Fi

L'option *Afficher le réseau Wi-Fi* lit le SSID courant. macOS exige pour cela
l'autorisation **Localisation** : elle n'est demandée qu'à l'activation de l'option,
et l'application fonctionne entièrement sans.

## Compilation

```shell
make            # produit TGVSpeed.app
make install    # copie dans /Applications
make universal  # binaire arm64 + x86_64
```

Aucune dépendance externe : Swift 6, AppKit, `URLSession`. macOS 14 minimum
(les badges de retard utilisent `NSMenuItemBadge`).

La signature est *ad hoc* par défaut ; pour une vraie identité :

```shell
make app CODESIGN_ID="Developer ID Application: …"
```

## Développement hors du train

`tgvsim` rejoue un trajet complet — position, vitesse, progression des arrêts, retards —
sur les mêmes routes que le routeur de bord.

```shell
make sim                                     # http://localhost:8000
make demo                                    # lance l'app branchée dessus
make check                                   # imprime le menu construit, sans interface
```

Options du simulateur :

```shell
swift run tgvsim --port 8000 --at 60 --speed 1
```

- `--at <min>` : minute du trajet où démarrer (60 = entre Bordeaux et Angoulême, ~200 km/h)
- `--speed <n>` : accélération du temps (`30` rejoue les 3 h 40 en 7 minutes)

La variable `TGVSPEED_BASE_URL` redirige l'application vers n'importe quelle base d'API.

## Particularités de l'API

Relevées à bord, elles ne sont documentées nulle part :

- il n'y a **pas de champ `carrier`** dans `/train/details` ; le libellé est composé
  en dur sous la forme `TGV INOUI <numéro>` ;
- le bloc `progress` d'un arrêt décrit le tronçon qui **part** de cet arrêt, pas celui
  qui y arrive : la distance restante jusqu'au prochain arrêt se lit donc sur l'arrêt
  précédent, et le terminus n'a pas de bloc `progress` du tout ;
- `consumed_data` et `remaining_data` sont en **kilo-octets** (leur somme vaut 1 024 000,
  soit le forfait de 1 Go), `granted_bandwidth` en **kbit/s** ;
- `quality` est une note **sur 5**, pas un pourcentage.

Les endpoints `connection/data_consumption` et `connection/connected_devices` n'existent
pas en REST (404) : ce sont uniquement des événements Socket.IO.

Voir `Fixtures/README.md` pour les captures.
