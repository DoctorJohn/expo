#import "EXBuildConstants.h"
#import "EXEnvironment.h"
#import "EXErrorRecoveryManager.h"
#import "EXKernel.h"
#import "EXAbstractLoader.h"
#import "EXKernelLinkingManager.h"
#import "EXKernelServiceRegistry.h"
#import "EXKernelUtil.h"
#import "EXLog.h"
#import "ExpoKit.h"
#import "EXReactAppManager.h"
#import "EXReactAppManager+Private.h"
#import "EXVersionManagerObjC.h"
#import "EXVersions.h"
#import "EXAppViewController.h"
#import <ExpoModulesCore/EXModuleRegistryProvider.h>
#import <EXConstants/EXConstantsService.h>
#import <ReactCommon/RCTTurboModuleManager.h>

// When `use_frameworks!` is used, the generated Swift header is inside modules.
// Otherwise, it's available only locally with double-quoted imports.
#if __has_include(<EXManifests/EXManifests-Swift.h>)
#import <EXManifests/EXManifests-Swift.h>
#else
#import "EXManifests-Swift.h"
#endif

#import <React/RCTBridge.h>
#import <React/RCTRootView.h>

#import "Expo_Go-Swift.h"

NSString *const RCTInstanceDidLoadBundle = @"RCTInstanceDidLoadBundle";

@implementation RCTSource (EXReactAppManager)

- (instancetype)initWithURL:(nonnull NSURL *)url data:(nonnull NSData *)data
{
  if (self = [super init]) {
    // Use KVO since RN publicly declares these properties as readonly and privately defines the
    // ivars
    [self setValue:url forKey:@"url"];
    [self setValue:data forKey:@"data"];
    [self setValue:@(data.length) forKey:@"length"];
    [self setValue:@(RCTSourceFilesChangedCountNotBuiltByBundler) forKey:@"filesChangedCount"];
  }
  return self;
}

@end

@interface EXReactAppManager ()

@property (nonatomic, strong) UIView * __nullable reactRootView;
@property (nonatomic, copy) RCTSourceLoadBlock loadCallback;
@property (nonatomic, strong) NSDictionary *initialProps;
@property (nonatomic, strong) NSTimer *viewTestTimer;

@end

@implementation EXReactAppManager

- (instancetype)initWithAppRecord:(EXKernelAppRecord *)record initialProps:(NSDictionary *)initialProps
{
  if (self = [super init]) {
    _appRecord = record;
    _initialProps = initialProps;
    _isHeadless = NO;
    _exceptionHandler = [[EXReactAppExceptionHandler alloc] initWithAppRecord:_appRecord];
    RCTRegisterReloadCommandListener(self);
  }
  return self;
}

- (id)reactHost {
  return _expoAppInstance.reactNativeFactory.rootViewFactory.reactHost;
}

- (void)setAppRecord:(EXKernelAppRecord *)appRecord
{
  _appRecord = appRecord;
  _exceptionHandler = [[EXReactAppExceptionHandler alloc] initWithAppRecord:appRecord];
}

- (EXReactAppManagerStatus)status
{
  if (!_appRecord) {
    return kEXReactAppManagerStatusError;
  }
  if (_loadCallback) {
    return kEXReactAppManagerStatusBridgeLoading;
  }
  if (_isReactHostRunning) {
    return kEXReactAppManagerStatusRunning;
  }
  return kEXReactAppManagerStatusNew;
}

- (UIView *)rootView
{
  return _reactRootView;
}

- (void)rebuildHost
{
  EXAssertMainThread();
  NSAssert((_delegate != nil), @"Cannot init react app without EXReactAppManagerDelegate");

  [self _invalidateAndClearDelegate:NO];

  // Assert early so we can catch the error before instantiating the RCTHost, otherwise we would be passing a
  // nullish scope key to the scoped modules.
  // Alternatively we could skip instantiating the scoped modules but then singletons like the one used in
  // expo-updates would be loaded as bare modules. In the case of expo-updates, this would throw a fatal error
  // because Expo.plist is not available in the Expo Go app.
  NSAssert(_appRecord.scopeKey, @"Experience scope key should be nonnull when getting initial properties for root view. This can occur when the manifest JSON, loaded from the server, is missing keys.");

  if ([self isReadyToLoad]) {
    _versionManager = [[EXVersionManager alloc] initWithParams:[self extraParams]
                                                      manifest:_appRecord.appLoader.manifest
                                                  fatalHandler:handleFatalReactError
                                                   logFunction:[self logFunction]
                                                  logThreshold:[self logLevel]];
    
    [self _createAppInstance];
    [self _startObservingNotificationsForHost];
    
    if (!_isHeadless) {
      _reactRootView = [self.expoAppInstance.reactNativeFactory.rootViewFactory viewWithModuleName:[self applicationKeyForRootView] initialProperties:[self initialPropertiesForRootView]];
    }

    [self setupWebSocketControls];
    [_delegate reactAppManagerIsReadyForLoad:self];
  }
}

- (void)_createAppInstance
{
  __weak __typeof(self) weakSelf = self;
  ExpoAppInstance *appInstance = [[ExpoAppInstance alloc] initWithSourceURL:[self bundleUrl] manager:_versionManager onLoad:^(NSURL *sourceURL, RCTSourceLoadBlock loadCallback) {
    EXReactAppManager *strongSelf = weakSelf;
    [strongSelf loadSourceForHost:sourceURL onComplete:loadCallback];
  }];

  _expoAppInstance = appInstance;
}

- (NSDictionary *)extraParams
{
  // we allow the vanilla RN dev menu in some circumstances.
  BOOL isStandardDevMenuAllowed = false;
  return @{
    @"manifest": _appRecord.appLoader.manifest.rawManifestJSON,
    @"constants": @{
        @"linkingUri": RCTNullIfNil([EXKernelLinkingManager linkingUriForExperienceUri:_appRecord.appLoader.manifestUrl useLegacy:NO]),
        @"experienceUrl": RCTNullIfNil(_appRecord.appLoader.manifestUrl? _appRecord.appLoader.manifestUrl.absoluteString: nil),
        @"expoRuntimeVersion": [EXBuildConstants sharedInstance].expoRuntimeVersion,
        @"manifest": _appRecord.appLoader.manifest.rawManifestJSON,
        @"executionEnvironment": [self _executionEnvironment],
        @"appOwnership": @"expo",
        @"isHeadless": @(_isHeadless),
        @"supportedExpoSdks": @[[EXVersions sharedInstance].sdkVersion],
    },
    @"exceptionsManagerDelegate": _exceptionHandler,
    @"initialUri": RCTNullIfNil([EXKernelLinkingManager initialUriWithManifestUrl:_appRecord.appLoader.manifestUrl]),
    @"isDeveloper": @([self enablesDeveloperTools]),
    @"isStandardDevMenuAllowed": @(isStandardDevMenuAllowed),
    @"testEnvironment": @([EXEnvironment sharedEnvironment].testEnvironment),
    @"services": [EXKernel sharedInstance].serviceRegistry.allServices,
    @"singletonModules": [EXModuleRegistryProvider singletonModules],
    @"moduleRegistryDelegateClass": RCTNullIfNil([self moduleRegistryDelegateClass]),
    @"fileSystemDirectories": @{
        @"documentDirectory": [self scopedDocumentDirectory],
        @"cachesDirectory": [self scopedCachesDirectory]
    }
  };
}

- (void)invalidate
{
  [self _invalidateAndClearDelegate:YES];
}

- (void)_invalidateAndClearDelegate:(BOOL)clearDelegate
{
  [self _stopObservingNotifications];
  if (_viewTestTimer) {
    [_viewTestTimer invalidate];
    _viewTestTimer = nil;
  }
  if (_versionManager) {
    [_versionManager invalidate];
    _versionManager = nil;
  }
  if (_reactRootView) {
    [_reactRootView removeFromSuperview];
    _reactRootView = nil;
  }
  if (_expoAppInstance) {
    _expoAppInstance = nil;
    if (_delegate) {
      [_delegate reactAppManagerDidInvalidate:self];
      if (clearDelegate) {
        _delegate = nil;
      }
    }
  }
  _isReactHostRunning = NO;
}

- (BOOL)isReadyToLoad
{
  if (_appRecord) {
    return (_appRecord.appLoader.status == kEXAppLoaderStatusHasManifest || _appRecord.appLoader.status == kEXAppLoaderStatusHasManifestAndBundle);
  }
  return NO;
}

- (NSURL *)bundleUrl
{
  return [EXApiUtil bundleUrlFromManifest:_appRecord.appLoader.manifest];
}

#pragma mark - EXAppFetcherDataSource

- (NSString *)bundleResourceNameForAppFetcher:(EXAppFetcher *)appFetcher withManifest:(nonnull EXManifestsManifest *)manifest
{
  return manifest.legacyId;
}

- (BOOL)appFetcherShouldInvalidateBundleCache:(EXAppFetcher *)appFetcher
{
  return NO;
}

- (void)loadSourceForHost:(NSURL *)sourceURL onComplete:(RCTSourceLoadBlock)loadCallback {
  // clear any potentially old loading state
  if (_appRecord.scopeKey) {
    [[EXKernel sharedInstance].serviceRegistry.errorRecoveryManager setError:nil forScopeKey:_appRecord.scopeKey];
  }
  
  if ([self enablesDeveloperTools]) {
    if ([_appRecord.appLoader supportsBundleReload]) {
      [_appRecord.appLoader forceBundleReload];
    } else {
      NSAssert(_appRecord.scopeKey, @"EXKernelAppRecord.scopeKey should be nonnull if we have a manifest with developer tools enabled");
      [[EXKernel sharedInstance] reloadAppWithScopeKey:_appRecord.scopeKey];
    }
  }
  
  _loadCallback = loadCallback;
  if (_appRecord.appLoader.status == kEXAppLoaderStatusHasManifestAndBundle) {
    // finish loading immediately (app loader won't call this since it's already done)
    [self appLoaderFinished];
  } else {
    // wait for something else to call `appLoaderFinished` or `appLoaderFailed` later.
  }
}

- (void)appLoaderFinished
{
  NSData *data = _appRecord.appLoader.bundle;
  if (_loadCallback) {
    _loadCallback(nil, [[RCTSource alloc] initWithURL:[self bundleUrl] data:data]);
    _loadCallback = nil;
  }
}

- (void)appLoaderFailedWithError:(NSError *)error
{
  // RN is going to call RCTFatal() on this error, so keep a reference to it for later
  // so we can distinguish this non-fatal error from actual fatal cases.
  if (_appRecord.scopeKey) {
    [[EXKernel sharedInstance].serviceRegistry.errorRecoveryManager setError:error forScopeKey:_appRecord.scopeKey];
  }

  // react won't post this for us
  [[NSNotificationCenter defaultCenter] postNotificationName:RCTJavaScriptDidFailToLoadNotification object:error];

  if (_loadCallback) {
    _loadCallback(error, nil);
    _loadCallback = nil;
  }
}

#pragma mark - JavaScript loading

- (void)_startObservingNotificationsForHost
{
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(_handleJavaScriptLoadEvent:)
                                               name:RCTInstanceDidLoadBundle
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(_handleJavaScriptLoadEvent:)
                                               name:RCTJavaScriptDidFailToLoadNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(_handleReactContentEvent:)
                                               name:RCTContentDidAppearNotification
                                             object:nil];
}

- (void)_stopObservingNotifications
{
  [[NSNotificationCenter defaultCenter] removeObserver:self name:RCTInstanceDidLoadBundle object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:RCTJavaScriptDidFailToLoadNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:RCTContentDidAppearNotification object:nil];
}

- (void)_handleJavaScriptStartLoadingEvent:(NSNotification *)notification
{
  __weak __typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong __typeof(self) strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf.delegate reactAppManagerStartedLoadingJavaScript:strongSelf];
    }
  });
}

- (void)_handleJavaScriptLoadEvent:(NSNotification *)notification
{
  if ([notification.name isEqualToString:RCTInstanceDidLoadBundle]) {
    _isReactHostRunning = YES;
    _hasHostEverLoaded = YES;
    [_versionManager hostFinishedLoading:self.reactHost];

    // TODO: temporary solution for hiding LoadingProgressWindow
    if (_appRecord.viewController) {
      EX_WEAKIFY(self);
      dispatch_async(dispatch_get_main_queue(), ^{
        EX_ENSURE_STRONGIFY(self);
        [self->_appRecord.viewController hideLoadingProgressWindow];
      });
    }
  } else if ([notification.name isEqualToString:RCTJavaScriptDidFailToLoadNotification]) {
    NSError *error = (notification.userInfo) ? notification.userInfo[@"error"] : nil;
    if (_appRecord.scopeKey) {
      [[EXKernel sharedInstance].serviceRegistry.errorRecoveryManager setError:error forScopeKey:_appRecord.scopeKey];
    }

    EX_WEAKIFY(self);
    dispatch_async(dispatch_get_main_queue(), ^{
      EX_ENSURE_STRONGIFY(self);
      [self.delegate reactAppManager:self failedToLoadJavaScriptWithError:error];
    });
  }
}

# pragma mark app loading & splash screen

- (void)_handleReactContentEvent:(NSNotification *)notification
{
  if ([notification.name isEqualToString:RCTContentDidAppearNotification]) {
    EX_WEAKIFY(self);
    dispatch_async(dispatch_get_main_queue(), ^{
      EX_ENSURE_STRONGIFY(self);
      [self.delegate reactAppManagerAppContentDidAppear:self];
      [self _appLoadingFinished];
    });
  }
}

- (void)_appLoadingFinished
{
  EX_WEAKIFY(self);
  dispatch_async(dispatch_get_main_queue(), ^{
    EX_ENSURE_STRONGIFY(self);
    if (self.appRecord.scopeKey) {
      [[EXKernel sharedInstance].serviceRegistry.errorRecoveryManager experienceFinishedLoadingWithScopeKey:self.appRecord.scopeKey];
    }
    [self.delegate reactAppManagerFinishedLoadingJavaScript:self];
  });
}

- (void)didReceiveReloadCommand {
  EX_WEAKIFY(self);
  dispatch_async(dispatch_get_main_queue(), ^{
    EX_ENSURE_STRONGIFY(self);
    [self.delegate reactAppManagerAppContentWillReload:self];
  });
}

#pragma mark - dev tools

- (RCTLogFunction)logFunction
{
  return (([self enablesDeveloperTools]) ? EXDeveloperRCTLogFunction : EXDefaultRCTLogFunction);
}

- (RCTLogLevel)logLevel
{
  return ([self enablesDeveloperTools]) ? RCTLogLevelInfo : RCTLogLevelWarning;
}

- (BOOL)enablesDeveloperTools
{
  EXManifestsManifest *manifest = _appRecord.appLoader.manifest;
  if (manifest) {
    return manifest.isUsingDeveloperTool;
  }
  return false;
}

- (BOOL)requiresValidManifests
{
  return YES;
}

- (void)showDevMenu
{
  if ([self enablesDeveloperTools]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.versionManager showDevMenuForHost:self.reactHost];
    });
  }
}

- (void)reloadApp
{
  if ([self enablesDeveloperTools]) {
    RCTTriggerReloadCommandListeners(@"Dev menu - reload");
  }
}

- (void)togglePerformanceMonitor
{
  if ([self enablesDeveloperTools]) {
    [self.versionManager togglePerformanceMonitorForHost:self.reactHost];
  }
}

- (void)toggleElementInspector
{
  if ([self enablesDeveloperTools]) {
    [self.versionManager toggleElementInspectorForHost:self.reactHost];
  }
}

- (void)toggleDevMenu
{
  [[EXKernel sharedInstance] switchTasks];
}

- (void)setupWebSocketControls
{
  if ([self enablesDeveloperTools]) {
    if ([_versionManager respondsToSelector:@selector(addWebSocketNotificationHandler:queue:forMethod:)]) {
      __weak __typeof(self) weakSelf = self;

      // Attach listeners to the bundler's dev server web socket connection.
      // This enables tools to automatically reload the client remotely (i.e. in expo-cli).

      // Enable a lot of tools under the same command namespace
      [_versionManager addWebSocketNotificationHandler:^(id params) {
        if (params != [NSNull null] && (NSDictionary *)params) {
          NSDictionary *_params = (NSDictionary *)params;
          if (_params[@"name"] != nil && (NSString *)_params[@"name"]) {
            NSString *name = _params[@"name"];
            if ([name isEqualToString:@"reload"]) {
              [[EXKernel sharedInstance] reloadVisibleApp];
            } else if ([name isEqualToString:@"toggleDevMenu"]) {
              [weakSelf toggleDevMenu];
            } else if ([name isEqualToString:@"toggleElementInspector"]) {
              [weakSelf toggleElementInspector];
            } else if ([name isEqualToString:@"togglePerformanceMonitor"]) {
              [weakSelf togglePerformanceMonitor];
            }
          }
        }
      }
                                                 queue:dispatch_get_main_queue()
                                             forMethod:@"sendDevCommand"];

      // These (reload and devMenu) are here to match RN dev tooling.

      // Reload the app on "reload"
      [_versionManager addWebSocketNotificationHandler:^(id params) {
        [[EXKernel sharedInstance] reloadVisibleApp];
      }
                                                 queue:dispatch_get_main_queue()
                                             forMethod:@"reload"];

      // Open the dev menu on "devMenu"
      [_versionManager addWebSocketNotificationHandler:^(id params) {
        [weakSelf toggleDevMenu];
      }
                                                 queue:dispatch_get_main_queue()
                                             forMethod:@"devMenu"];
    }
  }
}

- (NSDictionary<NSString *, NSString *> *)devMenuItems
{
  return [self.versionManager devMenuItemsForHost:self.reactHost];
}

- (void)selectDevMenuItemWithKey:(NSString *)key
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.versionManager selectDevMenuItemWithKey:key host:self.reactHost bundleURL:[self bundleUrl]];
  });
}

#pragma mark - RN configuration

- (NSDictionary *)launchOptionsForHost
{
  return @{};
}

- (Class)moduleRegistryDelegateClass
{
  return nil;
}

- (NSString *)applicationKeyForRootView
{
  EXManifestsManifest *manifest = _appRecord.appLoader.manifest;
  if (manifest && manifest.appKey) {
    return manifest.appKey;
  }

  NSURL *bundleUrl = [self bundleUrl];
  if (bundleUrl) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:bundleUrl resolvingAgainstBaseURL:YES];
    NSArray<NSURLQueryItem *> *queryItems = components.queryItems;
    for (NSURLQueryItem *item in queryItems) {
      if ([item.name isEqualToString:@"app"]) {
        return item.value;
      }
    }
  }

  return @"main";
}

- (NSDictionary * _Nullable)initialPropertiesForRootView
{
  NSMutableDictionary *props = [NSMutableDictionary dictionary];
  NSMutableDictionary *expProps = [NSMutableDictionary dictionary];

  NSAssert(_appRecord.scopeKey, @"Experience scope key should be nonnull when getting initial properties for root view");

  NSDictionary *errorRecoveryProps = [[EXKernel sharedInstance].serviceRegistry.errorRecoveryManager developerInfoForScopeKey:_appRecord.scopeKey];
  if ([[EXKernel sharedInstance].serviceRegistry.errorRecoveryManager scopeKeyIsRecoveringFromError:_appRecord.scopeKey]) {
    [[EXKernel sharedInstance].serviceRegistry.errorRecoveryManager increaseAutoReloadBuffer];
    if (errorRecoveryProps) {
      expProps[@"errorRecovery"] = errorRecoveryProps;
    }
  }

  expProps[@"shell"] = @(_appRecord == nil);
  expProps[@"appOwnership"] = @"expo";
  if (_initialProps) {
    [expProps addEntriesFromDictionary:_initialProps];
  }

  NSString *manifestString = nil;
  EXManifestsManifest *manifest = _appRecord.appLoader.manifest;
  if (manifest && [NSJSONSerialization isValidJSONObject:manifest.rawManifestJSON]) {
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:manifest.rawManifestJSON options:0 error:&error];
    if (jsonData) {
      manifestString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    } else {
      DDLogWarn(@"Failed to serialize JSON manifest: %@", error);
    }
  }

  expProps[@"manifestString"] = manifestString;
  if (_appRecord.appLoader.manifestUrl) {
    expProps[@"initialUri"] = [_appRecord.appLoader.manifestUrl absoluteString];
  }
  props[@"exp"] = expProps;
  return props;
}

- (NSString *)_executionEnvironment
{
  return EXConstantsExecutionEnvironmentStoreClient;
}

- (NSString *)scopedDocumentDirectory
{
  NSString *scopeKey = _appRecord.scopeKey;
  NSString *mainDocumentDirectory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  NSString *exponentDocumentDirectory = [mainDocumentDirectory stringByAppendingPathComponent:@"ExponentExperienceData"];
  return [[exponentDocumentDirectory stringByAppendingPathComponent:scopeKey] stringByStandardizingPath];
}

- (NSString *)scopedCachesDirectory
{
  NSString *scopeKey = _appRecord.scopeKey;
  NSString *mainCachesDirectory = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
  NSString *exponentCachesDirectory = [mainCachesDirectory stringByAppendingPathComponent:@"ExponentExperienceData"];
  return [[exponentCachesDirectory stringByAppendingPathComponent:scopeKey] stringByStandardizingPath];
}

@end
