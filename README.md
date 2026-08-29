# TGVSpeed

Application native macOS affichant dans la barre de menus la vitesse du TGV,
le trajet et l'état de la connexion Wi-Fi de bord.

Réécriture en Swift/AppKit de [`tgvspeed`](https://github.com/rene-d/tgvspeed) (Python/rumps).

![TGVSpeed dans la barre de menus](docs/screenshot.png)

## Fonctionnement

Les données proviennent du routeur de bord, joignable uniquement depuis le réseau
`_SNCF_WIFI_INOUI` :

| Endpoint | Usage |
|---|---|
| `/router/api/train/gps` | position et vitesse — interrogé toutes les 2 s |
| `/router/api/train/details` | trajet et arrêts — toutes les 30 s |
| `/router/api/connection/status` | forfait de données — à l'ouverture du menu |
| `/router/api/connection/statistics` | qualité du lien et nombre d'appareils — idem |

Le mode nominal n'est toutefois pas le REST mais le **flux Socket.IO** du portail,
qui pousse la position à 1 Hz et quatre événements sans équivalent REST
(`connected_devices`, `data_consumption`, `bar_attendance`, `train_number`).
Le REST ci-dessus sert de **repli automatique** dès que le socket reste muet plus de
8 secondes — traversée de tunnel, perte de couverture — avec reconnexion en backoff.
Le transport utilisé est indiqué dans le menu *Statut*.

Le frontal nginx du portail ne relaie pas l'upgrade websocket, malgré ce qu'annonce
le handshake ; le portail lui-même s'épingle en `transports:["polling"]`.

Hors du train, l'application se met en veille : le sondage passe de 2 s à 20 s,
le titre se réduit à l'icône et les entrées de menu qui dépendent du réseau sont désactivées.

## Menu

- **Voyage** — ouvre le portail SNCF
- **TGV INOUI 6155 ▸** — les arrêts, heure réelle en tête ; les arrêts desservis sont grisés,
  les retards portent un badge et une infobulle avec le motif. **Cocher une gare** déclenche
  une notification avant l'arrivée — le délai se règle en pied de sous-menu,
  *Prévenir avant l'arrivée* (5 à 30 min, dix par défaut) ; ⌥ sur un arrêt ouvre sa fiche
  sur wifi.sncf
- **Carte (Google)** — la position courante dans Google Maps
- **Wi-Fi ▸** — données restantes, remise à zéro du forfait, qualité du lien, appareils
  connectés, file du bar ; le rendu brut des documents JSON est relégué dans un sous-menu
  *Détails techniques*
- **Statistiques ▸** — vitesse max et moyenne, distance parcourue, altitude, cap, arrivée estimée
- **Affichage ▸** — contenu du titre, unité (km/h ou mph), icône monochrome, affichage du réseau
- **Statut** — le document GPS brut, copiable
- **Aide** — le dépôt

### Notification d'arrivée

Une seule gare à la fois. La coche apparaît en badge sur le sous-menu du trajet, pour
la retrouver sans l'ouvrir, et disparaît d'elle-même une fois la gare desservie ou le
train changé.

Le seuil est évalué en continu plutôt que programmé à l'avance : l'heure d'arrivée bouge
au fil des retards publiés, et une notification planifiée serait fausse dès la minute
suivante. C'est l'**horaire annoncé**, retard inclus, qui sert de référence — l'ETA
calculée à partir de la vitesse ignore le freinage en approche et annoncerait sept minutes
là où la fiche horaire en promet dix.

Le délai de prévenance se choisit sous *Prévenir avant l'arrivée*, au pied du sous-menu
du trajet : 5, 10, 15, 20, 25 ou 30 minutes. Le badge de l'entrée rappelle la valeur
courante, dix minutes par défaut. Le changer ne rejoue pas une notification déjà partie.

macOS demande l'autorisation d'afficher des notifications au premier cochage.

### Réseau Wi-Fi

L'option *Afficher le réseau Wi-Fi* lit le SSID courant. macOS exige pour cela
l'autorisation **Localisation** : elle n'est demandée qu'à l'activation de l'option,
et l'application fonctionne entièrement sans.

## Compilation

```shell
make            # liste les cibles disponibles
make app        # produit TGVSpeed.app
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
- `--no-socket` : renvoie 404 sur `/socket.io/`, pour vérifier le repli REST

Le simulateur sert aussi le flux Socket.IO, aux mêmes cadences que la rame.
Pour l'observer :

```shell
./TGVSpeed.app/Contents/MacOS/TGVSpeed --socket-dump 25
```

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
