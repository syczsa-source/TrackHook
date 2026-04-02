#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

// 提前声明
void th_requestDistance(void);
void th_showAlert(NSString *title, NSString *msg);
void th_addFloatBtn(void);
void th_removeFloatBtn(void);

// 全局数据
static NSString *gAuthToken = nil;
static NSString *gTargetUserID = nil;
static double gMyLat = 0.0;
static double gMyLon = 0.0;
static UIButton *gFloatButton = nil;

#define EARTH_RADIUS 6371000.0

// 弹窗
void th_showAlert(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *vc = [UIApplication sharedApplication].windows.firstObject.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

// 距离计算
double th_calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    double rad = M_PI / 180.0;
    double dLat = (lat2 - lat1) * rad;
    double dLon = (lon2 - lon1) * rad;
    double a = sin(dLat/2) * sin(dLat/2) + cos(lat1*rad) * cos(lat2*rad) * sin(dLon/2) * sin(dLon/2);
    return 2 * EARTH_RADIUS * atan2(sqrt(a), sqrt(1-a));
}

// 悬浮按钮
void th_addFloatBtn() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatButton) return;
        gFloatButton = [UIButton buttonWithType:UIButtonTypeSystem];
        gFloatButton.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 80, 120, 60, 44);
        [gFloatButton setTitle:@"查距离" forState:UIControlStateNormal];
        [gFloatButton setBackgroundColor:[UIColor systemBlueColor]];
        [gFloatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        gFloatButton.layer.cornerRadius = 22;
        [gFloatButton addTarget:nil action:@selector(th_requestDistance) forControlEvents:UIControlEventTouchUpInside];
        [[UIApplication sharedApplication].windows.firstObject addSubview:gFloatButton];
    });
}

void th_removeFloatBtn() {
    dispatch_async(dispatch_get_main_queue(), ^{
        [gFloatButton removeFromSuperview];
        gFloatButton = nil;
    });
}

// 查询距离
void th_requestDistance(void) {
    if (!gAuthToken || !gTargetUserID || gMyLat == 0) {
        th_showAlert(@"提示", @"正在获取信息，请稍等");
        return;
    }

    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:@"https://social.irisgw.cn/users/avatar_map/index"]];
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
                double dist = th_calculateDistance(gMyLat, gMyLon, [user[@"latitude"] doubleValue], [user[@"longitude"] doubleValue]);
                th_showAlert(@"查询成功", [NSString stringWithFormat:@"对方ID：%@\n距离：%.0f米", gTargetUserID, dist]);
                return;
            }
        }
        th_showAlert(@"提示", @"未找到该用户");
    } resume];
}

// ==============================================
// 🔥 核心：只Hook Blued自定义类，不碰任何系统类
// 完全不闪退，自动抓取全保留
// ==============================================

// 1. 抓取 Blued 主页用户ID（安全）
%hook BLUserProfileViewController
- (void)viewDidLoad {
    %orig;
    id userModel = [self valueForKey:@"userModel"];
    gTargetUserID = [userModel valueForKey:@"userId"];
    th_addFloatBtn();
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    th_removeFloatBtn();
}
%end

// 2. 抓取 Blued 网络请求的 Authorization（安全）
%hook BLAPIManager
- (void)setValue:(id)value forHTTPHeaderField:(NSString *)field {
    %orig;
    if ([field isEqualToString:@"Authorization"]) {
        gAuthToken = value;
    }
}
%end

// 3. 抓取 Blued 自身的定位数据（安全）
%hook BLLocationManager
- (void)didUpdateLocationWithLatitude:(double)lat longitude:(double)lon {
    %orig;
    gMyLat = lat;
    gMyLon = lon;
}
%end

// 空构造，无系统操作
%ctor { }
