# Consignes pour Claude Code

Application de barre de menus macOS affichant la vitesse du TGV, écrite en Swift 6 + AppKit.
Réécriture native de `rene-d/tgvspeed` (Python/rumps).

## Contraintes du projet

- **Aucune dépendance externe.** Swift, AppKit, `URLSession`, `Network`. Le protocole
  Socket.IO est implémenté à la main (`EngineIOClient`). Ne pas introduire de paquet
  SwiftPM sans raison impérieuse.
- **Cible macOS 14**, imposée par `NSMenuItemBadge`.
- **Interface et commentaires en français**, comme le reste du dépôt.
- **Décodage tolérant** : le portail n'a pas de schéma stable et change sans préavis.
  Tout champ est optionnel, les types sont acceptés au sens large (`decodeLoose`
  dans `API/Models.swift`). Un champ inconnu ne doit jamais faire échouer un document.
- Vérifier avec `make check` avant de committer ; le dépôt pousse avec l'adresse
  `10288093+rene-d@users.noreply.github.com` (protection de confidentialité GitHub).

## Commandes

```shell
make                  # construit TGVSpeed.app
make sim              # simulateur sur http://localhost:8000
make demo             # lance l'app branchée sur le simulateur
make check            # imprime le menu construit, sans interface — le test de référence
make install          # copie dans /Applications
```

Deux modes non interactifs de l'application, utiles pour diagnostiquer sans capture d'écran
(la capture est souvent refusée faute d'autorisation « Enregistrement de l'écran ») :

```shell
./TGVSpeed.app/Contents/MacOS/TGVSpeed --dump-menu        # menu complet en texte
./TGVSpeed.app/Contents/MacOS/TGVSpeed --socket-dump 25   # écoute le flux Socket.IO 25 s
```

`TGVSPEED_BASE_URL` redirige l'application vers n'importe quelle base d'API :

```shell
TGVSPEED_BASE_URL=http://localhost:8000 ./TGVSpeed.app/Contents/MacOS/TGVSpeed --dump-menu
```

## Si l'API wifi.sncf change

Elle n'est pas documentée et a déjà changé une fois : le champ `carrier`, utilisé par
la version Python, a disparu. **Ces requêtes ne fonctionnent qu'à bord**, connecté à
`_SNCF_WIFI_INOUI`.

1. **Recapturer**, depuis le train :

   ```shell
   for e in train/gps train/details connection/status connection/statistics; do
     curl -s "https://wifi.sncf/router/api/$e" | python3 -m json.tool > "Fixtures/$(basename $e).json"
   done
   ./TGVSpeed.app/Contents/MacOS/TGVSpeed --socket-dump 60
   ```

   Anonymiser les adresses IP du client avant de committer une fixture.

2. **Comparer** aux fixtures existantes (`Fixtures/`) et à `docs/socketio.md`,
   qui recensent l'état connu de l'API.

3. **Adapter les modèles** dans `Sources/TGVSpeed/API/Models.swift`. Garder le décodage
   tolérant : ajouter un champ optionnel plutôt que rendre un champ obligatoire.

4. **Répercuter dans le simulateur** — `Sources/tgvsim/Simulator.swift` produit les mêmes
   documents. Un simulateur qui diverge de la réalité est pire que pas de simulateur.

5. **Vérifier le menu Wi-Fi** : `WiFiMenu.summary` lit six champs par leur nom
   (`remaining_data`, `consumed_data`, `next_reset`, `quality`, `devices`,
   `isBarQueueEmpty`). Si l'un d'eux est renommé, la ligne disparaît silencieusement —
   c'est là qu'il faut répercuter. Le sous-menu *Détails techniques*, lui, s'adapte
   tout seul puisqu'il rend le JSON tel quel.

6. `make check` doit continuer à afficher un menu cohérent.

### Pièges connus, vérifiés à bord

Ne pas les « corriger » sans nouvelle capture : ce sont des faits, pas des bugs.

- **Pas de champ `carrier`.** Le libellé est composé en dur : `TGV INOUI <number>`.
- **`progress` décrit le tronçon qui *part* de l'arrêt**, pas celui qui y arrive.
  La distance restante jusqu'au prochain arrêt se lit donc sur l'arrêt *précédent*
  (`TrainDetails.remainingDistanceToNextStop`), et le terminus n'a aucun bloc `progress`.
  `isDone` repose sur `progressPercentage != 0`.
- **`consumed_data` et `remaining_data` sont en kilo-octets** (leur somme vaut 1 024 000,
  soit le forfait de 1 Go) ; `granted_bandwidth` est en kbit/s. Voir `Formatters.kilobytes`
  et `Formatters.kilobitrate`.
- **`quality` est une note sur 5**, pas un pourcentage.
- **`connection/data_consumption` et `connection/connected_devices` n'existent pas en REST**
  (404) : ce sont uniquement des événements Socket.IO.
- **Le transport websocket est refusé par la rame** (HTTP 400, `{"code":3}`), alors que le
  handshake annonce `upgrades:["websocket"]`. Le long-polling est le seul transport viable.
  Ne pas retenter l'upgrade sans preuve qu'une rame l'accepte.
- **`trainProgress` renvoie `null`** sur les rames observées.

### Architecture des données

`TrainFeed` est la seule source de vérité pour le contrôleur de menu :

- **Socket.IO en mode nominal** — `gps` à 1 Hz, `trainDetails` toutes les 30 s, plus
  `connected_devices`, `data_consumption`, `bar_attendance` et `train_number`.
- **Repli REST automatique** dès que le socket reste muet plus de 8 s ; reconnexion du
  socket en backoff de 2 s à 30 s. Le repli sonde `/train/gps` toutes les 2 s à bord,
  toutes les 20 s hors du train.
- Le transport courant est visible dans le menu **Statut**.

Pour tester le repli sans quitter le bureau : `tgvsim --no-socket` renvoie 404 sur
`/socket.io/`, ce qui force l'application en REST.

## Changer le trajet simulé

Tout est dans `Sources/tgvsim/Journey.swift` : la liste `stops`, un `SimStop` par arrêt.

```swift
SimStop(code: "FRBOJ", label: "Bordeaux Saint-Jean",
        latitude: 44.8259, longitude: -0.5563,
        offsetMinutes: 50,          // minutes depuis le départ
        delayMinutes: 0,            // > 0 pose un badge de retard
        delayReason: nil)           // infobulle du badge
```

Ajuster aussi `carrier`, `number`, `trainId` en tête du fichier.

Le reste se déduit tout seul : `Simulator` calcule les distances orthodromiques entre
arrêts, applique un profil de vitesse trapézoïdal (15 % d'accélération, palier, 15 % de
freinage) et en tire position, vitesse, cap et progression. Il n'y a **pas** de vitesse
à saisir : elle découle de la distance et du temps alloué au tronçon. Un tronçon trop
court pour son horaire donnera donc une vitesse invraisemblable — vérifier avec :

```shell
make sim
curl -s http://localhost:8000/train/gps | python3 -m json.tool
```

Le stationnement en gare vaut `min(2 min, 25 % de l'intervalle)`, calculé par
`Simulator.dwell(before:)`.

Options utiles pendant la mise au point :

```shell
swift run tgvsim --at 90      # démarrer 90 minutes après le départ
swift run tgvsim --speed 30   # rejouer tout le trajet en quelques minutes
```

`SocketServer` rejoue les mêmes documents que le REST : rien à modifier de ce côté
en changeant de trajet.

## Structure

```
Sources/TGVSpeed/
  API/          EngineIOClient (Socket.IO), WifiSNCFClient (REST), Models, Formatters, JSONValue
  Menu/         construction des NSMenu, titre de la barre, icônes
  TrainFeed     socket + repli REST, source unique du contrôleur
  StatusItemController  titre, menus, actions
  MenuDump / SocketProbe  modes non interactifs
Sources/tgvsim/ simulateur : Journey (le trajet), Simulator (cinématique), SocketServer, main (HTTP)
Fixtures/       captures réelles servant de référence aux modèles
docs/socketio.md  relevé du protocole Socket.IO à bord
```
