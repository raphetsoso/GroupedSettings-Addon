#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>
#import <errno.h>

// ---------------------------------------------------------------------------
// GroupedSettings17 Addon for other Apps
//
// Applique le style edge-to-edge de GroupedSettings17 à d'autres apps Apple :
// Conseils, Contacts, Téléphone, Safari, Fichiers, Mail, Santé, Photos,
// Appareil photo, Horloge, Plans, Météo, Rappels, Forme, Localiser, Traduire,
// Freeform, Dictaphone, Livres, Assistance, Journal, Watch, Maison, toutes
// les autres apps Apple préinstallées, et des apps tierces populaires (désactivées par défaut).
//
//   - Nécessite GroupedSettings17 (dépendance dpkg + vérification à l'exécution :
//     recherche sur Havoc, sinon message d'erreur vers le GitHub).
//   - Pas de menu propre : un interrupteur par app est ajouté dans le panneau
//     GroupedSettings17 existant (domaine com.raphetsoso.groupedsettings17,
//     clés "addon.<bundle id>").
//   - Chaque app est indépendante ; chaque hook vérifie sa signature.
//
//   B. UITableView      : marges et rayon de section à 0.
//   C. UITableViewCell  : fond de cellule et highlight plats, pleine largeur.
//   D. UICollectionView : listes insetGrouped converties en grouped.
//   E. Cartes UICollectionView : marges du layout + rayons. Santé/Forme d'office ;
//      dans toute autre app dès qu'une carte arrondie pleine largeur est détectée.
//      Cartes verticales : groupe racine forcé à 100 % de largeur dès la création du
//      layout (pas de carte "penchée à gauche"), élargissement géométrique sûr,
//      passes de rattrapage au didMoveToWindow.
//      Carrousels (défilement latéral / orthogonal) : coins carrés, mais taille,
//      position et écarts d'origine conservés (jamais pleine largeur).
//   F. Marge de texte : le contenu aplati garde GS_TEXT_MARGIN pt de marge
//      (cellules, en-têtes/pieds de section, cartes) au lieu de coller au bord.
// ---------------------------------------------------------------------------

#define GS_DOMAIN CFSTR("com.raphetsoso.groupedsettings17")   // domaine de GroupedSettings17
#define GS_PKG_ID @"com.raphetsoso.groupedsettings17"
#define GS_HAVOC_URL @"https://havoc.app/package/com.raphetsoso.groupedsettings17"
#define GS_GITHUB_URL @"https://github.com/raphetsoso/groupedsettings"
#define GS_INSET_RADIUS 10.0   // rayon des cellules "inset" d'iOS 17

#ifndef GS_DEBUG
#define GS_DEBUG 1   // journal : /var/mobile/Library/Preferences/GroupedSettings17Addon.log (mettre 0 pour publier)
#endif

#if GS_DEBUG
static void GSWriteCrumb(NSString *msg) {
    static const char *paths[] = {
        "/var/mobile/Library/Preferences/GroupedSettings17Addon.log",
        "/var/mobile/GroupedSettings17Addon.log",
        "/tmp/GroupedSettings17Addon.log"
    };
    const char *line = [[msg stringByAppendingString:@"\n"] UTF8String];
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { write(fd, line, strlen(line)); close(fd); return; }
    }
}
#define GSLog(fmt, ...) do { \
    NSString *_gsm = [NSString stringWithFormat:@"[GS17] " fmt, ##__VA_ARGS__]; \
    GSWriteCrumb(_gsm); } while (0)
#else
#define GSLog(...) do {} while (0)
#endif

// --- Vérification des signatures ---------------------------------------------

static BOOL GSReturnsBool(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && (rt[0] == 'B' || rt[0] == 'c'));
    free(rt);
    return ok;
}

static BOOL GSReturnsDouble(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && rt[0] == 'd');
    free(rt);
    return ok;
}

static BOOL GSReturnsInsets(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && rt[0] == '{' && strstr(rt, "UIEdgeInsets") != NULL);
    free(rt);
    return ok;
}

static BOOL GSReturnsObject(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && rt[0] == '@');
    free(rt);
    return ok;
}

static BOOL GSHasArgCount(Class cls, SEL sel, unsigned int count) {
    Method m = class_getInstanceMethod(cls, sel);
    return m && method_getNumberOfArguments(m) == count;
}

// --- Préférence "addon.<bundle id>" (défaut : activé) ----------------------------------

static BOOL GSIsEnabledForKey(NSString *key, BOOL defaultValue) {
    CFPreferencesAppSynchronize(GS_DOMAIN);
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, GS_DOMAIN));
    if (value && [value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return defaultValue;
}

// --- Aplatissement -----------------------------------------------------------

static inline BOOL GSInsetsAreZero(NSDirectionalEdgeInsets i) {
    return i.top == 0 && i.leading == 0 && i.bottom == 0 && i.trailing == 0;
}

static UITableView *GSTableViewForView(UIView *view) {
    UIView *v = view.superview;
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    return (UITableView *)v;
}

// Dans Réglages iOS 17 les tables rapportent souvent style=1 (.grouped) avec
// un aspect "inset" venant de _sectionContentInset / _sectionCornerRadius :
// on traite donc .grouped ET .insetGrouped (aplatir une table déjà plate est
// sans effet).
static BOOL GSViewNeedsFlattening(UIView *view) {
    UITableView *table = GSTableViewForView(view);
    return table && (table.style == UITableViewStyleInsetGrouped ||
                     table.style == UITableViewStyleGrouped);
}

static UIBackgroundConfiguration *GSFlatConfiguration(UIBackgroundConfiguration *cfg) {
    if (!cfg) return nil;
    if (cfg.cornerRadius == 0 &&
        GSInsetsAreZero(cfg.backgroundInsets) &&
        cfg.edgesAddingLayoutMarginsToBackgroundInsets == NSDirectionalRectEdgeNone) {
        return cfg; // déjà plat : même instance (idempotent, pas de boucle)
    }
    UIBackgroundConfiguration *flat = [cfg copy];
    flat.cornerRadius = 0;
    flat.backgroundInsets = NSDirectionalEdgeInsetsZero;
    flat.edgesAddingLayoutMarginsToBackgroundInsets = NSDirectionalRectEdgeNone;
    return flat;
}

static void GSFlattenView(UIView *view) {
    if (view && view.layer.cornerRadius != 0) view.layer.cornerRadius = 0;
}

// Défini plus bas (couche E) : aplatit les cartes arrondies quasi pleine largeur.
static BOOL GSFlattenCardTree(UIView *view, UIView *root, CGFloat rootWidth, NSUInteger depth);

// ---------------------------------------------------------------------------
// Marge de texte (couche F)
//
// En passant en pleine largeur (inset de section = 0), le contenu perd la marge
// que la section lui donnait : le texte se retrouve collé au bord gauche. On
// impose donc une marge minimale (directionnelle : OK en RTL ; la zone sûre est
// conservée par UIKit en paysage). On ne fait que RELEVER une marge trop petite.
// Au plus 3 écritures par largeur et par vue : pas de boucle de mise en page
// si UIKit réécrit lui-même ses marges.
// ---------------------------------------------------------------------------
#define GS_TEXT_MARGIN 20.0

static void *kGSMarginStateKey = &kGSMarginStateKey;

static BOOL GSRaiseMargins(UIView *view) {
    if (!view) return NO;
    NSDirectionalEdgeInsets m = view.directionalLayoutMargins;
    if (m.leading >= GS_TEXT_MARGIN - 0.01 && m.trailing >= GS_TEXT_MARGIN - 0.01) return NO;
    m.leading = MAX(m.leading, (CGFloat)GS_TEXT_MARGIN);
    m.trailing = MAX(m.trailing, (CGFloat)GS_TEXT_MARGIN);
    view.directionalLayoutMargins = m;
    return YES;
}

static void GSApplyTextMargins(UIView *owner, UIView *content) {
    if (!owner || !content) return;
    CGFloat w = owner.bounds.size.width;
    if (w <= 0) return;
    NSArray *st = objc_getAssociatedObject(owner, kGSMarginStateKey);
    NSUInteger count = 0;
    if (st.count == 2 && fabs([st[0] doubleValue] - w) < 0.5) count = [st[1] unsignedIntegerValue];
    if (count >= 3) return;
    BOOL changed = GSRaiseMargins(owner);
    if (GSRaiseMargins(content)) changed = YES;
    if (changed) {
        objc_setAssociatedObject(owner, kGSMarginStateKey, @[@(w), @(count + 1)],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Balaie les vues de fond de la cellule, HORS contentView (les icônes et
// contrôles y ont leurs propres rayons) : rayon ~10 pt ou coins partiels.
static void GSFlattenBackgroundTree(UIView *view, UIView *skip, NSUInteger depth) {
    if (depth > 4) return;
    for (UIView *sub in view.subviews) {
        if (sub == skip) continue;
        CGFloat r = sub.layer.cornerRadius;
        if (r != 0) {
            BOOL partial = sub.layer.maskedCorners != (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                                                       kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
            if (fabs(r - GS_INSET_RADIUS) <= 0.25 || partial) sub.layer.cornerRadius = 0;
        }
        GSFlattenBackgroundTree(sub, skip, depth + 1);
    }
}

#if GS_DEBUG
static void GSProbeAppend(NSMutableString *out, UIView *v, NSUInteger depth, NSUInteger maxDepth) {
    if (depth > maxDepth) return;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    [out appendFormat:@"\n%@%@ f=%@ radius=%.1f", pad, NSStringFromClass([v class]),
        NSStringFromCGRect(v.frame), v.layer.cornerRadius];
    for (UIView *sub in v.subviews) GSProbeAppend(out, sub, depth + 1, maxDepth);
}

// Une fois par classe de cellule : hiérarchie de fond (identifie la vue arrondie).
static void GSProbeCell(UITableViewCell *cell) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = NSStringFromClass([cell class]);
    if ([seen containsObject:key] || seen.count > 25 || !cell.window) return;
    [seen addObject:key];
    UITableView *t = GSTableViewForView(cell);
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"CELL %@ table=%@ style=%ld cellFrame=%@ bgCfgRadius=%.1f",
        key, NSStringFromClass([t class]), (long)t.style, NSStringFromCGRect(cell.frame),
        cell.backgroundConfiguration ? cell.backgroundConfiguration.cornerRadius : -1.0];
    GSProbeAppend(out, cell, 0, 3);
    GSLog(@"%@", out);
}
#endif

// Écrit directement les réglages privés de la table (plus fiable que hooker
// leurs lecteurs, que UIKit peut ne pas appeler). Une seule fois par largeur.
static void *kGSTableWidthKey = &kGSTableWidthKey;

static void GSForceTableFlat(UITableView *t) {
    if (!(t.style == UITableViewStyleInsetGrouped || t.style == UITableViewStyleGrouped)) return;
    if (!t.window) return;
    CGFloat w = t.bounds.size.width;
    NSNumber *last = objc_getAssociatedObject(t, kGSTableWidthKey);
    if (last && fabs(last.doubleValue - w) < 0.5) return;
    objc_setAssociatedObject(t, kGSTableWidthKey, @(w), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SEL sFollow = NSSelectorFromString(@"_setSectionContentInsetFollowsLayoutMargins:");
    SEL sInset  = NSSelectorFromString(@"_setSectionContentInset:");
    SEL sRadius = NSSelectorFromString(@"_setSectionCornerRadius:");
    if ([t respondsToSelector:sFollow]) ((void (*)(id, SEL, BOOL))objc_msgSend)(t, sFollow, NO);
    if ([t respondsToSelector:sInset])  ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(t, sInset, UIEdgeInsetsZero);
    if ([t respondsToSelector:sRadius]) ((void (*)(id, SEL, CGFloat))objc_msgSend)(t, sRadius, 0);

#if GS_DEBUG
    SEL sRaw = NSSelectorFromString(@"_rawSectionContentInset");
    UIEdgeInsets raw = [t respondsToSelector:sRaw]
        ? ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(t, sRaw) : UIEdgeInsetsZero;
    id delegate = t.delegate;
    GSLog(@"TABLE %@ style=%ld delegate=%@ frame=%@ rawInset=%@ layoutMargins=%@",
          NSStringFromClass([t class]), (long)t.style,
          delegate ? NSStringFromClass([delegate class]) : @"nil",
          NSStringFromCGRect(t.frame), NSStringFromUIEdgeInsets(raw),
          NSStringFromUIEdgeInsets(t.layoutMargins));
#endif
}

static void GSFlattenCell(UITableViewCell *cell) {
    if (!GSViewNeedsFlattening(cell)) return;

    UIBackgroundConfiguration *cfg = cell.backgroundConfiguration;
    if (cfg) {
        UIBackgroundConfiguration *flat = GSFlatConfiguration(cfg);
        if (flat != cfg) cell.backgroundConfiguration = flat;
    }
    GSFlattenView(cell);
    GSFlattenView(cell.backgroundView);
    GSFlattenView(cell.selectedBackgroundView);
    GSFlattenView(cell.multipleSelectionBackgroundView);
    GSFlattenBackgroundTree(cell, cell.contentView, 0);

    // Carte arrondie posée dans la cellule : carrée, pleine largeur.
    CGFloat w = cell.bounds.size.width;
    if (w > 0) GSFlattenCardTree(cell, cell, w, 0);

    // Le texte ne doit pas coller au bord de l'écran.
    GSApplyTextMargins(cell, cell.contentView);
#if GS_DEBUG
    GSProbeCell(cell);
#endif
}

// ===========================================================================
// COUCHE B : UITableView
// ===========================================================================

%group TableContentInset
%hook UITableView
- (UIEdgeInsets)_sectionContentInset {
    return UIEdgeInsetsZero;
}
%end
%end

%group TableSectionRadius
%hook UITableView
- (CGFloat)_sectionCornerRadius {
    return 0;
}
%end
%end

%group TableForce
%hook UITableView
- (void)layoutSubviews {
    %orig;
    GSForceTableFlat(self);
}
%end
%end

// ===========================================================================
// COUCHE D : listes UICollectionView (listes de Notes)
// Une liste insetGrouped est convertie en grouped (API publique d'UIKit) :
// pleine largeur, sans coins arrondis.
// ===========================================================================

static inline UICollectionLayoutListAppearance GSMapAppearance(UICollectionLayoutListAppearance a) {
    return a == UICollectionLayoutListAppearanceInsetGrouped
        ? UICollectionLayoutListAppearanceGrouped : a;
}

#if GS_DEBUG
static void GSLogAppearanceOnce(const char *tag, long value) {
    static BOOL seen[16];
    if (value < 0 || value > 15) return;
    int idx = (int)value;
    if (seen[idx]) return;
    seen[idx] = YES;
    GSLog(@"LISTCONFIG %s appearance=%ld (2=insetGrouped, 1=grouped, 0=plain)", tag, value);
}
#endif

%group CollectionListInit
%hook UICollectionLayoutListConfiguration
- (instancetype)initWithAppearance:(UICollectionLayoutListAppearance)appearance {
#if GS_DEBUG
    GSLogAppearanceOnce("init", (long)appearance);
#endif
    return %orig(GSMapAppearance(appearance));
}
%end
%end

%group CollectionListSetter
%hook UICollectionLayoutListConfiguration
- (void)setAppearance:(UICollectionLayoutListAppearance)appearance {
#if GS_DEBUG
    GSLogAppearanceOnce("set", (long)appearance);
#endif
    %orig(GSMapAppearance(appearance));
}
%end
%end

#if GS_DEBUG
// Sonde : une fois par classe de UICollectionView, journalise sa mise en page.
%group CollectionProbe
%hook UICollectionView
- (void)didMoveToWindow {
    %orig;
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    if (!self.window) return;
    NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass([self class]),
                     NSStringFromClass([self.collectionViewLayout class])];
    if ([seen containsObject:key] || seen.count > 25) return;
    [seen addObject:key];
    GSLog(@"COLLECTION %@ frame=%@ delegate=%@", key, NSStringFromCGRect(self.frame),
          self.delegate ? NSStringFromClass([(NSObject *)self.delegate class]) : @"nil");
}
%end
%end
#endif

// ===========================================================================
// COUCHE C : UITableViewCell (fond et highlight plats)
// ===========================================================================

%group CellFlatten
%hook UITableViewCell
- (void)setBackgroundConfiguration:(UIBackgroundConfiguration *)configuration {
    if (configuration && GSViewNeedsFlattening(self)) {
        %orig(GSFlatConfiguration(configuration));
        return;
    }
    %orig(configuration);
}

- (void)updateConfigurationUsingState:(UICellConfigurationState *)state {
    %orig;
    GSFlattenCell(self);
}

- (void)layoutSubviews {
    // Marge posée AVANT la mise en page : le texte est placé correctement du 1er coup.
    if (GSViewNeedsFlattening(self)) GSApplyTextMargins(self, self.contentView);
    %orig;
    GSFlattenCell(self);
}
%end
%end

// En-têtes / pieds de section : même marge de texte que les cellules.
%group HeaderFooterMargins
%hook UITableViewHeaderFooterView
- (void)layoutSubviews {
    if (GSViewNeedsFlattening(self)) GSApplyTextMargins(self, self.contentView);
    %orig;
}
%end
%end

// Fond "système" par défaut (porte l'arrondi et le fond de sélection).
%group CellDefaultBackground
%hook UITableViewCell
- (UIBackgroundConfiguration *)defaultBackgroundConfiguration {
    UIBackgroundConfiguration *cfg = %orig;
    return GSViewNeedsFlattening(self) ? GSFlatConfiguration(cfg) : cfg;
}
%end
%end

// ===========================================================================
// COUCHE E : cartes UICollectionView (Santé, Forme)
//
// Ces apps n'utilisent pas des UITableView : leurs grandes cartes vivent dans
// des UICollectionView en "compositional layout". Les marges latérales viennent
// donc (1) des contentInsets des sections / groupes / items du layout,
// (2) de la référence d'inset (marges de mise en page) et (3) du rayon de coin
// des vues de fond des cellules. Les trois sont traités ici, uniquement dans
// ces apps (le reste du tweak est inchangé).
// ===========================================================================

static BOOL GSIsCardApp(void) {
    static BOOL value, done;
    if (!done) {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        value = [bid isEqualToString:@"com.apple.Health"] || [bid isEqualToString:@"com.apple.Fitness"];
        done = YES;
    }
    return value;
}

// Santé / Forme : mode carte d'office. Ailleurs : activé dès qu'une carte arrondie
// pleine largeur est détectée dans une UICollectionView (puis mise en page relancée).
static BOOL gGSCardLayoutActive = YES;   // actif d'emblée : la 1re mise en page est déjà pleine largeur
static inline BOOL GSCardLayoutActive(void) { return gGSCardLayoutActive || GSIsCardApp(); }

static BOOL GSReturnsDirectionalInsets(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && rt[0] == '{' && strstr(rt, "NSDirectionalEdgeInsets") != NULL);
    free(rt);
    return ok;
}

static BOOL GSSetterTakesDirectionalInsets(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 3) return NO;
    char *at = method_copyArgumentType(m, 2);
    BOOL ok = (at && at[0] == '{' && strstr(at, "NSDirectionalEdgeInsets") != NULL);
    free(at);
    return ok;
}

static BOOL GSIsIntegerAccessor(Class cls, SEL sel, BOOL setter) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (setter) {
        if (method_getNumberOfArguments(m) != 3) return NO;
        char *at = method_copyArgumentType(m, 2);
        BOOL ok = (at && (at[0] == 'q' || at[0] == 'l'));
        free(at);
        return ok;
    }
    char *rt = method_copyReturnType(m);
    BOOL ok = (rt && (rt[0] == 'q' || rt[0] == 'l'));
    free(rt);
    return ok;
}

// Marges gauche/droite à zéro (haut/bas conservés : espacement vertical des cartes).
static inline NSDirectionalEdgeInsets GSEdgeToEdge(NSDirectionalEdgeInsets i) {
    i.leading = 0;
    i.trailing = 0;
    return i;
}

// Marges symétriques d'un item/groupe (= marge de la carte) ; les écarts entre
// items voisins sont asymétriques et restent donc intacts.
static inline NSDirectionalEdgeInsets GSEdgeToEdgeIfSymmetric(NSDirectionalEdgeInsets i) {
    if (i.leading > 0 && fabs(i.leading - i.trailing) < 0.01) {
        i.leading = 0;
        i.trailing = 0;
    }
    return i;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
// layoutMargins / readableContent -> safeArea : pleine largeur en portrait,
// mais le contenu reste hors de l'encoche en paysage.
static inline NSInteger GSMapInsetsReference(NSInteger ref) {
    if (ref == (NSInteger)UIContentInsetsReferenceLayoutMargins ||
        ref == (NSInteger)UIContentInsetsReferenceReadableContent) {
        return (NSInteger)UIContentInsetsReferenceSafeArea;
    }
    return ref;
}
#pragma clang diagnostic pop

// Une section n'est mise en pleine largeur que si c'est une vraie liste/carte :
// pas de défilement orthogonal (rails d'apps, carrousels) et un groupe qui
// occupe toute la largeur. Les autres gardent leurs marges d'origine, sinon
// leurs textes et vignettes se collent au bord de l'écran.
static BOOL GSSectionIsFullWidthList(id section) {
    SEL sOrth = NSSelectorFromString(@"orthogonalScrollingBehavior");
    if ([section respondsToSelector:sOrth]) {
        NSInteger b = ((NSInteger (*)(id, SEL))objc_msgSend)(section, sOrth);
        if (b != 0) return NO;
    }
    SEL sGroup = NSSelectorFromString(@"group");
    if ([section respondsToSelector:sGroup]) {
        id g = ((id (*)(id, SEL))objc_msgSend)(section, sGroup);
        if ([g respondsToSelector:@selector(layoutSize)]) {
            NSCollectionLayoutSize *sz = [(NSCollectionLayoutItem *)g layoutSize];
            NSCollectionLayoutDimension *w = sz.widthDimension;
            CGFloat screenW = UIScreen.mainScreen.bounds.size.width;
            // Cartes dimensionnées en points (largeur écran - marges) : pleine largeur.
            if (w.isAbsolute && w.dimension < screenW * 0.7) return NO;
            if (w.isFractionalWidth && w.dimension < 0.8) return NO;
        }
    }
    return YES;
}

static BOOL GSItemIsFullWidth(NSCollectionLayoutItem *item) {
    if ([item isKindOfClass:NSClassFromString(@"NSCollectionLayoutSupplementaryItem")]) return NO;
    NSCollectionLayoutDimension *w = item.layoutSize.widthDimension;
    if (!w) return YES;
    CGFloat screenW = UIScreen.mainScreen.bounds.size.width;
    if (w.isAbsolute) return w.dimension >= screenW * 0.7;
    if (w.isFractionalWidth) return w.dimension >= 0.8;
    return YES;
}

// --- Appartenance item/groupe -> section ------------------------------------------
// Un item ou un groupe ne sait pas dans quelle section il vit. On le retient à la
// création de la section (référence faible, sans cycle) pour distinguer une liste
// verticale (cartes pleine largeur) d'un carrousel (défilement orthogonal), dont
// les écarts et les largeurs ne doivent JAMAIS être modifiés.
static void *kGSOwnerSectionKey  = &kGSOwnerSectionKey;
static void *kGSRootGroupKey     = &kGSRootGroupKey;
static void *kGSSectionTaggedKey = &kGSSectionTaggedKey;

static void GSTagItemTree(id item, id section, NSUInteger depth) {
    if (!item || !section || depth > 6) return;
    __weak id weakSection = section;
    id (^box)(void) = ^id{ return weakSection; };
    objc_setAssociatedObject(item, kGSOwnerSectionKey, box, OBJC_ASSOCIATION_COPY_NONATOMIC);
    SEL sSub = NSSelectorFromString(@"subitems");
    if ([item respondsToSelector:sSub]) {
        id subs = ((id (*)(id, SEL))objc_msgSend)(item, sSub);
        if ([subs isKindOfClass:[NSArray class]]) {
            for (id sub in (NSArray *)subs) GSTagItemTree(sub, section, depth + 1);
        }
    }
}

static void GSTagSection(id section, id group) {
    if (!section || !group) return;
    objc_setAssociatedObject(group, kGSRootGroupKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    GSTagItemTree(group, section, 0);
}

// Rattrapage : si la section a été créée par un autre chemin, on la balise au 1er accès.
static void GSEnsureSectionTagged(id section) {
    if ([objc_getAssociatedObject(section, kGSSectionTaggedKey) boolValue]) return;
    SEL sGroup = NSSelectorFromString(@"group");
    if (![section respondsToSelector:sGroup]) return;
    id g = ((id (*)(id, SEL))objc_msgSend)(section, sGroup);
    if (!g) return;
    objc_setAssociatedObject(section, kGSSectionTaggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    GSTagSection(section, g);
}

static id GSOwnerSection(id item) {
    id (^box)(void) = objc_getAssociatedObject(item, kGSOwnerSectionKey);
    return box ? box() : nil;
}

static BOOL GSSectionIsOrthogonal(id section) {
    SEL sOrth = NSSelectorFromString(@"orthogonalScrollingBehavior");
    if (!section || ![section respondsToSelector:sOrth]) return NO;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(section, sOrth) != 0;
}

static BOOL GSShouldZeroItemInsets(NSCollectionLayoutItem *item) {
    if (!GSCardLayoutActive() || !GSItemIsFullWidth(item)) return NO;
    id sec = GSOwnerSection(item);
    if (sec && GSSectionIsOrthogonal(sec)) return NO;   // carrousel : écarts entre cartes conservés
    return YES;
}

static void *kGSOrigSectionInsetsKey = &kGSOrigSectionInsetsKey;

%group CardSectionInsets
%hook NSCollectionLayoutSection
- (NSDirectionalEdgeInsets)contentInsets {
    NSDirectionalEdgeInsets o = %orig;
    if (!GSCardLayoutActive()) return o;
    GSEnsureSectionTagged(self);
    if (GSSectionIsFullWidthList(self)) return GSEdgeToEdge(o);
    NSValue *orig = objc_getAssociatedObject(self, kGSOrigSectionInsetsKey);
    return orig ? [orig directionalEdgeInsetsValue] : o;   // rail : marges d'origine
}
- (void)setContentInsets:(NSDirectionalEdgeInsets)insets {
    objc_setAssociatedObject(self, kGSOrigSectionInsetsKey,
                             [NSValue valueWithDirectionalEdgeInsets:insets],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig((GSCardLayoutActive() && GSSectionIsFullWidthList(self)) ? GSEdgeToEdge(insets) : insets);
}
%end
%end

%group CardItemInsets
%hook NSCollectionLayoutItem
- (NSDirectionalEdgeInsets)contentInsets {
    NSDirectionalEdgeInsets o = %orig;
    return GSShouldZeroItemInsets(self) ? GSEdgeToEdgeIfSymmetric(o) : o;
}
- (void)setContentInsets:(NSDirectionalEdgeInsets)insets {
    %orig(GSShouldZeroItemInsets(self) ? GSEdgeToEdgeIfSymmetric(insets) : insets);
}
%end
%end

// Groupe racine d'une liste verticale : une carte "carte de 343 pt" ou "90 %" restait
// collée à gauche (marges de section à 0 => carte penchée à gauche, vide à droite).
// On force sa largeur à 100 % AVANT la mise en page : pleine largeur dès la 1re image
// et hauteurs auto-dimensionnées calculées avec la bonne largeur.
%group CardGroupWidth
%hook NSCollectionLayoutItem
- (NSCollectionLayoutSize *)layoutSize {
    NSCollectionLayoutSize *o = %orig;
    if (!o || !GSCardLayoutActive()) return o;
    if (![objc_getAssociatedObject(self, kGSRootGroupKey) boolValue]) return o;
    id sec = GSOwnerSection(self);
    if (!sec || GSSectionIsOrthogonal(sec)) return o;          // carrousel : intact
    NSCollectionLayoutDimension *w = o.widthDimension;
    if (!w) return o;
    CGFloat screenW = UIScreen.mainScreen.bounds.size.width;
    BOOL widen = (w.isAbsolute && w.dimension >= screenW * 0.7) ||
                 (w.isFractionalWidth && w.dimension >= 0.8 && w.dimension < 0.999);
    if (!widen) return o;
    return [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                          heightDimension:o.heightDimension];
}
%end
%end

%group CardSectionTagInit
%hook NSCollectionLayoutSection
- (instancetype)initWithGroup:(id)group {
    id s = %orig;
    GSTagSection(s, group);
    return s;
}
%end
%end

%group CardSectionTagFactory
%hook NSCollectionLayoutSection
+ (instancetype)sectionWithGroup:(id)group {
    id s = %orig;
    GSTagSection(s, group);
    return s;
}
%end
%end

%group CardInsetsReference
%hook NSCollectionLayoutSection
- (NSInteger)contentInsetsReference {
    NSInteger o = %orig;
    GSEnsureSectionTagged(self);
    return (GSCardLayoutActive() && GSSectionIsFullWidthList(self)) ? GSMapInsetsReference(o) : o;
}
- (void)setContentInsetsReference:(NSInteger)ref {
    %orig((GSCardLayoutActive() && GSSectionIsFullWidthList(self)) ? GSMapInsetsReference(ref) : ref);
}
%end
%end

// Rayon des vues "carte" : sous-vues quasi pleine largeur de la cellule avec un
// rayon de carte (6-40 pt). Exclut les capsules (rayon = hauteur/2), les
// contrôles, les icônes et les petites vignettes.
static BOOL GSFlattenCardTree(UIView *view, UIView *root, CGFloat rootWidth, NSUInteger depth) {
    if (depth > 5) return NO;
    BOOL found = NO;
    for (UIView *sub in view.subviews) {
        CGFloat r = sub.layer.cornerRadius;
        if (r >= 4 && r <= 60 && ![sub isKindOfClass:[UIControl class]]) {
            CGRect f = [sub convertRect:sub.bounds toView:root];
            BOOL capsule = r >= sub.bounds.size.height / 2.0 - 0.5;
            if (!capsule && f.size.width >= rootWidth * 0.8) {
                sub.layer.cornerRadius = 0;
                found = YES;
            }
        }
        if (GSFlattenCardTree(sub, root, rootWidth, depth + 1)) found = YES;
    }
    return found;
}

#if GS_DEBUG
// Une fois par classe de cellule : hiérarchie AVANT aplatissement (diagnostic).
static void GSProbeCardCell(UICollectionViewCell *cell) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = NSStringFromClass([cell class]);
    if ([seen containsObject:key] || seen.count > 30 || !cell.window) return;
    [seen addObject:key];
    UIView *cv = cell.superview;
    while (cv && ![cv isKindOfClass:[UICollectionView class]]) cv = cv.superview;
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"CARDCELL %@ frame=%@ collection=%@ bgCfgRadius=%.1f", key,
        NSStringFromCGRect(cell.frame), cv ? NSStringFromCGRect(cv.frame) : @"nil",
        cell.backgroundConfiguration ? cell.backgroundConfiguration.cornerRadius : -1.0];
    GSProbeAppend(out, cell, 0, 4);
    GSLog(@"%@", out);
}
#endif

static UICollectionView *GSCollectionViewForView(UIView *view) {
    UIView *v = view.superview;
    while (v && ![v isKindOfClass:[UICollectionView class]]) v = v.superview;
    return (UICollectionView *)v;
}

// --- Carrousels (défilement latéral type captures d'écran de l'App Store) -------
// Leurs cartes doivent être CARRÉES (coins à 0) mais garder exactement leur taille
// et leur position : l'image 16:9 / format iPhone X ne doit jamais être étirée
// pleine largeur. Ils sont donc exclus de tout élargissement / déplacement /
// réinsertion de marge ; seuls leurs coins sont aplatis.
static BOOL GSLayoutScrollsHorizontally(UICollectionView *cv) {
    if (!cv) return NO;
    UICollectionViewLayout *l = cv.collectionViewLayout;
    if ([l isKindOfClass:[UICollectionViewFlowLayout class]]) {
        return ((UICollectionViewFlowLayout *)l).scrollDirection == UICollectionViewScrollDirectionHorizontal;
    }
    if ([l isKindOfClass:[UICollectionViewCompositionalLayout class]]) {
        return ((UICollectionViewCompositionalLayout *)l).configuration.scrollDirection ==
               UICollectionViewScrollDirectionHorizontal;
    }
    return cv.contentSize.width > cv.bounds.size.width + 1.0;
}

// Cellule dans un défilement orthogonal (un UIScrollView s'intercale entre elle
// et sa collection) ou dans une collection qui défile horizontalement.
static BOOL GSCellIsInRail(UIView *cell, UICollectionView *cv) {
    for (UIView *v = cell.superview; v && v != cv; v = v.superview) {
        if ([v isKindOfClass:[UICollectionView class]]) break;
        if ([v isKindOfClass:[UIScrollView class]]) return YES;
    }
    return GSLayoutScrollsHorizontally(cv);
}

// Une carte de carrousel (et pas une icône, une pastille ou une vignette) :
// assez large par rapport à l'écran de la collection.
static BOOL GSRailCellIsCardSized(UIView *cell, UICollectionView *cv) {
    CGFloat vw = cv ? cv.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    CGSize s = cell.bounds.size;
    if (vw <= 0 || s.width < vw * 0.4 || s.height < 40) return NO;
    CGFloat r = cell.layer.cornerRadius;
    return !(r > 0 && r >= s.height / 2.0 - 0.5);   // pas une capsule
}

// Cellule "pleine ligne" : presque aussi large que la collection et nettement
// moins haute (écarte vignettes, pastilles, icônes de grille et pages plein écran).
static BOOL GSIsFullRowCell(UICollectionViewCell *cell, UICollectionView *cv) {
    if (!cv) return NO;
    CGSize c = cv.bounds.size, s = cell.bounds.size;
    if (c.width <= 0 || s.width <= 0 || s.height <= 0) return NO;
    return s.width >= c.width * 0.7 && s.height <= c.height * 0.8;
}


// --- Contenu hors carte : on lui rend sa marge ---------------------------------
// Les marges de section étant à 0 en mode carte, une cellule qui n'est PAS une
// carte (titre, texte seul, ligne simple) se retrouverait collée au bord : on
// réinsère son contentView. Les médias pleine largeur et les cellules
// configurées via UIContentConfiguration (qui gèrent déjà leurs marges) sont exclus.
static BOOL GSTreeHasFullBleedImage(UIView *view, CGFloat width, NSUInteger depth) {
    if (depth > 3) return NO;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIImageView class]] &&
            sub.bounds.size.width >= width * 0.9 && sub.bounds.size.height > 40) return YES;
        if (GSTreeHasFullBleedImage(sub, width, depth + 1)) return YES;
    }
    return NO;
}

// La vue est-elle collée au bord gauche et quasi pleine largeur dans sa collection ?
static BOOL GSIsFlushFullWidth(UIView *view, UICollectionView *cv) {
    if (!cv) return NO;
    CGRect r = [cv convertRect:view.bounds fromView:view];
    UIEdgeInsets safe = cv.safeAreaInsets;
    CGFloat avail = cv.bounds.size.width - safe.left - safe.right;
    if (avail <= 0 || r.size.width < avail * 0.9) return NO;
    return (r.origin.x - safe.left) < GS_TEXT_MARGIN * 0.5;
}

static void GSInsetPlainCell(UICollectionViewCell *cell, UICollectionView *cv) {
    if (!GSCardLayoutActive() || !cell.window) return;
    if (!GSIsFlushFullWidth(cell, cv)) return;
    if (cell.contentConfiguration != nil || [cell isKindOfClass:[UICollectionViewListCell class]]) {
        GSApplyTextMargins(cell, cell.contentView);   // gèrent leurs marges via layoutMargins
        return;
    }
    UIView *content = cell.contentView;
    if (content.layer.cornerRadius >= 4 || cell.layer.cornerRadius >= 4) return;
    if (GSTreeHasFullBleedImage(content, cell.bounds.size.width, 0)) return;

    // Le fond reste pleine largeur même si le contentView est réduit.
    UIColor *bg = content.backgroundColor;
    if (bg && CGColorGetAlpha(bg.CGColor) > 0.01 && !cell.backgroundView &&
        !cell.backgroundConfiguration && !cell.backgroundColor) {
        cell.backgroundColor = bg;
    }
    CGRect target = CGRectInset(cell.bounds, GS_TEXT_MARGIN, 0);
    if (!CGRectEqualToRect(content.frame, target)) content.frame = target;
}

static void *kGSCardCellKey = &kGSCardCellKey;

static inline BOOL GSCellIsCard(UICollectionViewCell *cell) {
    return GSIsCardApp() || [objc_getAssociatedObject(cell, kGSCardCellKey) boolValue];
}


// --- Cartes : pleine largeur DÈS le premier affichage ---------------------------
// Les attributs de mise en page sont corrigés avant que la cellule soit placée
// (aucun rendu intermédiaire inset/arrondi), quelle que soit la mise en page de
// l'app (compositional, flow ou personnalisée).
static __weak UICollectionView *gGSLastCV = nil;

static BOOL GSCellLevelRounded(UICollectionViewCell *c) {
    UIBackgroundConfiguration *cfg = c.backgroundConfiguration;
    return (cfg && cfg.cornerRadius >= 6) || c.layer.cornerRadius >= 6 ||
           c.contentView.layer.cornerRadius >= 6 || c.backgroundView.layer.cornerRadius >= 6;
}

static BOOL GSCellIsCardCandidate(UICollectionViewCell *c) {
    return GSIsCardApp() || [objc_getAssociatedObject(c, kGSCardCellKey) boolValue] || GSCellLevelRounded(c);
}

// Élargit UNIQUEMENT une rangée verticale dont les marges latérales sont
// symétriques (carte "inset") ou nulles à gauche (carte restée collée à gauche).
// Une carte de carrousel (aperçu de la suivante : marges asymétriques), ou hors du
// cadre visible, n'est jamais touchée : sinon elle se retrouve empilée / décalée.
static CGRect GSWidenedFrame(CGRect f, UICollectionView *cv) {
    if (!cv || GSLayoutScrollsHorizontally(cv)) return f;
    UIEdgeInsets safe = cv.safeAreaInsets;
    CGFloat avail = cv.bounds.size.width - safe.left - safe.right;
    if (avail <= 0 || f.size.width < avail * 0.7) return f;       // pas une ligne/carte pleine largeur
    CGFloat x0 = cv.bounds.origin.x + safe.left;
    CGFloat left  = f.origin.x - x0;
    CGFloat right = (x0 + avail) - CGRectGetMaxX(f);
    CGFloat maxGap = avail * 0.25;
    if (left < -0.5 || right < -0.5 || left > maxGap || right > maxGap) return f;
    if (left < 0.5 && right < 0.5) return f;                      // déjà pleine largeur
    if (left > 0.5 && fabs(left - right) > 1.0) return f;         // asymétrique : carrousel
    f.origin.x = x0;
    f.size.width = avail;
    return f;
}

// Collection à utiliser dans applyLayoutAttributes: ; nil pour une cellule déjà
// placée dans un défilement orthogonal (carrousel : on n'y touche pas).
static UICollectionView *GSCollectionForApply(UICollectionViewCell *cell) {
    UIView *sv = cell.superview;
    if ([sv isKindOfClass:[UICollectionView class]]) return (UICollectionView *)sv;
    if (sv) return nil;
    return gGSLastCV;
}

static void *kGSRailCellKey = &kGSRailCellKey;

static void GSFlattenCellLevel(UICollectionViewCell *c) {
    GSFlattenView(c);
    GSFlattenView(c.contentView);
    GSFlattenView(c.backgroundView);
    GSFlattenView(c.selectedBackgroundView);
    UIBackgroundConfiguration *cfg = c.backgroundConfiguration;
    if (cfg) {
        UIBackgroundConfiguration *flat = GSFlatConfiguration(cfg);
        if (flat != cfg) c.backgroundConfiguration = flat;
    }
}

%group CardCollectionTracker
%hook UICollectionView
- (void)layoutSubviews {
    gGSLastCV = self;
    %orig;
}
%end
%end

// Carte de carrousel : coins carrés, rien d'autre (taille, position, marges et
// contenu restent ceux de l'app).
static void GSSquareRailCell(UICollectionViewCell *cell, UICollectionView *cv) {
    objc_setAssociatedObject(cell, kGSRailCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!GSRailCellIsCardSized(cell, cv)) return;
    GSFlattenCellLevel(cell);
    CGFloat w = cell.bounds.size.width;
    if (w > 0) GSFlattenCardTree(cell, cell, w, 0);
    objc_setAssociatedObject(cell, kGSCardCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // fond plat aussi
}

static void GSFlattenCardCell(UICollectionViewCell *cell) {
    if (!cell.window) return;
    BOOL cardApp = GSIsCardApp();
    UICollectionView *cv = GSCollectionViewForView(cell);
    if (GSCellIsInRail(cell, cv)) { GSSquareRailCell(cell, cv); return; }
    objc_setAssociatedObject(cell, kGSRailCellKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Hors Santé/Forme : seules les cellules pleine ligne sont des cartes candidates.
    if (!cardApp && !GSIsFullRowCell(cell, cv)) { GSInsetPlainCell(cell, cv); return; }
#if GS_DEBUG
    GSProbeCardCell(cell);
#endif
    UIBackgroundConfiguration *cfg = cell.backgroundConfiguration;
    BOOL rounded = (cfg && cfg.cornerRadius >= 6) ||
                   cell.layer.cornerRadius >= 6 ||
                   cell.contentView.layer.cornerRadius >= 6 ||
                   cell.backgroundView.layer.cornerRadius >= 6;
    CGFloat w = cell.bounds.size.width;
    BOOL found = (w > 0) ? GSFlattenCardTree(cell, cell, w, 0) : NO;

    if (!cardApp) {
        if (rounded || found) {
            objc_setAssociatedObject(cell, kGSCardCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (![objc_getAssociatedObject(cell, kGSCardCellKey) boolValue]) {
            // Pleine ligne sans carte arrondie (titre, texte seul) : pas aplatie,
            // mais elle récupère sa marge de texte.
            GSInsetPlainCell(cell, cv);
            return;
        }
        // Première carte arrondie détectée : active le mode carte (marges de
        // section à 0) puis relance la mise en page de cette collection.
        if (!gGSCardLayoutActive) {
            gGSCardLayoutActive = YES;
            GSLog(@"carte arrondie détectée (%@) : mode carte activé", NSStringFromClass([cell class]));
            __weak UICollectionView *weakCV = cv;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakCV.collectionViewLayout invalidateLayout];
            });
        }
    }

    if (cfg) {
        UIBackgroundConfiguration *flat = GSFlatConfiguration(cfg);
        if (flat != cfg) cell.backgroundConfiguration = flat;
    }
    GSFlattenView(cell);
    GSFlattenView(cell.contentView);
    GSFlattenView(cell.backgroundView);
    GSFlattenView(cell.selectedBackgroundView);
    GSApplyTextMargins(cell, cell.contentView);
    // Carte laissée étroite / décalée par la mise en page : pleine largeur.
    if (cv && cell.superview == cv && GSCellIsCard(cell)) {
        CGRect nf = GSWidenedFrame(cell.frame, cv);
        if (!CGRectEqualToRect(nf, cell.frame)) cell.frame = nf;
    }
    // Carte : le contentView occupe toute la cellule (jamais réinséré).
    if (cell.contentView.frame.size.width < cell.bounds.size.width - 0.5 &&
        cell.contentConfiguration == nil && GSCellIsCard(cell)) {
        cell.contentView.frame = cell.bounds;
    }
}

%group CardCells
%hook UICollectionViewCell
- (void)layoutSubviews {
    %orig;
    GSFlattenCardCell(self);
}
- (void)updateConfigurationUsingState:(UICellConfigurationState *)state {
    %orig;
    GSFlattenCardCell(self);
}
- (void)setBackgroundConfiguration:(UIBackgroundConfiguration *)configuration {
    %orig((configuration && GSCellIsCard(self)) ? GSFlatConfiguration(configuration) : configuration);
}
- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)attrs {
    if (attrs) {
        UIView *sv = self.superview;
        UICollectionView *cv = GSCollectionForApply(self);
        BOOL knownRail = [objc_getAssociatedObject(self, kGSRailCellKey) boolValue];
        if (!cv) {
            // Carrousel orthogonal : coins carrés dès la 1re image, mais ni taille ni
            // position modifiées.
            if (sv && GSCellLevelRounded(self) && GSRailCellIsCardSized(self, nil)) GSFlattenCellLevel(self);
        } else if (GSLayoutScrollsHorizontally(cv)) {
            if (GSCellLevelRounded(self) && GSRailCellIsCardSized(self, cv)) GSFlattenCellLevel(self);
        } else if (!knownRail && GSCellIsCardCandidate(self)) {
            CGRect nf = GSWidenedFrame(attrs.frame, cv);
            if (!CGRectEqualToRect(nf, attrs.frame)) {
                UICollectionViewLayoutAttributes *a = [attrs copy];
                a.frame = nf;
                attrs = a;
            }
            GSFlattenCellLevel(self);     // carré dès la 1re image, sans saut visible
        }
    }
    %orig(attrs);
}
// Contenu qui arrive après la 1re mise en page (cellules à contentConfiguration,
// vues hébergées) : quelques passes de rattrapage très rapprochées, pour que l'arrondi
// disparaisse sans délai perceptible. Chaque passe est idempotente.
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    static const double delays[] = {0.0, 0.08, 0.3};
    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        __weak UICollectionViewCell *weakCell = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UICollectionViewCell *c = weakCell;
            if (c && c.window) GSFlattenCardCell(c);
        });
    }
}
%end
%end

%group CardCellDefaultBackground
%hook UICollectionViewCell
- (UIBackgroundConfiguration *)defaultBackgroundConfiguration {
    UIBackgroundConfiguration *cfg = %orig;
    return GSCellIsCard(self) ? GSFlatConfiguration(cfg) : cfg;
}
%end
%end

// En-têtes / pieds de section (vues supplémentaires) : même marge de texte.
%group SupplementaryMargins
%hook UICollectionReusableView
- (void)layoutSubviews {
    if (GSCardLayoutActive() && ![self isKindOfClass:[UICollectionViewCell class]] && self.window) {
        UICollectionView *cv = GSCollectionViewForView(self);
        if (GSIsFlushFullWidth(self, cv) &&
            !GSTreeHasFullBleedImage(self, self.bounds.size.width, 0)) {
            GSApplyTextMargins(self, self);
        }
    }
    %orig;
}
%end
%end

static void GSInstallCardHooks(void) {
    Class section = objc_getClass("NSCollectionLayoutSection");
    Class item    = objc_getClass("NSCollectionLayoutItem");
    Class cell    = objc_getClass("UICollectionViewCell");

    BOOL sectionOK = section &&
        GSReturnsDirectionalInsets(section, NSSelectorFromString(@"contentInsets")) &&
        GSSetterTakesDirectionalInsets(section, NSSelectorFromString(@"setContentInsets:"));
    BOOL itemOK = item &&
        GSReturnsDirectionalInsets(item, NSSelectorFromString(@"contentInsets")) &&
        GSSetterTakesDirectionalInsets(item, NSSelectorFromString(@"setContentInsets:"));
    BOOL refOK = section &&
        GSIsIntegerAccessor(section, NSSelectorFromString(@"contentInsetsReference"), NO) &&
        GSIsIntegerAccessor(section, NSSelectorFromString(@"setContentInsetsReference:"), YES);
    GSLog(@"COUCHE E : section=%d item=%d reference=%d cell=%d", sectionOK, itemOK, refOK, cell != Nil);

    // Balisage item/groupe -> section + largeur de groupe racine à 100 %.
    BOOL tagInit = section && GSHasArgCount(section, NSSelectorFromString(@"initWithGroup:"), 3) &&
                   GSReturnsObject(section, NSSelectorFromString(@"initWithGroup:"));
    BOOL tagFactory = section && class_getClassMethod(section, NSSelectorFromString(@"sectionWithGroup:")) != NULL;
    BOOL sizeOK = item && GSReturnsObject(item, NSSelectorFromString(@"layoutSize"));
    GSLog(@"COUCHE E : tagInit=%d tagFactory=%d groupWidth=%d", tagInit, tagFactory, sizeOK);
    if (tagInit)    { %init(CardSectionTagInit); }
    if (tagFactory) { %init(CardSectionTagFactory); }
    if (sizeOK)     { %init(CardGroupWidth); }

    if (sectionOK) { %init(CardSectionInsets); }
    if (itemOK)    { %init(CardItemInsets); }
    if (refOK)     { %init(CardInsetsReference); }
    if (objc_getClass("UICollectionView")) { %init(CardCollectionTracker); }
    if (objc_getClass("UICollectionReusableView")) { %init(SupplementaryMargins); }
    if (cell) {
        %init(CardCells);
        if (GSReturnsObject(cell, @selector(defaultBackgroundConfiguration))) {
            %init(CardCellDefaultBackground);
        }
    }
}

// ===========================================================================
// Installation
// ===========================================================================

static void GSInstallUIKitHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class tableClass = objc_getClass("UITableView");
        Class cellClass  = objc_getClass("UITableViewCell");

        if (tableClass) {
            if (GSReturnsInsets(tableClass, @selector(_sectionContentInset))) {
                %init(TableContentInset);
            }
            if (GSReturnsDouble(tableClass, @selector(_sectionCornerRadius))) {
                %init(TableSectionRadius);
            }
            %init(TableForce);
        }
        Class listConfig = objc_getClass("UICollectionLayoutListConfiguration");
        BOOL hasInit = listConfig && GSHasArgCount(listConfig, @selector(initWithAppearance:), 3);
        BOOL hasSet  = listConfig && GSHasArgCount(listConfig, @selector(setAppearance:), 3);
        GSLog(@"COUCHE D : classe=%d initWithAppearance:=%d setAppearance:=%d", listConfig != Nil, hasInit, hasSet);
        if (hasInit) { %init(CollectionListInit); }
        if (hasSet)  { %init(CollectionListSetter); }
#if GS_DEBUG
        %init(CollectionProbe);
#endif

        if (cellClass) {
            %init(CellFlatten);
            if (GSReturnsObject(cellClass, @selector(defaultBackgroundConfiguration))) {
                %init(CellDefaultBackground);
            }
        }

        // Cartes en UICollectionView (couche E) : d'office dans Santé / Forme,
        // dans les autres apps seulement quand une carte arrondie est détectée.
        GSInstallCardHooks();

        // En-têtes / pieds de section : marge de texte (couche F).
        if (objc_getClass("UITableViewHeaderFooterView")) { %init(HeaderFooterMargins); }
    });
}

// ===========================================================================
// Apps ciblées (une entrée = un interrupteur dans le panneau GroupedSettings17)
// ===========================================================================

static NSArray<NSArray<NSString *> *> *GSAppleApps(void) {
    // { bundle id, nom EN, nom FR }
    return @[
        @[@"com.apple.tips",              @"Tips",     @"Conseils"],
        @[@"com.apple.MobileAddressBook", @"Contacts", @"Contacts"],
        @[@"com.apple.mobilephone",       @"Phone",    @"Téléphone"],
        @[@"com.apple.mobilesafari",      @"Safari",   @"Safari"],
        @[@"com.apple.DocumentsApp",      @"Files",    @"Fichiers"],
        @[@"com.apple.mobilemail",        @"Mail",     @"Mail"],
        @[@"com.apple.Health",            @"Health",   @"Santé"],
        @[@"com.apple.mobileslideshow",   @"Photos",   @"Photos"],
        @[@"com.apple.camera",            @"Camera",   @"Appareil photo"],
        @[@"com.apple.mobiletimer",       @"Clock",    @"Horloge"],
        @[@"com.apple.Maps",              @"Maps",     @"Plans"],
        @[@"com.apple.weather",           @"Weather",  @"Météo"],
        @[@"com.apple.reminders",         @"Reminders", @"Rappels"],
        @[@"com.apple.Fitness",           @"Fitness",  @"Forme"],
        @[@"com.apple.findmy",            @"Find My",  @"Localiser"],
        @[@"com.apple.Translate",         @"Translate", @"Traduire"],
        @[@"com.apple.freeform",          @"Freeform", @"Freeform"],
        @[@"com.apple.VoiceMemos",        @"Voice Memos", @"Dictaphone"],
        @[@"com.apple.iBooks",            @"Books",    @"Livres"],
        @[@"com.apple.supportapp",        @"Apple Support", @"Assistance"],
        @[@"com.apple.journal",           @"Journal",  @"Journal"],
        @[@"com.apple.Bridge",            @"Watch",    @"Watch"],
        @[@"com.apple.Home",              @"Home",     @"Maison"],
        @[@"com.apple.MobileSMS",         @"Messages", @"Messages"],
        @[@"com.apple.mobilecal",         @"Calendar", @"Calendrier"],
        @[@"com.apple.mobilenotes",       @"Notes",    @"Notes"],
        @[@"com.apple.AppStore",          @"App Store", @"App Store"],
        @[@"com.apple.Passbook",          @"Wallet",   @"Wallet"],
        @[@"com.apple.calculator",        @"Calculator", @"Calculette"],
        @[@"com.apple.compass",           @"Compass",  @"Boussole"],
        @[@"com.apple.measure",           @"Measure",  @"Mesure"],
        @[@"com.apple.shortcuts",         @"Shortcuts", @"Raccourcis"],
        @[@"com.apple.Music",             @"Music",    @"Musique"],
        @[@"com.apple.tv",                @"TV",       @"TV"],
        @[@"com.apple.podcasts",          @"Podcasts", @"Podcasts"],
        @[@"com.apple.facetime",          @"FaceTime", @"FaceTime"],
        @[@"com.apple.stocks",            @"Stocks",   @"Bourse"],
        @[@"com.apple.Magnifier",         @"Magnifier", @"Loupe"],
        @[@"com.apple.MobileStore",       @"iTunes Store", @"iTunes Store"],
        @[@"com.apple.Passwords",         @"Passwords", @"Mots de passe"],
        @[@"com.apple.store.Jolly",       @"Apple Store", @"Apple Store"],
    ];
}

// Apps tierces populaires (désactivées par défaut dans le menu).
static NSArray<NSArray<NSString *> *> *GSThirdPartyApps(void) {
    // { bundle id, nom }
    return @[
        @[@"net.whatsapp.WhatsApp",            @"WhatsApp"],
        @[@"com.burbn.instagram",              @"Instagram"],
        @[@"com.burbn.barcelona",              @"Threads"],
        @[@"com.facebook.Facebook",            @"Facebook"],
        @[@"com.facebook.Messenger",           @"Messenger"],
        @[@"com.zhiliaoapp.musically",         @"TikTok"],
        @[@"com.google.ios.youtube",           @"YouTube"],
        @[@"com.google.Gmail",                 @"Gmail"],
        @[@"com.google.chrome.ios",            @"Chrome"],
        @[@"com.google.Maps",                  @"Google Maps"],
        @[@"com.google.GoogleMobile",          @"Google"],
        @[@"com.google.Drive",                 @"Google Drive"],
        @[@"com.toyopagroup.picaboo",          @"Snapchat"],
        @[@"com.atebits.Tweetie2",             @"X"],
        @[@"ph.telegra.Telegraph",             @"Telegram"],
        @[@"org.whispersystems.signal",        @"Signal"],
        @[@"com.spotify.client",               @"Spotify"],
        @[@"com.netflix.Netflix",              @"Netflix"],
        @[@"com.disney.disneyplus",            @"Disney+"],
        @[@"com.amazon.Amazon",                @"Amazon"],
        @[@"com.hammerandchisel.discord",      @"Discord"],
        @[@"com.reddit.Reddit",                @"Reddit"],
        @[@"com.linkedin.LinkedIn",            @"LinkedIn"],
        @[@"pinterest",                        @"Pinterest"],
        @[@"com.ubercab.UberClient",           @"Uber"],
        @[@"com.waze.iphone",                  @"Waze"],
        @[@"tv.twitch",                        @"Twitch"],
        @[@"org.mozilla.ios.Firefox",          @"Firefox"],
        @[@"com.microsoft.Office.Outlook",     @"Outlook"],
        @[@"com.microsoft.skype.teams",        @"Teams"],
        @[@"com.microsoft.Office.Word",        @"Word"],
        @[@"com.microsoft.Office.Excel",       @"Excel"],
        @[@"us.zoom.videomeetings",            @"Zoom"],
        @[@"com.tinyspeck.chatlyio",           @"Slack"],
        @[@"com.getdropbox.Dropbox",           @"Dropbox"],
        @[@"com.yourcompany.PPClient",         @"PayPal"],
        @[@"com.openai.chat",                  @"ChatGPT"],
        @[@"com.duolingo.DuolingoMobile",      @"Duolingo"],
        @[@"com.airbnb.app",                   @"Airbnb"],
        @[@"com.ubercab.UberEats",             @"Uber Eats"],
        @[@"com.cardify.tinder",               @"Tinder"],
        @[@"com.moxco.bumble",                 @"Bumble"],
        @[@"com.strava.stravaride",            @"Strava"],
        @[@"com.revolut.revolut",              @"Revolut"],
        @[@"com.microsoft.msedge",             @"Edge"],
        @[@"com.deezer.Deezer",                @"Deezer"],
    ];
}

static BOOL GSIsThirdParty(NSString *bundleID) {
    for (NSArray<NSString *> *app in GSThirdPartyApps()) {
        if ([app[0] isEqualToString:bundleID]) return YES;
    }
    return NO;
}

// ---------------------------------------------------------------------------
// Apps RÉELLEMENT installées sur l'appareil
//
// Source unique : LSApplicationWorkspace. On écarte les apps qui ne sont pas
// vraiment utilisables : placeholders (téléchargement en cours), apps déchargées
// ou supprimées (appState non installé), et signale celles cachées par le système.
// Renvoie { bundle id : { @"name" : nom localisé, @"hidden" : BOOL } },
// ou nil si l'API est indisponible (l'appelant ne filtre alors pas, afin
// d'éviter un menu vide).
// ---------------------------------------------------------------------------

static BOOL GSObjectFlag(id obj, NSString *selName, BOOL fallback) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || ![obj respondsToSelector:sel]) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
}

static id GSObjectGet(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static NSDictionary<NSString *, NSDictionary *> *GSInstalledApps(void) {
    NSMutableDictionary<NSString *, NSDictionary *> *result = [NSMutableDictionary dictionary];
    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        id ws = GSObjectGet(wsClass, @"defaultWorkspace");
        id apps = GSObjectGet(ws, @"allInstalledApplications");
        if (![apps isKindOfClass:[NSArray class]]) {
            GSLog(@"apps installées : API indisponible");
            return nil;
        }
        for (id proxy in (NSArray *)apps) {
            @try {   // une app défaillante ne doit pas interrompre toute la détection
                id bid = GSObjectGet(proxy, @"applicationIdentifier");
                if (![bid isKindOfClass:[NSString class]] || ![(NSString *)bid length]) continue;

                // Pas vraiment installée : téléchargement en cours / déchargée / supprimée.
                if (GSObjectFlag(proxy, @"isPlaceholder", NO)) continue;
                id state = GSObjectGet(proxy, @"appState");
                if (state && !GSObjectFlag(state, @"isInstalled", YES)) continue;

                id tags = GSObjectGet(proxy, @"appTags");
                BOOL hidden = [tags isKindOfClass:[NSArray class]] && [(NSArray *)tags containsObject:@"hidden"];

                id name = GSObjectGet(proxy, @"localizedName");
                if (![name isKindOfClass:[NSString class]]) name = @"";

                result[bid] = @{@"name": name, @"hidden": @(hidden)};
            } @catch (NSException *e) {
                GSLog(@"app ignorée : %@", e);
            }
        }
    } @catch (NSException *e) {
        GSLog(@"détection des apps : %@", e);
        return nil;
    }
    if (!result.count) return nil;
    GSLog(@"apps réellement installées : %lu", (unsigned long)result.count);
    return result;
}

// Ne garde d'une liste prédéfinie que les apps réellement installées.
// installed == nil (API indisponible) : liste inchangée.
static NSArray<NSArray<NSString *> *> *GSFilterInstalled(NSArray<NSArray<NSString *> *> *list,
                                                         NSDictionary<NSString *, NSDictionary *> *installed) {
    if (!installed) return list;
    NSMutableArray<NSArray<NSString *> *> *out = [NSMutableArray arrayWithCapacity:list.count];
    for (NSArray<NSString *> *app in list) {
        if (installed[app[0]]) [out addObject:app];
        else GSLog(@"non installée, masquée : %@", app[0]);
    }
    return out;
}

// Apps installées qui ne figurent dans aucune liste.
// { bundle id, nom }, triées par nom ; ignore les apps cachées et Réglages.
static NSArray<NSArray<NSString *> *> *GSDetectOtherApps(NSDictionary<NSString *, NSDictionary *> *installed) {
    if (!installed) return @[];
    NSMutableSet<NSString *> *known = [NSMutableSet setWithObjects:@"com.apple.Preferences", nil];
    for (NSArray<NSString *> *a in GSAppleApps()) [known addObject:a[0]];
    for (NSArray<NSString *> *a in GSThirdPartyApps()) [known addObject:a[0]];
    NSString *own = [[NSBundle mainBundle] bundleIdentifier];
    if (own) [known addObject:own];

    NSMutableArray<NSArray<NSString *> *> *found = [NSMutableArray array];
    [installed enumerateKeysAndObjectsUsingBlock:^(NSString *bid, NSDictionary *info, BOOL *stop) {
        if ([known containsObject:bid] || [info[@"hidden"] boolValue]) return;
        NSString *name = info[@"name"];
        if (!name.length) return;
        [found addObject:@[bid, name]];
    }];
    [found sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [a[1] localizedCaseInsensitiveCompare:b[1]];
    }];
    return found;
}

static NSString *GSAddonKey(NSString *bundleID) {
    return [@"addon." stringByAppendingString:bundleID];
}

// ===========================================================================
// Langues : mêmes 12 langues que GroupedSettings17
// (en, fr, de, it, ru, zh-Hans, zh-Hant, ja, vi, ar, es, pt ; anglais par défaut)
// ===========================================================================

static NSString *GSLanguageCode(void) {
    // Langue du SYSTÈME (et non le réglage de langue propre à l'app) ; si elle
    // n'est pas prise en charge, anglais.
    NSArray *langs = CFBridgingRelease(CFPreferencesCopyValue(CFSTR("AppleLanguages"),
        kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    if (![langs isKindOfClass:[NSArray class]] || !langs.count) langs = [NSLocale preferredLanguages];
    NSString *lang = [langs.firstObject isKindOfClass:[NSString class]] ? langs.firstObject : @"en";
    if ([lang hasPrefix:@"zh"]) {
        BOOL trad = [lang hasPrefix:@"zh-Hant"] || [lang hasPrefix:@"zh-TW"] || [lang hasPrefix:@"zh-HK"] || [lang hasPrefix:@"zh-MO"];
        return trad ? @"zh-Hant" : @"zh-Hans";
    }
    for (NSString *code in @[@"fr", @"de", @"it", @"ru", @"ja", @"vi", @"ar", @"es", @"pt"]) {
        if ([lang hasPrefix:code]) return code;
    }
    return @"en";
}

static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *GSStringTable(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"close": @{
                @"en": @"Close",
                @"fr": @"Fermer",
                @"de": @"Schließen",
                @"it": @"Chiudi",
                @"ru": @"Закрыть",
                @"zh-Hans": @"关闭",
                @"zh-Hant": @"關閉",
                @"ja": @"閉じる",
                @"vi": @"Đóng",
                @"ar": @"إغلاق",
                @"es": @"Cerrar",
                @"pt": @"Fechar",
            },
            @"open_havoc": @{
                @"en": @"Open Havoc",
                @"fr": @"Ouvrir Havoc",
                @"de": @"Havoc öffnen",
                @"it": @"Apri Havoc",
                @"ru": @"Открыть Havoc",
                @"zh-Hans": @"打开 Havoc",
                @"zh-Hant": @"打開 Havoc",
                @"ja": @"Havoc を開く",
                @"vi": @"Mở Havoc",
                @"ar": @"فتح Havoc",
                @"es": @"Abrir Havoc",
                @"pt": @"Abrir Havoc",
            },
            @"open_github": @{
                @"en": @"Open GitHub",
                @"fr": @"Ouvrir GitHub",
                @"de": @"GitHub öffnen",
                @"it": @"Apri GitHub",
                @"ru": @"Открыть GitHub",
                @"zh-Hans": @"打开 GitHub",
                @"zh-Hant": @"打開 GitHub",
                @"ja": @"GitHub を開く",
                @"vi": @"Mở GitHub",
                @"ar": @"فتح GitHub",
                @"es": @"Abrir GitHub",
                @"pt": @"Abrir GitHub",
            },
            @"req_title": @{
                @"en": @"GroupedSettings17 required",
                @"fr": @"GroupedSettings17 requis",
                @"de": @"GroupedSettings17 erforderlich",
                @"it": @"GroupedSettings17 richiesto",
                @"ru": @"Требуется GroupedSettings17",
                @"zh-Hans": @"需要 GroupedSettings17",
                @"zh-Hant": @"需要 GroupedSettings17",
                @"ja": @"GroupedSettings17 が必要です",
                @"vi": @"Cần GroupedSettings17",
                @"ar": @"GroupedSettings17 مطلوب",
                @"es": @"Se requiere GroupedSettings17",
                @"pt": @"GroupedSettings17 necessário",
            },
            @"req_havoc": @{
                @"en": @"GroupedSettings17 Addon for other Apps needs GroupedSettings17. It was found on Havoc: install it, then reopen this app.",
                @"fr": @"GroupedSettings17 Addon for other Apps a besoin de GroupedSettings17. Il est disponible sur Havoc : installe-le, puis rouvre cette app.",
                @"de": @"GroupedSettings17 Addon for other Apps benötigt GroupedSettings17. Es wurde auf Havoc gefunden: Installiere es und öffne diese App danach erneut.",
                @"it": @"GroupedSettings17 Addon for other Apps richiede GroupedSettings17. È disponibile su Havoc: installalo, poi riapri questa app.",
                @"ru": @"GroupedSettings17 Addon for other Apps требуется GroupedSettings17. Он найден в Havoc: установите его и снова откройте это приложение.",
                @"zh-Hans": @"GroupedSettings17 Addon for other Apps 需要 GroupedSettings17。已在 Havoc 上找到它：请安装后重新打开此 App。",
                @"zh-Hant": @"GroupedSettings17 Addon for other Apps 需要 GroupedSettings17。已在 Havoc 找到：請安裝後重新打開此 App。",
                @"ja": @"GroupedSettings17 Addon for other Apps には GroupedSettings17 が必要です。Havoc で見つかりました。インストールしてから、このAppを開き直してください。",
                @"vi": @"GroupedSettings17 Addon for other Apps cần GroupedSettings17. Đã tìm thấy trên Havoc: hãy cài đặt rồi mở lại ứng dụng này.",
                @"ar": @"تحتاج GroupedSettings17 Addon for other Apps إلى GroupedSettings17. تم العثور عليه على Havoc: ثبّته ثم أعد فتح هذا التطبيق.",
                @"es": @"GroupedSettings17 Addon for other Apps necesita GroupedSettings17. Se encontró en Havoc: instálalo y vuelve a abrir esta app.",
                @"pt": @"GroupedSettings17 Addon for other Apps precisa do GroupedSettings17. Foi encontrado no Havoc: instale-o e volte a abrir esta app.",
            },
            @"err_title": @{
                @"en": @"Error: GroupedSettings17 missing",
                @"fr": @"Erreur : GroupedSettings17 manquant",
                @"de": @"Fehler: GroupedSettings17 fehlt",
                @"it": @"Errore: GroupedSettings17 mancante",
                @"ru": @"Ошибка: GroupedSettings17 не установлен",
                @"zh-Hans": @"错误：未安装 GroupedSettings17",
                @"zh-Hant": @"錯誤：未安裝 GroupedSettings17",
                @"ja": @"エラー：GroupedSettings17 がありません",
                @"vi": @"Lỗi: thiếu GroupedSettings17",
                @"ar": @"خطأ: GroupedSettings17 غير مثبّت",
                @"es": @"Error: falta GroupedSettings17",
                @"pt": @"Erro: falta o GroupedSettings17",
            },
            @"err_msg": @{
                @"en": @"GroupedSettings17 Addon for other Apps needs GroupedSettings17, which was not found on Havoc. Please install GroupedSettings17 from %@",
                @"fr": @"GroupedSettings17 Addon for other Apps a besoin de GroupedSettings17, introuvable sur Havoc. Installe GroupedSettings17 depuis %@",
                @"de": @"GroupedSettings17 Addon for other Apps benötigt GroupedSettings17, das auf Havoc nicht gefunden wurde. Bitte installiere GroupedSettings17 von %@",
                @"it": @"GroupedSettings17 Addon for other Apps richiede GroupedSettings17, non trovato su Havoc. Installa GroupedSettings17 da %@",
                @"ru": @"GroupedSettings17 Addon for other Apps требуется GroupedSettings17, который не найден в Havoc. Установите GroupedSettings17 отсюда: %@",
                @"zh-Hans": @"GroupedSettings17 Addon for other Apps 需要 GroupedSettings17，但在 Havoc 上未找到。请从以下地址安装 GroupedSettings17：%@",
                @"zh-Hant": @"GroupedSettings17 Addon for other Apps 需要 GroupedSettings17，但在 Havoc 找不到。請從以下網址安裝 GroupedSettings17：%@",
                @"ja": @"GroupedSettings17 Addon for other Apps には GroupedSettings17 が必要ですが、Havoc で見つかりませんでした。次のURLから GroupedSettings17 をインストールしてください：%@",
                @"vi": @"GroupedSettings17 Addon for other Apps cần GroupedSettings17 nhưng không tìm thấy trên Havoc. Vui lòng cài GroupedSettings17 từ %@",
                @"ar": @"تحتاج GroupedSettings17 Addon for other Apps إلى GroupedSettings17 الذي لم يُعثر عليه على Havoc. يرجى تثبيت GroupedSettings17 من %@",
                @"es": @"GroupedSettings17 Addon for other Apps necesita GroupedSettings17, que no se encontró en Havoc. Instala GroupedSettings17 desde %@",
                @"pt": @"GroupedSettings17 Addon for other Apps precisa do GroupedSettings17, que não foi encontrado no Havoc. Instale o GroupedSettings17 a partir de %@",
            },
            @"top_note": @{
                @"en": @"The top switch is only for Settings. Apps are set in the menus below.",
                @"fr": @"L'interrupteur du haut ne concerne que Réglages. Les apps se règlent dans les menus ci-dessous.",
                @"de": @"Der obere Schalter gilt nur für Einstellungen. Die Apps werden in den Menüs darunter eingestellt.",
                @"it": @"L'interruttore in alto riguarda solo Impostazioni. Le app si regolano nei menu qui sotto.",
                @"ru": @"Верхний переключатель относится только к «Настройкам». Приложения настраиваются в меню ниже.",
                @"zh-Hans": @"顶部开关仅适用于“设置”。各个 App 请在下方菜单中设置。",
                @"zh-Hant": @"頂部開關僅適用於「設定」。各個 App 請在下方選單中設定。",
                @"ja": @"上のスイッチは「設定」アプリ専用です。ほかのAppは下のメニューで設定します。",
                @"vi": @"Công tắc ở trên cùng chỉ dành cho Cài đặt. Các ứng dụng được thiết lập trong các menu bên dưới.",
                @"ar": @"المفتاح العلوي مخصص للإعدادات فقط. يتم ضبط التطبيقات من القوائم أدناه.",
                @"es": @"El interruptor superior solo afecta a Ajustes. Las apps se configuran en los menús de abajo.",
                @"pt": @"O interruptor superior é apenas para Ajustes. As apps são configuradas nos menus abaixo.",
            },
            @"group_title": @{
                @"en": @"Other Apps",
                @"fr": @"Autres applications",
                @"de": @"Weitere Apps",
                @"it": @"Altre app",
                @"ru": @"Другие приложения",
                @"zh-Hans": @"其他 App",
                @"zh-Hant": @"其他 App",
                @"ja": @"その他のApp",
                @"vi": @"Ứng dụng khác",
                @"ar": @"تطبيقات أخرى",
                @"es": @"Otras apps",
                @"pt": @"Outras apps",
            },
            @"menu_apple": @{
                @"en": @"Preinstalled Apps",
                @"fr": @"Apps préinstallées",
                @"de": @"Vorinstallierte Apps",
                @"it": @"App preinstallate",
                @"ru": @"Предустановленные приложения",
                @"zh-Hans": @"预装 App",
                @"zh-Hant": @"預載 App",
                @"ja": @"プリインストールApp",
                @"vi": @"Ứng dụng cài sẵn",
                @"ar": @"التطبيقات المثبتة مسبقًا",
                @"es": @"Apps preinstaladas",
                @"pt": @"Apps pré-instaladas",
            },
            @"menu_third": @{
                @"en": @"Third-Party Apps",
                @"fr": @"Apps tierces",
                @"de": @"Apps von Drittanbietern",
                @"it": @"App di terze parti",
                @"ru": @"Сторонние приложения",
                @"zh-Hans": @"第三方 App",
                @"zh-Hant": @"第三方 App",
                @"ja": @"サードパーティApp",
                @"vi": @"Ứng dụng bên thứ ba",
                @"ar": @"تطبيقات الجهات الخارجية",
                @"es": @"Apps de terceros",
                @"pt": @"Apps de terceiros",
            },
            @"footer_apple": @{
                @"en": @"Apple apps. Close and reopen an app after a change.",
                @"fr": @"Apps Apple. Ferme puis rouvre l'app après un changement.",
                @"de": @"Apple-Apps. Nach einer Änderung die App schließen und erneut öffnen.",
                @"it": @"App Apple. Dopo una modifica, chiudi e riapri l'app.",
                @"ru": @"Приложения Apple. После изменения закройте и снова откройте приложение.",
                @"zh-Hans": @"Apple App。更改后请关闭并重新打开对应 App。",
                @"zh-Hant": @"Apple App。變更後請關閉並重新打開對應 App。",
                @"ja": @"Apple純正App。変更後はAppを終了してからもう一度開いてください。",
                @"vi": @"Ứng dụng của Apple. Sau khi thay đổi, hãy đóng rồi mở lại ứng dụng.",
                @"ar": @"تطبيقات Apple. بعد أي تغيير، أغلق التطبيق ثم افتحه من جديد.",
                @"es": @"Apps de Apple. Tras un cambio, cierra y vuelve a abrir la app.",
                @"pt": @"Apps da Apple. Após uma alteração, feche e reabra a app.",
            },
            @"footer_third": @{
                @"en": @"Third-party apps, popular ones and those detected on this device, off by default. Close and reopen an app after a change.",
                @"fr": @"Apps tierces, populaires et détectées sur cet appareil, désactivées par défaut. Ferme puis rouvre l'app après un changement.",
                @"de": @"Apps von Drittanbietern, beliebte und auf diesem Gerät gefundene, standardmäßig aus. Nach einer Änderung die App schließen und erneut öffnen.",
                @"it": @"App di terze parti, popolari e rilevate su questo dispositivo, disattivate per impostazione predefinita. Dopo una modifica, chiudi e riapri l'app.",
                @"ru": @"Сторонние приложения — популярные и найденные на этом устройстве, по умолчанию выключены. После изменения закройте и снова откройте приложение.",
                @"zh-Hans": @"第三方 App（热门及在此设备上检测到的），默认关闭。更改后请关闭并重新打开对应 App。",
                @"zh-Hant": @"第三方 App（熱門及在此裝置上偵測到的），預設為關閉。變更後請關閉並重新打開對應 App。",
                @"ja": @"サードパーティApp（人気のものと、このデバイスで検出されたもの）。初期設定ではオフ。変更後はAppを終了してからもう一度開いてください。",
                @"vi": @"Ứng dụng bên thứ ba, phổ biến và được phát hiện trên thiết bị này, mặc định tắt. Sau khi thay đổi, hãy đóng rồi mở lại ứng dụng.",
                @"ar": @"تطبيقات الجهات الخارجية، الشائعة والمكتشفة على هذا الجهاز، متوقفة افتراضيًا. بعد أي تغيير، أغلق التطبيق ثم افتحه من جديد.",
                @"es": @"Apps de terceros, populares y detectadas en este dispositivo, desactivadas por defecto. Tras un cambio, cierra y vuelve a abrir la app.",
                @"pt": @"Apps de terceiros, populares e detetadas neste dispositivo, desativadas por predefinição. Após uma alteração, feche e reabra a app.",
            },
        };
    });
    return table;
}

static NSString *GSS(NSString *key) {
    NSDictionary *row = GSStringTable()[key];
    return row[GSLanguageCode()] ?: row[@"en"] ?: key;
}

// Nom d'app localisé par le système (suit toutes les langues) ; anglais en secours.
static NSString *GSAppName(NSString *bundleID, NSString *fallback) {
    Class proxy = NSClassFromString(@"LSApplicationProxy");
    SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxy && [proxy respondsToSelector:sel]) {
        id p = ((id (*)(id, SEL, id))objc_msgSend)(proxy, sel, bundleID);
        SEL nameSel = NSSelectorFromString(@"localizedName");
        if (p && [p respondsToSelector:nameSel]) {
            id n = ((id (*)(id, SEL))objc_msgSend)(p, nameSel);
            if ([n isKindOfClass:[NSString class]] && [n length] && ![n isEqualToString:bundleID]) return n;
        }
    }
    return fallback;
}

// ===========================================================================
// Dépendance : GroupedSettings17 doit être installé
// ===========================================================================

// Ne conclut "absent" que si TOUS les chemins répondent ENOENT : un refus du
// bac à sable (EPERM/EACCES) n'est pas une preuve d'absence.
static BOOL GSDependencyMissing(void) {
    static const char *paths[] = {
        "/var/jb/Library/MobileSubstrate/DynamicLibraries/GroupedSettings17.dylib",
        "/var/jb/Library/PreferenceBundles/GroupedSettings17Prefs.bundle",
        "/Library/MobileSubstrate/DynamicLibraries/GroupedSettings17.dylib",
        "/Library/PreferenceBundles/GroupedSettings17Prefs.bundle",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (access(paths[i], F_OK) == 0) return NO;
        if (errno != ENOENT) return NO;
    }
    return YES;
}

static UIViewController *GSTopViewController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        window = ws.keyWindow ?: ws.windows.firstObject;
        if (window) break;
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void GSPresentAlert(NSString *title, NSString *message, NSString *openTitle, NSString *url) {
    UIViewController *top = GSTopViewController();
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:openTitle
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        NSURL *u = [NSURL URLWithString:url];
        if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:GSS(@"close")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

// GroupedSettings17 absent : cherche d'abord sur Havoc ; sinon erreur vers le GitHub.
static void GSHandleMissingDependency(void) {
    GSLog(@"GroupedSettings17 absent : recherche sur Havoc");
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:GS_HAVOC_URL]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:8];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        BOOL onHavoc = (!err && code == 200 && data.length > 0);
        GSLog(@"Havoc : code=%ld trouvé=%d", (long)code, onHavoc);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (onHavoc) {
                GSPresentAlert(
                    GSS(@"req_title"),
                    GSS(@"req_havoc"),
                    GSS(@"open_havoc"), GS_HAVOC_URL);
            } else {
                GSPresentAlert(
                    GSS(@"err_title"),
                    [NSString stringWithFormat:GSS(@"err_msg"), GS_GITHUB_URL],
                    GSS(@"open_github"), GS_GITHUB_URL);
            }
        });
    }] resume];
}

static void GSScheduleMissingDependencyAlert(void) {
    __block id token = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ GSHandleMissingDependency(); });
    }];
}

// ===========================================================================
// Menu : interrupteurs par app ajoutés dans le panneau GroupedSettings17
// (pas de menu propre à l'addon)
// ===========================================================================

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get
                                  detail:(Class)detail cell:(NSInteger)cell edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

@interface GSPRootListController : UIViewController
- (NSArray *)specifiers;
@end

// Menu "Apps tierces" : apps populaires RÉELLEMENT installées + toutes les
// autres apps installées détectées automatiquement, triées par nom.
static NSArray<NSArray<NSString *> *> *GSAllThirdPartyApps(NSDictionary<NSString *, NSDictionary *> *installed) {
    NSMutableArray<NSArray<NSString *> *> *all = [NSMutableArray array];
    for (NSArray<NSString *> *a in GSFilterInstalled(GSThirdPartyApps(), installed)) {
        [all addObject:@[a[0], GSAppName(a[0], a[1])]];
    }
    [all addObjectsFromArray:GSDetectOtherApps(installed)];
    [all sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [a[1] localizedCaseInsensitiveCompare:b[1]];
    }];
    return all;
}

#define GS_LIST_KEY @"GSAddonList"   // propriété du lien : "apple" ou "third"

// Groupe + un interrupteur par app (sert aux deux sous-menus).
static NSArray *GSBuildAppSpecifiers(id target, NSArray<NSArray<NSString *> *> *apps,
                                     BOOL defaultOn, NSString *footer) {
    Class specClass = NSClassFromString(@"PSSpecifier");
    if (!specClass) return @[];
    NSMutableArray *out = [NSMutableArray array];
    PSSpecifier *group = [specClass groupSpecifierWithName:nil];
    [group setProperty:footer forKey:@"footerText"];
    [out addObject:group];
    for (NSArray<NSString *> *app in apps) {
        NSString *name = GSAppName(app[0], app[1]);
        PSSpecifier *sw = [specClass preferenceSpecifierNamed:name
                                                       target:target
                                                          set:@selector(setPreferenceValue:specifier:)
                                                          get:@selector(readPreferenceValue:)
                                                       detail:Nil
                                                         cell:6 /* PSSwitchCell */
                                                         edit:Nil];
        [sw setProperty:@"com.raphetsoso.groupedsettings17" forKey:@"defaults"];
        [sw setProperty:GSAddonKey(app[0]) forKey:@"key"];
        [sw setProperty:@(defaultOn) forKey:@"default"];
        [sw setProperty:name forKey:@"label"];
        [out addObject:sw];
    }
    return out;
}

// Contrôleur des sous-menus, créé à l'exécution (PSListController vit dans
// Preferences.framework : pas de dépendance à l'édition de liens).
static Class GSAddonListClass(void) {
    Class c = objc_getClass("GSAddonListController");
    if (c) return c;
    Class sup = NSClassFromString(@"PSListController");
    if (!sup) return Nil;
    c = objc_allocateClassPair(sup, "GSAddonListController", 0);
    if (!c) return Nil;

    IMP imp = imp_implementationWithBlock(^NSArray *(id me) {
        NSArray *cached = [me valueForKey:@"_specifiers"];
        if (cached) return cached;
        id spec = [me valueForKey:@"specifier"];
        id kind = [(PSSpecifier *)spec propertyForKey:GS_LIST_KEY];
        BOOL third = [kind isEqual:@"third"];
        // Liste recalculée à chaque ouverture du sous-menu : seules les apps
        // réellement installées à cet instant sont proposées.
        NSDictionary *installed = GSInstalledApps();
        NSArray *specs = GSBuildAppSpecifiers(
            me,
            third ? GSAllThirdPartyApps(installed) : GSFilterInstalled(GSAppleApps(), installed),
            !third,
            GSS(third ? @"footer_third" : @"footer_apple"));
        [me setValue:specs forKey:@"_specifiers"];
        return specs;
    });
    class_addMethod(c, @selector(specifiers), imp, "@@:");
    objc_registerClassPair(c);
    return c;
}

%group PrefsMenu
%hook GSPRootListController
- (NSArray *)specifiers {
    NSArray *orig = %orig;
    if (!orig.count) return orig;
    for (PSSpecifier *s in orig) {
        id key = [s propertyForKey:@"GSAddonMarker"];
        if (key) return orig; // déjà ajouté
    }
    Class specClass = NSClassFromString(@"PSSpecifier");
    Class listClass = GSAddonListClass();
    if (!specClass || !listClass) return orig;

    // Précise que l'interrupteur du haut ne concerne que Réglages.
    PSSpecifier *first = orig.firstObject;
    id oldFooter = [first propertyForKey:@"footerText"];
    NSString *note = GSS(@"top_note");
    NSString *footer = ([oldFooter isKindOfClass:[NSString class]] && [(NSString *)oldFooter length])
        ? [NSString stringWithFormat:@"%@\n\n%@", oldFooter, note] : note;
    [first setProperty:footer forKey:@"footerText"];

    // Deux sous-menus.
    NSMutableArray *extra = [NSMutableArray array];
    PSSpecifier *group = [specClass groupSpecifierWithName:GSS(@"group_title")];
    [group setProperty:@YES forKey:@"GSAddonMarker"];
    [extra addObject:group];

    NSArray *kinds = @[@[@"apple", GSS(@"menu_apple")],
                       @[@"third", GSS(@"menu_third")]];
    for (NSArray<NSString *> *k in kinds) {
        PSSpecifier *link = [specClass preferenceSpecifierNamed:k[1]
                                                         target:self
                                                            set:Nil
                                                            get:Nil
                                                         detail:listClass
                                                           cell:1 /* PSLinkCell */
                                                           edit:Nil];
        [link setProperty:k[0] forKey:GS_LIST_KEY];
        [extra addObject:link];
    }

    // Après l'interrupteur principal, avant le groupe du bouton Respring.
    NSMutableArray *all = [orig mutableCopy];
    NSUInteger idx = all.count >= 3 ? 2 : all.count;
    [all insertObjects:extra atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(idx, extra.count)]];
    [self setValue:all forKey:@"_specifiers"];
    return all;
}
%end
%end

static BOOL GSInstallPrefsMenu(void) {
    static BOOL installed = NO;
    if (installed) return YES;
    Class cls = objc_getClass("GSPRootListController");
    if (!cls) return NO;
    installed = YES;
    %init(PrefsMenu, GSPRootListController = cls);
    GSLog(@"menu GroupedSettings17 : sous-menus ajoutés");
    return YES;
}

// ===========================================================================
// Point d'entrée
// ===========================================================================

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;

        // Réglages : seulement l'ajout des interrupteurs dans le panneau GroupedSettings17.
        if ([bid isEqualToString:@"com.apple.Preferences"]) {
            if (!GSInstallPrefsMenu()) {
                // Le bundle de préférences est chargé à l'ouverture du panneau.
                [[NSNotificationCenter defaultCenter]
                    addObserverForName:NSBundleDidLoadNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                    GSInstallPrefsMenu();
                }];
            }
            return;
        }

        // Apps connues (listes) : alerte si GroupedSettings17 manque.
        BOOL known = GSIsThirdParty(bid);
        for (NSArray<NSString *> *app in GSAppleApps()) {
            if ([app[0] isEqualToString:bid]) { known = YES; break; }
        }
        if (known) {
            if (GSDependencyMissing()) {
                GSScheduleMissingDependencyAlert();
                return;
            }
            if (!GSIsEnabledForKey(GSAddonKey(bid), !GSIsThirdParty(bid))) return;
        } else {
            // App détectée automatiquement : active seulement si son interrupteur
            // a été mis (défaut : désactivé). Sans alerte si GroupedSettings17 manque.
            if (!GSIsEnabledForKey(GSAddonKey(bid), NO)) return;
            if (GSDependencyMissing()) return;
        }

        GSLog(@"charge dans %@ (iOS %@)", bid, [[UIDevice currentDevice] systemVersion]);
        GSInstallUIKitHooks();
    }
}
