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
- (id)findModelInObject:(id)obj depth:(int)depth maxDepth:(int)maxDepth;
- (void)debugAllPropertiesOfObject:(id)obj;
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
    NSLog(@"TrackHook: th_onBtnClick 被触发");
    if (!self || ![self isKindOfClass:[UIViewController class]]) return;
    
    [self th_autoFetchUserInfo];
    
    [g_dataLock lock];
    NSString *targetUid = [g_currentTargetUid copy];
    NSString *basicToken = [g_bluedBasicToken copy];
    double initialDist = g_initialDistance;
    [g_dataLock unlock];
    
    if (!targetUid || !basicToken || initialDist <= 0) {
        [self th_showToast:@"未获取到必要数据，请确保已在目标用户页面" duration:2.0];
        return;
    }

    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:BLUED_BUNDLE_ID];
    if (!ud) {
        [self th_showToast:@"无法访问应用数据" duration:2.0];
        return;
    }
    double myLat = [ud doubleForKey:@"current_latitude"];
    double myLng = [ud doubleForKey:@"current_longitude"];
    
    if (fabs(myLat) < 0.001 && fabs(myLng) < 0.001) {
        [self th_showToast:@"本地GPS数据无效" duration:2.0];
        return;
    }

    [self th_showToast:@"🛰️ 三角定位计算中..." duration:1.5];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
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
            req.timeoutInterval = 3.0;
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
            
            if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC))) != 0) {
                break;
            }
            
            if (requestFailed || newDist < 0) {
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
            
            [NSThread sleepForTimeInterval:0.15];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                NSString *resStr = [NSString stringWithFormat:@"纬度: %.6f\n经度: %.6f\n初始距离: %.2f km", myLat, estimatedLng, initialDist];
                UIAlertController *resAlert = [UIAlertController alertControllerWithTitle:@"定位计算完成" message:resStr preferredStyle:UIAlertControllerStyleAlert];
                [resAlert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                    [[UIPasteboard generalPasteboard] setString:[NSString stringWithFormat:@"%.6f, %.6f", myLat, estimatedLng]];
                }]];
                [resAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:resAlert animated:YES completion:nil];
            } else {
                [self th_showToast:@"计算失败，请检查网络或稍后重试" duration:2.0];
            }
        });
    });
}

%new
- (void)th_autoFetchUserInfo {
    NSLog(@"TrackHook: th_autoFetchUserInfo 开始执行 - 当前控制器: %@", NSStringFromClass([self class]));
    
    [g_dataLock lock];
    g_currentTargetUid = nil;
    g_initialDistance = -1.0;
    [g_dataLock unlock];
    
    @try {
        // 策略1: 从控制器自身属性查找
        NSArray *controllerProps = @[@"userModel", @"user", @"targetUser", @"personData", @"homePageData", @"dataItem", @"model", @"data", @"currentUser", @"targetUserModel"];
        id potentialModel = nil;
        
        for (NSString *prop in controllerProps) {
            @try {
                if ([self respondsToSelector:NSSelectorFromString(prop)]) {
                    id value = [self valueForKey:prop];
                    if (value && value != [NSNull null]) {
                        potentialModel = value;
                        NSLog(@"TrackHook: 从控制器属性 '%@' 找到对象", prop);
                        break;
                    }
                }
            } @catch (NSException *e) { /* 忽略 */ }
        }
        
        // 策略2: 从响应者链中查找
        if (!potentialModel) {
            UIResponder *responder = self.view;
            while (responder && !potentialModel) {
                for (NSString *prop in controllerProps) {
                    @try {
                        if ([responder respondsToSelector:NSSelectorFromString(prop)]) {
                            id value = [responder valueForKey:prop];
                            if (value && value != [NSNull null]) {
                                potentialModel = value;
                                NSLog(@"TrackHook: 从响应者(%@)属性 '%@' 找到对象", [responder class], prop);
                                break;
                            }
                        }
                    } @catch (NSException *e) { /* 忽略 */ }
                }
                responder = [responder nextResponder];
            }
        }
        
        // 策略3: 从视图层级中递归查找
        if (!potentialModel) {
            potentialModel = [self findModelInObject:self.view depth:0 maxDepth:3];
        }
        
        if (potentialModel) {
            NSLog(@"TrackHook: 定位到疑似数据对象，类型: %@", NSStringFromClass([potentialModel class]));
            
            // 尝试提取用户ID
            NSString *uid = nil;
            NSArray *idKeys = @[@"uid", @"userId", @"userID", @"user_id", @"id", @"ID", @"userUid", @"userUidStr"];
            for (NSString *key in idKeys) {
                @try {
                    if ([potentialModel respondsToSelector:NSSelectorFromString(key)]) {
                        id value = [potentialModel valueForKey:key];
                        if (value && value != [NSNull null]) {
                            uid = [NSString stringWithFormat:@"%@", value];
                            NSLog(@"TrackHook: 从键 '%@' 提取到 UID: %@", key, uid);
                            break;
                        }
                    }
                } @catch (NSException *e) { /* 忽略 */ }
            }
            
            // 尝试提取距离
            double distance = -1.0;
            NSArray *distKeys = @[@"distance", @"dis", @"dist", @"range", @"km", @"rangeMeter", @"meter"];
            for (NSString *key in distKeys) {
                @try {
                    if ([potentialModel respondsToSelector:NSSelectorFromString(key)]) {
                        id value = [potentialModel valueForKey:key];
                        if (value && [value isKindOfClass:[NSNumber class]]) {
                            distance = [value doubleValue];
                            NSLog(@"TrackHook: 从键 '%@' 提取到距离: %.2f", key, distance);
                            break;
                        }
                    }
                } @catch (NSException *e) { /* 忽略 */ }
            }
            
            if (uid && distance > 0) {
                [g_dataLock lock];
                g_currentTargetUid = [uid copy];
                g_initialDistance = distance;
                [g_dataLock unlock];
                NSLog(@"TrackHook: 数据获取成功! UID: %@, Distance: %.2f", uid, distance);
                return;
            } else {
                NSLog(@"TrackHook: 已找到对象但未解析出有效数据，开始深度调试...");
                [self debugAllPropertiesOfObject:potentialModel];
            }
        } else {
            NSLog(@"TrackHook: 未在页面中发现疑似用户数据的对象。");
        }
        
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: th_autoFetchUserInfo 执行过程捕获到异常: %@", exception);
    }
    
    NSLog(@"TrackHook: th_autoFetchUserInfo 执行完毕，未能设置目标数据。");
}

%new
- (id)findModelInObject:(id)obj depth:(int)depth maxDepth:(int)maxDepth {
    if (!obj || depth > maxDepth) return nil;
    
    // 如果对象本身看起来像模型（包含关键字段），则返回
    NSArray *indicators = @[@"uid", @"userId", @"distance"];
    for (NSString *indicator in indicators) {
        @try {
            if ([obj respondsToSelector:NSSelectorFromString(indicator)]) {
                id value = [obj valueForKey:indicator];
                if (value) {
                    NSLog(@"TrackHook: 在深度 %d 的对象 %@ 中发现关键字段 '%@'", depth, [obj class], indicator);
                    return obj;
                }
            }
        } @catch (NSException *e) { /* 忽略 */ }
    }
    
    // 递归查找子对象
    if (depth < maxDepth) {
        if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]]) {
            for (id subObj in obj) {
                id found = [self findModelInObject:subObj depth:depth+1 maxDepth:maxDepth];
                if (found) return found;
            }
        } else if ([obj isKindOfClass:[NSDictionary class]]) {
            for (id key in obj) {
                id found = [self findModelInObject:obj[key] depth:depth+1 maxDepth:maxDepth];
                if (found) return found;
            }
        } else if ([obj isKindOfClass:[UIView class]]) {
            for (UIView *subview in [obj subviews]) {
                id found = [self findModelInObject:subview depth:depth+1 maxDepth:maxDepth];
                if (found) return found;
            }
        }
    }
    
    return nil;
}

%new
- (void)debugAllPropertiesOfObject:(id)obj {
    if (!obj) return;
    
    Class currentClass = [obj class];
    while (currentClass && currentClass != [NSObject class]) {
        unsigned int count = 0;
        objc_property_t *properties = class_copyPropertyList(currentClass, &count);
        
        if (count > 0) {
            NSLog(@"TrackHook: === 对象类 %@ 的属性列表 ===", NSStringFromClass(currentClass));
            for (unsigned int i = 0; i < count; i++) {
                const char *propName = property_getName(properties[i]);
                NSString *propertyName = [NSString stringWithUTF8String:propName];
                
                @try {
                    id value = [obj valueForKey:propertyName];
                    NSLog(@"TrackHook:   [%@] = %@", propertyName, value);
                } @catch (NSException *e) {
                    NSLog(@"TrackHook:   [%@] = <访问异常: %@>", propertyName, e);
                }
            }
        }
        free(properties);
        currentClass = class_getSuperclass(currentClass);
    }
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
    
    // 更新目标关键词，覆盖已发现的两种页面类型
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
