#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>

// ==================== 全局变量声明 ====================
static NSMutableDictionary *g_capturedRequests;
static NSString *g_bluedBasicToken;
static NSString *g_currentTargetUid;
static double g_currentLat = 0.0;
static double g_currentLng = 0.0;
static double g_targetDistance = 0.0;
static NSString *g_amapAddress;
static NSLock *g_dataLock;
static BOOL g_debugMode = YES;

// ==================== 工具函数 ====================
static NSString *decodeURLString(NSString *encodedString) {
    if (!encodedString) return nil;
    return [encodedString stringByRemovingPercentEncoding];
}

static NSDictionary *parseQueryString(NSString *query) {
    if (!query) return @{};
    
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSArray *components = [query componentsSeparatedByString:@"&"];
    
    for (NSString *component in components) {
        NSArray *keyValue = [component componentsSeparatedByString:@"="];
        if (keyValue.count == 2) {
            NSString *key = decodeURLString(keyValue[0]);
            NSString *value = decodeURLString(keyValue[1]);
            if (key && value) {
                params[key] = value;
            }
        }
    }
    
    return [params copy];
}

// ==================== 初始化函数 ====================
%ctor {
    NSLog(@"TrackHook: 🚀 Tweak已加载");
    
    g_capturedRequests = [NSMutableDictionary dictionary];
    g_dataLock = [[NSLock alloc] init];
    g_debugMode = YES;
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSLog(@"TrackHook: 📱 应用已启动");
    }];
}

// ==================== UIViewController Hook ====================
%hook UIViewController

%new
- (void)th_showToast:(NSString *)message duration:(NSTimeInterval)duration {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;
    
    UILabel *toastLabel = [[UILabel alloc] init];
    toastLabel.text = message;
    toastLabel.textColor = [UIColor whiteColor];
    toastLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.7];
    toastLabel.textAlignment = NSTextAlignmentCenter;
    toastLabel.font = [UIFont systemFontOfSize:14];
    toastLabel.layer.cornerRadius = 8;
    toastLabel.clipsToBounds = YES;
    
    CGSize textSize = [message sizeWithAttributes:@{NSFontAttributeName: toastLabel.font}];
    CGFloat padding = 20;
    CGFloat width = MIN(textSize.width + padding * 2, window.bounds.size.width - 40);
    CGFloat height = textSize.height + padding;
    
    toastLabel.frame = CGRectMake((window.bounds.size.width - width) / 2, window.bounds.size.height - 150, width, height);
    [window addSubview:toastLabel];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{
            toastLabel.alpha = 0;
        } completion:^(BOOL finished) {
            [toastLabel removeFromSuperview];
        }];
    });
}

%new
- (void)th_exportAllData {
    [g_dataLock lock];
    
    NSMutableDictionary *exportData = [NSMutableDictionary dictionary];
    if (g_bluedBasicToken) exportData[@"basic_token"] = g_bluedBasicToken;
    if (g_currentTargetUid) exportData[@"current_uid"] = g_currentTargetUid;
    if (fabs(g_currentLat) > 0.001) exportData[@"latitude"] = @(g_currentLat);
    if (fabs(g_currentLng) > 0.001) exportData[@"longitude"] = @(g_currentLng);
    if (fabs(g_targetDistance) > 0.001) exportData[@"target_distance"] = @(g_targetDistance);
    if (g_capturedRequests.count > 0) exportData[@"captured_requests"] = g_capturedRequests;
    
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:exportData options:NSJSONWritingPrettyPrinted error:&error];
    
    [g_dataLock unlock];
    
    if (!error && jsonData) {
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [[UIPasteboard generalPasteboard] setString:jsonString];
        [self th_showToast:@"数据已导出到剪贴板" duration:2.0];
    } else {
        [self th_showToast:@"导出失败" duration:2.0];
    }
}

%new
- (void)th_clearAllData {
    [g_dataLock lock];
    [g_capturedRequests removeAllObjects];
    g_bluedBasicToken = nil;
    g_currentTargetUid = nil;
    g_currentLat = 0.0;
    g_currentLng = 0.0;
    g_targetDistance = 0.0;
    g_amapAddress = nil;
    [g_dataLock unlock];
    
    [self th_showToast:@"所有数据已清除" duration:2.0];
}

%new
- (void)th_testCoordinateRequest {
    NSString *testUrl = @"https://social.irisgw.cn/users?latitude=22.760733&longitude=114.382814&limit=60&uid=76818159";
    NSLog(@"TrackHook: 🧪 模拟测试请求: %@", testUrl);
    
    NSURLComponents *components = [NSURLComponents componentsWithString:testUrl];
    NSString *query = components.query;
    
    if (query) {
        NSDictionary *params = parseQueryString(query);
        for (NSString *key in params) {
            if ([key isEqualToString:@"latitude"]) {
                double lat = [params[key] doubleValue];
                [g_dataLock lock]; g_currentLat = lat; [g_dataLock unlock];
                NSLog(@"TrackHook: 🧪 测试纬度: %.6f", lat);
            } else if ([key isEqualToString:@"longitude"]) {
                double lng = [params[key] doubleValue];
                [g_dataLock lock]; g_currentLng = lng; [g_dataLock unlock];
                NSLog(@"TrackHook: 🧪 测试经度: %.6f", lng);
            }
        }
    }
    
    [self th_showToast:@"测试请求已执行" duration:2.0];
}

%new
- (void)th_showSystemLog {
    [self th_showToast:@"系统日志功能需要额外权限" duration:2.0];
}

%new
- (void)th_showAllRequests {
    [g_dataLock lock];
    
    NSMutableString *requestsInfo = [NSMutableString string];
    [requestsInfo appendString:@"📋 所有捕获的请求\n\n"];
    
    NSArray *sortedKeys = [[g_capturedRequests allKeys] sortedArrayUsingSelector:@selector(compare:)];
    
    if (sortedKeys.count == 0) {
        [requestsInfo appendString:@"❌ 无捕获的请求\n"];
    } else {
        for (NSString *key in sortedKeys) {
            NSDictionary *req = g_capturedRequests[key];
            NSString *timestamp = req[@"timestamp"];
            NSString *type = req[@"type"] ?: @"unknown";
            NSString *url = req[@"url"];
            
            [requestsInfo appendFormat:@"[%@] %@\nURL: %@\n", timestamp, type, url];
            
            NSDictionary *params = req[@"params"];
            if (params && params.count > 0) {
                [requestsInfo appendString:@"参数:\n"];
                for (NSString *paramKey in params) {
                    NSString *value = params[paramKey];
                    if (value.length > 50) value = [NSString stringWithFormat:@"%@...", [value substringToIndex:50]];
                    [requestsInfo appendFormat:@"  %@: %@\n", paramKey, value];
                }
            }
            [requestsInfo appendString:@"\n"];
        }
    }
    
    [g_dataLock unlock];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"所有请求" message:requestsInfo preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)th_onAdvancedBtnClick {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"高级功能" message:@"选择要执行的操作" preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"导出所有数据" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [self th_exportAllData];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"清除所有数据" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
        [self th_clearAllData];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"模拟坐标请求" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [self th_testCoordinateRequest];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"查看系统日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [self th_showSystemLog];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)th_onButtonPan:(UIPanGestureRecognizer *)pan {
    UIButton *button = (UIButton *)pan.view;
    CGPoint translation = [pan translationInView:button.superview];
    
    CGPoint center = button.center;
    center.x += translation.x;
    center.y += translation.y;
    
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
    
    center.x = MAX(30, MIN(screenWidth - 30, center.x));
    center.y = MAX(50, MIN(screenHeight - 50, center.y));
    
    button.center = center;
    [pan setTranslation:CGPointZero inView:button.superview];
}

%new
- (void)addTrackHookButton {
    UIButton *trackButton = [UIButton buttonWithType:UIButtonTypeCustom];
    trackButton.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 70, 100, 60, 60);
    trackButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
    trackButton.layer.cornerRadius = 30;
    trackButton.layer.shadowColor = [UIColor blackColor].CGColor;
    trackButton.layer.shadowOffset = CGSizeMake(0, 2);
    trackButton.layer.shadowOpacity = 0.3;
    trackButton.layer.shadowRadius = 4;
    
    [trackButton setTitle:@"TH" forState:UIControlStateNormal];
    [trackButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    trackButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    
    [trackButton addTarget:self action:@selector(th_onBtnClick) forControlEvents:UIControlEventTouchUpInside];
    
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(th_onAdvancedBtnClick)];
    [trackButton addGestureRecognizer:longPress];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(th_onButtonPan:)];
    [trackButton addGestureRecognizer:pan];
    
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (window) {
        [window addSubview:trackButton];
        [window bringSubviewToFront:trackButton];
    }
}

%new
- (void)th_onBtnClick {
    NSLog(@"TrackHook: 🎯 悬浮按钮被点击");
    
    [g_dataLock lock];
    
    NSMutableString *debugInfo = [NSMutableString string];
    [debugInfo appendString:@"🔧 TrackHook 调试信息\n\n"];
    [debugInfo appendFormat:@"📱 应用状态:\n  • 调试模式: %@\n  • 捕获请求数: %lu\n\n", g_debugMode ? @"✅ 开启" : @"🔇 关闭", (unsigned long)g_capturedRequests.count];
    [debugInfo appendFormat:@"🔑 认证信息:\n  • Basic Token: %@\n  • 当前用户ID: %@\n\n", g_bluedBasicToken ? @"✅ 已获取" : @"❌ 无", g_currentTargetUid ?: @"❌ 无"];
    
    [debugInfo appendFormat:@"📍 坐标信息:\n"];
    if (fabs(g_currentLat) > 0.001 && fabs(g_currentLng) > 0.001) {
        [debugInfo appendFormat:@"  • 纬度: %.6f\n  • 经度: %.6f\n  • 距离: %.2f km\n\n", g_currentLat, g_currentLng, g_targetDistance];
    } else {
        [debugInfo appendString:@"  • ❌ 未捕获到有效坐标\n\n"];
    }
    
    NSArray *sortedKeys = [[g_capturedRequests allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSInteger recentCount = MIN(3, sortedKeys.count);
    
    if (recentCount > 0) {
        [debugInfo appendString:@"📡 最近请求:\n"];
        for (NSInteger i = MAX(0, (NSInteger)sortedKeys.count - recentCount); i < sortedKeys.count; i++) {
            NSString *key = sortedKeys[i];
            NSDictionary *req = g_capturedRequests[key];
            NSString *url = req[@"url"];
            NSString *type = req[@"type"] ?: @"unknown";
            
            if (url.length > 50) {
                url = [NSString stringWithFormat:@"%@...%@", [url substringToIndex:25], [url substringFromIndex:url.length - 25]];
            }
            [debugInfo appendFormat:@"  [%ld] %@\n", (long)i+1, type];
            
            NSDictionary *params = req[@"params"];
            if (params) {
                if (params[@"latitude"]) [debugInfo appendFormat:@"    📌 lat: %@\n", params[@"latitude"]];
                if (params[@"longitude"]) [debugInfo appendFormat:@"    📌 lng: %@\n", params[@"longitude"]];
                if (params[@"uid"]) [debugInfo appendFormat:@"    👤 uid: %@\n", params[@"uid"]];
            }
        }
    } else {
        [debugInfo appendString:@"📡 最近请求: 无\n"];
    }
    
    [g_dataLock unlock];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TrackHook" message:debugInfo preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"复制Token" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        if (g_bluedBasicToken) {
            [[UIPasteboard generalPasteboard] setString:g_bluedBasicToken];
            [self th_showToast:@"Token已复制到剪贴板" duration:2.0];
        } else {
            [self th_showToast:@"无Token可复制" duration:2.0];
        }
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"查看所有请求" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [self th_showAllRequests];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"切换调试模式" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        g_debugMode = !g_debugMode;
        NSString *msg = g_debugMode ? @"✅ 调试模式已开启" : @"🔇 调试模式已关闭";
        [self th_showToast:msg duration:2.0];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad {
    %orig;
    
    if ([self isKindOfClass:NSClassFromString(@"BLHomeViewController")] || 
        [self isKindOfClass:NSClassFromString(@"BLNearbyViewController")] ||
        [self isKindOfClass:NSClassFromString(@"BLMapViewController")]) {
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self addTrackHookButton];
        });
    }
}
%end

// ==================== NSURLSession Hook ====================
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    NSString *urlString = request.URL.absoluteString;
    
    if (g_debugMode) {
        NSLog(@"TrackHook: 🌐 网络请求 URL: %@", urlString);
        NSLog(@"TrackHook: 🌐 请求方法: %@", request.HTTPMethod ?: @"GET");
    }
    
    NSDictionary *headers = request.allHTTPHeaderFields;
    if (headers.count > 0 && g_debugMode) {
        NSLog(@"TrackHook: 📋 请求头总数: %lu", (unsigned long)headers.count);
        for (NSString *key in headers) {
            NSString *value = headers[key];
            if ([key isEqualToString:@"Authorization"]) {
                if ([value hasPrefix:@"Basic "]) {
                    NSString *token = [value substringFromIndex:6];
                    NSLog(@"TrackHook: 🔐 Basic Token 前50字符: %@...", [token substringToIndex:MIN(50, token.length)]);
                    
                    [g_dataLock lock];
                    g_bluedBasicToken = [value copy];
                    [g_dataLock unlock];
                } else if ([value hasPrefix:@"Bearer "]) {
                    NSLog(@"TrackHook: 🔐 Bearer Token 存在");
                }
            }
        }
    }
    
    BOOL isTargetRequest = NO;
    NSString *requestType = @"unknown";
    
    if ([urlString containsString:@"/users/map/pass/by/status"]) {
        isTargetRequest = YES;
        requestType = @"map_status";
        NSLog(@"TrackHook: 🗺️ 捕获到地图找人接口");
    } else if ([urlString containsString:@"/users?"] && 
              ([urlString containsString:@"latitude="] || [urlString containsString:@"longitude="])) {
        isTargetRequest = YES;
        requestType = @"users_list";
        NSLog(@"TrackHook: 🎯 捕获到用户列表接口（含坐标）");
    } else if ([urlString containsString:@"/users/selection"]) {
        isTargetRequest = YES;
        requestType = @"selection";
        NSLog(@"TrackHook: 🎯 捕获到用户筛选接口");
    } else if ([urlString containsString:@"/users/map"]) {
        isTargetRequest = YES;
        requestType = @"map_related";
        NSLog(@"TrackHook: 🗺️ 捕获到地图相关接口");
    }
    
    if (isTargetRequest) {
        NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
        NSString *query = components.query;
        
        if (query && query.length > 0) {
            NSDictionary *params = parseQueryString(query);
            
            if (g_debugMode) {
                NSLog(@"TrackHook: 🔍 完整查询参数: %@", query);
                NSLog(@"TrackHook: 📊 解析后的参数数量: %lu", (unsigned long)params.count);
            }
            
            NSString *latStr = params[@"latitude"];
            NSString *lngStr = params[@"longitude"];
            
            if (latStr) {
                double lat = [latStr doubleValue];
                if (fabs(lat) > 0.0001) {
                    [g_dataLock lock];
                    g_currentLat = lat;
                    [g_dataLock unlock];
                    NSLog(@"TrackHook: ✅ 捕获纬度: %.6f", lat);
                } else {
                    NSLog(@"TrackHook: ⚠️ 纬度值无效: %@", latStr);
                }
            }
            
            if (lngStr) {
                double lng = [lngStr doubleValue];
                if (fabs(lng) > 0.0001) {
                    [g_dataLock lock];
                    g_currentLng = lng;
                    [g_dataLock unlock];
                    NSLog(@"TrackHook: ✅ 捕获经度: %.6f", lng);
                } else {
                    NSLog(@"TrackHook: ⚠️ 经度值无效: %@", lngStr);
                }
            }
            
            NSString *uid = params[@"uid"];
            if (uid && uid.length > 0) {
                [g_dataLock lock];
                g_currentTargetUid = [uid copy];
                [g_dataLock unlock];
                NSLog(@"TrackHook: 👤 捕获用户ID: %@", uid);
            }
            
            NSString *distanceStr = params[@"distance"] ?: params[@"range"];
            if (distanceStr) {
                double distance = [distanceStr doubleValue];
                [g_dataLock lock];
                g_targetDistance = distance;
                [g_dataLock unlock];
                NSLog(@"TrackHook: 📏 捕获距离参数: %.2f", distance);
            }
            
            NSString *filtersStr = params[@"filters"];
            if (filtersStr) {
                NSData *filtersData = [filtersStr dataUsingEncoding:NSUTF8StringEncoding];
                NSError *error;
                NSDictionary *filters = [NSJSONSerialization JSONObjectWithData:filtersData options:0 error:&error];
                if (!error && [filters isKindOfClass:[NSDictionary class]]) {
                    NSLog(@"TrackHook: 🎛️ 筛选条件: %@", filters);
                }
            }
        }
        
        NSMutableDictionary *requestInfo = [NSMutableDictionary dictionary];
        requestInfo[@"url"] = urlString;
        requestInfo[@"method"] = request.HTTPMethod ?: @"GET";
        requestInfo[@"timestamp"] = [NSDate date].description;
        requestInfo[@"type"] = requestType;
        requestInfo[@"headers"] = headers ?: @{};
        
        if (query && query.length > 0) {
            requestInfo[@"params"] = parseQueryString(query);
        }
        
        [g_dataLock lock];
        NSString *key = [NSString stringWithFormat:@"%f", [[NSDate date] timeIntervalSince1970]];
        g_capturedRequests[key] = requestInfo;
        
        if (g_debugMode) {
            NSLog(@"TrackHook: 💾 已保存请求记录，总数: %lu", (unsigned long)g_capturedRequests.count);
        }
        [g_dataLock unlock];
    }
    
    if (request.HTTPBody && g_debugMode) {
        NSString *bodyString = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        if (bodyString && bodyString.length > 0) {
            NSLog(@"TrackHook: 📦 请求体（前200字符）: %@", [bodyString substringToIndex:MIN(200, bodyString.length)]);
        }
    }
    
    return %orig(request, completionHandler);
}
%end

// ==================== NSURLConnection Hook ====================
%hook NSURLConnection

+ (NSData *)sendSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error {
    NSString *urlString = request.URL.absoluteString;
    
    if (g_debugMode) {
        NSLog(@"TrackHook: 🔄 NSURLConnection同步请求: %@", urlString);
    }
    
    if ([urlString containsString:@"/users/map"] || 
        ([urlString containsString:@"/users"] && 
         ([urlString containsString:@"latitude="] || [urlString containsString:@"longitude="]))) {
        NSLog(@"TrackHook: 🎯 NSURLConnection捕获地图/坐标接口");
        
        NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
        NSString *query = components.query;
        
        if (query) {
            NSDictionary *params = parseQueryString(query);
            
            for (NSString *key in params) {
                if ([key isEqualToString:@"latitude"]) {
                    double lat = [params[key] doubleValue];
                    [g_dataLock lock];
                    g_currentLat = lat;
                    [g_dataLock unlock];
                    NSLog(@"TrackHook: ✅ NSURLConnection捕获纬度: %.6f", lat);
                } else if ([key isEqualToString:@"longitude"]) {
                    double lng = [params[key] doubleValue];
                    [g_dataLock lock];
                    g_currentLng = lng;
                    [g_dataLock unlock];
                    NSLog(@"TrackHook: ✅ NSURLConnection捕获经度: %.6f", lng);
                }
            }
        }
        
        NSMutableDictionary *requestInfo = [NSMutableDictionary dictionary];
        requestInfo[@"url"] = urlString;
        requestInfo[@"timestamp"] = [NSDate date].description;
        requestInfo[@"type"] = @"sync_connection";
        
        if (query) {
            requestInfo[@"params"] = parseQueryString(query);
        }
        
        [g_dataLock lock];
        NSString *key = [NSString stringWithFormat:@"sync_%f", [[NSDate date] timeIntervalSince1970]];
        g_capturedRequests[key] = requestInfo;
        [g_dataLock unlock];
    }
    
    return %orig(request, response, error);
}

+ (void)sendAsynchronousRequest:(NSURLRequest *)request queue:(NSOperationQueue *)queue completionHandler:(void (^)(NSURLResponse *, NSData *, NSError *))handler {
    NSString *urlString = request.URL.absoluteString;
    
    if (g_debugMode) {
        NSLog(@"TrackHook: 🔄 NSURLConnection异步请求: %@", urlString);
    }
    
    if ([urlString containsString:@"/users/map"] || 
        ([urlString containsString:@"/users"] && 
         ([urlString containsString:@"latitude="] || [urlString containsString:@"longitude="]))) {
        NSLog(@"TrackHook: 🎯 NSURLConnection异步捕获地图/坐标接口");
        
        NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
        NSString *query = components.query;
        
        if (query) {
            NSDictionary *params = parseQueryString(query);
            
            for (NSString *key in params) {
                if ([key isEqualToString:@"latitude"]) {
                    double lat = [params[key] doubleValue];
                    [g_dataLock lock];
                    g_currentLat = lat;
                    [g_dataLock unlock];
                    NSLog(@"TrackHook: ✅ NSURLConnection异步捕获纬度: %.6f", lat);
                } else if ([key isEqualToString:@"longitude"]) {
                    double lng = [params[key] doubleValue];
                    [g_dataLock lock];
                    g_currentLng = lng;
                    [g_dataLock unlock];
                    NSLog(@"TrackHook: ✅ NSURLConnection异步捕获经度: %.6f", lng);
                }
            }
        }
        
        NSMutableDictionary *requestInfo = [NSMutableDictionary dictionary];
        requestInfo[@"url"] = urlString;
        requestInfo[@"timestamp"] = [NSDate date].description;
        requestInfo[@"type"] = @"async_connection";
        
        if (query) {
            requestInfo[@"params"] = parseQueryString(query);
        }
        
        [g_dataLock lock];
        NSString *key = [NSString stringWithFormat:@"async_%f", [[NSDate date] timeIntervalSince1970]];
        g_capturedRequests[key] = requestInfo;
        [g_dataLock unlock];
    }
    
    return %orig(request, queue, handler);
}
%end

// ==================== 应用生命周期Hook ====================
%hook UIApplication

- (void)applicationDidBecomeActive:(UIApplication *)application { %orig; NSLog(@"TrackHook: 📱 应用进入前台"); }
- (void)applicationWillResignActive:(UIApplication *)application { %orig; NSLog(@"TrackHook: 📱 应用进入后台"); }
- (void)applicationWillTerminate:(UIApplication *)application { %orig; NSLog(@"TrackHook: 📱 应用即将终止"); }

%end
