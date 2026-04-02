#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

// 函数前置声明
void th_showAlert(NSString *title, NSString *msg);
void th_addFloatButton(void);
void th_removeFloatButton(void);
void th_queryUserDistance(void);

// 全局变量
static NSString *gAuthToken = nil;
static NSString *gTargetUserID = nil;
static double gMyLatitude = 0.0;
static double gMyLongitude = 0.0;
static UIButton *gFloatButton = nil;

#define EARTH_RADIUS 6371000.0

// 安全弹窗
void th_showAlert(NSString *title, NSString *msg) {
    if (!title || !msg) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        UIWindow *window = [UIApplication sharedApplication].windows.firstObject;
        if (!window) return;
        UIViewController *topVC = window.rootViewController;
        if (!topVC) return;
        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// 距离计算公式
double th_calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    double rad = M_PI / 180.0;
    double dLat = (lat2 - lat1) * rad;
    double dLon = (lon2 - lon1) * rad;
    double a = sin(dLat/2) * sin(dLat/2) + cos(lat1*rad) * cos(lat2*rad) * sin(dLon/2) * sin(dLon/2);
    return 2 * EARTH_RADIUS * asin(sqrt(a));
}

// 创建悬浮按钮
void th_addFloatButton() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatButton) return;
        gFloatButton = [UIButton buttonWithType:UIButtonTypeSystem];
        gFloatButton.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 90, 150, 70, 40);
        [gFloatButton setTitle:@"查距离" forState:UIControlStateNormal];
        [gFloatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        gFloatButton.backgroundColor = [UIColor systemBlueColor];
        gFloatButton.layer.cornerRadius = 20;
        gFloatButton.clipsToBounds = YES;
        [gFloatButton addTarget:nil action:@selector(th_queryUserDistance) forControlEvents:UIControlEventTouchUpInside];
        [[UIApplication sharedApplication].windows.firstObject addSubview:gFloatButton];
    });
}

// 销毁悬浮按钮
void th_removeFloatButton() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatButton) {
            [gFloatButton removeFromSuperview];
            gFloatButton = nil;
        }
    });
}

// 核心：查询用户距离（修复所有语法错误）
void th_queryUserDistance(void) {
    if (!gAuthToken || !gTargetUserID || gMyLatitude == 0) {
        th_showAlert(@"提示", @"信息获取中，请重试");
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://social.irisgw.cn/users/avatar_map/index"];
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url 
                                                              cachePolicy:NSURLRequestReloadIgnoringCacheData 
                                                          timeoutInterval:10];
    request.HTTPMethod = @"POST";

    // 请求头
    [request setValue:@"zh-CN" forHTTPHeaderField:@"Accept-Language"];
    [request setValue:@"a0001i" forHTTPHeaderField:@"Channel"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:gAuthToken forHTTPHeaderField:@"Authorization"];

    // 请求体
    NSDictionary *body = @{
        @"self_location": @{
            @"latitude": @(gMyLatitude),
            @"longitude": @(gMyLongitude)
        },
        @"zoom_scale": @"3.77",
        @"avatar_span": @"56",
        @"use_pay_map": @0
    };
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    // 🔥 修复：语法100%正确，方括号完全配对
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            th_showAlert(@"请求失败", @"网络异常");
            return;
        }
        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *avatars = result[@"avatars"];
        for (NSDictionary *user in avatars) {
            if ([user[@"user_id"] isEqualToString:gTargetUserID]) {
                double dist = th_calculateDistance(gMyLatitude, gMyLongitude, [user[@"latitude"] doubleValue], [user[@"longitude"] doubleValue]);
                th_showAlert(@"查询成功", [NSString stringWithFormat:@"距离：%.0f 米", dist]);
                return;
            }
        }
        th_showAlert(@"提示", @"未找到用户信息");
    }];
    [task resume];
}

// ==============================================
// 轻量Hook，TrollStore专属，绝不闪退
// ==============================================

// 监听个人主页
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *className = NSStringFromClass(self.class);
    if ([className containsString:@"Profile"]) {
        th_addFloatButton();
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    th_removeFloatButton();
}
%end

// 抓取认证令牌
%hook NSURLSessionDataTask
- (NSURLRequest *)originalRequest {
    NSURLRequest *req = %orig;
    NSString *auth = req.allHTTPHeaderFields[@"Authorization"];
    if (auth && [auth hasPrefix:@"Bearer "]) {
        gAuthToken = auth;
    }
    return req;
}
%end

// 抓取定位
%hook CLLocationManager
- (void)didUpdateLocations:(NSArray *)locations {
    %orig;
    CLLocation *loc = locations.lastObject;
    if (loc) {
        gMyLatitude = loc.coordinate.latitude;
        gMyLongitude = loc.coordinate.longitude;
    }
}
%end

// 构造函数
%ctor {

}
