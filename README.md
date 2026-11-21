# PillMusic

Une petite pilule flottante pour piloter ta musique sur **macOS** (Apple Musique, Spotify) et **Windows** (Spotify, Apple Music, Deezer, Tidal, navigateurs…) : pochette animée, titre, progression, morceau précédent/suivant et paroles synchronisées — toujours à portée de main, sans ouvrir Musique.

<p align="center"><img src="docs/pill.png" width="520" alt="PillMusic en clair et en sombre"></p>

## Fonctionnalités

- **Pilule flottante** qui se déplace où tu veux (y compris dans les coins), au-dessus de toutes les fenêtres, sans gêner le Dock ni voler le focus clavier.
- **Pochette en métal liquide** : un shader qui reprend les couleurs de la pochette en cours.
- **Apple Musique et Spotify** : la pilule suit automatiquement le lecteur qui joue (choix manuel au clic droit › Lecteur si les deux sont installés).
- **Contrôles** : lecture/pause, précédent, suivant, barre de progression.
- **Paroles synchronisées** (via [LRCLIB](https://lrclib.net)) qui flottent au-dessus ou en dessous de la pilule ; glisser pour relire les lignes précédentes.
- **Raccourci global** `⌃⌘M` pour afficher/masquer la pilule.
- **Thème clair / sombre**, trois tailles, lancement à l'ouverture de session.
- **Économe** : moins d'images par seconde sur batterie et en mode économie d'énergie, rendu en pause quand la pilule est cachée.

## Installation

Tout se télécharge depuis la page [Releases](../../releases) (pas besoin de télécharger le code).

### Mac

1. Télécharge `PillMusic.zip`, dézippe et glisse **PillMusic.app** dans **Applications**.
2. Au premier lancement, macOS bloque l'app (elle n'est pas notariée par Apple) : ouvre **Réglages Système → Confidentialité et sécurité**, descends tout en bas et clique sur **Ouvrir quand même**.
3. Accepte l'autorisation de contrôler **Musique** ou **Spotify** (app de bureau).

Nécessite macOS 14 (Sonoma) ou plus récent, sur un Mac Apple Silicon (M1 et suivants).

### Windows

1. Télécharge `PillMusic-Windows-x64.zip` (ou `-arm64` pour les PC Snapdragon), dézippe et lance **PillMusic.exe** (tu peux le ranger où tu veux, par exemple dans Documents).
2. Windows affiche *« Windows a protégé votre ordinateur »* (l'app n'est pas signée) : clique sur **Informations complémentaires → Exécuter quand même**.

La pilule suit n'importe quel lecteur qui apparaît dans les contrôles multimédias de Windows : Spotify, Apple Music, Deezer, Tidal, YouTube dans le navigateur… Raccourci : `Ctrl+Alt+M`. Clic droit sur la pilule ou sur l'icône près de l'horloge pour les réglages. Windows 10 (2004) ou Windows 11.

## Compiler soi-même

**Mac** — pas besoin de Xcode, les outils en ligne de commande suffisent (`xcode-select --install`) :

```sh
./scripts/build.sh      # → build/PillMusic.app
./scripts/package.sh    # → build/PillMusic.zip, prêt à partager
```

**Windows** — avec le [SDK .NET 8](https://dotnet.microsoft.com/download) (compile aussi depuis macOS ou Linux) :

```sh
dotnet publish windows/PillMusic -c Release -r win-x64 -o out   # → out/PillMusic.exe
```

GitHub Actions compile les deux versions Windows à chaque modification de `windows/` et les joint aux Releases.

## Structure

| Fichier | Rôle |
| --- | --- |
| `Sources/PillMusic/App.swift` | Fenêtres, menu, raccourci, placement à l'écran |
| `Sources/PillMusic/PillView.swift` | Interface de la pilule (SwiftUI) |
| `Sources/PillMusic/MusicController.swift` | Dialogue avec Musique et Spotify (AppleScript) |
| `Sources/PillMusic/LiquidMetal.swift` | Shader de la pochette |
| `Sources/PillMusic/Lyrics.swift` | Paroles synchronisées |
| `Sources/PillMusic/Artwork.swift` | Recherche de pochettes et de liens |
| `Sources/PillMusic/Power.swift` | Adaptation à la batterie |
| `icon/` | Génération de l'icône de l'app |
| `windows/PillMusic/` | Version Windows (C#, WPF) : même design, même shader, mêmes paroles |

## Crédits

- Police [Geist](https://vercel.com/font) — SIL Open Font License (`Resources/Geist-OFL.txt`).
- Paroles fournies par [LRCLIB](https://lrclib.net).

## Licence

[MIT](LICENSE)
