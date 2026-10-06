# Languages

NOOP on iPhone and Android offers two languages: **English** and **German**.

The in-app choice is under Settings → Appearance → Language:

- **English**
- **Deutsch**
- **System** — German when the phone is set to German, English for every other phone language

A change applies the next time the app is opened.

## Files native speakers edit

Do not rename the keys. Change only the text a person reads.

| Language | Android | Apple |
| --- | --- | --- |
| English | `android/app/src/main/res/values/strings.xml` | `Strand/Resources/Localizable.xcstrings` (`en` value) |
| German | `android/app/src/main/res/values-de/strings.xml` | `Strand/Resources/Localizable.xcstrings` (`de` value) |

Bottom bar, in that order:

| Key | English | German |
| --- | --- | --- |
| `nav_bar_home` / catalog key `Home` | Home | Startseite |
| `nav_bar_health` / catalog key `Health` | Health | Gesundheit |
| `nav_bar_coach` / catalog key `AI Coach` | AI Coach | KI-Coach |
| `nav_bar_more` / catalog key `More` | More | Mehr |

On Android the bar reads the `nav_bar_*` strings. On Apple the bar uses the catalog keys `Home`, `Health`, `AI Coach`, and `More`.

## What stays on the device

Health data lives in the app's private database. Settings (language, units, coach, alarms, and the rest) live in the app's preferences. Both survive an update of the same install. A copy of the preferences is also written into the app's private files and restored if the preferences file comes back empty after an update. Nothing is uploaded.
