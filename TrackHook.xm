#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>

// ========== 修复：显式声明所有自定义方法 ==========
%interface UIViewController (TrackHookMethods)
- (void)th_showToast:(NSString *)message duration:(NSTimeInterval)duration;
- (void)th_exportAllData;
- (void)th_clearAllData;
- (void)th_testCoordinateRequest;
- (void)th_showSystemLog;
- (void)th_showAllRequests;
- (void)th_onAdvancedBtnClick;
- (void)th_onButtonPan:(UIPanGestureRecognizer *)pan;
- (void)addTrackHookButton;
- (void)th_onBtnClick;
%end

// ========== 原代码保持以下部分不变 ==========
static NSMutableDictionary *g_capturedRequests;
static NSMutableArray *g_requestHistory;
static UIButton *g_trackHookButton;
static UIPanGestureRecognizer *g_buttonPanGesture;
static UIVisualEffectView *g_debugPanel;
static UITableView *g_requestTableView;
static BOOL g_isRecording = YES;
static NSString *g_apiToken = nil;

%hook UIViewController

%new
- (void)th_showToast:(NSString *)message duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:alert animated:YES completion:nil];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
    });
}

%new
- (void)th_exportAllData {
    @try {
        NSMutableString *exportString = [NSMutableString string];
        [exportString appendString:@"=== 请求捕获数据 ===\n\n"];
        
        for (NSString *key in g_capturedRequests) {
            NSDictionary *request = g_capturedRequests[key];
            [exportString appendFormat:@"URL: %@\n", request[@"url"]];
            [exportString appendFormat:@"方法: %@\n", request[@"method"]];
            [exportString appendFormat:@"时间: %@\n", request[@"timestamp"]];
            
            if (request[@"headers"]) {
                [exportString appendFormat:@"请求头: %@\n", request[@"headers"]];
            }
            
            if (request[@"body"]) {
                [exportString appendFormat:@"请求体: %@\n", request[@"body"]];
            }
            
            if (request[@"response"]) {
                [exportString appendFormat:@"响应: %@\n", request[@"response"]];
            }
            
            [exportString appendString:@"\n" + [@"-" stringByPaddingToLength:50 withString:@"-" startingAtIndex:0] + "\n\n"];
        }
        
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = exportString;
        
        [self th_showToast:@"数据已导出到剪贴板" duration:2.0];
    } @catch (NSException *exception) {
        [self th_showToast:@"导出失败" duration:2.0];
    }
}

%new
- (void)th_clearAllData {
    [g_capturedRequests removeAllObjects];
    [g_requestHistory removeAllObjects];
    
    if (g_requestTableView) {
        [g_requestTableView reloadData];
    }
    
    [self th_showToast:@"所有数据已清除" duration:2.0];
}

%new
- (void)th_testCoordinateRequest {
    NSURLSession *session = [NSURLSession sharedSession];
    NSURL *url = [NSURL URLWithString:@"https://httpbin.org/get"];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error) {
            [self th_showToast:@"测试请求已执行" duration:2.0];
        }
    }];
    [task resume];
}

%new
- (void)th_showSystemLog {
    [self th_showToast:@"系统日志功能需要额外权限" duration:2.0];
}

%new
- (void)th_onAdvancedBtnClick {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"高级功能"
                                                                   message:@"请选择操作"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"导出所有数据"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self th_exportAllData];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"清除所有数据"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [self th_clearAllData];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"测试坐标请求"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self th_testCoordinateRequest];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"系统日志"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self th_showSystemLog];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)th_onButtonPan:(UIPanGestureRecognizer *)pan {
    UIButton *button = (UIButton *)pan.view;
    CGPoint translation = [pan translationInView:button.superview];
    
    button.center = CGPointMake(button.center.x + translation.x,
                                 button.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:button.superview];
    
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGFloat screenWidth = screenBounds.size.width;
        CGFloat screenHeight = screenBounds.size.height;
        
        CGPoint buttonCenter = button.center;
        CGFloat buttonWidth = button.bounds.size.width;
        CGFloat buttonHeight = button.bounds.size.height;
        
        CGFloat leftMargin = buttonCenter.x;
        CGFloat rightMargin = screenWidth - buttonCenter.x;
        CGFloat topMargin = buttonCenter.y;
        CGFloat bottomMargin = screenHeight - buttonCenter.y;
        
        CGFloat minMargin = MIN(MIN(leftMargin, rightMargin), MIN(topMargin, bottomMargin));
        CGPoint newCenter = buttonCenter;
        
        if (minMargin == leftMargin) {
            newCenter = CGPointMake(buttonWidth/2 + 10, buttonCenter.y);
        } else if (minMargin == rightMargin) {
            newCenter = CGPointMake(screenWidth - buttonWidth/2 - 10, buttonCenter.y);
        } else if (minMargin == topMargin) {
            newCenter = CGPointMake(buttonCenter.x, buttonHeight/2 + 50);
        } else if (minMargin == bottomMargin) {
            newCenter = CGPointMake(buttonCenter.x, screenHeight - buttonHeight/2 - 10);
        }
        
        [UIView animateWithDuration:0.3 animations:^{
            button.center = newCenter;
        }];
    }
}

%new
- (void)addTrackHookButton {
    if (g_trackHookButton) {
        return;
    }
    
    g_trackHookButton = [UIButton buttonWithType:UIButtonTypeCustom];
    g_trackHookButton.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 70,
                                         [UIScreen mainScreen].bounds.size.height / 2,
                                         60, 60);
    g_trackHookButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    g_trackHookButton.layer.cornerRadius = 30;
    g_trackHookButton.layer.shadowColor = [UIColor blackColor].CGColor;
    g_trackHookButton.layer.shadowOffset = CGSizeMake(0, 2);
    g_trackHookButton.layer.shadowOpacity = 0.3;
    g_trackHookButton.layer.shadowRadius = 4;
    
    [g_trackHookButton setTitle:@"TH" forState:UIControlStateNormal];
    [g_trackHookButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    g_trackHookButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    
    [g_trackHookButton addTarget:self
                          action:@selector(th_onBtnClick)
                forControlEvents:UIControlEventTouchUpInside];
    
    g_buttonPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                 action:@selector(th_onButtonPan:)];
    [g_trackHookButton addGestureRecognizer:g_buttonPanGesture];
    
    UIWindow *keyWindow = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].windows.firstObject;
    }
    
    [keyWindow addSubview:g_trackHookButton];
    [keyWindow bringSubviewToFront:g_trackHookButton];
}

%new
- (void)th_onBtnClick {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TrackHook"
                                                                   message:@"请选择操作"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"显示所有请求"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self th_showAllRequests];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"复制Token"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        if (g_apiToken && g_apiToken.length > 0) {
            UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
            pasteboard.string = g_apiToken;
            [self th_showToast:@"Token已复制到剪贴板" duration:2.0];
        } else {
            [self th_showToast:@"无Token可复制" duration:2.0];
        }
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"高级功能"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self th_onAdvancedBtnClick];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"隐藏按钮"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        g_trackHookButton.hidden = YES;
        NSString *msg = @"按钮已隐藏，可通过重启应用恢复";
        [self th_showToast:msg duration:2.0];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)th_showAllRequests {
    if (!g_debugPanel) {
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        g_debugPanel = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        g_debugPanel.frame = CGRectMake(20, 100,
                                       [UIScreen mainScreen].bounds.size.width - 40,
                                       [UIScreen mainScreen].bounds.size.height - 200);
        g_debugPanel.layer.cornerRadius = 10;
        g_debugPanel.layer.masksToBounds = YES;
        g_debugPanel.alpha = 0;
        
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0,
                                                                       g_debugPanel.bounds.size.width, 50)];
        titleLabel.text = @"捕获的请求";
        titleLabel.textColor = [UIColor whiteColor];
        titleLabel.textAlignment = NSTextAlignmentCenter;
        titleLabel.font = [UIFont boldSystemFontOfSize:18];
        
        UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        closeButton.frame = CGRectMake(g_debugPanel.bounds.size.width - 50, 0, 50, 50);
        [closeButton setTitle:@"X" forState:UIControlStateNormal];
        [closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [closeButton addTarget:self
                        action:@selector(th_hideDebugPanel)
              forControlEvents:UIControlEventTouchUpInside];
        
        g_requestTableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 50,
                                                                          g_debugPanel.bounds.size.width,
                                                                          g_debugPanel.bounds.size.height - 50)
                                                          style:UITableViewStylePlain];
        g_requestTableView.backgroundColor = [UIColor clearColor];
        g_requestTableView.dataSource = self;
        g_requestTableView.delegate = self;
        g_requestTableView.tableFooterView = [UIView new];
        
        [g_debugPanel.contentView addSubview:titleLabel];
        [g_debugPanel.contentView addSubview:closeButton];
        [g_debugPanel.contentView addSubview:g_requestTableView];
    }
    
    UIWindow *keyWindow = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].windows.firstObject;
    }
    
    [keyWindow addSubview:g_debugPanel];
    [keyWindow bringSubviewToFront:g_debugPanel];
    
    [g_requestTableView reloadData];
    
    [UIView animateWithDuration:0.3 animations:^{
        g_debugPanel.alpha = 1;
    }];
}

%new
- (void)th_hideDebugPanel {
    [UIView animateWithDuration:0.3 animations:^{
        g_debugPanel.alpha = 0;
    } completion:^(BOOL finished) {
        [g_debugPanel removeFromSuperview];
    }];
}

- (void)viewDidLoad {
    %orig;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_capturedRequests = [NSMutableDictionary dictionary];
        g_requestHistory = [NSMutableArray array];
        
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        Method originalMethod = class_getInstanceMethod([NSURLSession class], @selector(sessionWithConfiguration:));
        Method swizzledMethod = class_getInstanceMethod([self class], @selector(th_sessionWithConfiguration:));
        method_exchangeImplementations(originalMethod, swizzledMethod);
    });
    
    if ([self isKindOfClass:NSClassFromString(@"SomeViewControllerToAvoid")]) {
        return;
    }
    
    [self addTrackHookButton];
}

%new
+ (NSURLSession *)th_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    NSURLSession *session = %orig;
    
    Class delegateClass = configuration.delegateClass;
    if (delegateClass) {
        Method originalMethod = class_getInstanceMethod(delegateClass, @selector(URLSession:task:didCompleteWithError:));
        Method swizzledMethod = class_getInstanceMethod([self class], @selector(th_URLSession:task:didCompleteWithError:));
        
        if (originalMethod && !method_getImplementation(swizzledMethod)) {
            method_exchangeImplementations(originalMethod, swizzledMethod);
        }
    }
    
    return session;
}

%new
- (void)th_URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    %orig;
    
    if (!g_isRecording) return;
    
    NSURLRequest *request = task.originalRequest;
    if (!request) return;
    
    NSString *requestId = [NSString stringWithFormat:@"%lu", (unsigned long)task.taskIdentifier];
    
    NSMutableDictionary *requestInfo = [NSMutableDictionary dictionary];
    requestInfo[@"url"] = request.URL.absoluteString ?: @"";
    requestInfo[@"method"] = request.HTTPMethod ?: @"GET";
    requestInfo[@"timestamp"] = [NSDate date].description;
    
    if (request.allHTTPHeaderFields) {
        requestInfo[@"headers"] = request.allHTTPHeaderFields;
    }
    
    if (request.HTTPBody) {
        NSString *bodyString = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        if (bodyString) {
            requestInfo[@"body"] = bodyString;
        }
    }
    
    if ([task.response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)task.response;
        NSMutableDictionary *responseDict = [NSMutableDictionary dictionary];
        responseDict[@"statusCode"] = @(httpResponse.statusCode);
        responseDict[@"headers"] = httpResponse.allHeaderFields ?: @{};
        requestInfo[@"response"] = responseDict;
    }
    
    @synchronized(g_capturedRequests) {
        g_capturedRequests[requestId] = requestInfo;
        [g_requestHistory addObject:requestInfo];
    }
    
    if (g_requestTableView) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [g_requestTableView reloadData];
        });
    }
    
    if ([request.URL.absoluteString containsString:@"token"] ||
        [request.URL.absoluteString containsString:@"api_key"]) {
        NSString *bodyString = requestInfo[@"body"];
        if (bodyString) {
            NSRange tokenRange = [bodyString rangeOfString:@"token=([^&]+)" options:NSRegularExpressionSearch];
            if (tokenRange.location != NSNotFound) {
                g_apiToken = [bodyString substringWithRange:tokenRange];
            }
        }
    }
}

%end

// ========== UITableView数据源和代理方法 ==========
%hook UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == g_requestTableView) {
        return g_capturedRequests.count;
    }
    return %orig;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == g_requestTableView) {
        static NSString *cellId = @"TrackHookCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
            cell.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.8];
            cell.textLabel.textColor = [UIColor whiteColor];
            cell.detailTextLabel.textColor = [UIColor lightGrayColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        
        NSArray *keys = [g_capturedRequests allKeys];
        if (indexPath.row < keys.count) {
            NSString *key = keys[indexPath.row];
            NSDictionary *request = g_capturedRequests[key];
            
            cell.textLabel.text = request[@"url"];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ - %@", request[@"method"], request[@"timestamp"]];
        }
        
        return cell;
    }
    return %orig;
}

%end

%hook UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == g_requestTableView) {
        NSArray *keys = [g_capturedRequests allKeys];
        if (indexPath.row < keys.count) {
            NSString *key = keys[indexPath.row];
            NSDictionary *request = g_capturedRequests[key];
            
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"请求详情"
                                                                           message:[NSString stringWithFormat:@"URL: %@\n\n方法: %@\n\n时间: %@\n\n请求头: %@\n\n请求体: %@\n\n响应: %@",
                                                                                    request[@"url"],
                                                                                    request[@"method"],
                                                                                    request[@"timestamp"],
                                                                                    request[@"headers"] ?: @"无",
                                                                                    request[@"body"] ?: @"无",
                                                                                    request[@"response"] ?: @"无"]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"复制URL"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *action) {
                UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
                pasteboard.string = request[@"url"];
            }]];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            
            UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
            while (topController.presentedViewController) {
                topController = topController.presentedViewController;
            }
            [topController presentViewController:alert animated:YES completion:nil];
        }
    } else {
        %orig;
    }
}

%end

%ctor {
    NSLog(@"[TrackHook] 已加载");
}
