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
- Ein neuer Kommentar darf nur mit einer eigenen Marker-Zeile angelegt werden:
  == KOMMENTAR TT.MM.JJJJ HH:MM ==  und darunter der Text. Er darf an jeder
  Stelle zwischen den bestehenden Abschnitten stehen.
- Aufwand darf nur mit einer eigenen Marker-Zeile gebucht werden:
  == AUFWAND TT.MM.JJJJ HH:MM DAUER ==  (z. B. 1,5h) und darunter der
  Buchungskommentar. Beliebig viele solcher Blöcke sind erlaubt.
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
| `===== NEUER KOMMENTAR =====` | Text darunter wird als neuer Kommentar angelegt (Zeitpunkt: jetzt) |
| `== KOMMENTAR TT.MM.JJJJ HH:MM ==` | neuer Kommentar mit diesem Zeitstempel – wird an der passenden Stelle im Ticketverlauf einsortiert |
| `== AUFWAND TT.MM.JJJJ HH:MM 1,5h ==` | neue Zeitbuchung (Aufwand) am angegebenen Tag mit Dauer, Startzeit und Buchungskommentar |
| `===== KOMMENTAR <ID> · … =====` | bestehender Kommentar wird aktualisiert (nur bei Änderung) |

Leere Abschnitte oder fehlende Marker werden ignoriert – es wird nichts versehentlich gelöscht.

### Neue Kommentare mit Zeitstempel

An beliebiger Stelle in der RTF (z. B. zwischen zwei bestehenden Kommentaren) eine Marker-Zeile mit Datum und Uhrzeit einfügen, darunter den Text:

```text
== KOMMENTAR 01.11.2026 10:00 ==
Telefonat mit Kunde: Freigabe erteilt, Umsetzung ab Montag.
```

Beim Sync wird der Kommentar angelegt und über die Backdating-API des Plugins **redmine-extended-api** auf den angegebenen Zeitpunkt (lokale Zeit) datiert – Redmine sortiert ihn damit chronologisch korrekt in den Verlauf ein. Mehrere solcher Blöcke sind möglich; sie werden in Dateireihenfolge verarbeitet. Erlaubte Formate: `TT.MM.JJJJ HH:MM`, `TT.MM.JJJJ HH:MM:SS`, `JJJJ-MM-TT HH:MM`, nur Datum (= 00:00). Zwei oder mehr `=` am Zeilenanfang/-ende genügen.

Ist das Plugin nicht installiert oder die Funktion „Backdating“ in den Plugin-Einstellungen nicht aktiv, wird der Kommentar trotzdem angelegt – dann mit dem aktuellen Zeitpunkt, und das Script zeigt eine Warnung.

### Aufwand buchen (Zeiterfassung)

Beliebig viele Zeitbuchungen lassen sich an jeder Stelle der RTF anlegen – je Buchung eine Marker-Zeile, darunter der Buchungskommentar:

```text
== AUFWAND 03.11.2026 09:00 1,5h ==
Fehleranalyse und Telefonat mit dem Kunden

== AUFWAND 04.11.2026 13:15-14:00 Support ==
Rückfrage zur Freigabe

== AUFWAND 05.11.2026 90min ==
```

Aufbau der Marker-Zeile: `AUFWAND <Datum> [<Startzeit>] <Dauer> [<Aktivität>]`

| Teil | Formate | Pflicht |
|---|---|---|
| Datum | `TT.MM.JJJJ`, `TT.MM.JJ`, `JJJJ-MM-TT` | ja |
| Startzeit | `HH:MM` | nein |
| Dauer | `1,5h` · `2h` · `1.25std` · `90min` · `45m` · `1h30` · `1:30h` · `1,5` – oder statt Startzeit + Dauer eine Spanne `09:00-10:30` / `09:00 bis 10:30` | ja |
| Aktivität | Name (oder Anfang davon, z. B. `entw`) bzw. ID der Redmine-Aktivität | nein – sonst `REDMINE_ACTIVITY` aus der Config, sonst Standard-Aktivität |

- Gebucht wird als der verbundene Benutzer auf das geöffnete Ticket (`spent_on` = Datum, `hours` = Dauer).
- Der Text unter dem Marker wird zum Buchungskommentar; mehrere Zeilen werden mit ` / ` verbunden (Redmine erlaubt nur eine Zeile, max. 1024 Zeichen). Ein leerer Kommentar ist erlaubt.
- **Startzeit:** Redmine kennt für Zeitbuchungen nur ein Datum, keine Uhrzeit. Ist eine Startzeit angegeben, wird die Spanne deshalb vor den Kommentar geschrieben (`09:00–10:30 · Fehleranalyse …`). Gibt es in Redmine benutzerdefinierte Felder für Zeitbuchungen (z. B. „Beginn“/„Ende“), können deren IDs in `.redmine_config` hinterlegt werden – dann werden Start-/Endzeit zusätzlich dort gespeichert:

  ```bash
  REDMINE_TIME_START_FIELD_ID=5   # Custom-Field „Beginn“ (Zeitbuchung)
  REDMINE_TIME_END_FIELD_ID=6     # Custom-Field „Ende“ (Zeitbuchung)
  REDMINE_TIME_IN_COMMENT=0       # Spanne dann nicht mehr in den Kommentar schreiben
  ```
- Fehlerhafte Blöcke (ungültiges Datum, fehlende Dauer, unbekannte Aktivität) werden mit Meldung übersprungen – die übrigen Buchungen laufen trotzdem.
- Der bisher gebuchte Aufwand des Tickets steht im Terminal (`Aufwand`) und im Kopf der RTF.

## Voraussetzungen

- macOS (nutzt `textutil` und `open`), Bash ≥ 3.2
- `curl` und `jq` (`brew install jq`)
- Redmine-API-Key: Redmine → *Mein Konto* → *API-Zugriffsschlüssel*
- Für Aufwandsbuchungen: Modul *Zeiterfassung* im Projekt aktiv und Recht *Aufwand buchen*
- Für datierte Kommentare: Plugin [redmine-extended-api](https://github.com/leanderkretschmer/redmine-extended-api) mit aktivierter Backdating-Funktion

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

Nur den Text **unter** den `=====`-Markern ändern, die Marker selbst nicht anfassen. Neue Kommentare mit `== KOMMENTAR TT.MM.JJJJ HH:MM ==` einfügen.

![Ticket-Ansicht und RTF](img/02-ticket-und-rtf.png)

### 3. Änderung erkannt → ENTER synchronisiert

Nach dem Speichern erscheint der grüne Haken. **ENTER** schickt die Änderungen nach Redmine, danach geht es zurück zur Startseite und die RTF wird geleert.

![Änderung erkannt](img/03-aenderung-erkannt.png)

## Hinweise

- In der RTF stehen immer alle Kommentare in voller Länge; das Terminal zeigt nur die ersten 3 gekürzt an.
- TextEdit speichert automatisch; vor ENTER trotzdem mit ⌘S sichern, damit der letzte Stand synchronisiert wird.
- Abbruch mit `q` lässt die RTF unverändert; beim nächsten Ticket wird sie überschrieben.
- Zeilen, die mit `==` beginnen und enden, sind als Marker reserviert – nicht im Kommentartext verwenden.
