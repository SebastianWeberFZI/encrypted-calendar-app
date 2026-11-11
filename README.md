# Kalender (verschlüsselt, GitHub-Backend)

Gemeinsamer Android-Kalender für zwei Personen nach dem Vorbild „Einfacher Kalender Tagesplaner“
(Komorebi). Daten liegen in privaten GitHub-Repos, jede Datei einzeln mit **AES-256-GCM**
verschlüsselt (Schlüssel per **Argon2id** aus der Passphrase) – gleiches Konzept wie
`encrypted-todo-app`.

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
