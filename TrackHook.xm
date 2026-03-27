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

// ==================== 类别方法声明 ====================
@interface UIViewController (TrackHookMethods)
- (NSString *)extractUserIdFromUI;
- (NSString *)findUserIdInShareSheet;
- (NSString *)findUserIdInProfilePage;
- (NSString *)findUserIdGlobally;
- (void)debugLogCurrentDataState;
- (UIWindow *)th_getSafeKeyWindow;
- (void)th_onBtnClick;
- (void)th_addBtn;
- (void)th_handlePan:(UIPanGestureRecognizer *)pan;
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur;
@end

@interface NSURLSession (TrackHookMethods)
- (void)extractDistanceFromJSON:(NSDictionary *)json;
- (void)deepSearchDistanceInObject:(id)obj;
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
    return foundWindow ?: [UIApplication sharedApplication].keyWindow;
}

%new
- (void)th_onBtnClick {
    NSLog(@"TrackHook: 🎯 悬浮按钮被点击");
    
    // 尝试从UI中提取用户ID
    NSString *uid = [self extractUserIdFromUI];
    
    if (uid && uid.length > 0) {
        NSLog(@"TrackHook: ✅ 从UI提取到用户ID: %@", uid);
        [g_dataLock lock];
        g_currentTargetUid = [uid copy];
        [g_dataLock unlock];
    }
    
    [self debugLogCurrentDataState];
    
    [g_dataLock lock];
    NSString *targetUid = [g_currentTargetUid copy];
    NSString *basicToken = [g_bluedBasicToken copy];
    double myLat = g_currentLat;
    double myLng = g_currentLng;
    double distance = g_targetDistance;
    [g_dataLock unlock];
    
    // 检查数据完整性
    if (!targetUid) {
        [self th_showToast:@"未获取到用户ID" duration:2.0];
        return;
    }
    if (!basicToken) {
        [self th_showToast:@"未获取到认证令牌" duration:2.0];
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
    NSString *resStr = [NSString stringWithFormat:@"纬度: %.6f\n经度: %.6f\n距离: %.2f km\n用户ID: %@", 
                       myLat, myLng, distance, targetUid];
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
- (NSString *)extractUserIdFromUI {
    // 策略1：在分享界面中查找用户ID
    NSString *uid = [self findUserIdInShareSheet];
    if (uid) {
        return uid;
    }
    
    // 策略2：在个人主页查找用户ID
    uid = [self findUserIdInProfilePage];
    if (uid) {
        return uid;
    }
    
    // 策略3：全局搜索
    return [self findUserIdGlobally];
}

%new
- (NSString *)findUserIdInShareSheet {
    __block NSString *foundUid = nil;
    UIWindow *keyWindow = [self th_getSafeKeyWindow];
    
    if (!keyWindow) return nil;
    
    __block void (^__weak weakSearchBlock)(UIView *);
    void (^searchBlock)(UIView *);
    
    weakSearchBlock = searchBlock = ^(UIView *view) {
        if (!view || foundUid) return;
        
        if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UITextView class]]) {
            NSString *text = nil;
            if ([view isKindOfClass:[UILabel class]]) {
                text = [(UILabel *)view text];
            } else {
                text = [(UITextView *)view text];
            }
            
            if (text && text.length > 0) {
                // 记录所有扫描到的文本，用于调试
                NSLog(@"TrackHook: 👀 扫描分享界面文本: '%@'", text);
                
                NSArray *patterns = @[
                    @"ID[:：]\\s*(\\d+)",      // ID: 478940426
                    @"ID\\s*(\\d+)",           // ID478940426
                    @"UID[:：]\\s*(\\d+)",     // UID: 478940426
                    @"用户ID[:：]\\s*(\\d+)",  // 用户ID: 478940426
                    @"用户编号[:：]\\s*(\\d+)", // 用户编号: 478940426
                    @"\\d{6,}"                 // 纯数字（6位以上）
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
                            if (uid.length >= 6) {
                                foundUid = uid;
                                NSLog(@"TrackHook: ✅ 在分享界面找到用户ID: %@ (模式: %@)", uid, pattern);
                                return;
                            }
                        }
                    }
                }
            }
        }
        
        for (UIView *subview in view.subviews) {
            if (weakSearchBlock) {
                weakSearchBlock(subview);
            }
            if (foundUid) break;
        }
    };
    
    searchBlock(keyWindow);
    
    return foundUid;
}

%new
- (NSString *)findUserIdInProfilePage {
    __block NSString *foundUid = nil;
    
    __block void (^__weak weakSearchBlock)(UIView *);
    void (^searchBlock)(UIView *);
    
    weakSearchBlock = searchBlock = ^(UIView *view) {
        if (!view || foundUid) return;
        
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            NSString *text = label.text;
            
            if (text && text.length > 0) {
                if ([text containsString:@"ID:"]) {
                    NSError *error = nil;
                    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"ID[:：]\\s*(\\d+)" 
                                                                                           options:NSRegularExpressionCaseInsensitive 
                                                                                             error:&error];
                    if (!error) {
                        NSTextCheckingResult *match = [regex firstMatchInString:text 
                                                                        options:0 
                                                                          range:NSMakeRange(0, text.length)];
                        if (match) {
                            foundUid = [text substringWithRange:[match rangeAtIndex:1]];
                            NSLog(@"TrackHook: ✅ 在个人主页找到用户ID: %@", foundUid);
                            return;
                        }
                    }
                }
            }
        }
        
        for (UIView *subview in view.subviews) {
            if (weakSearchBlock) {
                weakSearchBlock(subview);
            }
            if (foundUid) break;
        }
    };
    
    searchBlock(self.view);
    
    return foundUid;
}

%new
- (NSString *)findUserIdGlobally {
    __block NSString *foundUid = nil;
    UIWindow *keyWindow = [self th_getSafeKeyWindow];
    
    if (!keyWindow) return nil;
    
    __block void (^__weak weakSearchBlock)(UIView *);
    void (^searchBlock)(UIView *);
    
    weakSearchBlock = searchBlock = ^(UIView *view) {
        if (!view || foundUid) return;
        
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            NSString *text = label.text;
            
            if (text && text.length > 0) {
                NSError *error = nil;
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\d{6,}" 
                                                                                       options:0 
                                                                                         error:&error];
                if (!error) {
                    NSTextCheckingResult *match = [regex firstMatchInString:text 
                                                                   options:0 
                                                                     range:NSMakeRange(0, text.length)];
                    if (match) {
                        NSString *uid = [text substringWithRange:match.range];
                        if (uid.length >= 6 && uid.length <= 9) {
                            NSString *context = text.lowercaseString;
                            if (![context containsString:@"km"] && 
                                ![context containsString:@"m"] && 
                                ![context containsString:@"kg"] &&
                                ![context containsString:@"cm"] &&
                                ![context containsString:@"岁"] &&
                                ![context containsString:@"年"] &&
                                ![context containsString:@"月"] &&
                                ![context containsString:@"日"] &&
                                ![context containsString:@":"] &&
                                ![context containsString:@"."]) {
                                foundUid = uid;
                                NSLog(@"TrackHook: ✅ 全局搜索找到用户ID: %@", foundUid);
                                return;
                            }
                        }
                    }
                }
            }
        }
        
        for (UIView *subview in view.subviews) {
            if (weakSearchBlock) {
                weakSearchBlock(subview);
            }
            if (foundUid) break;
        }
    };
    
    searchBlock(keyWindow);
    
    return foundUid;
}

%new
- (void)debugLogCurrentDataState {
    [g_dataLock lock];
    NSString *uid = [g_currentTargetUid copy];
    NSString *token = [g_bluedBasicToken copy];
    double lat = g_currentLat;
    double lng = g_currentLng;
    double distance = g_targetDistance;
    [g_dataLock unlock];
    
    NSLog(@"TrackHook: 📊 当前数据状态:");
    NSLog(@"TrackHook:   用户ID: %@", uid ?: @"<空>");
    NSLog(@"TrackHook:   Token: %@", token ? @"<已获取>" : @"<空>");
    NSLog(@"TrackHook:   坐标: (%.6f, %.6f)", lat, lng);
    NSLog(@"TrackHook:   距离: %.2f km", distance);
}

%new
- (void)th_addBtn {
    NSLog(@"TrackHook: 🎨 准备添加悬浮按钮");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 获取当前活跃的窗口场景（WindowScene），这对于多窗口应用至关重要
        UIWindowScene *targetScene = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                    targetScene = (UIWindowScene *)scene;
                    break;
                }
            }
        }
        
        if (!targetScene) {
            NSLog(@"TrackHook: ❌ 无法获取当前活跃的 WindowScene");
            return;
        }
        
        // 2. 创建或更新独立的悬浮窗口
        if (!g_floatWindow || g_floatWindow.windowScene != targetScene) {
            // 如果窗口不存在，或不属于当前活跃的场景，则重新创建
            CGRect screenBounds = targetScene.coordinateSpace.bounds;
            g_floatWindow = [[UIWindow alloc] initWithFrame:screenBounds];
            g_floatWindow.windowScene = targetScene; // 【关键】关联到当前场景
            g_floatWindow.windowLevel = UIWindowLevelAlert + 1000; // 设为非常高的层级
            g_floatWindow.backgroundColor = [UIColor clearColor];
            g_floatWindow.rootViewController = [UIViewController new]; // 避免警告
            g_floatWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
            g_floatWindow.userInteractionEnabled = YES;
            g_floatWindow.hidden = NO;
            [g_floatWindow makeKeyAndVisible]; // 【关键】尝试成为Key Window
            
            NSLog(@"TrackHook: 🪟 已创建/更新独立悬浮窗口 (Scene: %@, Level: %.0f)", targetScene, g_floatWindow.windowLevel);
        }
        
        // 3. 移除旧按钮（如果存在）
        UIButton *oldBtn = [g_floatWindow viewWithTag:TRACK_BTN_TAG];
        if (oldBtn) {
            [oldBtn removeFromSuperview];
        }
        
        // 4. 创建并添加新按钮
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
        
        // 【关键修复】: 将 UIEventTouchUpInside 改为 UIControlEventTouchUpInside
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
    
    // 限制在窗口内
    CGFloat margin = 28;
    CGRect safeArea = v.superview.bounds;
    v.center = CGPointMake(MAX(margin, MIN(safeArea.size.width - margin, v.center.x)),
                           MAX(margin, MIN(safeArea.size.height - margin, v.center.y)));
}

%new
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 在独立窗口上显示toast
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
        // 【修改点】仅在明确需要时，才考虑隐藏按钮。此处先简单记录日志，观察规律。
        NSLog(@"TrackHook: 📍 当前页面 (%@) 非目标页面，暂不处理按钮。", clsName);
        // 注意：这里不再主动移除按钮，因为我们的悬浮窗口是全局独立的。
    }
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *res, NSError *err))completionHandler {
    
    void (^customCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (completionHandler) {
            completionHandler(data, response, error);
        }
        
        if (!error && data && request) {
            NSString *urlString = [request.URL absoluteString];
            NSString *host = request.URL.host;
            
            if (host && ([host containsString:@"blued.cn"] || [host containsString:@"irisgw.cn"])) {
                
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
                
                @try {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (json) {
                        [self extractDistanceFromJSON:json];
                    }
                } @catch (NSException *exception) {
                }
            }
        }
    };
    
    NSURLSessionDataTask *task = %orig(request, customCompletionHandler);
    return task;
}

%new
- (void)extractDistanceFromJSON:(NSDictionary *)json {
    if (!json) return;
    
    [self deepSearchDistanceInObject:json];
}

%new
- (void)deepSearchDistanceInObject:(id)obj {
    if (!obj) return;
    
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        
        for (NSString *key in @[@"distance", @"dis", @"range"]) {
            id value = dict[key];
            if (value && [value isKindOfClass:[NSNumber class]]) {
                double distance = [value doubleValue];
                if (distance > 0) {
                    [g_dataLock lock];
                    g_targetDistance = distance;
                    [g_dataLock unlock];
                    NSLog(@"TrackHook: 📏 从JSON提取到距离: %.2f km", distance);
                    return;
                }
            }
        }
        
        id location = dict[@"location"];
        if (location && [location isKindOfClass:[NSString class]]) {
            NSString *locationStr = (NSString *)location;
            if ([locationStr containsString:@" km"]) {
                NSScanner *scanner = [NSScanner scannerWithString:locationStr];
                double distance = 0.0;
                if ([scanner scanDouble:&distance] && distance > 0) {
                    [g_dataLock lock];
                    g_targetDistance = distance;
                    [g_dataLock unlock];
                    NSLog(@"TrackHook: 📏 从location字段提取到距离: %.2f km", distance);
                    return;
                }
            }
        }
        
        for (id value in [dict allValues]) {
            [self deepSearchDistanceInObject:value];
        }
        
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            [self deepSearchDistanceInObject:item];
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
