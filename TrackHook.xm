#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

#define TRACK_BTN_TAG 100001
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

// 全局数据存储
static NSLock *g_dataLock = nil;
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_currentLat = 0.0;
static double g_currentLng = 0.0;
static double g_targetDistance = -1.0;
static UIWindow *g_floatWindow = nil;
static NSString *g_amapAddress = nil;
static NSMutableDictionary *g_capturedRequests = nil;  // 存储捕获的请求
static NSMutableDictionary *g_userData = nil;         // 存储用户数据

// ==================== 自定义窗口类 ====================
@interface TrackHookWindow : UIWindow
@end

@implementation TrackHookWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    UIView *btnView = [self viewWithTag:TRACK_BTN_TAG];
    if (btnView && [btnView pointInside:[self convertPoint:point toView:btnView] withEvent:event]) {
        return hitView;
    }
    return nil;
}
@end
// ==================== 自定义窗口类结束 ====================

// ==================== 类别方法声明 ====================
@interface UIViewController (TrackHookMethods)
- (UIWindow *)th_getSafeKeyWindow;
- (void)th_onBtnClick;
- (void)th_onAdvancedBtnClick;  // 新增：高级功能按钮
- (void)th_showRequestsList;    // 新增：显示请求列表
- (NSString *)extractUserIdFromUI;
- (NSString *)searchViewHierarchy:(UIView *)view;
- (void)th_addBtn;
- (void)th_handlePan:(UIPanGestureRecognizer *)pan;
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur;
@end

@interface NSURLConnection (TrackHookMethods)
+ (void)processRequestData:(NSURLRequest *)request responseData:(NSData *)responseData;
+ (BOOL)isTargetRequest:(NSString *)urlString host:(NSString *)host;
+ (void)extractDataFromURL:(NSString *)urlString;
+ (void)enhancedExtractDataFromURL:(NSString *)urlString request:(NSURLRequest *)request;
@end

@interface NSURLSession (TrackHookMethods)
- (void)processRequestData:(NSURLRequest *)request responseData:(NSData *)responseData;
- (void)extractDataFromResponse:(NSData *)data forRequest:(NSURLRequest *)request;
- (void)deepSearchDistanceInObject:(id)obj;
- (void)deepSearchUserIdInObject:(id)obj;
@end

%ctor {
    NSLog(@"TrackHook: 🚀 Hook初始化");
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_dataLock = [[NSLock alloc] init];
        g_capturedRequests = [[NSMutableDictionary alloc] init];
        g_userData = [[NSMutableDictionary alloc] init];
        NSLog(@"TrackHook: ✅ 全局变量已初始化");
    });
    
    %init;
}

%hook UIViewController

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
    return foundWindow ?: [[UIApplication sharedApplication] windows].firstObject;
}

%new
- (void)th_onBtnClick {
    NSLog(@"TrackHook: 🎯 悬浮按钮被点击 - 基础功能");
    
    [g_dataLock lock];
    NSString *currentToken = [g_bluedBasicToken copy];
    NSString *currentUid = [g_currentTargetUid copy];
    double lat = g_currentLat;
    double lng = g_currentLng;
    double distance = g_targetDistance;
    NSString *amapAddr = [g_amapAddress copy];
    [g_dataLock unlock];
    
    NSLog(@"TrackHook: 📊 当前数据状态:");
    NSLog(@"TrackHook:   Token: %@", currentToken ? @"✅ 已获取" : @"❌ 无");
    NSLog(@"TrackHook:   用户ID: %@", currentUid ?: @"❌ 无");
    NSLog(@"TrackHook:   我的坐标: (%.6f, %.6f)", lat, lng);
    NSLog(@"TrackHook:   距离: %.2f km", distance);
    NSLog(@"TrackHook:   高德地址: %@", amapAddr ?: @"❌ 无");
    
    // 尝试从UI提取用户ID
    NSString *uid = [self extractUserIdFromUI];
    if (uid && uid.length > 0) {
        NSLog(@"TrackHook: ✅ 从UI提取到用户ID: %@", uid);
        [g_dataLock lock];
        g_currentTargetUid = [uid copy];
        [g_dataLock unlock];
    }
    
    [g_dataLock lock];
    NSString *targetUid = [g_currentTargetUid copy];
    NSString *basicToken = [g_bluedBasicToken copy];
    double myLat = g_currentLat;
    double myLng = g_currentLng;
    double myDistance = g_targetDistance;
    NSString *myAmapAddr = [g_amapAddress copy];
    [g_dataLock unlock];
    
    if (!targetUid) {
        [self th_showToast:@"缺少用户ID\n请点击右上角分享按钮" duration:3.0];
        return;
    }
    if (!basicToken) {
        [self th_showToast:@"缺少Token\n请刷新动态后重试" duration:3.0];
        return;
    }
    if (fabs(myLat) < 0.001 || fabs(myLng) < 0.001) {
        [self th_showToast:@"缺少我的坐标\n请先刷新用户动态" duration:3.0];
        return;
    }

    NSString *resStr = [NSString stringWithFormat:@"🆔 用户ID: %@\n\n📍 我的位置:\n纬度: %.6f\n经度: %.6f\n\n📏 距离: %.2f km\n\n🗺️ 高德地址: %@\n\n🔐 Basic Token:\n%@", 
                       targetUid, myLat, myLng, myDistance, 
                       myAmapAddr ?: @"无", 
                       [basicToken substringToIndex:MIN(50, basicToken.length)]];
    
    UIAlertController *resAlert = [UIAlertController alertControllerWithTitle:@"定位信息" 
                                                                     message:resStr 
                                                              preferredStyle:UIAlertControllerStyleAlert];
    
    [resAlert addAction:[UIAlertAction actionWithTitle:@"复制坐标" 
                                                 style:UIAlertActionStyleDefault 
                                               handler:^(UIAlertAction *a){
        NSString *coords = [NSString stringWithFormat:@"%.6f, %.6f", myLat, myLng];
        [[UIPasteboard generalPasteboard] setString:coords];
        [self th_showToast:@"坐标已复制" duration:1.0];
    }]];
    
    [resAlert addAction:[UIAlertAction actionWithTitle:@"复制Token" 
                                                 style:UIAlertActionStyleDefault 
                                               handler:^(UIAlertAction *a){
        if (basicToken) {
            [[UIPasteboard generalPasteboard] setString:basicToken];
            [self th_showToast:@"Token已复制" duration:1.0];
        } else {
            [self th_showToast:@"无Token信息" duration:1.0];
        }
    }]];
    
    [resAlert addAction:[UIAlertAction actionWithTitle:@"高级功能" 
                                                 style:UIAlertActionStyleDefault 
                                               handler:^(UIAlertAction *a){
        [self th_onAdvancedBtnClick];
    }]];
    
    [resAlert addAction:[UIAlertAction actionWithTitle:@"确定" 
                                                 style:UIAlertActionStyleCancel 
                                               handler:nil]];
    [self presentViewController:resAlert animated:YES completion:nil];
}

%new
- (void)th_onAdvancedBtnClick {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"高级功能" 
                                                                   message:@"选择要执行的操作" 
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"查看请求列表" 
                                              style:UIAlertActionStyleDefault 
                                            handler:^(UIAlertAction *a){
        [self th_showRequestsList];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"清除所有数据" 
                                              style:UIAlertActionStyleDestructive 
                                            handler:^(UIAlertAction *a){
        [g_dataLock lock];
        g_bluedBasicToken = nil;
        g_currentTargetUid = nil;
        g_currentLat = 0.0;
        g_currentLng = 0.0;
        g_targetDistance = -1.0;
        g_amapAddress = nil;
        [g_capturedRequests removeAllObjects];
        [g_userData removeAllObjects];
        [g_dataLock unlock];
        [self th_showToast:@"已清除所有数据" duration:2.0];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"导出数据" 
                                              style:UIAlertActionStyleDefault 
                                            handler:^(UIAlertAction *a){
        [self th_exportData];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" 
                                              style:UIAlertActionStyleCancel 
                                            handler:nil]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)th_showRequestsList {
    NSMutableString *result = [NSMutableString string];
    [result appendString:@"📡 捕获的网络请求:\n\n"];
    
    NSArray *sortedKeys = [[g_capturedRequests allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *key in sortedKeys) {
        NSDictionary *requestInfo = g_capturedRequests[key];
        [result appendFormat:@"📍 %@\n", requestInfo[@"url"]];
        [result appendFormat:@"   ⏰ %@\n", requestInfo[@"timestamp"]];
        [result appendFormat:@"   📁 参数: %@\n\n", requestInfo[@"params"]];
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"请求列表" 
                                                                   message:result.length > 0 ? result : @"暂无捕获的请求" 
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" 
                                              style:UIAlertActionStyleCancel 
                                            handler:nil]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)th_exportData {
    NSMutableDictionary *exportData = [NSMutableDictionary dictionary];
    
    [g_dataLock lock];
    if (g_currentTargetUid) exportData[@"user_id"] = g_currentTargetUid;
    if (g_bluedBasicToken) exportData[@"basic_token"] = g_bluedBasicToken;
    if (fabs(g_currentLat) > 0.001) exportData[@"latitude"] = @(g_currentLat);
    if (fabs(g_currentLng) > 0.001) exportData[@"longitude"] = @(g_currentLng);
    if (g_targetDistance > 0) exportData[@"distance"] = @(g_targetDistance);
    if (g_amapAddress) exportData[@"address"] = g_amapAddress;
    
    if (g_capturedRequests.count > 0) {
        exportData[@"captured_requests"] = [g_capturedRequests copy];
    }
    
    if (g_userData.count > 0) {
        exportData[@"user_data"] = [g_userData copy];
    }
    [g_dataLock unlock];
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:exportData options:NSJSONWritingPrettyPrinted error:&error];
    
    if (error) {
        [self th_showToast:@"导出失败" duration:2.0];
        return;
    }
    
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [[UIPasteboard generalPasteboard] setString:jsonStr];
    [self th_showToast:@"数据已复制到剪贴板" duration:2.0];
}

%new
- (NSString *)extractUserIdFromUI {
    NSLog(@"TrackHook: 🔍 开始从UI提取用户ID");
    
    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
    
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha <= 0) continue;
        
        NSString *foundUid = [self searchViewHierarchy:window];
        if (foundUid) {
            NSLog(@"TrackHook: ✅ 找到用户ID: %@", foundUid);
            return foundUid;
        }
    }
    
    NSLog(@"TrackHook: ❌ 未找到用户ID");
    return nil;
}

%new
- (NSString *)searchViewHierarchy:(UIView *)view {
    if (!view) return nil;
    
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        NSString *text = label.text;
        if (text && text.length > 0) {
            NSArray *patterns = @[
                @"ID\\s*[:：]\\s*(\\d+)",
                @"用户ID\\s*[:：]\\s*(\\d+)",
                @"UID\\s*[:：]\\s*(\\d+)",
                @"\\b(\\d{6,10})\\b"
            ];
            
            for (NSString *pattern in patterns) {
                NSError *error = nil;
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern 
                                                                                       options:NSRegularExpressionCaseInsensitive 
                                                                                         error:&error];
                if (!error) {
                    NSTextCheckingResult *match = [regex firstMatchInString:text 
                                                                    options:0 
                                                                      range:NSMakeRange(0, text.length)];
                    if (match) {
                        NSString *uid = [text substringWithRange:[match rangeAtIndex:1]];
                        if (uid.length >= 6 && uid.length <= 10) {
                            return uid;
                        }
                    }
                }
            }
        }
    }
    
    for (UIView *subview in view.subviews) {
        NSString *foundUid = [self searchViewHierarchy:subview];
        if (foundUid) {
            return foundUid;
        }
    }
    
    return nil;
}

%new
- (void)th_addBtn {
    NSLog(@"TrackHook: 🎨 准备添加悬浮按钮");
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *targetScene = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                    targetScene = (UIWindowScene *)scene;
                    break;
                }
            }
        }
        
        if (@available(iOS 13.0, *)) {
            if (!targetScene) {
                NSLog(@"TrackHook: ❌ 无法获取当前活跃的 WindowScene");
                return;
            }
        }
        
        BOOL needCreateWindow = NO;
        if (@available(iOS 13.0, *)) {
            needCreateWindow = (!g_floatWindow || g_floatWindow.windowScene != targetScene);
        } else {
            needCreateWindow = (!g_floatWindow);
        }
        
        if (needCreateWindow) {
            CGRect screenBounds = [UIScreen mainScreen].bounds;
            g_floatWindow = [[TrackHookWindow alloc] initWithFrame:screenBounds];
            if (@available(iOS 13.0, *)) {
                g_floatWindow.windowScene = targetScene;
            }
            g_floatWindow.windowLevel = UIWindowLevelStatusBar + 10;
            g_floatWindow.backgroundColor = [UIColor clearColor];
            g_floatWindow.rootViewController = [UIViewController new];
            g_floatWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
            g_floatWindow.userInteractionEnabled = YES;
            g_floatWindow.hidden = NO;
            NSLog(@"TrackHook: 🪟 已创建独立悬浮窗口");
        }
        
        UIButton *oldBtn = [g_floatWindow viewWithTag:TRACK_BTN_TAG];
        if (oldBtn) [oldBtn removeFromSuperview];
        
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.tag = TRACK_BTN_TAG;
        btn.frame = CGRectMake(g_floatWindow.bounds.size.width - 70, g_floatWindow.bounds.size.height / 2, 56, 56);
        btn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.85];
        [btn setTitle:@"🛰️" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:24];
        btn.layer.cornerRadius = 28;
        btn.layer.borderWidth = 1.0;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
        btn.layer.shadowColor = [UIColor blackColor].CGColor;
        btn.layer.shadowOffset = CGSizeMake(0, 2);
        btn.layer.shadowOpacity = 0.3;
        btn.userInteractionEnabled = YES;
        
        [btn addTarget:self action:@selector(th_onBtnClick) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(th_handlePan:)];
        [btn addGestureRecognizer:pan];
        [g_floatWindow addSubview:btn];
        NSLog(@"TrackHook: ✅ 悬浮按钮已添加到独立窗口");
    });
}

%new
- (void)th_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint translation = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x + translation.x, v.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:v.superview];
    CGFloat margin = 28;
    CGRect safeArea = v.superview.bounds;
    v.center = CGPointMake(MAX(margin, MIN(safeArea.size.width - margin, v.center.x)),
                           MAX(margin, MIN(safeArea.size.height - margin, v.center.y)));
}

%new
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_floatWindow) {
            g_floatWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            g_floatWindow.windowLevel = UIWindowLevelStatusBar + 1;
            g_floatWindow.backgroundColor = [UIColor clearColor];
            g_floatWindow.userInteractionEnabled = YES;
            g_floatWindow.hidden = NO;
        }
        for (UIView *subview in g_floatWindow.subviews) {
            if ([subview isKindOfClass:[UILabel class]] && subview.tag == 9999) {
                [subview removeFromSuperview];
            }
        }
        UILabel *lab = [[UILabel alloc] init];
        lab.tag = 9999;
        lab.text = msg;
        lab.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        lab.textColor = [UIColor whiteColor];
        lab.layer.cornerRadius = 10;
        lab.clipsToBounds = YES;
        lab.numberOfLines = 0;
        CGSize textSize = [lab sizeThatFits:CGSizeMake(g_floatWindow.bounds.size.width * 0.7, 100)];
        lab.bounds = CGRectMake(0, 0, textSize.width + 30, textSize.height + 20);
        lab.center = CGPointMake(g_floatWindow.bounds.size.width / 2, g_floatWindow.bounds.size.height * 0.85);
        [g_floatWindow addSubview:lab];
        lab.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{ lab.alpha = 1.0; }];
        [UIView animateWithDuration:0.3 delay:dur options:0 animations:^{ lab.alpha = 0; } completion:^(BOOL finished) { 
            if (finished) [lab removeFromSuperview]; 
        }];
    });
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    NSString *clsName = NSStringFromClass([self class]);
    NSArray *targetKeywords = @[@"Detail", @"User", @"Profile", @"Homepage", @"Info", @"HomePage", @"PersonData", @"HomeView", @"Selection", @"List", @"Explore"];
    BOOL shouldInject = NO;
    for (NSString *keyword in targetKeywords) {
        if ([clsName containsString:keyword]) {
            shouldInject = YES;
            break;
        }
    }
    if (shouldInject) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self th_addBtn];
        });
    } else {
        if (g_floatWindow) {
            UIView *btn = [g_floatWindow viewWithTag:TRACK_BTN_TAG];
            if (btn) {
                [btn removeFromSuperview];
                NSLog(@"TrackHook: 📍 在非目标页面移除按钮");
            }
        }
    }
}
%end

%hook NSMutableURLRequest

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    NSLog(@"TrackHook: 🏷️ 设置HTTP头字段: %@ = %@...", field, 
          [value substringToIndex:MIN(30, value.length)]);
    
    if ([field isEqualToString:@"Authorization"] && [value hasPrefix:@"Basic "]) {
        NSString *token = [value substringFromIndex:6];
        if (token.length > 0) {
            [g_dataLock lock];
            g_bluedBasicToken = [token copy];
            [g_dataLock unlock];
            NSLog(@"TrackHook: ✅ 捕获到Basic Token (长度: %lu)", (unsigned long)token.length);
        }
    }
    
    %orig(value, field);
}

%end

%hook NSURLConnection

+ (NSData *)sendSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse * _Nullable *)response error:(NSError * _Nullable *)error {
    NSLog(@"TrackHook: 🔄 同步请求: %@", request.URL.absoluteString);
    
    [self processRequestData:request responseData:nil];
    NSData *responseData = %orig(request, response, error);
    
    if (responseData) {
        [self processRequestData:request responseData:responseData];
    }
    
    return responseData;
}

+ (void)sendAsynchronousRequest:(NSURLRequest *)request queue:(NSOperationQueue *)queue completionHandler:(void (^)(NSURLResponse *, NSData *, NSError *))handler {
    
    NSLog(@"TrackHook: 🔄 异步请求: %@", request.URL.absoluteString);
    
    [self processRequestData:request responseData:nil];
    
    void (^customHandler)(NSURLResponse *, NSData *, NSError *) = ^(NSURLResponse *response, NSData *data, NSError *err) {
        if (data) {
            [self processRequestData:request responseData:data];
        }
        if (handler) handler(response, data, err);
    };
    
    %orig(request, queue, customHandler);
}

%new
+ (void)processRequestData:(NSURLRequest *)request responseData:(NSData *)responseData {
    NSString *urlString = request.URL.absoluteString;
    NSString *host = request.URL.host;
    
    BOOL shouldProcess = [self isTargetRequest:urlString host:host];
    
    if (shouldProcess) {
        NSLog(@"TrackHook: 📡 捕获NSURLConnection请求: %@", urlString);
        
        // 捕获Authorization
        NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
        if (auth && [auth hasPrefix:@"Basic "]) {
            NSString *token = [auth substringFromIndex:6];
            [g_dataLock lock];
            g_bluedBasicToken = [token copy];
            NSLog(@"TrackHook: ✅ 从NSURLConnection捕获Token");
            [g_dataLock unlock];
        }
        
        // 从URL参数提取数据
        [self enhancedExtractDataFromURL:urlString request:request];
        
        // 保存请求信息
        [g_dataLock lock];
        NSMutableDictionary *reqInfo = [NSMutableDictionary dictionary];
        reqInfo[@"url"] = urlString;
        reqInfo[@"timestamp"] = [NSDate date];
        reqInfo[@"method"] = request.HTTPMethod ?: @"GET";
        
        // 保存请求头
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        [request.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            if ([key isEqualToString:@"Authorization"]) {
                headers[key] = [value substringToIndex:MIN(30, value.length)] ?: @"[已截断]";
            } else {
                headers[key] = value;
            }
        }];
        reqInfo[@"headers"] = headers;
        
        // 保存参数
        if ([urlString containsString:@"?"]) {
            NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
            NSMutableDictionary *params = [NSMutableDictionary dictionary];
            for (NSURLQueryItem *item in components.queryItems) {
                params[item.name] = item.value ?: @"";
            }
            reqInfo[@"params"] = params;
        }
        
        NSString *reqKey = [NSString stringWithFormat:@"%lu", (unsigned long)[urlString hash]];
        g_capturedRequests[reqKey] = reqInfo;
        
        // 只保留最近20个请求
        if (g_capturedRequests.count > 20) {
            NSArray *sortedKeys = [[g_capturedRequests allKeys] sortedArrayUsingSelector:@selector(compare:)];
            NSString *oldestKey = sortedKeys.firstObject;
            [g_capturedRequests removeObjectForKey:oldestKey];
        }
        [g_dataLock unlock];
        
        // 处理响应数据
        if (responseData && responseData.length > 0) {
            [self processResponseData:responseData forRequest:request];
        }
    }
}

%new
+ (void)processResponseData:(NSData *)data forRequest:(NSURLRequest *)request {
    @try {
        if (data.length > 0) {
            NSString *contentType = request.allHTTPHeaderFields[@"Content-Type"];
            if ([contentType containsString:@"application/json"] || [contentType containsString:@"text/json"]) {
                NSError *error = nil;
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                if (!error && json) {
                    NSLog(@"TrackHook: 📦 JSON响应: %@", json);
                    
                    // 提取用户数据
                    [self extractUserDataFromJSON:json];
                    
                    // 提取距离信息
                    [self extractDistanceFromJSON:json];
                    
                    // 提取用户列表
                    [self extractUserListFromJSON:json];
                } else if (error) {
                    NSLog(@"TrackHook: ❌ JSON解析失败: %@", error);
                }
            } else if ([contentType containsString:@"text/"]) {
                NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (text && text.length > 0) {
                    NSLog(@"TrackHook: 📄 文本响应: %@", [text substringToIndex:MIN(200, text.length)]);
                }
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: ❌ 响应处理异常: %@", exception);
    }
}

%new
+ (void)extractUserDataFromJSON:(id)json {
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = json;
        
        // 尝试提取用户ID
        NSArray *uidKeys = @[@"uid", @"user_id", @"userId", @"union_uid", @"unionUid", @"id"];
        for (NSString *key in uidKeys) {
            id value = dict[key];
            if (value) {
                NSString *uidStr = nil;
                if ([value isKindOfClass:[NSString class]]) {
                    uidStr = value;
                } else if ([value isKindOfClass:[NSNumber class]]) {
                    uidStr = [value stringValue];
                }
                if (uidStr && uidStr.length >= 6 && uidStr.length <= 10) {
                    [g_dataLock lock];
                    g_currentTargetUid = [uidStr copy];
                    NSLog(@"TrackHook: 🔍 从JSON提取用户ID: %@", uidStr);
                    
                    // 保存用户数据
                    if (!g_userData[uidStr]) {
                        g_userData[uidStr] = [NSMutableDictionary dictionary];
                    }
                    
                    // 提取用户信息
                    NSMutableDictionary *userInfo = g_userData[uidStr];
                    NSArray *infoKeys = @[@"nickname", @"name", @"username", @"avatar", @"distance", @"lat", @"lng", @"latitude", @"longitude", @"location"];
                    
                    for (NSString *infoKey in infoKeys) {
                        id infoValue = dict[infoKey];
                        if (infoValue && infoValue != [NSNull null]) {
                            userInfo[infoKey] = infoValue;
                        }
                    }
                    
                    [g_dataLock unlock];
                    return;
                }
            }
        }
        
        // 递归搜索
        for (id value in dict.allValues) {
            [self extractUserDataFromJSON:value];
        }
    } else if ([json isKindOfClass:[NSArray class]]) {
        for (id item in json) {
            [self extractUserDataFromJSON:item];
        }
    }
}

%new
+ (void)extractDistanceFromJSON:(id)json {
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = json;
        
        for (NSString *key in dict.allKeys) {
            if ([key.lowercaseString containsString:@"distance"] || 
                [key.lowercaseString containsString:@"dis"] ||
                [key.lowercaseString containsString:@"range"]) {
                id value = dict[key];
                if ([value isKindOfClass:[NSNumber class]]) {
                    double distance = [value doubleValue];
                    if (distance > 0) {
                        [g_dataLock lock];
                        g_targetDistance = distance;
                        NSLog(@"TrackHook: 📏 距离: %.2f km", distance);
                        [g_dataLock unlock];
                        return;
                    }
                } else if ([value isKindOfClass:[NSString class]]) {
                    NSString *strValue = (NSString *)value;
                    if ([strValue containsString:@"km"]) {
                        NSScanner *scanner = [NSScanner scannerWithString:strValue];
                        double distance = 0.0;
                        if ([scanner scanDouble:&distance] && distance > 0) {
                            [g_dataLock lock];
                            g_targetDistance = distance;
                            NSLog(@"TrackHook: 📏 从字符串提取距离: %.2f km", distance);
                            [g_dataLock unlock];
                            return;
                        }
                    }
                }
            }
        }
        
        for (id value in dict.allValues) {
            [self extractDistanceFromJSON:value];
        }
    } else if ([json isKindOfClass:[NSArray class]]) {
        for (id item in json) {
            [self extractDistanceFromJSON:item];
        }
    }
}

%new
+ (void)extractUserListFromJSON:(id)json {
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = json;
        
        // 查找用户列表
        NSArray *listKeys = @[@"users", @"list", @"data", @"items", @"results"];
        for (NSString *key in listKeys) {
            id value = dict[key];
            if ([value isKindOfClass:[NSArray class]]) {
                NSArray *userList = value;
                NSLog(@"TrackHook: 👥 发现用户列表，共%lu个用户", (unsigned long)userList.count);
                
                for (id user in userList) {
                    [self extractUserDataFromJSON:user];
                }
            }
        }
        
        // 递归搜索
        for (id value in dict.allValues) {
            [self extractUserListFromJSON:value];
        }
    } else if ([json isKindOfClass:[NSArray class]]) {
        // 整个响应就是数组
        NSArray *userList = json;
        NSLog(@"TrackHook: 👥 发现用户列表，共%lu个用户", (unsigned long)userList.count);
        
        for (id user in userList) {
            [self extractUserDataFromJSON:user];
        }
    }
}

%new
+ (BOOL)isTargetRequest:(NSString *)urlString host:(NSString *)host {
    if (!host && !urlString) return NO;
    
    // 目标主机列表
    NSArray *targetHosts = @[@"198.18.1.70", @"198.18.1.76", @"198.18.3.228", 
                            @"social.irisgw.cn", @"pay.irisgw.cn", @"blued.cn", @"irisgw.cn",
                            @"dualstack-restios.amap.com", @"restapi.amap.com", @"lbs.amap.com"];
    
    for (NSString *targetHost in targetHosts) {
        if ([host containsString:targetHost]) {
            return YES;
        }
    }
    
    // 匹配URL特征
    NSArray *urlPatterns = @[
        @"target_uid=", @"latitude=", @"longitude=", @"lat=", @"lng=",
        @"/users/", @"/pay/", @"location=", @"regeocode", @"selection",
        @"nearby", @"explore", @"discover", @"recommend", @"match"
    ];
    
    for (NSString *pattern in urlPatterns) {
        if ([urlString containsString:pattern]) {
            return YES;
        }
    }
    
    return NO;
}

%new
+ (void)extractDataFromURL:(NSString *)urlString {
    if (!urlString) return;
    
    // 解析URL参数
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    for (NSURLQueryItem *item in components.queryItems) {
        // 提取用户ID
        if ([item.name isEqualToString:@"target_uid"] || 
            [item.name isEqualToString:@"uid"] || 
            [item.name isEqualToString:@"user_id"]) {
            NSString *uid = item.value;
            if (uid && uid.length >= 6 && uid.length <= 10) {
                [g_dataLock lock];
                g_currentTargetUid = [uid copy];
                NSLog(@"TrackHook: 🔍 从URL参数捕获用户ID: %@", uid);
                [g_dataLock unlock];
            }
        }
        // 提取坐标
        else if ([item.name isEqualToString:@"latitude"] || [item.name isEqualToString:@"lat"]) {
            double lat = [item.value doubleValue];
            if (fabs(lat) > 0.001) {
                [g_dataLock lock];
                g_currentLat = lat;
                NSLog(@"TrackHook: 📍 纬度: %.6f", lat);
                [g_dataLock unlock];
            }
        }
        else if ([item.name isEqualToString:@"longitude"] || [item.name isEqualToString:@"lon"] || 
                 [item.name isEqualToString:@"lng"]) {
            double lng = [item.value doubleValue];
            if (fabs(lng) > 0.001) {
                [g_dataLock lock];
                g_currentLng = lng;
                NSLog(@"TrackHook: 📍 经度: %.6f", lng);
                [g_dataLock unlock];
            }
        }
    }
}

%new
+ (void)enhancedExtractDataFromURL:(NSString *)urlString request:(NSURLRequest *)request {
    if (!urlString) return;
    
    NSLog(@"TrackHook: 🔍 分析URL: %@", urlString);
    
    // 使用更全面的URL解析
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    
    // 提取所有参数
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        params[item.name] = item.value ?: @"";
        
        // 特别关注关键参数
        if ([item.name isEqualToString:@"extra_info"]) {
            NSLog(@"TrackHook: 🔐 发现加密参数extra_info，长度: %lu", (unsigned long)item.value.length);
        }
        
        // 设备信息参数
        if ([item.name isEqualToString:@"idfa"] || 
            [item.name isEqualToString:@"make"] || 
            [item.name isEqualToString:@"model"]) {
            NSLog(@"TrackHook: 📱 设备信息: %@ = %@", item.name, item.value);
        }
        
        // 时间戳参数
        if ([item.name isEqualToString:@"boot_mark"] || [item.name isEqualToString:@"update_mark"]) {
            NSLog(@"TrackHook: ⏱️ 时间戳参数: %@ = %@", item.name, item.value);
        }
    }
    
    // 从URL路径提取用户ID
    NSString *path = components.path;
    if ([path containsString:@"/users/"]) {
        NSArray *pathComponents = [path componentsSeparatedByString:@"/"];
        for (NSInteger i = 0; i < pathComponents.count; i++) {
            NSString *component = pathComponents[i];
            if ([component isEqualToString:@"users"] && i+1 < pathComponents.count) {
                NSString *nextComponent = pathComponents[i+1];
                // 检查是否为数字
                NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
                if ([nextComponent rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
                    if (nextComponent.length >= 6 && nextComponent.length <= 10) {
                        [g_dataLock lock];
                        g_currentTargetUid = [nextComponent copy];
                        NSLog(@"TrackHook: 🔍 从URL路径捕获用户ID: %@", nextComponent);
                        [g_dataLock unlock];
                        break;
                    }
                }
            }
        }
    }
    
    // 从查询参数提取用户ID
    [self extractDataFromURL:urlString];
    
    // 提取请求体中的数据
    if (request.HTTPBody && request.HTTPBody.length > 0) {
        @try {
            NSError *error = nil;
            id bodyDict = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:&error];
            if (!error && [bodyDict isKindOfClass:[NSDictionary class]]) {
                NSLog(@"TrackHook: 📦 请求体JSON: %@", bodyDict);
                
                // 从请求体提取用户ID
                NSDictionary *dict = (NSDictionary *)bodyDict;
                NSArray *uidKeys = @[@"uid", @"user_id", @"userId", @"target_uid"];
                for (NSString *key in uidKeys) {
                    id value = dict[key];
                    if (value) {
                        NSString *uidStr = nil;
                        if ([value isKindOfClass:[NSString class]]) {
                            uidStr = value;
                        } else if ([value isKindOfClass:[NSNumber class]]) {
                            uidStr = [value stringValue];
                        }
                        if (uidStr && uidStr.length >= 6 && uidStr.length <= 10) {
                            [g_dataLock lock];
                            g_currentTargetUid = [uidStr copy];
                            NSLog(@"TrackHook: 🔍 从请求体捕获用户ID: %@", uidStr);
                            [g_dataLock unlock];
                            break;
                        }
                    }
                }
                
                // 从请求体提取坐标
                NSArray *latKeys = @[@"latitude", @"lat"];
                NSArray *lngKeys = @[@"longitude", @"lng", @"lon"];
                
                for (NSString *key in latKeys) {
                    id value = dict[key];
                    if (value) {
                        double lat = 0.0;
                        if ([value isKindOfClass:[NSNumber class]]) {
                            lat = [value doubleValue];
                        } else if ([value isKindOfClass:[NSString class]]) {
                            lat = [value doubleValue];
                        }
                        if (fabs(lat) > 0.001) {
                            [g_dataLock lock];
                            g_currentLat = lat;
                            NSLog(@"TrackHook: 📍 从请求体纬度: %.6f", lat);
                            [g_dataLock unlock];
                            break;
                        }
                    }
                }
                
                for (NSString *key in lngKeys) {
                    id value = dict[key];
                    if (value) {
                        double lng = 0.0;
                        if ([value isKindOfClass:[NSNumber class]]) {
                            lng = [value doubleValue];
                        } else if ([value isKindOfClass:[NSString class]]) {
                            lng = [value doubleValue];
                        }
                        if (fabs(lng) > 0.001) {
                            [g_dataLock lock];
                            g_currentLng = lng;
                            NSLog(@"TrackHook: 📍 从请求体经度: %.6f", lng);
                            [g_dataLock unlock];
                            break;
                        }
                    }
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"TrackHook: ❌ 解析请求体异常: %@", exception);
        }
    }
}
%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *res, NSError *err))completionHandler {
    
    [self processRequestData:request responseData:nil];
    
    void (^customCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (completionHandler) {
            completionHandler(data, response, error);
        }
        
        // 处理响应
        if (data && data.length > 0) {
            [NSURLConnection processResponseData:data forRequest:request];
        }
    };
    
    return %orig(request, customCompletionHandler);
}

%new
- (void)processRequestData:(NSURLRequest *)request responseData:(NSData *)responseData {
    [NSURLConnection processRequestData:request responseData:responseData];
}

%end
