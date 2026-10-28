//
//  Tweak.xm — 快手 (com.kuaishou.ksa) 视频播放页「双击 -> 打开评论区」
// ------------------------------------------------------------------
//  功能:
//   1. 播放页双击: 拦截“双击点赞”, 改为打开评论区
//   2. 取消双击爱心点赞动画
//   3. 仅在视频播放页生效
//   4. 打印日志 ([KSDT])
//   5. 防野指针闪退
//
//  实现 (不依赖快手私有类名, 稳定可编译):
//   · 核心: hook UIView -addGestureRecognizer:
//     当发现“双击”UITapGestureRecognizer 被添加时:
//        - 清空快手原 target-action (移除点赞逻辑)
//        - 添加我们自己的 target-action
//     双击触发时判断是否播放页 -> 打开评论区。
//   · 同时 hook -init / setNumberOfTapsRequired: 追踪双击手势。
//   · 爱心动画: hook CALayer -addAnimation:forKey: 过滤.
//   · 全部使用 MSHookMessageEx 动态 hook, 目标类缺失也不会导致 tweak 崩溃。
// ------------------------------------------------------------------

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

#define KSDT_LOG(fmt, ...) NSLog(@"[KSDT] " fmt, ##__VA_ARGS__)

// ==================== 安全工具 ====================
static inline BOOL KSDT_OK(id o) {
    if (!o) return NO;
    if ((uintptr_t)o < 0x1000) return NO;
    @try {
        Class c = object_getClass(o);
        if (!c || class_isMetaClass(c)) return NO;
        (void)[o isKindOfClass:[NSObject class]];
        return YES;
    } @catch (__unused NSException *e) { return NO; }
}

// ==================== 播放页判定 ====================
static NSArray<NSString *> *KSDT_PlayerKeywords(void) {
    static NSArray *kw = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        kw = @[ @"player", @"feedplayer", @"videoplayer", @"ksplayer",
                @"slidescene", @"feeddetail", @"videocontroller",
                @"photo", @"mediaview", @"video", @"pager" ];
    });
    return kw;
}
static BOOL KSDT_LooksLikePlayer(NSString *cls) {
    if (cls.length == 0) return NO;
    NSString *l = cls.lowercaseString;
    for (NSString *k in KSDT_PlayerKeywords())
        if ([l containsString:k]) return YES;
    return NO;
}
static BOOL KSDT_IsInPlayerPage(id obj) {
    if (!KSDT_OK(obj)) return NO;
    @try {
        if (KSDT_LooksLikePlayer(NSStringFromClass([obj class]))) return YES;
        id cur = obj;
        for (int i = 0; i < 20 && KSDT_OK(cur); i++) {
            if (KSDT_LooksLikePlayer(NSStringFromClass([cur class]))) return YES;
            cur = [cur nextResponder];
            if (!cur) break;
        }
        if ([obj isKindOfClass:[UIView class]]) {
            UIView *v = (UIView *)obj;
            while (v) {
                if (KSDT_LooksLikePlayer(NSStringFromClass([v class]))) return YES;
                v = v.superview;
            }
            UIResponder *r = (UIResponder *)obj;
            while (r && ![r isKindOfClass:[UIViewController class]]) r = [r nextResponder];
            if ([r isKindOfClass:[UIViewController class]])
                if (KSDT_LooksLikePlayer(NSStringFromClass([r class]))) return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

// ==================== 爱心动画屏蔽 ====================
static BOOL KSDT_IsHeartName(NSString *name) {
    if (name.length == 0) return NO;
    NSString *l = name.lowercaseString;
    for (NSString *kw in @[ @"heart", @"like", @"doubleclick", @"dblclick",
                            @"digg", @"praise", @"love", @"thumb" ])
        if ([l containsString:kw]) return YES;
    return NO;
}
static BOOL KSDT_IsHeartThing(id o) {
    if (!KSDT_OK(o)) return NO;
    @try { return KSDT_IsHeartName(NSStringFromClass([o class])); }
    @catch (__unused NSException *e) { return NO; }
}

// ==================== 打开评论区 ====================
static NSArray<NSString *> *KSDT_OpenCommentSels(void) {
    return @[ @"openComment", @"showComment", @"showComments", @"openComments",
              @"openCommentView", @"showCommentView", @"openCommentPanel",
              @"showCommentPanel", @"clickComment", @"didClickComment",
              @"onClickComment", @"showCommentList", @"presentCommentView",
              @"openCommentsPanel", @"toggleComment", @"openCommentController" ];
}

static id KSDT_FindCommentBtn(id obj, NSUInteger depth) {
    if (!KSDT_OK(obj) || depth > 7) return nil;
    @try {
        if ([obj isKindOfClass:[UIView class]]) {
            NSArray *kws = @[ @"comment", @"pinglun", @"praiselist", @"commenticon" ];
            for (UIView *sub in ((UIView *)obj).subviews) {
                if (!KSDT_OK(sub)) continue;
                NSString *cn = NSStringFromClass([sub class]).lowercaseString;
                if (cn) for (NSString *kw in kws)
                    if ([cn containsString:kw]) return sub;
                @try {
                    NSString *acc = sub.accessibilityIdentifier.lowercaseString;
                    if (acc && [acc containsString:@"comment"]) return sub;
                } @catch (__unused NSException *e) {}
                id f = KSDT_FindCommentBtn(sub, depth + 1);
                if (f) return f;
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}
static id KSDT_FindCommentBtnInWindows(void) {
    @try {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!KSDT_OK(w)) continue;
            id b = KSDT_FindCommentBtn(w, 0);
            if (b) return b;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}
static void KSDT_SafePerform(id t, NSString *selName) {
    if (!KSDT_OK(t) || !selName.length) return;
    @try {
        SEL s = NSSelectorFromString(selName);
        if (s && [t respondsToSelector:s]) {
            IMP imp = [t methodForSelector:s];
            if (imp) ((void (*)(id, SEL))imp)(t, s);
        }
    } @catch (NSException *e) { KSDT_LOG(@"perform %@ 异常:%@", selName, e); }
}

static void KSDT_OpenComment(id ctx) {
    @try {
        KSDT_LOG(@"尝试打开评论区...");
        NSMutableArray *targets = [NSMutableArray array];
        if (KSDT_OK(ctx)) [targets addObject:ctx];
        id cur = ctx;
        for (int i = 0; i < 16 && KSDT_OK(cur); i++) {
            if (![targets containsObject:cur]) [targets addObject:cur];
            cur = [cur nextResponder];
        }
        for (id t in targets) {
            for (NSString *sn in KSDT_OpenCommentSels()) {
                SEL s = NSSelectorFromString(sn);
                if (s && [t respondsToSelector:s]) {
                    KSDT_LOG(@"命中 -[%@ %@]", NSStringFromClass([t class]), sn);
                    KSDT_SafePerform(t, sn);
                    return;
                }
            }
        }
        id btn = KSDT_FindCommentBtn(ctx, 0);
        if (!btn) btn = KSDT_FindCommentBtnInWindows();
        if (KSDT_OK(btn)) {
            KSDT_LOG(@"命中评论按钮:%@", NSStringFromClass([btn class]));
            if ([btn isKindOfClass:[UIControl class]]) {
                [(UIControl *)btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            } else if ([btn isKindOfClass:[UIView class]]) {
                if ([btn respondsToSelector:@selector(accessibilityActivate)])
                    [(UIView *)btn accessibilityActivate];
                for (UIGestureRecognizer *g in [(UIView *)btn gestureRecognizers])
                    if ([g isKindOfClass:[UITapGestureRecognizer class]])
                        KSDT_SafePerform(g, @"_handleTap");
            }
            return;
        }
        KSDT_LOG(@"未找到评论入口，请查日志补充候选");
    } @catch (NSException *e) { KSDT_LOG(@"OpenComment 异常:%@", e); }
}

// ==================== 双击处理 target (强持有, 稳定) ====================
@interface KSDT_TapHandler : NSObject
- (void)onDoubleTap:(UITapGestureRecognizer *)g;
@end

@implementation KSDT_TapHandler
- (void)onDoubleTap:(UITapGestureRecognizer *)g {
    @try {
        if (!KSDT_OK(g)) { KSDT_LOG(@"双击手势已释放, 忽略"); return; }
        UIView *view = g.view;
        if (!KSDT_IsInPlayerPage(view)) {
            KSDT_LOG(@"双击不在播放页, 忽略");
            return;
        }
        KSDT_LOG(@"播放页双击 -> 打开评论区 (已拦截点赞)");
        KSDT_OpenComment(view);
    } @catch (NSException *e) { KSDT_LOG(@"onDoubleTap 异常:%@", e); }
}
@end

static KSDT_TapHandler *KSDT_handler = nil;

// 处理一个双击手势: 移除原 action, 添加我们的 action
static void KSDT_TakeOverGesture(UITapGestureRecognizer *tap) {
    if (!KSDT_OK(tap)) return;
    @try {
        if (tap.numberOfTapsRequired != 2) return;
        // 标记避免重复接管
        static char kFlag;
        if (objc_getAssociatedObject(tap, &kFlag)) return;
        objc_setAssociatedObject(tap, &kFlag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 记录原 target-action (不执行, 即拦截点赞)
        NSString *origDesc = @"(none)";
        SEL targetsSel = NSSelectorFromString(@"_targets");
        if ([tap respondsToSelector:targetsSel]) {
            id targets = ((id (*)(id, SEL))objc_msgSend)(tap, targetsSel);
            if ([targets isKindOfClass:[NSArray class]]) {
                NSMutableArray *pairs = [NSMutableArray array];
                for (id pair in targets) {
                    if (!KSDT_OK(pair)) continue;
                    SEL as = NSSelectorFromString(@"action");
                    id tg = nil; SEL ac = NULL;
                    if ([pair respondsToSelector:as])
                        ac = ((SEL (*)(id, SEL))objc_msgSend)(pair, as);
                    SEL ts = NSSelectorFromString(@"target");
                    if ([pair respondsToSelector:ts])
                        tg = ((id (*)(id, SEL))objc_msgSend)(pair, ts);
                    if (KSDT_OK(tg))
                        [pairs addObject:[NSString stringWithFormat:@"-[%@ %@]",
                                          NSStringFromClass([tg class]),
                                          ac ? NSStringFromSelector(ac) : @"?"]];
                }
                if (pairs.count) origDesc = [pairs componentsJoinedByString:@", "];
            }
        }
        KSDT_LOG(@"接管双击手势 class=%@ view=%@ 原action: %@",
                 NSStringFromClass([tap class]),
                 NSStringFromClass([tap.view class]), origDesc);

        // 移除所有原有 target-action (移除点赞)
        @try { [tap removeTarget:nil action:NULL]; }
        @catch (__unused NSException *e) {}

        // 添加我们的 handler
        [tap addTarget:KSDT_handler action:@selector(onDoubleTap:)];
    } @catch (NSException *e) { KSDT_LOG(@"TakeOver 异常:%@", e); }
}

// ==================== Hooks ====================
static void (*orig_addGesture)(id, SEL, UIGestureRecognizer *);
static void ksd_addGesture(id self, SEL _cmd, UIGestureRecognizer *g) {
    orig_addGesture(self, _cmd, g);
    @try {
        if (KSDT_OK(g) && [g isKindOfClass:[UITapGestureRecognizer class]]) {
            UITapGestureRecognizer *tap = (UITapGestureRecognizer *)g;
            if (tap.numberOfTapsRequired == 2) {
                // 快手可能在其后追加 action, 延迟到主线程下一轮再接管
                __weak UIGestureRecognizer *wg = g;
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIGestureRecognizer *gg = wg;
                    if (KSDT_OK(gg)) KSDT_TakeOverGesture((UITapGestureRecognizer *)gg);
                });
            }
        }
    } @catch (__unused NSException *e) {}
}

static void (*orig_setTapsReq)(id, SEL, NSUInteger);
static void ksd_setTapsReq(id self, SEL _cmd, NSUInteger n) {
    orig_setTapsReq(self, _cmd, n);
    @try {
        if (n == 2 && [self isKindOfClass:[UITapGestureRecognizer class]]) {
            __weak UIGestureRecognizer *wg = (UIGestureRecognizer *)self;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIGestureRecognizer *gg = wg;
                if (KSDT_OK(gg)) KSDT_TakeOverGesture((UITapGestureRecognizer *)gg);
            });
        }
    } @catch (__unused NSException *e) {}
}

static void (*orig_addAnim)(id, SEL, CAAnimation *, NSString *);
static void ksd_addAnim(id self, SEL _cmd, CAAnimation *anim, NSString *key) {
    @try {
        if (KSDT_IsHeartThing(self) || KSDT_IsHeartThing(anim) || KSDT_IsHeartName(key)) {
            KSDT_LOG(@"拦截爱心动画 layer=%@ key=%@", NSStringFromClass([self class]), key);
            return;
        }
    } @catch (__unused NSException *e) {}
    orig_addAnim(self, _cmd, anim, key);
}

// ==================== 构造函数 ====================
%ctor {
    KSDT_LOG(@"=== KSDoubleTap 已加载 (iOS15+, com.kuaishou.ksa) ===");

    KSDT_handler = [KSDT_TapHandler new];

    Class uiv = NSClassFromString(@"UIView");
    if (uiv) {
        MSHookMessageEx(uiv, @selector(addGestureRecognizer:),
                        (IMP)ksd_addGesture, (IMP *)&orig_addGesture);
        KSDT_LOG(@"已 hook UIView addGestureRecognizer:");
    }
    Class tap = NSClassFromString(@"UITapGestureRecognizer");
    if (tap) {
        MSHookMessageEx(tap, @selector(setNumberOfTapsRequired:),
                        (IMP)ksd_setTapsReq, (IMP *)&orig_setTapsReq);
        KSDT_LOG(@"已 hook UITapGestureRecognizer setNumberOfTapsRequired:");
    }
    Class cal = NSClassFromString(@"CALayer");
    if (cal) {
        MSHookMessageEx(cal, @selector(addAnimation:forKey:),
                        (IMP)ksd_addAnim, (IMP *)&orig_addAnim);
        KSDT_LOG(@"已 hook CALayer addAnimation:forKey:");
    }
    KSDT_LOG(@"初始化完成");
}
