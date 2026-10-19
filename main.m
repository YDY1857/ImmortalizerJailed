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
    ===== 修改说明 v4（2026-10，针对"进程还活着但倒计时冻结"）=====

    原来的三个 hook 只处理了 scene 的 settings diff（foreground = No 等），
    但广告 SDK 暂停倒计时靠的是通知，不是 scene 状态：
        UIApplicationWillResignActiveNotification   ← 失焦，广告最常见的是这个
        UIApplicationDidEnterBackgroundNotification
    只要这两个通知送到 App，开屏广告 / 激励视频就会立刻 pause，定时器被 invalidate。

    本次在 NSNotificationCenter 的发帖入口上做一层过滤：
    勾了保活之后，这两个通知以及对应的 UIScene 版本不再投递给 App 内部的监听者，
    广告就以为"我一直在前台"，倒计时继续走。

    同时 applicationState 改为恒返回 Active（只对 UserNotifications / PushKit
    的调用方如实返回），避免 App 通过状态查询自己得出"我在后台"的结论。

    被拦截的次数会写进 NSUserDefaults 的 immortalizer_swallow_count，
    浮窗长按时可以看 —— 如果这个数字一直是 0，说明压根没有失焦通知发出，
    那倒计时就是被 CADisplayLink / 视频渲染停掉的，代码层面无解。
*/

#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>
#import <dlfcn.h>
#import "FloatingButtonWindow.h"
#import "PrivateHeaders.h"

static BOOL isImmortalized;

static void prefsChanged() {
    isImmortalized = [[NSUserDefaults standardUserDefaults] boolForKey:@"immortalized"];
}

#pragma mark - Scene 层拦截（原作者逻辑，保持不变）

static void (*original_sceneID_updateWithSettingsDiff_transitionContext_completion)(id, SEL, id, id, id, id);

/* thanks to @khanhduytran0 for this wonderful hook. goat */
void new_sceneID_updateWithSettingsDiff_transitionContext_completion(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    if (!isImmortalized) {
        return original_sceneID_updateWithSettingsDiff_transitionContext_completion(self, _cmd, arg1, arg2, arg3, arg4);
    }

    NSString *diffDescription = [arg2 description];

    if ([diffDescription containsString:@"foreground = NotSet"] || 
        [diffDescription containsString:@"foreground = No"] || 
        [diffDescription containsString:@"foreground = BSSettingFlagNo"] || 
        [diffDescription containsString:@"foreground = NO"]) { 
        return;
    }

    if ([diffDescription containsString:@"hostContextIdentifierForSnapshotting = 0"] || 
        [diffDescription containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [diffDescription containsString:@"targetOfEventDeferringEnvironments = (empty)"]) { 
        return;
    }
    
    if ([diffDescription containsString:@"FBSceneSnapshotAction:"]) { 
        return;
    }

    return original_sceneID_updateWithSettingsDiff_transitionContext_completion(self, _cmd, arg1, arg2, arg3, arg4);
}

#pragma mark - 通知层拦截（v4 新增）

static NSArray *blockedNotificationNames(void) {
    static NSArray *names = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[
            UIApplicationWillResignActiveNotification,
            UIApplicationDidEnterBackgroundNotification,
            @"UIApplicationWillBeginSuspendingNotification",
            @"UISceneWillDeactivateNotification",
            @"UISceneDidEnterBackgroundNotification"
        ];
    });
    return names;
}

static BOOL shouldSwallowNotification(NSString *name) {
    if (!isImmortalized || name == nil) {
        return NO;
    }
    if (![blockedNotificationNames() containsObject:name]) {
        return NO;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger count = [defaults integerForKey:@"immortalizer_swallow_count"];
    [defaults setInteger:count + 1 forKey:@"immortalizer_swallow_count"];

    return YES;
}

static void (*orig_post_with_info)(id, SEL, NSString *, id, NSDictionary *);
static void hook_post_with_info(id self, SEL _cmd, NSString *name, id object, NSDictionary *info) {
    if (shouldSwallowNotification(name)) {
        return;
    }
    orig_post_with_info(self, _cmd, name, object, info);
}

static void (*orig_post_basic)(id, SEL, NSString *, id);
static void hook_post_basic(id self, SEL _cmd, NSString *name, id object) {
    if (shouldSwallowNotification(name)) {
        return;
    }
    orig_post_basic(self, _cmd, name, object);
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

#pragma mark - 通知展示拦截（v3 原有逻辑，保留）

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

        // 2. 通知投递过滤（v4）
        Class centerClass = objc_getClass("NSNotificationCenter");
        if (centerClass) {
            Method withInfo = class_getInstanceMethod(centerClass, @selector(postNotificationName:object:userInfo:));
            if (withInfo) {
                orig_post_with_info = (void (*)(id, SEL, NSString *, id, NSDictionary *))method_getImplementation(withInfo);
                method_setImplementation(withInfo, (IMP)hook_post_with_info);
            }
            Method basic = class_getInstanceMethod(centerClass, @selector(postNotificationName:object:));
            if (basic) {
                orig_post_basic = (void (*)(id, SEL, NSString *, id))method_getImplementation(basic);
                method_setImplementation(basic, (IMP)hook_post_basic);
            }
        }

        // 3. Application State Hook
        Class uiAppClass = objc_getClass("UIApplication");
        Method appStateMethod = class_getInstanceMethod(uiAppClass, @selector(applicationState));
        if (appStateMethod) {
            orig_applicationState = (void *)method_getImplementation(appStateMethod);
            method_setImplementation(appStateMethod, (IMP)hook_applicationState);
        }

        // 4. Notification Delegate Hook
        Class unCenterClass = objc_getClass("UNUserNotificationCenter");
        Method setDelegateMethod = class_getInstanceMethod(unCenterClass, @selector(setDelegate:));
        if (setDelegateMethod) {
            orig_setDelegate = (void *)method_getImplementation(setDelegateMethod);
            method_setImplementation(setDelegateMethod, (IMP)hook_setDelegate);
        }

        // 5. 监听保活开关
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)prefsChanged, CFSTR("com.sergy.immortalizerjailed.updateprefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        [[FloatingButtonWindow sharedInstance] showButton];
    });
}

__attribute__((constructor)) static void initialize() {
    prefsChanged();
    setup();
}
