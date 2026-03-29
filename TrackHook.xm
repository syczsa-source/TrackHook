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
static BOOL g_isDebugLogEnabled = YES; // 调试开关

// ===================== 调试日志 =====================
#define DEBUG_LOG(fmt, ...) \
    do { \
        if (g_isDebugLogEnabled) { \
            NSLog(@"[TrackHook-DEBUG] %s:%d " fmt, __FUNCTION__, __LINE__, ##__VA_ARGS__); \
        } \
    } while(0)

// ===================== 线程安全的全局变量访问工具 =====================
static inline void safe_set_blued_token(NSString *value) {
    os_unfair_lock_lock(&g_dataLock);
    g_bluedBasicToken = [value copy];
    if (g_isDebugLogEnabled && value) {
        DEBUG_LOG(@"Token已更新: %@", value);
    }
    os_unfair_lock_unlock(&g_dataLock);
}

static inline NSString *safe_get_blued_token(void) {
    os_unfair_lock_lock(&g_dataLock);
    NSString *result = [g_bluedBasicToken copy];
    os_unfair_lock_unlock(&g_dataLock);
    return result;
}

static inline void safe_set_my_location(double lat, double lng) {
    os_unfair_lock_lock(&g_dataLock);
    g_myLat = lat;
    g_myLng = lng;
    if (g_isDebugLogEnabled) {
        DEBUG_LOG(@"位置已更新: %.6f, %.6f", lat, lng);
    }
    os_unfair_lock_unlock(&g_dataLock);
}

static inline void safe_get_my_location(double *lat, double *lng) {
    if (!lat || !lng) return;
    os_unfair_lock_lock(&g_dataLock);
    *lat = g_myLat;
    *lng = g_myLng;
    os_unfair_lock_unlock(&g_dataLock);
}

// ===================== 工具函数 =====================
static NSString* extract_value_from_string(NSString *string, NSString *key) {
    if (!string || !key) return nil;
    
    NSString *pattern = [NSString stringWithFormat:@"%@=([^&]+)", key];
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern 
                                                                           options:0 
                                                                             error:&error];
    if (error) {
        DEBUG_LOG(@"正则错误: %@", error);
        return nil;
    }
    
    NSTextCheckingResult *result = [regex firstMatchInString:string 
                                                      options:0 
                                                        range:NSMakeRange(0, [string length])];
    if (result && result.range.location != NSNotFound) {
        NSString *value = [string substringWithRange:[result rangeAtIndex:1]];
        return [value stringByRemovingPercentEncoding];
    }
    
    return nil;
}

static void process_request_data(NSURLRequest *request) {
    @autoreleasepool {
        // 1. 记录所有请求用于调试
        NSString *urlString = request.URL.absoluteString;
        NSString *host = request.URL.host;
        NSString *method = request.HTTPMethod ?: @"GET";
        
        DEBUG_LOG(@"请求: %@ %@", method, urlString);
        
        // 2. 检查是否是目标请求
        BOOL isTargetRequest = NO;
        NSArray *targetHosts = @[@"social.irisgw.cn", @"pay.irisgw.cn", 
                                @"blued.cn", @"irisgw.cn", @"198.18."];
        
        for (NSString *targetHost in targetHosts) {
            if ([host containsString:targetHost] || [host hasPrefix:targetHost]) {
                isTargetRequest = YES;
                break;
            }
        }
        
        if (!isTargetRequest) {
            // 记录非目标请求但包含位置信息的
            if ([urlString containsString:@"latitude"] || [urlString containsString:@"longitude"]) {
                DEBUG_LOG(@"非目标但含位置: %@", urlString);
            }
            return;
        }
        
        DEBUG_LOG(@"✅ 捕获目标请求: %@", host);
        
        // 3. 提取认证信息
        NSDictionary *headers = request.allHTTPHeaderFields;
        for (NSString *key in headers) {
            NSString *value = headers[key];
            
            // Basic Token
            if ([key isEqualToString:@"Authorization"] && [value hasPrefix:@"Basic "]) {
                NSString *token = [value substringFromIndex:6];
                if (token.length > 0) {
                    safe_set_blued_token(token);
                }
            }
            
            // Bearer Token
            if ([key isEqualToString:@"Authorization"] && [value hasPrefix:@"Bearer "]) {
                NSString *token = [value substringFromIndex:7];
                if (token.length > 0) {
                    safe_set_blued_token(token);
                }
            }
            
            // Cookie
            if ([key isEqualToString:@"Cookie"]) {
                DEBUG_LOG(@"Cookie: %@", value);
                // 可以从Cookie中提取更多信息
            }
        }
        
        // 4. 从URL中提取位置
        double lat = 0.0, lng = 0.0;
        
        // 从URL参数中提取
        NSString *latStr = extract_value_from_string(urlString, @"latitude");
        NSString *lngStr = extract_value_from_string(urlString, @"longitude");
        
        if (!latStr) latStr = extract_value_from_string(urlString, @"lat");
        if (!lngStr) lngStr = extract_value_from_string(urlString, @"lng");
        
        if (latStr && lngStr) {
            lat = [latStr doubleValue];
            lng = [lngStr doubleValue];
            
            if (fabs(lat) > 0.001 && fabs(lng) > 0.001) {
                safe_set_my_location(lat, lng);
            }
        }
        
        // 5. 如果有请求体，尝试从其中提取
        if (request.HTTPBody) {
            @try {
                id json = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *dict = (NSDictionary *)json;
                    if (dict[@"latitude"] && dict[@"longitude"]) {
                        double jsonLat = [dict[@"latitude"] doubleValue];
                        double jsonLng = [dict[@"longitude"] doubleValue];
                        if (fabs(jsonLat) > 0.001 && fabs(jsonLng) > 0.001) {
                            safe_set_my_location(jsonLat, jsonLng);
                        }
                    }
                }
            } @catch (NSException *exception) {
                // 非JSON请求体，忽略
            }
        }
    }
}

// ===================== 类别方法声明 =====================
@interface UIViewController (TrackHookMethods)
- (void)addFloatButton;
- (void)actuallyAddFloatButtonToWindow:(UIWindow *)window;
- (void)th_onPan:(UIPanGestureRecognizer *)pan;
- (void)th_onBtnClick;
- (UIViewController *)th_topViewController;
@end

// ===================== Hook NSURLSession (核心抓包) =====================
%hook NSURLSession

// Hook 主要的数据请求方法
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request 
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    
    // 异步处理，不阻塞原始请求
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        process_request_data(request);
    });
    
    return %orig(request, completionHandler);
}

// Hook 其他可能的请求方法
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url 
                         completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        process_request_data(request);
    });
    
    return %orig(url, completionHandler);
}

// Hook 上传任务
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request 
                                          fromData:(NSData *)bodyData 
                                 completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        process_request_data(request);
    });
    
    return %orig(request, bodyData, completionHandler);
}

%end

// ===================== Hook UIViewController (悬浮按钮) =====================
%hook UIViewController

%new
- (void)addFloatButton {
    // 确保在主线程执行
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self addFloatButton];
        });
        return;
    }
    
    @try {
        // 检查按钮是否已存在
        if (g_floatBtn && g_floatBtn.superview) {
            [g_floatBtn.superview bringSubviewToFront:g_floatBtn];
            return;
        }
        
        // 获取合适的窗口
        UIWindow *targetWindow = nil;
        
        if (@available(iOS 13.0, *)) {
            NSSet<UIScene *> *connectedScenes = [UIApplication sharedApplication].connectedScenes;
            for (UIScene *scene in connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    for (UIWindow *window in windowScene.windows) {
                        if (window.isKeyWindow) {
                            targetWindow = window;
                            break;
                        }
                    }
                }
                if (targetWindow) break;
            }
        } else {
            targetWindow = [UIApplication sharedApplication].keyWindow;
        }
        
        if (!targetWindow) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *window in windows) {
                if (window.windowLevel == UIWindowLevelNormal && !window.hidden) {
                    targetWindow = window;
                    break;
                }
            }
        }
        
        if (!targetWindow) {
            DEBUG_LOG(@"❌ 未找到合适的窗口");
            return;
        }
        
        // 延迟添加按钮，避免卡顿
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self actuallyAddFloatButtonToWindow:targetWindow];
            });
        });
        
    } @catch (NSException *exception) {
        DEBUG_LOG(@"❌ addFloatButton异常: %@", exception);
    }
}

%new
- (void)actuallyAddFloatButtonToWindow:(UIWindow *)window {
    @try {
        if (g_floatBtn) {
            [g_floatBtn removeFromSuperview];
            g_floatBtn = nil;
        }
        
        // 创建悬浮按钮
        CGFloat screenWidth = window.bounds.size.width;
        CGFloat screenHeight = window.bounds.size.height;
        
        g_floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        g_floatBtn.frame = CGRectMake(screenWidth - 80, screenHeight / 2, 60, 60);
        g_floatBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
        [g_floatBtn setTitle:@"位置" forState:UIControlStateNormal];
        [g_floatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        g_floatBtn.titleLabel.font = [UIFont systemFontOfSize:14];
        g_floatBtn.layer.cornerRadius = 30;
        g_floatBtn.layer.masksToBounds = YES;
        g_floatBtn.layer.borderWidth = 2;
        g_floatBtn.layer.borderColor = [UIColor whiteColor].CGColor;
        g_floatBtn.layer.shadowColor = [UIColor blackColor].CGColor;
        g_floatBtn.layer.shadowOffset = CGSizeMake(0, 2);
        g_floatBtn.layer.shadowOpacity = 0.3;
        g_floatBtn.layer.shadowRadius = 4;
        g_floatBtn.alpha = 0;
        
        // 添加点击事件 - 使用更可靠的UIControlEventTouchUpInside
        [g_floatBtn addTarget:self 
                       action:@selector(th_onBtnClick) 
             forControlEvents:UIControlEventTouchUpInside];
        
        // 添加长按事件，方便调试
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] 
                                                   initWithTarget:self 
                                                   action:@selector(th_onLongPress:)];
        longPress.minimumPressDuration = 1.0;
        [g_floatBtn addGestureRecognizer:longPress];
        
        // 拖拽手势
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] 
                                      initWithTarget:self 
                                      action:@selector(th_onPan:)];
        [g_floatBtn addGestureRecognizer:pan];
        
        [window addSubview:g_floatBtn];
        [window bringSubviewToFront:g_floatBtn];
        
        // 淡入动画
        [UIView animateWithDuration:0.3 animations:^{
            g_floatBtn.alpha = 1.0;
        }];
        
        DEBUG_LOG(@"✅ 悬浮按钮已添加");
        
    } @catch (NSException *exception) {
        DEBUG_LOG(@"❌ actuallyAddFloatButton异常: %@", exception);
    }
}

%new
- (void)th_onBtnClick {
    @try {
        DEBUG_LOG(@"悬浮按钮被点击");
        
        // 震动反馈
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [generator impactOccurred];
        }
        
        // 获取当前最顶层的ViewController
        UIViewController *topVC = [self th_topViewController];
        if (!topVC) {
            DEBUG_LOG(@"❌ 无法获取顶层ViewController");
            return;
        }
        
        // 获取数据
        NSString *token = safe_get_blued_token();
        double lat = 0.0, lng = 0.0;
        safe_get_my_location(&lat, &lng);
        
        // 构建显示信息
        NSMutableString *message = [NSMutableString string];
        [message appendString:@"=== TrackHook 调试信息 ===\n\n"];
        
        if (fabs(lat) > 0.001 && fabs(lng) > 0.001) {
            [message appendFormat:@"📍 位置: %.6f, %.6f\n", lat, lng];
        } else {
            [message appendString:@"📍 位置: 未获取\n"];
        }
        
        if (token && token.length > 0) {
            [message appendFormat:@"🔑 Token: %@\n", token];
        } else {
            [message appendString:@"🔑 Token: 未获取\n"];
        }
        
        [message appendFormat:@"\n最后更新: %@", [NSDate date]];
        
        // 创建Alert
        UIAlertController *alert = [UIAlertController 
            alertControllerWithTitle:@"位置信息" 
                             message:message 
                      preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction 
            actionWithTitle:@"复制Token" 
                      style:UIAlertActionStyleDefault 
                    handler:^(UIAlertAction *action) {
            if (token) {
                [UIPasteboard generalPasteboard].string = token;
                DEBUG_LOG(@"Token已复制到剪贴板");
            }
        }]];
        
        [alert addAction:[UIAlertAction 
            actionWithTitle:@"分享位置" 
                      style:UIAlertActionStyleDefault 
                    handler:^(UIAlertAction *action) {
            if (fabs(lat) > 0.001 && fabs(lng) > 0.001) {
                NSString *locationStr = [NSString stringWithFormat:@"%.6f,%.6f", lat, lng];
                [UIPasteboard generalPasteboard].string = locationStr;
                DEBUG_LOG(@"位置已复制: %@", locationStr);
            }
        }]];
        
        [alert addAction:[UIAlertAction 
            actionWithTitle:@"确定" 
                      style:UIAlertActionStyleCancel 
                    handler:nil]];
        
        [alert addAction:[UIAlertAction 
            actionWithTitle:@"查看日志" 
                      style:UIAlertActionStyleDefault 
                    handler:^(UIAlertAction *action) {
            // 可以在这里添加查看完整日志的功能
        }]];
        
        // 显示Alert
        [topVC presentViewController:alert animated:YES completion:^{
            DEBUG_LOG(@"Alert已显示");
        }];
        
    } @catch (NSException *exception) {
        DEBUG_LOG(@"❌ th_onBtnClick异常: %@", exception);
    }
}

%new
- (void)th_onLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        DEBUG_LOG(@"按钮长按");
        
        // 显示调试菜单
        UIAlertController *debugAlert = [UIAlertController 
            alertControllerWithTitle:@"调试选项" 
                             message:@"选择操作" 
                      preferredStyle:UIAlertControllerStyleActionSheet];
        
        [debugAlert addAction:[UIAlertAction 
            actionWithTitle:@"重新加载按钮" 
                      style:UIAlertActionStyleDefault 
                    handler:^(UIAlertAction *action) {
            [g_floatBtn removeFromSuperview];
            g_floatBtn = nil;
            [self addFloatButton];
        }]];
        
        [debugAlert addAction:[UIAlertAction 
            actionWithTitle:@"隐藏按钮" 
                      style:UIAlertActionStyleDefault 
                    handler:^(UIAlertAction *action) {
            [UIView animateWithDuration:0.3 animations:^{
                g_floatBtn.alpha = 0;
            }];
        }]];
        
        [debugAlert addAction:[UIAlertAction 
            actionWithTitle:@"显示按钮" 
                      style:UIAlertActionStyleDefault 
                    handler:^(UIAlertAction *action) {
            [UIView animateWithDuration:0.3 animations:^{
                g_floatBtn.alpha = 1.0;
            }];
        }]];
        
        [debugAlert addAction:[UIAlertAction 
            actionWithTitle:@"取消" 
                      style:UIAlertActionStyleCancel 
                    handler:nil]];
        
        UIViewController *topVC = [self th_topViewController];
        if (topVC) {
            // 适配iPad
            if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
                debugAlert.popoverPresentationController.sourceView = g_floatBtn;
                debugAlert.popoverPresentationController.sourceRect = g_floatBtn.bounds;
            }
            
            [topVC presentViewController:debugAlert animated:YES completion:nil];
        }
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
    CGRect bounds = window.bounds;
    CGFloat statusBarHeight = 20;
    
    CGFloat minX = margin + btn.bounds.size.width / 2;
    CGFloat maxX = bounds.size.width - margin - btn.bounds.size.width / 2;
    CGFloat minY = statusBarHeight + margin + btn.bounds.size.height / 2;
    CGFloat maxY = bounds.size.height - margin - btn.bounds.size.height / 2;
    
    btn.center = CGPointMake(
        MAX(minX, MIN(maxX, btn.center.x)),
        MAX(minY, MIN(maxY, btn.center.y))
    );
    
    // 松手时自动贴边
    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        
        CGPoint targetCenter = btn.center;
        CGFloat centerX = bounds.size.width / 2;
        
        // 自动贴到左右两边
        if (btn.center.x < centerX) {
            targetCenter.x = minX;
        } else {
            targetCenter.x = maxX;
        }
        
        [UIView animateWithDuration:0.2 
                              delay:0 
             usingSpringWithDamping:0.8 
              initialSpringVelocity:0.5 
                            options:UIViewAnimationOptionCurveEaseOut 
                         animations:^{
            btn.center = targetCenter;
        } completion:nil];
    }
}

%new
- (UIViewController *)th_topViewController {
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    if (!keyWindow) {
        NSArray *windows = [UIApplication sharedApplication].windows;
        for (UIWindow *window in windows) {
            if (window.windowLevel == UIWindowLevelNormal && !window.hidden) {
                keyWindow = window;
                break;
            }
        }
    }
    
    UIViewController *rootVC = keyWindow.rootViewController;
    if (!rootVC) return nil;
    
    UIViewController *topVC = rootVC;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    
    if ([topVC isKindOfClass:[UINavigationController class]]) {
        topVC = [(UINavigationController *)topVC topViewController];
    } else if ([topVC isKindOfClass:[UITabBarController class]]) {
        topVC = [(UITabBarController *)topVC selectedViewController];
        if ([topVC isKindOfClass:[UINavigationController class]]) {
            topVC = [(UINavigationController *)topVC topViewController];
        }
    }
    
    return topVC;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    
    // 只在主线程处理
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self viewDidAppear:animated];
        });
        return;
    }
    
    @try {
        // 检查当前ViewController是否是需要显示按钮的页面
        NSString *className = NSStringFromClass([self class]);
        
        // 扩展目标页面列表
        NSArray *targetControllers = @[
            @"Home", @"Profile", @"User", @"Nearby", @"Discover", 
            @"Message", @"Mine", @"Main", @"TabBar", @"Navigation"
        ];
        
        BOOL shouldShow = NO;
        for (NSString *keyword in targetControllers) {
            if ([className containsString:keyword]) {
                shouldShow = YES;
                break;
            }
        }
        
        if (shouldShow) {
            // 延迟显示，避免卡顿
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), 
                          dispatch_get_main_queue(), ^{
                [self addFloatButton];
            });
        }
        
    } @catch (NSException *exception) {
        DEBUG_LOG(@"❌ viewDidAppear异常: %@", exception);
    }
}

%end

%ctor {
    NSLog(@"🚀 TrackHook插件加载 - 编译时间: %s %s", __DATE__, __TIME__);
    
    // 初始化全局变量
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_userInfoDict = [NSMutableDictionary dictionary];
        g_initialized = YES;
        DEBUG_LOG(@"全局变量初始化完成");
    });
    
    // 初始化Hook
    %init;
}
