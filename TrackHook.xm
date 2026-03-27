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

// ==================== 自定义窗口类 - 解决事件拦截问题 ====================
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
    
    // === 调试：检查所有关键数据 ===
    [g_dataLock lock];
    NSString *currentToken = [g_bluedBasicToken copy];
    NSString *currentUid = [g_currentTargetUid copy];
    double lat = g_currentLat;
    double lng = g_currentLng;
    double distance = g_targetDistance;
    [g_dataLock unlock];
    
    NSLog(@"TrackHook: 📊 点击时数据快照:");
    NSLog(@"TrackHook:   Token: %@", currentToken ?: @"<空>");
    NSLog(@"TrackHook:   用户ID: %@", currentUid ?: @"<空>");
    NSLog(@"TrackHook:   坐标: (%.6f, %.6f)", lat, lng);
    NSLog(@"TrackHook:   距离: %.2f km", distance);
    
    // 尝试从UI中提取用户ID
    NSString *uid = [self extractUserIdFromUI];
    if (uid && uid.length > 0) {
        NSLog(@"TrackHook: ✅ 从UI提取到用户ID: %@", uid);
        [g_dataLock lock];
        g_currentTargetUid = [uid copy];
        [g_dataLock unlock];
        currentUid = uid; // 更新本地变量
    }
    
    // 重新获取数据（可能已被更新）
    [g_dataLock lock];
    NSString *targetUid = [g_currentTargetUid copy];
    NSString *basicToken = [g_bluedBasicToken copy];
    double myLat = g_currentLat;
    double myLng = g_currentLng;
    double myDistance = g_targetDistance;
    [g_dataLock unlock];
    
    // 检查数据完整性
    if (!targetUid) {
        [self th_showToast:@"缺少用户ID\n请确保在分享界面点击按钮" duration:3.0];
        return;
    }
    if (!basicToken) {
        [self th_showToast:@"缺少认证令牌\n请先刷新页面或浏览动态" duration:3.0];
        return;
    }
    if (fabs(myLat) < 0.001 || fabs(myLng) < 0.001) {
        [self th_showToast:@"缺少坐标信息\n请先刷新用户时间线" duration:3.0];
        return;
    }
    if (myDistance <= 0) {
        [self th_showToast:@"缺少距离信息\n网络请求未捕获距离" duration:3.0];
        return;
    }

    // 显示结果
    NSString *resStr = [NSString stringWithFormat:@"纬度: %.6f\n经度: %.6f\n距离: %.2f km\n用户ID: %@", 
                       myLat, myLng, myDistance, targetUid];
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
    NSLog(@"TrackHook: 🔍 开始提取用户ID");
    
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
    NSLog(@"TrackHook: 🔍 开始在分享界面查找用户ID");
    
    __block NSString *foundUid = nil;
    
    // 搜索所有窗口
    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
    NSLog(@"TrackHook: 发现 %lu 个窗口", (unsigned long)windows.count);
    
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha <= 0) continue;
        
        __block void (^__weak weakSearchBlock)(UIView *);
        void (^searchBlock)(UIView *);
        
        weakSearchBlock = searchBlock = ^(UIView *view) {
            if (!view || foundUid) return;
            
            // 检查所有包含文本的视图
            if ([view isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)view;
                NSString *text = label.text;
                
                if (text && text.length > 0) {
                    // 记录包含"ID"的文本用于调试
                    if ([text containsString:@"ID"] || [text containsString:@"558289410"] || [text containsString:@"558"]) {
                        NSLog(@"TrackHook: 👀 扫描到相关文本: '%@' (类: %@)", text, NSStringFromClass([view class]));
                    }
                    
                    // 匹配 "ID:558289410" 这种格式
                    NSArray *patterns = @[
                        @"ID\\s*[:：]\\s*(\\d+)",           // ID:558289410
                        @"^ID\\s*[:：]\\s*(\\d+)$",         // 单独一行的ID
                        @"用户ID\\s*[:：]\\s*(\\d+)",       // 用户ID:558289410
                        @"UID\\s*[:：]\\s*(\\d+)",          // UID:558289410
                        @"\\b(\\d{6,10})\\b"               // 6-10位纯数字
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
                                    foundUid = uid;
                                    NSLog(@"TrackHook: ✅ 在分享界面找到用户ID: %@ (模式: %@)", uid, pattern);
                                    return;
                                }
                            }
                        }
                    }
                }
            }
            // 也检查UITextView
            else if ([view isKindOfClass:[UITextView class]]) {
                UITextView *textView = (UITextView *)view;
                NSString *text = textView.text;
                
                if (text && text.length > 0) {
                    if ([text containsString:@"ID"] || [text containsString:@"558289410"]) {
                        NSLog(@"TrackHook: 👀 在UITextView中扫描到文本: '%@'", text);
                    }
                    
                    NSArray *patterns = @[@"ID\\s*[:：]\\s*(\\d+)"];
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
                                    foundUid = uid;
                                    NSLog(@"TrackHook: ✅ 在UITextView中找到用户ID: %@", uid);
                                    return;
                                }
                            }
                        }
                    }
                }
            }
            
            // 递归搜索子视图
            for (UIView *subview in view.subviews) {
                if (weakSearchBlock) {
                    weakSearchBlock(subview);
                }
                if (foundUid) break;
            }
        };
        
        searchBlock(window);
        if (foundUid) break;
    }
    
    if (!foundUid) {
        NSLog(@"TrackHook: ❌ 在分享界面未找到用户ID");
    }
    
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
                    NSLog(@"TrackHook: 👀 在个人主页发现ID文本: '%@'", text);
                    
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
    NSLog(@"TrackHook: 🌍 开始全局搜索用户ID");
    
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
                // 查找6-10位数字
                NSError *error = nil;
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\b(\\d{6,10})\\b" 
                                                                                       options:0 
                                                                                         error:&error];
                if (!error) {
                    NSTextCheckingResult *match = [regex firstMatchInString:text 
                                                                   options:0 
                                                                     range:NSMakeRange(0, text.length)];
                    if (match) {
                        NSString *uid = [text substringWithRange:match.range];
                        if (uid.length >= 6 && uid.length <= 10) {
                            NSString *context = text.lowercaseString;
                            // 排除常见干扰
                            if (![context containsString:@"km"] && 
                                ![context containsString:@"m"] && 
                                ![context containsString:@"kg"] &&
                                ![context containsString:@"cm"] &&
                                ![context containsString:@"岁"] &&
                                ![context containsString:@"年"] &&
                                ![context containsString:@"月"] &&
                                ![context containsString:@"日"] &&
                                ![context containsString:@"%"] &&
                                ![context containsString:@"¥"] &&
                                ![context containsString:@"￥"]) {
                                foundUid = uid;
                                NSLog(@"TrackHook: ✅ 全局搜索找到用户ID: %@ (文本: %@)", foundUid, text);
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
        // 1. 获取当前活跃的窗口场景
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
            CGRect screenBounds = targetScene.coordinateSpace.bounds;
            g_floatWindow = [[TrackHookWindow alloc] initWithFrame:screenBounds];
            g_floatWindow.windowScene = targetScene;
            g_floatWindow.windowLevel = UIWindowLevelStatusBar + 10;
            g_floatWindow.backgroundColor = [UIColor clearColor];
            g_floatWindow.rootViewController = [UIViewController new];
            g_floatWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
            g_floatWindow.userInteractionEnabled = YES;
            g_floatWindow.hidden = NO;
            
            NSLog(@"TrackHook: 🪟 已创建独立悬浮窗口");
        }
        
        // 3. 移除旧按钮
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
                
                // === 捕获 Basic Token ===
                NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
                if (auth && [auth hasPrefix:@"Basic "]) {
                    NSString *token = [auth substringFromIndex:6];
                    if (token.length > 0) {
                        [g_dataLock lock];
                        g_bluedBasicToken = [token copy];
                        [g_dataLock unlock];
                        NSLog(@"TrackHook: ✅ 已捕获到 Basic Token (URL: %@)", urlString);
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
                                NSLog(@"TrackHook: 📍 从请求捕获纬度: %.6f (URL: %@)", lat, urlString);
                            }
                        } else if ([item.name isEqualToString:@"lot"] || [item.name isEqualToString:@"lon"]) {
                            double lng = [item.value doubleValue];
                            if (fabs(lng) > 0.001) {
                                [g_dataLock lock];
                                g_currentLng = lng;
                                [g_dataLock unlock];
                                NSLog(@"TrackHook: 📍 从请求捕获经度: %.6f (URL: %@)", lng, urlString);
                            }
                        }
                    }
                }
                
                // === 从网络响应中提取距离信息 ===
                @try {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (json) {
                        [self extractDistanceFromJSON:json url:urlString];
                    }
                } @catch (NSException *exception) {
                    // 忽略解析错误
                }
            }
        }
    };
    
    NSURLSessionDataTask *task = %orig(request, customCompletionHandler);
    return task;
}

%new
- (void)extractDistanceFromJSON:(NSDictionary *)json url:(NSString *)urlString {
    if (!json) return;
    
    [self deepSearchDistanceInObject:json url:urlString];
}

%new
- (void)deepSearchDistanceInObject:(id)obj url:(NSString *)urlString {
    if (!obj) return;
    
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        
        // 检查是否有距离字段
        for (NSString *key in @[@"distance", @"dis", @"range"]) {
            id value = dict[key];
            if (value && [value isKindOfClass:[NSNumber class]]) {
                double distance = [value doubleValue];
                if (distance > 0) {
                    [g_dataLock lock];
                    g_targetDistance = distance;
                    [g_dataLock unlock];
                    NSLog(@"TrackHook: 📏 从JSON提取到距离: %.2f km (URL: %@)", distance, urlString);
                    return;
                }
            }
        }
        
        // 检查 location 字段
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
                    NSLog(@"TrackHook: 📏 从location字段提取到距离: %.2f km (URL: %@)", distance, urlString);
                    return;
                }
            }
        }
        
        // 递归搜索
        for (id value in [dict allValues]) {
            [self deepSearchDistanceInObject:value url:urlString];
        }
        
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            [self deepSearchDistanceInObject:item url:urlString];
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
