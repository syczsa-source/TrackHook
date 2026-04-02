#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

// 函数声明
void th_showAlert(NSString *title, NSString *msg);
void th_addFloatingButton(UIViewController *vc);
void th_removeFloatingButton(void);
void th_handleFloatTap(void);
void th_captureAuthToken(NSURLRequest *req);

// 全局变量
static NSString *gAuthToken = nil;
static NSString *gTargetUserID = nil;
static double gMyLat = 0.0;
static double gMyLon = 0.0;
static UIButton *gFloatBtn = nil;

#define EARTH_RADIUS 6371000.0

// 安全弹窗
void th_showAlert(NSString *title, NSString *msg) {
    if (!title || !msg) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *topVC = [UIApplication sharedApplication].windows.firstObject.rootViewController;
        while (topVC.presentedViewController) topVC = topVC.presentedViewController;
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// 距离计算
double th_calcDist(double lat1, double lon1, double lat2, double lon2) {
    double rad = M_PI / 180.0;
    double dLat = (lat2 - lat1) * rad;
    double dLon = (lon1 - lon2) * rad;
    double a = sin(dLat/2)*sin(dLat/2) + cos(lat1*rad)*cos(lat2*rad)*sin(dLon/2)*sin(dLon/2);
    return 2 * EARTH_RADIUS * asin(sqrt(a));
}

// 借鉴正常插件：添加悬浮按钮（核心修复）
void th_addFloatingButton(UIViewController *vc) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatBtn) return;
        gFloatBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        gFloatBtn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 90, 160, 70, 40);
        [gFloatBtn setTitle:@"查距离" forState:UIControlStateNormal];
        [gFloatBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gFloatBtn.backgroundColor = UIColor.systemBlueColor;
        gFloatBtn.layer.cornerRadius = 20;
        gFloatBtn.clipsToBounds = YES;
        [gFloatBtn addTarget:nil action:@selector(th_handleFloatTap) forControlEvents:UIControlEventTouchUpInside];
        
        // 借鉴正常插件：添加到当前VC的view，而非全局window
        [vc.view addSubview:gFloatBtn];
        [vc.view bringSubviewToFront:gFloatBtn];
    });
}

// 移除按钮
void th_removeFloatingButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatBtn) {
            [gFloatBtn removeFromSuperview];
            gFloatBtn = nil;
        }
        gTargetUserID = nil;
    });
}

// 按钮点击事件
void th_handleFloatTap(void) {
    if (!gAuthToken || !gTargetUserID || gMyLat == 0) {
        th_showAlert(@"提示", @"获取信息中，请稍后重试");
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://social.irisgw.cn/users/avatar_map/index"];
    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10];
    req.HTTPMethod = @"POST";
    [req setValue:@"zh-CN" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"a0001i" forHTTPHeaderField:@"Channel"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:gAuthToken forHTTPHeaderField:@"Authorization"];

    NSDictionary *body = @{
        @"self_location": @{@"latitude":@(gMyLat), @"longitude":@(gMyLon)},
        @"zoom_scale": @"3.77", @"avatar_span": @"56", @"use_pay_map": @0
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (err || !data) { th_showAlert(@"失败", @"网络异常"); return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *avatars = json[@"avatars"];
        for (NSDictionary *user in avatars) {
            if ([user[@"user_id"] isEqualToString:gTargetUserID]) {
                double dist = th_calcDist(gMyLat, gMyLon, [user[@"latitude"] doubleValue], [user[@"longitude"] doubleValue]);
                th_showAlert(@"成功", [NSString stringWithFormat:@"距离：%.0f米", dist]);
                return;
            }
        }
        th_showAlert(@"提示", @"未找到该用户");
    }];
    [task resume];
}

// 抓取令牌
void th_captureAuthToken(NSURLRequest *req) {
    NSDictionary *headers = req.allHTTPHeaderFields;
    NSString *auth = headers[@"Authorization"];
    if (auth && [auth hasPrefix:@"Bearer "]) {
        gAuthToken = auth;
    }
}

// ==============================================
// 精准Hook Blued真实类（来自你提供的插件符号表）
// ==============================================

// 1. Hook 个人主页 BDUserProfileViewController（按钮显示核心）
%hook BDUserProfileViewController
- (void)viewDidLoad {
    %orig;
    // 获取用户ID
    id userModel = [self valueForKey:@"userModel"];
    if (userModel) {
        gTargetUserID = [userModel valueForKey:@"userId"];
        th_addFloatingButton(self);
    }
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    th_removeFloatingButton();
}
%end

// 2. Hook 私聊页 PrivateChatViewController（兼容显示）
%hook PrivateChatViewController
- (void)viewDidLoad {
    %orig;
    th_addFloatingButton(self);
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    th_removeFloatingButton();
}
%end

// 3. Hook 网络请求抓令牌
%hook NSURLSessionDataTask
- (NSURLRequest *)originalRequest {
    NSURLRequest *req = %orig;
    th_captureAuthToken(req);
    return req;
}
%end

// 4. Hook 定位获取坐标
%hook CLLocationManager
- (void)didUpdateLocations:(NSArray<CLLocation *> *)locations {
    %orig;
    CLLocation *loc = locations.lastObject;
    if (loc) {
        gMyLat = loc.coordinate.latitude;
        gMyLon = loc.coordinate.longitude;
    }
}
%end

%ctor {
    // 空构造，无多余操作
}
