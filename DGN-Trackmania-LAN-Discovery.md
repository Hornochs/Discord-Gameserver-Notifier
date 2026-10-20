# DGN: TrackMania Forever lässt sich per UDP-Broadcast finden

Stand: 2026-10-20 · Gemessen gegen den TMNF-Server Build 2011-02-21 auf der Dev-VM · Gefunden
beim Bau des LAN-Scans in LANPilot (Phase 6)

## Kurzfassung

`trackmania_nations.py` findet TMNF-Server bisher per **TCP-Sweep**: Jede Adresse aller Scan-Ranges
bekommt auf Port 2350 eine Info-Anfrage, 64 gleichzeitig, mit 1,5 s Timeout. Laut Docstring
antworten Trackmania-Server nicht auf Broadcasts. **Das stimmt nicht.** TMNF beantwortet
dieselbe UDP-Session-Abfrage, die DGN schon für Sunrise schickt. Dafür braucht die Abfrage
zwei Dinge:

1. die Spiel-ID **`TmForever`**,
2. den **TMNF-Prüfsummenschlüssel** (`TrackmaniaNations._CHECKSUM_KEY` in opengsq), nicht den
   von Sunrise.

Mit dem Sunrise-Schlüssel kommt für keine Spiel-ID eine Antwort. Daher stammt vermutlich die
Annahme, TMNF reagiere nicht auf Broadcasts.

Nichts umgebaut, nur aufgeschrieben.

## Messung

| Ziel | Antwort |
|---|---|
| Directed Broadcast (`x.x.x.255` des Netzes) | ja, < 1 ms, von UDP 2350 |
| `255.255.255.255` | ja |
| Unicast an die Server-IP | ja |
| `127.0.0.1` | ja |
| Spiel-IDs `TMForever`, `TmNationsForever`, `TmUnitedForever`, `TmNations`, `TmUnited`, `""` … | keine Antwort |
| Spiel-ID `TmForever` mit **Sunrise**-Schlüssel | keine Antwort |
| Spiel-ID `TmForever` mit **TMNF**-Schlüssel | **Antwort** |

Der Server lauscht auf UDP 2350 sowie TCP 2350 und 3450. XML-RPC lief nur auf `127.0.0.1:5000`.

## Paketformat

Das Format ist dasselbe wie bei Sunrise (`TrackmaniaSunrise.build_session_query()` /
`parse_session_reply()`). Nur der Schlüssel für die Prüfsumme ist ein anderer.

**Anfrage** (Nachrichtentyp 0, CNetFormQuerrySessions), ohne Längenpräfix:

```
82 00 <prüfsumme u32>                    Flags (0x80 | Checksum), Typ 0
u32 len + "TmForever"                    Spiel-ID
u32 len + Client-Name                    beliebig, z. B. "opengsq"
00 00 00 00 00 00                        Adresse, vom Server nicht genutzt
u32 nonce
```

**Antwort** (Typ 1, CNetFormEnumSessions), 79 Byte, von UDP 2350:

```
82 01 <prüfsumme u32>
u32 nonce          ← bei TMNF immer 0, die Nonce der Anfrage wird NICHT zurückgegeben
str "GameNet"      Anwendung
str "TmForever"    Spiel-ID
str "100"          Version
str <Hostname>     Rechnername des Servers (nicht der Servername)
4 Byte IP (umgedreht) + u16 Port     Server-Adresse und Spielport (2350)
4 Byte IP (umgedreht) + u16 Port     zweite Adresse (hier identisch)
```

Wichtig für die Umsetzung:

- **`TrackmaniaNations.build_message()` hängt ein u32-Längenpräfix vorne an**, weil es für TCP
  gedacht ist. Für das UDP-Datagramm müssen die ersten 4 Byte weg: `build_message(0, payload)[4:]`.
- **`TrackmaniaSunrise.parse_session_reply()` passt nicht.** Es prüft die Prüfsumme mit dem
  Sunrise-Schlüssel und verlangt die eigene Nonce. Stattdessen mit
  `TrackmaniaNations.decode_message()` dekodieren und die Felder selbst lesen. Die Nonce darf
  dabei nicht geprüft werden.
- Der Servername steht nicht in der Antwort, sondern nur der Rechnername. Name, Map, Spieler und
  Modus kommen weiterhin aus `TrackmaniaNations(ip, port).get_info()`, jetzt aber nur für die
  Hosts, die geantwortet haben.
- Den Port aus der Antwort nehmen. Bei Sunrise wich der Server einmal auf 2351 aus, als 2350
  noch belegt war, und meldete das in der Antwort. Bei TMNF ist das nicht gemessen, aber
  wahrscheinlich gleich. Deshalb die Abfrage an 2350 bis 2353 schicken.

## Skizze für DGN

```python
import secrets
import struct

from opengsq.protocols.trackmania_nations import TrackmaniaNations

def _pack(text: str) -> bytes:
    data = text.encode()
    return struct.pack("<I", len(data)) + data

nonce = secrets.randbits(32)
payload = _pack("TmForever") + _pack("opengsq") + bytes(6) + struct.pack("<I", nonce)
query = TrackmaniaNations.build_message(0, payload)[4:]   # ohne TCP-Längenpräfix

# wie bei Sunrise: query an Broadcast-Adresse(n), Ports 2350-2353, Antworten sammeln
for data, (host, sender_port) in responses:
    message_type, body = TrackmaniaNations.decode_message(data)   # prüft die TMNF-Prüfsumme
    if message_type != 1:
        continue
    # body: u32 nonce (0), str application, str game_id, str version, str host_name,
    #       4 Byte IP + u16 Port; game_id muss "TmForever" sein
    ...
    info = await TrackmaniaNations(host, port, timeout).get_info()
```

In LANPilot steht die fertige Fassung in `src/lanpilot/games/trackmania/discovery.py`. Dort
erledigen eine Funktion für beide Generationen (`_discover()`) und ein eigener, begrenzter
Parser (`parse_session()`) die Arbeit. Den Code darfst du ins DGN übernehmen.

## Was es bringt

| | TCP-Sweep (jetzt) | UDP-Session-Abfrage |
|---|---|---|
| Dauer für ein /23 (510 Adressen) | ca. 12 s. Eine Adresse ohne Host scheitert erst nach ca. 3 s mit „No route to host“, die 1,5 s Timeout schneiden das ab. | ca. 2 s (Wartezeit auf Broadcast-Antworten) plus wenige ms pro gefundenem Server |
| Verbindungen | eine TCP-Verbindung pro Adresse, alle 5 Minuten | ein Broadcast, TCP nur zu echten Servern |
| große Ranges (/16) | praktisch nicht nutzbar | egal |
| Server in anderen Subnetzen (geroutet) | gefunden | **nicht** gefunden, weil Broadcasts nicht geroutet werden. Hier hilft der Sweep weiterhin. Möglich wäre: Broadcast als Standard, Sweep als Option für Ranges ohne Broadcast. |

## Offen

- **United Forever (TMUF)** ist nicht gemessen. Vermutlich gilt dieselbe Server-Binary und
  dieselbe Spiel-ID `TmForever`, aber das ist nicht geprüft.
- Mehrere TMNF-Server auf einem Host (2351 ff.): nicht gemessen.
- Sunrise ist unverändert: Spiel-ID `TmSunrise` mit Sunrise-Schlüssel, die Nonce wird dort
  zurückgegeben.
