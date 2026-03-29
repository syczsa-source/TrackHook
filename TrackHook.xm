#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <os/lock.h>

// ===================== 全局变量声明 =====================
static os_unfair_lock g_dataLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary *g_userInfoDict = nil;
static NSString *g_currentTargetUid = nil;
static NSString *g_bluedBasicToken = nil;
static double g_myLat = 0.0;
static double g_myLng = 0.0;
static UIButton *g_floatBtn = nil;
static BOOL g_initialized = NO;

// ===================== 线程安全的全局变量访问工具 =====================
// 修复：使用独立的获取和设置函数，避免直接传递全局变量地址
static inline void safe_set_blued_token(NSString *value) {
    os_unfair_lock_lock(&g_dataLock);
    g_bluedBasicToken = [value copy];
    os_unfair_lock_unlock(&g_dataLock);
}

static inline NSString *safe_get_blued_token(void) {
    os_unfair_lock_lock(&g_dataLock);
    NSString *result = [g_bluedBasicToken copy];
    os_unfair_lock_unlock(&g_dataLock);
    return result;
}

static inline void safe_set_my_lat(double value) {
    os_unfair_lock_lock(&g_dataLock);
    g_myLat = value;
    os_unfair_lock_unlock(&g_dataLock);
}

static inline double safe_get_my_lat(void) {
    os_unfair_lock_lock(&g_dataLock);
    double result = g_myLat;
    os_unfair_lock_unlock(&g_dataLock);
    return result;
}

static inline void safe_set_my_lng(double value) {
    os_unfair_lock_lock(&g_dataLock);
    g_myLng = value;
    os_unfair_lock_unlock(&g_dataLock);
}

static inline double safe_get_my_lng(void) {
    os_unfair_lock_lock(&g_dataLock);
    double result = g_myLng;
    os_unfair_lock_unlock(&g_dataLock);
    return result;
}

// ===================== 类别方法声明 =====================
// 修复：添加缺少的方法声明
@interface UIViewController (TrackHookMethods)
- (void)addFloatButton;
- (void)actuallyAddFloatButtonToWindow:(UIWindow *)window;
- (void)th_onPan:(UIPanGestureRecognizer *)pan;
- (void)th_onBtnClick;
@end

// ===================== 核心修复：简化 Hook，避免冲突 =====================

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request 
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    
    // 只在主线程异步处理，不阻塞原始调用
    NSString *urlString = request.URL.absoluteString;
    NSString *host = request.URL.host;
    
    // 检查是否是目标请求
    BOOL shouldProcess = NO;
    if (host && urlString) {
        if ([host hasPrefix:@"198.18."]) {
            shouldProcess = YES;
        } else if ([host containsString:@"social.irisgw.cn"] || 
                  [host containsString:@"pay.irisgw.cn"] ||
                  [host containsString:@"blued.cn"]) {
            shouldProcess = YES;
        }
    }
    
    if (shouldProcess) {
        // 异步处理，避免阻塞网络线程
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                // 1. 抓取认证Token
                NSString *authHeader = request.allHTTPHeaderFields[@"Authorization"];
                if (authHeader && [authHeader hasPrefix:@"Basic "]) {
                    NSString *token = [authHeader substringFromIndex:6];
                    if (token.length > 0) {
                        safe_set_blued_token(token);
                        NSLog(@"TrackHook: ✅ 成功抓取Blued Basic Token");
                    }
                }
                
                // 2. 提取坐标（简化解析）
                NSRange latRange = [urlString rangeOfString:@"latitude="];
                NSRange lngRange = [urlString rangeOfString:@"longitude="];
                
                if (latRange.location != NSNotFound) {
                    NSString *substring = [urlString substringFromIndex:latRange.location + latRange.length];
                    NSArray *components = [substring componentsSeparatedByString:@"&"];
                    if (components.count > 0) {
                        double lat = [components[0] doubleValue];
                        if (fabs(lat) > 0.001) {
                            safe_set_my_lat(lat);
                        }
                    }
                }
                
                if (lngRange.location != NSNotFound) {
                    NSString *substring = [urlString substringFromIndex:lngRange.location + lngRange.length];
                    NSArray *components = [substring componentsSeparatedByString:@"&"];
                    if (components.count > 0) {
                        double lng = [components[0] doubleValue];
                        if (fabs(lng) > 0.001) {
                            safe_set_my_lng(lng);
                        }
                    }
                }
            }
        });
    }
    
    // 必须调用原始实现
    return %orig(request, completionHandler);
}

%end

%hook UIViewController

%new
- (void)addFloatButton {
    // 确保只在主线程执行
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self addFloatButton];
        });
        return;
    }
    
    @try {
        if (g_floatBtn && g_floatBtn.superview) return;
        
        // 安全获取 keyWindow
        UIWindow *keyWindow = nil;
        
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    for (UIWindow *window in windowScene.windows) {
                        if (window.isKeyWindow) {
                            keyWindow = window;
                            break;
                        }
                    }
                    if (keyWindow) break;
                }
            }
        } else {
            keyWindow = [UIApplication sharedApplication].keyWindow;
        }
        
        if (!keyWindow) {
            // 如果没有 keyWindow，使用第一个 window
            NSArray *windows = [UIApplication sharedApplication].windows;
            if (windows.count > 0) {
                keyWindow = windows[0];
            } else {
                return;
            }
        }
        
        // 确保不在启动时立即添加按钮
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self actuallyAddFloatButtonToWindow:keyWindow];
            });
        });
        
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: ❌ addFloatButton 异常: %@", exception);
    }
}

%new
- (void)actuallyAddFloatButtonToWindow:(UIWindow *)window {
    @try {
        if (g_floatBtn && g_floatBtn.superview) return;
        
        g_floatBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        g_floatBtn.frame = CGRectMake(window.bounds.size.width - 70, window.bounds.size.height - 200, 60, 60);
        g_floatBtn.backgroundColor = [UIColor systemBlueColor];
        [g_floatBtn setTitle:@"定位" forState:UIControlStateNormal];
        [g_floatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        g_floatBtn.layer.cornerRadius = 30;
        g_floatBtn.layer.masksToBounds = YES;
        g_floatBtn.alpha = 0; // 初始透明
        
        [g_floatBtn addTarget:self action:@selector(th_onBtnClick) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(th_onPan:)];
        [g_floatBtn addGestureRecognizer:pan];
        
        [window addSubview:g_floatBtn];
        
        // 淡入动画
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            g_floatBtn.alpha = 1.0;
        } completion:nil];
        
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: ❌ actuallyAddFloatButton 异常: %@", exception);
    }
}

%new
- (void)th_onBtnClick {
    @try {
        NSString *token = safe_get_blued_token();
        double myLat = safe_get_my_lat();
        double myLng = safe_get_my_lng();
        
        NSString *message = [NSString stringWithFormat:@"我的位置: %.6f, %.6f\nToken: %@", 
                           myLat, myLng, token ? @"已获取" : @"未获取"];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TrackHook" 
                                                                       message:message 
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" 
                                                  style:UIAlertActionStyleDefault 
                                                handler:nil]];
        
        [self presentViewController:alert animated:YES completion:nil];
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: ❌ th_onBtnClick 异常: %@", exception);
    }
}

%new
- (void)th_onPan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    if (!btn) return;
    
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;
    
    CGPoint translation = [pan translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:btn.superview];
    
    // 边界限制
    CGFloat margin = 30;
    CGRect safeArea = window.bounds;
    
    CGFloat minX = margin + btn.bounds.size.width / 2;
    CGFloat maxX = safeArea.size.width - margin - btn.bounds.size.width / 2;
    CGFloat minY = 100 + btn.bounds.size.height / 2; // 避开状态栏
    CGFloat maxY = safeArea.size.height - margin - btn.bounds.size.height / 2;
    
    btn.center = CGPointMake(
        MAX(minX, MIN(maxX, btn.center.x)),
        MAX(minY, MIN(maxY, btn.center.y))
    );
    
    // 松手时自动贴边
    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        CGPoint targetCenter = btn.center;
        
        // 自动贴到最近边
        if (btn.center.x < window.bounds.size.width / 2) {
            targetCenter.x = minX;
        } else {
            targetCenter.x = maxX;
        }
        
        [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            btn.center = targetCenter;
        } completion:nil];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    
    // 只在特定页面显示按钮
    NSString *className = NSStringFromClass([self class]);
    NSArray *targetControllers = @[@"HomeViewController", @"ProfileViewController", 
                                   @"UserDetailViewController", @"NearbyViewController"];
    
    for (NSString *targetClass in targetControllers) {
        if ([className containsString:targetClass]) {
            // 延迟添加，避免影响页面切换性能
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self addFloatButton];
            });
            break;
        }
    }
}

%end

%ctor {
    NSLog(@"TrackHook: 🚀 插件加载");
    
    // 简化初始化，避免复杂操作
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_userInfoDict = [NSMutableDictionary dictionary];
        g_initialized = YES;
    });
    
    // 初始化必须调用
    %init;
}
