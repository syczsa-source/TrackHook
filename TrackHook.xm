#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>

#define TRACK_BTN_TAG 100001
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

static NSLock *g_dataLock = nil;
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUnionUid = nil; // 【关键变更】存储 union_uid
static double g_currentLat = 0.0;
static double g_currentLng = 0.0;
static double g_targetDistance = -1.0;

@interface UIViewController (TrackHook)
- (UIWindow *)th_getSafeKeyWindow;
- (void)th_autoFetchUserInfo;
- (void)th_onBtnClick;
- (void)th_addBtn;
- (void)th_handlePan:(UIPanGestureRecognizer *)pan;
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur;
- (void)debugLogCurrentDataState;
@end

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
    return foundWindow ?: [UIApplication sharedApplication].keyWindow;
}

%new
- (void)th_onBtnClick {
    NSLog(@"TrackHook: 🎯 悬浮按钮被点击");
    
    [self debugLogCurrentDataState];
    
    [g_dataLock lock];
    NSString *targetUnionUid = [g_currentTargetUnionUid copy];
    NSString *basicToken = [g_bluedBasicToken copy];
    double myLat = g_currentLat;
    double myLng = g_currentLng;
    double distance = g_targetDistance;
    [g_dataLock unlock];
    
    // 检查数据完整性
    if (!targetUnionUid) {
        [self th_showToast:@"未获取到用户标识(union_uid)" duration:2.0];
        return;
    }
    if (!basicToken) {
        [self th_showToast:@"未获取到认证令牌(Token)" duration:2.0];
        return;
    }
    if (fabs(myLat) < 0.001 || fabs(myLng) < 0.001) {
        [self th_showToast:@"未获取到坐标信息" duration:2.0];
        return;
    }
    if (distance <= 0) {
        [self th_showToast:@"未获取到距离信息" duration:2.0];
        return;
    }

    // 显示结果
    NSString *resStr = [NSString stringWithFormat:@"纬度: %.6f\n经度: %.6f\n距离: %.2f km\n用户标识: %@", 
                       myLat, myLng, distance, targetUnionUid];
    UIAlertController *resAlert = [UIAlertController alertControllerWithTitle:@"定位信息" 
                                                                     message:resStr 
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [resAlert addAction:[UIAlertAction actionWithTitle:@"复制坐标" 
                                                 style:UIAlertActionStyleDefault 
                                               handler:^(UIAlertAction *a){
        [[UIPasteboard generalPasteboard] setString:[NSString stringWithFormat:@"%.6f, %.6f", myLat, myLng]];
        NSLog(@"TrackHook: 📋 已复制坐标到剪贴板");
    }]];
    [resAlert addAction:[UIAlertAction actionWithTitle:@"确定" 
                                                 style:UIAlertActionStyleCancel 
                                               handler:nil]];
    [self presentViewController:resAlert animated:YES completion:nil];
}

%new
- (void)th_autoFetchUserInfo {
    // 此方法在当前策略下主要作为日志记录，核心数据已由网络监听自动捕获
    NSLog(@"TrackHook: 🔍 自动获取用户信息被调用");
    [self debugLogCurrentDataState];
}

%new
- (void)debugLogCurrentDataState {
    [g_dataLock lock];
    NSString *uid = [g_currentTargetUnionUid copy];
    NSString *token = [g_bluedBasicToken copy];
    double lat = g_currentLat;
    double lng = g_currentLng;
    double distance = g_targetDistance;
    [g_dataLock unlock];
    
    NSLog(@"TrackHook: 📊 当前数据状态:");
    NSLog(@"TrackHook:   Union UID: %@", uid ?: @"<空>");
    NSLog(@"TrackHook:   Token: %@", token ? @"<已获取>" : @"<空>");
    NSLog(@"TrackHook:   坐标: (%.6f, %.6f)", lat, lng);
    NSLog(@"TrackHook:   距离: %.2f km", distance);
}

%new
- (void)th_addBtn {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self th_addBtn]; });
        return;
    }
    UIWindow *win = [self th_getSafeKeyWindow];
    if (!win) return;
    if ([win viewWithTag:TRACK_BTN_TAG]) return;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = TRACK_BTN_TAG;
    btn.frame = CGRectMake(win.bounds.size.width - 70, win.bounds.size.height / 2, 56, 56);
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
    btn.layer.zPosition = 9999;
    
    [btn addTarget:self action:@selector(th_onBtnClick) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(th_handlePan:)];
    [btn addGestureRecognizer:pan];
    [win addSubview:btn];
    NSLog(@"TrackHook: ✅ 悬浮按钮已添加到窗口");
}

%new
- (void)th_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint translation = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x + translation.x, v.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:v.superview];
    
    // 限制在窗口内
    CGFloat margin = 28;
    CGRect safeArea = v.superview.bounds;
    v.center = CGPointMake(MAX(margin, MIN(safeArea.size.width - margin, v.center.x)),
                           MAX(margin, MIN(safeArea.size.height - margin, v.center.y)));
}

%new
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self th_getSafeKeyWindow];
        if (!win) return;
        for (UIView *subview in win.subviews) {
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
        
        CGSize textSize = [lab sizeThatFits:CGSizeMake(win.bounds.size.width * 0.7, 100)];
        lab.bounds = CGRectMake(0, 0, textSize.width + 30, textSize.height + 20);
        lab.center = CGPointMake(win.bounds.size.width / 2, win.bounds.size.height * 0.85);
        
        [win addSubview:lab];
        lab.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{ lab.alpha = 1.0; }];
        [UIView animateWithDuration:0.3 delay:dur options:0 animations:^{ lab.alpha = 0; } completion:^(BOOL finished) { 
            if (finished) [lab removeFromSuperview]; 
        }];
    });
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
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
        UIWindow *win = [self th_getSafeKeyWindow];
        UIView *btn = [win viewWithTag:TRACK_BTN_TAG];
        if (btn) {
            [btn removeFromSuperview];
        }
    }
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *res, NSError *err))completionHandler {
    
    void (^customCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        // 1. 先执行原始回调
        if (completionHandler) {
            completionHandler(data, response, error);
        }
        
        // 2. 我们的处理逻辑
        if (!error && data && request) {
            NSString *urlString = [request.URL absoluteString];
            NSString *host = request.URL.host;
            
            if (host && ([host containsString:@"blued.cn"] || [host containsString:@"irisgw.cn"])) {
                
                // === 捕获 Basic Token ===
                NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
                if ([auth hasPrefix:@"Basic "]) {
                    NSString *token = [auth substringFromIndex:6];
                    if (token.length > 0) {
                        [g_dataLock lock];
                        g_bluedBasicToken = [token copy];
                        [g_dataLock unlock];
                        NSLog(@"TrackHook: ✅ 已捕获到 Basic Token");
                    }
                }
                
                // === 从 timeline 请求中提取坐标 ===
                if ([urlString containsString:@"/timeline"] || [urlString containsString:@"lat="]) {
                    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
                    for (NSURLQueryItem *item in components.queryItems) {
                        if ([item.name isEqualToString:@"lat"]) {
                            double lat = [item.value doubleValue];
                            if (fabs(lat) > 0.001) {
                                [g_dataLock lock];
                                g_currentLat = lat;
                                [g_dataLock unlock];
                                NSLog(@"TrackHook: 📍 从请求捕获纬度: %.6f", lat);
                            }
                        } else if ([item.name isEqualToString:@"lot"] || [item.name isEqualToString:@"lon"]) {
                            double lng = [item.value doubleValue];
                            if (fabs(lng) > 0.001) {
                                [g_dataLock lock];
                                g_currentLng = lng;
                                [g_dataLock unlock];
                                NSLog(@"TrackHook: 📍 从请求捕获经度: %.6f", lng);
                            }
                        }
                    }
                }
                
                // === 解析响应体，寻找 union_uid 和 distance ===
                @try {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (json) {
                        [self deepSearchUnionUidAndDistanceInJSONObject:json sourceURL:urlString];
                    }
                } @catch (NSException *exception) {
                    // 忽略解析错误
                }
            }
        }
    };
    
    // 调用原始方法
    NSURLSessionDataTask *task = %orig(request, customCompletionHandler);
    return task;
}

%new
- (void)deepSearchUnionUidAndDistanceInJSONObject:(id)jsonObj sourceURL:(NSString *)urlString {
    if (!jsonObj) return;
    
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObj;
        
        // 1. 首先检查当前字典是否有我们需要的字段
        NSString *foundUnionUid = nil;
        double foundDistance = -1.0;
        
        // 查找 union_uid
        id unionUidValue = dict[@"union_uid"];
        if (unionUidValue && [unionUidValue isKindOfClass:[NSString class]] && ((NSString *)unionUidValue).length > 0) {
            foundUnionUid = (NSString *)unionUidValue;
        }
        
        // 查找 distance (数字)
        id distanceNum = dict[@"distance"];
        if (distanceNum && [distanceNum isKindOfClass:[NSNumber class]]) {
            foundDistance = [distanceNum doubleValue];
        }
        // 查找 distance (文本，如 "5.40 km")
        if (foundDistance <= 0) {
            id distanceText = dict[@"location"]; // 有时距离在 location 字段
            if (distanceText && [distanceText isKindOfClass:[NSString class]]) {
                NSString *text = (NSString *)distanceText;
                if ([text containsString:@" km"]) {
                    NSScanner *scanner = [NSScanner scannerWithString:text];
                    [scanner scanDouble:&foundDistance];
                }
            }
        }
        
        // 如果找到了 union_uid，保存它
        if (foundUnionUid) {
            [g_dataLock lock];
            g_currentTargetUnionUid = [foundUnionUid copy];
            if (foundDistance > 0) {
                g_targetDistance = foundDistance;
            }
            [g_dataLock unlock];
            NSLog(@"TrackHook: 🎯 从API响应中找到 union_uid: %@, 距离: %.2f km", foundUnionUid, foundDistance);
        }
        
        // 2. 递归搜索嵌套的字典和数组
        for (id value in [dict allValues]) {
            [self deepSearchUnionUidAndDistanceInJSONObject:value sourceURL:urlString];
        }
        
    } else if ([jsonObj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)jsonObj) {
            [self deepSearchUnionUidAndDistanceInJSONObject:item sourceURL:urlString];
        }
    }
}
%end

%ctor {
    NSLog(@"TrackHook: 🚀 插件已加载");
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_dataLock = [[NSLock alloc] init];
    });
    %init;
}
