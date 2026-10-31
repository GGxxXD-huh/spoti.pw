#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>

// Spotify 9.1.90; selectors are checked before use. Access is protected by a
// per-install random token embedded in the URL. No audio leaves the phone.
static const uint16_t kPort = 8765;
static NSString *const kTokenKey = @"chroma.localweb.token";
static __weak id player;
static id CaptureState(id self, SEL cmd);
static id (*originalState)(id, SEL);
static void (*originalAddObserver)(id, SEL, id);
static BOOL stateHookInstalled, observerHookInstalled;

static void CaptureObserver(id self, SEL cmd, id observer) {
    player = self;
    originalAddObserver(self, cmd, observer);
}
static void InstallPlayerHooks(void) {
    Class cls=NSClassFromString(@"SPTEsperantoPlayer");
    if (!cls) return;
    if (!stateHookInstalled) {
        SEL sel=NSSelectorFromString(@"state"); Method method=class_getInstanceMethod(cls,sel);
        if (method) { originalState=(id(*)(id,SEL))method_getImplementation(method); class_replaceMethod(cls,sel,(IMP)CaptureState,method_getTypeEncoding(method)); stateHookInstalled=YES; }
    }
    if (!observerHookInstalled) {
        SEL sel=NSSelectorFromString(@"addPlayerObserver:"); Method method=class_getInstanceMethod(cls,sel);
        if (method) { originalAddObserver=(void(*)(id,SEL,id))method_getImplementation(method); class_replaceMethod(cls,sel,(IMP)CaptureObserver,method_getTypeEncoding(method)); observerHookInstalled=YES; }
    }
}
static NSString *token;
static dispatch_source_t listener;
static atomic_bool refreshScheduled = false;

static id CaptureState(id self, SEL cmd) {
    player = self;
    return originalState(self, cmd);
}

static id ObjectValue(id obj, SEL sel) {
    return obj && [obj respondsToSelector:sel] ? ((id(*)(id,SEL))objc_msgSend)(obj,sel) : nil;
}
static double NumberValue(id obj, SEL sel, double fallback) {
    return obj && [obj respondsToSelector:sel] ? ((double(*)(id,SEL))objc_msgSend)(obj,sel) : fallback;
}
static NSString *TrackID(id track, NSDictionary *info) {
    id uri = ObjectValue(track, NSSelectorFromString(@"URI"));
    NSString *value = [uri isKindOfClass:NSURL.class] ? [uri absoluteString] :
        [uri isKindOfClass:NSString.class] ? uri : nil;
    if (!value) {
        id external = info[MPNowPlayingInfoPropertyExternalContentIdentifier];
        if ([external isKindOfClass:NSString.class]) value = external;
    }
    if (![value isKindOfClass:NSString.class]) return nil;
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSArray *parts = [value componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@":/?#=&"]];
    for (NSString *candidate in parts.reverseObjectEnumerator) {
        if (candidate.length == 22 && [candidate rangeOfCharacterFromSet:bad].location == NSNotFound) return candidate;
    }
    return nil;
}

static NSArray *CachedLyrics(NSString *trackID) {
    if (!trackID) return @[];
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSData *data = nil;
    for (NSString *folder in @[@"spoti.pw/Lyrics", @"spoti.pw/SpotifyLyrics"]) {
        NSString *path = [[base stringByAppendingPathComponent:folder]
            stringByAppendingPathComponent:[trackID stringByAppendingPathExtension:@"json"]];
        data = [NSData dataWithContentsOfFile:path];
        if (data.length > 0 && data.length <= 2*1024*1024) break;
        data = nil;
    }
    if (!data || data.length > 2*1024*1024) return @[];
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *lines = [root isKindOfClass:NSDictionary.class] ? root[@"ln"] : nil;
    if (![lines isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id line in lines) {
        if (![line isKindOfClass:NSDictionary.class] || ![line[@"w"] isKindOfClass:NSArray.class]) continue;
        NSMutableArray *words = [NSMutableArray array];
        for (id word in line[@"w"]) {
            if (![word isKindOfClass:NSArray.class] || [word count] < 3 ||
                ![word[0] isKindOfClass:NSString.class] || ![word[1] isKindOfClass:NSNumber.class] ||
                ![word[2] isKindOfClass:NSNumber.class]) continue;
            [words addObject:@{@"text":word[0],@"start":word[1],@"end":word[2]}];
        }
        id time = line[@"s"];
        if (words.count && [time isKindOfClass:NSNumber.class]) {
            id end = [line[@"e"] isKindOfClass:NSNumber.class] ? line[@"e"] : time;
            [out addObject:@{@"time":time,@"end":end,@"words":words}];
        }
        if (out.count >= 1000) break;
    }
    return out;
}

static NSDictionary *Snapshot(void) {
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo ?: @{};
    id state = ObjectValue(player, NSSelectorFromString(@"state"));
    id track = ObjectValue(state, NSSelectorFromString(@"track"));
    NSString *title = [info[MPMediaItemPropertyTitle] isKindOfClass:NSString.class] ? info[MPMediaItemPropertyTitle] : ObjectValue(track, NSSelectorFromString(@"trackTitle"));
    NSString *artist = [info[MPMediaItemPropertyArtist] isKindOfClass:NSString.class] ? info[MPMediaItemPropertyArtist] : ObjectValue(track, NSSelectorFromString(@"artistName"));
    double duration = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
    if (duration <= 0) duration = NumberValue(state, NSSelectorFromString(@"duration"), 0);
    double position = [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue];
    position = NumberValue(state, NSSelectorFromString(@"position"), position);
    if (!isfinite(duration)) duration=0;
    if (!isfinite(position)) position=0;
    double rate = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
    if (state && [state respondsToSelector:NSSelectorFromString(@"isPaused")])
        rate = ((BOOL(*)(id,SEL))objc_msgSend)(state, NSSelectorFromString(@"isPaused")) ? 0 : 1;
    NSString *trackID = TrackID(track,info);
    return @{@"title":title ?: @"Waiting for Spotify", @"artist":artist ?: @"", @"trackID":trackID ?: @"",
             @"duration":@(MAX(0,duration)), @"position":@(MAX(0,position)),
             @"playing":@(rate > 0), @"lyrics":CachedLyrics(trackID),
             @"controlReady":@(player != nil), @"playerHooks":@[@(stateHookInstalled), @(observerHookInstalled)]};
}

static NSData *Art(void) {
    id artwork = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyArtwork];
    if (![artwork respondsToSelector:@selector(imageWithSize:)]) return nil;
    UIImage *image = [artwork imageWithSize:CGSizeMake(500,500)];
    return image ? UIImageJPEGRepresentation(image, 0.8) : nil;
}

static BOOL Command(NSString *action) {
    id p = player, state = ObjectValue(p, NSSelectorFromString(@"state"));
    if (!p) return NO;
    SEL sel = NULL;
    if ([action isEqualToString:@"toggle"]) {
        BOOL paused = state && [state respondsToSelector:NSSelectorFromString(@"isPaused")] ?
            ((BOOL(*)(id,SEL))objc_msgSend)(state,NSSelectorFromString(@"isPaused")) : NO;
        sel = NSSelectorFromString(paused ? @"resume:" : @"pause:");
        if ([p respondsToSelector:sel]) { ((id(*)(id,SEL,id))objc_msgSend)(p,sel,nil); return YES; }
    } else if ([action isEqualToString:@"next"]) {
        sel = NSSelectorFromString(@"skipToNextTrack");
        if ([p respondsToSelector:sel]) { ((void(*)(id,SEL))objc_msgSend)(p,sel); return YES; }
        sel = NSSelectorFromString(@"skipToNextTrackWithOptions:");
        if ([p respondsToSelector:sel]) { ((id(*)(id,SEL,id))objc_msgSend)(p,sel,nil); return YES; }
    } else if ([action isEqualToString:@"previous"]) {
        sel = NSSelectorFromString(@"skipToPreviousTrackWithOptions:");
        if ([p respondsToSelector:sel]) { ((id(*)(id,SEL,id))objc_msgSend)(p,sel,nil); return YES; }
    } else if ([action hasPrefix:@"seek/"]) {
        NSString *value = [action substringFromIndex:5];
        NSScanner *scanner = [NSScanner scannerWithString:value]; double seconds = 0;
        sel = NSSelectorFromString(@"seekTo:");
        if ([scanner scanDouble:&seconds] && scanner.isAtEnd && isfinite(seconds) && seconds >= 0 &&
            seconds <= 86400 && [p respondsToSelector:sel]) {
            ((void(*)(id,SEL,double))objc_msgSend)(p,sel,seconds); return YES;
        }
    }
    return NO;
}

#include "local_web_page.h"

static void Reply(int fd, int status, NSString *type, NSData *body) {
    const char *reason = status == 200 ? "OK" : status == 404 ? "Not Found" : "Bad Request";
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %d %s\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n",status,reason,type,(unsigned long)body.length];
    NSData *head = [header dataUsingEncoding:NSUTF8StringEncoding];
    for (NSData *chunk in @[head,body ?: NSData.data]) {
        const uint8_t *p = chunk.bytes; NSUInteger left = chunk.length;
        while (left) { ssize_t n = send(fd,p,left,0); if (n <= 0) return; p += n; left -= (NSUInteger)n; }
    }
}

static void LocalWebHandle(int fd) {
    @autoreleasepool {
        struct timeval timeout = {3,0}; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        int noSigPipe=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSigPipe,sizeof(noSigPipe));
        char data[8193]; ssize_t count = 0;
        while (count < (ssize_t)sizeof(data)-1) {
            ssize_t n = recv(fd,data+count,sizeof(data)-1-(size_t)count,0);
            if (n <= 0) break;
            count += n; data[count]=0;
            if (strstr(data,"\r\n\r\n")) break;
        }
        if (count <= 0) { close(fd); return; } data[count]=0;
        NSString *request = [[NSString alloc] initWithBytes:data length:(NSUInteger)count encoding:NSUTF8StringEncoding];
        NSArray *words = [[[request componentsSeparatedByString:@"\r\n"] firstObject] componentsSeparatedByString:@" "];
        if (words.count < 2) { Reply(fd,400,@"text/plain",NSData.data);close(fd);return; }
        NSString *method=words[0], *path=[[words[1] componentsSeparatedByString:@"?"] firstObject];
        NSString *prefix=[@"/" stringByAppendingString:token];
        if (![path isEqualToString:prefix] && ![path hasPrefix:[prefix stringByAppendingString:@"/"]]) {
            Reply(fd,404,@"text/plain",NSData.data);close(fd);return;
        }
        NSString *tail=[path substringFromIndex:prefix.length];
        __block NSData *body=nil; __block int status=200; NSString *type=@"text/html; charset=utf-8";
        if ([method isEqualToString:@"GET"] && (tail.length==0 || [tail isEqualToString:@"/"])) body=[NSData dataWithBytes:kWebPage length:kWebPageLength];
        else if ([method isEqualToString:@"GET"] && [tail isEqualToString:@"/state"]) {
            __block NSDictionary *state; dispatch_sync(dispatch_get_main_queue(),^{ state=Snapshot(); });
            body=[NSJSONSerialization dataWithJSONObject:state options:0 error:nil];type=@"application/json; charset=utf-8";
        } else if ([method isEqualToString:@"GET"] && [tail isEqualToString:@"/art"]) {
            dispatch_sync(dispatch_get_main_queue(),^{ body=Art(); });type=@"image/jpeg";if(!body)status=404;
        } else if ([method isEqualToString:@"POST"] && [tail hasPrefix:@"/control/"]) {
            NSString *action=[tail substringFromIndex:9]; __block BOOL ok=NO;
            dispatch_sync(dispatch_get_main_queue(),^{ ok=Command(action); });
            status=ok?200:400;type=@"application/json";body=[NSJSONSerialization dataWithJSONObject:@{@"ok":@(ok)} options:0 error:nil];
        } else status=404;
        Reply(fd,status,type,body ?: NSData.data);close(fd);
    }
}

static NSString *WifiAddress(void) {
    struct ifaddrs *interfaces=NULL; NSString *address=nil;
    if (getifaddrs(&interfaces)==0) {
        for (struct ifaddrs *i=interfaces;i;i=i->ifa_next) {
            if (i->ifa_addr && i->ifa_addr->sa_family==AF_INET && strcmp(i->ifa_name,"en0")==0) {
                char buffer[INET_ADDRSTRLEN];
                if (inet_ntop(AF_INET,&((struct sockaddr_in *)i->ifa_addr)->sin_addr,buffer,sizeof(buffer))) address=[NSString stringWithUTF8String:buffer];
                break;
            }
        }
        freeifaddrs(interfaces);
    }
    return address;
}

static void ShowLink(int attempts) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"spotifyglass.webPlayer"]) return;
    NSString *address=WifiAddress();
    if (!address) return;
    UIViewController *root=nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows) if (window.isKeyWindow) {root=window.rootViewController;break;}
    if (!root && attempts>0) {dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{ShowLink(attempts-1);});return;}
    if (!root) return;
    while (root.presentedViewController) root=root.presentedViewController;
    NSString *url=[NSString stringWithFormat:@"http://%@:%u/%@/",address,kPort,token];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Local Web Player" message:url preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy link" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){UIPasteboard.generalPasteboard.string=url;}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Share link" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
            share.popoverPresentationController.sourceView=root.view;
            [root presentViewController:share animated:YES completion:nil];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [root presentViewController:alert animated:YES completion:nil];
}

// All listener lifecycle changes run on the main queue. The Chroma toggle is
// the single source of truth; cancellation closes the listening socket.
static void RefreshLocalWeb(void) {
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:@"spotifyglass.webPlayer"];
    if (!enabled) {
        if (listener) { dispatch_source_cancel(listener); listener = nil; }
        return;
    }
    if (listener) return;
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if (fd<0) { NSLog(@"[chroma-local] socket failed"); return; }
    int reuse=1; setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse));
    struct sockaddr_in addr={0}; addr.sin_len=sizeof(addr); addr.sin_family=AF_INET;
    addr.sin_port=htons(kPort); addr.sin_addr.s_addr=htonl(INADDR_ANY);
    if (bind(fd,(struct sockaddr *)&addr,sizeof(addr))<0 || listen(fd,8)<0) {
        close(fd); NSLog(@"[chroma-local] could not listen on port %u",kPort);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ RefreshLocalWeb(); });
        return;
    }
    dispatch_queue_t q=dispatch_queue_create("pw.chroma.localweb",DISPATCH_QUEUE_SERIAL);
    listener=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,q);
    dispatch_source_set_event_handler(listener,^{ int client=accept(fd,NULL,NULL); if(client>=0)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{LocalWebHandle(client);}); });
    dispatch_source_set_cancel_handler(listener,^{close(fd);}); dispatch_resume(listener);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(),^{ShowLink(5);});
}

static void ScheduleLocalWebRefresh(void) {
    if (atomic_exchange(&refreshScheduled, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&refreshScheduled, false);
        RefreshLocalWeb();
    });
}

__attribute__((constructor)) static void StartLocalWeb(void) {
    @autoreleasepool {
        NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
        NSString *saved=[defaults stringForKey:kTokenKey];
        if (saved.length != 32) {
            unsigned char bytes[16]; if (SecRandomCopyBytes(kSecRandomDefault,sizeof(bytes),bytes)!=errSecSuccess) return;
            NSMutableString *hex=[NSMutableString stringWithCapacity:32]; for (int i=0;i<16;i++) [hex appendFormat:@"%02x",bytes[i]];
            saved=hex; [defaults setObject:saved forKey:kTokenKey];
        }
        token=[saved copy];
        InstallPlayerHooks();
        dispatch_async(dispatch_get_main_queue(),^{
            InstallPlayerHooks();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{InstallPlayerHooks();});
            NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
            [center addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note){ScheduleLocalWebRefresh();}];
            [center addObserverForName:@"SGWebPlayerDidChangeNotification" object:nil queue:nil usingBlock:^(__unused NSNotification *note){ScheduleLocalWebRefresh();}];
            RefreshLocalWeb();
        });
    }
}
