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
    ===== 修改说明 v8（2026-10）=====

    真机抓日志找到了根因：作者写的匹配字符串在自己的过滤条件里从来没命中过。

    iOS 27 把这个 settings diff 的 description 格式改了：
        作者找 "foreground = No"
        实际是 "foreground [obj] = 0"        （foreground 被拆成 [flag] / [obj] 两个键）
    加上一条都拦不住，hook 等于原样转发，保活自然失效。
    这也能解释"用两天后突然失效"——那两天系统还是旧格式，一次小版本更新改掉了。

    v8 做的事：
      1. 按真机实测格式重写匹配规则（新格式 + 旧格式都兼容）；
      2. deactivationReasons 只在被设成具体原因时吞掉，清空的那条必须放行，
         否则 App 会永远卡在失活态，就是 issue #7 的闪退；
      3. 日志只记录被拦的、以及带 foreground / deactivationReasons 字样的记录。
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
        失活：deactivationReasons 被设成具体原因（systemGesture / systemAnimation）。
        清空时是 "deactivationReasons = ;"，这一条必须放行 ——
        全吞掉会让 App 永远卡在失活态，也就是 issue #7 那个闪退。
    */
    if ([diff containsString:@"deactivationReasons"] &&
        ![diff containsString:@"deactivationReasons = ;"]) {
        return @"deactivate";
    }

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
