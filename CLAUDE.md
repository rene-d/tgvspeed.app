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
make                  # liste les cibles disponibles
make app              # construit TGVSpeed.app
make sim              # simulateur sur http://localhost:8000
make demo             # lance l'app branchée sur le simulateur
make check            # imprime le menu construit, sans interface — le test de référence
make install          # copie dans /Applications
make universal dmg    # binaire arm64 + x86_64, puis l'image disque distribuée
```

Deux modes non interactifs de l'application, utiles pour diagnostiquer sans capture d'écran
(la capture est souvent refusée faute d'autorisation « Enregistrement de l'écran ») :

```shell
./TGVSpeed.app/Contents/MacOS/TGVSpeed --dump-menu        # menu complet en texte
./TGVSpeed.app/Contents/MacOS/TGVSpeed --socket-dump 25   # écoute le flux Socket.IO 25 s
./TGVSpeed.app/Contents/MacOS/TGVSpeed --export t.json    # document de diagnostic complet
```

`--export` assemble exactement ce que produit *Exporter en JSON…* dans le menu Wi-Fi :
mémoire de l'application, six endpoints REST, événements Socket.IO, empreintes du
portail. `--full` y ajoute ses contenus. C'est la trace à joindre quand l'API change —
elle contient l'adresse IP attribuée par la rame, à anonymiser avant de la publier.

`TGVSPEED_BASE_URL` redirige l'application vers n'importe quelle base d'API :

```shell
TGVSPEED_BASE_URL=http://localhost:8000 ./TGVSpeed.app/Contents/MacOS/TGVSpeed --dump-menu
```

## Si l'API wifi.sncf change

Elle n'est pas documentée et a déjà changé une fois : le champ `carrier`, utilisé par
la version Python, a disparu. **Ces requêtes ne fonctionnent qu'à bord**, connecté à
`_SNCF_WIFI_INOUI`.

0. **Relever d'abord les empreintes** (§ *Savoir si l'API a changé* du `README.md`) :
   l'API n'a pas de numéro de version, mais le hachage des bundles du portail change
   à chaque redéploiement. Inchangé, il n'y a rien à réanalyser.

1. **Recapturer**, depuis le train :

   ```shell
   for e in train/gps train/details connection/status connection/statistics; do
     curl -s "https://wifi.sncf/router/api/$e" | python3 -m json.tool > "Fixtures/$(basename $e).json"
   done
   ./TGVSpeed.app/Contents/MacOS/TGVSpeed --socket-dump 60
   ```

   Anonymiser les adresses IP du client avant de committer une fixture.

2. **Comparer** aux fixtures existantes (`Fixtures/`), qui recensent l'état connu de l'API.

3. **Adapter les modèles** dans `Sources/TGVSpeed/API/Models.swift`. Garder le décodage
   tolérant : ajouter un champ optionnel plutôt que rendre un champ obligatoire.

4. **Répercuter dans le simulateur** — `Sources/tgvsim/Simulator.swift` produit les mêmes
   documents. Un simulateur qui diverge de la réalité est pire que pas de simulateur.

5. **Vérifier le menu Wi-Fi** : `WiFiMenu.summary` lit six champs par leur nom
   (`remaining_data`, `consumed_data`, `next_reset`, `quality`, `devices`,
   `isBarQueueEmpty`). Si l'un d'eux est renommé, la ligne disparaît silencieusement —
   c'est là qu'il faut répercuter. Le sous-menu *Détails techniques*, lui, s'adapte
   tout seul puisqu'il rend le JSON tel quel — moins ce qu'écartent `excludedEvents`
   et `excludedKeys` en tête du même fichier. Un document qui apparaît vide dans le
   menu est probablement filtré, pas absent : *Exporter en JSON…* le montre entier.

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
  (404) : ce sont uniquement des événements Socket.IO. `bar_attendance`, en revanche,
  a bien un équivalent REST — `bar/attendance`. Répondent 404 également, malgré leur
  présence dans le bundle du portail : `connection/registry`, `bar/meta.json`,
  `connections/`.
- **Le frontal nginx du portail ne relaie pas l'upgrade websocket.** engine.io répond
  `400 {"code":3}` parce que la requête lui parvient comme un GET ordinaire, alors que
  son propre handshake annonce `upgrades:["websocket"]` — il se croit joignable et ignore
  que nginx ne lui passera jamais l'upgrade. Le portail lui-même s'épingle d'ailleurs en
  `transports:["polling"]` (voir son bundle, `/assets/js/*.app.js`). Le réseau de bord n'y
  est pour rien : les websockets sortants aboutissent (101). Le long-polling est donc le
  seul transport viable ; ne pas retenter l'upgrade sans preuve qu'une rame l'accepte.
  Vérifié le 29 août 2026 à bord du TGV INOUI 6124.
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

## Notification d'arrivée

`ArrivalAlarm` prévient avant l'arrivée à la gare cochée dans le sous-menu du trajet.

- **Une seule gare**, mémorisée sous la forme `train|code` dans les préférences. Le numéro
  de train accompagne le code pour qu'une sélection oubliée ne se réveille pas au voyage
  suivant ; elle s'efface aussi dès que la gare est desservie.
- **Le seuil est évalué à chaque position**, pas programmé à l'avance : l'heure d'arrivée
  bouge au fil des retards publiés. `firedCode` empêche la répétition.
- **Un horaire qui recule réarme la notification.** Un retard annoncé après coup rend
  fausse celle qui vient de partir : dès que l'arrêt ressort de la fenêtre — `remaining >
  leadTime + rearmMargin` — `firedCode` est effacé et l'alarme repart au nouveau seuil.
  La marge vaut `min(120 s, délai / 2)` : fixe, elle interdirait tout réarmement sur un
  délai court, et absente, l'ETA calculée ferait osciller la notification autour de la
  limite.
- **macOS peut refuser les notifications sans que rien ne le dise** :
  `UNUserNotificationCenter.add` accepte la demande même quand l'autorisation vaut
  `denied`, et la jette. L'application lit donc `getNotificationSettings` au lancement
  et à chaque ouverture du menu ; `ArrivalAlarm.isMuted` déclenche un avertissement dans
  le sous-menu du trajet et un badge ⚠︎ sur le menu principal. L'autorisation est
  demandée au lancement, pas seulement au premier cochage : macOS ne pose la question
  qu'une fois, et après un refus toute demande ultérieure est sans effet.
- **Un délégué `UNUserNotificationCenterDelegate` est indispensable** : sans
  `willPresent`, aucune bannière n'apparaît quand l'application est active — ce qu'un
  agent de barre de menus devient dès qu'on ouvre son menu.
- **Le délai est réglable** dans le sous-menu du trajet (*Prévenir avant l'arrivée*,
  5 à 30 min, 10 par défaut), persisté sous la clé `alarmLead` en minutes.
  `ArrivalAlarm.leadTime` reste la seule lecture du délai, en secondes.
- **La référence est `stop.realDate`**, l'horaire annoncé retard inclus — pas l'ETA
  calculée, qui ignore le freinage en approche et sous-estime la fin de tronçon.
  Ne pas intervertir sans raison : l'écart mesuré était de trois minutes.

Pour l'essayer sans attendre dix minutes :

```shell
swift run tgvsim --port 8008 --at 80          # Angoulême est à t+90, donc à 10 min
defaults write fr.rene.TGVSpeed alarmStop "TGV INOUI 8476|FRANG"
TGVSPEED_BASE_URL=http://localhost:8008 ./TGVSpeed.app/Contents/MacOS/TGVSpeed
```

`TGVSPEED_ALARM_LEAD` court-circuite le réglage du menu et abaisse le seuil en secondes
pour tester un franchissement (`TGVSPEED_ALARM_LEAD=30` avec `--at 89`).

Pour vérifier le **réarmement**, `tgvsim --late <min> --late-after <s>` annonce un retard
en cours de route sur les arrêts pas encore desservis. Le scénario qui l'exerce en deux
minutes, terminus à la minute 232 du trajet simulé :

```shell
swift run tgvsim --port 8337 --at 216 --speed 30 --late 60 --late-after 10
defaults write fr.rene.TGVSpeed alarmStop "TGV INOUI 8476|FRPMO"
TGVSPEED_BASE_URL=http://localhost:8337 TGVSPEED_ALARM_LEAD=30 \
  ./TGVSpeed.app/Contents/MacOS/TGVSpeed
```

Deux lignes `alarme :` doivent sortir — la première vers t+2 s, la seconde après que le
retard a repoussé l'arrivée. Le retard annoncé doit rester large : la fenêtre de
réarmement se referme à une seconde par seconde, et l'application ne relit le trajet que
toutes les 30 s. Un retard trop court se referme avant qu'elle l'ait vu. L'alarme trace sur la sortie standard en
plus de poster la notification — avec un `fflush` explicite, sans quoi rien n'apparaît
quand la sortie est redirigée et que le processus est tué.

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
```
