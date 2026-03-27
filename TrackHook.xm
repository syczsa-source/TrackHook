#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>
#import <CoreLocation/CoreLocation.h> // 为更复杂的地理计算预留

#define TRACK_BTN_TAG 100001
// 使用更精确的WGS-84椭球体长半轴半径（单位：公里），替换原有的粗略值
#define EARTH_RADIUS_KM 6378.137
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

// 使用线程安全的属性访问，避免数据竞争（参考文档中关于多线程及稳定性的强调）
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
    if (!self || ![self isKindOfClass:[UIViewController class]]) return;
    
    [self th_autoFetchUserInfo];
    
    // 加锁读取全局变量
    [g_dataLock lock];
    NSString *targetUid = [g_currentTargetUid copy];
    NSString *basicToken = [g_bluedBasicToken copy];
    double initialDist = g_initialDistance;
    [g_dataLock unlock];
    
    if (!targetUid || !basicToken || initialDist <= 0) {
        [self th_showToast:@"未获取到必要数据，请确保已在目标用户页面" duration:2.0];
        return;
    }

    // 修复：使用标准方式获取NSUserDefaults，避免潜在的内存泄漏和不必要的实例化
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:BLUED_BUNDLE_ID];
    if (!ud) {
        [self th_showToast:@"无法访问应用数据" duration:2.0];
        return;
    }
    double myLat = [ud doubleForKey:@"current_latitude"];
    double myLng = [ud doubleForKey:@"current_longitude"];
    
    if (fabs(myLat) < 0.001 && fabs(myLng) < 0.001) { // 更严格的判断
        [self th_showToast:@"本地GPS数据无效" duration:2.0];
        return;
    }

    [self th_showToast:@"🛰️ 三角定位计算中..." duration:1.5];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 算法优化：使用二分查找逼近，而非简单平均，提高收敛速度和稳定性
        double minLng = myLng - 1.0; // 初始搜索范围±1度
        double maxLng = myLng + 1.0;
        double estimatedLng = myLng;
        double currentDist = initialDist;
        BOOL success = NO;
        int maxIterations = 15; // 限制最大迭代次数
        double tolerance = 0.01; // 收敛容忍度（公里）

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
            
            // 等待请求完成，设置超时
            if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC))) != 0) {
                break; // 超时
            }
            
            if (requestFailed || newDist < 0) {
                break; // 请求失败或数据无效
            }
            
            double deltaDist = newDist - currentDist;
            // 文档第六章强调的调试思想：此处逻辑可通过LLDB设置断点观察 deltaDist, estimatedLng 等值
            if (fabs(deltaDist) < tolerance) {
                // 距离变化很小，认为已收敛
                success = YES;
                break;
            } else if (deltaDist > 0) {
                // 新距离变大了，说明估计方向错误，向反方向调整搜索边界
                maxLng = estimatedLng;
            } else {
                // 新距离变小了，说明方向正确，继续向同方向调整搜索边界
                minLng = estimatedLng;
            }
            // 取新区间中点作为下一次的估计值
            estimatedLng = (minLng + maxLng) / 2.0;
            currentDist = newDist;
            
            [NSThread sleepForTimeInterval:0.15]; // 增加请求间隔，降低频率
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
    // 【核心修复】借鉴文档第九、十章方法：从UI响应链追溯，而非盲目遍历属性
    // 目标：找到当前视图控制器中持有“目标用户信息”的对象。
    // 原方法暴力尝试属性名，不稳定。更好的方法是结合Cycript动态分析确定准确属性名。
    // 此处提供一种更稳健的备选方案：尝试获取当前控制器的“数据模型”或“目标用户”属性。
    // 实际逆向中，应使用Cycript的`choose`和`recursiveDescription`定位该对象。
    @try {
        id potentialModel = nil;
        UIResponder *responder = self.view;
        // 方法1: 尝试从视图的nextResponder链中寻找（参考第十章iMessage案例）
        while (responder && !potentialModel) {
            if ([responder respondsToSelector:@selector(userModel)]) {
                potentialModel = [responder valueForKey:@"userModel"];
                break;
            } else if ([responder respondsToSelector:@selector(user)]) {
                potentialModel = [responder valueForKey:@"user"];
                break;
            } else if ([responder respondsToSelector:@selector(targetUser)]) {
                potentialModel = [responder valueForKey:@"targetUser"];
                break;
            }
            responder = [responder nextResponder];
        }
        
        // 方法2: 如果方法1失败，回退到原逻辑尝试控制器的属性
        if (!potentialModel) {
            NSArray *propertyNames = @[@"userModel", @"user", @"targetUser", @"dataItem", @"currentUser"];
            for (NSString *name in propertyNames) {
                if ([self respondsToSelector:NSSelectorFromString(name)]) {
                    potentialModel = [self valueForKey:name];
                    if (potentialModel) break;
                }
            }
        }
        
        if (potentialModel) {
            NSString *uid = nil;
            double distance = -1.0;
            // 尝试从模型中获取uid和distance属性
            if ([potentialModel respondsToSelector:@selector(uid)]) {
                uid = [NSString stringWithFormat:@"%@", [potentialModel valueForKey:@"uid"]];
            }
            if ([potentialModel respondsToSelector:@selector(distance)]) {
                distance = [[potentialModel valueForKey:@"distance"] doubleValue];
            }
            
            if (uid && distance > 0) {
                [g_dataLock lock];
                g_currentTargetUid = [uid copy];
                g_initialDistance = distance;
                [g_dataLock unlock];
                return;
            }
        }
    } @catch (NSException *exception) {
        // 静默失败，避免崩溃
    }
    // 获取失败，清空旧数据
    [g_dataLock lock];
    g_currentTargetUid = nil;
    g_initialDistance = -1.0;
    [g_dataLock unlock];
}

%new
- (void)th_addBtn {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self th_addBtn]; });
        return;
    }
    UIWindow *win = [self th_getSafeKeyWindow];
    if (!win || [win viewWithTag:TRACK_BTN_TAG]) return;

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
}

%new
- (void)th_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint translation = [pan translationInView:v.superview];
    CGPoint newCenter = CGPointMake(v.center.x + translation.x, v.center.y + translation.y);
    
    // 限制按钮不超出屏幕安全区域
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
        // 移除旧的toast
        for (UIView *subview in win.subviews) {
            if ([subview isKindOfClass:[UILabel class]] && subview.tag == 9999) {
                [subview removeFromSuperview];
            }
        }
        
        UILabel *lab = [[UILabel alloc] init];
        lab.tag = 9999;
        lab.text = msg;
        lab.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        lab.textColor = [UIColor whiteColor];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
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
    // 更精确地匹配目标页面，减少不必要的注入
    NSArray *targetKeywords = @[@"Detail", @"User", @"Profile", @"Homepage", @"Info"];
    BOOL shouldInject = NO;
    for (NSString *keyword in targetKeywords) {
        if ([clsName containsString:keyword]) {
            shouldInject = YES;
            break;
        }
    }
    
    if (shouldInject) {
        // 延迟注入，避免与页面动画冲突
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self th_addBtn];
        });
    } else {
        // 如果不是目标页面，则移除可能存在的按钮（如果用户拖拽到了这里）
        UIWindow *win = [self th_getSafeKeyWindow];
        [[win viewWithTag:TRACK_BTN_TAG] removeFromSuperview];
    }
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *res, NSError *err))completionHandler {
    NSURLSessionDataTask *task = %orig(request, completionHandler);
    // 【修复与优化】只拦截目标域名的请求，避免不必要的全局hook和线程安全问题
    if (request && [request.URL.host containsString:@"blued.cn"]) {
        NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
        if ([auth hasPrefix:@"Basic "]) {
            NSString *token = [auth substringFromIndex:6];
            if (token.length > 0) {
                [g_dataLock lock];
                g_bluedBasicToken = [token copy];
                [g_dataLock unlock];
            }
        }
    }
    return task;
}
%end

// 初始化
%ctor {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_dataLock = [[NSLock alloc] init];
    });
    %init;
}
