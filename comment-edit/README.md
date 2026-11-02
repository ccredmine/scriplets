# comment-edit – Redmine-Tickets als RTF bearbeiten

## Prompt für ChatGPT

Wenn der Inhalt der `current-ticket.rtf` von ChatGPT überarbeitet werden soll, den Text zusammen mit diesem Prompt übergeben:

```text
Du bekommst den Inhalt eines Redmine-Tickets. Bearbeite ausschließlich den Inhalt
der Beschreibung und der Kommentare.

Regeln:
- Bearbeite niemals die Syntax oder Struktur der Datei.
- Marker-Zeilen (===== BESCHREIBUNG =====, ===== NEUER KOMMENTAR =====,
  ===== KOMMENTAR <ID> · <Autor> · <Datum> =====), Kopfzeilen, Reihenfolge und
  Formatierung bleiben exakt so, wie sie sind.
- Erlaubt ist nur das Bearbeiten, Entfernen oder Hinzufügen von Inhalten
  innerhalb der markierten Bereiche.
- Gib den kompletten Text mit unveränderter Struktur zurück.
```

Das Ergebnis in TextEdit einfügen, speichern (⌘S) – das Script erkennt die Änderung und synchronisiert nach ENTER.

---

## Was macht das Tool?

`redmine_sync.sh` ist eine kleine CLI-Oberfläche für macOS:

1. Ticket-ID eingeben → das Ticket wird im Terminal angezeigt
2. `current-ticket.rtf` wird neben dem Script geschrieben und im Standard-Editor (TextEdit) geöffnet
3. Datei bearbeiten und speichern → das Script erkennt die Änderung → ✔
4. **ENTER** synchronisiert nach Redmine → zurück zur Startseite, die RTF wird geleert

Synchronisiert werden:

| Abschnitt in der RTF | Wirkung in Redmine |
|---|---|
| `===== BESCHREIBUNG =====` | Beschreibung des Tickets wird aktualisiert (nur bei Änderung) |
| `===== NEUER KOMMENTAR =====` | Text darunter wird als neuer Kommentar angelegt |
| `===== KOMMENTAR <ID> · … =====` | bestehender Kommentar wird aktualisiert (nur bei Änderung) |

Leere Abschnitte oder fehlende Marker werden ignoriert – es wird nichts versehentlich gelöscht.

## Voraussetzungen

- macOS (nutzt `textutil` und `open`), Bash ≥ 3.2
- `curl` und `jq` (`brew install jq`)
- Redmine-API-Key: Redmine → *Mein Konto* → *API-Zugriffsschlüssel*

## Einrichtung

```bash
chmod +x redmine_sync.sh
./redmine_sync.sh
```

Beim ersten Start werden Redmine-URL und API-Key abgefragt und in `.redmine_config` (neben dem Script) gespeichert. Alternativ `.redmine_config.example` kopieren und ausfüllen. Die Datei ist per `.gitignore` ausgeschlossen – **nie einchecken**.

## Ablauf

### 1. Startseite – Ticket-ID eingeben

Unten steht, mit welcher Redmine-Instanz und welchem Benutzer das Tool verbunden ist. Alle Änderungen laufen unter diesem Benutzer.

![Startseite](img/01-startseite.png)

### 2. Ticket-Ansicht + RTF im Editor

Links das Ticket mit Metadaten, Beschreibung und den ersten Kommentaren. Rechts die automatisch geöffnete `current-ticket.rtf`. Das Terminal wartet, bis die Datei gespeichert wird (`q` bricht ab).

Nur den Text **unter** den `=====`-Markern ändern, die Marker selbst nicht anfassen.

![Ticket-Ansicht und RTF](img/02-ticket-und-rtf.png)

### 3. Änderung erkannt → ENTER synchronisiert

Nach dem Speichern erscheint der grüne Haken. **ENTER** schickt die Änderungen nach Redmine, danach geht es zurück zur Startseite und die RTF wird geleert.

![Änderung erkannt](img/03-aenderung-erkannt.png)

## Hinweise

- In der RTF landen maximal 5 Kommentare, im Terminal werden 3 angezeigt.
- TextEdit speichert automatisch; vor ENTER trotzdem mit ⌘S sichern, damit der letzte Stand synchronisiert wird.
- Abbruch mit `q` lässt die RTF unverändert; beim nächsten Ticket wird sie überschrieben.
