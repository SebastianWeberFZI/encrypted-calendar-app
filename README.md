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
- Startbildschirm-**Widgets**: „Monat“ (2–6 Wochen, passt sich der Größe an) und „Agenda“
- Offline-First, Sync-Queue, Konflikte: jüngere Änderung gewinnt, die andere bleibt als „(Konflikt)“-Kopie

## Daten-Repo
```
meta.json            KDF-Parameter (unverschlüsselt)
keycheck.enc         Schlüsselprobe
calendars/<id>.enc   Kalenderdefinitionen
events/<id>.enc      ein Termin pro Datei
```

## Entwicklung
Gebaut und getestet in der Android-Werkstatt (`../werkstatt`). Werkstatt-Builds
(`--dart-define=WERKSTATT=true`) füllen die Einrichtung für das Mock-Backend vor.
