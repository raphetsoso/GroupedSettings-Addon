# GroupedSettings Addon for Other Apps

An iOS tweak designed to adapt and apply the exact visual customization logic from GroupedSettings17 to compatible Apps.

## Overview

- **Tweak Name:** GroupedSettings Addon for Other Apps
- **Target OS:** iOS 15.0 – 26.0.1
- **Primary Function:** Replicates the styling, hierarchy, and appearance mechanics of GroupedSettings17 across targeted applications without altering default features or adding extra settings panels.

## Technical Details

- **Frameworks:** UIKit, Logos (Theos)
- **Origin:** Adaptation of the GroupedSettings17 source code logic, modified to hook into selected application bundle IDs.

## Détection des apps

Les sous-menus ne proposent que les apps **réellement installées** sur l'appareil
(lecture de `LSApplicationWorkspace`, recalculée à chaque ouverture du sous-menu) :

- les apps Apple et tierces « populaires » des listes intégrées sont masquées si elles
  ne sont pas installées (ex. app Apple supprimée, WhatsApp absent) ;
- les apps en cours de téléchargement (placeholders), déchargées ou supprimées sont ignorées ;
- les autres apps installées sont ajoutées automatiquement au menu « Apps tierces » ;
- si l'API système est indisponible, les listes intégrées sont affichées telles quelles
  (plutôt qu'un menu vide).

## Santé et Forme (couche E)

Ces deux apps affichent leurs grandes cartes dans des `UICollectionView` en compositional layout
(et non des `UITableView`). Une couche dédiée, active uniquement dans `com.apple.Health` et
`com.apple.Fitness`, met à zéro les marges latérales des sections et des items symétriques,
remplace la référence d'inset « marges de mise en page » par la zone sûre, et supprime les
rayons de coin des cartes pleine largeur.

Diagnostic (`GS_DEBUG=1`) : ouvrir Santé / Forme puis lire
`/var/mobile/Library/Preferences/GroupedSettings17Addon.log` (lignes `COUCHE E` et `CARDCELL`).
