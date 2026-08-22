# Socket.IO du portail wifi.sncf — relevé à bord

Relevé le 22 août 2026 à bord du TGV INOUI 6155 (Paris-Gare-de-Lyon → Hyères).

## Résultat principal

**Le transport websocket est refusé par la rame.** Le serveur l'annonce pourtant
dans son handshake :

```console
$ curl 'https://wifi.sncf/socket.io/?EIO=4&transport=polling'
0{"sid":"hNP-5oiB4kUwJZY-AAHO","upgrades":["websocket"],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}
```

mais toute tentative d'upgrade échoue, avec ou sans `sid` valide, avec ou sans en-tête `Origin` :

```console
$ curl -i -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
       -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: …' \
       'https://wifi.sncf/socket.io/?EIO=4&transport=websocket&sid=…'
HTTP/1.1 400 Bad Request
{"code":3,"message":"Bad request"}
```

`code: 3` est l'erreur *Bad request* d'Engine.IO. `URLSessionWebSocketTask` échoue
de la même façon (*bad response from the server*). Le proxy frontal de bord ne
relaie pas l'upgrade.

**En pratique, le flux temps réel du portail est du long-polling HTTP** — ce que
confirme l'URL relevée dans le navigateur, qui reste en `transport=polling`.

## Protocole

Engine.IO v4 / Socket.IO v4 (et non Socket.IO 3 comme le supposait le prototype Python),
namespace applicatif `/router/api/pepita`.

Séquence complète, entièrement reproductible en `curl` :

```console
# 1. handshake → sid
curl 'https://wifi.sncf/socket.io/?EIO=4&transport=polling&t=<ts>'
0{"sid":"<SID>","upgrades":["websocket"],"pingInterval":25000,"pingTimeout":20000,…}

# 2. connexion au namespace
curl -X POST --data-binary '40/router/api/pepita,' \
     'https://wifi.sncf/socket.io/?EIO=4&transport=polling&sid=<SID>&t=<ts>'
ok

# 3. lecture (long-polling, une requête bloque jusqu'au prochain événement)
curl 'https://wifi.sncf/socket.io/?EIO=4&transport=polling&sid=<SID>&t=<ts>'
40/router/api/pepita,{"sid":"…"}
42/router/api/pepita,["gps",{"success":true,…,"speed":67.942,…}]
```

Les paquets multiples d'une même réponse sont séparés par `\x1e`.
Un paquet `2` (PING) doit recevoir un `3` (PONG) posté sur la même session,
sous peine de fermeture au bout de `pingTimeout` (20 s).

## Événements observés

Sur une session de 100 secondes :

| Événement | Occurrences | Cadence | Équivalent REST |
|---|---|---|---|
| `gps` | 100 | ~1 Hz | `/train/gps` |
| `connected_devices` | 25 | ~4 s | aucun (404) |
| `trainDetails` | 3 | ~30 s | `/train/details` |
| `trainProgress` | 3 | ~30 s | aucun — **charge utile `null`** |
| `modulesConfiguration` | 1 | à la connexion | aucun |
| `train_number` | 1 | à la connexion | aucun |
| `data_consumption` | 1 | à la connexion | aucun (404) |
| `bar_attendance` | 1 | à la connexion | aucun |

Charges utiles inédites :

```json
train_number       {"projectId":1,"trainId":2116,"boxId":2,"externalId":"260"}
bar_attendance     {"isBarQueueEmpty":false}
connected_devices  {"devices":29}
data_consumption   {"ip":"…","grant":true,"class":5,"granted_bandwidth":100000,
                    "consumed_data":205242,"remaining_data":818757,"next_reset":…}
```

`modulesConfiguration` expose une quarantaine de clés de configuration du portail
(`portal.journey.map.*`, `portal.chat.*`, `portal.streaming.*`…), sans intérêt direct ici.

## Ce que le socket apporterait

- **GPS à 1 Hz** au lieu d'un sondage toutes les 2 s : titre de barre de menus plus fluide,
  statistiques de vitesse et de distance sensiblement plus justes.
- **Push au lieu de polling** : plus de requêtes à vide hors couverture.
- **Quatre événements sans équivalent REST** : `connected_devices`, `data_consumption`,
  `bar_attendance`, `train_number`.

Coût : une implémentation Engine.IO v4 en long-polling, soit environ 150 lignes
(handshake, boucle de lecture, PING/PONG, parsing des trames `42<namespace>,[…]`).
Aucune bibliothèque n'est nécessaire, et `socket.io-client-swift` serait même
à contre-emploi puisqu'elle privilégie un transport websocket ici indisponible.

## Points de vigilance

- Le forfait est de 1 Go par tranche (`consumed_data` + `remaining_data` = 1 024 000 Ko),
  remis à zéro périodiquement. Le long-polling maintient une requête HTTP ouverte en
  permanence : à surveiller, même si le volume utile reste négligeable.
- `pingTimeout` de 20 s : une traversée de tunnel invalide la session, il faut
  refaire le handshake et se reconnecter au namespace.
- `trainProgress` renvoie `null` sur cette rame — inutilisable en l'état.
