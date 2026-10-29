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
// Freeform, Dictaphone, Livres.
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

static BOOL GSIsEnabledForKey(NSString *key) {
    CFPreferencesAppSynchronize(GS_DOMAIN);
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, GS_DOMAIN));
    if (value && [value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return YES;
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
    %orig;
    GSFlattenCell(self);
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
    });
}

// ===========================================================================
// Apps ciblées (une entrée = un interrupteur dans le panneau GroupedSettings17)
// ===========================================================================

static NSArray<NSArray<NSString *> *> *GSAddonApps(void) {
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
    ];
}

static NSString *GSAddonKey(NSString *bundleID) {
    return [@"addon." stringByAppendingString:bundleID];
}

static BOOL GSIsFrench(void) {
    NSString *lang = [NSLocale preferredLanguages].firstObject;
    return [lang hasPrefix:@"fr"];
}

static NSString *GSL(NSString *en, NSString *fr) {
    return GSIsFrench() ? fr : en;
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
    [alert addAction:[UIAlertAction actionWithTitle:GSL(@"Close", @"Fermer")
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
                    GSL(@"GroupedSettings17 required", @"GroupedSettings17 requis"),
                    GSL(@"GroupedSettings17 Addon for other Apps needs GroupedSettings17. It was found on Havoc: install it, then reopen this app.",
                        @"GroupedSettings17 Addon for other Apps a besoin de GroupedSettings17. Il est disponible sur Havoc : installe-le, puis rouvre cette app."),
                    GSL(@"Open Havoc", @"Ouvrir Havoc"), GS_HAVOC_URL);
            } else {
                GSPresentAlert(
                    GSL(@"Error: GroupedSettings17 missing", @"Erreur : GroupedSettings17 manquant"),
                    [NSString stringWithFormat:GSL(
                        @"GroupedSettings17 Addon for other Apps needs GroupedSettings17, which was not found on Havoc. Please install GroupedSettings17 from %@",
                        @"GroupedSettings17 Addon for other Apps a besoin de GroupedSettings17, introuvable sur Havoc. Installe GroupedSettings17 depuis %@"),
                        GS_GITHUB_URL],
                    GSL(@"Open GitHub", @"Ouvrir GitHub"), GS_GITHUB_URL);
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

%group PrefsMenu
%hook GSPRootListController
- (NSArray *)specifiers {
    NSArray *orig = %orig;
    if (!orig.count) return orig;
    for (PSSpecifier *s in orig) {
        id key = [s propertyForKey:@"key"];
        if ([key isKindOfClass:[NSString class]] && [(NSString *)key hasPrefix:@"addon."]) return orig; // déjà ajouté
    }
    Class specClass = NSClassFromString(@"PSSpecifier");
    if (!specClass) return orig;

    NSMutableArray *extra = [NSMutableArray array];
    PSSpecifier *group = [specClass groupSpecifierWithName:GSL(@"Other Apps", @"Autres applications")];
    [group setProperty:GSL(@"Enable or disable the edge-to-edge style for each app. Close and reopen the app after a change.",
                           @"Active ou désactive le style bord à bord pour chaque app. Ferme puis rouvre l'app après un changement.")
                forKey:@"footerText"];
    [extra addObject:group];

    for (NSArray<NSString *> *app in GSAddonApps()) {
        PSSpecifier *sw = [specClass preferenceSpecifierNamed:GSIsFrench() ? app[2] : app[1]
                                                       target:self
                                                          set:@selector(setPreferenceValue:specifier:)
                                                          get:@selector(readPreferenceValue:)
                                                       detail:Nil
                                                         cell:6 /* PSSwitchCell */
                                                         edit:Nil];
        [sw setProperty:@"com.raphetsoso.groupedsettings17" forKey:@"defaults"];
        [sw setProperty:GSAddonKey(app[0]) forKey:@"key"];
        [sw setProperty:@YES forKey:@"default"];
        [sw setProperty:GSIsFrench() ? app[2] : app[1] forKey:@"label"];
        [extra addObject:sw];
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
    GSLog(@"menu GroupedSettings17 : interrupteurs ajoutés");
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

        // Apps ciblées.
        BOOL targeted = NO;
        for (NSArray<NSString *> *app in GSAddonApps()) {
            if ([app[0] isEqualToString:bid]) { targeted = YES; break; }
        }
        if (!targeted) return;

        if (GSDependencyMissing()) {
            GSScheduleMissingDependencyAlert();
            return;
        }
        if (!GSIsEnabledForKey(GSAddonKey(bid))) return;

        GSLog(@"charge dans %@ (iOS %@)", bid, [[UIDevice currentDevice] systemVersion]);
        GSInstallUIKitHooks();
    }
}
