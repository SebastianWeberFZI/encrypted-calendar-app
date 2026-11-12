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
- Monat (Komorebi-Raster mit Terminlabels und mehrtägigen Balken), Woche, Liste
- Wiederholungen (täglich/wöchentlich an Wochentagen/monatlich/jährlich, Intervall, Ende), einzelne Vorkommen löschen
- Feiertage je Bundesland (lokal berechnet)
- Erinnerungen als **Push** (exakte Alarme) und/oder **E-Mail** (SMTP direkt vom Handy)
- **Mehrtägige Termine** als ein Termin mit durchgehendem Balken; anlegen per langem Drücken und Ziehen über die Tage
- Startbildschirm-**Widgets**: „Monat“ (scrollbar, Tag antippen legt einen Termin an) und „Agenda“; Kalenderauswahl je Widget über das Zahnrad
- Offline-First, Sync-Queue, Konflikte: jüngere Änderung gewinnt, die andere bleibt als „(Konflikt)“-Kopie
- **Abgleich mit dem Google-Kalender** (bzw. jedem Kalender des Handys), siehe unten

## Google-Kalender abgleichen
Für alle, die ihren Google-Kalender weiter nutzen. Der Abgleich läuft auf dem Android-Handy dieser
Person über den Kalenderspeicher von Android – ohne Google-Login in der App und ohne Google-Bibliothek;
Google selbst überträgt die Termine zwischen Handy und Konto.

1. Auf dem Handy: Google-Konto in den Android-Einstellungen, Kalender-Synchronisierung an.
2. In der App: Einstellungen → **Google-Kalender** → „Mit dem Kalender dieses Handys abgleichen“,
   Kalenderzugriff erlauben, Datenquelle für die Google-Termine wählen (empfohlen: die gemeinsame).

Danach:
- Termine aller App-Kalender landen im Google-Hauptkalender (je App-Kalender umstellbar oder abschaltbar).
  Sie sind als Kopien der App markiert und kommen nicht doppelt zurück.
- Termine aus dem Google-Kalender erscheinen im App-Kalender „<Name> – Google“ (z. B. „Sarah – Google“).
  Alle, die die Datenquelle nutzen, sehen sie; ändern kann sie nur die Besitzerin – Änderungen anderer
  werden zurückgesetzt.
- Änderungen und Löschungen laufen in beide Richtungen (beim Öffnen, nach Änderungen, etwa jede Minute bei
  offener App und alle 15 Minuten im Hintergrund). Ändern beide Seiten denselben Termin, gewinnt die
  Herkunftsseite. Verschwinden plötzlich viele Termine auf einer Seite, wird nichts gelöscht.
- Serien, die die App nicht abbilden kann (z. B. „jeden 2. Dienstag“), erscheinen als einzelne Termine
  (30 Tage zurück bis gut ein Jahr voraus), änderbar nur in Google. Erinnerungen, Teilnehmer und
  Terminfarben werden nicht übertragen; abgeglichen wird ab 90 Tagen in der Vergangenheit.
- Zuordnungen liegen nur auf diesem Handy (`google_sync/state.json`); übernommene Termine tragen im Repo
  das Feld `google` (ID im Handy-Kalender), der Kalender das Feld `sync` (Besitzerin).

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
