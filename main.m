/* 
    Copyright (C) 2025  Serge Alagon

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>. 
*/

/*
    ===== 修改说明 v7（2026-10）=====

    这一版的目标是"退回去 + 装眼睛"，不再盲改。

    为什么退回：
      v4 硬拦 willResignActive / didEnterBackground 通知 → 拦截计数飙到 99、界面卡死；
      v5 / v6 加 deactivationReasons 过滤 → 从后台切回来直接闪退。
      这正是作者 issue #7 记录过的 iOS 27 行为：过滤失活事件会导致进程终止。

    所以 v7：
      1. scene hook 恢复成作者的原始过滤条件，一个字不改；
      2. 把每次进来的 settings diff 原文抓下来（最多 40 条），浮窗长按可以看到；
      3. applicationState 恒返回 Active（仅推送相关调用方如实返回）。

    有了真机上的真实字符串，才能精准匹配，而不是继续猜 "foreground = No"。
*/

#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>
#import <dlfcn.h>
#import "FloatingButtonWindow.h"
#import "PrivateHeaders.h"

static BOOL isImmortalized;

#pragma mark - diff 日志（v7 新增）

static NSMutableArray<NSString *> *gDiffLog = nil;

static void rememberDiff(NSString *line) {
    if (gDiffLog == nil) {
        gDiffLog = [NSMutableArray array];
    }
    if (line.length == 0) {
        line = @"(空)";
    }
    [gDiffLog addObject:line];
    while (gDiffLog.count > 40) {
        [gDiffLog removeObjectAtIndex:0];
    }
}

/* 给浮窗调用：返回当前日志快照 */
NSArray<NSString *> *ImmortalizerCopyDiffLog(void) {
    if (gDiffLog == nil) {
        return @[];
    }
    return [gDiffLog copy];
}

static void prefsChanged() {
    isImmortalized = [[NSUserDefaults standardUserDefaults] boolForKey:@"immortalized"];
}

#pragma mark - Scene 层拦截（作者的原始逻辑，保持不变）

static void (*original_sceneID_updateWithSettingsDiff_transitionContext_completion)(id, SEL, id, id, id, id);

/* thanks to @khanhduytran0 for this wonderful hook. goat */
void new_sceneID_updateWithSettingsDiff_transitionContext_completion(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    NSString *diffDescription = [arg2 description];

    if (!isImmortalized) {
        return original_sceneID_updateWithSettingsDiff_transitionContext_completion(self, _cmd, arg1, arg2, arg3, arg4);
    }

    BOOL shouldDrop = NO;

    if ([diffDescription containsString:@"foreground = NotSet"] || 
        [diffDescription containsString:@"foreground = No"] || 
        [diffDescription containsString:@"foreground = BSSettingFlagNo"] || 
        [diffDescription containsString:@"foreground = NO"]) { 
        shouldDrop = YES;
    } else if ([diffDescription containsString:@"hostContextIdentifierForSnapshotting = 0"] || 
               [diffDescription containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
               [diffDescription containsString:@"targetOfEventDeferringEnvironments = (empty)"]) { 
        shouldDrop = YES;
    } else if ([diffDescription containsString:@"FBSceneSnapshotAction:"]) { 
        shouldDrop = YES;
    }

    rememberDiff([NSString stringWithFormat:@"%@ %@", shouldDrop ? @"DROP" : @"PASS", diffDescription ?: @"(null)"]);

    if (shouldDrop) {
        return;
    }

    return original_sceneID_updateWithSettingsDiff_transitionContext_completion(self, _cmd, arg1, arg2, arg3, arg4);
}

#pragma mark - 状态查询拦截

static UIApplicationState (*orig_applicationState)(id, SEL);

static UIApplicationState realApplicationState(void) {
    if (orig_applicationState == NULL) {
        return UIApplicationStateActive;
    }
    return orig_applicationState((id)UIApplication.sharedApplication, @selector(applicationState));
}

static UIApplicationState hook_applicationState(id self, SEL _cmd) {
    UIApplicationState real = orig_applicationState ? orig_applicationState(self, _cmd) : UIApplicationStateActive;

    if (real == UIApplicationStateActive) {
        return real;
    }

    /* 推送 / PushKit 必须拿到真实状态，否则后台通知不会按后台规则处理 */
    void *returnAddress = __builtin_extract_return_addr(__builtin_return_address(0));
    Dl_info info;
    if (dladdr(returnAddress, &info) && info.dli_fname) {
        NSString *imageName = [NSString stringWithUTF8String:info.dli_fname];
        if ([imageName containsString:@"UserNotifications"] || [imageName containsString:@"PushKit"]) {
            return real;
        }
    }

    return UIApplicationStateActive;
}

#pragma mark - 通知展示拦截（作者逻辑，保留）

static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions));
static void hook_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions options)) {
    if (isImmortalized && realApplicationState() != UIApplicationStateActive) {
        completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge);
    } else if (orig_willPresent) {
        orig_willPresent(self, _cmd, center, notification, completionHandler);
    }
}

static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>);
static void hook_setDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    if (orig_setDelegate) orig_setDelegate(self, _cmd, delegate);
    if (delegate) {
        Class delegateClass = [delegate class];
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method method = class_getInstanceMethod(delegateClass, sel);
        if (method) {
            IMP currentIMP = method_getImplementation(method);
            if (currentIMP != (IMP)hook_willPresent) {
                orig_willPresent = (void *)currentIMP;
                method_setImplementation(method, (IMP)hook_willPresent);
            }
        }
    }
}

#pragma mark - Setup

static void setup() {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. Scene Hook
        Class targetClass = objc_getClass("FBSWorkspaceScenesClient");
        SEL originalSelector = @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:);
        Method originalMethod = class_getInstanceMethod(targetClass, originalSelector);

        if (originalMethod) {
            original_sceneID_updateWithSettingsDiff_transitionContext_completion = (void (*)(id, SEL, id, id, id, id))method_getImplementation(originalMethod);
            method_setImplementation(originalMethod, (IMP)new_sceneID_updateWithSettingsDiff_transitionContext_completion);
        }

        // 2. Application State Hook
        Class uiAppClass = objc_getClass("UIApplication");
        Method appStateMethod = class_getInstanceMethod(uiAppClass, @selector(applicationState));
        if (appStateMethod) {
            orig_applicationState = (void *)method_getImplementation(appStateMethod);
            method_setImplementation(appStateMethod, (IMP)hook_applicationState);
        }

        // 3. Notification Delegate Hook
        Class unCenterClass = objc_getClass("UNUserNotificationCenter");
        Method setDelegateMethod = class_getInstanceMethod(unCenterClass, @selector(setDelegate:));
        if (setDelegateMethod) {
            orig_setDelegate = (void *)method_getImplementation(setDelegateMethod);
            method_setImplementation(setDelegateMethod, (IMP)hook_setDelegate);
        }

        // 4. 监听保活开关
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)prefsChanged, CFSTR("com.sergy.immortalizerjailed.updateprefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        [[FloatingButtonWindow sharedInstance] showButton];
    });
}

__attribute__((constructor)) static void initialize() {
    prefsChanged();
    setup();
}
