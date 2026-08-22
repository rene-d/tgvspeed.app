# Fixtures

Documents JSON capturés à bord du TGV INOUI 6155 le 22 août 2026,
servant de référence pour les modèles `Codable`.

| Fichier | Source |
|---|---|
| `gps.json` | `GET /router/api/train/gps` |
| `trainDetails.json` | `GET /router/api/train/details` |
| `connection_status.json` | `GET /router/api/connection/status` |
| `connection_statistics.json` | `GET /router/api/connection/statistics` |
| `data_consumption.json` | événement Socket.IO `data_consumption` (pas d'équivalent REST) |
| `connected_devices.json` | événement Socket.IO `connected_devices` (pas d'équivalent REST) |

L'adresse IP du client a été remplacée par `10.0.0.1` dans `data_consumption.json`.

Le relevé du flux Socket.IO est détaillé dans [`../docs/socketio.md`](../docs/socketio.md).
