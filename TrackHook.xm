#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

// ===================== 全局变量声明 =====================
static dispatch_semaphore_t g_dataLock = NULL;
static NSMutableDictionary *g_userInfoDict = nil;
static NSString *g_currentTargetUid = nil;
static NSString *g_bluedBasicToken = nil;
static double g_myLat = 0.0;
static double g_myLng = 0.0;
static double g_targetLat = 0.0;
static double g_targetLng = 0.0;
static double g_targetDistance = -1.0;
static UIButton *g_floatBtn = nil;

// ===================== 类别方法声明 =====================
@interface NSURLConnection (TrackHookMethods)
+ (BOOL)isTargetRequest:(NSString *)urlString host:(NSString *)host;
+ (void)extractMyLocationFromURL:(NSString *)urlString;
@end

@interface NSURLSession (TrackHookMethods)
- (void)processTargetRequest:(NSURLRequest *)request;
- (void)extractTargetUidFromURL:(NSString *)urlString;
- (void)parseResponseData:(NSData *)data forRequest:(NSURLRequest *)request;
- (void)parseNearbyUserList:(NSDictionary *)json;
- (void)parseUserDetail:(NSDictionary *)json;
@end

@interface UIViewController (TrackHookMethods)
- (void)addFloatButton;
- (void)th_onPan:(UIPanGestureRecognizer *)pan;
- (void)th_onBtnClick;
- (NSString *)th_extractUserIdFromUI;
- (NSString *)th_searchUidInView:(UIView *)view;
- (void)th_showToast:(NSString *)message duration:(NSTimeInterval)duration;
@end
// ===================== 类别声明结束 =====================

%hook NSURLConnection

%new
+ (BOOL)isTargetRequest:(NSString *)urlString host:(NSString *)host {
    if (!host && !urlString) return NO;
    
    // 最高优先级：精准匹配附近用户核心接口
    if ([urlString containsString:@"/users"] && 
        ([host containsString:@"social.irisgw.cn"] || [host hasPrefix:@"198.18."]) &&
        ([urlString containsString:@"sort_by=nearby"] || [urlString containsString:@"source=map"])) {
        NSLog(@"TrackHook: ✅ 命中附近用户核心接口");
        return YES;
    }
    
    // 匹配用户详情页接口
    if ([urlString containsString:@"/users/"] && 
        ([host containsString:@"social.irisgw.cn"] || [host hasPrefix:@"198.18."])) {
        NSLog(@"TrackHook: ✅ 命中用户详情页接口");
        return YES;
    }
    
    // 全量匹配Blued服务端IP段
    if ([host hasPrefix:@"198.18."]) return YES;
    
    // 全量匹配Blued业务域名
    NSArray *targetHosts = @[
        @"moments.irisgw.cn",
        @"social.irisgw.cn", 
        @"pay.irisgw.cn", 
        @"blued.cn", 
        @"irisgw.cn"
    ];
    for (NSString *targetHost in targetHosts) {
        if ([host containsString:targetHost]) return YES;
    }
    
    // 匹配带用户核心数据的接口路径
    NSArray *urlPatterns = @[
        @"target_uid=", @"uid=", @"user_id=", 
        @"latitude=", @"longitude=", 
        @"/pay/", @"/blued/verification", @"red-rank"
    ];
    for (NSString *pattern in urlPatterns) {
        if ([urlString containsString:pattern]) return YES;
    }
    
    return NO;
}

%new
+ (void)extractMyLocationFromURL:(NSString *)urlString {
    if (!urlString || urlString.length == 0) return;
    
    // 从URL参数中提取自身坐标
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"latitude"]) {
            double lat = [item.value doubleValue];
            if (fabs(lat) > 0.001) {
                dispatch_semaphore_wait(g_dataLock, DISPATCH_TIME_FOREVER);
                g_myLat = lat;
                dispatch_semaphore_signal(g_dataLock);
                NSLog(@"TrackHook: ✅ 抓取自身纬度: %.6f", lat);
            }
        }
        if ([item.name isEqualToString:@"longitude"]) {
            double lng = [item.value doubleValue];
            if (fabs(lng) > 0.001) {
                dispatch_semaphore_wait(g_dataLock, DISPATCH_TIME_FOREVER);
                g_myLng = lng;
                dispatch_semaphore_signal(g_dataLock);
                NSLog(@"TrackHook: ✅ 抓取自身经度: %.6f", lng);
            }
        }
    }
}

%end

%hook NSURLSession

%new
- (void)processTargetRequest:(NSURLRequest *)request {
    NSString *urlString = request.URL.absoluteString;
    NSString *host = request.URL.host;
    
    // 过滤并处理目标请求
    if (![NSURLConnection isTargetRequest:urlString host:host]) return;
    
    // 1. 抓取认证Token
    NSString *authHeader = request.allHTTPHeaderFields[@"Authorization"];
    if (authHeader && [authHeader hasPrefix:@"Basic "]) {
        NSString *token = [authHeader substringFromIndex:6];
        if (token.length > 0) {
            dispatch_semaphore_wait(g_dataLock, DISPATCH_TIME_FOREVER);
            g_bluedBasicToken = [token copy];
            dispatch_semaphore_signal(g_dataLock);
            NSLog(@"TrackHook: ✅ 成功抓取Blued Basic Token");
        }
    }
    
    // 2. 提取自身坐标
    [NSURLConnection extractMyLocationFromURL:urlString];
    
    // 3. 提取URL中的目标用户UID
    [self extractTargetUidFromURL:urlString];
}

%new
- (void)extractTargetUidFromURL:(NSString *)urlString {
    if (!urlString || urlString.length == 0) return;
    
    // 匹配 /users/123456 格式的用户详情页URL
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"/users/(\\d+)" options:0 error:nil];
    NSTextCheckingResult *result = [regex firstMatchInString:urlString options:0 range:NSMakeRange(0, urlString.length)];
    if (result && result.numberOfRanges > 1) {
        NSString *uid = [urlString substringWithRange:[result rangeAtIndex:1]];
        if (uid.length >= 6) {
            dispatch_semaphore_wait(g_dataLock, DISPATCH_TIME_FOREVER);
            g_currentTargetUid = [uid copy];
            dispatch_semaphore_signal(g_dataLock);
            NSLog(@"TrackHook: ✅ 从URL提取到目标用户UID: %@", uid);
        }
    }
}

%new
- (void)parseResponseData:(NSData *)data forRequest:(NSURLRequest *)request {
    if (!data || data.length == 0) return;
    
    NSString *urlString = request.URL.absoluteString;
    NSString *host = request.URL.host;
    if (![NSURLConnection isTargetRequest:urlString host:host]) return;
    
    // 解析JSON数据
    NSError *jsonError = nil;
    id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || !jsonObj) {
        NSLog(@"TrackHook: ❌ JSON解析失败: %@", jsonError.localizedDescription);
        return;
    }
    
    // 校验接口返回状态
    if (![jsonObj isKindOfClass:[NSDictionary class]] || [jsonObj[@"code"] intValue] != 200) {
        NSLog(@"TrackHook: ❌ 接口返回失败");
        return;
    }
    
    // 1. 解析附近用户列表接口
    if ([urlString containsString:@"/users"] && ([urlString containsString:@"sort_by=nearby"] || [urlString containsString:@"source=map"])) {
        [self parseNearbyUserList:jsonObj];
    }
    // 2. 解析用户详情页接口
    else if ([urlString containsString:@"/users/"]) {
        [self parseUserDetail:jsonObj];
    }
}

%new
- (void)parseNearbyUserList:(NSDictionary *)json {
    NSArray *userList = json[@"data"];
    if (!userList || ![userList isKindOfClass:[NSArray class]] || userList.count == 0) {
        NSLog(@"TrackHook: ❌ 附近用户列表为空");
        return;
    }
    
    dispatch_semaphore_wait(g_dataLock, DISPATCH_TIME_FOREVER);
    for (NSDictionary *user in userList) {
        // 过滤广告数据，只处理真实用户
        NSNumber *isAds = user[@"is_ads"];
        if (isAds && isAds.intValue == 1) continue;
        
        // 提取用户核心信息
        NSString *uid = nil;
        if (user[@"uid"]) uid = [user[@"uid"] stringValue];
        else if (user[@"user_id"]) uid = [user[@"user_id"] stringValue];
        else if (user[@"id"]) uid = [user[@"id"] stringValue];
        
        if (!uid || uid.length < 6) continue;
        
        double distance = [user[@"distance"] doubleValue];
        NSString *name = user[@"name"] ?: @"未知用户";
        NSNumber *age = user[@"age"] ?: @0;
        double lat = [user[@"latitude"] doubleValue];
        double lng = [user[@"longitude"] doubleValue];
        
        // 存储到全局字典
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        userInfo[@"uid"] = uid;
        userInfo[@"name"] = name;
        userInfo[@"age"] = age;
        userInfo[@"distance"] = @(distance);
        if (fabs(lat) > 0.001 && fabs(lng) > 0.001) {
            userInfo[@"latitude"] = @(lat);
            userInfo[@"longitude"] = @(lng);
        }
        
        [g_userInfoDict setObject:userInfo forKey:uid];
        NSLog(@"TrackHook: ✅ 存储用户 %@(%@) 数据: 距离%.2fkm", name, uid, distance);
    }
    
    // 兜底解析直播用户数据
    NSArray *liveUsers = json[@"extra"][@"adms_operating"];
    if (liveUsers && [liveUsers isKindOfClass:[NSArray class]]) {
        for (NSDictionary *liveUser in liveUsers) {
            NSString *uid = [liveUser[@"uid"] stringValue];
            if (!uid || uid.length < 6) continue;
            
            double distance = [liveUser[@"distance"] doubleValue];
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            userInfo[@"uid"] = uid;
            userInfo[@"name"] = liveUser[@"name"] ?: @"直播用户";
            userInfo[@"age"] = liveUser[@"age"] ?: @0;
            userInfo[@"distance"] = @(distance);
            
            [g_userInfoDict setObject:userInfo forKey:uid];
            NSLog(@"TrackHook: ✅ 存储直播用户 %@ 数据: 距离%.2fkm", uid, distance);
        }
    }
    dispatch_semaphore_signal(g_dataLock);
    
    NSLog(@"TrackHook: 🎯 本次共成功抓取 %lu 个附近用户完整数据", (unsigned long)userList.count);
}

%new
- (void)parseUserDetail:(NSDictionary *)json {
    NSDictionary *userData = json[@"data"];
    if (!userData || ![userData isKindOfClass:[NSDictionary class]]) {
        NSLog(@"TrackHook: ❌ 用户详情数据为空");
        return;
    }
    
    // 提取用户详情核心数据
    NSString *uid = nil;
    if (userData[@"uid"]) uid = [userData[@"uid"] stringValue];
    else if (userData[@"user_id"]) uid = [userData[@"user_id"] stringValue];
    
    if (!uid || uid.length < 6) return;
    
    double lat = [userData[@"latitude"] doubleValue];
    double lng = [userData[@"longitude"] doubleValue];
    double distance = [userData[@"distance"] doubleValue];
    
    if (fabs(lat) < 0.001 || fabs(lng) < 0.001) {
        NSLog(@"TrackHook: ❌ 用户详情无坐标数据");
        return;
    }
    
    // 更新到全局字典与当前目标数据
    dispatch_semaphore_wait(g_dataLock, DISPATCH_TIME_FOREVER);
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:g_userInfoDict[uid] ?: @{}];
    userInfo[@"latitude"] = @(lat);
    userInfo[@"longitude"] = @(lng);
    userInfo[@"distance"] = @(distance);
    [g_userInfoDict setObject:userInfo forKey:uid];
    
    // 更新当前目标数据
    g_targetLat = lat;
    g_targetLng = lng;
    g_targetDistance = distance;
    g_currentTargetUid = [uid copy];
    dispatch_semaphore_signal(g_dataLock);
    
    NSLog(@"TrackHook: ✅ 从详情页拿到用户 %@ 完整坐标: %.6f, %.6f 距离: %.2fkm", uid, lat, lng, distance);
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    // 过滤并处理目标请求
    [self processTargetRequest:request];
    
    // 拦截回调，解析响应数据
    void (^customCompletion)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error) {
            [self parseResponseData:data forRequest:request];
        }
        // 执行原回调
        if (completionHandler) {
            completionHandler(data, response, error);
        }
    };
    
    return %orig(request, customCompletion);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    [self processTargetRequest:request];
    
    void (^customCompletion)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error) {
            [self parseResponseData:data forRequest:request];
        }
        if (completionHandler) {
            completionHandler(data, response, error);
        }
    };
    
    return %orig(url, customCompletion);
}

%end

%hook UIViewController

%new
- (void)addFloatButton {
    // 避免重复创建
    if (g_floatBtn && g_floatBtn.superview) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
        if (!keyWindow) return;
        
        // 创建悬浮按钮
        g_floatBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        g_floatBtn.frame = CGRectMake(keyWindow.bounds.size.width - 70, keyWindow.bounds.size.height - 200, 60, 60);
        g_floatBtn.backgroundColor = [UIColor systemBlueColor];
        [g_floatBtn setTitle:@"定位" forState:UIControlStateNormal];
        [g_floatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        g_floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        g_floatBtn.layer.cornerRadius = 30;
        g_floatBtn.layer.masksToBounds = YES;
        g_floatBtn.layer.shadowColor = [UIColor blackColor].CGColor;
        g_floatBtn.layer.shadowOpacity = 0.3;
        g_floatBtn.layer.shadowRadius = 5;
        g_floatBtn.layer.shadowOffset = CGSizeMake(0, 2);
        
        // 添加点击事件
        [g_floatBtn addTarget:self action:@selector(th_onBtnClick) forControlEvents:UIControlEventTouchUpInside];
        
        // 添加拖拽手势
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(th_onPan:)];
        [g_floatBtn addGestureRecognizer:pan];
        
        // 添加到窗口
        [keyWindow addSubview:g_floatBtn];
        [keyWindow bringSubviewToFront:g_floatBtn];
        
        NSLog(@"TrackHook: ✅ 悬浮按钮创建成功");
    });
}

%new
- (void)th_onPan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    if (!btn) return;
    
    CGPoint translation = [pan translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:btn.superview];
    
    // 松手后自动贴边
    if (pan.state == UIGestureRecognizerStateEnded) {
        UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
        CGFloat margin = 10;
        CGFloat centerX = btn.center.x;
        CGFloat centerY = btn.center.y;
        
        // 左右贴边
        if (centerX < keyWindow.bounds.size.width / 2) {
            centerX = btn.bounds.size.width / 2 + margin;
        } else {
            centerX = keyWindow.bounds.size.width - btn.bounds.size.width / 2 - margin;
        }
        
        // 上下边界限制
        CGFloat topLimit = btn.bounds.size.height / 2 + 50;
        CGFloat bottomLimit = keyWindow.bounds.size.height - btn.bounds.size.height / 2 - 50;
        if (centerY < topLimit) centerY = topLimit;
        if (centerY > bottomLimit) centerY = bottomLimit;
        
        // 动画贴边
        [UIView animateWithDuration:0.2 animations:^{
            btn.center = CGPointMake(centerX, centerY);
        }];
    }
}

%new
- (void)th_onBtnClick {
    NSLog(@"TrackHook: 🎯 悬浮按钮被点击");
    
    // 1. 先从UI提取当前用户UID
    NSString *currentUid = [self th_extractUserIdFromUI];
    dispatch_semaphore_wait(g_dataLock, DISPATCH_TIME_FOREVER);
    if (currentUid && currentUid.length >= 6) {
        g_currentTargetUid = [currentUid copy];
    }
    NSString *targetUid = [g_currentTargetUid copy];
    NSDictionary *userInfo = [g_userInfoDict objectForKey:targetUid];
    NSString *token = [g_bluedBasicToken copy];
    double myLat = g_myLat;
    double myLng = g_myLng;
    dispatch_semaphore_signal(g_dataLock);
    
    // 2. 基础校验
    if (!targetUid || targetUid.length < 6) {
        [self th_showToast:@"未获取到用户ID\n请先打开用户主页" duration:2.0];
        return;
    }
    if (!userInfo) {
        [self th_showToast:@"未找到该用户数据\n请先刷新附近列表" duration:3.0];
        return;
    }
    
    // 3. 提取用户完整数据
    NSString *name = userInfo[@"name"] ?: @"未知用户";
    NSNumber *age = userInfo[@"age"] ?: @0;
    double distance = [userInfo[@"distance"] doubleValue];
    double targetLat = [userInfo[@"latitude"] doubleValue];
    double targetLng = [userInfo[@"longitude"] doubleValue];
    
    // 4. 拼接展示内容
    NSMutableString *resStr = [NSMutableString string];
    [resStr appendFormat:@"昵称: %@\n", name];
    [resStr appendFormat:@"年龄: %@\n", age];
    [resStr appendFormat:@"用户ID: %@\n", targetUid];
    [resStr appendFormat:@"距离: %.2f km\n", distance];
    
    if (fabs(targetLat) > 0.001 && fabs(targetLng) > 0.001) {
        [resStr appendFormat:@"\n目标纬度: %.6f\n", targetLat];
        [resStr appendFormat:@"目标经度: %.6f", targetLng];
    }
    if (fabs(myLat) > 0.001 && fabs(myLng) > 0.001) {
        [resStr appendFormat:@"\n\n我的纬度: %.6f\n我的经度: %.6f", myLat, myLng];
    }
    if (token) {
        [resStr appendFormat:@"\n\nToken状态: 已获取"];
    } else {
        [resStr appendFormat:@"\n\nToken状态: 未获取"];
    }
    
    // 5. 弹窗展示
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"用户定位信息" 
                                                                     message:resStr 
                                                              preferredStyle:UIAlertControllerStyleAlert];
    
    // 复制坐标按钮
    if (fabs(targetLat) > 0.001 && fabs(targetLng) > 0.001) {
        [alert addAction:[UIAlertAction actionWithTitle:@"复制目标坐标" 
                                                     style:UIAlertActionStyleDefault 
                                                   handler:^(UIAlertAction *action) {
            NSString *coord = [NSString stringWithFormat:@"%.6f, %.6f", targetLat, targetLng];
            [[UIPasteboard generalPasteboard] setString:coord];
            [self th_showToast:@"目标坐标已复制" duration:1.0];
        }]];
    }
    
    // 复制用户ID按钮
    [alert addAction:[UIAlertAction actionWithTitle:@"复制用户ID" 
                                                 style:UIAlertActionStyleDefault 
                                               handler:^(UIAlertAction *action) {
        [[UIPasteboard generalPasteboard] setString:targetUid];
        [self th_showToast:@"用户ID已复制" duration:1.0];
    }]];
    
    // 确定按钮
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" 
                                                 style:UIAlertActionStyleCancel 
                                               handler:nil]];
    
    // 主线程弹出弹窗
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:alert animated:YES completion:nil];
    });
}

%new
- (NSString *)th_extractUserIdFromUI {
    // 递归遍历UI，提取用户UID（适配Blued主流版本的UI结构）
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    return [self th_searchUidInView:keyWindow];
}

%new
- (NSString *)th_searchUidInView:(UIView *)view {
    if (!view) return nil;
    
    // 遍历子视图
    for (UIView *subView in view.subviews) {
        // 检查UILabel中的纯数字UID（6位以上）
        if ([subView isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)subView;
            NSString *text = label.text;
            if (text.length >= 6) {
                NSCharacterSet *nonDigitSet = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
                if ([text rangeOfCharacterFromSet:nonDigitSet].location == NSNotFound) {
                    NSLog(@"TrackHook: ✅ 从UI提取到用户UID: %@", text);
                    return text;
                }
            }
        }
        // 递归遍历
        NSString *result = [self th_searchUidInView:subView];
        if (result) return result;
    }
    return nil;
}

%new
- (void)th_showToast:(NSString *)message duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
        if (!keyWindow) return;
        
        // 创建toast视图
        UIView *toastView = [[UIView alloc] init];
        toastView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        toastView.layer.cornerRadius = 10;
        toastView.layer.masksToBounds = YES;
        
        UILabel *messageLabel = [[UILabel alloc] init];
        messageLabel.text = message;
        messageLabel.textColor = [UIColor whiteColor];
        messageLabel.font = [UIFont systemFontOfSize:14];
        messageLabel.numberOfLines = 0;
        messageLabel.textAlignment = NSTextAlignmentCenter;
        
        [toastView addSubview:messageLabel];
        [keyWindow addSubview:toastView];
        [keyWindow bringSubviewToFront:toastView];
        
        // 自动布局
        messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
        toastView.translatesAutoresizingMaskIntoConstraints = NO;
        
        [NSLayoutConstraint activateConstraints:@[
            [messageLabel.topAnchor constraintEqualToAnchor:toastView.topAnchor constant:12],
            [messageLabel.leftAnchor constraintEqualToAnchor:toastView.leftAnchor constant:20],
            [messageLabel.rightAnchor constraintEqualToAnchor:toastView.rightAnchor constant:-20],
            [messageLabel.bottomAnchor constraintEqualToAnchor:toastView.bottomAnchor constant:-12],
            
            [toastView.centerXAnchor constraintEqualToAnchor:keyWindow.centerXAnchor],
            [toastView.bottomAnchor constraintEqualToAnchor:keyWindow.bottomAnchor constant:-120],
            [toastView.widthAnchor constraintLessThanOrEqualToConstant:keyWindow.bounds.size.width - 60]
        ]];
        
        // 自动消失
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                toastView.alpha = 0;
            } completion:^(BOOL finished) {
                [toastView removeFromSuperview];
            }];
        });
    });
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    // 确保悬浮按钮在主线程添加
    dispatch_async(dispatch_get_main_queue(), ^{
        [self addFloatButton];
    });
}

%end

%ctor {
    NSLog(@"TrackHook: 🚀 插件加载成功");
    
    // 初始化线程锁
    g_dataLock = dispatch_semaphore_create(1);
    
    // 初始化全局字典
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_userInfoDict = [NSMutableDictionary dictionary];
    });
    
    %init;
}
