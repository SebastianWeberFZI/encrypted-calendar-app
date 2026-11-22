# Kalender (verschlüsselt, GitHub-Backend)

Gemeinsamer Android-Kalender für zwei Personen nach dem Vorbild „Einfacher Kalender Tagesplaner“
(Komorebi). Daten liegen in privaten GitHub-Repos, jede Datei einzeln mit **AES-256-GCM**
verschlüsselt (Schlüssel per **Argon2id** aus der Passphrase) – gleiches Konzept wie
`encrypted-todo-app`.

## Installieren

<a href="https://sebastianweberfzi.github.io/encrypted-calendar-app/"><img src="https://sebastianweberfzi.github.io/encrypted-calendar-app/qr.svg" alt="QR-Code der F-Droid-Paketquelle (Kalender)" width="180" align="right"></a>

**F-Droid (empfohlen):** Auf der [Installationsseite](https://sebastianweberfzi.github.io/encrypted-calendar-app/) den QR-Code scannen
(F-Droid → Einstellungen → Paketquellen → **+**) oder dort auf dem Handy auf „hier tippen“ –
die Paketquelle wird dann direkt in F-Droid hinzugefügt. Updates kommen danach automatisch.

**Ohne F-Droid:** APK der [neuesten Version](https://github.com/SebastianWeberFZI/encrypted-calendar-app/releases/latest)
herunterladen und installieren.

Beim ersten Start fragt die App nach dem privaten Daten-Repo, einem Fine-grained Token
(nur „Contents: Read and write“) und der Passphrase.

<br clear="right">

## Funktionen
- Mehrere **Datenquellen** (z. B. „Gemeinsam“ + „Privat“), je Repo + Passphrase
- Beliebig viele **Kalender** je Datenquelle (Farbe, Symbol, Standard-Erinnerungen; Art „Termine“ oder „Geburtstage“)
- Kalender einzeln oder gemeinsam einblenden (Kalenderleiste, „nur dieser“ per langem Tippen)
- Monat (Komorebi-Raster mit Terminlabels und mehrtägigen Balken; Wochen laufen durchgehend, frei nach oben/unten scrollbar), Woche, Liste
- Wiederholungen (täglich/wöchentlich an Wochentagen/monatlich/jährlich, Intervall, Ende), einzelne Vorkommen löschen
- Feiertage je Bundesland (lokal berechnet)
- Erinnerungen als **Push** (exakte Alarme) und/oder **E-Mail** (SMTP direkt vom Handy)
- **Mehrtägige Termine** als ein Termin mit durchgehendem Balken; anlegen per langem Drücken und Ziehen über die Tage
- Startbildschirm-**Widgets**: „Monat“ (scrollbar, Tag antippen legt einen Termin an) und „Agenda“; Kalenderauswahl je Widget über das Zahnrad
- Offline-First, Sync-Queue, Konflikte: jüngere Änderung gewinnt, die andere bleibt als „(Konflikt)“-Kopie
- **Abgleich mit dem Google-Kalender** (bzw. jedem Kalender des Handys), siehe unten
- **Kalender-Abos** (ICS/webcal), z. B. Abfuhrtermine oder Schulferien, siehe unten

## Google-Kalender abgleichen
Für alle, die ihren Google-Kalender weiter nutzen. Der Abgleich läuft auf dem Android-Handy dieser
Person über den Kalenderspeicher von Android – ohne Google-Login in der App und ohne Google-Bibliothek;
Google selbst überträgt die Termine zwischen Handy und Konto.

1. Auf dem Handy: Google-Konto in den Android-Einstellungen, Kalender-Synchronisierung an.
2. In der App: Einstellungen → **Google-Kalender** → „Mit dem Kalender dieses Handys abgleichen“,
   Kalenderzugriff erlauben, Kalender des Handys wählen (vorgeschlagen: der Google-Hauptkalender),
   Datenquelle für die Google-Termine wählen (empfohlen: die gemeinsame).
3. Vor dem Einschalten zeigt **Probelauf** Termin für Termin, was passieren würde – ohne etwas zu ändern.

Gefahrlos ausprobieren: in Google einen leeren Kalender (z. B. „App-Test“) anlegen, auf dem Handy
synchronisieren lassen, ihn in Schritt 2 wählen und als Datenquelle die private nehmen. „Abgleich beenden“
entfernt danach alle Kopien wieder. Die App ändert nur den gewählten Kalender und nur auf dem Handy, auf dem
der Abgleich eingeschaltet ist; Termine, die in Google angelegt wurden, ändert oder löscht sie nur, wenn ihre
Besitzerin das in der App tut. Was jeder Abgleich geändert hat, steht unter „Letzte Änderungen“.

Danach:
- Termine aller App-Kalender landen im Google-Hauptkalender (je App-Kalender umstellbar oder abschaltbar).
  Sie sind als Kopien der App markiert und kommen nicht doppelt zurück.
- Termine aus dem Google-Kalender erscheinen im App-Kalender „<Name> – Google“ (z. B. „Sarah – Google“).
  Alle, die die Datenquelle nutzen, sehen sie; ändern kann sie nur die Besitzerin – Änderungen anderer
  werden zurückgesetzt.
- Einzelne Google-Termine kann die Besitzerin einem anderen App-Kalender zuordnen (Termin antippen →
  „Zuordnen“, oder im Bearbeiten-Dialog den Kalender wechseln). Sie bleiben mit dem Original in Google
  verbunden; Änderungen laufen weiter in beide Richtungen, das Original wird nicht ersetzt.
- Änderungen und Löschungen laufen in beide Richtungen (beim Öffnen, nach Änderungen, etwa jede Minute bei
  offener App und alle 15 Minuten im Hintergrund). Ändern beide Seiten denselben Termin, gewinnt die
  Herkunftsseite. Verschwinden plötzlich viele Termine auf einer Seite, wird nichts gelöscht.
- Serien wie in Google: „jeden 2. Dienstag“, „letzter Freitag im Monat“, „am 1. und 15.“, „letzter
  Werktag“, „2. Sonntag im Mai“, „endet nach 10 Terminen“ werden echte Serien (änderbar, zuordenbar).
  Nur sehr seltene Regeln (z. B. stündlich, Kalenderwochen) erscheinen als einzelne Termine (30 Tage zurück
  bis gut ein Jahr voraus), änderbar nur in Google.
- Erinnerungen (Benachrichtigungen) laufen in beide Richtungen, wenn eingeschaltet. Auf dem Handy mit dem
  Abgleich meldet sie dann der Google-Kalender, die App nicht zusätzlich; Erinnerungen an Google-Termine
  anderer bekommt man nicht. E-Mail-Erinnerungen bleiben getrennt. Teilnehmer und Terminfarben werden nicht
  übertragen.
- Zeitraum: standardmäßig ab 90 Tagen in der Vergangenheit, einstellbar bis „gesamte Vergangenheit“ (vorher
  zeigt ein Probelauf die Menge). Jeder Termin ist eine Datei im Daten-Repo; GitHub nimmt nur einige hundert
  neue Dateien pro Stunde an, die App sendet große Mengen deshalb gedrosselt über mehrere Stunden.
- Jede Person kann das auf ihrem eigenen Handy einschalten (der Kalender heißt dann nach ihrem Profilnamen,
  z. B. „Sebastian – Google“). Die Google-Termine der anderen Person landen standardmäßig mit im eigenen
  Google-Kalender; unter „Je App-Kalender“ lässt sich das abschalten. Einen in Google geteilten Kalender
  sollte nur eine Person übernehmen, sonst erscheint er doppelt.
- Zuordnungen liegen nur auf diesem Handy (`google_sync/state.json`); übernommene Termine tragen im Repo
  das Feld `google` (ID im Handy-Kalender, Besitzerin), der Kalender das Feld `sync` (Besitzerin).

## Kalender-Abos (z. B. Müllabfuhr)
Ein Kalender kann seine Termine aus einer Internet-Adresse beziehen (iCalendar/ICS, auch `webcal://`):
Kalender verwalten → **+ Kalender** → „Abo eines Internet-Kalenders“.

- Vorlage **Abfuhrtermine Landkreis Germersheim**: Ortschaft, Behältergröße und Abfallarten wählen. Die
  Seite des Kreises gibt die Datei erst über ein Formular heraus; die App schickt es beim Abruf selbst ab
  (das klappt auch mit anderen Seiten, die einen solchen „Als ICS herunterladen“-Knopf haben).
  Die Vorlage legt Farben je Abfallart und die Erinnerung „Vortag um 19:00“ an.
- Jedes Handy ruft das Abo etwa alle 12 Stunden ab (App oder Hintergrund; nach einem Fehler nach einer
  Stunde erneut), im Kalender-Editor auch sofort. Die Termin-IDs entstehen aus Kalender, Tag und Titel –
  so legen beide Handys dieselben Termine an, ohne Doppelte und ohne Konflikte.
- Abo-Termine ändert niemand von Hand. Fehlt ein künftiger Termin in der Datei, verschwindet er (z. B.
  verlegte Abfuhr); Vergangenes und Heutiges bleibt stehen, auch wenn der Anbieter nur „ab heute“ liefert.
- Farben: Termine, deren Titel einer Farbbedeutung des Kalenders entspricht (z. B. „Restmüll“), bekommen
  diese Farbe. Erinnerungen und Farben des Kalenders gelten für alle seine Termine.
- Abo-Kalender werden nicht in den Google-Kalender übertragen.
- Im Repo: der Kalender trägt das Feld `subscription` (`url`, `label`); der Abrufstand liegt nur auf dem Handy.

## Protokoll und Konflikte
- Die App notiert lokal, was beim Abgleich passiert (gesendet, empfangen, Konflikte mit den abweichenden
  Feldern, Google-Abgleich, Fehler) – eine Datei je Tag, 14 Tage, App (`[ui]`) und Hintergrund (`[bg]`) gemeinsam.
- Einstellungen → Info → **Protokoll**: ansehen, löschen oder „In Download ablegen“. Die Dateien landen unter
  `Download/Kalender-Protokoll/` (`kalender-JJJJ-MM-TT.txt` plus `kalender-info.txt` mit Version, Quellen und
  ausstehenden Änderungen) und lassen sich per USB-Kabel auf den Rechner ziehen. Schlüssel und Tokens stehen nicht
  darin, bei Konflikten aber Termininhalte.
- Eine „(Konflikt)“-Kopie entsteht nur noch, wenn beide Seiten dasselbe Feld verschieden geändert haben
  (Beginn, Ende, Ganztägig und Wiederholung zählen dabei als ein Feld). Kein Konflikt: gleicher Inhalt auf
  beiden Seiten; remote liegt ein Stand, auf dem die lokale Änderung beruht (z. B. hat der Hintergrund-Abgleich
  ihn schon gesendet); oder beide haben verschiedene Felder geändert (z. B. hier den Titel, dort den Ort) –
  dann werden beide Änderungen zusammengeführt.
- App und Hintergrund-Abgleich arbeiten mit eigenen Kopien im Speicher. Jede lokale Änderung bekommt deshalb
  einen eigenen Eintrag im Änderungs-Journal (`pending/`), den der andere Teil nicht überschreiben kann; den
  Sync-Zustand schreibt nur der Abgleich unter der Sync-Sperre. Nach dem Update auf 0.1.10 vergleicht der erste
  Abgleich einmal jeden Termin mit dem Repo und sendet Änderungen nach, die nie angekommen sind.

## Daten-Repo
```
meta.json            KDF-Parameter (unverschlüsselt)
keycheck.enc         Schlüsselprobe
calendars/<id>.enc   Kalenderdefinitionen
events/<id>.enc      ein Termin pro Datei
```

## Kompatibilität zwischen App-Versionen
Beide Handys müssen nicht gleichzeitig aktualisiert werden:
- Ältere und neuere Dokumente werden tolerant gelesen – fehlende Felder bekommen Standardwerte, falsche Typen oder unbekannte Werte bringen die App nicht zum Absturz.
- Felder, die eine App-Version nicht kennt, bleiben beim Speichern unverändert erhalten (eine ältere App beschneidet die Daten einer neueren nicht).
- Dokumente in einem neueren Verschlüsselungsformat werden weder gelesen noch überschrieben; die App bittet dann um ein Update.
- Erhöht eine neuere App die Datenformat-Generation (`schema` in `meta.json`), pausieren ältere Apps den Abgleich, behalten ihre lokalen Änderungen und bitten um ein Update.
- Unlesbare oder beschädigte Dateien werden übersprungen und nicht bei jedem Abgleich neu geladen.

## Entwicklung
Gebaut und getestet in der Android-Werkstatt (`../werkstatt`). Werkstatt-Builds
(`--dart-define=WERKSTATT=true`) füllen die Einrichtung für das Mock-Backend vor.
