#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

// ===================== 全局变量声明 =====================
static dispatch_semaphore_t g_dataLock = NULL;
static NSMutableDictionary *g_userInfoDict = nil;
static NSString *g_currentTargetUid = nil;
static NSString *g_bluedBasicToken = nil;
static double g_myLat = 0.0;
static double g_myLng = 0.0;
static double g_targetLat = 0.0;
static double g_targetLng = 0.0;
static double g_targetDistance = -1.0;
static UIButton *g_floatBtn = nil;

// ===================== 类别方法声明 =====================
@interface NSURLConnection (TrackHookMethods)
+ (BOOL)isTargetRequest:(NSString *)urlString host:(NSString *)host;
+ (void)extractMyLocationFromURL:(NSString *)urlString;
@end

@interface NSURLSession (TrackHookMethods)
- (void)processTargetRequest:(NSURLRequest *)request;
@end

@interface UIViewController (TrackHookMethods)
- (void)addFloatButton;
- (void)th_onPan:(UIPanGestureRecognizer *)pan;
- (void)th_onBtnClick;
@end
// ===================== 类别声明结束 =====================

%hook NSURLConnection

%new
+ (BOOL)isTargetRequest:(NSString *)urlString host:(NSString *)host {
    @try {
        if (!host && !urlString) return NO;
        
        // 简化匹配逻辑，避免正则表达式
        if ([host hasPrefix:@"198.18."]) return YES;
        
        NSArray *targetHosts = @[
            @"social.irisgw.cn", 
            @"pay.irisgw.cn", 
            @"blued.cn", 
            @"irisgw.cn"
        ];
        
        for (NSString *targetHost in targetHosts) {
            if ([host containsString:targetHost]) return YES;
        }
        
        return NO;
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: ❌ isTargetRequest 异常: %@", exception);
        return NO;
    }
}

%new
+ (void)extractMyLocationFromURL:(NSString *)urlString {
    @try {
        if (!urlString || urlString.length == 0) return;
        
        // 简化解析逻辑
        NSArray *components = [urlString componentsSeparatedByString:@"&"];
        for (NSString *component in components) {
            if ([component hasPrefix:@"latitude="]) {
                NSString *latStr = [component substringFromIndex:9];
                double lat = [latStr doubleValue];
                if (fabs(lat) > 0.001) {
                    dispatch_semaphore_wait(g_dataLock, DISPATCH_TIME_FOREVER);
                    g_myLat = lat;
                    dispatch_semaphore_signal(g_dataLock);
                }
            } else if ([component hasPrefix:@"longitude="]) {
                NSString *lngStr = [component substringFromIndex:10];
                double lng = [lngStr doubleValue];
                if (fabs(lng) > 0.001) {
                    dispatch_semaphore_wait(g_dataLock, DISPATCH_TIME_FOREVER);
                    g_myLng = lng;
                    dispatch_semaphore_signal(g_dataLock);
                }
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: ❌ extractMyLocationFromURL 异常: %@", exception);
    }
}

%end

%hook NSURLSession

%new
- (void)processTargetRequest:(NSURLRequest *)request {
    @try {
        NSString *urlString = request.URL.absoluteString;
        NSString *host = request.URL.host;
        
        if (![NSURLConnection isTargetRequest:urlString host:host]) return;
        
        // 1. 抓取认证Token
        NSString *authHeader = request.allHTTPHeaderFields[@"Authorization"];
        if (authHeader && [authHeader hasPrefix:@"Basic "]) {
            NSString *token = [authHeader substringFromIndex:6];
            if (token.length > 0) {
                dispatch_semaphore_wait(g_dataLock, DISPATCH_TIME_FOREVER);
                g_bluedBasicToken = [token copy];
                dispatch_semaphore_signal(g_dataLock);
                NSLog(@"TrackHook: ✅ 成功抓取Blued Basic Token");
            }
        }
        
        // 2. 提取自身坐标
        [NSURLConnection extractMyLocationFromURL:urlString];
        
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: ❌ processTargetRequest 异常: %@", exception);
    }
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request 
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    
    // 异步处理，不阻塞
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [self processTargetRequest:request];
    });
    
    // 使用原始的completionHandler
    return %orig(request, completionHandler);
}

%end

%hook UIViewController

%new
- (void)addFloatButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (g_floatBtn && g_floatBtn.superview) return;
            
            UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
            if (!keyWindow) return;
            
            // 简化按钮创建
            g_floatBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            g_floatBtn.frame = CGRectMake(keyWindow.bounds.size.width - 70, keyWindow.bounds.size.height - 200, 60, 60);
            g_floatBtn.backgroundColor = [UIColor systemBlueColor];
            [g_floatBtn setTitle:@"定位" forState:UIControlStateNormal];
            [g_floatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            g_floatBtn.layer.cornerRadius = 30;
            g_floatBtn.layer.masksToBounds = YES;
            
            [g_floatBtn addTarget:self action:@selector(th_onBtnClick) forControlEvents:UIControlEventTouchUpInside];
            
            // 拖拽手势
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(th_onPan:)];
            [g_floatBtn addGestureRecognizer:pan];
            
            [keyWindow addSubview:g_floatBtn];
        } @catch (NSException *exception) {
            NSLog(@"TrackHook: ❌ addFloatButton 异常: %@", exception);
        }
    });
}

%new
- (void)th_onBtnClick {
    @try {
        dispatch_semaphore_wait(g_dataLock, DISPATCH_TIME_FOREVER);
        NSString *token = [g_bluedBasicToken copy];
        double myLat = g_myLat;
        double myLng = g_myLng;
        dispatch_semaphore_signal(g_dataLock);
        
        NSString *message = [NSString stringWithFormat:@"我的位置: %.6f, %.6f\nToken: %@", 
                           myLat, myLng, token ? @"已获取" : @"未获取"];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TrackHook" 
                                                                       message:message 
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        
        [self presentViewController:alert animated:YES completion:nil];
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: ❌ th_onBtnClick 异常: %@", exception);
    }
}

%new
- (void)th_onPan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    if (!btn) return;
    
    CGPoint translation = [pan translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:btn.superview];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    
    // 延迟添加按钮，避免启动时卡顿
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self addFloatButton];
    });
}

%end

%ctor {
    NSLog(@"TrackHook: 🚀 插件加载");
    
    // 初始化线程锁（关键修复）
    g_dataLock = dispatch_semaphore_create(1);
    
    // 延迟初始化全局变量
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_userInfoDict = [NSMutableDictionary dictionary];
    });
    
    %init; // 必须添加的初始化调用（关键修复）
}
