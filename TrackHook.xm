#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>
#import <CoreLocation/CoreLocation.h>

#define TRACK_BTN_TAG 100001
#define EARTH_RADIUS_KM 6378.137
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

static NSLock *g_dataLock = nil;
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_initialDistance = -1.0;

@interface UIViewController (TrackHook)
- (UIWindow *)th_getSafeKeyWindow;
- (void)th_autoFetchUserInfo;
- (void)th_onBtnClick;
- (void)th_addBtn;
- (void)th_handlePan:(UIPanGestureRecognizer *)pan;
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur;
- (NSString *)extractUserIdFromUI;
- (double)extractDistanceFromUI;
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
    // 【关键安全修复1】：确保在主线程执行，并添加基本检查
    if (![NSThread isMainThread]) {
        NSLog(@"TrackHook: 错误：th_onBtnClick 不在主线程！");
        return;
    }
    if (!self || ![self isKindOfClass:[UIViewController class]]) {
        NSLog(@"TrackHook: 错误：self 无效或不是控制器");
        return;
    }
    
    NSLog(@"TrackHook: th_onBtnClick 被触发");
    
    // 【关键安全修复2】：将可能崩溃的数据获取和网络请求放入安全的异步块
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            NSLog(@"TrackHook: 控制器已释放");
            return;
        }
        
        @try {
            [strongSelf th_autoFetchUserInfo];
        } @catch (NSException *exception) {
            NSLog(@"TrackHook: th_autoFetchUserInfo 发生严重异常: %@", exception);
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf th_showToast:@"数据获取时发生异常" duration:2.0];
            });
            return;
        }
        
        NSString *targetUid = nil;
        NSString *basicToken = nil;
        double initialDist = -1.0;
        
        [g_dataLock lock];
        targetUid = [g_currentTargetUid copy];
        basicToken = [g_bluedBasicToken copy];
        initialDist = g_initialDistance;
        [g_dataLock unlock];
        
        if (!targetUid || !basicToken || initialDist <= 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf th_showToast:@"未获取到必要数据，请确保已在目标用户页面" duration:2.0];
            });
            return;
        }

        NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:BLUED_BUNDLE_ID];
        if (!ud) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf th_showToast:@"无法访问应用数据" duration:2.0];
            });
            return;
        }
        double myLat = [ud doubleForKey:@"current_latitude"];
        double myLng = [ud doubleForKey:@"current_longitude"];
        
        if (fabs(myLat) < 0.001 && fabs(myLng) < 0.001) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf th_showToast:@"本地GPS数据无效" duration:2.0];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf th_showToast:@"🛰️ 三角定位计算中..." duration:1.5];
        });

        // 三角定位计算逻辑（保持不变，但包裹在try-catch中）
        @try {
            double minLng = myLng - 1.0;
            double maxLng = myLng + 1.0;
            double estimatedLng = myLng;
            double currentDist = initialDist;
            BOOL success = NO;
            int maxIterations = 15;
            double tolerance = 0.01;

            for (int i = 0; i < maxIterations && !success; i++) {
                NSString *urlStr = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", targetUid];
                NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
                [req setValue:[NSString stringWithFormat:@"Basic %@", basicToken] forHTTPHeaderField:@"Authorization"];
                req.timeoutInterval = 5.0; // 稍微增加超时
                req.HTTPMethod = @"GET";

                __block double newDist = -1.0;
                __block BOOL requestFailed = NO;
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                
                NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
                    if (!err && data) {
                        @try {
                            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                            if (json && [json[@"data"] isKindOfClass:[NSDictionary class]]) {
                                newDist = [json[@"data"][@"distance"] doubleValue];
                            }
                        } @catch (NSException *exception) {
                            requestFailed = YES;
                        }
                    } else {
                        requestFailed = YES;
                    }
                    dispatch_semaphore_signal(sem);
                }];
                [task resume];
                
                if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC))) != 0) {
                    NSLog(@"TrackHook: 网络请求超时");
                    break;
                }
                
                if (requestFailed || newDist < 0) {
                    NSLog(@"TrackHook: 网络请求失败或数据无效");
                    break;
                }
                
                double deltaDist = newDist - currentDist;
                if (fabs(deltaDist) < tolerance) {
                    success = YES;
                    break;
                } else if (deltaDist > 0) {
                    maxLng = estimatedLng;
                } else {
                    minLng = estimatedLng;
                }
                estimatedLng = (minLng + maxLng) / 2.0;
                currentDist = newDist;
                
                [NSThread sleepForTimeInterval:0.2]; // 增加间隔，降低频率
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    NSString *resStr = [NSString stringWithFormat:@"纬度: %.6f\n经度: %.6f\n初始距离: %.2f km", myLat, estimatedLng, initialDist];
                    UIAlertController *resAlert = [UIAlertController alertControllerWithTitle:@"定位计算完成" message:resStr preferredStyle:UIAlertControllerStyleAlert];
                    [resAlert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                        [[UIPasteboard generalPasteboard] setString:[NSString stringWithFormat:@"%.6f, %.6f", myLat, estimatedLng]];
                    }]];
                    [resAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
                    [strongSelf presentViewController:resAlert animated:YES completion:nil];
                } else {
                    [strongSelf th_showToast:@"计算失败，请检查网络或稍后重试" duration:2.0];
                }
            });
        } @catch (NSException *exception) {
            NSLog(@"TrackHook: 三角定位计算过程发生异常: %@", exception);
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf th_showToast:@"计算过程发生错误" duration:2.0];
            });
        }
    });
}

%new
- (void)th_autoFetchUserInfo {
    NSLog(@"TrackHook: th_autoFetchUserInfo 开始执行 - 当前控制器: %@", NSStringFromClass([self class]));
    
    // 先清空旧数据
    [g_dataLock lock];
    g_currentTargetUid = nil;
    g_initialDistance = -1.0;
    [g_dataLock unlock];
    
    @try {
        NSString *uid = nil;
        double distance = -1.0;
        
        // 【稳定性修复】：使用简化策略，暂时移除复杂的运行时反射
        
        // 策略1: 快速尝试最常见的几个属性
        NSArray *quickProperties = @[@"user", @"userModel", @"personData", @"dataItem"];
        for (NSString *prop in quickProperties) {
            @try {
                if ([self respondsToSelector:NSSelectorFromString(prop)]) {
                    id value = [self valueForKey:prop];
                    if (value && value != [NSNull null]) {
                        // 尝试从这个对象获取uid
                        NSArray *idKeys = @[@"uid", @"userId", @"id"];
                        for (NSString *key in idKeys) {
                            @try {
                                if ([value respondsToSelector:NSSelectorFromString(key)]) {
                                    id idValue = [value valueForKey:key];
                                    if (idValue && idValue != [NSNull null]) {
                                        uid = [NSString stringWithFormat:@"%@", idValue];
                                        NSLog(@"TrackHook: 从对象属性 '%@' 的字段 '%@' 找到UID: %@", prop, key, uid);
                                        break;
                                    }
                                }
                            } @catch (NSException *e) {}
                        }
                        
                        // 尝试获取距离
                        NSArray *distKeys = @[@"distance", @"dis"];
                        for (NSString *key in distKeys) {
                            @try {
                                if ([value respondsToSelector:NSSelectorFromString(key)]) {
                                    id distValue = [value valueForKey:key];
                                    if (distValue && [distValue isKindOfClass:[NSNumber class]]) {
                                        distance = [distValue doubleValue];
                                        NSLog(@"TrackHook: 从对象属性 '%@' 的字段 '%@' 找到距离: %.2f", prop, key, distance);
                                        break;
                                    }
                                }
                            } @catch (NSException *e) {}
                        }
                        
                        if (uid && distance > 0) break;
                    }
                }
            } @catch (NSException *e) {
                // 忽略访问异常
            }
        }
        
        // 策略2: 如果快速属性没找到，尝试从UI文本中提取（安全兜底）
        if (!uid || uid.length == 0) {
            NSString *extractedUid = [self extractUserIdFromUI];
            if (extractedUid && extractedUid.length > 0) {
                uid = extractedUid;
                NSLog(@"TrackHook: 从UI文本中提取到 UID: %@", uid);
            }
        }
        
        if (distance <= 0) {
            double extractedDist = [self extractDistanceFromUI];
            if (extractedDist > 0) {
                distance = extractedDist;
                NSLog(@"TrackHook: 从UI文本中提取到距离: %.2f", distance);
            }
        }
        
        // 存储找到的数据
        if (uid && uid.length > 0) {
            NSString *cleanUid = [[uid componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
            
            if (cleanUid.length >= 6) {
                [g_dataLock lock];
                g_currentTargetUid = [cleanUid copy];
                g_initialDistance = distance;
                [g_dataLock unlock];
                NSLog(@"TrackHook: 成功保存目标数据 - UID: %@, Distance: %.2f", cleanUid, distance);
                return;
            } else {
                NSLog(@"TrackHook: 提取到的UID '%@' 清理后 '%@' 长度不足", uid, cleanUid);
            }
        }
        
        NSLog(@"TrackHook: 未能提取到有效UID和距离");
        
    } @catch (NSException *exception) {
        // 【关键安全修复3】：捕获所有异常，防止崩溃
        NSLog(@"TrackHook: th_autoFetchUserInfo 捕获到异常（已处理）: %@", exception);
    }
}

%new
- (NSString *)extractUserIdFromUI {
    __block NSString *foundUid = nil;
    
    __block void (^__weak weakSearchBlock)(UIView *);
    void (^searchBlock)(UIView *);
    
    weakSearchBlock = searchBlock = ^(UIView *view) {
        if (!view || foundUid) return;
        
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            NSString *text = label.text;
            
            if (text && text.length > 0) {
                // 匹配 "ID:161766904" 这种显式格式
                if ([text hasPrefix:@"ID:"] && text.length > 3) {
                    NSString *userId = [text substringFromIndex:3];
                    if (userId.length >= 6) {
                        foundUid = userId;
                        NSLog(@"TrackHook: 从Label提取到ID (前缀匹配): %@", foundUid);
                        return;
                    }
                }
                
                // 使用正则表达式提取长数字串
                NSError *error = nil;
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\d{6,}" options:0 error:&error];
                if (!error) {
                    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
                    if (match) {
                        NSString *userId = [text substringWithRange:match.range];
                        foundUid = userId;
                        NSLog(@"TrackHook: 从Label文本 '%@' 中正则提取到ID: %@", text, foundUid);
                        return;
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
    
    // 限制递归深度，防止栈溢出
    @try {
        searchBlock(self.view);
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: extractUserIdFromUI 递归出错: %@", exception);
    }
    
    return foundUid;
}

%new
- (double)extractDistanceFromUI {
    __block double foundDistance = -1.0;
    
    __block void (^__weak weakSearchBlock)(UIView *);
    void (^searchBlock)(UIView *);
    
    weakSearchBlock = searchBlock = ^(UIView *view) {
        if (!view || foundDistance > 0) return;
        
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            NSString *text = label.text;
            
            if (text && [text containsString:@"km"]) {
                NSScanner *scanner = [NSScanner scannerWithString:text];
                double distance = 0.0;
                if ([scanner scanDouble:&distance]) {
                    foundDistance = distance;
                    NSLog(@"TrackHook: 从Label '%@' 提取到距离: %.2f km", text, distance);
                    return;
                }
            }
        }
        
        for (UIView *subview in view.subviews) {
            if (weakSearchBlock) {
                weakSearchBlock(subview);
            }
            if (foundDistance > 0) break;
        }
    };
    
    @try {
        searchBlock(self.view);
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: extractDistanceFromUI 递归出错: %@", exception);
    }
    
    return foundDistance;
}

%new
- (void)th_addBtn {
    NSLog(@"TrackHook: th_addBtn 被调用");
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self th_addBtn]; });
        return;
    }
    UIWindow *win = [self th_getSafeKeyWindow];
    if (!win) {
        NSLog(@"TrackHook: 未找到 KeyWindow");
        return;
    }
    if ([win viewWithTag:TRACK_BTN_TAG]) {
        NSLog(@"TrackHook: 按钮已存在");
        return;
    }

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
    NSLog(@"TrackHook: 悬浮按钮已添加到窗口");
}

%new
- (void)th_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint translation = [pan translationInView:v.superview];
    CGPoint newCenter = CGPointMake(v.center.x + translation.x, v.center.y + translation.y);
    
    CGFloat margin = 28;
    newCenter.x = MAX(margin, MIN(v.superview.bounds.size.width - margin, newCenter.x));
    newCenter.y = MAX(margin, MIN(v.superview.bounds.size.height - margin, newCenter.y));
    
    v.center = newCenter;
    [pan setTranslation:CGPointZero inView:v.superview];
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
        [UIView animateWithDuration:0.3 animations:^{ lab.alpha = 1.0; }];
        [UIView animateWithDuration:0.3 delay:dur options:0 animations:^{ lab.alpha = 0; } completion:^(BOOL finished) { [lab removeFromSuperview]; }];
    });
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *clsName = NSStringFromClass([self class]);
    NSLog(@"TrackHook: viewDidAppear 被调用，当前控制器: %@", clsName);
    
    // 目标关键词已更新，支持 BDHomePagePersonDataViewController 和 BDHomeViewController
    NSArray *targetKeywords = @[@"Detail", @"User", @"Profile", @"Homepage", @"Info", @"HomePage", @"PersonData", @"HomeView"];
    BOOL shouldInject = NO;
    for (NSString *keyword in targetKeywords) {
        if ([clsName containsString:keyword]) {
            shouldInject = YES;
            NSLog(@"TrackHook: 页面类名包含关键字 '%@'，将注入按钮", keyword);
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
            NSLog(@"TrackHook: 从非目标页面移除按钮");
        }
    }
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *res, NSError *err))completionHandler {
    NSURLSessionDataTask *task = %orig(request, completionHandler);
    if (request && [request.URL.host containsString:@"blued.cn"]) {
        NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
        if ([auth hasPrefix:@"Basic "]) {
            NSString *token = [auth substringFromIndex:6];
            if (token.length > 0) {
                [g_dataLock lock];
                g_bluedBasicToken = [token copy];
                [g_dataLock unlock];
                NSLog(@"TrackHook: 已捕获到 Basic Token");
            }
        }
    }
    return task;
}
%end

%ctor {
    NSLog(@"TrackHook: 插件已加载 (Constructor)");
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_dataLock = [[NSLock alloc] init];
    });
    %init;
}
