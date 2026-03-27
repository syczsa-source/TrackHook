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
    NSLog(@"TrackHook: th_onBtnClick 被触发");
    if (!self || ![self isKindOfClass:[UIViewController class]]) return;
    
    [self th_autoFetchUserInfo];
    
    [g_dataLock lock];
    NSString *targetUid = [g_currentTargetUid copy];
    NSString *basicToken = [g_bluedBasicToken copy];
    double initialDist = g_initialDistance;
    [g_dataLock unlock];
    
    NSLog(@"TrackHook: 当前数据 - UID: %@, Token: %@, 距离: %.2f", 
          targetUid ?: @"<空>", 
          basicToken ? @"<有>" : @"<空>", 
          initialDist);
    
    if (!targetUid || !basicToken || initialDist <= 0) {
        NSString *msg = @"未获取到必要数据";
        if (!targetUid) msg = @"未获取到用户ID";
        else if (!basicToken) msg = @"未获取到认证令牌";
        else if (initialDist <= 0) msg = @"未获取到距离信息";
        
        [self th_showToast:msg duration:2.0];
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
        NSString *uid = nil;
        double distance = -1.0;
        
        // 从网络Hook已捕获的数据中读取（主要来源）
        [g_dataLock lock];
        uid = [g_currentTargetUid copy];
        NSString *basicToken = [g_bluedBasicToken copy];
        [g_dataLock unlock];
        
        if (uid) {
            NSLog(@"TrackHook: 从网络请求中获取到 UID: %@", uid);
        } else {
            NSLog(@"TrackHook: 网络请求中尚未捕获到UID");
        }
        
        if (basicToken) {
            NSLog(@"TrackHook: 已获取到 Basic Token");
        } else {
            NSLog(@"TrackHook: 尚未获取到 Basic Token");
        }
        
        // 备用策略：如果网络未捕获到UID，尝试从UI文本中提取
        if (!uid || uid.length == 0) {
            uid = [self extractUserIdFromUI];
            if (uid) {
                NSLog(@"TrackHook: 从UI文本中提取到 UID: %@", uid);
            }
        }
        
        // 距离信息从UI中提取（主要来源）
        distance = [self extractDistanceFromUI];
        if (distance > 0) {
            NSLog(@"TrackHook: 从UI中提取到距离: %.2f km", distance);
        } else {
            NSLog(@"TrackHook: 未在UI中找到距离信息");
        }
        
        // 最终处理
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
        
        // 如果缺少Token
        if (!basicToken || basicToken.length == 0) {
            NSLog(@"TrackHook: 缺少必要的 Basic Token");
        }
        
        NSLog(@"TrackHook: 数据不完整，无法进行计算");
        
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: th_autoFetchUserInfo 捕获到异常: %@", exception);
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
    
    @try {
        searchBlock(self.view);
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: extractUserIdFromUI 递归异常: %@", exception);
    }
    
    return foundUid;
}

%new
- (double)extractDistanceFromUI {
    // 策略1：精准定位 BDDistanceAndTimeView
    __block double foundDistance = -1.0;
    
    __block void (^__weak weakSearchBlock)(UIView *);
    void (^searchBlock)(UIView *);
    
    weakSearchBlock = searchBlock = ^(UIView *view) {
        if (!view || foundDistance > 0) return;
        
        // 查找 BDDistanceAndTimeView
        if ([NSStringFromClass([view class]) isEqualToString:@"BDDistanceAndTimeView"]) {
            NSLog(@"TrackHook: 找到 BDDistanceAndTimeView");
            
            // 遍历子视图寻找距离标签
            for (UIView *subview in view.subviews) {
                if ([subview isKindOfClass:[UILabel class]]) {
                    UILabel *label = (UILabel *)subview;
                    NSString *text = label.text;
                    
                    if (text && [text containsString:@"km"]) {
                        NSScanner *scanner = [NSScanner scannerWithString:text];
                        double distance = 0.0;
                        if ([scanner scanDouble:&distance] && distance > 0) {
                            foundDistance = distance;
                            NSLog(@"TrackHook: 从 BDDistanceAndTimeView 提取到距离: %.2f km", distance);
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
            if (foundDistance > 0) break;
        }
    };
    
    searchBlock(self.view);
    
    // 策略2：如果没找到BDDistanceAndTimeView，尝试全局搜索
    if (foundDistance <= 0) {
        NSLog(@"TrackHook: 未找到BDDistanceAndTimeView，尝试全局搜索");
        __block void (^__weak weakSearchBlock2)(UIView *);
        void (^searchBlock2)(UIView *);
        
        weakSearchBlock2 = searchBlock2 = ^(UIView *view) {
            if (!view || foundDistance > 0) return;
            
            if ([view isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)view;
                NSString *text = label.text;
                
                if (text && [text containsString:@"km"]) {
                    NSScanner *scanner = [NSScanner scannerWithString:text];
                    double distance = 0.0;
                    if ([scanner scanDouble:&distance] && distance > 0) {
                        foundDistance = distance;
                        NSLog(@"TrackHook: 从全局Label提取到距离: %.2f km", distance);
                        return;
                    }
                }
            }
            
            for (UIView *subview in view.subviews) {
                if (weakSearchBlock2) {
                    weakSearchBlock2(subview);
                }
                if (foundDistance > 0) break;
            }
        };
        
        searchBlock2(self.view);
    }
    
    if (foundDistance <= 0) {
        NSLog(@"TrackHook: 未在UI中找到距离信息");
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
        [UIView animateWithDuration:0.3 delay:dur options:0 animations:^{ lab.alpha = 0; } completion:^(BOOL finished) { 
            if (finished) [lab removeFromSuperview]; 
        }];
    });
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *clsName = NSStringFromClass([self class]);
    NSLog(@"TrackHook: viewDidAppear 被调用，当前控制器: %@", clsName);
    
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
    
    if (request) {
        NSString *urlString = [request.URL absoluteString];
        NSString *host = request.URL.host;
        
        // 监听所有发往blued.cn的请求
        if (host && [host containsString:@"blued.cn"]) {
            NSLog(@"TrackHook: 监听到Blued请求: %@", urlString);
            
            // 1. 尝试从URL路径中提取UID
            NSArray *uidPatterns = @[
                @"/users/(\\d+)",                    // /users/54533294
                @"/user/(\\d+)",                     // /user/54533294
                @"[?&]uid=(\\d+)",                   // ?uid=54533294
                @"[?&]user_id=(\\d+)",               // ?user_id=54533294
                @"[?&]target_uid=(\\d+)",            // ?target_uid=54533294
                @"[?&]userId=(\\d+)"                 // ?userId=54533294
            ];
            
            for (NSString *pattern in uidPatterns) {
                @try {
                    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
                    NSTextCheckingResult *match = [regex firstMatchInString:urlString options:0 range:NSMakeRange(0, urlString.length)];
                    
                    if (match) {
                        NSString *capturedUid = [urlString substringWithRange:[match rangeAtIndex:1]];
                        if (capturedUid && capturedUid.length >= 6) {
                            [g_dataLock lock];
                            g_currentTargetUid = [capturedUid copy];
                            [g_dataLock unlock];
                            NSLog(@"TrackHook: 从URL模式 '%@' 捕获到 UID: %@", pattern, capturedUid);
                            break;
                        }
                    }
                } @catch (NSException *e) {
                    NSLog(@"TrackHook: 正则匹配异常: %@", e);
                }
            }
            
            // 2. 捕获Basic Token
            NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
            if ([auth hasPrefix:@"Basic "]) {
                NSString *token = [auth substringFromIndex:6];
                if (token.length > 0) {
                    [g_dataLock lock];
                    g_bluedBasicToken = [token copy];
                    [g_dataLock unlock];
                    NSLog(@"TrackHook: 已捕获到 Basic Token (长度: %lu)", (unsigned long)token.length);
                }
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
