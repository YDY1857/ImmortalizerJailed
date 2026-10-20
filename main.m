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
    ===== 修改说明 v9（2026-10，最后一次实验版）=====

    真机日志找到的根因：作者写的匹配字符串在 iOS 27 上从来没命中过。
        iOS 27 实际格式：foreground [flag] = NotSet;  foreground [obj] = 0;
        作者找的是：      foreground = No
    所以 hook 等于空转，保活失效。

    v8 同时把 deactivationReasons 也吞了 → 切回前台直接闪退。
    v5 / v6 也是同样原因崩的。三次实测结论一致：
        **只要吞掉失活事件，iOS 27 就会终止进程**（作者 issue #7 记录过）。

    所以 v9 只做一件事：把 foreground 的匹配改成新格式。
    deactivationReasons 一律原样放行，一个字都不动。

    如果 v9 还崩，说明"吞任何 scene 更新"在 iOS 27 上都不可行，
    这条路就彻底到头了，不要再试。
*/

#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>
#import <dlfcn.h>
#import "FloatingButtonWindow.h"
#import "PrivateHeaders.h"

static BOOL isImmortalized;

#pragma mark - diff 日志

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

/* 返回非 nil 表示这条更新要被吞掉，字符串顺便当日志里的原因 */
static NSString *dropReasonForDiff(NSString *diff) {
    if (diff.length == 0) {
        return nil;
    }

    /* iOS 27 新格式：foreground 拆成 flag / obj 两个键 */
    if ([diff containsString:@"foreground [obj] = 0"] ||
        [diff containsString:@"foreground [flag] = No"] ||
        [diff containsString:@"foreground [obj] = No"]) {
        return @"foreground";
    }

    /* iOS 14 ~ 26 旧格式，保留兼容 */
    if ([diff containsString:@"foreground = NotSet"] ||
        [diff containsString:@"foreground = No"] ||
        [diff containsString:@"foreground = BSSettingFlagNo"] ||
        [diff containsString:@"foreground = NO"]) {
        return @"foreground-legacy";
    }

    /*
        v9：deactivationReasons 这条彻底不碰。
        实测 v5 / v6 / v8 都证明：只要吞掉失活事件，iOS 27 就会在切回前台时
        把进程终止掉（作者 issue #7）。所以这里只保留 foreground 分支，
        deactivationReasons 无论设置还是清空，一律原样放行。
    */

    if ([diff containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [diff containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [diff containsString:@"targetOfEventDeferringEnvironments = (empty)"]) {
        return @"snapshotting";
    }

    if ([diff containsString:@"FBSceneSnapshotAction:"]) {
        return @"snapshot-action";
    }

    return nil;
}

/* thanks to @khanhduytran0 for this wonderful hook. goat */
void new_sceneID_updateWithSettingsDiff_transitionContext_completion(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    NSString *diffDescription = [arg2 description];

    if (!isImmortalized) {
        return original_sceneID_updateWithSettingsDiff_transitionContext_completion(self, _cmd, arg1, arg2, arg3, arg4);
    }

    /*
        v8：把匹配规则改成真机实测到的格式。

        iOS 27 上这个 description 变成了：
            foreground [flag] = NotSet;
            foreground [obj]  = 0;          ← 0 就是"即将进后台"
            deactivationReasons = systemGesture;   ← 被切走的原因
            deactivationReasons = ;                ← 清空（回到前台时要放行）

        作者原来的 "foreground = No" 在新格式里根本不存在，所以一条都拦不住。
    */
    NSString *reason = dropReasonForDiff(diffDescription);
    BOOL shouldDrop = (reason != nil);

    /*
        日志只留有用的：被拦的，以及带 foreground / deactivationReasons /
        snapshotting 字样的。不然满屏都是屏幕亮度变化，把关键记录挤掉。
    */
    BOOL worthLogging = shouldDrop ||
                        [diffDescription containsString:@"foreground"] ||
                        [diffDescription containsString:@"deactivationReasons"] ||
                        [diffDescription containsString:@"Snapshotting"];

    if (worthLogging) {
        rememberDiff([NSString stringWithFormat:@"%@%@ %@",
                      shouldDrop ? @"DROP" : @"PASS",
                      reason ? [NSString stringWithFormat:@"(%@)", reason] : @"",
                      diffDescription ?: @"(null)"]);
    }

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
